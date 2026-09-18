#!/usr/bin/env bash
#
# server-setup.sh — Automated Server Provisioning: deploy-service + api-service
# Installs and configures: Nomad, Docker (+BuildKit), Railpack, Redis, Traefik
# (with Cloudflare DNS-01 TLS), deploy-service, and api-service (both
# managed by pm2). Applies any pending Prisma migrations (for whichever
# service has a schema) before starting either service under pm2.
#
# Target: a fresh Ubuntu 24.04 server.
#
# USAGE — always source set-env.sh first, then run this with sudo -E
# (the -E preserves the environment variables the sourcing just set):
#   source test.set-env.sh
#   sudo -E bash test.server-setup.sh
#
# This script takes NO command-line flags — every value it needs (APP_ENV,
# DOMAIN, CF_DNS_API_TOKEN, ACME_EMAIL, etc.) comes from environment
# variables that must already be set (normally by sourcing set-env.sh
# immediately before running this).
#
# ENVIRONMENT-AWARE NAMING (driven entirely by $APP_ENV, required, no exceptions):
#   APP_ENV=prod:            bare names/domain, no prefix at all
#                         -> deploy-service, api-service, ship.<DOMAIN>
#   APP_ENV=test/demo/other: "<env>-" prefix on service names,
#                         "<env>." inserted into the domain right before
#                         the base domain, after any subdomain
#                         -> test-deploy-service, test-api-service,
#                            ship.test.<DOMAIN>
#   Ports are also offset per environment (prod +0, test +1000,
#   demo +2000) so multiple environments can coexist on one host
#   without colliding, if that's ever needed.
#
# ARCHITECTURE:
#   - deploy-service: public, does the actual build+deploy work. Auth on
#     every request calls api-service's token-introspection endpoint.
#     There is no bypass — every deploy request must present a real,
#     valid token that api-service recognizes.
#   - api-service: internal-only (never exposed via Traefik).
#   - Both services' actual code is pulled from git (see
#     DEPLOY_SERVICE_REPO / API_SERVICE_REPO below) — this script does
#     NOT generate or assume anything about either service's internals
#     beyond "has a package.json with a start script." Whatever each
#     repo actually implements (token storage, company/project logic,
#     etc.) is that repo's own concern — consult each one's own docs.
#
# DNS mapping is done MANUALLY, not by this script — see README.md for
# the exact records to create. This script only configures the server
# side (Nomad, Traefik, the two services); it never touches DNS.
#
# Required (environment variables — normally set by sourcing set-env.sh):
#   APP_ENV                 test | demo | prod
#   DOMAIN              e.g. embarko.ai
#   CF_DNS_API_TOKEN    Cloudflare API token, "Edit zone DNS" scope, for
#                       this zone — needed for Traefik's DNS-01 certificate
#                       challenge, NOT for creating DNS records (that's
#                       manual — see README.md)
#   ACME_EMAIL          real email for Let's Encrypt expiry notices
#   DEPLOY_SERVICE_REPO git URL for deploy-service's source
#   API_SERVICE_REPO    git URL for api-service's source
#
# Optional:
#   INTERNAL_API_SECRET  shared secret between deploy-service and api-service;
#                        if not set, one is generated. Must be named exactly
#                        this — it's written into each service's .env under
#                        the key their own code actually reads
#                        (process.env.INTERNAL_API_SECRET in both repos).
#   DEPLOY_SUBDOMAIN     default: ship
#   APPS_SUBDOMAIN_BASE  default: app   (apps live at <name>.<APPS_SUBDOMAIN_BASE>.[<env>.]<DOMAIN>)
#   APP_USER             default: ubuntu (the user both services and pm2 run as — shared across environments, not env-prefixed)

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Read required vars from the environment, validate, compute naming
# ---------------------------------------------------------------------------
: "${APP_ENV:?APP_ENV is not set. Source set-env.sh first: source test.set-env.sh}"
: "${DOMAIN:?DOMAIN is not set. Source set-env.sh first.}"
: "${CF_DNS_API_TOKEN:?CF_DNS_API_TOKEN is not set. Source set-env.sh first.}"
: "${ACME_EMAIL:?ACME_EMAIL is not set. Source set-env.sh first.}"
: "${DEPLOY_SERVICE_REPO:?DEPLOY_SERVICE_REPO is not set. Source set-env.sh first.}"
: "${API_SERVICE_REPO:?API_SERVICE_REPO is not set. Source set-env.sh first.}"

if [[ ! "$APP_ENV" =~ ^(test|demo|prod)$ ]]; then
  echo "ERROR: APP_ENV must be one of: test, demo, prod (got '$APP_ENV'). Check set-env.sh." >&2
  exit 1
fi

export INTERNAL_API_SECRET="${INTERNAL_API_SECRET:-$(openssl rand -hex 32)}"
DEPLOY_SUBDOMAIN="${DEPLOY_SUBDOMAIN:-ship}"
APPS_SUBDOMAIN_BASE="${APPS_SUBDOMAIN_BASE:-app}"
APP_USER="${APP_USER:-ubuntu}"
APP_HOME="/home/${APP_USER}"

if [[ "$APP_ENV" == "prod" ]]; then
  PREFIX=""
  DOMAIN_ENV_SEGMENT=""
  PORT_OFFSET=0
else
  PREFIX="${APP_ENV}-"
  # Overridable: export DOMAIN_ENV_SEGMENT="" before sourcing this (e.g. in
  # your set-env.sh) to serve this environment off the BARE domain
  # (ship.<DOMAIN> instead of ship.test.<DOMAIN>) — useful when a domain
  # already has DNS/a cert provisioned for it from before this environment
  # naming scheme existed. Directory names, pm2 process names, and the
  # port offset below are untouched either way — this only affects the
  # domain. Uses bash's "-" (not ":-") so an explicitly-empty override is
  # honored — only a genuinely UNSET DOMAIN_ENV_SEGMENT falls back to the
  # default "<env>." segment.
  DOMAIN_ENV_SEGMENT="${DOMAIN_ENV_SEGMENT-${APP_ENV}.}"
  case "$APP_ENV" in
    test) PORT_OFFSET=1000 ;;
    demo) PORT_OFFSET=2000 ;;
  esac
fi

DEPLOY_SERVICE_NAME="${PREFIX}deploy-service"
API_SERVICE_NAME="${PREFIX}api-service"
DEPLOY_PORT=$((4000 + PORT_OFFSET))
API_PORT=$((4100 + PORT_OFFSET))
# The scale-to-zero activator (deploy-service/activator.js). Same offset
# scheme as the two above so test/demo/prod can share a box without
# colliding. Bound to 127.0.0.1 only — it is reached exclusively through
# Traefik, never directly.
ACTIVATOR_PORT=$((4200 + PORT_OFFSET))

# How long an app must go without a real (non-bot) request before the idle
# watcher may stop it. Defaulted here rather than required in
# <env>.variables.sh so an older variables file still provisions.
#
# 360 minutes = 6 hours. The number is chosen around the cost of STOPPING,
# not the cost of waking: waking is graceful (~5s, the visitor gets a slow
# page and then correct content), but for the few seconds after a stop
# Traefik still routes to the dead allocation and a request gets a hard
# 502. So what matters is how OFTEN an app stops, not how long it stays
# stopped. Working-day gaps run 4-6 hours, so a shorter threshold makes
# apps cycle during office hours, putting those 502 windows exactly where
# people are; 6 hours pushes almost every stop into the night, when the
# same window is very unlikely to be hit by anyone. See
# docs/scale-to-zero-gated-plan.md Step 5.
IDLE_THRESHOLD_MIN="${IDLE_THRESHOLD_MIN:-360}"

# pm2 process names ALWAYS carry the APP_ENV prefix, even for prod —
# deliberately separate from DEPLOY_SERVICE_NAME/API_SERVICE_NAME above
# (which stay bare-for-prod, used for directories/domains/Traefik, since
# those are already deployed on prod using bare names — changing that
# would mean re-provisioning already-working infrastructure). This only
# affects how processes are labeled in `pm2 list`.
PM2_DEPLOY_NAME="${APP_ENV}-deploy-service"
PM2_API_NAME="${APP_ENV}-api-service"
PM2_ACTIVATOR_NAME="${APP_ENV}-activator"

DEPLOY_HOST="${DEPLOY_SUBDOMAIN}.${DOMAIN_ENV_SEGMENT}${DOMAIN}"
APPS_DOMAIN_SUFFIX="${APPS_SUBDOMAIN_BASE}.${DOMAIN_ENV_SEGMENT}${DOMAIN}"
# Dedicated CNAME target for CLIENT custom domains (see api-service's
# docs/Customdomain-req.md) — deliberately a separate hostname from
# DEPLOY_HOST/APPS_DOMAIN_SUFFIX above, and must stay unproxied if this
# host ever sits behind a proxying CDN: an external domain not managed in
# that same proxy account can't be CNAME'd to a proxied hostname. Same
# env-segment convention as the other computed hostnames above.
EDGE_HOSTNAME="edge.${DOMAIN_ENV_SEGMENT}${DOMAIN}"

echo "=================================================================="
echo " Provisioning — environment: ${APP_ENV}"
echo " deploy-service   : ${DEPLOY_SERVICE_NAME}  (port ${DEPLOY_PORT})"
echo " activator        : ${PM2_ACTIVATOR_NAME}  (port ${ACTIVATOR_PORT}, scale-to-zero)"
echo " api-service      : ${API_SERVICE_NAME}  (port ${API_PORT})"
echo " Deploy API host  : https://${DEPLOY_HOST}/apps"
echo " api-service      : https://${DEPLOY_HOST}/api (internal-only otherwise)"
echo " Apps wildcard    : https://<app>.${APPS_DOMAIN_SUFFIX}"
echo " Custom-domain CNAME target : ${EDGE_HOSTNAME}  (must stay unproxied — see README.md)"
echo "=================================================================="

SERVER_IP=$(curl -s https://ifconfig.me || hostname -I | awk '{print $1}')
echo "Detected server IP: ${SERVER_IP}"

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
# apt/dpkg's lock can be held transiently by Ubuntu's own automatic
# background updater (unattended-upgrades), on its own independent
# schedule unrelated to anything this script does. Confirmed in practice
# — this exact contention has actually happened, not theoretical. Wait it
# out with a bounded retry rather than hard-failing, since this can occur
# at genuinely unpredictable times on any fresh box.
wait_for_apt_lock() {
  local max_wait=300
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if [[ $waited -ge $max_wait ]]; then
      echo "ERROR: dpkg lock still held after ${max_wait}s (likely unattended-upgrades taking unusually long). Giving up." >&2
      echo "Check manually: ps aux | grep unattended-upgr" >&2
      exit 1
    fi
    echo "    Waiting for dpkg lock to be released (likely unattended-upgrades running)... (${waited}s elapsed)"
    sleep 5
    waited=$((waited + 5))
  done
}

echo "--> Installing base packages"
wait_for_apt_lock
apt-get update -y
wait_for_apt_lock
apt-get install -y wget gpg coreutils curl unzip jq ufw git xz-utils

# ---------------------------------------------------------------------------
# 2. Nomad — installed as a direct binary download from HashiCorp's releases,
#    NOT via apt. This is deliberate: apt.releases.hashicorp.com does not
#    reliably publish packages for every Ubuntu codename (confirmed missing
#    for 20.04/focal in practice), which silently falls back to whatever
#    ancient version Ubuntu's own `universe` repo happens to bundle —
#    incompatible with the modern nomad.hcl this script generates. A direct
#    binary download has no such dependency on OS version/codename at all.
# ---------------------------------------------------------------------------
echo "--> Installing Nomad (direct binary, not apt — see comment above for why)"
NOMAD_VERSION=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/nomad | jq -r .current_version)
if [[ -z "$NOMAD_VERSION" || "$NOMAD_VERSION" == "null" ]]; then
  echo "ERROR: could not determine latest Nomad version from HashiCorp's checkpoint API." >&2
  exit 1
fi
echo "    Installing Nomad ${NOMAD_VERSION}"
curl -sSL -o /tmp/nomad.zip "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip"
unzip -o /tmp/nomad.zip -d /usr/local/bin
chmod +x /usr/local/bin/nomad
rm -f /tmp/nomad.zip
hash -r

cat > /lib/systemd/system/nomad.service << 'EOF'
[Unit]
Description=Nomad
Documentation=https://developer.hashicorp.com/nomad
Wants=network-online.target
After=network-online.target
StartLimitBurst=3
StartLimitIntervalSec=10

[Service]
ExecReload=/bin/kill -HUP $MAINPID
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
Restart=on-failure
RestartSec=2
TasksMax=infinity
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

echo "--> Configuring Nomad"
mkdir -p /etc/nomad.d /opt/nomad/data
cat > /etc/nomad.d/nomad.hcl << EOF
data_dir  = "/opt/nomad/data"
bind_addr = "0.0.0.0"

advertise {
  http = "${SERVER_IP}"
  rpc  = "${SERVER_IP}"
  serf = "${SERVER_IP}"
}

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
}

plugin "docker" {
  config {
    allow_privileged = true
    volumes {
      enabled = true
    }

    # Nomad's docker driver garbage collects images by default
    # (gc.image = true, image_delay = "3m"): once the last allocation
    # referencing an image is collected, it deletes the image itself.
    #
    # That is fatal to scale-to-zero. App images are built locally by
    # railpack and pushed to NO registry, and job specs reference them
    # with force_pull = false — so an image Nomad deletes is gone for
    # good. Stopping an idle app therefore destroyed the only copy of its
    # image three minutes later, and waking it failed with "pull access
    # denied ... repository does not exist", which reads like a registry
    # auth problem and is nothing of the sort. Diagnosed exactly that way
    # on 2026-09-18 against scale-to-zero-test-1.
    #
    # Turned off rather than given a longer image_delay: deploy-service
    # already owns image lifecycle end to end — pruneOldImages() keeps
    # IMAGE_RETAIN_COUNT versions per app after each deploy, and teardown
    # removes an app's images when it is deleted. Nomad's GC was a second,
    # uncoordinated policy on top of that, which is also why rollback to
    # an older imageTag could find its image missing.
    gc {
      image = false
    }
  }
}
EOF

systemctl enable nomad
systemctl restart nomad

# Memory oversubscription — a CLUSTER-WIDE scheduler setting, not part of
# nomad.hcl above and not something a job spec can turn on for itself.
#
# deploy-service's generated job specs declare both `memory` (the low
# number Nomad bin-packs against) and `memory_max` (the ceiling a task may
# burst to when the host has room) — see hostnsoft-deploy/nomad-job-spec.js
# and docs/Memory-oversubscription-req.md. With this setting OFF, Nomad
# still ACCEPTS those jobs but ignores memory_max entirely, which means
# every app silently gets its low floor (32/128MB) as a HARD cap and starts
# OOM-killing. It fails quiet, not loud — which is exactly why it belongs
# in this script rather than staying a one-off manual command someone ran
# on the live box once.
#
# `set-config` only overrides the flags actually passed, leaving the rest
# of the scheduler config alone, so this is safe to re-run on an existing
# server (this whole script is meant to be idempotent).
echo "--> Enabling Nomad memory oversubscription"
# Needs an elected leader, which isn't instant after the restart above.
nomad_ready=false
for _ in $(seq 1 30); do
  # get-config is the precondition for set-config below (it needs an
  # elected leader), so probing with it tests exactly the right thing.
  if nomad operator scheduler get-config >/dev/null 2>&1; then
    nomad_ready=true
    break
  fi
  sleep 2
done
if [[ "$nomad_ready" != true ]]; then
  echo "ERROR: Nomad did not become ready within 60s; cannot enable memory" >&2
  echo "       oversubscription. Fix Nomad, then re-run this script (or run" >&2
  echo "       'nomad operator scheduler set-config -memory-oversubscription=true'" >&2
  echo "       by hand). Deployed apps will OOM at their scheduling floor until" >&2
  echo "       this is set." >&2
  exit 1
fi
nomad operator scheduler set-config -memory-oversubscription=true

# ---------------------------------------------------------------------------
# 3. Docker
# ---------------------------------------------------------------------------
echo "--> Installing Docker"
if ! command -v docker >/dev/null 2>&1; then
  wait_for_apt_lock
  apt-get install -y docker.io
fi

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "features": {
    "containerd-snapshotter": false
  }
}
EOF

systemctl enable docker
systemctl restart docker

# Verify Docker actually came up — if daemon.json's containerd-snapshotter
# key is unrecognized by whatever docker.io version this OS shipped, this
# catches it here with a clear message, rather than the failure surfacing
# confusingly several steps later (e.g. BuildKit mysteriously not starting).
if ! systemctl is-active --quiet docker; then
  echo "ERROR: Docker failed to start after applying /etc/docker/daemon.json." >&2
  echo "If this is an old Docker version that doesn't recognize the" >&2
  echo "'features.containerd-snapshotter' key, try removing that file" >&2
  echo "entirely and re-running: rm /etc/docker/daemon.json && systemctl restart docker" >&2
  echo "Full error:" >&2
  journalctl -xeu docker --no-pager | tail -20 >&2
  exit 1
fi

usermod -aG docker "${APP_USER}" || true

# ---------------------------------------------------------------------------
# 3b. Redis — local instance for api-service (REDIS_URL in variables.sh).
#     Bound to 127.0.0.1 only: never exposed publicly, no ufw rule needed.
#     Idempotent — apt is a no-op if already installed; config is rewritten
#     in place and the service restarted on every run.
#
#     NOT pinned to a specific version — installed via apt, so the actual
#     Redis version depends entirely on this Ubuntu release's package
#     archive (e.g. 22.04 ships 6.0.x, 24.04 ships 7.0.x). Confirmed in
#     practice: api-service's connectorPendingLogin.ts originally used
#     GETDEL (added in Redis 6.2) and failed in prod with "ERR unknown
#     command `GETDEL`" against an older apt-installed Redis — fixed in
#     that repo by using MULTI GET+DEL instead, which works on any
#     version. Keep app code Redis-version-agnostic rather than assuming
#     whatever this apt package happens to install here.
# ---------------------------------------------------------------------------
echo "--> Installing Redis"
if ! command -v redis-server >/dev/null 2>&1; then
  wait_for_apt_lock
  apt-get install -y redis-server
fi
sed -i -E 's/^#? *bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
sed -i -E 's/^#? *protected-mode .*/protected-mode yes/' /etc/redis/redis.conf
sed -i -E 's/^#? *supervised .*/supervised systemd/' /etc/redis/redis.conf
systemctl enable redis-server
systemctl restart redis-server
# Command substitution, not `| grep -q`: under `set -o pipefail` a grep -q
# that matches early closes the pipe, the upstream command takes SIGPIPE
# and exits 141, and the pipeline reports that 141 as the result — so a
# successful match can read as a failure. Unlikely with output this small,
# but the same construct broke scale-to-zero-soak.sh for real on
# 2026-09-18, so it is not left in place anywhere.
if [[ "$(redis-cli ping 2>/dev/null)" != "PONG" ]]; then
  echo "ERROR: Redis did not respond to PING after restart." >&2
  journalctl -xeu redis-server --no-pager | tail -20 >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. BuildKit + Railpack
#
# Pinned to v0.30.0, NOT :latest — deliberate. BuildKit v0.31.0+ (through
# at least v0.32.2) bundles a runc with a masked-paths hardening regression
# (CVE-2025-31133 / 52881 / 52565): runc's maskDir() now mounts masked
# paths like /proc/acpi with a tmpfs option (nr_inodes=1) that several
# kernels — confirmed on Ubuntu 20.04's 5.4 kernel, also seen on various
# cloud/KVM guest kernels — reject with EINVAL, so EVERY build-step
# container fails at init with "can't mask dir ... invalid argument".
# v0.30.0 is the last release before this regression (runc 1.3.5,
# unaffected). Confirmed in practice, not theoretical — this exact
# failure has been hit. Bump this pin once BuildKit ships runc >= 1.4.4
# (the fixed version) — check https://github.com/moby/moby/issues/52972
# before assuming a newer tag is safe again.
# ---------------------------------------------------------------------------
echo "--> Starting BuildKit"
docker rm -f buildkit >/dev/null 2>&1 || true
# --restart unless-stopped: caught during a 2026-09-12 reboot-resilience
# review, before ever actually rebooting production — a bare `docker run
# -d` with no restart policy does NOT come back after a host reboot,
# unlike the Nomad-managed jobs and systemd-enabled services elsewhere in
# this script, which do. Without this, new builds/deploys would silently
# fail after any reboot until someone noticed and restarted this container
# by hand. "unless-stopped" (not "always") so an operator's own deliberate
# `docker stop buildkit` is still respected rather than immediately undone.
#
# -v buildkit-cache:/var/lib/buildkit: BuildKit's entire layer cache lives
# in that path INSIDE the container, so the `docker rm -f` above used to
# destroy it on every run of this script — making the next build of every
# app a cold, from-scratch one. Measured on 2026-09-18: app build times
# roughly doubled (to 4-5 minutes) immediately after a re-provision, with
# nothing else changed. A NAMED volume survives container removal, so the
# container stays disposable (which is what makes this script re-runnable)
# while the cache does not.
#
# Not a bind mount: the cache is BuildKit's private format, nothing else
# reads it, and a named volume needs no host path to exist or be chowned.
# BuildKit runs its own periodic GC inside the volume, so this grows to a
# bounded size rather than forever.
docker run --privileged -d --restart unless-stopped --name buildkit \
  -v buildkit-cache:/var/lib/buildkit \
  moby/buildkit:v0.30.0

# Verify it's actually running — if the pinned moby/buildkit image
# turns out to need Docker Engine features this OS's docker.io version
# doesn't have, this catches it here with a clear message, rather than the
# failure surfacing confusingly later as "railpack build" mysteriously
# can't connect to BuildKit during an actual app deploy.
sleep 2
# Command substitution rather than `| grep -q .` — same pipefail/SIGPIPE
# reasoning as the redis check above.
if [[ -z "$(docker ps --filter name=buildkit --filter status=running -q)" ]]; then
  echo "ERROR: BuildKit container failed to start or exited immediately." >&2
  echo "This may mean the installed Docker Engine version is too old for" >&2
  echo "the pinned moby/buildkit:v0.30.0 image. Check what's actually" >&2
  echo "installed:" >&2
  echo "  docker version" >&2
  echo "  docker logs buildkit" >&2
  exit 1
fi

echo "--> Installing Railpack (direct binary, not their install.sh)"
if ! command -v railpack >/dev/null 2>&1; then
  # railpack.com/install.sh is not usable on this OS for two separate
  # reasons, both confirmed in practice, not theoretical:
  #   1. It uses `curl --retry-all-errors` unconditionally in its actual
  #      download step (not just version detection) — a flag curl only
  #      gained in 7.71; Ubuntu 20.04 ships 7.68. Pre-supplying
  #      RAILPACK_VERSION only skips ONE use of this flag (their
  #      version-detection step) — the download step fails the same way
  #      regardless.
  #   2. The script uses bash-only `[[ ]]` syntax while `curl | sh`
  #      invokes `dash` on Ubuntu, which doesn't support it — separate
  #      failures ("sh: [[: not found") on top of the curl issue.
  # Bypassing their installer entirely and downloading the release
  # asset directly avoids both problems and has no OS-version
  # dependency at all — same approach as Nomad above, for the same
  # reason.
  RAILPACK_VERSION=$(curl -sS https://api.github.com/repos/railwayapp/railpack/releases/latest | jq -r '.tag_name' | sed 's/^v//')
  if [[ -z "$RAILPACK_VERSION" || "$RAILPACK_VERSION" == "null" ]]; then
    echo "    Could not determine latest Railpack version via GitHub API — falling back to a pinned known-good version."
    echo "    (This may not be the latest release — check https://github.com/railwayapp/railpack/releases if this matters.)"
    RAILPACK_VERSION="0.38.0"
  fi
  echo "    Installing Railpack ${RAILPACK_VERSION}"
  curl -sSL -o /tmp/railpack.tar.gz \
    "https://github.com/railwayapp/railpack/releases/download/v${RAILPACK_VERSION}/railpack-v${RAILPACK_VERSION}-x86_64-unknown-linux-musl.tar.gz"
  tar -xzf /tmp/railpack.tar.gz -C /usr/local/bin railpack
  chmod +x /usr/local/bin/railpack
  rm -f /tmp/railpack.tar.gz
  hash -r
fi

if ! grep -q BUILDKIT_HOST /etc/environment 2>/dev/null; then
  echo 'BUILDKIT_HOST=docker-container://buildkit' >> /etc/environment
fi

# ---------------------------------------------------------------------------
# 5. Traefik — config files + Nomad job
#    Two routers on ONE domain: bare path -> deploy-service, /api -> api-service.
#    Router/service names use the env-prefixed service names, so config
#    for multiple environments can coexist in the same dynamic.yml
#    without name collisions if ever merged onto one Traefik instance.
#    There is only ONE Traefik job regardless of environment — it's the
#    shared reverse proxy for this host, not per-environment itself.
# ---------------------------------------------------------------------------
echo "--> Configuring Traefik"
mkdir -p /opt/traefik
touch /opt/traefik/acme.json
chmod 600 /opt/traefik/acme.json

# JSON access log, mounted out to the host — read by every environment's
# hostnsoft-deploy (see its analytics/access-log-tailer.js) to build
# per-app traffic/error/latency analytics. There is only ONE Traefik
# instance regardless of environment (see the note above), so this one
# log is shared read-only input for every environment's own analytics
# ingestion, each tracking its own read position independently.
#
# world-readable+executable directory: Traefik's container writes this
# file as root, but deploy-service reads it as the non-root APP_USER.
# The file itself isn't chmod'd here (it doesn't exist until Traefik's
# first log write) — this relies on Traefik creating it with the
# ordinary 644 a root process gets under a standard umask, which is the
# common case but hasn't been independently confirmed against this
# exact Traefik image; if deploy-service logs permission-denied reading
# this path, chmod the file itself (or adjust Traefik's container
# umask) rather than loosening this directory further.
mkdir -p /opt/traefik/logs
chmod 755 /opt/traefik/logs

# Separate cert storage for the HTTP-01 resolver (client custom domains,
# see api-service's docs/Customdomain-req.md constraint #1) — kept apart
# from acme.json (the platform's own DNS-01 certs) deliberately, so an
# issue with one resolver's storage can't affect the other's.
touch /opt/traefik/acme-http.json
chmod 600 /opt/traefik/acme-http.json

# Router priorities, and why they're this large.
#
# Traefik gives a router with no explicit priority a priority equal to its
# rule's LENGTH. Every customer app's router (hostnsoft-deploy's
# nomad-job-spec.js) is generated without one, so each sits somewhere
# around 25-40. The two platform routers below used to be 100 and 1 —
# numbers chosen only to order them against each OTHER, which left the
# deploy service at priority 1: below every app router on the host.
#
# That only stayed safe because an app's hostname is always
# <slug>.app.<domain> and can never equal ${DEPLOY_HOST}. The moment apps
# are served at <slug>.<domain>, an app named after the deploy host would
# emit Host(`${DEPLOY_HOST}`) at ~25 and outrank the real deploy service —
# taking over the endpoint agents POST source and deploy tokens to.
# Traefik matches on the Host header, so DNS doesn't protect this.
#
# These are set far above any rule-length-derived value so the platform's
# own hostnames cannot be captured by a router from the Nomad provider,
# whatever it's called. This is the floor; the reserved-name list is the
# other, independent guard. The gap between the two preserves the original
# intent: /api must still beat the bare host.
cat > /opt/traefik/dynamic.yml << EOF
http:
  routers:
    ${API_SERVICE_NAME}:
      rule: "Host(\`${DEPLOY_HOST}\`) && PathPrefix(\`/api\`)"
      entryPoints:
        - websecure
      service: ${API_SERVICE_NAME}
      priority: 10100
      middlewares:
        - ${PREFIX}strip-api-prefix
      tls:
        certResolver: cloudflare

    ${DEPLOY_SERVICE_NAME}:
      rule: "Host(\`${DEPLOY_HOST}\`)"
      entryPoints:
        - websecure
      service: ${DEPLOY_SERVICE_NAME}
      priority: 10000
      tls:
        certResolver: cloudflare

    # --- scale-to-zero wake-on-request (plan Step 4) ---------------------
    #
    # A STOPPED app has no Traefik router at all: app routers come from
    # the Nomad provider, which only sees RUNNING services. Its hostname
    # would simply 404. This fallback router catches that hostname and
    # hands it to deploy-service/activator.js, which starts the job, waits
    # for it, and forwards the original request.
    #
    # priority: 1 is the whole mechanism. App routers set no explicit
    # priority, so Traefik derives theirs from the rule's length (~44 for
    # a Host rule) — any running app therefore outranks this by a wide
    # margin and its traffic never touches the activator. The instant the
    # job stops and its router disappears, this becomes the only match.
    #
    # ONE router per app, by exact hostname, never a wildcard: that is
    # what makes "no other app's traffic can reach the activator" a fact
    # about this file rather than a hope about its code. The app names
    # here MUST match WAKEABLE_APPS in activator.js — an app routed here
    # but not in that list gets a 404 instead of a wake, and an app in
    # that list with no router here is never woken because nothing ever
    # reaches the activator. Step 6/7 is where this stops being hand-
    # maintained.
    ${PREFIX}wake-scale-to-zero-test-1:
      rule: "Host(\`scale-to-zero-test-1.${APPS_DOMAIN_SUFFIX}\`)"
      entryPoints:
        - websecure
      service: ${PREFIX}scale-to-zero-activator
      priority: 1
      tls:
        certResolver: cloudflare

  middlewares:
    ${PREFIX}strip-api-prefix:
      stripPrefix:
        prefixes:
          - "/api"

  services:
    ${PREFIX}scale-to-zero-activator:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${ACTIVATOR_PORT}"

    ${DEPLOY_SERVICE_NAME}:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${DEPLOY_PORT}"

    ${API_SERVICE_NAME}:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:${API_PORT}"
EOF

cat > "${APP_HOME}/traefik.nomad" << EOF
job "traefik" {
  datacenters = ["dc1"]
  type        = "system"

  group "proxy" {
    network {
      port "http"  { static = 80 }
      port "https" { static = 443 }
    }

    task "traefik" {
      driver = "docker"

      config {
        image        = "traefik:v3.2"
        network_mode = "host"

        volumes = [
          "/opt/traefik/acme.json:/acme.json",
          "/opt/traefik/acme-http.json:/acme-http.json",
          "/opt/traefik/dynamic.yml:/etc/traefik/dynamic.yml",
          "/opt/traefik/logs:/var/log/traefik"
        ]

        args = [
          "--accesslog=true",
          # JSON (not the default CLF text) and to a file (not stdout) —
          # every environment's hostnsoft-deploy reads this file directly
          # off disk (see TRAEFIK_ACCESS_LOG_PATH); Nomad's own captured
          # stdout log isn't something another process can tail.
          "--accesslog.format=json",
          "--accesslog.filepath=/var/log/traefik/access.log",
          # Keep ONE request header in the access log: User-Agent, which
          # deploy-service's analytics/bot-filter.js uses to tell a real
          # visit from a credential scanner. Without it every scan counts
          # as traffic, and under scale-to-zero an app would be woken to
          # serve a bot probing for its .env. Named explicitly rather
          # than keeping all headers — the rest are not needed and some
          # (Cookie, Authorization) must never be written to disk.
          "--accesslog.fields.headers.defaultmode=drop",
          "--accesslog.fields.headers.names.User-Agent=keep",
          "--entrypoints.web.address=:80",
          "--entrypoints.websecure.address=:443",
          "--entrypoints.web.http.redirections.entryPoint.to=websecure",
          "--entrypoints.web.http.redirections.entryPoint.scheme=https",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://127.0.0.1:4646",
          "--providers.nomad.exposedByDefault=false",
          # Default is 15s. That interval is a BLACKOUT WINDOW for
          # scale-to-zero: between an app being stopped and Traefik
          # noticing, Traefik still holds that app's own router pointing
          # at a dead allocation, so requests get a fast 502 instead of
          # falling through to the priority-1 activator router that would
          # have woken it. Measured on 2026-09-18 — 10 requests sent
          # seconds after a stop all failed without the activator ever
          # being invoked.
          #
          # 5s shortens the window rather than closing it; nothing here
          # can make Traefik's view of a stopped job instantaneous. The
          # poll is against Nomad's local API and is cheap.
          "--providers.nomad.refreshInterval=5s",
          "--providers.file.filename=/etc/traefik/dynamic.yml",
          "--certificatesresolvers.cloudflare.acme.dnschallenge=true",
          "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare",
          "--certificatesresolvers.cloudflare.acme.email=${ACME_EMAIL}",
          "--certificatesresolvers.cloudflare.acme.storage=/acme.json",
          # HTTP-01 resolver for CLIENT custom domains (see api-service's
          # docs/Customdomain-req.md constraint #1) — DNS-01 above only
          # works for domains in this platform's own Cloudflare zone;
          # HTTP-01 works for any domain pointed at this server regardless
          # of who controls its DNS. Traefik natively excludes its own
          # ACME challenge path from the web->websecure redirect above, so
          # the two coexist on the same :80 entrypoint without conflict —
          # confirmed against a real externally-pointed test domain before
          # relying on this in prod; don't just take this comment's word
          # for it.
          "--certificatesresolvers.letsencrypt-http.acme.httpchallenge=true",
          "--certificatesresolvers.letsencrypt-http.acme.httpchallenge.entrypoint=web",
          "--certificatesresolvers.letsencrypt-http.acme.email=${ACME_EMAIL}",
          "--certificatesresolvers.letsencrypt-http.acme.storage=/acme-http.json"
        ]
      }

      env {
        CF_DNS_API_TOKEN = "${CF_DNS_API_TOKEN}"
      }
    }
  }
}
EOF

# ---------------------------------------------------------------------------
# 6. deploy-service and api-service — clean pull from git, branch = APP_ENV
#
# "Clean pull" means: if the code directory already exists (a prior
# deploy), discard ANY local drift and reset it to exactly match the
# remote branch — never merge, never leave stale files around. If it
# doesn't exist yet, clone fresh. Either way, the directory ends up
# byte-for-byte what's on the remote branch named "${APP_ENV}".
#
# This script does NOT know or assume anything about what's inside
# either repo beyond: it has a package.json with a "start" script.
# Application-level concerns (database setup, initial token/company
# creation, etc.) are the repo's own responsibility now — consult each
# repo's own README for that, not this script.
# ---------------------------------------------------------------------------

clean_pull() {
  local repo_url="$1"
  local target_dir="$2"
  local branch="$3"

  if [[ -d "${target_dir}/.git" ]]; then
    echo "    ${target_dir} already exists — resetting to origin/${branch} (discarding any local changes)"
    sudo -u "${APP_USER}" bash -c "
      cd '${target_dir}' &&
      git fetch origin '${branch}' &&
      git reset --hard 'origin/${branch}' &&
      git clean -fd
    "
  else
    echo "    Cloning ${repo_url} (branch: ${branch}) -> ${target_dir}"
    sudo -u "${APP_USER}" git clone --branch "${branch}" --single-branch "${repo_url}" "${target_dir}"
  fi
}

# .env generation lives in env-hydrate-lib.sh, shared with redeploy.sh
# so the two can never drift. Sourced by path relative to THIS script, not
# the caller's cwd: this is normally run as `sudo -E bash server-setup.sh`
# from inside the Server-setup directory, but nothing guarantees that.
_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "${_SETUP_DIR}/env-hydrate-lib.sh" ]]; then
  echo "ERROR: ${_SETUP_DIR}/env-hydrate-lib.sh is missing — copy the whole" >&2
  echo "       Server-setup directory to this box, not just server-setup.sh." >&2
  exit 1
fi
# shellcheck source=env-hydrate-lib.sh
source "${_SETUP_DIR}/env-hydrate-lib.sh"

echo "--> Pulling ${DEPLOY_SERVICE_NAME} from ${DEPLOY_SERVICE_REPO} (branch: ${APP_ENV})"
mkdir -p "${APP_HOME}"
chown "${APP_USER}:${APP_USER}" "${APP_HOME}"
clean_pull "${DEPLOY_SERVICE_REPO}" "${APP_HOME}/${DEPLOY_SERVICE_NAME}" "${APP_ENV}"

echo "--> Pulling ${API_SERVICE_NAME} from ${API_SERVICE_REPO} (branch: ${APP_ENV})"
clean_pull "${API_SERVICE_REPO}" "${APP_HOME}/${API_SERVICE_NAME}" "${APP_ENV}"

# Sidecar used only for orphan (anonymous, unclaimed) deploys — see
# hostnsoft-deploy's docs/Anonymous-deploy-req.md #5 and
# nomad-job-spec.js. Built ONCE here, not per-deploy: nomad-job-spec.js
# references it by this fixed tag with force_pull=false, same convention
# as every per-app image built locally by railpack. Idempotent — rebuilds
# in place on every re-run of this script, picking up any code changes.
if [[ -d "${APP_HOME}/${DEPLOY_SERVICE_NAME}/orphan-proxy" ]]; then
  echo "--> Building orphan-banner-proxy sidecar image"
  docker build -t orphan-banner-proxy:local "${APP_HOME}/${DEPLOY_SERVICE_NAME}/orphan-proxy"
fi

echo "--> Generating .env files from each repo's .env.example"
# Exported here (not just passed to pm2 later) so hydrate_env_file's
# indirect lookup (${!key}) picks them up and bakes them into each
# service's actual .env — both services load their .env via dotenv, so
# this is what they see at runtime, not whatever's on pm2's command line.
#
# PORT is exported separately per service, right before that service's
# own hydrate_env_file call — deploy-service and api-service each need a
# DIFFERENT port (DEPLOY_PORT vs API_PORT), so a single shared export
# would leak the wrong value into whichever one hydrates second.
export HOSTNSOFT_API_URL="http://127.0.0.1:${API_PORT}"
export APPS_DOMAIN_SUFFIX  # value already computed in section 0 above


# Custom domains (api-service's docs/Customdomain-req.md) — both computed
# automatically rather than requiring manual values in variables.sh:
# EDGE_HOSTNAME follows the same env-segmented naming as every other
# computed hostname here, and ORIGIN_SERVER_IP is exactly the same IP
# this script already auto-detected for its own Traefik/DNS-instructions
# use above — no reason to make an operator re-supply it by hand.
export EDGE_HOSTNAME
export ORIGIN_SERVER_IP="${SERVER_IP}"

# The platform's own zone — api-service refuses to register any custom
# domain that is, or sits under, it. Such a name resolves to this origin,
# so it would pass DNS verification on the IP-match fallback and then take
# a Traefik router for a platform hostname.
#
# $DOMAIN is the bare registrable domain, which is exactly the right value,
# and this deliberately keeps any explicit setting from variables.sh: it is
# a security control, so an operator stating it outright should win over
# anything computed here.
export PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-$DOMAIN}"

# Anonymous deploys' orphan-proxy sidecar (deploy-service's
# docs/Anonymous-deploy-req.md #5) — same underlying value as
# ORIGIN_SERVER_IP above (this box's own address), under the name
# deploy-service's own .env.example actually expects. Confirmed in
# practice: Docker publishes this box's app container ports bound to
# this exact address, not 0.0.0.0/127.0.0.1 — the sidecar needs to know
# it to reach the app task it fronts at all.
export ORIGIN_IP="${SERVER_IP}"

# Analytics (deploy-service's analytics/*.js) — TRAEFIK_ACCESS_LOG_PATH
# is the same value across every environment (one shared Traefik
# instance, see section 5 above); ANALYTICS_DB_PATH is per-environment
# so prod/test/demo never write into the same SQLite file. Created here
# (not left for the app to create) so it exists with the right owner
# before deploy-service ever starts.
export TRAEFIK_ACCESS_LOG_PATH="/opt/traefik/logs/access.log"
ANALYTICS_DIR="/opt/hostnsoft-analytics/${APP_ENV}"
mkdir -p "${ANALYTICS_DIR}"
chown "${APP_USER}:${APP_USER}" "${ANALYTICS_DIR}"
export ANALYTICS_DB_PATH="${ANALYTICS_DIR}/analytics.db"

# Per-app persistent storage (deploy-service's nomad-job-spec.js) — each
# app's DATA_DIR is a subdirectory here, bind-mounted into its container
# at /data.
#
# This exists so an app's data is NOT owned by its Nomad allocation.
# DATA_DIR used to be /alloc/data, which Nomad garbage-collects along
# with a stopped job (job_gc_threshold, 4h by default) — fine while every
# app ran forever, fatal the moment anything stops one. A SQLite database
# would come back empty, and silently, since an app that finds no
# database usually just creates a fresh one and looks healthy. This is
# the prerequisite for scale-to-zero.
#
# Per-environment, like ANALYTICS_DIR above, so prod/test/demo can never
# collide on an app name. Created here rather than left to the app so it
# exists with the right owner before deploy-service ever starts. NOT
# under any git-managed checkout: clean_pull does `git reset --hard &&
# git clean -fd` on every re-run, which would erase every app's database.
#
# deploy-service chmods each app's own subdirectory to 0777 as it creates
# it — Railpack images do not all run as root, and a container that
# cannot write its own data directory fails at runtime rather than at
# deploy time.
export APP_DATA_ROOT="/opt/embarko-appdata/${APP_ENV}"
mkdir -p "${APP_DATA_ROOT}"
chown "${APP_USER}:${APP_USER}" "${APP_DATA_ROOT}"

export PORT="${DEPLOY_PORT}"
hydrate_env_file "${APP_HOME}/${DEPLOY_SERVICE_NAME}"

export PORT="${API_PORT}"
hydrate_env_file "${APP_HOME}/${API_SERVICE_NAME}"

# PORT was exported per service immediately before each hydrate above, so
# the LAST value (api-service's) is still in scope here. That matters: the
# pm2 ecosystem file deliberately does not set PORT, leaving each service
# to read its own .env — but dotenv does NOT override a variable already
# present in the environment, and `pm2 start` below inherits this shell.
# Left set, deploy-service would come up on api-service's port: Traefik
# then finds nothing on 4000 (502 on the deploy host), routes /api to the
# wrong process, and api-service crash-loops unable to bind. That is
# exactly the outage of 2026-09-17, reproduced by provisioning alone.
#
# Unset, so each service's own .env is authoritative.
unset PORT

chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}/${DEPLOY_SERVICE_NAME}" "${APP_HOME}/${API_SERVICE_NAME}" "${APP_HOME}/traefik.nomad"

echo "--> Installing Node.js (direct binary, current LTS — not NodeSource, not pinned to a specific version number)"
if ! command -v node >/dev/null 2>&1; then
  # Not using NodeSource's setup script: separately from any OS-compatibility
  # question, the previously-hardcoded Node 20.x pin is now past its support
  # window — better to always install whatever is currently the real LTS
  # than to trust a hardcoded major version number that goes stale over
  # time. Node's own dist index is the authoritative source for this.
  NODE_VERSION=$(curl -sS https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')
  if [[ -z "$NODE_VERSION" || "$NODE_VERSION" == "null" ]]; then
    echo "ERROR: could not determine current Node.js LTS version from nodejs.org." >&2
    exit 1
  fi
  echo "    Installing Node.js ${NODE_VERSION} (current LTS)"
  curl -sSL -o /tmp/node.tar.xz "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz"
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm -f /tmp/node.tar.xz
  hash -r
fi
if ! command -v pm2 >/dev/null 2>&1; then
  # Explicitly HOME=/root here: this script runs under `sudo -E`, which
  # preserves the invoking user's $HOME (typically /home/ubuntu) even
  # though this command executes as root. Without this override, npm
  # would create its cache at $HOME/.npm — i.e. inside APP_USER's home
  # directory — but owned by root, since the process itself is root.
  # That then breaks the APP_USER-context `npm install` calls just below,
  # which hit those root-owned cache files and fail with EACCES. Confirmed
  # in practice, not theoretical — this exact failure has been hit.
  HOME=/root npm install -g pm2
fi

# npm ci (not npm install): guarantees a fully clean node_modules on
# every run (it removes any existing one internally) while installing
# the EXACT versions pinned in package-lock.json — unlike `rm -rf
# node_modules package-lock.json && npm install`, which would discard
# those pinned versions and let npm resolve potentially newer,
# untested ones instead. Falls back to `npm install` only if a repo
# genuinely has no committed lockfile (npm ci requires one).
for svc_dir in "${APP_HOME}/${DEPLOY_SERVICE_NAME}" "${APP_HOME}/${API_SERVICE_NAME}"; do
  if sudo -u "${APP_USER}" bash -c "test -f '${svc_dir}/package-lock.json'"; then
    sudo -u "${APP_USER}" bash -c "cd '${svc_dir}' && npm ci"
  else
    echo "    ${svc_dir} has no package-lock.json — falling back to npm install"
    sudo -u "${APP_USER}" bash -c "cd '${svc_dir}' && rm -rf node_modules && npm install"
  fi
done

# Run each repo's own build step, but only if it actually defines one —
# don't assume every service is TypeScript/needs compiling. Confirmed
# necessary in practice: a repo whose "start" script runs `node
# dist/server.js` fails with MODULE_NOT_FOUND if this step is skipped,
# since `dist/` only exists after a build.
for svc_dir in "${APP_HOME}/${DEPLOY_SERVICE_NAME}" "${APP_HOME}/${API_SERVICE_NAME}"; do
  HAS_BUILD_SCRIPT=$(sudo -u "${APP_USER}" bash -c "cd '${svc_dir}' && node -e \"process.exit(require('./package.json').scripts?.build ? 0 : 1)\"" && echo "yes" || echo "no")
  if [[ "$HAS_BUILD_SCRIPT" == "yes" ]]; then
    echo "    ${svc_dir} has a build script — running it"
    sudo -u "${APP_USER}" bash -c "cd '${svc_dir}' && npm run build"
  fi
done

# Apply pending Prisma migrations, for whichever service(s) actually use
# Prisma — detected generically (a prisma/schema.prisma file), same "no
# built-in knowledge of either repo's internals" philosophy as the build-
# script check above, rather than hardcoding this to api-service by name.
# `migrate deploy` (not `migrate dev`) is the correct command outside a
# dev environment: it only applies already-committed migrations and never
# prompts or generates new ones. Must run BEFORE pm2 starts anything
# below — a service with a schema newer than its actual database (a
# missing table/column from a migration that was never applied here)
# will fail confusingly at the first request that touches it rather than
# at a clear startup step. DATABASE_URL is already in this service's own
# .env from hydrate_env_file above, which Prisma's CLI reads the same way
# the app itself does.
for svc_dir in "${APP_HOME}/${DEPLOY_SERVICE_NAME}" "${APP_HOME}/${API_SERVICE_NAME}"; do
  HAS_PRISMA_SCHEMA=$(sudo -u "${APP_USER}" bash -c "test -f '${svc_dir}/prisma/schema.prisma'" && echo "yes" || echo "no")
  if [[ "$HAS_PRISMA_SCHEMA" == "yes" ]]; then
    echo "    ${svc_dir} has a Prisma schema — applying pending migrations"
    sudo -u "${APP_USER}" bash -c "cd '${svc_dir}' && npx prisma migrate deploy"
  fi
done


# ---------------------------------------------------------------------------
# 7. Firewall — 22 (SSH), 80, and 443 are public. Neither service's own
#    port is opened: both bind 127.0.0.1 only, reachable exclusively
#    through Traefik on 443.
#
#    SSH MUST be allowed before `ufw --force enable` runs, not after —
#    confirmed the hard way: an earlier version of this script enabled
#    ufw without ever explicitly allowing port 22, which immediately cut
#    off all NEW inbound SSH connections (already-established sessions
#    can survive, which is why the script itself kept running — but
#    reconnecting afterward was impossible without out-of-band console
#    access). Do not reorder these three lines.
# ---------------------------------------------------------------------------
echo "--> Configuring firewall (OS-level, via ufw)"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo ""
echo "!! IMPORTANT if running on an OpenStack-based cloud (e.g. NeevCloud):"
echo "!! ufw only controls the OS-level firewall INSIDE this VM. Your cloud"
echo "!! provider's Security Group (a separate, network-level firewall) must"
echo "!! ALSO explicitly allow inbound (ingress) AND outbound (egress) on"
echo "!! ports 80 and 443, or none of this will be reachable regardless of"
echo "!! what ufw says. Check this in your provider's console now if unsure."
echo ""

# ---------------------------------------------------------------------------
# 8. Deploy Traefik via Nomad
# ---------------------------------------------------------------------------
echo "--> Deploying Traefik"
sudo -u "${APP_USER}" bash -c "nomad job run ${APP_HOME}/traefik.nomad"

# ---------------------------------------------------------------------------
# 9. Start both services under pm2, persist across reboots
#
# A pm2 ecosystem file (not ad-hoc `pm2 start npm --name ...` CLI calls)
# is written to ${APP_HOME}/ecosystem.config.js — a discoverable, re-runnable
# definition of both processes. Per-environment secrets/URLs (INTERNAL_API_SECRET,
# PORT, HOSTNSOFT_API_URL) are NOT duplicated here — they're already baked
# into each service's own .env by hydrate_env_file above, which each
# service loads itself via dotenv. Only BUILDKIT_HOST goes in `env` below,
# since it isn't an app secret, just something deploy-service's child
# `railpack`/buildkit invocations expect to inherit.
#
# Once this has run once, ${PM2_DEPLOY_NAME}/${PM2_API_NAME} are registered
# with pm2 by name — `pm2 restart <name>` or `pm2 start <name>` (after a
# stop) work with no arguments from then on; re-running this whole
# ecosystem file also works (`pm2 start ecosystem.config.js`).
# ---------------------------------------------------------------------------
echo "--> Writing pm2 ecosystem file and starting ${PM2_DEPLOY_NAME} + ${PM2_API_NAME}"
echo "    (using 'npm start' — each repo's package.json must define a"
echo "    'start' script; this script no longer assumes a specific entry"
echo "    filename, since the code comes from your own repos now)"
cat > "${APP_HOME}/ecosystem.config.js" << EOF
module.exports = {
  apps: [
    {
      name: '${PM2_API_NAME}',
      cwd: '${APP_HOME}/${API_SERVICE_NAME}',
      script: 'npm',
      args: 'start',
    },
    {
      name: '${PM2_DEPLOY_NAME}',
      cwd: '${APP_HOME}/${DEPLOY_SERVICE_NAME}',
      script: 'npm',
      args: 'start',
      env: {
        BUILDKIT_HOST: 'docker-container://buildkit',
      },
    },
    {
      // scale-to-zero activator — see deploy-service/activator.js and
      // docs/scale-to-zero-gated-plan.md Step 4. Runs from the
      // deploy-service checkout (it reuses that service's .env and its
      // nomad-job-spec helpers) but as its OWN process: it sits in the
      // path of real visitor traffic and holds connections open for the
      // length of a cold start, which must never be able to take
      // deploy-service's API down with it.
      //
      // script, not 'npm start': that would run deploy-service itself.
      name: '${PM2_ACTIVATOR_NAME}',
      cwd: '${APP_HOME}/${DEPLOY_SERVICE_NAME}',
      script: 'activator.js',
      env: {
        ACTIVATOR_PORT: '${ACTIVATOR_PORT}',
      },
    },
  ],
};
EOF
chown "${APP_USER}:${APP_USER}" "${APP_HOME}/ecosystem.config.js"

sudo -u "${APP_USER}" bash -c "
  cd ${APP_HOME}
  pm2 start ecosystem.config.js
  pm2 save
"
env PATH=$PATH:/usr/bin pm2 startup systemd -u "${APP_USER}" --hp "${APP_HOME}" || true

# ---------------------------------------------------------------------------
# 9b. Scale-to-zero idle watcher — a systemd timer, not cron.
#
# Step 5 of docs/scale-to-zero-gated-plan.md: idle detection has to run on
# a schedule rather than by hand. A timer rather than cron for two reasons
# that matter here — the run's output lands in the journal where it can
# actually be read afterwards, and Persistent=true means a run missed
# while the box was down happens at boot instead of being silently
# skipped.
#
# Runs as APP_USER, never root. idle-report.js opens the analytics
# database read-write (it sets WAL mode), so a root run would leave
# root-owned -wal/-shm files beside a ubuntu-owned database and break the
# running service's ability to write to it.
#
# SAFETY: this timer can only ever stop an app named in STOPPABLE_APPS, a
# frozen list hardcoded in idle-report.js. Putting it on a schedule does
# NOT widen what it may touch — every other idle app is reported and left
# running, which is exactly what makes scheduling it safe at this stage.
#
# IDLE_THRESHOLD_MIN comes from <env>.variables.sh. That value is the
# PRODUCTION threshold; the Step 5 soak overrides it with something much
# shorter, via scale-to-zero-soak.sh, to force many cycles per day.
# ---------------------------------------------------------------------------
IDLE_WATCHER_UNIT="embarko-idle-${APP_ENV}"
echo "--> Installing scale-to-zero idle watcher timer '${IDLE_WATCHER_UNIT}' (threshold: ${IDLE_THRESHOLD_MIN} min)"

write_idle_watcher_units() {
  cat > "/etc/systemd/system/${IDLE_WATCHER_UNIT}.service" << EOF
[Unit]
Description=Embarko scale-to-zero idle watcher (${APP_ENV})
After=network.target

[Service]
Type=oneshot
User=${APP_USER}
WorkingDirectory=${APP_HOME}/${DEPLOY_SERVICE_NAME}
Environment=IDLE_THRESHOLD_MIN=${IDLE_THRESHOLD_MIN}
ExecStart=/usr/local/bin/node ${APP_HOME}/${DEPLOY_SERVICE_NAME}/idle-report.js --apply
EOF

  cat > "/etc/systemd/system/${IDLE_WATCHER_UNIT}.timer" << EOF
[Unit]
Description=Run the Embarko scale-to-zero idle watcher every 10 minutes (${APP_ENV})

[Timer]
# OnActiveSec (relative to when the TIMER starts), not OnBootSec (relative
# to BOOT): on a box that booted days ago an OnBootSec deadline is already
# in the past and yields no future trigger, leaving the timer dependent on
# OnUnitActiveSec having a previous run to chain from — which a freshly
# installed unit does not have. The result is a timer with no next elapse
# that silently never fires. The soak timer hit exactly this on
# 2026-09-18; this one happened to escape it only because its service had
# already run under the same unit.
OnActiveSec=2min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
}

write_idle_watcher_units
systemctl daemon-reload
systemctl enable --now "${IDLE_WATCHER_UNIT}.timer"

# ---------------------------------------------------------------------------
# 10. DNS — done manually, not by this script. See README.md for the
#     exact record types/values. Printed here too as a convenience.
# ---------------------------------------------------------------------------
echo "--> DNS is set up manually — see README.md. Records needed for this environment:"
echo "    A   ${DEPLOY_HOST}   -> ${SERVER_IP}"
echo "    A   *.${APPS_DOMAIN_SUFFIX}   -> ${SERVER_IP}"
echo "    A   ${EDGE_HOSTNAME}   -> ${SERVER_IP}   (custom-domain CNAME target — keep this one UNPROXIED if using a CDN in front of DNS)"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Setup complete — environment: ${APP_ENV}"
echo ""
echo " deploy-service:  directory ${DEPLOY_SERVICE_NAME}, pm2 process '${PM2_DEPLOY_NAME}'  (https://${DEPLOY_HOST}/apps)"
echo " api-service:     directory ${API_SERVICE_NAME}, pm2 process '${PM2_API_NAME}'  (https://${DEPLOY_HOST}/api)"
echo " Apps live at:    https://<app-name>.${APPS_DOMAIN_SUFFIX}"
echo " Custom-domain CNAME target: ${EDGE_HOSTNAME}"
echo ""
echo " pm2 ecosystem file: ${APP_HOME}/ecosystem.config.js"
echo " From now on: pm2 restart ${PM2_API_NAME}   /   pm2 restart ${PM2_DEPLOY_NAME}"
echo " (or, from a clean slate: cd ${APP_HOME} && pm2 start ecosystem.config.js)"
echo ""
echo " INTERNAL_API_SECRET (deploy-service <-> api-service, never customer-facing): ${INTERNAL_API_SECRET}"
echo ""
echo " Save this now — it will not be shown again by this script."
echo ""
echo " Deploy token / initial data setup: this script no longer generates"
echo " a placeholder token store — that's now whatever api-service's own"
echo " code actually implements. Consult that repo's own README/docs for"
echo " how to create an initial company and deploy token before testing"
echo " an actual deploy through deploy-service."
echo ""
echo " Both services were pulled from their configured git repos, branch"
echo " '${APP_ENV}':"
echo "   deploy-service: ${DEPLOY_SERVICE_REPO}"
echo "   api-service:    ${API_SERVICE_REPO}"
echo ""
echo " DNS was NOT created automatically — see README.md and the records"
echo " printed above. Wait for propagation before testing. First TLS cert"
echo " issuance may take a minute or two once DNS is live."
echo ""
echo " If this is an OpenStack-based cloud (NeevCloud, etc.): double check"
echo " your provider's Security Group allows ports 80/443 in BOTH ingress"
echo " and egress directions — ufw alone is not sufficient there."
echo "=================================================================="