#!/usr/bin/env bash
# apply-app-config.sh — re-push an app's CURRENT config, regenerating its
# Nomad job spec without its deploy token and without a rebuild.
#
#   sudo bash apply-app-config.sh prod <app> [app...]
#   sudo bash apply-app-config.sh prod --dry-run <app>
#
# Calls api-service's own applyCurrentConfig(), so env vars, custom domains,
# memory and image tag all come from its database — nothing is guessed and
# nothing is overwritten. The same function the dashboard's
# POST /env-vars/apply uses, which is company-scoped and therefore unusable
# for an app owned by someone else.
#
# Written for the /alloc/data -> /data migration: an app only picks up the
# bind mount when its spec is regenerated, which had not happened for apps
# last deployed before 2026-09-17. server-setup.md#apply-app-config

set -euo pipefail

APP_ENV="${1:-}"
shift || true
if [[ ! "$APP_ENV" =~ ^(test|demo|prod)$ ]]; then
  echo "Usage: sudo bash apply-app-config.sh <test|demo|prod> [--dry-run] <app> [app...]" >&2
  exit 2
fi

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; shift; fi
[[ $# -gt 0 ]] || { echo "ERROR: name at least one app." >&2; exit 2; }

APP_USER="${APP_USER:-ubuntu}"
APP_HOME="/home/${APP_USER}"
if [[ "$APP_ENV" == "prod" ]]; then PREFIX=""; else PREFIX="${APP_ENV}-"; fi
API_DIR="${APP_HOME}/${PREFIX}api-service"

[[ -f "${API_DIR}/dist/services/redeploy.js" ]] || {
  echo "ERROR: ${API_DIR}/dist/services/redeploy.js missing — build api-service first." >&2
  exit 1
}

echo "=================================================================="
echo " Re-applying stored config — environment: ${APP_ENV}"
echo " Apps: $*"
$DRY_RUN && echo " DRY RUN — reports what would be pushed, changes nothing"
echo "=================================================================="

# Runs as APP_USER from the api-service directory so dotenv, Prisma and the
# compiled code all resolve exactly as they do for the running service.
sudo -u "${APP_USER}" DRY_RUN="$DRY_RUN" APPS="$*" bash -c "cd '${API_DIR}' && node -e '
require(\"dotenv\").config();
const { PrismaClient } = require(\"@prisma/client\");
const { applyCurrentConfig } = require(\"./dist/services/redeploy\");
(async () => {
  const prisma = new PrismaClient();
  let failed = 0;
  for (const slug of process.env.APPS.split(/\\s+/).filter(Boolean)) {
    const p = await prisma.project.findFirst({ where: { slug } });
    if (!p) { console.log(\"  \" + slug + \": NOT FOUND in api-service\"); failed++; continue; }
    if (process.env.DRY_RUN === \"true\") {
      const d = p.currentDeploymentId
        ? await prisma.deployment.findFirst({ where: { id: p.currentDeploymentId } })
        : null;
      console.log(\"  \" + slug + \": would re-push image=\" + (d && d.imageTag ? d.imageTag : \"NONE\"));
      if (!d || !d.imageTag || d.status !== \"success\") failed++;
      continue;
    }
    const r = await applyCurrentConfig(p, \"config:apply-app-config.sh\");
    if (r.ok) console.log(\"  \" + slug + \": pushed, deployment \" + r.deployment.id);
    else { console.log(\"  \" + slug + \": FAILED (\" + r.code + \")\"); failed++; }
  }
  await prisma.\$disconnect();
  process.exit(failed > 0 ? 1 : 0);
})().catch((e) => { console.error(e.message); process.exit(1); });
'"

$DRY_RUN && exit 0

echo ""
echo "--> Waiting 35s for Nomad to place the new allocations"
sleep 35
echo "--> Result"
rc=0
for app in "$@"; do
  dd=$(sudo -u "${APP_USER}" bash -c "nomad job inspect '${app}'" 2>/dev/null \
        | jq -r '[.Job.TaskGroups[].Tasks[]|select(.Name=="server")|.Env.DATA_DIR]|first' 2>/dev/null || echo '?')
  code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 20 "https://${app}.app.${DOMAIN_ENV_SEGMENT:-}${DOMAIN:-embarko.ai}/" || echo 000)
  printf '    %-28s DATA_DIR=%-12s http=%s\n' "$app" "$dd" "$code"
  [[ "$dd" == "/data" ]] || rc=1
done

if [[ "$rc" -ne 0 ]]; then
  echo ""
  echo "!! At least one app is NOT on /data. Its old allocation directory is"
  echo "!! untouched, so nothing is lost — check the deployment status before"
  echo "!! re-running:  nomad job status <app>"
fi
exit "$rc"
