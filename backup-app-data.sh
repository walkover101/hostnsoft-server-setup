#!/usr/bin/env bash
# backup-app-data.sh — off-box backup of every app's DATA_DIR and the
# platform's own irreplaceable state, to NeevCloud S3 (Zata) via restic.
#
#   sudo -E bash backup-app-data.sh --check    # report only, touches nothing
#   sudo -E bash backup-app-data.sh            # DRY RUN (default)
#   sudo -E bash backup-app-data.sh --apply    # actually back up
#
# Run it the same way as every other script here:
#   source prod.set-env.sh && source prod.variables.sh
#   sudo -E bash backup-app-data.sh --check
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
#
# Until now DATA_DIR survived redeploys and nothing else. The public docs
# say so plainly: "durable against deploys, not against hardware loss".
# One disk failure destroyed every customer's data with no recovery path.
#
# ---------------------------------------------------------------------------
# WHY NOT NEEVCLOUD SNAPSHOTS
#
# NeevCloud snapshots are INSTANCE-level (VM memory + disk + components),
# and their own docs say they "are not a replacement for regular backups".
# Restoring one app would mean building a whole VM from a snapshot — not a
# restore path anyone will use at 3am. They are worth taking before risky
# maintenance; they are not this.
#
# restic gives what they cannot: per-file restore, encryption, dedup, and
# retention. NeevCloud documents restic against Zata S3 themselves.
#
# ---------------------------------------------------------------------------
# THE SQLITE PROBLEM, AND HOW THIS HANDLES IT
#
# Apps store SQLite under DATA_DIR. A live SQLite database is THREE files
# (db, -wal, -shm) that must be copied at ONE instant. Copy them at three
# different instants — which is exactly what walking a live directory
# does — and the result can restore as corrupt. Nothing warns you; you
# find out during the restore you were counting on.
#
# The fix is a point-in-time view of the filesystem. Two are possible here
# and the script picks whichever the box actually supports:
#
#   lvm     APP_DATA_ROOT sits on an LVM logical volume with free space in
#           its volume group. Snapshot it, mount read-only, back up from
#           the mount, release it. Crash-consistent, which is the bar that
#           matters — SQLite is designed to recover from crash-consistent
#           state exactly as it survives power loss.
#
#   stopped No LVM available. Back up only apps with NO running allocation
#           right now, because a stopped app is not writing and its files
#           are therefore already consistent. Running apps are REPORTED AS
#           DEFERRED, never copied live. This is safe rather than complete,
#           and on this platform it is far less lossy than it sounds:
#           scale-to-zero universal mode means most apps are stopped
#           overnight anyway, so a nightly run covers them within days.
#
# There is deliberately no "just copy it live" mode. A backup that might
# be corrupt is worse than none, because it is trusted.
#
# ---------------------------------------------------------------------------
# NEVER
#
#   - Deletes anything under APP_DATA_ROOT. It only reads.
#   - Copies a running app's data without a snapshot (see above).
#   - Runs as anything but root — LVM and the data tree both need it.

set -euo pipefail

MODE=dryrun
for arg in "$@"; do
  case "$arg" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    --dry-run) MODE=dryrun ;;
    *) echo "Unknown argument: $arg" >&2
       echo "Usage: sudo -E bash backup-app-data.sh [--check|--dry-run|--apply]" >&2
       exit 2 ;;
  esac
done

if [[ "$(id -u)" != "0" ]]; then
  echo "ERROR: must run as root (LVM and the app data tree both require it)." >&2
  exit 1
fi

: "${APP_ENV:?APP_ENV is not set — source <env>.set-env.sh and <env>.variables.sh first}"
: "${APP_DATA_ROOT:?APP_DATA_ROOT is not set — source <env>.variables.sh first}"

# restic's own configuration lives outside this repo, root-only, because it
# holds the S3 keys and the encryption password. NeevCloud's restic guide
# uses this same path. Expected contents:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export RESTIC_PASSWORD=...
#   export RESTIC_REPOSITORY=s3:https://idr01.zata.ai/<bucket>/<env>
#
# RESTIC_PASSWORD must ALSO be stored somewhere off this machine. Without
# it the backups are unreadable, which turns a disaster into a permanent
# one. That is the single most common way a restic setup fails in practice.
RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"

NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
SNAP_NAME="embarko-backup-${APP_ENV}"
SNAP_MOUNT="/mnt/${SNAP_NAME}"
SNAP_SIZE="${SNAP_SIZE:-5G}"     # CoW space, not a copy of the data
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

say() { echo "--> $*"; }
warn() { echo "!!  $*" >&2; }

# --------------------------------------------------------------------------
# What gets backed up besides app data. Each of these is irreplaceable and
# small; losing any of them is its own outage.
# --------------------------------------------------------------------------
PLATFORM_PATHS=()
add_platform_path() { [[ -e "$1" ]] && PLATFORM_PATHS+=("$1") || true; }
add_platform_path /opt/traefik/acme.json           # DNS-01 certs
add_platform_path /opt/traefik/acme-http.json      # HTTP-01 certs, custom domains
add_platform_path /opt/traefik/dynamic             # platform.yml + scale-to-zero.yml
add_platform_path "${ANALYTICS_DB_PATH:-/opt/hostnsoft-analytics/${APP_ENV}/analytics.db}"
# api-service's SQLite lives inside its checkout; APP_HOME is set by the
# setup script's environment, so only include it when we can see it.
if [[ -n "${APP_HOME:-}" ]]; then
  add_platform_path "${APP_HOME}/${APP_ENV}-api-service/prisma"
fi

# --------------------------------------------------------------------------
# Which consistency mechanism is available
# --------------------------------------------------------------------------
detect_snapshot_mode() {
  local src_dev lv_path
  if ! command -v lvcreate >/dev/null 2>&1; then
    echo "stopped"; return
  fi
  src_dev="$(findmnt -n -o SOURCE --target "$APP_DATA_ROOT" 2>/dev/null || true)"
  [[ -z "$src_dev" ]] && { echo "stopped"; return; }
  # An LVM LV reports as /dev/mapper/vg-lv and lvs can identify it.
  lv_path="$(lvs --noheadings -o lv_path "$src_dev" 2>/dev/null | tr -d ' ' || true)"
  [[ -z "$lv_path" ]] && { echo "stopped"; return; }
  echo "lvm"
}

vg_free_for() {
  local lv_path="$1" vg
  vg="$(lvs --noheadings -o vg_name "$lv_path" 2>/dev/null | tr -d ' ')"
  vgs --noheadings -o vg_free --units g "$vg" 2>/dev/null | tr -d ' '
}

# --------------------------------------------------------------------------
# Which apps are safe to read right now (only used in 'stopped' mode)
# --------------------------------------------------------------------------
running_app_names() {
  curl -sf "${NOMAD_ADDR}/v1/jobs" 2>/dev/null \
    | tr ',' '\n' \
    | grep -o '"ID":"[^"]*"' \
    | sed 's/"ID":"//;s/"//' \
    | sort -u || true
}

# --------------------------------------------------------------------------
# Preflight — every check that can fail, reported together rather than one
# per run. A backup you think is configured but is not is the worst state.
# --------------------------------------------------------------------------
PREFLIGHT_FAILED=false
preflight() {
  say "Environment      : ${APP_ENV}"
  say "App data root    : ${APP_DATA_ROOT}"

  if [[ ! -d "$APP_DATA_ROOT" ]]; then
    warn "APP_DATA_ROOT does not exist: ${APP_DATA_ROOT}"
    PREFLIGHT_FAILED=true
  else
    say "Apps present     : $(find "$APP_DATA_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)"
    say "App data size    : $(du -sxh "$APP_DATA_ROOT" 2>/dev/null | cut -f1)"
  fi

  if command -v restic >/dev/null 2>&1; then
    say "restic           : $(restic version 2>/dev/null | head -1)"
  else
    warn "restic is NOT installed. Install it before --apply."
    PREFLIGHT_FAILED=true
  fi

  if [[ -r "$RESTIC_ENV_FILE" ]]; then
    say "restic env       : ${RESTIC_ENV_FILE} (present)"
    # shellcheck disable=SC1090
    set +u; . "$RESTIC_ENV_FILE"; set -u
    for v in RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
      [[ -z "${!v:-}" ]] && { warn "${v} is not set in ${RESTIC_ENV_FILE}"; PREFLIGHT_FAILED=true; }
    done
    [[ -n "${RESTIC_REPOSITORY:-}" ]] && say "repository       : ${RESTIC_REPOSITORY}"
  else
    warn "${RESTIC_ENV_FILE} missing or unreadable. See the header of this script."
    PREFLIGHT_FAILED=true
  fi

  SNAPSHOT_MODE="$(detect_snapshot_mode)"
  if [[ "$SNAPSHOT_MODE" == "lvm" ]]; then
    local lv_path free
    lv_path="$(lvs --noheadings -o lv_path "$(findmnt -n -o SOURCE --target "$APP_DATA_ROOT")" | tr -d ' ')"
    free="$(vg_free_for "$lv_path")"
    say "Consistency      : LVM snapshot (${lv_path}, VG free ${free})"
    say "                   -> every app backed up consistently, running or not"
  else
    say "Consistency      : no LVM — falling back to STOPPED-APPS-ONLY"
    say "                   -> running apps are deferred, never copied live"
    say "                   -> re-run nightly; scale-to-zero stops most apps overnight"
  fi

  if [[ "${#PLATFORM_PATHS[@]}" -eq 0 ]]; then
    warn "No platform paths found (certs, analytics, prisma). Check the variables are sourced."
  else
    say "Platform paths   : ${#PLATFORM_PATHS[@]} found"
    for p in "${PLATFORM_PATHS[@]}"; do echo "                     ${p}"; done
  fi
}

# --------------------------------------------------------------------------
# Snapshot lifecycle. The trap matters: an LVM snapshot left behind fills
# its CoW space, goes invalid, and then quietly wedges the volume group.
# --------------------------------------------------------------------------
SNAP_CREATED=""
cleanup_snapshot() {
  [[ -z "$SNAP_CREATED" ]] && return 0
  mountpoint -q "$SNAP_MOUNT" && umount "$SNAP_MOUNT" || true
  lvremove -f "$SNAP_CREATED" >/dev/null 2>&1 || warn "could not remove snapshot ${SNAP_CREATED} — remove it by hand"
  SNAP_CREATED=""
}
trap cleanup_snapshot EXIT INT TERM

create_snapshot() {
  local src_dev lv_path
  src_dev="$(findmnt -n -o SOURCE --target "$APP_DATA_ROOT")"
  lv_path="$(lvs --noheadings -o lv_path "$src_dev" | tr -d ' ')"
  say "Creating LVM snapshot of ${lv_path} (${SNAP_SIZE} CoW)"
  lvremove -f "/dev/$(lvs --noheadings -o vg_name "$lv_path" | tr -d ' ')/${SNAP_NAME}" >/dev/null 2>&1 || true
  lvcreate -L "$SNAP_SIZE" -s -n "$SNAP_NAME" "$lv_path" >/dev/null
  SNAP_CREATED="/dev/$(lvs --noheadings -o vg_name "$lv_path" | tr -d ' ')/${SNAP_NAME}"
  mkdir -p "$SNAP_MOUNT"
  # -o ro,nouuid: read-only because we never write to it, nouuid because
  # XFS refuses to mount a snapshot whose UUID matches the live volume.
  mount -o ro,nouuid "$SNAP_CREATED" "$SNAP_MOUNT" 2>/dev/null \
    || mount -o ro "$SNAP_CREATED" "$SNAP_MOUNT"
  say "Snapshot mounted at ${SNAP_MOUNT}"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
preflight

if [[ "$MODE" == "check" ]]; then
  echo
  if $PREFLIGHT_FAILED; then
    say "CHECK FAILED — fix the items marked !! above before --apply."
    exit 1
  fi
  say "CHECK PASSED — safe to run --dry-run, then --apply."
  exit 0
fi

if $PREFLIGHT_FAILED; then
  warn "Refusing to continue: preflight failed. Run --check for the full list."
  exit 1
fi

# Build the list of paths to hand restic.
TARGETS=()
DEFERRED=()

if [[ "$SNAPSHOT_MODE" == "lvm" ]]; then
  [[ "$MODE" == "apply" ]] && create_snapshot
  # APP_DATA_ROOT may be a subdirectory of the snapshotted filesystem, so
  # map its path inside the mount rather than assuming it is the root.
  MP="$(findmnt -n -o TARGET --target "$APP_DATA_ROOT")"
  REL="${APP_DATA_ROOT#"$MP"}"
  TARGETS+=("${SNAP_MOUNT}${REL}")
else
  mapfile -t RUNNING < <(running_app_names)
  while IFS= read -r dir; do
    app="$(basename "$dir")"
    if printf '%s\n' "${RUNNING[@]:-}" | grep -qx "$app"; then
      DEFERRED+=("$app")
    else
      TARGETS+=("$dir")
    fi
  done < <(find "$APP_DATA_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)
  # Dot-directories (.specs, .scale-to-zero) are platform state, not an
  # app's data, and no app writes them mid-request — always safe to take.
  for d in "$APP_DATA_ROOT"/.[!.]*; do [[ -e "$d" ]] && TARGETS+=("$d"); done
fi

TARGETS+=("${PLATFORM_PATHS[@]}")

echo
say "Would back up ${#TARGETS[@]} path(s)"
for t in "${TARGETS[@]}"; do echo "      + ${t}"; done
if [[ "${#DEFERRED[@]}" -gt 0 ]]; then
  echo
  warn "DEFERRED ${#DEFERRED[@]} running app(s) — not copied live, will be taken once stopped:"
  for a in "${DEFERRED[@]}"; do echo "      ~ ${a}"; done
fi

if [[ "$MODE" == "dryrun" ]]; then
  echo
  say "DRY RUN — nothing was written. Re-run with --apply."
  exit 0
fi

# shellcheck disable=SC1090
set +u; . "$RESTIC_ENV_FILE"; set -u
export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

if ! restic cat config >/dev/null 2>&1; then
  say "Repository not initialised yet — running restic init"
  restic init
fi

say "Backing up"
restic backup \
  --tag "env:${APP_ENV}" \
  --tag "mode:${SNAPSHOT_MODE}" \
  --host "embarko-${APP_ENV}" \
  --exclude '*.sock' \
  --exclude '**/node_modules' \
  "${TARGETS[@]}"

say "Applying retention (daily ${KEEP_DAILY}, weekly ${KEEP_WEEKLY}, monthly ${KEEP_MONTHLY})"
restic forget \
  --host "embarko-${APP_ENV}" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune

say "Done. Latest snapshots:"
restic snapshots --host "embarko-${APP_ENV}" --latest 3
