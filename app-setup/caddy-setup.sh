#!/bin/bash

# Setup script for Caddy-based home server
# Deploys configuration, web assets, wrapper script, and LaunchDaemon plist
# Run: sudo ./caddy-setup.sh

set -e

# Check if running with sudo privileges
if [[ "${EUID}" -ne 0 ]]; then
  echo "❌ This script requires sudo privileges for directory creation"
  echo "Please run: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
HOSTNAME=${HOSTNAME:-$(hostname -s)}
OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
DEPLOY_CONFIG_DIR="/Users/${OPERATOR_USERNAME}/.config/caddy"
DEPLOY_WEB_ROOT="/usr/local/var/www"
DEPLOY_LOG_DIR="/usr/local/var/log/caddy"
DEPLOY_STATE_DIR="/Users/${OPERATOR_USERNAME}/.local/state/caddy"
DEPLOY_WRAPPER="/usr/local/bin/caddy-wrapper.sh"
DEPLOY_PLIST="/Library/LaunchDaemons/com.caddyserver.caddy.plist"
DEPLOY_MEDIA_SERVER="/usr/local/bin/media-server.py"
HOSTNAME_LOWER="$(echo "${HOSTNAME}" | tr '[:upper:]' '[:lower:]')"
DEPLOY_MEDIA_PLIST="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.media-server.plist"

echo "🧀 Setting up Caddy home server for ${HOSTNAME}.local"
echo "=================================================="

# Create directory structure
echo "Creating directories..."
mkdir -p "${DEPLOY_LOG_DIR}"
chown -R "${OPERATOR_USERNAME}:staff" "${DEPLOY_LOG_DIR}"
mkdir -p "${DEPLOY_STATE_DIR}"
chown -R "${OPERATOR_USERNAME}:staff" "${DEPLOY_STATE_DIR}"
mkdir -p "${DEPLOY_WEB_ROOT}"
chown -R "${OPERATOR_USERNAME}:staff" "${DEPLOY_WEB_ROOT}"
mkdir -p "${DEPLOY_CONFIG_DIR}"
chown -R "${OPERATOR_USERNAME}:staff" "${DEPLOY_CONFIG_DIR}"

# Deploy web files from www/
echo "Deploying web assets..."
if [[ -d "${TEMPLATE_DIR}/www" ]]; then
  cp -r "${TEMPLATE_DIR}/www/"* "${DEPLOY_WEB_ROOT}/"
  echo "✓ Copied web assets to ${DEPLOY_WEB_ROOT}/"
else
  echo "⚠ No www/ directory found — skipping web assets"
fi

# Copy CA certificate for distribution (if Caddy has generated one)
CA_CERT_SOURCE="/Users/${OPERATOR_USERNAME}/Library/Application Support/Caddy/pki/authorities/local/root.crt"
CA_CERT_DEST="${DEPLOY_WEB_ROOT}/caddy-root-ca.crt"

if [[ -f "${CA_CERT_SOURCE}" ]]; then
  cp "${CA_CERT_SOURCE}" "${CA_CERT_DEST}"
  echo "✓ Copied CA certificate for distribution"
else
  echo "⚠ CA certificate not found (Caddy may not have run yet)"
fi

# Deploy Caddyfile
echo "Deploying Caddyfile..."
if [[ -f "${TEMPLATE_DIR}/Caddyfile" ]]; then
  cp "${TEMPLATE_DIR}/Caddyfile" "${DEPLOY_CONFIG_DIR}/Caddyfile"
  chown "${OPERATOR_USERNAME}:staff" "${DEPLOY_CONFIG_DIR}/Caddyfile"
  echo "✓ Copied Caddyfile to ${DEPLOY_CONFIG_DIR}/"
else
  echo "❌ No Caddyfile found in ${TEMPLATE_DIR}"
  exit 1
fi

# Deploy caddy-wrapper.sh
echo "Deploying caddy-wrapper.sh..."
if [[ -f "${TEMPLATE_DIR}/caddy-wrapper.sh" ]]; then
  cp "${TEMPLATE_DIR}/caddy-wrapper.sh" "${DEPLOY_WRAPPER}"
  chmod +x "${DEPLOY_WRAPPER}"
  echo "✓ Copied caddy-wrapper.sh to ${DEPLOY_WRAPPER}"
else
  echo "❌ No caddy-wrapper.sh found in ${TEMPLATE_DIR}"
  exit 1
fi

# Install LaunchDaemon plist
echo "Installing LaunchDaemon plist..."
PLIST_SOURCE="${TEMPLATE_DIR}/com.caddyserver.caddy.plist"
if [[ -f "${PLIST_SOURCE}" ]]; then
  cp "${PLIST_SOURCE}" "${DEPLOY_PLIST}"
  chown root:wheel "${DEPLOY_PLIST}"
  chmod 644 "${DEPLOY_PLIST}"
  echo "✓ Installed plist to ${DEPLOY_PLIST}"
else
  echo "⚠ No plist found — skipping LaunchDaemon install"
fi

# Deploy media-server.py
echo "Deploying media-server.py..."
if [[ -f "${TEMPLATE_DIR}/media-server.py" ]]; then
  cp "${TEMPLATE_DIR}/media-server.py" "${DEPLOY_MEDIA_SERVER}"
  chmod +x "${DEPLOY_MEDIA_SERVER}"
  echo "✓ Copied media-server.py to ${DEPLOY_MEDIA_SERVER}"
else
  echo "❌ No media-server.py found in ${TEMPLATE_DIR}"
  exit 1
fi

# Install media-server LaunchDaemon plist
echo "Installing media-server LaunchDaemon plist..."
MEDIA_PLIST_SOURCE="${TEMPLATE_DIR}/com.media-server.plist"
if [[ -f "${MEDIA_PLIST_SOURCE}" ]]; then
  cp "${MEDIA_PLIST_SOURCE}" "${DEPLOY_MEDIA_PLIST}"
  chown root:wheel "${DEPLOY_MEDIA_PLIST}"
  chmod 644 "${DEPLOY_MEDIA_PLIST}"
  echo "✓ Installed plist to ${DEPLOY_MEDIA_PLIST}"
else
  echo "⚠ No media-server plist found — skipping"
fi

# Install Caddy if not present (drop privileges — Homebrew rejects root)
if ! command -v caddy &>/dev/null; then
  echo "Installing Caddy via Homebrew..."
  sudo -u "${SUDO_USER:-operator}" brew install caddy
else
  CADDY_VERSION=$(caddy version)
  echo "✓ Caddy already installed (${CADDY_VERSION})"
fi

# Validate configuration — use a dummy token that looks real enough to pass the
# cloudflare module's format check (it rejects obviously fake values like "placeholder")
DUMMY_TOKEN="dummy0token0for0validation0only000000000"
echo "Validating configuration..."
if HOSTNAME="${HOSTNAME}" CF_API_TOKEN="${DUMMY_TOKEN}" caddy validate --config "${DEPLOY_CONFIG_DIR}/Caddyfile" 2>&1; then
  echo "✓ Configuration valid"
else
  echo "❌ Configuration validation failed"
  exit 1
fi

echo ""
echo "🚀 Setup complete!"
echo ""
echo "Environment:"
echo "  Hostname: ${HOSTNAME}"
echo "  Server URL: https://${HOSTNAME}.local"
echo "  Web root: ${DEPLOY_WEB_ROOT}"
echo "  Config: ${DEPLOY_CONFIG_DIR}/Caddyfile"
echo "  Wrapper: ${DEPLOY_WRAPPER}"
echo "  Media server: ${DEPLOY_MEDIA_SERVER}"
echo "  Logs: ${DEPLOY_LOG_DIR}/"
echo ""
echo "Commands:"
echo "  Start:   sudo launchctl bootstrap system ${DEPLOY_PLIST}"
echo "  Restart: sudo launchctl kickstart -k system/com.caddyserver.caddy"
echo "  Stop:    sudo launchctl bootout system/com.caddyserver.caddy"
echo "  Health:  ./caddy-health.sh"
echo ""
echo "Certificate installation:"
echo "  Download: https://${HOSTNAME}.local/caddy-root-ca.crt"
echo ""
echo "⚠ This script does NOT start or reload services."
echo "  Caddy:        sudo launchctl kickstart -k system/com.caddyserver.caddy"
echo "  Media server: sudo launchctl kickstart -k system/com.${HOSTNAME_LOWER}.media-server"
