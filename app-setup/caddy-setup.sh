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
HOSTNAME_LOWER="$(echo "${HOSTNAME}" | tr '[:upper:]' '[:lower:]')"
OPERATOR_USERNAME="${OPERATOR_USERNAME:-operator}"
EXTERNAL_HOSTNAME="${EXTERNAL_HOSTNAME:-}"
SERVER_LAN_IP="${SERVER_LAN_IP:-}"
BASICAUTH_USERNAME="${BASICAUTH_USERNAME:-}"
BASICAUTH_HASH="${BASICAUTH_HASH:-}"
HOME_LINKS_TITLE="${HOME_LINKS_TITLE:-}"
HOME_LINK1_NAME="${HOME_LINK1_NAME:-}"
HOME_LINK1_PATH="${HOME_LINK1_PATH:-}"
HOME_LINK1_URL="${HOME_LINK1_URL:-}"
HOME_LINK2_NAME="${HOME_LINK2_NAME:-}"
HOME_LINK2_PATH="${HOME_LINK2_PATH:-}"
HOME_LINK2_URL="${HOME_LINK2_URL:-}"
NAS_SHARE_NAME="${NAS_SHARE_NAME:-Media}"
ACCESS_ALLOWED_EMAIL="${ACCESS_ALLOWED_EMAIL:-}"
HOME_ASSISTANT_HOSTNAME="${HOME_ASSISTANT_HOSTNAME:-}"
HOME_ASSISTANT_UPSTREAM="${HOME_ASSISTANT_UPSTREAM:-}"

# Validate required variables — empty values produce invalid Caddyfile syntax
if [[ -z "${EXTERNAL_HOSTNAME}" ]]; then
  echo "❌ EXTERNAL_HOSTNAME is required (e.g. tilsit.vip)"
  exit 1
fi
if [[ -z "${SERVER_LAN_IP}" ]]; then
  echo "❌ SERVER_LAN_IP is required (e.g. 10.0.15.15)"
  exit 1
fi
for var in BASICAUTH_USERNAME BASICAUTH_HASH; do
  if [[ -z "${!var}" ]]; then
    echo "❌ ${var} is required (empty value produces invalid Caddyfile)"
    exit 1
  fi
done
# The tunnel site's only origin check. Empty would match any email at all,
# and quotes or spaces would break the Caddyfile token.
if [[ ! "${ACCESS_ALLOWED_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo "❌ ACCESS_ALLOWED_EMAIL must be one plain email address (got '${ACCESS_ALLOWED_EMAIL}')"
  exit 1
fi

# BEGIN home links

# Optional dashboard links, such as your NAS admin pages (#265). See
# "Dashboard links" in docs/components/caddy.md.

# Validate HOME_LINK*; set HOME_LINK_SED and HOME_LINK_PATHS. 1 on bad input.
resolve_home_links() {
  local n old_key old_url name_var path_var url_var name path url lower seen=""
  local name_re='^[A-Za-z0-9 ._-]+$' path_re='^[A-Za-z0-9-]+$'
  local url_re='^https://[A-Za-z0-9._~:/?@!$&()*+,;=%-]+$'
  HOME_LINKS_TITLE="${HOME_LINKS_TITLE:-Links}"
  if [[ ! "${HOME_LINKS_TITLE}" =~ ${name_re} ]]; then
    echo "❌ HOME_LINKS_TITLE may hold only letters, digits, spaces, '.', '_' and '-'" >&2
    return 1
  fi
  HOME_LINK_SED=()
  HOME_LINK_PATHS=""
  for n in 1 2; do
    name_var="HOME_LINK${n}_NAME"
    path_var="HOME_LINK${n}_PATH"
    url_var="HOME_LINK${n}_URL"
    name="${!name_var:-}"
    path="${!path_var:-}"
    url="${!url_var:-}"
    # The deprecated key for this slot. Its URL moves to HOME_LINKN_URL.
    case "${n}" in
      1) old_key="QUICKCONNECT_ROMANO" ;;
      *) old_key="QUICKCONNECT_BERKSWELL" ;;
    esac
    old_url="${!old_key:-}"
    if [[ -n "${old_url}" ]]; then
      # Never change the dashboard labels or link paths without notice.
      if [[ -z "${name}" || -z "${path}" ]]; then
        {
          echo "❌ ${old_key} is set, but ${name_var} and ${path_var} are not."
          echo "   ${old_key} is deprecated. Add these lines to config.conf:"
          echo "     ${name_var}=\"<label>\""
          echo "     ${path_var}=\"<path>\""
          echo "     ${url_var}=\"${url:-${old_url}}\""
          echo "   Then remove ${old_key} and run caddy-setup.sh again."
        } >&2
        return 1
      fi
      echo "⚠ ${old_key} is deprecated; using ${name_var} and ${path_var}. Remove ${old_key} from config.conf." >&2
      url="${url:-${old_url}}"
    fi
    if [[ -z "${url}" ]]; then
      HOME_LINK_SED+=(-e "/@@BEGIN_HOME_LINK${n}@@/,/@@END_HOME_LINK${n}@@/d")
      printf -v "${name_var}" '%s' ""
      printf -v "${path_var}" '%s' ""
      printf -v "${url_var}" '%s' ""
      continue
    fi
    if [[ ! "${url}" =~ ${url_re} ]]; then
      printf '❌ %s must be an https:// URL with no spaces, quotes, braces, | or backslash\n' "${url_var}" >&2
      return 1
    fi
    if [[ ! "${name}" =~ ${name_re} ]]; then
      echo "❌ ${name_var} must be set to a label of letters, digits, spaces, '.', '_' and '-'" >&2
      return 1
    fi
    if [[ ! "${path}" =~ ${path_re} ]]; then
      echo "❌ ${path_var} must be set to letters, digits and '-' only (no '/')" >&2
      return 1
    fi
    lower="$(tr '[:upper:]' '[:lower:]' <<<"${path}")"
    case "${lower}" in
      transmission | media)
        echo "❌ ${path_var} '${path}' is already a route on this server" >&2
        return 1
        ;;
      *) ;;
    esac
    if [[ "${path}" == "${seen}" ]]; then
      echo "❌ ${path_var} '${path}' is the same as the other link's path" >&2
      return 1
    fi
    seen="${path}"
    HOME_LINK_PATHS="${HOME_LINK_PATHS:+${HOME_LINK_PATHS} }${path}"
    # sed treats & in the replacement as the match, so escape it.
    url="$(sed 's/&/\\&/g' <<<"${url}")"
    printf -v "${url_var}" '%s' "${url}"
  done
  # The outer block goes first: once it deletes a line, no later range sees it.
  if [[ -z "${HOME_LINK_PATHS}" ]]; then
    HOME_LINK_SED=(-e "/@@BEGIN_HOME_LINKS@@/,/@@END_HOME_LINKS@@/d" "${HOME_LINK_SED[@]}")
  fi
  HOME_LINK_SED+=(-e "/@@(BEGIN|END)_HOME_LINKS?[0-9]*@@/d")
}

# Validate HOME_ASSISTANT_*; add to HOME_LINK_SED (run after
# resolve_home_links). See docs/components/cloudflare-tunnel.md.
resolve_home_assistant() {
  local host="${HOME_ASSISTANT_HOSTNAME:-}" upstream="${HOME_ASSISTANT_UPSTREAM:-}"
  local main addr port octet
  local label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
  local host_re="^(${label}\.)+${label}\$"
  local ipv4_re='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
  local name_re='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
  # Both values go into the Caddyfile unquoted, so these patterns are strict.
  if [[ -z "${host}" && -z "${upstream}" ]]; then
    HOME_LINK_SED+=(-e "/@@BEGIN_HOME_ASSISTANT@@/,/@@END_HOME_ASSISTANT@@/d")
    return 0
  fi
  if [[ -z "${host}" || -z "${upstream}" ]]; then
    echo "❌ Set both HOME_ASSISTANT_HOSTNAME and HOME_ASSISTANT_UPSTREAM, or neither" >&2
    return 1
  fi
  main="$(tr '[:upper:]' '[:lower:]' <<<"${EXTERNAL_HOSTNAME}")"
  if [[ ! "${host}" =~ ${host_re} ]]; then
    echo "❌ HOME_ASSISTANT_HOSTNAME must be a lower-case DNS name (e.g. ha.${main})" >&2
    return 1
  fi
  # A subdomain of EXTERNAL_HOSTNAME: same Cloudflare zone and Access team.
  if [[ "${host}" != *".${main}" ]]; then
    echo "❌ HOME_ASSISTANT_HOSTNAME must be a subdomain of ${main} (e.g. ha.${main})" >&2
    return 1
  fi
  addr="${upstream%:*}"
  port="${upstream##*:}"
  if [[ "${addr}" == "${upstream}" || ! "${port}" =~ ^[0-9]{1,5}$ ]] \
    || ((10#${port} < 1 || 10#${port} > 65535)); then
    echo "❌ HOME_ASSISTANT_UPSTREAM must be host:port, such as 192.168.21.20:8123 (no scheme, no path)" >&2
    return 1
  fi
  if [[ "${addr}" =~ ${ipv4_re} ]]; then
    for octet in ${addr//./ }; do
      if ((10#${octet} > 255)); then
        echo "❌ HOME_ASSISTANT_UPSTREAM has a bad IPv4 address: ${addr}" >&2
        return 1
      fi
    done
  elif [[ ! "${addr}" =~ ${name_re} ]]; then
    echo "❌ HOME_ASSISTANT_UPSTREAM must be IPv4:port or hostname:port (letters, digits, '.' and '-')" >&2
    return 1
  fi
  case "$(tr '[:upper:]' '[:lower:]' <<<"${addr}")" in
    *.local)
      echo "⚠ HOME_ASSISTANT_UPSTREAM uses a .local name. Its mDNS lookup can take seconds; an IP address is faster." >&2
      ;;
    *) ;;
  esac
  HOME_LINK_SED+=(-e "/@@(BEGIN|END)_HOME_ASSISTANT@@/d")
}

# Template substitution helper — replaces __PLACEHOLDER__ tokens in a file.
# Uses | as sed delimiter (safe: bcrypt hashes don't contain |).
substitute_template() {
  local src="$1" dst="$2"
  sed -E "${HOME_LINK_SED[@]}" \
    -e "s|__HOSTNAME__|${HOSTNAME}|g" \
    -e "s|__HOSTNAME_LOWER__|${HOSTNAME_LOWER}|g" \
    -e "s|__OPERATOR_USERNAME__|${OPERATOR_USERNAME}|g" \
    -e "s|__EXTERNAL_HOSTNAME__|${EXTERNAL_HOSTNAME}|g" \
    -e "s|__SERVER_LAN_IP__|${SERVER_LAN_IP}|g" \
    -e "s|__BASICAUTH_USERNAME__|${BASICAUTH_USERNAME}|g" \
    -e "s|__BASICAUTH_HASH__|${BASICAUTH_HASH}|g" \
    -e "s|__HOME_LINKS_TITLE__|${HOME_LINKS_TITLE}|g" \
    -e "s|__HOME_LINK1_NAME__|${HOME_LINK1_NAME}|g" \
    -e "s|__HOME_LINK1_PATH__|${HOME_LINK1_PATH}|g" \
    -e "s|__HOME_LINK1_URL__|${HOME_LINK1_URL}|g" \
    -e "s|__HOME_LINK2_NAME__|${HOME_LINK2_NAME}|g" \
    -e "s|__HOME_LINK2_PATH__|${HOME_LINK2_PATH}|g" \
    -e "s|__HOME_LINK2_URL__|${HOME_LINK2_URL}|g" \
    -e "s|__HOME_LINK_PATHS__|${HOME_LINK_PATHS}|g" \
    -e "s|__NAS_SHARE_NAME__|${NAS_SHARE_NAME}|g" \
    -e "s|__ACCESS_ALLOWED_EMAIL__|${ACCESS_ALLOWED_EMAIL}|g" \
    -e "s|__HOME_ASSISTANT_HOSTNAME__|${HOME_ASSISTANT_HOSTNAME}|g" \
    -e "s|__HOME_ASSISTANT_UPSTREAM__|${HOME_ASSISTANT_UPSTREAM}|g" \
    "${src}" >"${dst}"
}
# END home links

# Stop here on a bad or deprecated HOME_LINK* or a bad HOME_ASSISTANT_*
# setting: nothing is written yet.
resolve_home_links || exit 1
resolve_home_assistant || exit 1

DEPLOY_CONFIG_DIR="/Users/${OPERATOR_USERNAME}/.config/caddy"
DEPLOY_WEB_ROOT="/usr/local/var/www"
DEPLOY_LOG_DIR="/usr/local/var/log/caddy"
DEPLOY_STATE_DIR="/Users/${OPERATOR_USERNAME}/.local/state/caddy"
DEPLOY_WRAPPER="/usr/local/bin/caddy-wrapper.sh"
DEPLOY_HEALTH="/usr/local/bin/caddy-health.sh"
DEPLOY_PLIST="/Library/LaunchDaemons/com.caddyserver.caddy.plist"
DEPLOY_MEDIA_SERVER="/usr/local/bin/media-server.py"
DEPLOY_MEDIA_PLIST="/Library/LaunchDaemons/com.${HOSTNAME_LOWER}.media-server.plist"

# `sed > dst` keeps an existing file's mode, so set owner and mode explicitly.
install_root_script() {
  chown root:wheel "$1"
  chmod 755 "$1"
}

echo "🧀 Setting up Caddy home server for ${HOSTNAME}.local"
echo "=================================================="

# Create directory structure
echo "Creating directories..."
# Root daemons run scripts from here; only root may write to it.
install -d -o root -g wheel -m 755 /usr/local/bin
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
  # Text files carry placeholders too (site.webmanifest has __HOSTNAME__).
  for web_file in "${TEMPLATE_DIR}/www/"*.html "${TEMPLATE_DIR}/www/"*.webmanifest; do
    [[ -f "${web_file}" ]] || continue
    substitute_template "${web_file}" "${DEPLOY_WEB_ROOT}/$(basename "${web_file}")"
  done
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
  substitute_template "${TEMPLATE_DIR}/Caddyfile" "${DEPLOY_CONFIG_DIR}/Caddyfile"
  chown "${OPERATOR_USERNAME}:staff" "${DEPLOY_CONFIG_DIR}/Caddyfile"
  echo "✓ Copied Caddyfile to ${DEPLOY_CONFIG_DIR}/"
else
  echo "❌ No Caddyfile found in ${TEMPLATE_DIR}"
  exit 1
fi

# Deploy caddy-wrapper.sh
echo "Deploying caddy-wrapper.sh..."
if [[ -f "${TEMPLATE_DIR}/caddy-wrapper.sh" ]]; then
  substitute_template "${TEMPLATE_DIR}/caddy-wrapper.sh" "${DEPLOY_WRAPPER}"
  install_root_script "${DEPLOY_WRAPPER}"
  echo "✓ Copied caddy-wrapper.sh to ${DEPLOY_WRAPPER}"
else
  echo "❌ No caddy-wrapper.sh found in ${TEMPLATE_DIR}"
  exit 1
fi

# Deploy caddy-health.sh
echo "Deploying caddy-health.sh..."
if [[ -f "${TEMPLATE_DIR}/caddy-health.sh" ]]; then
  substitute_template "${TEMPLATE_DIR}/caddy-health.sh" "${DEPLOY_HEALTH}"
  install_root_script "${DEPLOY_HEALTH}"
  echo "✓ Copied caddy-health.sh to ${DEPLOY_HEALTH}"
else
  echo "❌ No caddy-health.sh found in ${TEMPLATE_DIR}"
  exit 1
fi

# Install LaunchDaemon plist
echo "Installing LaunchDaemon plist..."
PLIST_SOURCE="${TEMPLATE_DIR}/com.caddyserver.caddy.plist"
if [[ -f "${PLIST_SOURCE}" ]]; then
  substitute_template "${PLIST_SOURCE}" "${DEPLOY_PLIST}"
  chown root:wheel "${DEPLOY_PLIST}"
  chmod 644 "${DEPLOY_PLIST}"
  echo "✓ Installed plist to ${DEPLOY_PLIST}"
else
  echo "⚠ No plist found — skipping LaunchDaemon install"
fi

# Deploy media-server.py
echo "Deploying media-server.py..."
if [[ -f "${TEMPLATE_DIR}/media-server.py" ]]; then
  substitute_template "${TEMPLATE_DIR}/media-server.py" "${DEPLOY_MEDIA_SERVER}"
  install_root_script "${DEPLOY_MEDIA_SERVER}"
  echo "✓ Copied media-server.py to ${DEPLOY_MEDIA_SERVER}"
else
  echo "❌ No media-server.py found in ${TEMPLATE_DIR}"
  exit 1
fi

# Install media-server LaunchDaemon plist
echo "Installing media-server LaunchDaemon plist..."
MEDIA_PLIST_SOURCE="${TEMPLATE_DIR}/com.media-server.plist"
if [[ -f "${MEDIA_PLIST_SOURCE}" ]]; then
  substitute_template "${MEDIA_PLIST_SOURCE}" "${DEPLOY_MEDIA_PLIST}"
  chown root:wheel "${DEPLOY_MEDIA_PLIST}"
  chmod 644 "${DEPLOY_MEDIA_PLIST}"
  echo "✓ Installed plist to ${DEPLOY_MEDIA_PLIST}"
else
  echo "⚠ No media-server plist found — skipping"
fi

# Install Caddy if not present (drop privileges — Homebrew rejects root)
# Apple Silicon only — this project targets M-series Mac Minis
CADDY_BIN="/opt/homebrew/bin/caddy"
if [[ ! -x "${CADDY_BIN}" ]]; then
  echo "Installing Caddy via Homebrew..."
  sudo -u "${SUDO_USER:-operator}" brew install caddy
  if [[ ! -x "${CADDY_BIN}" ]]; then
    echo "❌ Caddy installation failed"
    exit 1
  fi
fi
CADDY_VERSION=$("${CADDY_BIN}" version)
echo "✓ Caddy installed (${CADDY_VERSION})"

# Validate configuration — use a dummy token that looks real enough to pass the
# cloudflare module's format check (it rejects obviously fake values like "placeholder")
DUMMY_TOKEN="dummy0token0for0validation0only000000000"
echo "Validating configuration..."
if HOSTNAME="${HOSTNAME}" CF_API_TOKEN="${DUMMY_TOKEN}" "${CADDY_BIN}" validate --config "${DEPLOY_CONFIG_DIR}/Caddyfile" 2>&1; then
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
echo "  Health check: ${DEPLOY_HEALTH}"
echo "  Media server: ${DEPLOY_MEDIA_SERVER}"
echo "  Logs: ${DEPLOY_LOG_DIR}/"
echo ""
echo "Commands:"
echo "  Start:   sudo launchctl bootstrap system ${DEPLOY_PLIST}"
echo "  Restart: sudo launchctl kickstart -k system/com.caddyserver.caddy"
echo "  Stop:    sudo launchctl bootout system/com.caddyserver.caddy"
echo "  Health:  ${DEPLOY_HEALTH}"
echo ""
echo "Certificate installation:"
echo "  Download: https://${HOSTNAME}.local/caddy-root-ca.crt"
echo ""
echo "⚠ This script does NOT start or reload services."
echo "  Caddy:        sudo launchctl kickstart -k system/com.caddyserver.caddy"
echo "  Media server: sudo launchctl kickstart -k system/com.${HOSTNAME_LOWER}.media-server"
