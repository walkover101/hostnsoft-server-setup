#!/usr/bin/env bash
# scale-to-zero-soak.sh — Step 5 soak harness.
#
#   sudo bash scale-to-zero-soak.sh prod            # start
#   sudo bash scale-to-zero-soak.sh prod --remove   # stop, restore prod
#
# Adds the two things production deliberately lacks: synthetic traffic (the
# test app has no users, so it would stop once and never wake) and a
# 15-minute threshold via a systemd drop-in, for ~30 cycles a day instead
# of four. Both undone by --remove, without re-provisioning.
#
# Changes only the SCHEDULE and THRESHOLD — what may be stopped is still
# scale-to-zero-apps.js. See docs/scale-to-zero-gated-plan.md Step 5.

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

# systemctl cat, not `list-unit-files | grep -q`: under pipefail a matching
# grep -q closes the pipe and the pipeline reports SIGPIPE as failure.
if ! systemctl cat "${IDLE_UNIT}.timer" >/dev/null 2>&1; then
  echo "ERROR: ${IDLE_UNIT}.timer is not installed. Run server-setup.sh first." >&2
  exit 1
fi

# --- 1. shorten the idle threshold, via a drop-in ---------------------
mkdir -p "$DROPIN_DIR"
cat > "${DROPIN_DIR}/soak.conf" << 'EOF'
# Step 5 soak ONLY — removed by --remove. A drop-in, not a unit edit, so
# server-setup.sh cannot bake this test value into production.
[Service]
Environment=IDLE_THRESHOLD_MIN=15
EOF

# 45min against a 15min threshold: the app is reliably stopped first, so
# every request is a real cold start. --max-time 150 matches the wake
# timeout, so a curl giving up early cannot look like a failure.
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
# OnActiveSec (from timer start), not OnBootSec (from boot) — an OnBootSec
# deadline on a long-running box is already past and never fires.
OnActiveSec=1min
# OnUnitInactiveSec: this oneshot can run 150s, and measuring from when it
# FINISHED also gives the interval its intended meaning.
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
