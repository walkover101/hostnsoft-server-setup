#!/usr/bin/env bash
#
# server-setup.sh — Automated Server Provisioning: deploy-service + api-service
# Installs and configures: Nomad, Docker (+BuildKit), Railpack, Traefik
# (with Cloudflare DNS-01 TLS), deploy-service, and api-service (both
# managed by pm2).
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
  DOMAIN_ENV_SEGMENT="${APP_ENV}."
  case "$APP_ENV" in
    test) PORT_OFFSET=1000 ;;
    demo) PORT_OFFSET=2000 ;;
  esac
fi

DEPLOY_SERVICE_NAME="${PREFIX}deploy-service"
API_SERVICE_NAME="${PREFIX}api-service"
DEPLOY_PORT=$((4000 + PORT_OFFSET))
API_PORT=$((4100 + PORT_OFFSET))

# pm2 process names ALWAYS carry the APP_ENV prefix, even for prod —
# deliberately separate from DEPLOY_SERVICE_NAME/API_SERVICE_NAME above
# (which stay bare-for-prod, used for directories/domains/Traefik, since
# those are already deployed on prod using bare names — changing that
# would mean re-provisioning already-working infrastructure). This only
# affects how processes are labeled in `pm2 list`.
PM2_DEPLOY_NAME="${APP_ENV}-deploy-service"
PM2_API_NAME="${APP_ENV}-api-service"

DEPLOY_HOST="${DEPLOY_SUBDOMAIN}.${DOMAIN_ENV_SEGMENT}${DOMAIN}"
APPS_DOMAIN_SUFFIX="${APPS_SUBDOMAIN_BASE}.${DOMAIN_ENV_SEGMENT}${DOMAIN}"

echo "=================================================================="
echo " Provisioning — environment: ${APP_ENV}"
echo " deploy-service   : ${DEPLOY_SERVICE_NAME}  (port ${DEPLOY_PORT})"
echo " api-service      : ${API_SERVICE_NAME}  (port ${API_PORT})"
echo " Deploy API host  : https://${DEPLOY_HOST}/apps"
echo " api-service      : https://${DEPLOY_HOST}/api (internal-only otherwise)"
echo " Apps wildcard    : https://<app>.${APPS_DOMAIN_SUFFIX}"
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
  }
}
EOF

systemctl enable nomad
systemctl restart nomad

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
# 4. BuildKit + Railpack
# ---------------------------------------------------------------------------
echo "--> Starting BuildKit"
docker rm -f buildkit >/dev/null 2>&1 || true
docker run --privileged -d --name buildkit moby/buildkit

# Verify it's actually running — if the current `moby/buildkit:latest` image
# turns out to need Docker Engine features this OS's docker.io version
# doesn't have, this catches it here with a clear message, rather than the
# failure surfacing confusingly later as "railpack build" mysteriously
# can't connect to BuildKit during an actual app deploy.
sleep 2
if ! docker ps --filter name=buildkit --filter status=running -q | grep -q .; then
  echo "ERROR: BuildKit container failed to start or exited immediately." >&2
  echo "This may mean the installed Docker Engine version is too old for" >&2
  echo "the current moby/buildkit:latest image. Check what's actually" >&2
  echo "installed and consider pinning an older BuildKit tag if so:" >&2
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

cat > /opt/traefik/dynamic.yml << EOF
http:
  routers:
    ${API_SERVICE_NAME}:
      rule: "Host(\`${DEPLOY_HOST}\`) && PathPrefix(\`/api\`)"
      entryPoints:
        - websecure
      service: ${API_SERVICE_NAME}
      priority: 100
      middlewares:
        - ${PREFIX}strip-api-prefix
      tls:
        certResolver: cloudflare

    ${DEPLOY_SERVICE_NAME}:
      rule: "Host(\`${DEPLOY_HOST}\`)"
      entryPoints:
        - websecure
      service: ${DEPLOY_SERVICE_NAME}
      priority: 1
      tls:
        certResolver: cloudflare

  middlewares:
    ${PREFIX}strip-api-prefix:
      stripPrefix:
        prefixes:
          - "/api"

  services:
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
          "/opt/traefik/dynamic.yml:/etc/traefik/dynamic.yml"
        ]

        args = [
          "--accesslog=true",
          "--entrypoints.web.address=:80",
          "--entrypoints.websecure.address=:443",
          "--entrypoints.web.http.redirections.entryPoint.to=websecure",
          "--entrypoints.web.http.redirections.entryPoint.scheme=https",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://127.0.0.1:4646",
          "--providers.nomad.exposedByDefault=false",
          "--providers.file.filename=/etc/traefik/dynamic.yml",
          "--certificatesresolvers.cloudflare.acme.dnschallenge=true",
          "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare",
          "--certificatesresolvers.cloudflare.acme.email=${ACME_EMAIL}",
          "--certificatesresolvers.cloudflare.acme.storage=/acme.json"
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

# Builds each repo's real .env from its own .env.example, substituting
# values from whatever's been exported into this shell (normally sourced
# from a separate <env>.variables.sh file — see set-env.sh/README) —
# fully generic, since this script has no built-in knowledge of what
# app-specific variables either repo actually needs. Each repo's own
# .env.example is the source of truth for which keys exist; the
# variables file is the source of truth for real values. A key with no
# matching override keeps whatever default the example file itself has.
#
# ALSO appends any variable listed in variables.sh's own
# APP_VARIABLE_NAMES array that ISN'T already covered by .env.example —
# necessary because an example file can be incomplete/stale relative to
# what the actual code needs (confirmed in practice: a real app required
# JWT_SECRET, which its own .env.example didn't declare at all — without
# this, that value would be silently dropped rather than ever reaching
# the app, even though it was correctly provided in variables.sh).
hydrate_env_file() {
  local dir="$1"
  local example_file="${dir}/.env.example"
  local target_file="${dir}/.env"
  declare -A seen_keys=()

  if [[ ! -f "$example_file" ]]; then
    echo "    No .env.example in ${dir} — starting from an empty .env"
    > "$target_file"
  else
    echo "    Generating .env for ${dir} from .env.example + provided variables"
    > "$target_file"

    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
        key="${BASH_REMATCH[1]}"
        seen_keys["$key"]=1
        override_value="${!key:-}"
        if [[ -n "$override_value" ]]; then
          echo "${key}=${override_value}" >> "$target_file"
        else
          echo "$line" >> "$target_file"
        fi
      else
        echo "$line" >> "$target_file"
      fi
    done < "$example_file"
  fi

  # Append anything from variables.sh's APP_VARIABLE_NAMES not already
  # covered above — see comment block preceding this function for why.
  local extra_names=("${APP_VARIABLE_NAMES[@]:-}")
  local appended_any=0
  for name in "${extra_names[@]}"; do
    if [[ -z "$name" ]]; then
      continue
    fi
    if [[ -z "${seen_keys[$name]:-}" ]]; then
      value="${!name:-}"
      if [[ -n "$value" ]]; then
        if [[ "$appended_any" -eq 0 ]]; then
          echo "" >> "$target_file"
          echo "# Appended by server-setup.sh — not present in .env.example" >> "$target_file"
          appended_any=1
        fi
        echo "${name}=${value}" >> "$target_file"
      fi
    fi
  done
}

echo "--> Pulling ${DEPLOY_SERVICE_NAME} from ${DEPLOY_SERVICE_REPO} (branch: ${APP_ENV})"
mkdir -p "${APP_HOME}"
chown "${APP_USER}:${APP_USER}" "${APP_HOME}"
clean_pull "${DEPLOY_SERVICE_REPO}" "${APP_HOME}/${DEPLOY_SERVICE_NAME}" "${APP_ENV}"

echo "--> Pulling ${API_SERVICE_NAME} from ${API_SERVICE_REPO} (branch: ${APP_ENV})"
clean_pull "${API_SERVICE_REPO}" "${APP_HOME}/${API_SERVICE_NAME}" "${APP_ENV}"

echo "--> Generating .env files from each repo's .env.example"
# Exported here (not just passed to pm2 later) so hydrate_env_file's
# indirect lookup (${!key}) picks them up and bakes them into each
# service's actual .env — both services load their .env via dotenv, so
# this is what they see at runtime, not whatever's on pm2's command line.
export PORT="${API_PORT}"
export HOSTNSOFT_API_URL="http://127.0.0.1:${API_PORT}"
hydrate_env_file "${APP_HOME}/${DEPLOY_SERVICE_NAME}"
hydrate_env_file "${APP_HOME}/${API_SERVICE_NAME}"

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
# 10. DNS — done manually, not by this script. See README.md for the
#     exact record types/values. Printed here too as a convenience.
# ---------------------------------------------------------------------------
echo "--> DNS is set up manually — see README.md. Records needed for this environment:"
echo "    A   ${DEPLOY_HOST}   -> ${SERVER_IP}"
echo "    A   *.${APPS_DOMAIN_SUFFIX}   -> ${SERVER_IP}"

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