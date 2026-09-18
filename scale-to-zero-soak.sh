#!/usr/bin/env bash
# scale-to-zero-soak.sh — Step 5 of docs/scale-to-zero-gated-plan.md.
#
#   sudo bash scale-to-zero-soak.sh prod            # start the soak
#   sudo bash scale-to-zero-soak.sh prod --remove   # stop it, restore prod settings
#
# Step 5 asks for the mechanism to cycle idle -> stop -> request -> wake ->
# serve -> idle unattended for 24-48h. Two things are needed that the
# production setup deliberately does NOT provide:
#
#   1. TRAFFIC. scale-to-zero-test-1 has no real users, so on a schedule it
#      would stop once and stay stopped forever — exercising the stop path
#      and never the wake path, which is the half that can lose data.
#      This installs a timer that requests it periodically.
#
#   2. A SHORT THRESHOLD. The production threshold is 6 hours, chosen to
#      keep stops out of working hours. At 6h a 24h soak yields about four
#      cycles, which is far too few to shake out a race. A drop-in
#      overrides it to 15 minutes for the idle watcher, giving ~30 cycles a
#      day.
#
# Both are deliberately temporary and both are undone by --remove. The
# override is a systemd drop-in rather than an edit to the unit file, so
# the next server-setup.sh run cannot silently bake the test threshold
# into production — and --remove restores the real value without needing
# to re-provision.
#
# SAFETY: this changes only the SCHEDULE and the THRESHOLD. What may be
# stopped is still governed entirely by STOPPABLE_APPS, the frozen list
# hardcoded in deploy-service/idle-report.js. A 15-minute threshold makes
# nearly every app on the box report as idle — and every one of them that
# is not on that list is still left running. That is the property the soak
# is partly there to test.

set -euo pipefail

APP_ENV="${1:-}"
if [[ ! "$APP_ENV" =~ ^(test|demo|prod)$ ]]; then
  echo "Usage: sudo bash scale-to-zero-soak.sh <test|demo|prod> [--remove]" >&2
  exit 2
fi
ACTION="${2:-install}"

if [[ "$(id -u)" != "0" ]]; then
  echo "ERROR: run with sudo — this writes systemd units under /etc." >&2
  exit 1
fi

APP_USER="${APP_USER:-ubuntu}"
TEST_APP="scale-to-zero-test-1"

IDLE_UNIT="embarko-idle-${APP_ENV}"
SOAK_UNIT="embarko-s2z-soak-${APP_ENV}"
DROPIN_DIR="/etc/systemd/system/${IDLE_UNIT}.service.d"

# Must match APPS_DOMAIN_SUFFIX for this environment. Derived the same way
# server-setup.sh derives it, so the two cannot drift.
DOMAIN="${DOMAIN:-embarko.ai}"
if [[ "$APP_ENV" == "prod" ]]; then DOMAIN_ENV_SEGMENT=""; else DOMAIN_ENV_SEGMENT="${APP_ENV}."; fi
TEST_URL="https://${TEST_APP}.app.${DOMAIN_ENV_SEGMENT}${DOMAIN}/"

if [[ "$ACTION" == "--remove" ]]; then
  echo "--> Removing the soak and restoring production settings"
  systemctl disable --now "${SOAK_UNIT}.timer" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SOAK_UNIT}.timer" "/etc/systemd/system/${SOAK_UNIT}.service"
  rm -rf "$DROPIN_DIR"
  systemctl daemon-reload
  systemctl restart "${IDLE_UNIT}.timer"
  echo "    Idle watcher threshold is back to the value in its unit file:"
  systemctl show "${IDLE_UNIT}.service" -p Environment
  echo "    Soak removed. The test app is left exactly as it is — nothing is deleted."
  exit 0
fi

echo "=================================================================="
echo " Starting the scale-to-zero soak — environment: ${APP_ENV}"
echo " Test app : ${TEST_APP}"
echo " URL      : ${TEST_URL}"
echo " Threshold: 15 min (overridden; production value is restored by --remove)"
echo "=================================================================="

# `systemctl cat`, NOT `systemctl list-unit-files | grep -q`. Under
# `set -o pipefail`, `grep -q` exiting the instant it matches closes the
# pipe, the still-writing upstream command takes SIGPIPE and exits 141,
# and the PIPELINE reports 141 — so a successful match reads as a failure.
# list-unit-files emits hundreds of lines and this unit sorts early, so
# grep bails almost immediately with plenty left to write. That made this
# check fail intermittently and then permanently (2026-09-18), reporting
# a timer that was installed and running as missing.
if ! systemctl cat "${IDLE_UNIT}.timer" >/dev/null 2>&1; then
  echo "ERROR: ${IDLE_UNIT}.timer is not installed. Run server-setup.sh first." >&2
  exit 1
fi

# --- 1. shorten the idle threshold, via a drop-in ---------------------
mkdir -p "$DROPIN_DIR"
cat > "${DROPIN_DIR}/soak.conf" << 'EOF'
# Step 5 soak ONLY. Installed by scale-to-zero-soak.sh, removed by its
# --remove. A drop-in rather than an edit to the unit file so that
# server-setup.sh regenerating that file cannot bake this test value into
# production, and so removing it restores the real threshold with no
# re-provision.
[Service]
Environment=IDLE_THRESHOLD_MIN=15
EOF

# --- 2. synthetic traffic --------------------------------------------
# Every 45 minutes against a 15-minute threshold: long enough that the app
# is reliably stopped before each request (so every request is a real cold
# start, not a no-op against a running app), short enough for ~30 full
# cycles a day.
#
# --max-time 150 matches the activator's own wake timeout plus headroom:
# the request SHOULD be held through the cold start, and a curl that gave
# up early would look like a failure that never happened.
#
# The status code and total time go to the journal, so `journalctl -u` is a
# complete record of every cycle's outcome and latency afterwards.
cat > "/etc/systemd/system/${SOAK_UNIT}.service" << EOF
[Unit]
Description=Embarko scale-to-zero soak — request the test app to force a wake (${APP_ENV})
After=network.target

[Service]
Type=oneshot
User=${APP_USER}
ExecStart=/usr/bin/curl -sS -o /dev/null -w "soak: status=%{http_code} total=%{time_total}s\\n" --max-time 150 ${TEST_URL}
EOF

cat > "/etc/systemd/system/${SOAK_UNIT}.timer" << EOF
[Unit]
Description=Request ${TEST_APP} every 45 minutes to exercise wake-on-request (${APP_ENV})

[Timer]
# OnActiveSec, NOT OnBootSec: OnBootSec is measured from BOOT, so on a box
# that booted days ago its deadline is permanently in the past and never
# produces a future trigger. Combined with the OnUnitInactiveSec below —
# which needs a run inside THIS timer unit's lifetime to chain from, and
# has none on a freshly installed unit — the timer ends up with no next
# elapse at all: `systemctl list-timers` shows "n/a" and it never fires.
# Seen exactly that way on 2026-09-18, including after a reinstall, since
# removing the unit wipes systemd's record of the earlier run (the journal
# line survives, which makes it look like the timer is still anchored).
#
# OnActiveSec is relative to when the TIMER starts, so installing it always
# produces a first run, whether that is now or at boot.
OnActiveSec=1min
# OnUnitInactiveSec, NOT OnUnitActiveSec: this service is Type=oneshot and
# a single run can last up to 150s (it holds the connection through a cold
# start). OnUnitActiveSec measures from the moment the unit went active,
# which for a long-running oneshot leaves systemd with no next elapse to
# compute while it is still running — `systemctl list-timers` shows "n/a"
# and the timer fires once and never again. Seen exactly that way on
# 2026-09-18. Measuring from when the last run FINISHED also gives the
# interval its intended meaning: 45 minutes of genuine idleness after a
# request, comfortably past the 15-minute threshold.
OnUnitInactiveSec=45min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl restart "${IDLE_UNIT}.timer"
systemctl enable --now "${SOAK_UNIT}.timer"

echo
echo "Soak running. Watch it with:"
echo "  systemctl list-timers | grep embarko"
echo "  journalctl -u ${SOAK_UNIT}.service --since today | grep soak:"
echo "  journalctl -u ${IDLE_UNIT}.service --since today | grep -E 'stopped|ABORT|snapshot'"
echo
echo "Every 'soak:' line should read status=200. A 502 is the Traefik"
echo "blackout window (a request landing in the seconds after a stop) and"
echo "is the single most important thing this soak exists to measure —"
echo "count them against the total number of cycles."
echo
echo "Stop the soak and restore production settings with:"
echo "  sudo bash scale-to-zero-soak.sh ${APP_ENV} --remove"
