#!/usr/bin/env bash
# restore-drill.sh — prove the backups are restorable. Read-only against
# production: it restores into a scratch directory and never touches
# APP_DATA_ROOT, any running app, or the repository's contents.
#
#   sudo -E bash restore-drill.sh                    # drill every app in the latest snapshot
#   sudo -E bash restore-drill.sh --app invoice-tool # drill one app
#   sudo -E bash restore-drill.sh --keep             # leave the restored copy for inspection
#   sudo -E bash restore-drill.sh --self-test        # ALSO prove the integrity check can fail
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS, AND WHY IT IS THE REAL DELIVERABLE
#
# A backup job that reports success every night proves only that a job ran.
# It does not prove the bytes are readable, that the encryption password
# still works, or — the one that actually bites — that the SQLite files
# inside are consistent rather than a torn copy taken mid-write.
#
# The only evidence that counts is a restore. This script is that evidence,
# and it is meant to run on a schedule, not once at setup.
#
# --self-test is not decoration. A check that never fails is
# indistinguishable from a check that cannot fail: the drill deliberately
# corrupts a COPY and confirms the verifier rejects it. Without that, a
# silently broken integrity check reports every restore as healthy.

set -euo pipefail

ONE_APP=""
KEEP=false
SELF_TEST=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) ONE_APP="${2:-}"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    --self-test) SELF_TEST=true; shift ;;
    *) echo "Unknown argument: $1" >&2
       echo "Usage: sudo -E bash restore-drill.sh [--app NAME] [--keep] [--self-test]" >&2
       exit 2 ;;
  esac
done

if [[ "$(id -u)" != "0" ]]; then
  echo "ERROR: must run as root (the backup contains root-owned files)." >&2
  exit 1
fi

: "${APP_ENV:?APP_ENV is not set — source <env>.set-env.sh and <env>.variables.sh first}"
: "${APP_DATA_ROOT:?APP_DATA_ROOT is not set — source <env>.variables.sh first}"

RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"
[[ -r "$RESTIC_ENV_FILE" ]] || { echo "ERROR: ${RESTIC_ENV_FILE} missing." >&2; exit 1; }
# shellcheck disable=SC1090
set +u; . "$RESTIC_ENV_FILE"; set -u
export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

SCRATCH="$(mktemp -d /var/tmp/restore-drill-XXXXXX)"
cleanup() { $KEEP || rm -rf "$SCRATCH"; }
trap cleanup EXIT

say()  { echo "--> $*"; }
pass() { echo "    PASS  $*"; }
fail() { echo "    FAIL  $*" >&2; FAILURES=$((FAILURES+1)); }
FAILURES=0
DB_COUNT=0

# ---------------------------------------------------------------------------
# 1. The repository is readable at all
# ---------------------------------------------------------------------------
say "Checking repository is readable"
if restic cat config >/dev/null 2>&1; then
  pass "repository opened (password and S3 credentials are valid)"
else
  echo "FAIL: cannot open the repository. Password or credentials are wrong," >&2
  echo "      or the bucket is unreachable. Nothing else can be trusted." >&2
  exit 1
fi

LATEST="$(restic snapshots --host "embarko-${APP_ENV}" --latest 1 --json 2>/dev/null \
  | grep -o '"short_id":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//')"
[[ -z "$LATEST" ]] && { echo "FAIL: no snapshots for host embarko-${APP_ENV}." >&2; exit 1; }
say "Latest snapshot: ${LATEST}"

# How old is it? A backup that silently stopped running three weeks ago is
# the most common failure of all, and it looks exactly like success.
SNAP_TIME="$(restic snapshots --host "embarko-${APP_ENV}" --latest 1 --json 2>/dev/null \
  | grep -o '"time":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//')"
if [[ -n "$SNAP_TIME" ]]; then
  age_h=$(( ( $(date +%s) - $(date -d "$SNAP_TIME" +%s 2>/dev/null || echo 0) ) / 3600 ))
  if [[ "$age_h" -gt 48 ]]; then
    fail "latest backup is ${age_h}h old — the schedule is not running"
  else
    pass "latest backup is ${age_h}h old"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Restore
# ---------------------------------------------------------------------------
if [[ -n "$ONE_APP" ]]; then
  say "Restoring ${ONE_APP} into ${SCRATCH}"
  restic restore "$LATEST" --target "$SCRATCH" --include "${APP_DATA_ROOT}/${ONE_APP}" >/dev/null
else
  say "Restoring all app data into ${SCRATCH}"
  restic restore "$LATEST" --target "$SCRATCH" --include "${APP_DATA_ROOT}" >/dev/null
fi

RESTORED_ROOT="${SCRATCH}${APP_DATA_ROOT}"
if [[ ! -d "$RESTORED_ROOT" ]]; then
  echo "FAIL: restore produced nothing at ${RESTORED_ROOT}." >&2
  exit 1
fi
pass "restore completed ($(du -sh "$RESTORED_ROOT" 2>/dev/null | cut -f1))"

# ---------------------------------------------------------------------------
# 3. Every SQLite file in the restore must pass integrity_check
#
# This is the step that catches a torn copy. A database copied mid-write
# usually still OPENS — it fails here, not on open, which is why "the app
# started fine" is not evidence of a good backup.
# ---------------------------------------------------------------------------
if ! command -v sqlite3 >/dev/null 2>&1; then
  fail "sqlite3 is not installed — cannot verify database integrity (apt-get install -y sqlite3)"
else
  say "Verifying SQLite integrity"
  while IFS= read -r db; do
    # Identify by magic header rather than extension: apps name their
    # databases anything at all (data.db, store.sqlite, app.db3, no
    # extension whatsoever).
    head -c 15 "$db" 2>/dev/null | grep -q 'SQLite format 3' || continue
    DB_COUNT=$((DB_COUNT+1))
    result="$(sqlite3 "file:${db}?immutable=1" 'PRAGMA integrity_check;' 2>&1 | head -1 || echo 'unreadable')"
    if [[ "$result" == "ok" ]]; then
      pass "$(basename "$(dirname "$db")")/$(basename "$db")"
    else
      fail "$(basename "$(dirname "$db")")/$(basename "$db") -> ${result}"
    fi
  done < <(find "$RESTORED_ROOT" -type f -size +0c 2>/dev/null)

  if [[ "$DB_COUNT" -eq 0 ]]; then
    say "No SQLite databases found in the restore (fine if no app uses one yet)"
  else
    say "Checked ${DB_COUNT} database(s)"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Self-test: prove the verifier can actually fail
# ---------------------------------------------------------------------------
if $SELF_TEST; then
  say "Self-test: corrupting a COPY to confirm the check rejects it"
  victim="$(find "$RESTORED_ROOT" -type f -size +4096c 2>/dev/null | while read -r f; do
      head -c 15 "$f" | grep -q 'SQLite format 3' && { echo "$f"; break; }; done)"
  if [[ -z "$victim" ]]; then
    say "  (skipped — no SQLite database large enough in this restore)"
  else
    cp "$victim" "${SCRATCH}/selftest.db"
    # Overwrite a page well past the header: a corrupt header would fail to
    # OPEN, which is a weaker result. This forces integrity_check itself to
    # be the thing that catches it.
    dd if=/dev/urandom of="${SCRATCH}/selftest.db" bs=1 seek=3000 count=400 conv=notrunc status=none
    r="$(sqlite3 "file:${SCRATCH}/selftest.db?immutable=1" 'PRAGMA integrity_check;' 2>&1 | head -1 || echo 'unreadable')"
    if [[ "$r" == "ok" ]]; then
      fail "self-test: corrupted database still reported ok — THE CHECK IS NOT WORKING"
    else
      pass "self-test: corruption correctly detected (${r})"
    fi
    rm -f "${SCRATCH}/selftest.db"
  fi
fi

# ---------------------------------------------------------------------------
echo
if [[ "$FAILURES" -eq 0 ]]; then
  say "DRILL PASSED — ${DB_COUNT} database(s) verified from snapshot ${LATEST}"
  $KEEP && say "Restored copy kept at ${SCRATCH}"
  exit 0
else
  say "DRILL FAILED — ${FAILURES} problem(s) above. Do not trust these backups."
  $KEEP && say "Restored copy kept at ${SCRATCH}"
  exit 1
fi
