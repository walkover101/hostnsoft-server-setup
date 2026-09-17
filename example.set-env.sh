#!/usr/bin/env bash
# set-env.sh — sets every environment variable server-setup.sh needs.
#
# Deployment convention: copy this file to each server renamed with an
# env prefix (test.set-env.sh, demo.set-env.sh, prod.set-env.sh) — the
# ONLY thing that should differ between copies is the APP_ENV= line below.
# Everything else (DOMAIN, CF_DNS_API_TOKEN, ACME_EMAIL) is typically the
# same across all environments, since they usually share one Cloudflare
# account/zone.
#
# IMPORTANT: source this, don't execute it — exports only persist in
# your current shell if sourced:
#   source test.set-env.sh
#   sudo -E bash test.server-setup.sh

# ---------------------------------------------------------------------
# REQUIRED — fill these in yourself. Never commit real values to git.
# ---------------------------------------------------------------------
export APP_ENV="REPLACE_ME_WITH_test_demo_OR_prod"
export DOMAIN="embarko.ai"
export CF_DNS_API_TOKEN="REPLACE_ME_WITH_YOUR_CLOUDFLARE_TOKEN"
export ACME_EMAIL="REPLACE_ME_WITH_A_REAL_EMAIL"
export DEPLOY_SERVICE_REPO="REPLACE_ME_WITH_GIT_URL"   # e.g. git@github.com:you/deploy-service.git
export API_SERVICE_REPO="REPLACE_ME_WITH_GIT_URL"      # e.g. git@github.com:you/api-service.git

# ---------------------------------------------------------------------
# OPTIONAL — sensible defaults, override before sourcing if needed
# ---------------------------------------------------------------------
export DEPLOY_SUBDOMAIN="${DEPLOY_SUBDOMAIN:-ship}"
export APPS_SUBDOMAIN_BASE="${APPS_SUBDOMAIN_BASE:-app}"
export APP_USER="${APP_USER:-ubuntu}"

# For test/demo only (prod is always bare): uncomment to serve this
# environment off the BARE domain (ship.<DOMAIN>) instead of the default
# ship.<env>.<DOMAIN> — useful if that bare hostname already has DNS/a
# cert from before this env-naming scheme existed. Directory names, pm2
# process names, and the port offset are unaffected either way.
# export DOMAIN_ENV_SEGMENT=""

# ---------------------------------------------------------------------
# Guard: refuse to proceed with unfilled placeholders
# ---------------------------------------------------------------------
if [[ "$APP_ENV" == "REPLACE_ME_WITH_test_demo_OR_prod" ]]; then
  echo "ERROR: edit set-env.sh and set APP_ENV to test, demo, or prod before sourcing." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ ! "$APP_ENV" =~ ^(test|demo|prod)$ ]]; then
  echo "ERROR: APP_ENV must be exactly one of: test, demo, prod (got '$APP_ENV')." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ "$CF_DNS_API_TOKEN" == "REPLACE_ME_WITH_YOUR_CLOUDFLARE_TOKEN" ]]; then
  echo "ERROR: edit set-env.sh and fill in CF_DNS_API_TOKEN before sourcing." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ "$ACME_EMAIL" == "REPLACE_ME_WITH_A_REAL_EMAIL" ]]; then
  echo "ERROR: edit set-env.sh and fill in ACME_EMAIL before sourcing." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ "$DEPLOY_SERVICE_REPO" == "REPLACE_ME_WITH_GIT_URL" ]]; then
  echo "ERROR: edit set-env.sh and fill in DEPLOY_SERVICE_REPO before sourcing." >&2
  return 1 2>/dev/null || exit 1
fi
if [[ "$API_SERVICE_REPO" == "REPLACE_ME_WITH_GIT_URL" ]]; then
  echo "ERROR: edit set-env.sh and fill in API_SERVICE_REPO before sourcing." >&2
  return 1 2>/dev/null || exit 1
fi

# NOTE on auth: server-setup.sh runs `git clone`/`git fetch` non-interactively
# under sudo — it cannot prompt for a password. Make sure whichever form of
# auth you use actually works non-interactively as the target user BEFORE
# running server-setup.sh:
#   - SSH URL (git@github.com:...): the APP_USER (default: ubuntu) needs a
#     working SSH key/agent already set up for this host, OR
#   - HTTPS URL with an embedded token (https://<token>@github.com/...):
#     works without any prior SSH setup, but treat that URL itself as a
#     secret — don't commit set-env.sh with a real token embedded in it.

# ---------------------------------------------------------------------
# Auto-generate INTERNAL_API_SECRET if not already set — printed once so
# you can save it; server-setup.sh would generate its own if left unset
# here, but generating it up front means you see the value before, not
# only buried in that script's final output.
# ---------------------------------------------------------------------
# RECOVER BEFORE GENERATING. This value authenticates api-service ->
# deploy-service calls, so both services must carry the IDENTICAL string.
# Generating a fresh one on every source looks harmless — and is, if both
# .env files are then rebuilt and both processes restarted together — but
# any path that rebuilds only one service, or restarts only one, leaves
# the pair mismatched and every internal call 401s. That failure is
# silent until something actually tries a cross-service call.
#
# It also used to defeat the recovery logic in env-hydrate-lib.sh's
# derive_env_vars, which only looks for an existing secret when the
# variable is UNSET — an exported fresh value skipped it every time.
#
# So: an already-deployed secret wins over a new one. A brand-new box
# (no .env anywhere) still generates one, which is the only case that
# should.
if [[ -z "${INTERNAL_API_SECRET:-}" ]]; then
  _secret_home="/home/${APP_USER:-ubuntu}"
  if [[ "${APP_ENV:-prod}" == "prod" ]]; then _secret_prefix=""; else _secret_prefix="${APP_ENV}-"; fi
  for _candidate in "${_secret_home}/${_secret_prefix}api-service/.env" \
                    "${_secret_home}/${_secret_prefix}deploy-service/.env"; do
    if [[ -r "$_candidate" ]]; then
      _found=$(grep -m1 '^INTERNAL_API_SECRET=' "$_candidate" 2>/dev/null | cut -d= -f2- || true)
      if [[ -n "$_found" ]]; then
        export INTERNAL_API_SECRET="$_found"
        echo "==> Reusing existing INTERNAL_API_SECRET from ${_candidate}"
        break
      fi
    fi
  done
  unset _secret_home _secret_prefix _candidate _found
fi

if [[ -z "${INTERNAL_API_SECRET:-}" ]]; then
  export INTERNAL_API_SECRET="$(openssl rand -hex 32)"
  echo "==> Generated a NEW INTERNAL_API_SECRET (no existing one found)."
  echo "    Both services must be hydrated and restarted together, or"
  echo "    internal calls between them will fail with 401."
fi

echo ""
echo "==> Environment ready (APP_ENV=${APP_ENV}):"
echo "    DOMAIN=${DOMAIN}"
echo "    ACME_EMAIL=${ACME_EMAIL}"
echo "    DEPLOY_SUBDOMAIN=${DEPLOY_SUBDOMAIN}"
echo "    APPS_SUBDOMAIN_BASE=${APPS_SUBDOMAIN_BASE}"
echo "    APP_USER=${APP_USER}"
echo "    DEPLOY_SERVICE_REPO=${DEPLOY_SERVICE_REPO}  (branch: ${APP_ENV})"
echo "    API_SERVICE_REPO=${API_SERVICE_REPO}  (branch: ${APP_ENV})"
echo "    (CF_DNS_API_TOKEN, INTERNAL_API_SECRET are set but not printed again here)"
echo ""
echo "==> DNS mapping is manual — see README.md before running server-setup.sh."
echo "==> Now run: sudo -E bash ${APP_ENV}.server-setup.sh   (or server-setup.sh, whatever you named your copy)"