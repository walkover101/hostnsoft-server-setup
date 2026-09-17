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
PM2_DEPLOY_NAME="${APP_ENV}-deploy-service"
PM2_API_NAME="${APP_ENV}-api-service"
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
  if [[ -n "$missing" ]]; then
    echo "--> ${label}: .env is missing key(s) from .env.example:"
    printf '      %s\n' $missing
    NEEDS_HYDRATE+=("$spec")
  else
    echo "--> ${label}: .env already has every key from .env.example"
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
npm install

# Generic detection rather than hardcoding which service compiles: a pull
# only updates source, so for a compiled service the restart re-executes
# the PREVIOUS build until this runs — silently serving stale code after a
# successful pull. That happened here before this step existed.
if node -e "process.exit(require('./package.json').scripts?.build ? 0 : 1)"; then
  echo "--> ${DEPLOY_DIR} has a build script — running it"
  npm run build
fi

echo "--> Restarting ${PM2_DEPLOY_NAME}"
pm2 restart "${PM2_DEPLOY_NAME}" --update-env

# ---------------------------------------------------------------------
# 4. api-service — dependencies, Prisma, build, migrations, restart.
# ---------------------------------------------------------------------
cd "$API_DIR"

echo "--> Installing dependencies"
npm install

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
pm2 restart "${PM2_API_NAME}" --update-env

echo "=================================================================="
echo " Redeploy complete — environment: ${APP_ENV}"
echo " Existing customer app Nomad jobs were not touched by this script."
echo "=================================================================="
