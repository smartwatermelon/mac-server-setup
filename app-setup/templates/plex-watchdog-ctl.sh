#!/usr/bin/env bash
#
# plex-watchdog-ctl — Manage Plex settings watchdog
#
# Commands:
#   status   Show monitored settings: golden vs current values
#   accept   Update golden config to match current Plex values (accept drift)
#   revert   Push golden config values back to Plex (revert drift)
#   refresh  Re-fetch all Plex settings, regenerate commented section of golden.conf
#
# Template placeholders (replaced by plex-watchdog-setup.sh at deploy time):
#   __HOSTNAME__          → server hostname (e.g. TILSIT)
#   __MONITORING_EMAIL__  → destination email address
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-03-25

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PLEX_URL="http://localhost:32400"

CONFIG_DIR="${HOME}/.config/plex-watchdog"
GOLDEN_CONF="${CONFIG_DIR}/golden.conf"
STATE_FILE="${CONFIG_DIR}/state.json"
PLEX_TOKEN_FILE="${CONFIG_DIR}/token"
LOG_FILE="${HOME}/.local/state/plex-watchdog.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [plex-watchdog-ctl] %s\n' "${timestamp}" "$1" >>"${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Plex token from file
# ---------------------------------------------------------------------------

get_plex_token() {
  if [[ ! -f "${PLEX_TOKEN_FILE}" ]]; then
    echo "Error: Plex token file not found at ${PLEX_TOKEN_FILE}" >&2
    echo "Run plex-watchdog-setup.sh to configure the watchdog." >&2
    exit 1
  fi
  tr -d '[:space:]' <"${PLEX_TOKEN_FILE}"
}

# ---------------------------------------------------------------------------
# Fetch and parse Plex prefs
# Returns "key=value" lines, sorted
# ---------------------------------------------------------------------------

fetch_and_parse_prefs() {
  local token="$1"
  local xml
  xml=$(curl -sf --max-time 15 -H "X-Plex-Token: ${token}" "${PLEX_URL}/:/prefs" 2>/dev/null) || {
    echo "Error: Cannot reach Plex at ${PLEX_URL}" >&2
    exit 1
  }

  local count
  count=$(echo "${xml}" | xmllint --xpath 'count(//Setting)' - 2>/dev/null) || {
    echo "Error: Failed to parse Plex prefs XML" >&2
    exit 1
  }

  local i=1
  while [[ ${i} -le ${count} ]]; do
    local id value
    id=$(echo "${xml}" | xmllint --xpath "string(//Setting[${i}]/@id)" - 2>/dev/null) || true
    value=$(echo "${xml}" | xmllint --xpath "string(//Setting[${i}]/@value)" - 2>/dev/null) || true
    if [[ -n "${id}" ]]; then
      printf '%s=%s\n' "${id}" "${value}"
    fi
    ((i += 1))
  done | sort
}

# ---------------------------------------------------------------------------
# Load golden config (uncommented key: value pairs)
# ---------------------------------------------------------------------------

load_golden() {
  if [[ ! -f "${GOLDEN_CONF}" ]]; then
    echo "Error: Golden config not found at ${GOLDEN_CONF}" >&2
    exit 1
  fi

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    local key value
    key=$(echo "${line}" | sed 's/:.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    value=$(echo "${line}" | sed 's/^[^:]*://' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    if [[ -n "${key}" ]]; then
      printf '%s=%s\n' "${key}" "${value}"
    fi
  done <"${GOLDEN_CONF}"
}

# ---------------------------------------------------------------------------
# Atomic file write (write to tmp, then mv)
# ---------------------------------------------------------------------------

atomic_write() {
  local target="$1"
  local content="$2"
  local tmp="${target}.tmp.$$"
  printf '%s' "${content}" >"${tmp}"
  mv "${tmp}" "${target}"
}

# ---------------------------------------------------------------------------
# Command: status
# ---------------------------------------------------------------------------

cmd_status() {
  local token
  token=$(get_plex_token)

  local current_prefs
  current_prefs=$(fetch_and_parse_prefs "${token}")

  local golden_prefs
  golden_prefs=$(load_golden)

  local has_drift=false

  # Print header
  printf '%-40s %-15s %-15s %s\n' "Setting" "Golden" "Current" "Status"
  printf '%-40s %-15s %-15s %s\n' "-------" "------" "-------" "------"

  while IFS='=' read -r golden_key golden_value; do
    [[ -z "${golden_key}" ]] && continue

    local current_value
    current_value=$(echo "${current_prefs}" | awk -F= -v k="${golden_key}" '$1 == k {print substr($0, length(k)+2); exit}') || true

    local status="OK"
    if [[ "${current_value}" != "${golden_value}" ]]; then
      status="DRIFTED"
      has_drift=true
    fi

    # Truncate long values for display
    local display_golden="${golden_value}"
    local display_current="${current_value}"
    [[ ${#display_golden} -gt 14 ]] && display_golden="${display_golden:0:11}..."
    [[ ${#display_current} -gt 14 ]] && display_current="${display_current:0:11}..."

    printf '%-40s %-15s %-15s %s\n' "${golden_key}" "${display_golden}" "${display_current}" "${status}"
  done <<<"${golden_prefs}"

  echo ""
  if [[ "${has_drift}" == "true" ]]; then
    echo "Drift detected. Run 'plex-watchdog-ctl accept' or 'plex-watchdog-ctl revert'."
    return 1
  else
    echo "All monitored settings match golden configuration."
    return 0
  fi
}

# ---------------------------------------------------------------------------
# Command: accept
# ---------------------------------------------------------------------------

cmd_accept() {
  local token
  token=$(get_plex_token)

  local current_prefs
  current_prefs=$(fetch_and_parse_prefs "${token}")

  local golden_prefs
  golden_prefs=$(load_golden)

  local changes_made=false
  local golden_content
  golden_content=$(cat "${GOLDEN_CONF}")

  while IFS='=' read -r golden_key golden_value; do
    [[ -z "${golden_key}" ]] && continue

    local current_value
    current_value=$(echo "${current_prefs}" | awk -F= -v k="${golden_key}" '$1 == k {print substr($0, length(k)+2); exit}') || true

    if [[ "${current_value}" != "${golden_value}" ]]; then
      echo "ACCEPTED: ${golden_key} ${golden_value} -> ${current_value}"
      log "ACCEPTED: ${golden_key} ${golden_value} -> ${current_value}"

      # Update the value in golden config content (awk for safe replacement — no sed injection)
      golden_content=$(printf '%s\n' "${golden_content}" | awk -v k="${golden_key}" -v v="${current_value}" '
        $0 ~ "^"k":" { print k": "v; next } { print }
      ')
      changes_made=true
    fi
  done <<<"${golden_prefs}"

  if [[ "${changes_made}" == "true" ]]; then
    atomic_write "${GOLDEN_CONF}" "${golden_content}"

    # Clear alert state
    if [[ -f "${STATE_FILE}" ]]; then
      local state
      state=$(jq '.settings = (.settings // {} | to_entries | map(.value.alerted = false | .value.alerted_value = null) | from_entries)' "${STATE_FILE}" 2>/dev/null) || state="{}"
      atomic_write "${STATE_FILE}" "${state}"
    fi

    echo ""
    echo "Golden config updated. Watchdog will stop alerting on these changes."
  else
    echo "No drift found — nothing to accept."
  fi
}

# ---------------------------------------------------------------------------
# Command: revert
# ---------------------------------------------------------------------------

cmd_revert() {
  local token
  token=$(get_plex_token)

  # Verify Plex is reachable before attempting any changes
  if ! curl -sf --max-time 5 "${PLEX_URL}/identity" >/dev/null 2>&1; then
    echo "Error: Plex is not reachable at ${PLEX_URL}. Cannot revert." >&2
    exit 1
  fi

  local current_prefs
  current_prefs=$(fetch_and_parse_prefs "${token}")

  local golden_prefs
  golden_prefs=$(load_golden)

  local reverts_attempted=0
  local reverts_succeeded=0
  local reverts_failed=0

  while IFS='=' read -r golden_key golden_value; do
    [[ -z "${golden_key}" ]] && continue

    local current_value
    current_value=$(echo "${current_prefs}" | awk -F= -v k="${golden_key}" '$1 == k {print substr($0, length(k)+2); exit}') || true

    if [[ "${current_value}" != "${golden_value}" ]]; then
      ((reverts_attempted += 1))
      echo -n "Reverting ${golden_key}: ${current_value} -> ${golden_value}... "

      # URL-encode the value for the PUT request
      local encoded_value
      encoded_value=$(printf '%s' "${golden_value}" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=''))" 2>/dev/null) || encoded_value="${golden_value}"

      if curl -sf --max-time 10 -X PUT \
        -H "X-Plex-Token: ${token}" \
        "${PLEX_URL}/:/prefs?${golden_key}=${encoded_value}" >/dev/null 2>&1; then

        # Verify the change took effect
        local verify_prefs verify_value
        verify_prefs=$(fetch_and_parse_prefs "${token}")
        verify_value=$(echo "${verify_prefs}" | awk -F= -v k="${golden_key}" '$1 == k {print substr($0, length(k)+2); exit}') || true

        if [[ "${verify_value}" == "${golden_value}" ]]; then
          echo "OK"
          log "REVERTED: ${golden_key} ${current_value} -> ${golden_value}"
          ((reverts_succeeded += 1))
        else
          echo "FAILED (verification: got '${verify_value}', expected '${golden_value}')"
          log "ERROR: Revert verification failed for ${golden_key}: expected=${golden_value} actual=${verify_value}"
          ((reverts_failed += 1))
        fi
      else
        echo "FAILED (PUT request failed)"
        log "ERROR: Revert PUT failed for ${golden_key}"
        ((reverts_failed += 1))
      fi
    fi
  done <<<"${golden_prefs}"

  if [[ ${reverts_attempted} -eq 0 ]]; then
    echo "No drift found — nothing to revert."
    return 0
  fi

  echo ""
  echo "Reverted: ${reverts_succeeded}/${reverts_attempted}"

  if [[ ${reverts_failed} -gt 0 ]]; then
    echo "Failed: ${reverts_failed} (alert state preserved for failed settings — watchdog will re-alert)"
    return 1
  fi

  # Clear alert state for successfully reverted settings
  if [[ -f "${STATE_FILE}" ]]; then
    local state
    state=$(jq '.settings = (.settings // {} | to_entries | map(.value.alerted = false | .value.alerted_value = null) | from_entries)' "${STATE_FILE}" 2>/dev/null) || state="{}"
    atomic_write "${STATE_FILE}" "${state}"
  fi

  echo "All settings reverted. Watchdog alert state cleared."
}

# ---------------------------------------------------------------------------
# Command: refresh
# ---------------------------------------------------------------------------

cmd_refresh() {
  local token
  token=$(get_plex_token)

  local current_prefs
  current_prefs=$(fetch_and_parse_prefs "${token}")

  if [[ ! -f "${GOLDEN_CONF}" ]]; then
    echo "Error: Golden config not found at ${GOLDEN_CONF}" >&2
    exit 1
  fi

  # Back up current golden config
  cp "${GOLDEN_CONF}" "${GOLDEN_CONF}.bak"
  echo "Backup saved to ${GOLDEN_CONF}.bak"

  # Read monitored settings (uncommented lines) and preserve them
  declare -A monitored_settings
  local monitored_keys=()
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    local key value
    key=$(echo "${line}" | sed 's/:.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    value=$(echo "${line}" | sed 's/^[^:]*://' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    if [[ -n "${key}" ]]; then
      monitored_settings["${key}"]="${value}"
      monitored_keys+=("${key}")
    fi
  done <"${GOLDEN_CONF}"

  # Check for monitored settings that no longer exist in Plex
  for key in "${monitored_keys[@]}"; do
    if ! echo "${current_prefs}" | grep -q "^${key}="; then
      echo "WARNING: Monitored setting '${key}' no longer exists in Plex prefs — kept in golden.conf but may be stale"
      log "WARNING: monitored setting '${key}' no longer exists in Plex prefs"
    fi
  done

  # Read the golden config up to (and including) the header, preserving structure.
  # We'll regenerate from the template structure: keep everything above the first
  # uncommented setting or the first "# ===" section header, then rebuild.
  # Simpler approach: read the existing file, update __VALUE__ placeholders and
  # commented values with current Plex values, preserve uncommented lines.

  local new_content=""
  local settings_in_golden=()

  while IFS= read -r line; do
    if [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*(.*):\ __VALUE__$ ]] \
      || [[ "${line}" =~ ^[[:space:]]*#[[:space:]]*([^:]+):\ (.+)$ ]]; then
      # This is a commented-out setting line
      local key
      key=$(echo "${line}" | sed 's/^[[:space:]]*#[[:space:]]*//' | sed 's/:.*//' | sed 's/[[:space:]]*$//')

      # Get current value from Plex
      local plex_value
      plex_value=$(echo "${current_prefs}" | grep "^${key}=" | head -1 | sed "s/^${key}=//") || true

      if [[ -n "${plex_value}" ]] || echo "${current_prefs}" | grep -q "^${key}="; then
        new_content+="# ${key}: ${plex_value}"$'\n'
        settings_in_golden+=("${key}")
      else
        # Setting no longer exists — keep the line as-is
        new_content+="${line}"$'\n'
        settings_in_golden+=("${key}")
      fi
    elif [[ -z "${line}" ]] || [[ "${line}" =~ ^[[:space:]]*# ]]; then
      # Comment or blank line — preserve as-is
      new_content+="${line}"$'\n'
    else
      # Uncommented (monitored) setting — preserve the golden value
      local key
      key=$(echo "${line}" | sed 's/:.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
      if [[ -n "${key}" ]] && [[ -n "${monitored_settings[${key}]+x}" ]]; then
        new_content+="${key}: ${monitored_settings[${key}]}"$'\n'
        settings_in_golden+=("${key}")
      else
        new_content+="${line}"$'\n'
      fi
    fi
  done <"${GOLDEN_CONF}"

  # Count new settings in Plex that aren't in golden config at all
  local new_count=0
  while IFS='=' read -r plex_key _; do
    local found=false
    for existing_key in "${settings_in_golden[@]}"; do
      if [[ "${existing_key}" == "${plex_key}" ]]; then
        found=true
        break
      fi
    done
    if [[ "${found}" == "false" ]]; then
      ((new_count += 1))
    fi
  done <<<"${current_prefs}"

  # Write atomically
  atomic_write "${GOLDEN_CONF}" "${new_content}"

  log "Golden config refreshed: ${#settings_in_golden[@]} settings updated, ${new_count} new settings in Plex not in golden config"
  echo "Refreshed: ${#settings_in_golden[@]} settings updated"
  if [[ ${new_count} -gt 0 ]]; then
    echo "Note: ${new_count} Plex settings exist that are not in golden.conf (run refresh after a Plex update to add them)"
  fi

  # Show diff
  if command -v diff &>/dev/null; then
    echo ""
    echo "Changes:"
    diff "${GOLDEN_CONF}.bak" "${GOLDEN_CONF}" || true
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
  status)
    cmd_status
    ;;
  accept)
    cmd_accept
    ;;
  revert)
    cmd_revert
    ;;
  refresh)
    cmd_refresh
    ;;
  *)
    echo "Usage: plex-watchdog-ctl {status|accept|revert|refresh}"
    echo ""
    echo "Commands:"
    echo "  status   Show monitored settings vs current Plex values"
    echo "  accept   Update golden config to match current Plex values"
    echo "  revert   Push golden config values back to Plex"
    echo "  refresh  Re-fetch all Plex settings, update commented values in golden.conf"
    exit 1
    ;;
esac
