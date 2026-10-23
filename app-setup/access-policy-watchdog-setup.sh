#!/usr/bin/env bash
#
# access-policy-watchdog-setup.sh: deploy the Access policy-drift watchdog.
# See "Drift watchdog" in docs/apps/cloudflare-tunnel-README.md.

# An operator agent, not a root daemon: msmtp refuses a config file the
# invoking user does not own, so root could not send the alert.

# Usage: sudo ./access-policy-watchdog-setup.sh
# Needs msmtp-setup.sh done, the keychain token, and operator logged in.

# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-10-22

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "❌ This script requires sudo privileges (it reads the System keychain)"
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
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
CLOUDFLARE_ACCESS_APP_ID="${CLOUDFLARE_ACCESS_APP_ID:-}"
CLOUDFLARE_ACCESS_POLICY_ID="${CLOUDFLARE_ACCESS_POLICY_ID:-}"
CLOUDFLARE_ACCESS_IDP_ID="${CLOUDFLARE_ACCESS_IDP_ID:-}"
ACCESS_ALLOWED_EMAIL="${ACCESS_ALLOWED_EMAIL:-}"

# Every value below is substituted into the watchdog with sed, using | as the
# delimiter, so each is checked against a strict pattern first.
missing=()
check_value() {
  local name="$1" pattern="$2" value="${!1:-}"
  if [[ -z "${value}" ]]; then
    missing+=("${name} (not set)")
  elif [[ ! "${value}" =~ ${pattern} ]]; then
    missing+=("${name} (unexpected format: '${value}')")
  fi
}
ID_PATTERN='^[A-Za-z0-9-]+$'
check_value MONITORING_EMAIL '^[^@|[:space:]]+@[^@|[:space:]]+$'
check_value EXTERNAL_HOSTNAME '^[a-z0-9.-]+$'
check_value CLOUDFLARE_ACCOUNT_ID "${ID_PATTERN}"
check_value CLOUDFLARE_ACCESS_APP_ID "${ID_PATTERN}"
check_value CLOUDFLARE_ACCESS_POLICY_ID "${ID_PATTERN}"
check_value CLOUDFLARE_ACCESS_IDP_ID "${ID_PATTERN}"
check_value ACCESS_ALLOWED_EMAIL '^[^@|[:space:]]+@[^@|[:space:]]+$'
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "❌ Fix these values in ${CONFIG_FILE}:"
  for m in "${missing[@]}"; do
    echo "   ${m}"
  done
  exit 1
fi
if [[ "${MONITORING_EMAIL}" == "your-email@example.com" ]]; then
  echo "❌ MONITORING_EMAIL is still the template default in ${CONFIG_FILE}"
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

for tpl in access-policy-watchdog.sh alert-lib.sh com.access-policy-watchdog.plist; do
  if [[ ! -f "${TEMPLATE_DIR}/${tpl}" ]]; then
    echo "❌ Template not found: ${TEMPLATE_DIR}/${tpl}"
    exit 1
  fi
done

CONFIG_DIR="${OPERATOR_HOME}/.config/access-policy-watchdog"
TOKEN_FILE="${CONFIG_DIR}/token"
WATCHDOG_DEST="${OPERATOR_HOME}/.local/bin/access-policy-watchdog"
ALERT_LIB_DEST="${OPERATOR_HOME}/.local/lib/alert-lib.sh"
LAUNCHAGENT_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
LABEL="com.${HOSTNAME_LOWER}.access-policy-watchdog"
PLIST_DEST="${LAUNCHAGENT_DIR}/${LABEL}.plist"
WATCHDOG_LOG="${OPERATOR_HOME}/.local/state/access-policy-watchdog.log"

echo "🔒 Deploying the Access policy-drift watchdog for ${EXTERNAL_HOSTNAME}"
echo "=================================================="

# Directories, owned by operator. Run mkdir as operator, so any parent it
# creates is operator's too.
for dir in "${CONFIG_DIR}" "$(dirname "${WATCHDOG_DEST}")" "$(dirname "${ALERT_LIB_DEST}")" \
  "${LAUNCHAGENT_DIR}" "$(dirname "${WATCHDOG_LOG}")"; do
  sudo -u "${OPERATOR_USERNAME}" mkdir -p "${dir}"
done
chmod 700 "${CONFIG_DIR}"

# API token: keychain → operator file (600), by redirect only, never an
# argument. umask 077 keeps the temp file private from the start.
token_tmp=$(umask 077 && mktemp "${CONFIG_DIR}/token.XXXXXX")
trap 'rm -f "${token_tmp:-}"' EXIT
if ! security find-generic-password \
  -s "cloudflare-access-readonly-token" \
  -a "${EXTERNAL_HOSTNAME}" \
  -w \
  /Library/Keychains/System.keychain >"${token_tmp}" 2>/dev/null \
  || [[ ! -s "${token_tmp}" ]]; then
  echo "❌ Keychain item not found or empty:"
  echo "   service=cloudflare-access-readonly-token account=${EXTERNAL_HOSTNAME}"
  echo "   (System keychain). See \"Drift watchdog\" in docs/apps/cloudflare-tunnel-README.md."
  exit 1
fi
chown "${OPERATOR_USERNAME}:staff" "${token_tmp}"
chmod 600 "${token_tmp}"
mv "${token_tmp}" "${TOKEN_FILE}"
echo "✓ API token stored at ${TOKEN_FILE} (mode 600, owner ${OPERATOR_USERNAME})"

# Shared alert library
cp "${TEMPLATE_DIR}/alert-lib.sh" "${ALERT_LIB_DEST}"
chown "${OPERATOR_USERNAME}:staff" "${ALERT_LIB_DEST}"
chmod 644 "${ALERT_LIB_DEST}"
echo "✓ alert-lib.sh deployed to ${ALERT_LIB_DEST}"

# Watchdog
sed \
  -e "s|__HOSTNAME__|${HOSTNAME_VALUE}|g" \
  -e "s|__MONITORING_EMAIL__|${MONITORING_EMAIL}|g" \
  -e "s|__EXTERNAL_HOSTNAME__|${EXTERNAL_HOSTNAME}|g" \
  -e "s|__CLOUDFLARE_ACCOUNT_ID__|${CLOUDFLARE_ACCOUNT_ID}|g" \
  -e "s|__CLOUDFLARE_ACCESS_APP_ID__|${CLOUDFLARE_ACCESS_APP_ID}|g" \
  -e "s|__CLOUDFLARE_ACCESS_POLICY_ID__|${CLOUDFLARE_ACCESS_POLICY_ID}|g" \
  -e "s|__CLOUDFLARE_ACCESS_IDP_ID__|${CLOUDFLARE_ACCESS_IDP_ID}|g" \
  -e "s|__ACCESS_ALLOWED_EMAIL__|${ACCESS_ALLOWED_EMAIL}|g" \
  "${TEMPLATE_DIR}/access-policy-watchdog.sh" >"${WATCHDOG_DEST}"
chown "${OPERATOR_USERNAME}:staff" "${WATCHDOG_DEST}"
chmod 700 "${WATCHDOG_DEST}"
echo "✓ Watchdog deployed to ${WATCHDOG_DEST}"

# LaunchAgent plist
sed \
  -e "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" \
  -e "s|__OPERATOR_USERNAME__|${OPERATOR_USERNAME}|g" \
  "${TEMPLATE_DIR}/com.access-policy-watchdog.plist" >"${PLIST_DEST}"
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
echo "Checking the live Access rule (as ${OPERATOR_USERNAME}, launchd environment)..."
check_rc=0
sudo -u "${OPERATOR_USERNAME}" /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME="${OPERATOR_HOME}" \
  /bin/bash -c 'cd "${HOME}" && exec /bin/bash "$1" --check' _ "${WATCHDOG_DEST}" || check_rc=$?
if [[ ${check_rc} -ne 0 ]]; then
  echo
  echo "❌ The check did not pass (exit ${check_rc}). The LaunchAgent was NOT loaded."
  echo "   Exit 1: the live rule differs from config.conf, or an object is missing."
  echo "   Exit 2: the API could not be read (token, network)."
  echo "   Fix the rule or the expected values, then re-run this script."
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
echo "  Check now:  sudo -u ${OPERATOR_USERNAME} /bin/bash ${WATCHDOG_DEST} --check"
echo "  Run now:    sudo launchctl kickstart -kp ${SERVICE_TARGET}"
echo "  Log:        tail -f ${WATCHDOG_LOG}"
echo "  State:      sudo cat ${CONFIG_DIR}/state.json"
