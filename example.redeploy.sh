#!/usr/bin/env bash
# redeploy.sh — pulls latest code for deploy-service + api-service and
# restarts them, WITHOUT touching Nomad/Docker/Traefik or any already-
# running customer app job. Use this for routine "ship a code change"
# deploys; use server-setup.sh only for initial provisioning or an
# actual infra-level change (new resolver, Traefik config, etc.).
#
# Deployment convention: same as set-env.sh/variables.sh — copy this per
# environment, renamed with an env prefix (test.redeploy.sh,
# prod.redeploy.sh) and APP_ENV/APP_USER filled in below. Self-contained
# — no need to source set-env.sh/variables.sh first.
#
# Run directly as APP_USER (no sudo) — every action here (git, docker
# build, prisma migrate, pm2) only needs that user's own permissions
# (docker group membership, pm2's user-level daemon), and running as
# root would leave root-owned files behind in this user's own checkouts.
#   bash prod.redeploy.sh
#
# What this does NOT do, on purpose: restart Nomad/Docker, re-apply
# Traefik's job, touch firewall rules, or affect any customer app's
# Nomad job — all of that is server-setup.sh's job, not this one's.

set -euo pipefail

# ---------------------------------------------------------------------
# REQUIRED — fill these in yourself, matching this environment's
# set-env.sh copy.
# ---------------------------------------------------------------------
APP_ENV="REPLACE_ME_WITH_test_demo_OR_prod"
APP_USER="ubuntu"

if [[ "$APP_ENV" == "REPLACE_ME_WITH_test_demo_OR_prod" ]]; then
  echo "ERROR: edit redeploy.sh and set APP_ENV to test, demo, or prod before running." >&2
  exit 1
fi
if [[ ! "$APP_ENV" =~ ^(test|demo|prod)$ ]]; then
  echo "ERROR: APP_ENV must be exactly one of: test, demo, prod (got '$APP_ENV')." >&2
  exit 1
fi

# Same env-aware naming as server-setup.sh — must stay identical, or
# this ends up pulling/restarting the wrong directories/processes.
if [[ "$APP_ENV" == "prod" ]]; then
  PREFIX=""
else
  PREFIX="${APP_ENV}-"
fi
DEPLOY_SERVICE_NAME="${PREFIX}deploy-service"
API_SERVICE_NAME="${PREFIX}api-service"
PM2_DEPLOY_NAME="${APP_ENV}-deploy-service"
PM2_API_NAME="${APP_ENV}-api-service"
APP_HOME="/home/${APP_USER}"

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
# deploy-service
# ---------------------------------------------------------------------
DEPLOY_DIR="${APP_HOME}/${DEPLOY_SERVICE_NAME}"
echo "--> Pulling ${DEPLOY_DIR}"
cd "${DEPLOY_DIR}"
git pull

# Nomad references this image by a fixed tag with force_pull=false (see
# nomad-job-spec.js) — a git pull alone never rebuilds it. Only rebuilt
# when the orphan-proxy/ directory actually exists in this checkout, same
# condition server-setup.sh itself uses.
if [[ -d "${DEPLOY_DIR}/orphan-proxy" ]]; then
  echo "--> Rebuilding orphan-banner-proxy sidecar image"
  docker build -t orphan-banner-proxy:local "${DEPLOY_DIR}/orphan-proxy"
fi

# Same generic detection as server-setup.sh — only runs a build if this
# checkout actually defines one (deploy-service currently doesn't; this
# stays generic rather than hardcoding "only api-service builds", so it
# keeps working correctly if that ever changes). MUST run before the
# restart below: a git pull only updates source files — for a compiled
# service (e.g. TypeScript -> dist/), the restart re-executes whatever
# was PREVIOUSLY built until this actually runs, silently serving stale
# code despite a real, successful pull. Confirmed the hard way: this step
# was missing here for a while, and `git pull` reporting fresh commits
# gave no indication the running process was still on old compiled output.
HAS_BUILD_SCRIPT=$(node -e "process.exit(require('./package.json').scripts?.build ? 0 : 1)" && echo "yes" || echo "no")
if [[ "$HAS_BUILD_SCRIPT" == "yes" ]]; then
  echo "--> ${DEPLOY_DIR} has a build script — running it"
  npm run build
fi

echo "--> Restarting ${PM2_DEPLOY_NAME}"
pm2 restart "${PM2_DEPLOY_NAME}"

# ---------------------------------------------------------------------
# api-service
# ---------------------------------------------------------------------
API_DIR="${APP_HOME}/${API_SERVICE_NAME}"
echo "--> Pulling ${API_DIR}"
cd "${API_DIR}"
git pull

# See the identical build-step comment in the deploy-service section
# above — api-service DOES define a build script (TypeScript -> dist/,
# and "start" runs the compiled output), so this is the actual fix for
# the exact staleness this script was missing before.
HAS_BUILD_SCRIPT=$(node -e "process.exit(require('./package.json').scripts?.build ? 0 : 1)" && echo "yes" || echo "no")
if [[ "$HAS_BUILD_SCRIPT" == "yes" ]]; then
  echo "--> ${API_DIR} has a build script — running it"
  npm run build
fi

# Same generic detection as server-setup.sh — only applies migrations if
# this checkout actually has a Prisma schema. Must run BEFORE the
# restart below: a service with a schema newer than its database fails
# confusingly on the first request that touches the gap, not clearly at
# startup, if this were skipped or run after.
if [[ -f "${API_DIR}/prisma/schema.prisma" ]]; then
  echo "--> Applying pending Prisma migrations"
  npx prisma migrate deploy
fi

echo "--> Restarting ${PM2_API_NAME}"
pm2 restart "${PM2_API_NAME}"

echo "=================================================================="
echo " Redeploy complete — environment: ${APP_ENV}"
echo " Existing customer app Nomad jobs were not touched by this script."
echo "=================================================================="
