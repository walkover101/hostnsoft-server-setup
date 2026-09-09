#!/usr/bin/env bash
# variables.sh — app-specific environment variables, distinct from
# set-env.sh's infra-level variables (DOMAIN, CF_DNS_API_TOKEN, etc.).
#
# Deployment convention: same as set-env.sh — copy this per server,
# renamed with an env prefix (test.variables.sh, prod.variables.sh).
#
# WHAT GOES HERE: whatever variables deploy-service and api-service's
# own .env.example files actually define. This script has no built-in
# knowledge of what those are — check each repo directly:
#   cat ~/deploy-service/.env.example
#   cat ~/api-service/.env.example
# and add an `export KEY=value` line here for each one that needs a
# real value (secrets, real URLs, etc.) rather than whatever placeholder
# the example file itself has. A key with no corresponding export here
# keeps the .env.example's own default — only override what actually
# needs a real value for this environment.
#
# IMPORTANT: source this BEFORE server-setup.sh, same as set-env.sh:
#   source prod.set-env.sh
#   source prod.variables.sh
#   sudo -E bash prod.server-setup.sh
#
# Never commit a real copy of this file with actual secret values to git.

# ---------------------------------------------------------------------
# Example shape — DELETE these placeholders and replace with whatever
# keys your repos' own .env.example files actually define. These names
# are illustrative only, not something this script or its repos
# necessarily use.
# ---------------------------------------------------------------------
# export DATABASE_URL="postgres://user:pass@real-host:5432/proddb"
# export JWT_SECRET="a-real-secret-value"
# export SENTRY_DSN="https://real-dsn@sentry.io/project-id"


# ---------------------------------------------------------------------
# ENV Vars for API Service
# ---------------------------------------------------------------------
export DATABASE_URL="file:./app_env.db"
export JWT_SECRET="change me"
export PORT=4100
export NODE_ENV=production|test|demo
export FRONTEND_ORIGIN="https://embarko.ai"   # placeholder until the dashboard frontend exists — see below
export HOSTNSOFT_DEPLOY_URL="https://ship.embarko.ai"

export MSG91_AUTHKEY="change me"
export MSG91_GENERATE_AUTH_TOKEN_URL="https://routes.msg91.com/api/change_me/generateAuthToken"

# EDGE_HOSTNAME, ORIGIN_SERVER_IP, INTERNAL_API_SECRET (custom domains —
# see api-service's docs/Customdomain-req.md) are NOT set here — all
# three are computed/generated automatically by server-setup.sh itself
# (see its section 0 and INTERNAL_API_SECRET handling). Do not override
# them here unless you specifically need to force a different value.

# Optional — both have sensible defaults, uncomment only to override.
# How often already-active custom domains get re-checked against live
# DNS, in ms. Default: 24h (see api-service's docs/Customdomain-req.md).
# export DOMAIN_REVERIFICATION_INTERVAL_MS=86400000
# Anonymous ("orphan") deploys — see api-service's
# docs/Anonymous-deploy-req.md. ORPHAN_TTL_MS: how long an unclaimed
# orphan project lives before deletion. Default: 24h.
# export ORPHAN_TTL_MS=86400000
# ORPHAN_CLEANUP_INTERVAL_MS: how often the cleanup job checks for
# expired orphans. Default: 1h.
# export ORPHAN_CLEANUP_INTERVAL_MS=3600000
# Feature requests / feedback — see api-service's docs/request-feature-req.md.
# Rolling-window rate limits for the public (unauthenticated)
# POST /public/feature-requests endpoint. All optional, sensible defaults:
# export FEATURE_REQUEST_RATE_WINDOW_MS=3600000
# export FEATURE_REQUEST_RATE_PER_EMAIL=10
# export FEATURE_REQUEST_RATE_PER_IP=20
# export FEATURE_REQUEST_RATE_GLOBAL=500



# ---------------------------------------------------------------------
# ENV Vars for Deploy Service
# ---------------------------------------------------------------------
export HOSTNSOFT_API_URL="http://127.0.0.1:4100"
export APPS_DOMAIN_SUFFIX="app.embarko.ai"

# ORIGIN_IP is NOT set here either — auto-computed by server-setup.sh
# (see deploy-service's docs/Anonymous-deploy-req.md #5).
# TRAEFIK_ACCESS_LOG_PATH and ANALYTICS_DB_PATH are NOT set here either —
# both auto-computed by server-setup.sh (see deploy-service's analytics/
# and docs/CLAUDE.md).
# INTERNAL_API_SECRET is NOT set here either — see the note above; it's
# generated once by server-setup.sh and written identically into both
# services' .env files.

