#!/usr/bin/env bash
# fix-missing-analytics-env.sh — one-off remediation for hosts provisioned
# BEFORE server-setup.sh's analytics section (commit f39e972, 2026-09-08)
# existed. On those hosts, deploy-service's .env never got
# ANALYTICS_DB_PATH / TRAEFIK_ACCESS_LOG_PATH, because routine deploys go
# through redeploy.sh (git pull + npm install + restart only — it never
# regenerates .env), and server-setup.sh itself is only meant to be re-run
# for initial provisioning or an actual infra-level change, not routine
# config drift like this. Symptom this fixes: every project's
# GET .../analytics returning 503 "Analytics are temporarily unavailable",
# because deploy-service's analytics/db.js throws synchronously on every
# request when ANALYTICS_DB_PATH isn't set.
#
# Deliberately narrow — does ONLY the two things below, nothing else
# server-setup.sh would otherwise also do (no Docker/Nomad restart, no
# Traefik re-apply, no git reset):
#   1. Create/chown this environment's analytics dir, append the two env
#      vars to deploy-service's live .env (idempotent — skips any key
#      already present rather than duplicating it).
#   2. Restart ONLY the deploy-service pm2 process (same action
#      redeploy.sh already does routinely, not a new kind of risk).
#
# This does NOT make Traefik write JSON access logs — that flag
# (--accesslog.format=json) only takes effect once Traefik's own Nomad job
# is re-applied, which IS a shared, whole-platform action (the one Traefik
# instance in front of every environment). That's a separate, deliberate
# step — see the note this script prints at the end — not bundled in here.
#
# Deployment convention: same as redeploy.sh — copy this per environment
# if you need it for more than one, filling in APP_ENV/APP_USER below.
# Run directly as APP_USER for the .env edit + pm2 restart; the one
# directory-creation line needs root (via sudo), same division of labor
# server-setup.sh itself uses.

set -euo pipefail

# ---------------------------------------------------------------------
# REQUIRED — fill these in yourself, matching this environment's
# set-env.sh copy.
# ---------------------------------------------------------------------
APP_ENV="prod"
APP_USER="ubuntu"

if [[ ! "$APP_ENV" =~ ^(test|demo|prod)$ ]]; then
  echo "ERROR: APP_ENV must be exactly one of: test, demo, prod (got '$APP_ENV')." >&2
  exit 1
fi

if [[ "$APP_ENV" == "prod" ]]; then
  PREFIX=""
else
  PREFIX="${APP_ENV}-"
fi
DEPLOY_SERVICE_NAME="${PREFIX}deploy-service"
PM2_DEPLOY_NAME="${APP_ENV}-deploy-service"
APP_HOME="/home/${APP_USER}"
ENV_FILE="${APP_HOME}/${DEPLOY_SERVICE_NAME}/.env"
ANALYTICS_DIR="/opt/hostnsoft-analytics/${APP_ENV}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: ${ENV_FILE} not found — check APP_ENV/APP_USER above match this host." >&2
  exit 1
fi

echo "--> Creating ${ANALYTICS_DIR} (owned by ${APP_USER})"
sudo mkdir -p "$ANALYTICS_DIR"
sudo chown "${APP_USER}:${APP_USER}" "$ANALYTICS_DIR"

echo "--> Ensuring TRAEFIK_ACCESS_LOG_PATH / ANALYTICS_DB_PATH are in ${ENV_FILE}"
if ! grep -q '^TRAEFIK_ACCESS_LOG_PATH=' "$ENV_FILE"; then
  echo "TRAEFIK_ACCESS_LOG_PATH=/opt/traefik/logs/access.log" | sudo -u "${APP_USER}" tee -a "$ENV_FILE" >/dev/null
  echo "    added TRAEFIK_ACCESS_LOG_PATH"
else
  echo "    TRAEFIK_ACCESS_LOG_PATH already present — left as-is"
fi
if ! grep -q '^ANALYTICS_DB_PATH=' "$ENV_FILE"; then
  echo "ANALYTICS_DB_PATH=${ANALYTICS_DIR}/analytics.db" | sudo -u "${APP_USER}" tee -a "$ENV_FILE" >/dev/null
  echo "    added ANALYTICS_DB_PATH"
else
  echo "    ANALYTICS_DB_PATH already present — left as-is"
fi

echo "--> Restarting ${PM2_DEPLOY_NAME} (same restart redeploy.sh already does routinely)"
sudo -u "${APP_USER}" bash -c "pm2 restart ${PM2_DEPLOY_NAME}"

echo "=================================================================="
echo " Done. GET .../analytics should stop 503ing for ${APP_ENV} now —"
echo " CPU/memory numbers (from Nomad's stats API, independent of Traefik)"
echo " should populate immediately; traffic/request numbers will stay at"
echo " zero until Traefik's own Nomad job is re-applied with"
echo " --accesslog.format=json (server-setup.sh section 5/8) — that's a"
echo " separate, shared-infra action (the one Traefik instance in front"
echo " of every environment) with its own brief full-platform blip while"
echo " it restarts, so it's deliberately not bundled into this script."
echo "=================================================================="
