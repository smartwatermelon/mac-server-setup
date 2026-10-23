#!/usr/bin/env bash
#
# cloudflared-setup.sh: deploy the Cloudflare Tunnel daemon (wrapper and
# LaunchDaemon). See docs/apps/cloudflare-tunnel-README.md.

# Usage: sudo ./cloudflared-setup.sh
# Run caddy-setup.sh first, so Caddy listens on 127.0.0.1:8080.

# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-10-22

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
TUNNEL_METRICS_PORT="${TUNNEL_METRICS_PORT:-20241}"

if [[ -z "${EXTERNAL_HOSTNAME}" ]]; then
  echo "❌ EXTERNAL_HOSTNAME is required in ${CONFIG_FILE} (e.g. tilsit.vip)"
  exit 1
fi
if [[ ! "${TUNNEL_METRICS_PORT}" =~ ^[0-9]+$ ]] || [[ "${TUNNEL_METRICS_PORT}" -lt 1024 ]] \
  || [[ "${TUNNEL_METRICS_PORT}" -gt 65535 ]]; then
  echo "❌ TUNNEL_METRICS_PORT must be a port number from 1024 to 65535 (got '${TUNNEL_METRICS_PORT}')"
  exit 1
fi

if ! id -u "${OPERATOR_USERNAME}" >/dev/null 2>&1; then
  echo "❌ Operator user '${OPERATOR_USERNAME}' not found"
  exit 1
fi

# Install cloudflared if missing. Homebrew refuses to run as root, so drop to
# the admin account that ran sudo.
CLOUDFLARED_BIN="/opt/homebrew/bin/cloudflared"
if [[ ! -x "${CLOUDFLARED_BIN}" ]]; then
  if [[ -z "${SUDO_USER:-}" ]] || [[ "${SUDO_USER}" == "root" ]]; then
    echo "❌ cloudflared is not installed, and Homebrew cannot run as root."
    echo "   Run this script with sudo from the admin account, or first:"
    echo "   brew install cloudflared"
    exit 1
  fi
  echo "Installing cloudflared via Homebrew (as ${SUDO_USER})..."
  sudo -u "${SUDO_USER}" /opt/homebrew/bin/brew install cloudflared
  if [[ ! -x "${CLOUDFLARED_BIN}" ]]; then
    echo "❌ cloudflared installation failed"
    exit 1
  fi
fi
cloudflared_version=$("${CLOUDFLARED_BIN}" --version 2>&1) || cloudflared_version="version unknown"
echo "✓ ${cloudflared_version%%$'\n'*}"

# Check that the tunnel token is in the System keychain. No -w: this checks
# the item exists without printing the token.
if ! security find-generic-password \
  -s "cloudflare-tunnel-token" \
  -a "${EXTERNAL_HOSTNAME}" \
  /Library/Keychains/System.keychain >/dev/null 2>&1; then
  echo "❌ Keychain item not found:"
  echo "   service=cloudflare-tunnel-token account=${EXTERNAL_HOSTNAME}"
  echo "   (System keychain). Store the token with security prompting for it,"
  echo "   never as a command-line argument. See \"Token chain\" in"
  echo "   docs/apps/cloudflare-tunnel-README.md."
  exit 1
fi
echo "✓ Tunnel token found in the System keychain"

# The metrics port must be free, unless our own cloudflared holds it (a
# redeploy of a running daemon).
listener=$(lsof -nP -iTCP:"${TUNNEL_METRICS_PORT}" -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | head -1) || listener=""
if [[ -n "${listener}" ]] && [[ "${listener}" != "cloudflared" ]]; then
  echo "❌ Port ${TUNNEL_METRICS_PORT} is in use by '${listener}'. Set TUNNEL_METRICS_PORT in ${CONFIG_FILE}."
  exit 1
fi

DEPLOY_WRAPPER="/usr/local/bin/cloudflared-wrapper.sh"
DEPLOY_PLIST="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.cloudflare-tunnel.plist"
DEPLOY_LOG_DIR="/Users/${OPERATOR_USERNAME}/.local/state/cloudflared"
SERVICE_TARGET="system/com.${HOSTNAME_LOWER}.cloudflare-tunnel"

substitute_template() {
  local src="$1" dst="$2"
  sed \
    -e "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" \
    -e "s|__OPERATOR_USERNAME__|${OPERATOR_USERNAME}|g" \
    -e "s|__EXTERNAL_HOSTNAME__|${EXTERNAL_HOSTNAME}|g" \
    -e "s|__TUNNEL_METRICS_PORT__|${TUNNEL_METRICS_PORT}|g" \
    "${src}" >"${dst}"
}

echo "☁️  Deploying Cloudflare Tunnel daemon for ${HOSTNAME_VALUE}"
echo "=================================================="

# launchd does not create missing log directories: without this the daemon
# fails to start with no log at all.
mkdir -p "${DEPLOY_LOG_DIR}"
chown "${OPERATOR_USERNAME}:staff" "${DEPLOY_LOG_DIR}"

for tpl in cloudflared-wrapper.sh com.cloudflare-tunnel.plist; do
  if [[ ! -f "${TEMPLATE_DIR}/${tpl}" ]]; then
    echo "❌ Template not found: ${TEMPLATE_DIR}/${tpl}"
    exit 1
  fi
done

substitute_template "${TEMPLATE_DIR}/cloudflared-wrapper.sh" "${DEPLOY_WRAPPER}"
chown root:wheel "${DEPLOY_WRAPPER}"
chmod 755 "${DEPLOY_WRAPPER}"
echo "✓ Installed ${DEPLOY_WRAPPER}"

substitute_template "${TEMPLATE_DIR}/com.cloudflare-tunnel.plist" "${DEPLOY_PLIST}"
chown root:wheel "${DEPLOY_PLIST}"
chmod 644 "${DEPLOY_PLIST}"
if ! plutil -lint "${DEPLOY_PLIST}" >/dev/null 2>&1; then
  echo "❌ Invalid plist syntax — launchd will reject ${DEPLOY_PLIST}"
  plutil -lint "${DEPLOY_PLIST}"
  exit 1
fi
echo "✓ Installed ${DEPLOY_PLIST}"

if grep -q '__[A-Z_]*__' "${DEPLOY_WRAPPER}" "${DEPLOY_PLIST}"; then
  echo "❌ Unsubstituted placeholders in the deployed files:"
  grep -n '__[A-Z_]*__' "${DEPLOY_WRAPPER}" "${DEPLOY_PLIST}"
  exit 1
fi

# (Re)load the LaunchDaemon
if launchctl print "${SERVICE_TARGET}" >/dev/null 2>&1; then
  echo "↻ Reloading existing daemon (${SERVICE_TARGET})"
  launchctl bootout "${SERVICE_TARGET}" 2>/dev/null || true
fi
launchctl bootstrap system "${DEPLOY_PLIST}"
echo "✓ Daemon bootstrapped: ${SERVICE_TARGET}"

# /ready returns 200 once cloudflared has at least one connection to the edge.
echo "Waiting for the tunnel to connect..."
ready=false
for _ in $(seq 1 30); do
  if curl -sf --max-time 2 "http://127.0.0.1:${TUNNEL_METRICS_PORT}/ready" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "${ready}" == "true" ]]; then
  echo "✓ Tunnel connected (/ready returned 200)"
else
  echo "⚠ /ready did not return 200 within 60 s. Check:"
  echo "   tail -50 ${DEPLOY_LOG_DIR}/cloudflared-error.log"
fi

echo
echo "🚀 Setup complete."
echo
echo "Commands:"
echo "  Status:  sudo launchctl print ${SERVICE_TARGET} | head"
echo "  Ready:   curl -s http://127.0.0.1:${TUNNEL_METRICS_PORT}/ready"
echo "  Restart: sudo launchctl kickstart -k ${SERVICE_TARGET}"
echo "  Stop:    sudo launchctl bootout ${SERVICE_TARGET}"
echo "  Logs:    tail -f ${DEPLOY_LOG_DIR}/cloudflared-error.log"
