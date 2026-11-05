#!/usr/bin/env bash
#
# tunnel-watchdog-setup.sh: deploy the tunnel health watchdog.
# See docs/apps/cloudflare-tunnel-README.md.

# An operator agent, not a root daemon: msmtp refuses a config file the
# invoking user does not own, so root could not send the alert.

# Usage: sudo ./tunnel-watchdog-setup.sh
# Needs msmtp-setup.sh and cloudflared-setup.sh done, and operator logged in.

# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-11-05

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "❌ This script requires sudo privileges (it writes to the operator account)"
  echo "   Run: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
CONFIG_FILE="${SCRIPT_DIR}/config/config.conf"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "❌ Configuration file not found at ${CONFIG_FILE}"
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

HOSTNAME_VALUE="${HOSTNAME_OVERRIDE:-${SERVER_NAME:-$(hostname -s)}}"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME_VALUE}")"
OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
OPERATOR_HOME="/Users/${OPERATOR_USERNAME}"
MONITORING_EMAIL="${MONITORING_EMAIL:-}"
EXTERNAL_HOSTNAME="${EXTERNAL_HOSTNAME:-}"
# Same default and check as cloudflared-setup.sh: the watchdog must probe the
# port the daemon was given.
TUNNEL_METRICS_PORT="${TUNNEL_METRICS_PORT:-20241}"

# Every value below is substituted into the watchdog with sed, using | as the
# delimiter, so each is checked against a strict pattern first.
if [[ ! "${MONITORING_EMAIL}" =~ ^[^@|[:space:]]+@[^@|[:space:]]+$ ]] \
  || [[ "${MONITORING_EMAIL}" == "your-email@example.com" ]]; then
  echo "❌ MONITORING_EMAIL is not set to a real address in ${CONFIG_FILE}"
  exit 1
fi
if [[ ! "${EXTERNAL_HOSTNAME}" =~ ^[a-z0-9.-]+$ ]]; then
  echo "❌ EXTERNAL_HOSTNAME is required in ${CONFIG_FILE} (e.g. tilsit.vip)"
  exit 1
fi
if [[ ! "${OPERATOR_USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "❌ OPERATOR_USERNAME has an unexpected format: '${OPERATOR_USERNAME}'"
  exit 1
fi
if [[ ! "${TUNNEL_METRICS_PORT}" =~ ^[0-9]+$ ]] || [[ "${TUNNEL_METRICS_PORT}" -lt 1024 ]] \
  || [[ "${TUNNEL_METRICS_PORT}" -gt 65535 ]]; then
  echo "❌ TUNNEL_METRICS_PORT must be a port number from 1024 to 65535 (got '${TUNNEL_METRICS_PORT}')"
  exit 1
fi

if ! OPERATOR_UID=$(id -u "${OPERATOR_USERNAME}" 2>/dev/null); then
  echo "❌ Operator user '${OPERATOR_USERNAME}' not found"
  exit 1
fi

if [[ ! -f "${OPERATOR_HOME}/.config/msmtp/config" ]]; then
  echo "❌ msmtp is not configured for ${OPERATOR_USERNAME}. Run msmtp-setup.sh first."
  exit 1
fi

for tpl in tunnel-watchdog.sh alert-lib.sh com.tunnel-watchdog.plist; do
  if [[ ! -f "${TEMPLATE_DIR}/${tpl}" ]]; then
    echo "❌ Template not found: ${TEMPLATE_DIR}/${tpl}"
    exit 1
  fi
done

CONFIG_DIR="${OPERATOR_HOME}/.config/tunnel-watchdog"
WATCHDOG_DEST="${OPERATOR_HOME}/.local/bin/tunnel-watchdog"
ALERT_LIB_DEST="${OPERATOR_HOME}/.local/lib/alert-lib.sh"
LAUNCHAGENT_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
LABEL="com.${HOSTNAME_LOWER}.tunnel-watchdog"
PLIST_DEST="${LAUNCHAGENT_DIR}/${LABEL}.plist"
WATCHDOG_LOG="${OPERATOR_HOME}/.local/state/tunnel-watchdog.log"

echo "🚇 Deploying the Cloudflare Tunnel health watchdog for ${EXTERNAL_HOSTNAME}"
echo "=================================================="

# Directories, owned by operator. Run mkdir as operator, so any parent it
# creates is operator's too.
for dir in "${CONFIG_DIR}" "$(dirname "${WATCHDOG_DEST}")" "$(dirname "${ALERT_LIB_DEST}")" \
  "${LAUNCHAGENT_DIR}" "$(dirname "${WATCHDOG_LOG}")"; do
  sudo -u "${OPERATOR_USERNAME}" mkdir -p "${dir}"
done
chmod 700 "${CONFIG_DIR}"

# Shared alert library
cp "${TEMPLATE_DIR}/alert-lib.sh" "${ALERT_LIB_DEST}"
chown "${OPERATOR_USERNAME}:staff" "${ALERT_LIB_DEST}"
chmod 644 "${ALERT_LIB_DEST}"
echo "✓ alert-lib.sh deployed to ${ALERT_LIB_DEST}"

# Watchdog
sed \
  -e "s|__HOSTNAME__|${HOSTNAME_VALUE}|g" \
  -e "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" \
  -e "s|__OPERATOR_USERNAME__|${OPERATOR_USERNAME}|g" \
  -e "s|__MONITORING_EMAIL__|${MONITORING_EMAIL}|g" \
  -e "s|__EXTERNAL_HOSTNAME__|${EXTERNAL_HOSTNAME}|g" \
  -e "s|__TUNNEL_METRICS_PORT__|${TUNNEL_METRICS_PORT}|g" \
  "${TEMPLATE_DIR}/tunnel-watchdog.sh" >"${WATCHDOG_DEST}"
chown "${OPERATOR_USERNAME}:staff" "${WATCHDOG_DEST}"
chmod 700 "${WATCHDOG_DEST}"
echo "✓ Watchdog deployed to ${WATCHDOG_DEST}"

# LaunchAgent plist
sed \
  -e "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" \
  -e "s|__OPERATOR_USERNAME__|${OPERATOR_USERNAME}|g" \
  "${TEMPLATE_DIR}/com.tunnel-watchdog.plist" >"${PLIST_DEST}"
chown "${OPERATOR_USERNAME}:staff" "${PLIST_DEST}"
chmod 644 "${PLIST_DEST}"
if ! plutil -lint "${PLIST_DEST}" >/dev/null 2>&1; then
  echo "❌ Invalid plist syntax — launchd will reject ${PLIST_DEST}"
  plutil -lint "${PLIST_DEST}"
  exit 1
fi
echo "✓ LaunchAgent written to ${PLIST_DEST}"

if grep -q '__[A-Z_]*__' "${WATCHDOG_DEST}" "${PLIST_DEST}"; then
  echo "❌ Unsubstituted placeholders in the deployed files:"
  grep -n '__[A-Z_]*__' "${WATCHDOG_DEST}" "${PLIST_DEST}"
  exit 1
fi

# --check as operator in launchd's environment (sudo -u, not -iu: a login
# shell adds Homebrew). No email, no state change.
echo
echo "Checking the tunnel now (as ${OPERATOR_USERNAME}, launchd environment)..."
check_rc=0
sudo -u "${OPERATOR_USERNAME}" /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME="${OPERATOR_HOME}" \
  /bin/bash -c 'cd "${HOME}" && exec /bin/bash "$1" --check' _ "${WATCHDOG_DEST}" || check_rc=$?
if [[ ${check_rc} -ne 0 ]]; then
  echo
  echo "❌ The tunnel is not ready (exit ${check_rc}). The LaunchAgent was NOT loaded."
  echo "   Check the daemon: sudo launchctl print system/com.${HOSTNAME_LOWER}.cloudflare-tunnel"
  echo "   Then re-run this script."
  exit 1
fi

# (Re)load the LaunchAgent in operator's GUI domain.
SERVICE_TARGET="gui/${OPERATOR_UID}/${LABEL}"
if launchctl print "${SERVICE_TARGET}" >/dev/null 2>&1; then
  echo "↻ Reloading existing agent (${SERVICE_TARGET})"
  launchctl bootout "${SERVICE_TARGET}" 2>/dev/null || true
fi
if ! launchctl bootstrap "gui/${OPERATOR_UID}" "${PLIST_DEST}"; then
  echo "❌ launchctl bootstrap failed. Is ${OPERATOR_USERNAME} logged in?"
  echo "   Retry: sudo launchctl bootstrap gui/${OPERATOR_UID} ${PLIST_DEST}"
  exit 1
fi
echo "✓ Agent loaded: ${SERVICE_TARGET}"

echo
echo "🚀 Setup complete."
echo
echo "Commands:"
echo "  Check now:  sudo -H -u ${OPERATOR_USERNAME} /bin/bash ${WATCHDOG_DEST} --check"
echo "  Run now:    sudo launchctl kickstart -kp ${SERVICE_TARGET}"
echo "  Log:        tail -f ${WATCHDOG_LOG}"
echo "  State:      sudo cat ${CONFIG_DIR}/state.json"
