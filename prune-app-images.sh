#!/usr/bin/env bash
# prune-app-images.sh — reclaim disk by removing old per-app build images.
#
#   sudo bash prune-app-images.sh             # DRY RUN (default)
#   sudo bash prune-app-images.sh --apply     # actually remove
#   KEEP=2 sudo bash prune-app-images.sh      # keep 2 instead of 3 per app
#
# Why this exists as a separate thing from deploy-service's own retention:
#
# deploy-service prunes an app's old images inside pruneOldImages(), which
# runs ONLY as part of a deploy. An app deployed once and never again is
# therefore never pruned — it keeps every image it has ever had, forever.
# Nomad's docker driver used to reap those as a side effect of collecting
# old allocations, but that had to be turned off (gc { image = false } in
# nomad.hcl) because it also deleted the image of any app scale-to-zero
# had STOPPED, leaving it unwakeable. Turning it off was correct and left
# this gap; this script is what fills it.
#
# Observed 2026-09-21: 92% of a 124GB disk, ~70 images, many over 1GB,
# one app holding five 1.07GB images. IMAGE_RETAIN_COUNT defaults to 5,
# which at ~1GB an image across 40 apps does not fit on this box.
#
# WHAT IS NEVER REMOVED, and why each matters:
#
#   1. Any image a RUNNING container is using. Removing it would not stop
#      the container now, but the app could not be restarted or
#      rescheduled afterwards.
#   2. Any image named in a SAVED JOB SPEC ($APP_DATA_ROOT/.specs/*.json).
#      This is the scale-to-zero wake path: those apps are stopped, so no
#      container references their image, and a naive "remove what nothing
#      is running" rule would delete exactly the images needed to bring
#      them back. That is the failure this platform already hit once, on
#      2026-09-18, and it presents as "pull access denied ... repository
#      does not exist", which reads like a registry problem and is not.
#   3. The newest $KEEP images per app, which is what one-click rollback
#      reaches back through.
#
# Anything it cannot determine, it skips. A skipped image costs disk; a
# wrongly removed one costs an app that cannot start and cannot be
# rebuilt without its source.

set -euo pipefail

APPLY=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

KEEP="${KEEP:-3}"
APP_ENV="${APP_ENV:-prod}"
APP_DATA_ROOT="${APP_DATA_ROOT:-/opt/embarko-appdata/${APP_ENV}}"
SPEC_DIR="${APP_DATA_ROOT}/.specs"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: run with sudo — docker and the spec directory need it." >&2
  exit 1
fi
command -v docker >/dev/null || { echo "ERROR: docker not found." >&2; exit 1; }

echo "=================================================================="
echo " App image retention — mode: $([[ "$APPLY" == true ]] && echo APPLY || echo DRY-RUN)"
echo " Keeping the newest ${KEEP} image(s) per app, plus anything in use"
echo " by a running container or named in ${SPEC_DIR}"
echo "=================================================================="
df -h / | tail -1
echo ""

# --- protected set -----------------------------------------------------
# Built BEFORE anything is removed and treated as absolute. Both sources
# are cheap and exact; neither involves guessing from image age.
PROTECTED=$(mktemp)
trap 'rm -f "$PROTECTED"' EXIT

docker ps --format '{{.Image}}' >> "$PROTECTED" 2>/dev/null || true
RUNNING_COUNT=$(wc -l < "$PROTECTED" | tr -d ' ')

# The saved specs are JSON from `nomad job inspect`; the image is at
# .Job.TaskGroups[].Tasks[].Config.image. grep rather than jq so a single
# malformed spec cannot abort the whole run and leave the disk full.
SPEC_COUNT=0
if [[ -d "$SPEC_DIR" ]]; then
  for spec in "$SPEC_DIR"/*.json; do
    [[ -e "$spec" ]] || continue
    grep -o '"image"[[:space:]]*:[[:space:]]*"[^"]*"' "$spec" \
      | sed 's/.*"\([^"]*\)"$/\1/' >> "$PROTECTED" || true
    SPEC_COUNT=$((SPEC_COUNT + 1))
  done
fi

sort -u -o "$PROTECTED" "$PROTECTED"
echo "--> Protected: ${RUNNING_COUNT} running container image(s), ${SPEC_COUNT} saved spec(s)"
echo "    $(wc -l < "$PROTECTED" | tr -d ' ') distinct image reference(s) will never be removed"
echo ""

# --- per-app retention -------------------------------------------------
# Grouped by repository (which is the app name) and ordered newest first,
# so "keep the newest KEEP" is per app rather than global — a rarely
# deployed app keeps its own history rather than being crowded out by a
# busy one.
removed=0
kept=0
skipped=0
freed_estimate=0

for repo in $(docker images --format '{{.Repository}}' | grep -v '^<none>$' | sort -u); do
  mapfile -t tags < <(docker images --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}' \
    | awk -v r="$repo" -F'\t' '$2 ~ "^"r":" {print}' \
    | sort -r \
    | cut -f2,3)

  index=0
  for entry in "${tags[@]}"; do
    ref="${entry%%	*}"
    size="${entry##*	}"
    index=$((index + 1))

    if [[ "$ref" == *":<none>" ]]; then
      skipped=$((skipped + 1)); continue
    fi
    if grep -qxF "$ref" "$PROTECTED"; then
      printf '  KEEP  %-52s %-8s (in use / saved spec)\n' "$ref" "$size"
      kept=$((kept + 1)); continue
    fi
    if [[ "$index" -le "$KEEP" ]]; then
      printf '  KEEP  %-52s %-8s (newest %s)\n' "$ref" "$size" "$index"
      kept=$((kept + 1)); continue
    fi

    if [[ "$APPLY" == true ]]; then
      if docker rmi "$ref" >/dev/null 2>&1; then
        printf '  GONE  %-52s %-8s\n' "$ref" "$size"
        removed=$((removed + 1))
      else
        # Almost always "image is referenced in multiple repositories" or
        # an in-use layer. Never fatal: a skipped image costs disk, a
        # failed run costs the rest of the cleanup.
        printf '  SKIP  %-52s %-8s (docker refused)\n' "$ref" "$size"
        skipped=$((skipped + 1))
      fi
    else
      printf '  WOULD REMOVE %-45s %-8s\n' "$ref" "$size"
      removed=$((removed + 1))
    fi
  done
done

echo ""
echo "=================================================================="
if [[ "$APPLY" == true ]]; then
  echo " ${removed} removed, ${kept} kept, ${skipped} skipped."
  df -h / | tail -1
else
  echo " DRY RUN — nothing was removed. ${removed} would go, ${kept} kept, ${skipped} skipped."
  echo " Re-run with --apply to actually remove them."
fi
echo "=================================================================="
