#!/usr/bin/env bash
# migrate-app-data.sh — one-time migration of every app's DATA_DIR from
# its Nomad allocation directory onto the host data root.
#
# Context: DATA_DIR used to be /alloc/data (inside the allocation, which
# Nomad garbage-collects with a stopped job). It is now a host bind mount
# at $APP_DATA_ROOT/<appName>, mounted into the container at /data — see
# deploy-service's nomad-job-spec.js and docs/scale-to-zero-gated-plan.md
# Step 0. The new mount only takes effect on an app's NEXT deploy, so
# existing data has to be carried across by hand: that is what this does.
#
#   sudo bash migrate-app-data.sh              # DRY RUN (default)
#   sudo bash migrate-app-data.sh --copy       # actually copy
#   sudo bash migrate-app-data.sh --verify     # re-check a finished copy
#
# NEVER deletes anything. The allocation directory is left exactly as it
# is, so a failed migration is always recoverable by simply not
# redeploying that app. Re-running is safe: an app whose destination
# already holds data is skipped, not overwritten (use --force only when
# you have decided the destination copy is the wrong one).
#
# ORDER MATTERS — read before running:
#   1. Run with --copy. Apps keep running and keep writing to their OLD
#      location; this is a point-in-time snapshot.
#   2. Redeploy each app. That is what switches it to the new mount.
#   3. Anything an app wrote BETWEEN the copy and its redeploy stayed in
#      the old location and is not in the new one.
# For a busy app, stop it first, run --copy, then redeploy — that window
# is then empty. For an idle app, copy-then-redeploy promptly is fine.
# Re-running --copy after stopping an app picks up the delta (rsync), so
# the safe sequence for anything with real traffic is:
#      --copy  ->  nomad job stop <app>  ->  --copy --force  ->  redeploy

set -euo pipefail

MODE="dry-run"
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --copy)    MODE="copy" ;;
    --verify)  MODE="verify" ;;
    --force)   FORCE=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

APP_ENV="${APP_ENV:-prod}"
APP_DATA_ROOT="${APP_DATA_ROOT:-/opt/embarko-appdata/${APP_ENV}}"
NOMAD_DATA_DIR="${NOMAD_DATA_DIR:-/opt/nomad/data}"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"

# Platform jobs, not customer apps — same exclusion the idle-report uses.
PLATFORM_JOBS="traefik"

if [[ "$MODE" != "dry-run" && "$EUID" -ne 0 ]]; then
  echo "ERROR: allocation directories are root-owned — run with sudo." >&2
  exit 1
fi
for tool in jq rsync curl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required." >&2; exit 1; }
done

echo "=================================================================="
echo " App data migration — mode: ${MODE}"
echo " Source : ${NOMAD_DATA_DIR}/alloc/<allocID>/alloc/data"
echo " Dest   : ${APP_DATA_ROOT}/<appName>"
echo "=================================================================="
echo ""

mkdir -p "${APP_DATA_ROOT}"

# A file-level fingerprint, so "it copied" is proven rather than assumed:
# a matching file count and byte total would still pass if content were
# corrupted, so this hashes every file and compares the sorted manifest.
fingerprint() {
  local dir="$1"
  ( cd "$dir" && find . -type f -exec md5sum {} + 2>/dev/null | sort -k2 ) || true
}

# The CURRENT allocation, not merely the newest directory on disk: an app
# that has been redeployed leaves older alloc dirs behind until Nomad GCs
# them, and copying one of those would silently restore stale data.
current_alloc_id() {
  local job="$1"
  curl -sf "${NOMAD_ADDR}/v1/job/$(printf '%s' "$job" | jq -sRr @uri)/allocations" \
    | jq -r '[.[] | select(.ClientStatus == "running")]
             | sort_by(.CreateIndex) | last | .ID // empty'
}

jobs_json=$(curl -sf "${NOMAD_ADDR}/v1/jobs") || {
  echo "ERROR: could not reach Nomad at ${NOMAD_ADDR}" >&2; exit 1; }

mapfile -t APPS < <(echo "$jobs_json" | jq -r '.[] | select(.Status=="running") | .ID' | sort)

migrated=0; skipped=0; failed=0; needs_attention=0

for app in "${APPS[@]}"; do
  [[ " $PLATFORM_JOBS " == *" $app "* ]] && continue

  alloc_id=$(current_alloc_id "$app")
  if [[ -z "$alloc_id" ]]; then
    printf '%-28s  no running allocation — SKIPPED\n' "$app"
    skipped=$((skipped+1)); continue
  fi

  src="${NOMAD_DATA_DIR}/alloc/${alloc_id}/alloc/data"
  dest="${APP_DATA_ROOT}/${app}"

  if [[ ! -d "$src" ]] || [[ -z "$(ls -A "$src" 2>/dev/null)" ]]; then
    printf '%-28s  no DATA_DIR content — nothing to migrate\n' "$app"
    skipped=$((skipped+1)); continue
  fi

  src_files=$(find "$src" -type f 2>/dev/null | wc -l | tr -d ' ')
  src_bytes=$(du -sb "$src" 2>/dev/null | cut -f1)

  if [[ "$MODE" == "verify" ]]; then
    if [[ ! -d "$dest" ]]; then
      printf '%-28s  MISSING at destination (%s files)\n' "$app" "$src_files"
      needs_attention=$((needs_attention+1)); continue
    fi
    if diff <(fingerprint "$src") <(fingerprint "$dest") >/dev/null; then
      printf '%-28s  OK — %s files, %s bytes, checksums match\n' "$app" "$src_files" "$src_bytes"
    else
      printf '%-28s  MISMATCH — source and destination differ\n' "$app"
      printf '%-28s     (expected if the app has been redeployed and has written since)\n' ""
      needs_attention=$((needs_attention+1))
    fi
    continue
  fi

  if [[ -d "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]] && [[ "$FORCE" != true ]]; then
    printf '%-28s  destination already has data — SKIPPED (use --force)\n' "$app"
    skipped=$((skipped+1)); continue
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    printf '%-28s  WOULD COPY %s files, %s bytes\n' "$app" "$src_files" "$src_bytes"
    printf '%-28s     %s\n' "" "$src -> $dest"
    migrated=$((migrated+1)); continue
  fi

  mkdir -p "$dest"
  # -a preserves timestamps/permissions; --delete is deliberately NOT
  # used, so this can never remove anything at the destination.
  if rsync -a "$src"/ "$dest"/; then
    # Same permissive mode deploy-service applies when it creates the
    # directory: Railpack images do not all run as root, and a container
    # that cannot write its own data directory fails at runtime.
    chmod 0777 "$dest"
    if diff <(fingerprint "$src") <(fingerprint "$dest") >/dev/null; then
      printf '%-28s  COPIED + VERIFIED — %s files, %s bytes\n' "$app" "$src_files" "$src_bytes"
      migrated=$((migrated+1))
    else
      printf '%-28s  COPIED BUT VERIFY FAILED — do NOT redeploy this app\n' "$app"
      failed=$((failed+1))
    fi
  else
    printf '%-28s  COPY FAILED\n' "$app"
    failed=$((failed+1))
  fi
done

echo ""
echo "=================================================================="
case "$MODE" in
  dry-run) echo " DRY RUN — nothing was copied. ${migrated} app(s) would migrate, ${skipped} skipped." ;;
  copy)    echo " ${migrated} migrated, ${skipped} skipped, ${failed} FAILED." ;;
  verify)  echo " ${needs_attention} app(s) need attention." ;;
esac
echo " Source allocation directories were NOT modified or deleted."
echo "=================================================================="
[[ "$failed" -gt 0 ]] && exit 1
exit 0
