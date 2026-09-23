#!/usr/bin/env bash
# redeploy.sh — pull the latest deploy-service + api-service code, bring
# their .env files up to date, and restart them. Does NOT touch
# Nomad/Docker/Traefik or any running customer app job — that is
# server-setup.sh's job, and only for provisioning or a real infra change.
#
#   bash redeploy.sh prod
#   bash redeploy.sh test
#
# One file for every environment. It reads <env>.set-env.sh for APP_USER
# and DOMAIN, and <env>.variables.sh only if a .env actually needs
# rebuilding — a routine redeploy touches no secrets at all.
#
# Run as APP_USER, never with sudo: git, docker, npm and pm2 all work
# with that user's own permissions here, and root would leave root-owned
# files behind in their checkouts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_ENV="${1:-}"
if [[ ! "$APP_ENV" =~ ^(test|demo|prod)$ ]]; then
  echo "Usage: bash redeploy.sh <test|demo|prod>" >&2
  [[ -n "$APP_ENV" ]] && echo "       (got '${APP_ENV}')" >&2
  exit 2
fi

SET_ENV_FILE="${SCRIPT_DIR}/${APP_ENV}.set-env.sh"
VARIABLES_FILE="${SCRIPT_DIR}/${APP_ENV}.variables.sh"
if [[ ! -f "$SET_ENV_FILE" ]]; then
  echo "ERROR: ${SET_ENV_FILE} not found." >&2
  exit 1
fi
REQUESTED_ENV="$APP_ENV"
# shellcheck disable=SC1090
source "$SET_ENV_FILE"
# shellcheck source=env-hydrate-lib.sh
source "${SCRIPT_DIR}/env-hydrate-lib.sh"

# The set-env file exports its own APP_ENV, which has just overwritten
# ours. If it disagrees with the argument, the wrong file is about to be
# pointed at the wrong boxes — refuse rather than guess which was meant.
if [[ "$APP_ENV" != "$REQUESTED_ENV" ]]; then
  echo "ERROR: ${SET_ENV_FILE} sets APP_ENV='${APP_ENV}', but you asked for '${REQUESTED_ENV}'." >&2
  exit 1
fi

# Same env-aware naming as server-setup.sh — must stay identical, or this
# pulls and restarts the wrong directories and processes.
if [[ "$APP_ENV" == "prod" ]]; then PREFIX=""; else PREFIX="${APP_ENV}-"; fi
DEPLOY_SERVICE_NAME="${PREFIX}deploy-service"
API_SERVICE_NAME="${PREFIX}api-service"

# Same offsets server-setup.sh uses (its section 0) — these MUST stay
# identical or a hydrate here would write a port the Traefik routes
# generated there never point at. Referenced below when hydrating, and
# previously undefined in this script: that only escaped notice because
# the hydrate branch is conditional and had not fired yet.
case "$APP_ENV" in
  prod) PORT_OFFSET=0 ;;
  test) PORT_OFFSET=1000 ;;
  demo) PORT_OFFSET=2000 ;;
esac
DEPLOY_PORT=$((4000 + PORT_OFFSET))
API_PORT=$((4100 + PORT_OFFSET))
PM2_DEPLOY_NAME="${APP_ENV}-deploy-service"
PM2_API_NAME="${APP_ENV}-api-service"
PM2_ACTIVATOR_NAME="${APP_ENV}-activator"
ACTIVATOR_PORT=$((4200 + PORT_OFFSET))
APP_HOME="${APP_HOME:-/home/${APP_USER}}"
DEPLOY_DIR="${APP_HOME}/${DEPLOY_SERVICE_NAME}"
API_DIR="${APP_HOME}/${API_SERVICE_NAME}"

if [[ "$(whoami)" != "$APP_USER" ]]; then
  echo "ERROR: run this as ${APP_USER}, not sudo/root — see the comment at the top of this file." >&2
  exit 1
fi

echo "=================================================================="
echo " Redeploying — environment: ${APP_ENV}"
echo " deploy-service : ${DEPLOY_SERVICE_NAME}  (pm2: ${PM2_DEPLOY_NAME})"
echo " api-service    : ${API_SERVICE_NAME}  (pm2: ${PM2_API_NAME})"
echo "=================================================================="

# ---------------------------------------------------------------------
# 1. Pull both repos FIRST.
#
# The .env check below has to run against the .env.example this commit
# ships, not the one from before the pull — a commit that introduces a
# new required variable is exactly the case that used to slip through
# and only surface as a crash on restart.
# ---------------------------------------------------------------------
for dir in "$DEPLOY_DIR" "$API_DIR"; do
  echo "--> Pulling ${dir}"
  git -C "$dir" pull
done

# ---------------------------------------------------------------------
# 2. Bring each .env up to date with its (just-pulled) .env.example.
#
# Only rebuilds a .env that is actually missing a key, so a routine
# redeploy neither rewrites the file nor needs any secret. When a rebuild
# IS needed, variables.sh supplies the real values and derive_env_vars
# recomputes everything server-setup.sh derives — skipping that would
# write a .env that had quietly lost them.
# ---------------------------------------------------------------------
NEEDS_HYDRATE=()
for spec in "${DEPLOY_DIR}:deploy-service" "${API_DIR}:api-service"; do
  dir="${spec%%:*}"; label="${spec##*:}"
  [[ -d "$dir" ]] || continue
  missing="$(env_missing_keys "$dir")"

  # A present-but-WRONG value is invisible to the missing-key check, and
  # PORT is the one where that is catastrophic rather than cosmetic: the
  # two services must bind the two ports Traefik's routes point at, or
  # ship.embarko.ai 502s, /api reaches the wrong process, and the loser
  # crash-loops unable to bind. That is exactly what happened on
  # 2026-09-17, when a global `export PORT=4100` in variables.sh put
  # api-service's port into deploy-service's .env. Verified explicitly
  # here so a redeploy REPAIRS it instead of restarting into it.
  if [[ "$label" == "deploy-service" ]]; then expected_port="$DEPLOY_PORT"; else expected_port="$API_PORT"; fi
  actual_port="$(grep -m1 '^PORT=' "${dir}/.env" 2>/dev/null | cut -d= -f2- || true)"

  if [[ -n "$missing" ]]; then
    echo "--> ${label}: .env is missing key(s) from .env.example:"
    printf '      %s\n' $missing
    NEEDS_HYDRATE+=("$spec")
  elif [[ "$actual_port" != "$expected_port" ]]; then
    echo "--> ${label}: .env has PORT=${actual_port:-<unset>}, expected ${expected_port} — rebuilding"
    NEEDS_HYDRATE+=("$spec")
  else
    echo "--> ${label}: .env has every key, and PORT=${actual_port}"
  fi
done

if [[ ${#NEEDS_HYDRATE[@]} -gt 0 ]]; then
  if [[ ! -f "$VARIABLES_FILE" ]]; then
    echo "ERROR: a .env needs rebuilding, but ${VARIABLES_FILE} is missing." >&2
    echo "       That file holds the real values — restore it and re-run." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$VARIABLES_FILE"
  derive_env_vars
  for spec in "${NEEDS_HYDRATE[@]}"; do
    dir="${spec%%:*}"; label="${spec##*:}"
    # PORT differs per service, so export it immediately before each call.
    if [[ "$label" == "deploy-service" ]]; then
      export PORT="${DEPLOY_PORT}"
    else
      export PORT="${API_PORT}"
    fi
    hydrate_service_env "$dir" "$label"
  done
fi

# ---------------------------------------------------------------------
# 3. deploy-service — dependencies, sidecar image, build, restart.
# ---------------------------------------------------------------------
cd "$DEPLOY_DIR"

# Nomad references this image by a fixed tag with force_pull=false (see
# nomad-job-spec.js), so a git pull alone never rebuilds it. Only built
# when orphan-proxy/ actually exists, the same condition server-setup.sh
# uses.
if [[ -d "${DEPLOY_DIR}/orphan-proxy" ]]; then
  echo "--> Rebuilding orphan-banner-proxy sidecar image"
  docker build -t orphan-banner-proxy:local "${DEPLOY_DIR}/orphan-proxy"
fi

# A pull can add dependencies without this script knowing; npm install is
# what fetches them. Must precede the build and restart, or a new
# require() from this commit crashes the process even though the pull
# itself was clean.
echo "--> Installing dependencies"
# --include=dev, not a bare install: if NODE_ENV=production is exported
# (it was, globally, in variables.sh), npm omits devDependencies and
# strips typescript — so `npm run build` dies with "tsc: not found" and
# this script aborts BEFORE restarting anything. Explicit here so the
# build cannot break again on whatever NODE_ENV happens to be set.
npm install --include=dev

# Generic detection rather than hardcoding which service compiles: a pull
# only updates source, so for a compiled service the restart re-executes
# the PREVIOUS build until this runs — silently serving stale code after a
# successful pull. That happened here before this step existed.
if node -e "process.exit(require('./package.json').scripts?.build ? 0 : 1)"; then
  echo "--> ${DEPLOY_DIR} has a build script — running it"
  npm run build
fi

# Regenerate the scale-to-zero Traefik routers from the registry. Here as
# well as in server-setup.sh: the router file is derived from deploy-service
# code and the registry, both of which a redeploy can change, and needing a
# full re-provision to fix routing would defeat the point of Step 7.
# Non-fatal — a stopped allowlisted app would 404 until the next run.
# server-setup.md#s2z-routers
if [[ -f "${DEPLOY_DIR}/scale-to-zero-registry.js" ]]; then
  echo "--> Regenerating scale-to-zero Traefik routers"
  (cd "$DEPLOY_DIR" && node scale-to-zero-registry.js) \
    || echo "    WARNING: could not generate scale-to-zero routers (stopped apps would 404)"
fi

# Syntax-check before restarting. deploy-service is plain JS with no build
# step, so nothing else would catch a parse error until pm2 crash-loops on
# it. server-setup.md#syntax-check
echo "--> Checking deploy-service JavaScript parses"
find "$DEPLOY_DIR" -name '*.js' -not -path '*/node_modules/*' -print0 \
  | xargs -0 -n1 node --check

echo "--> Restarting ${PM2_DEPLOY_NAME}"
# PORT is set explicitly here, immediately before the restart, and NOT
# left to .env. `--update-env` hands pm2 this shell's environment, and
# dotenv does NOT override a variable that is already set — so any stale
# PORT exported in the operator's shell (for example from sourcing an
# older variables.sh) silently wins over the correct value in .env. That
# is precisely how deploy-service ended up bound to api-service's port on
# 2026-09-17 even after .env had been corrected: the file was right and
# the process still came up wrong.
#
# Setting it per service here makes the inherited value irrelevant.
export PORT="$DEPLOY_PORT"
pm2 restart "${PM2_DEPLOY_NAME}" --update-env

# ---------------------------------------------------------------------
# 3b. scale-to-zero activator (deploy-service/activator.js).
#
# Same checkout and the same .env as deploy-service, but its own process,
# so it restarts here alongside the code it was pulled with. Started
# rather than restarted when it isn't running yet: every box provisioned
# before Step 4 existed has no such pm2 process, and a bare `pm2 restart`
# would fail under `set -e` and abort the redeploy AFTER deploy-service
# had already been restarted — the worst place to stop.
#
# PORT is not exported for it. It reads ACTIVATOR_PORT, and leaving
# DEPLOY_PORT in the environment is harmless only because of that; the
# explicit export below removes the need to rely on it.
# ---------------------------------------------------------------------
if [[ -f "${DEPLOY_DIR}/activator.js" ]]; then
  export ACTIVATOR_PORT
  if pm2 describe "${PM2_ACTIVATOR_NAME}" >/dev/null 2>&1; then
    echo "--> Restarting ${PM2_ACTIVATOR_NAME}"
    pm2 restart "${PM2_ACTIVATOR_NAME}" --update-env
  else
    echo "--> ${PM2_ACTIVATOR_NAME} is not running yet — starting it"
    pm2 start "${DEPLOY_DIR}/activator.js" --name "${PM2_ACTIVATOR_NAME}" --cwd "${DEPLOY_DIR}"
    pm2 save
  fi
else
  echo "--> No activator.js in this checkout — skipping ${PM2_ACTIVATOR_NAME}"
fi

# ---------------------------------------------------------------------
# 4. api-service — dependencies, Prisma, build, migrations, restart.
# ---------------------------------------------------------------------
cd "$API_DIR"

echo "--> Installing dependencies"
# --include=dev, not a bare install: if NODE_ENV=production is exported
# (it was, globally, in variables.sh), npm omits devDependencies and
# strips typescript — so `npm run build` dies with "tsc: not found" and
# this script aborts BEFORE restarting anything. Explicit here so the
# build cannot break again on whatever NODE_ENV happens to be set.
npm install --include=dev

# npm install only regenerates the Prisma Client via @prisma/client's
# postinstall, which fires only when npm actually installs something. A
# schema-only change makes npm install a no-op, leaving the client stale
# and the build failing on a model it doesn't know about. Unconditional
# and before the build; it's a cheap no-op when nothing changed.
if [[ -f "${API_DIR}/prisma/schema.prisma" ]]; then
  echo "--> Regenerating Prisma Client"
  npx prisma generate
fi

if node -e "process.exit(require('./package.json').scripts?.build ? 0 : 1)"; then
  echo "--> ${API_DIR} has a build script — running it"
  npm run build
fi

# Before the restart: a service whose schema is newer than its database
# fails confusingly on the first request that touches the gap rather than
# clearly at startup.
if [[ -f "${API_DIR}/prisma/schema.prisma" ]]; then
  echo "--> Applying pending Prisma migrations"
  npx prisma migrate deploy
fi

echo "--> Restarting ${PM2_API_NAME}"
# Same reasoning as the deploy-service restart above.
export PORT="$API_PORT"
pm2 restart "${PM2_API_NAME}" --update-env

echo "=================================================================="
echo " Redeploy complete — environment: ${APP_ENV}"
echo " Existing customer app Nomad jobs were not touched by this script."
echo "=================================================================="
