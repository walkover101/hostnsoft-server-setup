#!/usr/bin/env bash
#
# server-setup.sh — provision a server: Nomad, Docker (+BuildKit), Railpack,
# Redis, Traefik (Cloudflare DNS-01 TLS), and deploy-service + api-service
# under pm2, applying pending Prisma migrations first. Target: a fresh
# Ubuntu 24.04 server. Re-running is safe and expected.
#
#   source prod.set-env.sh && source prod.variables.sh
#   sudo -E bash server-setup.sh
#
# Takes no flags: every value comes from the environment, which is what the
# -E preserves. Required: APP_ENV DOMAIN CF_DNS_API_TOKEN ACME_EMAIL
# DEPLOY_SERVICE_REPO API_SERVICE_REPO. Optional ones and their defaults are
# in the doc below. DNS is manual — see README.md.
#
# >>> WHY any of this is the way it is — incidents, version pins, ordering
# >>> constraints — is in server-setup.md. Read that before changing a step:
# >>> most of what looks arbitrary here cost an outage to learn.
#
#   Usage, all variables ....... server-setup.md#overview
#   Env-aware naming ........... server-setup.md#naming
#   Architecture ............... server-setup.md#architecture

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
  # Export DOMAIN_ENV_SEGMENT="" to serve a non-prod env off the bare
  # domain. "-" not ":-" so an explicitly-empty override is honoured.
  # server-setup.md#naming
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

# Minutes without a real (non-bot) request before the idle watcher may stop
# an app. 6h is a conservative starting point for Step 6, not a tuned value,
# and should be revisited with real data. server-setup.md#idle-threshold
IDLE_THRESHOLD_MIN="${IDLE_THRESHOLD_MIN:-360}"

# Megabytes of BuildKit layer cache to keep. The daily GC prunes down to
# this. Reached 33.56GB unbounded on a 124GB disk. server-setup.md#buildkit-cache
BUILDKIT_CACHE_KEEP_MB="${BUILDKIT_CACHE_KEEP_MB:-10000}"

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
# Bounded retry: unattended-upgrades holds the dpkg lock on its own
# schedule. Has actually happened here. server-setup.md#apt-lock
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
# 2. Nomad — direct binary download, NOT apt. HashiCorp's apt repo lacks
#    packages for some Ubuntu codenames and silently falls back to an
#    ancient universe build. server-setup.md#direct-binaries
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

    # gc.image=false. Nomad's default (true, 3m) deletes an app's image
    # once its allocations are collected — fatal for scale-to-zero, since
    # images are local-only and force_pull=false. deploy-service owns image
    # lifecycle instead. server-setup.md#nomad-image-gc
    gc {
      image = false
    }
  }
}
EOF

systemctl enable nomad
systemctl restart nomad

# Memory oversubscription: a CLUSTER-WIDE scheduler setting, not in
# nomad.hcl and not settable by a job spec. With it off Nomad accepts job
# specs but IGNORES memory_max, so every app gets its low floor as a hard
# cap and OOM-kills — silently. Safe to re-run.
# server-setup.md#oversubscription
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
# 3b. Redis — local, 127.0.0.1 only (so no ufw rule), installed via apt so
#     the VERSION depends on the Ubuntu release. Keep app code
#     version-agnostic; GETDEL once broke prod. server-setup.md#redis
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
# Pinned to v0.30.0, NOT :latest — v0.31.0+ bundles a runc whose masked-path
# handling fails on this kernel, breaking every build. Check the linked
# issue before bumping. server-setup.md#buildkit
# ---------------------------------------------------------------------------
echo "--> Starting BuildKit"
docker rm -f buildkit >/dev/null 2>&1 || true
# --restart unless-stopped: a bare `docker run -d` does not survive a host
# reboot, unlike everything else here. -v buildkit-cache: the layer cache
# lives inside the container, so the `docker rm -f` above used to wipe it
# on every run and double build times. server-setup.md#buildkit
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
  # Their install.sh is unusable here: it needs curl >= 7.71 and uses
  # bash-only syntax under dash. Download the asset directly, same as Nomad
  # above. server-setup.md#direct-binaries
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
# 5. Traefik — config files + Nomad job. Two routers on one domain: bare
#    path -> deploy-service, /api -> api-service. ONE Traefik job for the
#    host regardless of environment. server-setup.md#traefik
# ---------------------------------------------------------------------------
echo "--> Configuring Traefik"
mkdir -p /opt/traefik
touch /opt/traefik/acme.json
chmod 600 /opt/traefik/acme.json

# JSON access log written to a file and mounted out: every environment's
# deploy-service tails it off disk for per-app analytics. The directory is
# world-readable because Traefik writes as root while deploy-service reads
# as APP_USER. server-setup.md#access-log
mkdir -p /opt/traefik/logs
# Traefik watches this DIRECTORY, not a single file: server-setup.sh owns
# platform.yml in it, deploy-service owns scale-to-zero.yml, and neither can
# overwrite the other. Owned by APP_USER because deploy-service writes here
# as that user. server-setup.md#s2z-routers
mkdir -p /opt/traefik/dynamic
chown "${APP_USER}:${APP_USER}" /opt/traefik/dynamic
chmod 755 /opt/traefik/logs

# Separate cert storage for the HTTP-01 resolver (client custom domains,
# see api-service's docs/Customdomain-req.md constraint #1) — kept apart
# from acme.json (the platform's own DNS-01 certs) deliberately, so an
# issue with one resolver's storage can't affect the other's.
touch /opt/traefik/acme-http.json
chmod 600 /opt/traefik/acme-http.json

# Platform router priorities sit far above any value Traefik derives from
# rule length (~25-40 for an app router), so no customer app can capture a
# platform hostname. The 10000/10100 gap keeps /api ahead of the bare host.
# server-setup.md#router-priorities
# Scale-to-zero routers are NOT written here any more. deploy-service
# generates them per HOSTNAME into scale-to-zero.yml in the same directory,
# from its own registry, which is what lets an app opt in at deploy time
# and what covers custom domains. server-setup.md#s2z-routers

cat > /opt/traefik/dynamic/platform.yml << EOF
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
          "/opt/traefik/dynamic:/etc/traefik/dynamic",
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
          # Default 15s. Shortens (does not close) the window after a
          # stop in which Traefik still routes to a dead allocation; the
          # always-front router above is what closes it.
          # server-setup.md#refresh-interval
          "--providers.nomad.refreshInterval=5s",
          "--providers.file.directory=/etc/traefik/dynamic",
          "--certificatesresolvers.cloudflare.acme.dnschallenge=true",
          "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare",
          "--certificatesresolvers.cloudflare.acme.email=${ACME_EMAIL}",
          "--certificatesresolvers.cloudflare.acme.storage=/acme.json",
          # HTTP-01 for CLIENT custom domains — the DNS-01 resolver above
          # only covers this platform's own zone. Coexists with the
          # web->websecure redirect. server-setup.md#http01
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
# 6. deploy-service and api-service — clean pull from git, branch = APP_ENV.
#    Discards ANY local drift: reset --hard + clean -fd, never merge. This
#    is why app data and analytics live outside these checkouts.
#    server-setup.md#clean-pull
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
# Exported (not just passed to pm2) so hydrate_env_file's ${!key} lookup
# bakes them into each service's .env, which is what dotenv actually reads.
# PORT is exported per service, separately, immediately before that
# service's own hydrate call. server-setup.md#env-exports
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

# The platform's own zone: api-service refuses to register any custom
# domain under it, which would otherwise pass DNS verification and take a
# router for a platform hostname. An explicit setting wins — it is a
# security control. server-setup.md#platform-domain
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
# Must match the activator service name written into platform.yml above —
# it carries the APP_ENV prefix, and deploy-service generates routers that
# reference it by name. server-setup.md#s2z-routers
export ACTIVATOR_SERVICE_NAME="${PREFIX}scale-to-zero-activator"
export TRAEFIK_DYNAMIC_DIR="/opt/traefik/dynamic"
export ANALYTICS_DB_PATH="${ANALYTICS_DIR}/analytics.db"

# Per-app persistent storage, bind-mounted to /data. Exists so app data is
# NOT owned by its Nomad allocation — /alloc/data is garbage collected with
# a stopped job, which would silently empty every SQLite database. This is
# the prerequisite for scale-to-zero. server-setup.md#app-data-root
export APP_DATA_ROOT="/opt/embarko-appdata/${APP_ENV}"
mkdir -p "${APP_DATA_ROOT}"
chown "${APP_USER}:${APP_USER}" "${APP_DATA_ROOT}"

export PORT="${DEPLOY_PORT}"
hydrate_env_file "${APP_HOME}/${DEPLOY_SERVICE_NAME}"

export PORT="${API_PORT}"
hydrate_env_file "${APP_HOME}/${API_SERVICE_NAME}"

# Unset PORT before pm2 starts. dotenv does NOT override an already-set
# variable and `pm2 start` inherits this shell, so a leftover PORT puts
# deploy-service on api-service's port. That was the 2026-09-17 outage,
# reproducible by provisioning alone. server-setup.md#unset-port
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

# npm ci for pinned versions, --include=dev so NODE_ENV=production cannot
# strip typescript and break the build. server-setup.md#npm-install
for svc_dir in "${APP_HOME}/${DEPLOY_SERVICE_NAME}" "${APP_HOME}/${API_SERVICE_NAME}"; do
  if sudo -u "${APP_USER}" bash -c "test -f '${svc_dir}/package-lock.json'"; then
    sudo -u "${APP_USER}" bash -c "cd '${svc_dir}' && npm ci --include=dev"
  else
    echo "    ${svc_dir} has no package-lock.json — falling back to npm install"
    sudo -u "${APP_USER}" bash -c "cd '${svc_dir}' && rm -rf node_modules && npm install --include=dev"
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
  else
    # No build step means nothing would catch a parse error until pm2
    # crash-loops on it. server-setup.md#syntax-check
    echo "    ${svc_dir} has no build script — checking its JavaScript parses"
    sudo -u "${APP_USER}" bash -c "find '${svc_dir}' -name '*.js' -not -path '*/node_modules/*' -print0 | xargs -0 -n1 node --check"
  fi
done

# Apply pending Prisma migrations, detected generically
# (prisma/schema.prisma) rather than hardcoded to api-service.
# `migrate deploy`, never `migrate dev`. MUST run before pm2 starts
# anything. server-setup.md#prisma
for svc_dir in "${APP_HOME}/${DEPLOY_SERVICE_NAME}" "${APP_HOME}/${API_SERVICE_NAME}"; do
  HAS_PRISMA_SCHEMA=$(sudo -u "${APP_USER}" bash -c "test -f '${svc_dir}/prisma/schema.prisma'" && echo "yes" || echo "no")
  if [[ "$HAS_PRISMA_SCHEMA" == "yes" ]]; then
    echo "    ${svc_dir} has a Prisma schema — applying pending migrations"
    sudo -u "${APP_USER}" bash -c "cd '${svc_dir}' && npx prisma migrate deploy"
  fi
done

# Seed the scale-to-zero router file. Needs the repo pulled, .env generated
# and node_modules installed, so it runs here rather than beside the rest of
# the Traefik config. Non-fatal: without it a stopped allowlisted app 404s
# until the next deploy regenerates the file, which is bad but not an
# outage. server-setup.md#s2z-routers
if [[ -f "${APP_HOME}/${DEPLOY_SERVICE_NAME}/scale-to-zero-registry.js" ]]; then
  echo "--> Generating scale-to-zero Traefik routers"
  sudo -u "${APP_USER}" bash -c "cd '${APP_HOME}/${DEPLOY_SERVICE_NAME}' && node scale-to-zero-registry.js" \
    || echo "    WARNING: could not generate scale-to-zero routers (stopped apps would 404 until the next deploy)"
else
  echo ""
  echo "!! scale-to-zero-registry.js is NOT in this checkout of ${DEPLOY_SERVICE_NAME}."
  echo "!! Traefik has just been switched to the DIRECTORY provider, which expects"
  echo "!! that script to write /opt/traefik/dynamic/scale-to-zero.yml. Without it"
  echo "!! NO app has a wake router: every allowlisted app 404s the moment the idle"
  echo "!! watcher stops it — within IDLE_THRESHOLD_MIN (${IDLE_THRESHOLD_MIN}m), silently."
  echo "!!"
  echo "!! Merge the scale-to-zero Step 7 branch into '${APP_ENV}' and re-run this."
  echo "!! Until then, disable the idle watcher:  systemctl stop ${IDLE_WATCHER_UNIT:-embarko-idle-${APP_ENV}}.timer"
  echo ""
fi


# ---------------------------------------------------------------------------
# 6b. Log rotation. Traefik's access log and pm2's logs had no ceiling at
#     all — both grow with every request, forever. server-setup.md#log-rotation
# ---------------------------------------------------------------------------
echo "--> Configuring log rotation (Traefik access log + pm2)"

# copytruncate, NOT rename: Traefik holds this file open from inside its
# container, so a rename would leave it writing to the rotated file. The
# analytics tailer detects the truncation by inode+offset and resumes.
cat > /etc/logrotate.d/embarko-traefik << EOF
/opt/traefik/logs/access.log {
  daily
  rotate 7
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
  su root root
}
EOF

# pm2 rotates nothing on its own; this module is the supported way.
# Idempotent — re-installing an already-present module is a no-op.
sudo -u "${APP_USER}" bash -c "
  pm2 install pm2-logrotate >/dev/null 2>&1 || true
  pm2 set pm2-logrotate:max_size 50M
  pm2 set pm2-logrotate:retain 7
  pm2 set pm2-logrotate:compress true
" || echo "    WARNING: could not configure pm2-logrotate (pm2 logs will grow unbounded)"

# ---------------------------------------------------------------------------
# 7. Firewall — 22, 80, 443 public; neither service's port is opened (both
#    bind 127.0.0.1, reachable only via Traefik).
#
#    SSH MUST be allowed BEFORE `ufw --force enable`. Do not reorder these
#    three lines — getting it wrong locks you out. server-setup.md#firewall
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
# 9. Start both services under pm2, persist across reboots.
#
#    An ecosystem file, not ad-hoc CLI calls. Secrets are NOT duplicated
#    here — they are already in each service's .env. server-setup.md#pm2
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
# 9b. Scale-to-zero idle watcher — a systemd timer, not cron (journal +
#     Persistent). Runs as APP_USER, NEVER root: idle-report.js opens the
#     analytics database read-write, and root would leave root-owned
#     -wal/-shm files the service then cannot write past.
#
#     SAFETY: it can only stop an app named in scale-to-zero-apps.js.
#     Scheduling it does not widen that. server-setup.md#idle-watcher
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
# 9c. Docker GC — a daily timer.
#
#     Every container creation orphans an anonymous volume for images that
#     declare VOLUME, and nothing reuses them. Reached 74.66GB / 91% disk on
#     2026-09-21 with no symptom but `df`. Scale-to-zero makes it worse: one
#     orphan per sleep/wake cycle.
#
#     SAFE: app data is a BIND MOUNT and never appears in `docker volume ls`;
#     the images pruned are dangling-only. Tagged images are untouched here —
#     that is prune-app-images.sh. server-setup.md#docker-gc
# ---------------------------------------------------------------------------
DOCKER_GC_UNIT="embarko-docker-gc-${APP_ENV}"
echo "--> Installing Docker GC timer '${DOCKER_GC_UNIT}' (daily)"

cat > "/etc/systemd/system/${DOCKER_GC_UNIT}.service" << EOF
[Unit]
Description=Embarko Docker GC — reclaim orphaned anonymous volumes and dangling images (${APP_ENV})
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker volume prune -f
ExecStart=/usr/bin/docker image prune -f
# Leading '-': a failure here is ignored. If the buildkit container is not
# running, this exec fails, and it must not abort the volume/image prunes
# that already ran. --keep-storage is in MEGABYTES in this buildctl; "10GB"
# is rejected outright, which at least fails loudly rather than silently
# keeping everything. server-setup.md#buildkit-cache
ExecStart=-/usr/bin/docker exec buildkit buildctl prune --keep-storage ${BUILDKIT_CACHE_KEEP_MB}
EOF

cat > "/etc/systemd/system/${DOCKER_GC_UNIT}.timer" << EOF
[Unit]
Description=Run Embarko Docker GC daily (${APP_ENV})

[Timer]
# OnActiveSec, not OnBootSec — see the idle watcher timer above for why an
# OnBootSec deadline on a long-running box never fires.
OnActiveSec=15min
OnUnitInactiveSec=24h

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${DOCKER_GC_UNIT}.timer"

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