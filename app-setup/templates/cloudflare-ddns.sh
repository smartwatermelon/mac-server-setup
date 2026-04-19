#!/usr/bin/env bash
#
# cloudflare-ddns — Cloudflare A-record DDNS updater
#
# Checks the host's current public IP against the A record for __EXTERNAL_HOSTNAME__
# in Cloudflare, and PATCHes the record if they differ. Runs as root via
# LaunchDaemon so it can read CF_API_TOKEN from the System keychain.
#
# Template placeholders (substituted by cloudflare-ddns-setup.sh):
#   __EXTERNAL_HOSTNAME__   → public hostname (e.g. tilsit.vip)
#   __CLOUDFLARE_ZONE_ID__  → Cloudflare zone ID
#   __CLOUDFLARE_RECORD_ID__→ Cloudflare A-record ID
#   __OPERATOR_USERNAME__   → service-account name (for log path)
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-04-19

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

EXTERNAL_HOSTNAME="__EXTERNAL_HOSTNAME__"
CF_ZONE_ID="__CLOUDFLARE_ZONE_ID__"
CF_RECORD_ID="__CLOUDFLARE_RECORD_ID__"
OPERATOR_USERNAME="__OPERATOR_USERNAME__"

STATE_DIR="/Users/${OPERATOR_USERNAME}/.local/state"
LOG_FILE="${STATE_DIR}/cloudflare-ddns.log"
STATE_FILE="${STATE_DIR}/cloudflare-ddns.state"

CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=15
HEARTBEAT_INTERVAL_SECONDS=3600

# Public-IP providers tried in order. First provider returning a well-formed
# IPv4 wins. A malicious provider could return a bogus IP that we'd PATCH into
# Cloudflare; blast radius is bounded because the Cloudflare token is scoped
# to a single zone's DNS:Edit permission (set at token creation in the CF
# dashboard). If the token scope is ever broadened, revisit this choice —
# cross-validating 2-of-3 providers would be a cheap defense.
PUBLIC_IP_PROVIDERS=(
  "https://api.ipify.org"
  "https://ifconfig.me/ip"
  "https://icanhazip.com"
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local level="$1"
  shift
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [cloudflare-ddns] %s %s\n' "${timestamp}" "${level}" "$*" >>"${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Token from System keychain (root only)
# ---------------------------------------------------------------------------

read_cf_token() {
  security find-generic-password \
    -s "cloudflare-api-token" \
    -a "${EXTERNAL_HOSTNAME}" \
    -w \
    /Library/Keychains/System.keychain 2>/dev/null
}

# ---------------------------------------------------------------------------
# Public IP — try providers in order until one returns a valid IPv4
# ---------------------------------------------------------------------------

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# Accept only public, routable IPv4 addresses. A provider hiccup or a
# transparent proxy could return a private/loopback IP; PATCHing that into
# the public A-record would take the service offline. Rejects:
#   - malformed (via is_ipv4)
#   - any octet >255 (bad format)
#   - RFC1918 private (10/8, 172.16/12, 192.168/16)
#   - loopback (127/8), link-local (169.254/16), 0.0.0.0, multicast (224/4+)
is_public_ipv4() {
  local ip="$1"
  is_ipv4 "${ip}" || return 1
  local -a octets
  IFS='.' read -ra octets <<<"${ip}"
  local o
  for o in "${octets[@]}"; do
    ((o >= 0 && o <= 255)) || return 1
  done
  local a="${octets[0]}" b="${octets[1]}"
  # 0.0.0.0, loopback, multicast, reserved 240/4
  ((a == 0 || a == 127 || a >= 224)) && return 1
  # RFC1918
  ((a == 10)) && return 1
  ((a == 172 && b >= 16 && b <= 31)) && return 1
  ((a == 192 && b == 168)) && return 1
  # Link-local
  ((a == 169 && b == 254)) && return 1
  # CGNAT 100.64/10 — not truly public
  ((a == 100 && b >= 64 && b <= 127)) && return 1
  return 0
}

fetch_public_ip() {
  local provider ip
  for provider in "${PUBLIC_IP_PROVIDERS[@]}"; do
    ip=$(curl -sS \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      "${provider}" 2>/dev/null | tr -d '[:space:]') || ip=""
    if is_public_ipv4 "${ip}"; then
      printf '%s' "${ip}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Cloudflare API
# ---------------------------------------------------------------------------

cloudflare_get_record() {
  local token="$1"
  curl -sS \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    -H "Authorization: Bearer ${token}" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}"
}

cloudflare_patch_record() {
  # PATCH is a partial update — fields not sent are preserved. We deliberately
  # send only `content` so the user's `proxied` (orange-cloud), `ttl`, and any
  # record-level metadata survive an IP change.
  local token="$1" new_ip="$2"
  curl -sS \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    -X PATCH \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "$(printf '{"content":"%s"}' "${new_ip}")" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}"
}

# ---------------------------------------------------------------------------
# JSON helpers — parse Cloudflare response without needing jq
# (jq is available on TILSIT, but avoiding a dependency keeps the script
# self-contained for disaster recovery.)
# ---------------------------------------------------------------------------

json_field() {
  local json="$1" field="$2"
  printf '%s' "${json}" | python3 -c '
import json, sys
if len(sys.argv) < 2:
    sys.exit(1)
field = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
cur = d
for part in field.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(0)
# Emit JSON-native scalars so bash comparisons match the wire format:
#   true / false (lowercase) for booleans, bare numbers, strings unquoted.
if isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (str, int, float)):
    print(cur)
' "${field}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Heartbeat — log once per hour when no change is needed, so a silent
# log doesn't look like the updater is dead.
# ---------------------------------------------------------------------------

maybe_heartbeat() {
  local current_ip="$1"
  local last_heartbeat=0
  if [[ -f "${STATE_FILE}" ]]; then
    last_heartbeat=$(awk -F= '$1=="last_heartbeat" {print $2}' "${STATE_FILE}" 2>/dev/null || echo 0)
    [[ -z "${last_heartbeat}" ]] && last_heartbeat=0
  fi
  local now_epoch
  now_epoch=$(date +%s)
  local elapsed=$((now_epoch - last_heartbeat))
  if [[ ${elapsed} -ge ${HEARTBEAT_INTERVAL_SECONDS} ]]; then
    log "INFO" "heartbeat ok — public=${current_ip} matches ${EXTERNAL_HOSTNAME}"
    write_state "${current_ip}" "${now_epoch}"
  else
    # Update last_ip only; preserve heartbeat timestamp
    write_state "${current_ip}" "${last_heartbeat}"
  fi
}

write_state() {
  local ip="$1" heartbeat="$2"
  local tmp="${STATE_FILE}.tmp.$$"
  {
    printf 'last_ip=%s\n' "${ip}"
    printf 'last_heartbeat=%s\n' "${heartbeat}"
  } >"${tmp}"
  mv "${tmp}" "${STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

main() {
  mkdir -p "${STATE_DIR}"

  local token
  token=$(read_cf_token) || token=""
  if [[ -z "${token}" ]]; then
    log "ERROR" "cloudflare-api-token not found in System keychain (service=cloudflare-api-token account=${EXTERNAL_HOSTNAME})"
    exit 1
  fi

  local public_ip
  if ! public_ip=$(fetch_public_ip); then
    log "WARN" "could not determine public IP from any provider — will retry next cycle"
    exit 0
  fi

  local cf_response cf_curl_rc cf_success current_ip
  cf_response=$(cloudflare_get_record "${token}" 2>/dev/null) && cf_curl_rc=0 || cf_curl_rc=$?
  if [[ ${cf_curl_rc} -ne 0 ]] || [[ -z "${cf_response}" ]]; then
    # Transient: network/curl failure or empty body. Soft-fail so the next
    # cycle retries; don't flood monitoring with exit-1 alerts during an
    # upstream blip.
    log "WARN" "cloudflare GET unreachable (curl rc=${cf_curl_rc}) — will retry next cycle"
    exit 0
  fi
  cf_success=$(json_field "${cf_response}" "success" || true)
  if [[ "${cf_success}" != "true" ]]; then
    # Permanent: CF accepted the request but refused it (token revoked, wrong
    # zone/record ID, rate limited, etc.). Hard-fail so the error surfaces.
    log "ERROR" "cloudflare GET rejected — response: ${cf_response}"
    exit 1
  fi

  current_ip=$(json_field "${cf_response}" "result.content" || true)
  if [[ -z "${current_ip}" ]]; then
    log "ERROR" "cloudflare GET returned no result.content — response: ${cf_response}"
    exit 1
  fi

  if [[ "${current_ip}" == "${public_ip}" ]]; then
    maybe_heartbeat "${public_ip}"
    exit 0
  fi

  log "INFO" "IP change detected: ${EXTERNAL_HOSTNAME} ${current_ip} → ${public_ip}"

  local patch_response patch_curl_rc patch_success
  patch_response=$(cloudflare_patch_record "${token}" "${public_ip}" 2>/dev/null) \
    && patch_curl_rc=0 || patch_curl_rc=$?
  if [[ ${patch_curl_rc} -ne 0 ]] || [[ -z "${patch_response}" ]]; then
    log "WARN" "cloudflare PATCH unreachable (curl rc=${patch_curl_rc}) — will retry next cycle"
    exit 0
  fi
  patch_success=$(json_field "${patch_response}" "success" || true)
  if [[ "${patch_success}" != "true" ]]; then
    log "ERROR" "cloudflare PATCH rejected — response: ${patch_response}"
    exit 1
  fi

  log "INFO" "cloudflare A-record updated: ${EXTERNAL_HOSTNAME} → ${public_ip}"
  local now_epoch
  now_epoch=$(date +%s)
  write_state "${public_ip}" "${now_epoch}"
}

# ---------------------------------------------------------------------------
# Entry point — skipped when sourced for tests (TEST_RUNNER=true)
# ---------------------------------------------------------------------------

if [[ "${TEST_RUNNER:-false}" != "true" ]]; then
  main "$@"
fi
