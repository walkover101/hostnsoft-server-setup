#!/usr/bin/env bash
# env-hydrate-lib.sh — shared .env generation.
#
# SOURCED, never executed directly. Two callers:
#   - server-setup.sh   (full provisioning)
#   - redeploy.sh       (routine deploys; repairs a .env that lost a key)
#
# It lives in its own file precisely so those two can never drift: this
# is the single definition of how a service's .env is built. Before it
# existed, the only way to regenerate a .env was a full server-setup.sh
# run, which restarts Nomad/Docker/Traefik — far too blunt for "one
# service's .env got damaged", and so it simply didn't get done.
#
# Callers must have already exported every value referenced by a
# service's .env.example, plus APP_VARIABLE_NAMES.

# Builds each repo's real .env from its own .env.example, substituting
# values from whatever's been exported into this shell (normally sourced
# from a separate <env>.variables.sh file — see set-env.sh/README) —
# fully generic, since this script has no built-in knowledge of what
# app-specific variables either repo actually needs. Each repo's own
# .env.example is the source of truth for which keys exist; the
# variables file is the source of truth for real values. A key with no
# matching override keeps whatever default the example file itself has.
#
# ALSO appends any variable listed in variables.sh's own exported
# APP_VARIABLE_NAMES string (space-separated names) that ISN'T already covered by .env.example —
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
  # APP_VARIABLE_NAMES is an exported space-separated STRING, not an
  # array — bash arrays can't be exported, so an array set in variables.sh
  # would never reach this script through `sudo -E`.
  local extra_names=()
  read -ra extra_names <<< "${APP_VARIABLE_NAMES:-}"
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

# --------------------------------------------------------------------
# derive_env_vars — recompute everything server-setup.sh computes before
# it hydrates.
#
# Lives here so server-setup.sh and redeploy.sh get the identical
# derivation. These values are DERIVED, never set by hand in
# variables.sh, so any caller that hydrates without rebuilding them
# writes a .env that has silently lost them — the very failure hydration
# exists to repair.
#
# Requires APP_ENV, APP_USER and DOMAIN to already be exported (they come
# from <env>.set-env.sh).
# --------------------------------------------------------------------
derive_env_vars() {
  for required in APP_ENV APP_USER DOMAIN; do
    if [[ -z "${!required:-}" ]]; then
      echo "ERROR: ${required} is not set — source <env>.set-env.sh first." >&2
      return 1
    fi
  done

  if [[ "$APP_ENV" == "prod" ]]; then
    PREFIX=""
    DOMAIN_ENV_SEGMENT="${DOMAIN_ENV_SEGMENT-}"
  else
    PREFIX="${APP_ENV}-"
    DOMAIN_ENV_SEGMENT="${DOMAIN_ENV_SEGMENT-${APP_ENV}.}"
  fi

  DEPLOY_SERVICE_NAME="${PREFIX}deploy-service"
  API_SERVICE_NAME="${PREFIX}api-service"
  APP_HOME="${APP_HOME:-/home/${APP_USER}}"

  DEPLOY_SUBDOMAIN="${DEPLOY_SUBDOMAIN:-ship}"
  APPS_SUBDOMAIN_BASE="${APPS_SUBDOMAIN_BASE:-app}"
  DEPLOY_PORT="${DEPLOY_PORT:-4000}"
  API_PORT="${API_PORT:-4100}"

  SERVER_IP="${SERVER_IP:-$(curl -s --max-time 5 https://api.ipify.org || true)}"
  if [[ -z "$SERVER_IP" ]]; then
    echo "ERROR: could not determine this server's public IP (needed for ORIGIN_IP)." >&2
    echo "       Set SERVER_IP=<ip> and re-run." >&2
    return 1
  fi

  export APPS_DOMAIN_SUFFIX="${APPS_SUBDOMAIN_BASE}.${DOMAIN_ENV_SEGMENT}${DOMAIN}"
  export EDGE_HOSTNAME="${EDGE_HOSTNAME:-edge.${DOMAIN_ENV_SEGMENT}${DOMAIN}}"
  export ORIGIN_SERVER_IP="${SERVER_IP}"
  export ORIGIN_IP="${SERVER_IP}"
  export PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-${DOMAIN}}"
  export HOSTNSOFT_API_URL="http://127.0.0.1:${API_PORT}"
  export TRAEFIK_ACCESS_LOG_PATH="/opt/traefik/logs/access.log"
  export ANALYTICS_DB_PATH="/opt/hostnsoft-analytics/${APP_ENV}/analytics.db"
  export APP_DATA_ROOT="${APP_DATA_ROOT:-/opt/embarko-appdata/${APP_ENV}}"

  # INTERNAL_API_SECRET authenticates api-service -> deploy-service calls,
  # so BOTH services must carry the identical value. server-setup.sh
  # generates it once; regenerating it here would silently break that
  # pair. Recover it from whichever .env still has it, and only generate
  # one if neither does.
  if [[ -z "${INTERNAL_API_SECRET:-}" ]]; then
    for candidate in "${APP_HOME}/${API_SERVICE_NAME}/.env" "${APP_HOME}/${DEPLOY_SERVICE_NAME}/.env"; do
      if [[ -f "$candidate" ]]; then
        found=$(grep -m1 '^INTERNAL_API_SECRET=' "$candidate" 2>/dev/null | cut -d= -f2- || true)
        if [[ -n "$found" ]]; then
          export INTERNAL_API_SECRET="$found"
          echo "--> Recovered INTERNAL_API_SECRET from ${candidate}"
          break
        fi
      fi
    done
  fi
  if [[ -z "${INTERNAL_API_SECRET:-}" ]]; then
    echo "WARNING: INTERNAL_API_SECRET not found in either .env and not exported." >&2
    echo "         A NEW one will be generated — BOTH services must then be" >&2
    echo "         hydrated and restarted, or internal calls will 401." >&2
    export INTERNAL_API_SECRET="$(openssl rand -hex 32)"
  fi
}

# --------------------------------------------------------------------
# env_missing_keys <dir> — print each key declared in .env.example that
# is absent from .env, one per line. Silent (and success) when the
# directory has no .env.example, or when nothing is missing.
#
# Checks key PRESENCE, not values: a caller that hasn't sourced
# variables.sh can still use this to decide whether it needs to.
# --------------------------------------------------------------------
env_missing_keys() {
  local dir="$1"
  local example="${dir}/.env.example" target="${dir}/.env"
  [[ -f "$example" ]] || return 0
  [[ -f "$target" ]] || { echo "<no .env at all>"; return 0; }

  local key
  while IFS= read -r key; do
    grep -q "^[[:space:]]*${key}=" "$target" || echo "$key"
  done < <(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$example" \
             | tr -d ' =' | sort -u)
}

# --------------------------------------------------------------------
# hydrate_service_env <dir> <label> — back up the existing .env, rebuild
# it, and lock its permissions down. Never deletes a .env.
#
# chown only when running as root: server-setup.sh runs under sudo and
# must hand the file to APP_USER, whereas redeploy.sh already runs AS
# APP_USER, where a chown would fail for no benefit.
# --------------------------------------------------------------------
hydrate_service_env() {
  local dir="$1" label="$2"
  if [[ ! -d "$dir" ]]; then
    echo "--> ${label}: ${dir} does not exist — skipped"
    return 0
  fi
  if [[ -f "${dir}/.env" ]]; then
    local backup="${dir}/.env.backup-$(date +%Y%m%d-%H%M%S)"
    cp "${dir}/.env" "$backup"
    echo "--> ${label}: backed up existing .env -> ${backup}"
  fi
  hydrate_env_file "$dir"
  if [[ $EUID -eq 0 ]]; then
    chown "${APP_USER}:${APP_USER}" "${dir}/.env"
  fi
  chmod 600 "${dir}/.env"
  echo "--> ${label}: wrote ${dir}/.env ($(grep -c '^[A-Za-z_][A-Za-z0-9_]*=' "${dir}/.env") key(s))"
  warn_on_placeholder_values "$dir" "$label"
}

# A key added to .env.example but never exported by server-setup.sh, and
# never set in variables.sh, silently keeps the EXAMPLE's placeholder. The
# .env then has every key — so the missing-key check passes — and the app
# starts with a value like app.example.com.
#
# That is the shape of the two worst config failures here: analytics ran
# disabled for days because keys sat commented out, and a global PORT put
# deploy-service on api-service's port. Both were invisible until
# something downstream broke.
#
# Matches conventional placeholder markers rather than "value equals the
# example", because many keys legitimately match their example
# (TRAEFIK_DYNAMIC_DIR, SCALE_TO_ZERO_MODE, APP_DATA_ROOT all do).
# server-setup.md#placeholder-check
warn_on_placeholder_values() {
  local dir="$1" label="$2"
  local found
  found=$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=.*(example\.com|change-me|CHANGEME|203\.0\.113\.|your-|REPLACE_ME)' \
    "${dir}/.env" || true)
  [[ -z "$found" ]] && return 0

  echo ""
  echo "!! ${label}: .env still holds PLACEHOLDER values from .env.example:"
  echo "$found" | sed 's/^/!!   /'
  echo "!!"
  echo "!! That key is in .env.example but nothing supplies a real value."
  echo "!! Either export it in server-setup.sh (if it is computed) or set"
  echo "!! it in <env>.variables.sh (if it is a secret or a real URL)."
  echo ""
}
