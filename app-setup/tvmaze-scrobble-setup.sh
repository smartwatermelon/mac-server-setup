#!/usr/bin/env bash
#
# tvmaze-scrobble-setup.sh: deploy the Plex → TVmaze watched sync.
# See docs/components/tvmaze-scrobble.md.

# Installs the listener, worker, credentials and two LaunchAgents for operator.

# Operator agents, not root daemons: msmtp refuses a config file the
# invoking user does not own, and the Plex token file is operator's.

# Usage: sudo ./tvmaze-scrobble-setup.sh

# Needs msmtp and plex-watchdog set up, and the key in the admin keychain.

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
TVMAZE_USERNAME="${TVMAZE_USERNAME:-}"
PLEX_ACCOUNT_TITLE="${PLEX_ACCOUNT_TITLE:-}"
PLEX_ACCOUNT_ID="${PLEX_ACCOUNT_ID:-1}"
TVMAZE_SCROBBLE_PORT="${TVMAZE_SCROBBLE_PORT:-32599}"
KEYCHAIN_SERVICE="tvmaze-${HOSTNAME_LOWER}"
# The admin whose login keychain holds the key: the user who ran sudo.
ADMIN_USER="${SUDO_USER:-}"
# Injectable, so a test can stub it.
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"

# Values go into templates via sed (| delimiter) and bash strings.

# So each is checked first: no | & \ $ ` or ".
EMAIL_PATTERN='^[^@|&\[:space:]]+@[^@|&\[:space:]]+$'
if [[ ! "${MONITORING_EMAIL}" =~ ${EMAIL_PATTERN} ]] \
  || [[ "${MONITORING_EMAIL}" == "your-email@example.com" ]]; then
  echo "❌ MONITORING_EMAIL is not set to a real address in ${CONFIG_FILE}"
  exit 1
fi
# TVmaze wants the account username here, not the email address.
if [[ ! "${TVMAZE_USERNAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "❌ TVMAZE_USERNAME is required in ${CONFIG_FILE} (the TVmaze username, not the email)"
  exit 1
fi
if [[ ! "${PLEX_ACCOUNT_TITLE}" =~ ^[A-Za-z0-9\ ._@+-]+$ ]]; then
  echo "❌ PLEX_ACCOUNT_TITLE is required in ${CONFIG_FILE}: the Plex account name"
  echo "   whose plays sync (letters, digits, spaces and . _ @ + - only)"
  exit 1
fi
if [[ ! "${PLEX_ACCOUNT_ID}" =~ ^[0-9]+$ ]]; then
  echo "❌ PLEX_ACCOUNT_ID must be the server-local Plex account id (got '${PLEX_ACCOUNT_ID}')"
  exit 1
fi
if [[ ! "${OPERATOR_USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "❌ OPERATOR_USERNAME has an unexpected format: '${OPERATOR_USERNAME}'"
  exit 1
fi
if [[ ! "${TVMAZE_SCROBBLE_PORT}" =~ ^[0-9]+$ ]] || [[ "${TVMAZE_SCROBBLE_PORT}" -lt 1024 ]] \
  || [[ "${TVMAZE_SCROBBLE_PORT}" -gt 65535 ]]; then
  echo "❌ TVMAZE_SCROBBLE_PORT must be a port number from 1024 to 65535 (got '${TVMAZE_SCROBBLE_PORT}')"
  exit 1
fi
if [[ -z "${ADMIN_USER}" ]] || [[ "${ADMIN_USER}" == "root" ]]; then
  echo "❌ Run this with sudo from the admin account whose keychain holds the TVmaze key"
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
if [[ ! -s "${OPERATOR_HOME}/.config/plex-watchdog/token" ]]; then
  echo "❌ Plex token not found at ${OPERATOR_HOME}/.config/plex-watchdog/token."
  echo "   Run plex-watchdog-setup.sh first."
  exit 1
fi

for tpl in tvmaze-scrobble.sh tvmaze-scrobble-listener.py alert-lib.sh \
  com.tvmaze-scrobble.plist com.tvmaze-reconcile.plist; do
  if [[ ! -f "${TEMPLATE_DIR}/${tpl}" ]]; then
    echo "❌ Template not found: ${TEMPLATE_DIR}/${tpl}"
    exit 1
  fi
done

CONFIG_DIR="${OPERATOR_HOME}/.config/tvmaze-scrobble"
CREDENTIALS_FILE="${CONFIG_DIR}/credentials"
BIN_DIR="${OPERATOR_HOME}/.local/bin"
WORKER_DEST="${BIN_DIR}/tvmaze-scrobble"
LISTENER_DEST="${BIN_DIR}/tvmaze-scrobble-listener"
ALERT_LIB_DEST="${OPERATOR_HOME}/.local/lib/alert-lib.sh"
STATE_DIR="${OPERATOR_HOME}/.local/state/tvmaze-scrobble"
LOG_FILE="${OPERATOR_HOME}/.local/state/tvmaze-scrobble.log"
LAUNCHAGENT_DIR="${OPERATOR_HOME}/Library/LaunchAgents"
LISTENER_LABEL="com.${HOSTNAME_LOWER}.tvmaze-scrobble"
RECONCILE_LABEL="com.${HOSTNAME_LOWER}.tvmaze-reconcile"
LISTENER_PLIST="${LAUNCHAGENT_DIR}/${LISTENER_LABEL}.plist"
RECONCILE_PLIST="${LAUNCHAGENT_DIR}/${RECONCILE_LABEL}.plist"
LISTENER_TARGET="gui/${OPERATOR_UID}/${LISTENER_LABEL}"
RECONCILE_TARGET="gui/${OPERATOR_UID}/${RECONCILE_LABEL}"
WEBHOOK_URL="http://127.0.0.1:${TVMAZE_SCROBBLE_PORT}/plex"

echo "📺 Deploying the Plex → TVmaze watched sync"
echo "=================================================="

# The port must be free, or held by this listener (a re-run).
if port_pids=$(lsof -nP -t -iTCP:"${TVMAZE_SCROBBLE_PORT}" -sTCP:LISTEN 2>/dev/null) \
  && [[ -n "${port_pids}" ]]; then
  if ! "${LAUNCHCTL_BIN}" print "${LISTENER_TARGET}" >/dev/null 2>&1; then
    echo "❌ Port ${TVMAZE_SCROBBLE_PORT} is in use by another process (pid ${port_pids//$'\n'/ })."
    echo "   Set TVMAZE_SCROBBLE_PORT to a free port in ${CONFIG_FILE}."
    exit 1
  fi
fi

# The API key: from the admin's login keychain into a variable, then to the
# credentials file through a pipe. Never on argv, never printed.
if ! TVMAZE_KEY=$(sudo -H -u "${ADMIN_USER}" security find-generic-password \
  -s "${KEYCHAIN_SERVICE}" -a "${TVMAZE_USERNAME}" -w \
  "/Users/${ADMIN_USER}/Library/Keychains/login.keychain-db" 2>/dev/null) \
  || [[ -z "${TVMAZE_KEY}" ]]; then
  echo "❌ TVmaze API key not found in ${ADMIN_USER}'s keychain"
  echo "   (service=${KEYCHAIN_SERVICE} account=${TVMAZE_USERNAME})."
  echo "   Over ssh the login keychain may be locked: run 'security unlock-keychain' first."
  echo "   Add it (prompts for the key; source: 1Password Automation/TVMaze, field 'API Key'):"
  echo "     security add-generic-password -U -s ${KEYCHAIN_SERVICE} -a ${TVMAZE_USERNAME} -w"
  exit 1
fi

# Directories, owned by operator. Run mkdir as operator, so any parent it
# creates is operator's too.
for dir in "${CONFIG_DIR}" "${BIN_DIR}" "$(dirname "${ALERT_LIB_DEST}")" \
  "${STATE_DIR}" "${LAUNCHAGENT_DIR}"; do
  sudo -u "${OPERATOR_USERNAME}" mkdir -p "${dir}"
done
chmod 700 "${CONFIG_DIR}"

# Credentials: written by operator with umask 077, so the file is never
# readable by anyone else, even for a moment.
printf '%s:%s\n' "${TVMAZE_USERNAME}" "${TVMAZE_KEY}" \
  | sudo -u "${OPERATOR_USERNAME}" /bin/bash -c 'umask 077 && cat >"$1"' _ "${CREDENTIALS_FILE}"
unset TVMAZE_KEY
chmod 600 "${CREDENTIALS_FILE}"
echo "✓ Credentials written to ${CREDENTIALS_FILE} (mode 600)"

# Shared alert library
cp "${TEMPLATE_DIR}/alert-lib.sh" "${ALERT_LIB_DEST}"
chown "${OPERATOR_USERNAME}:staff" "${ALERT_LIB_DEST}"
chmod 644 "${ALERT_LIB_DEST}"
echo "✓ alert-lib.sh deployed to ${ALERT_LIB_DEST}"

# Worker
sed \
  -e "s|__HOSTNAME__|${HOSTNAME_VALUE}|g" \
  -e "s|__MONITORING_EMAIL__|${MONITORING_EMAIL}|g" \
  -e "s|__PLEX_ACCOUNT_TITLE__|${PLEX_ACCOUNT_TITLE}|g" \
  -e "s|__PLEX_ACCOUNT_ID__|${PLEX_ACCOUNT_ID}|g" \
  "${TEMPLATE_DIR}/tvmaze-scrobble.sh" >"${WORKER_DEST}"
chown "${OPERATOR_USERNAME}:staff" "${WORKER_DEST}"
chmod 700 "${WORKER_DEST}"
echo "✓ Worker deployed to ${WORKER_DEST}"

# Listener (no placeholders: the plist passes the port and worker path)
cp "${TEMPLATE_DIR}/tvmaze-scrobble-listener.py" "${LISTENER_DEST}"
chown "${OPERATOR_USERNAME}:staff" "${LISTENER_DEST}"
chmod 700 "${LISTENER_DEST}"
echo "✓ Listener deployed to ${LISTENER_DEST}"

# LaunchAgent plists
for pair in "com.tvmaze-scrobble.plist:${LISTENER_PLIST}" \
  "com.tvmaze-reconcile.plist:${RECONCILE_PLIST}"; do
  src="${pair%%:*}"
  dest="${pair#*:}"
  sed \
    -e "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" \
    -e "s|__OPERATOR_USERNAME__|${OPERATOR_USERNAME}|g" \
    -e "s|__TVMAZE_SCROBBLE_PORT__|${TVMAZE_SCROBBLE_PORT}|g" \
    "${TEMPLATE_DIR}/${src}" >"${dest}"
  chown "${OPERATOR_USERNAME}:staff" "${dest}"
  chmod 644 "${dest}"
  if ! plutil -lint "${dest}" >/dev/null 2>&1; then
    echo "❌ Invalid plist syntax — launchd will reject ${dest}"
    plutil -lint "${dest}"
    exit 1
  fi
  echo "✓ LaunchAgent written to ${dest}"
done

if grep -q '__[A-Z_]*__' "${WORKER_DEST}" "${LISTENER_PLIST}" "${RECONCILE_PLIST}"; then
  echo "❌ Unsubstituted placeholders in the deployed files:"
  grep -n '__[A-Z_]*__' "${WORKER_DEST}" "${LISTENER_PLIST}" "${RECONCILE_PLIST}"
  exit 1
fi

# --check as operator in launchd's environment (sudo -u, not -iu).

# Calls TVmaze /v1/auth/validate; no scrobble, no email.
echo
echo "Checking credentials (as ${OPERATOR_USERNAME}, launchd environment)..."
check_rc=0
sudo -u "${OPERATOR_USERNAME}" /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME="${OPERATOR_HOME}" \
  /bin/bash -c 'cd "${HOME}" && exec /bin/bash "$1" --check' _ "${WORKER_DEST}" || check_rc=$?
if [[ ${check_rc} -ne 0 ]]; then
  echo
  echo "❌ The check failed (exit ${check_rc}). The LaunchAgents were NOT loaded."
  exit 1
fi

# (Re)load both agents in operator's GUI domain. The reconcile agent runs at
# load; on a fresh install its first run only seeds the state.
for pair in "${LISTENER_TARGET}:${LISTENER_PLIST}" "${RECONCILE_TARGET}:${RECONCILE_PLIST}"; do
  target="${pair%%:*}"
  plist="${pair#*:}"
  if "${LAUNCHCTL_BIN}" print "${target}" >/dev/null 2>&1; then
    echo "↻ Reloading existing agent (${target})"
    "${LAUNCHCTL_BIN}" bootout "${target}" 2>/dev/null || true
  fi
  if ! "${LAUNCHCTL_BIN}" bootstrap "gui/${OPERATOR_UID}" "${plist}"; then
    echo "❌ launchctl bootstrap failed. Is ${OPERATOR_USERNAME} logged in?"
    echo "   Retry: sudo launchctl bootstrap gui/${OPERATOR_UID} ${plist}"
    exit 1
  fi
  echo "✓ Agent loaded: ${target}"
done

# The listener answers GET with 200.
listening=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf --max-time 2 "http://127.0.0.1:${TVMAZE_SCROBBLE_PORT}/" >/dev/null 2>&1; then
    listening=true
    break
  fi
  sleep 1
done
if [[ "${listening}" != "true" ]]; then
  echo "❌ The listener is not answering on 127.0.0.1:${TVMAZE_SCROBBLE_PORT}."
  echo "   Log: tail -50 ${LOG_FILE}"
  exit 1
fi
echo "✓ Listener answering on 127.0.0.1:${TVMAZE_SCROBBLE_PORT}"

echo
echo "🚀 Setup complete."
echo
echo "One manual step: add this webhook in the Plex web app"
echo "(signed in as ${PLEX_ACCOUNT_TITLE}: Settings → Webhooks → Add Webhook):"
echo
echo "  ${WEBHOOK_URL}"
echo
echo "Commands:"
echo "  Check:      sudo -H -u ${OPERATOR_USERNAME} /bin/bash ${WORKER_DEST} --check"
echo "  Reconcile:  sudo launchctl kickstart -kp ${RECONCILE_TARGET}"
echo "  Restart:    sudo launchctl kickstart -kp ${LISTENER_TARGET}"
echo "  Log:        tail -f ${LOG_FILE}"
echo "  State:      sudo ls -l ${STATE_DIR}"
