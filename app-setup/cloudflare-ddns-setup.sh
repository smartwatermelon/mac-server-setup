#!/usr/bin/env bash
#
# cloudflare-ddns-setup.sh — deploy the Cloudflare DDNS updater
#
# Installs /usr/local/bin/cloudflare-ddns + /Library/LaunchDaemons/
# com.<hostname>.cloudflare-ddns.plist, validates the plist, and bootstraps
# the daemon. The daemon reads CF_API_TOKEN from the System keychain, so the
# 'cloudflare-api-token' / <external-hostname> entry must already exist
# (installed during Caddy setup).
#
# Usage: sudo ./cloudflare-ddns-setup.sh
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-04-19

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "❌ This script requires sudo privileges"
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
EXTERNAL_HOSTNAME="${EXTERNAL_HOSTNAME:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_RECORD_ID="${CLOUDFLARE_RECORD_ID:-}"

# Validate required config
missing=()
[[ -z "${EXTERNAL_HOSTNAME}" ]] && missing+=("EXTERNAL_HOSTNAME")
[[ -z "${CLOUDFLARE_ZONE_ID}" ]] && missing+=("CLOUDFLARE_ZONE_ID")
[[ -z "${CLOUDFLARE_RECORD_ID}" ]] && missing+=("CLOUDFLARE_RECORD_ID")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "❌ Missing required values in ${CONFIG_FILE}:"
  for var in "${missing[@]}"; do
    echo "   ${var}"
  done
  echo
  echo "   The zone ID and record ID can be found in the Cloudflare dashboard"
  echo "   or via \`curl -H 'Authorization: Bearer \$CF_TOKEN' \\"
  echo "   https://api.cloudflare.com/client/v4/zones/\$ZONE_ID/dns_records\`."
  exit 1
fi

# Verify operator user exists
if ! id -u "${OPERATOR_USERNAME}" >/dev/null 2>&1; then
  echo "❌ Operator user '${OPERATOR_USERNAME}' not found"
  exit 1
fi

# Verify token is present in System keychain
if ! security find-generic-password \
  -s "cloudflare-api-token" \
  -a "${EXTERNAL_HOSTNAME}" \
  /Library/Keychains/System.keychain >/dev/null 2>&1; then
  echo "❌ Keychain entry not found:"
  echo "   service=cloudflare-api-token account=${EXTERNAL_HOSTNAME}"
  echo
  echo "   Run Caddy setup first (or add the token manually):"
  echo "   sudo security add-generic-password -U \\"
  echo "     -s 'cloudflare-api-token' -a '${EXTERNAL_HOSTNAME}' \\"
  echo "     -w '<token>' /Library/Keychains/System.keychain"
  exit 1
fi

# Deployment paths
DEPLOY_SCRIPT="/usr/local/bin/cloudflare-ddns"
DEPLOY_PLIST="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.cloudflare-ddns.plist"
DEPLOY_LOG="/Users/${OPERATOR_USERNAME}/.local/state/cloudflare-ddns.log"
DEPLOY_STATE_DIR="/Users/${OPERATOR_USERNAME}/.local/state"

# Shared substitution — sed delimiter | is safe here (zone/record IDs are hex)
substitute_template() {
  local src="$1" dst="$2"
  sed \
    -e "s|__HOSTNAME__|${HOSTNAME_VALUE}|g" \
    -e "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" \
    -e "s|__OPERATOR_USERNAME__|${OPERATOR_USERNAME}|g" \
    -e "s|__EXTERNAL_HOSTNAME__|${EXTERNAL_HOSTNAME}|g" \
    -e "s|__CLOUDFLARE_ZONE_ID__|${CLOUDFLARE_ZONE_ID}|g" \
    -e "s|__CLOUDFLARE_RECORD_ID__|${CLOUDFLARE_RECORD_ID}|g" \
    "${src}" >"${dst}"
}

echo "☁️  Deploying Cloudflare DDNS updater for ${HOSTNAME_VALUE}"
echo "=================================================="
echo "  External hostname: ${EXTERNAL_HOSTNAME}"
echo "  Zone ID:           ${CLOUDFLARE_ZONE_ID}"
echo "  Record ID:         ${CLOUDFLARE_RECORD_ID}"
echo

# Ensure operator state dir exists and is owned correctly.
# Non-recursive: other daemons already have state files here and own them.
mkdir -p "${DEPLOY_STATE_DIR}"
chown "${OPERATOR_USERNAME}:staff" "${DEPLOY_STATE_DIR}"

# Deploy updater script
SCRIPT_SOURCE="${TEMPLATE_DIR}/cloudflare-ddns.sh"
if [[ ! -f "${SCRIPT_SOURCE}" ]]; then
  echo "❌ Template not found: ${SCRIPT_SOURCE}"
  exit 1
fi
substitute_template "${SCRIPT_SOURCE}" "${DEPLOY_SCRIPT}"
chown root:wheel "${DEPLOY_SCRIPT}"
chmod 755 "${DEPLOY_SCRIPT}"
echo "✓ Installed ${DEPLOY_SCRIPT}"

# Deploy LaunchDaemon plist
PLIST_SOURCE="${TEMPLATE_DIR}/com.cloudflare-ddns.plist"
if [[ ! -f "${PLIST_SOURCE}" ]]; then
  echo "❌ Template not found: ${PLIST_SOURCE}"
  exit 1
fi
substitute_template "${PLIST_SOURCE}" "${DEPLOY_PLIST}"
chown root:wheel "${DEPLOY_PLIST}"
chmod 644 "${DEPLOY_PLIST}"

if ! plutil -lint "${DEPLOY_PLIST}" >/dev/null 2>&1; then
  echo "❌ Invalid plist syntax — launchd will reject ${DEPLOY_PLIST}"
  plutil -lint "${DEPLOY_PLIST}"
  exit 1
fi
echo "✓ Installed ${DEPLOY_PLIST}"

# Pre-create log file with operator ownership so the daemon (root) writes
# to it, but operator can tail it without sudo.
touch "${DEPLOY_LOG}"
chown "${OPERATOR_USERNAME}:staff" "${DEPLOY_LOG}"
chmod 644 "${DEPLOY_LOG}"

# (Re)load the LaunchDaemon
SERVICE_TARGET="system/com.${HOSTNAME_LOWER}.cloudflare-ddns"
if launchctl print "${SERVICE_TARGET}" >/dev/null 2>&1; then
  echo "↻ Reloading existing daemon (${SERVICE_TARGET})"
  launchctl bootout "${SERVICE_TARGET}" 2>/dev/null || true
fi
launchctl bootstrap system "${DEPLOY_PLIST}"
echo "✓ Daemon bootstrapped: ${SERVICE_TARGET}"

# Let the first RunAtLoad cycle complete, then report
sleep 3
if [[ -s "${DEPLOY_LOG}" ]]; then
  echo
  echo "First log entries:"
  tail -5 "${DEPLOY_LOG}" | sed 's/^/  /'
fi

echo
echo "🚀 Setup complete."
echo
echo "Commands:"
echo "  Status:  sudo launchctl print ${SERVICE_TARGET} | head"
echo "  Restart: sudo launchctl kickstart -k ${SERVICE_TARGET}"
echo "  Stop:    sudo launchctl bootout ${SERVICE_TARGET}"
echo "  Logs:    tail -f ${DEPLOY_LOG}"
echo "  One-shot manual run: sudo /usr/local/bin/cloudflare-ddns"
