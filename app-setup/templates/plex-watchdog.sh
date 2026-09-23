#!/usr/bin/env bash
#
# plex-watchdog — Plex settings drift detector
#
# Polls Plex server preferences against a golden configuration and sends
# email alerts when settings drift. Designed to run every 5 minutes via
# LaunchAgent (StartInterval=300).
#
# Each invocation is a single poll cycle: fetch, compare, alert, exit.
#
# Template placeholders (replaced by plex-watchdog-setup.sh at deploy time):
#   __HOSTNAME__          → server hostname (e.g. TILSIT)
#   __MONITORING_EMAIL__  → destination email address
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-03-25

set -euo pipefail

# launchd starts this with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which has no
# Homebrew in it. Set PATH explicitly so the script behaves the same under
# launchd as in a login shell. See docs/apps/monitoring-README.md.
ARCH="$(arch)"
case "${ARCH}" in
  arm64) HOMEBREW_PREFIX="/opt/homebrew" ;;
  *) HOMEBREW_PREFIX="/usr/local" ;;
esac
export PATH="${HOMEBREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOSTNAME_LABEL="__HOSTNAME__"
MONITORING_EMAIL="__MONITORING_EMAIL__"
PLEX_URL="http://localhost:32400"
PLEX_TOKEN_FILE="${HOME}/.config/plex-watchdog/token"

CONFIG_DIR="${HOME}/.config/plex-watchdog"
GOLDEN_CONF="${CONFIG_DIR}/golden.conf"
export STATE_FILE="${CONFIG_DIR}/state.json" # read by alert-lib.sh
LOG_FILE="${HOME}/.local/state/plex-watchdog.log"
ALERT_LIB="${ALERT_LIB:-${HOME}/.local/lib/alert-lib.sh}"

CONSECUTIVE_FAILURE_THRESHOLD=3
HEARTBEAT_INTERVAL_SECONDS=3600

# Media access check (see check_media_access). A blocked read can hang rather
# than fail, so a timeout counts as a failure.
MEDIA_CHECK_TIMEOUT_SECONDS=30
MEDIA_FAILURE_THRESHOLD=2
# A blocked Plex can stay blocked all day (the 2026-09-17 prompt lasted 19
# hours). Resend an open media alert twice a day. Used by alert_transition.
export ALERT_REMINDER_SECONDS=43200

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [plex-watchdog] %s\n' "${timestamp}" "$1" >>"${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Shared alert library: alert_send, and the alert_state_* helpers (atomic
# JSON state reads/writes via temp+mv) on STATE_FILE.
# Deployed by plex-watchdog-setup.sh and msmtp-setup.sh.
# ---------------------------------------------------------------------------

if [[ ! -r "${ALERT_LIB}" ]]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  log "ERROR: alert library not found at ${ALERT_LIB} — cannot send alerts. Re-run plex-watchdog-setup.sh"
  exit 1
fi
# shellcheck source=/dev/null
source "${ALERT_LIB}"

# ---------------------------------------------------------------------------
# Plex token from file
# Stored at setup time with mode 600, owned by operator.
# This avoids keychain access issues in non-interactive LaunchAgent contexts.
# ---------------------------------------------------------------------------

get_plex_token() {
  if [[ ! -f "${PLEX_TOKEN_FILE}" ]]; then
    log "ERROR: Plex token file not found at ${PLEX_TOKEN_FILE} — run plex-watchdog-setup.sh"
    exit 1
  fi
  local token
  token=$(tr -d '[:space:]' <"${PLEX_TOKEN_FILE}" 2>/dev/null)
  if [[ -z "${token}" ]]; then
    log "ERROR: Plex token file is empty at ${PLEX_TOKEN_FILE}"
    exit 1
  fi
  echo "${token}"
}

# ---------------------------------------------------------------------------
# Fetch Plex prefs XML
# ---------------------------------------------------------------------------

fetch_prefs_xml() {
  local token="$1"
  curl -sf --max-time 15 -H "X-Plex-Token: ${token}" "${PLEX_URL}/:/prefs" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Parse Plex prefs XML into key=value pairs using xmllint
# Output: one "key=value" per line, sorted
# ---------------------------------------------------------------------------

parse_prefs_xml() {
  local xml="$1"
  # Extract count of Setting elements
  local count
  count=$(echo "${xml}" | xmllint --xpath 'count(//Setting)' - 2>/dev/null) || {
    log "ERROR: xmllint failed to parse Plex prefs XML"
    return 1
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
# Load golden config (uncommented key: value pairs only)
# ---------------------------------------------------------------------------

load_golden() {
  if [[ ! -f "${GOLDEN_CONF}" ]]; then
    log "ERROR: Golden config not found at ${GOLDEN_CONF}"
    exit 1
  fi

  local has_settings=false
  while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    # Parse key: value
    local key value
    key=$(echo "${line}" | sed 's/:.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    value=$(echo "${line}" | sed 's/^[^:]*://' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

    if [[ -n "${key}" ]]; then
      printf '%s=%s\n' "${key}" "${value}"
      has_settings=true
    fi
  done <"${GOLDEN_CONF}"

  if [[ "${has_settings}" == "false" ]]; then
    log "ERROR: Golden config has no monitored settings (all commented out)"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Send email
# ---------------------------------------------------------------------------

send_email() {
  alert_send "$1" "$2"
}

# ---------------------------------------------------------------------------
# Media access check
#
# Plex can answer its API while it cannot open a single file: on 2026-09-17 a
# macOS privacy prompt blocked its NAS access for 19 hours (issue #199). So
# ask Plex itself to stat the newest movie or episode. Checking the NAS from
# this script would prove nothing: /bin/bash is a different TCC identity from
# Plex, so it can pass while Plex is blocked, or the reverse.
#
# Failure: a <Part> with exists="0" or accessible="0", or no answer within
# MEDIA_CHECK_TIMEOUT_SECONDS. Anything else that stops the check (no movie or
# episode in the recent list, the item removed between the two requests,
# attributes missing) is "unknown": logged, not counted.
#
# State: .media_check_failures, and .transitions.media_unreachable (owned by
# alert_transition).
# ---------------------------------------------------------------------------

check_media_access() {
  local token="$1"

  # recentlyAdded lists TV as <Directory type="season">, which has no <Part>
  # to check, so take the first <Video>.
  local recent rating_key
  if ! recent=$(curl -sf --max-time 15 -H "X-Plex-Token: ${token}" \
    "${PLEX_URL}/library/recentlyAdded?X-Plex-Container-Start=0&X-Plex-Container-Size=10" 2>/dev/null); then
    log "WARNING: media check skipped: could not list recently added items"
    return 0
  fi
  rating_key=$(echo "${recent}" | xmllint --xpath 'string((/MediaContainer/Video)[1]/@ratingKey)' - 2>/dev/null) || rating_key=""
  if [[ ! "${rating_key}" =~ ^[0-9]+$ ]]; then
    log "WARNING: media check skipped: no movie or episode in the recently added list"
    return 0
  fi

  local xml rc=0 failure=""
  xml=$(curl -sf --max-time "${MEDIA_CHECK_TIMEOUT_SECONDS}" -H "X-Plex-Token: ${token}" \
    "${PLEX_URL}/library/metadata/${rating_key}?checkFiles=1" 2>/dev/null) || rc=$?
  local title="item ${rating_key}" file=""
  if [[ ${rc} -eq 28 ]]; then
    failure="Plex did not answer within ${MEDIA_CHECK_TIMEOUT_SECONDS} s"
  elif [[ ${rc} -ne 0 ]]; then
    log "WARNING: media check skipped: checkFiles request for item ${rating_key} failed (curl exit ${rc})"
    return 0
  else
    local checked bad
    checked=$(echo "${xml}" | xmllint --xpath 'count(//Part[@exists and @accessible])' - 2>/dev/null) || checked=0
    if [[ "${checked}" == "0" ]]; then
      log "WARNING: media check skipped: no exists/accessible attributes for item ${rating_key}"
      return 0
    fi
    title=$(echo "${xml}" | xmllint --xpath 'string((//Video)[1]/@title)' - 2>/dev/null) || title="item ${rating_key}"
    bad=$(echo "${xml}" | xmllint --xpath 'count(//Part[@exists="0" or @accessible="0"])' - 2>/dev/null) || bad=0
    if [[ "${bad}" != "0" ]]; then
      local exists accessible
      file=$(echo "${xml}" | xmllint --xpath 'string((//Part[@exists="0" or @accessible="0"])[1]/@file)' - 2>/dev/null) || file=""
      exists=$(echo "${xml}" | xmllint --xpath 'string((//Part[@exists="0" or @accessible="0"])[1]/@exists)' - 2>/dev/null) || exists="?"
      accessible=$(echo "${xml}" | xmllint --xpath 'string((//Part[@exists="0" or @accessible="0"])[1]/@accessible)' - 2>/dev/null) || accessible="?"
      failure="Plex reports exists=${exists} accessible=${accessible}"
    fi
  fi

  local failures
  failures=$(alert_state_get "media_check_failures" "0")
  [[ "${failures}" =~ ^[0-9]+$ ]] || failures=0
  if [[ -n "${failure}" ]]; then
    failures=$((failures + 1))
    log "WARNING: media check failed (${failures}/${MEDIA_FAILURE_THRESHOLD}): ${title}: ${failure}"
  else
    failures=0
  fi
  # A corrupt state file must not stop the run under set -e: start it fresh,
  # as Step 8 does, so the cycle rewrites it.
  local state
  state=$(alert_state_read)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"${state}" || state='{}'
  state=$(jq --argjson f "${failures}" '.media_check_failures = $f' <<<"${state}")
  alert_state_write "${state}"

  local is_bad=false
  [[ ${failures} -ge ${MEDIA_FAILURE_THRESHOLD} ]] && is_bad=true
  local hostname_lower
  hostname_lower=$(echo "${HOSTNAME_LABEL}" | tr '[:upper:]' '[:lower:]')
  alert_transition "media_unreachable" "${is_bad}" \
    "[${HOSTNAME_LABEL}] Plex cannot read media files" \
    "Plex has failed to read a media file on ${failures} checks in a row (checked every 5 minutes).
Its API still answers, so Plex is running, but playback will fail.

Item:   ${title}
File:   ${file:-unknown}
Result: ${failure}

Common causes: a macOS privacy prompt waiting on the ${HOSTNAME_LABEL} desktop
(stall-watchdog also alerts on that), or a stale NAS mount.

Check: ssh ${hostname_lower} and look at the desktop, or ls -l the file above
Log:   ${LOG_FILE}" \
    "RESOLVED: [${HOSTNAME_LABEL}] Plex can read media files again" \
    "Plex read ${title} successfully. No action required." || true
}

# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

main() {
  mkdir -p "${CONFIG_DIR}"
  mkdir -p "$(dirname "${LOG_FILE}")"

  # Step 1: Get Plex token
  local token
  token=$(get_plex_token)

  # Step 2: Fetch prefs XML
  local xml
  if ! xml=$(fetch_prefs_xml "${token}") || [[ -z "${xml}" ]]; then
    # Plex unreachable — handle consecutive failures
    local failures
    failures=$(alert_state_get "consecutive_failures" "0")
    ((failures += 1))

    local state
    state=$(alert_state_read | jq --argjson f "${failures}" '.consecutive_failures = $f | .last_poll = (now | todate)' 2>/dev/null) || state="{\"consecutive_failures\": ${failures}}"
    alert_state_write "${state}"

    if [[ ${failures} -ge ${CONSECUTIVE_FAILURE_THRESHOLD} ]]; then
      log "ERROR: Plex unreachable for ${failures} consecutive polls"
      if [[ ${failures} -eq ${CONSECUTIVE_FAILURE_THRESHOLD} ]]; then
        # tr, not ${HOSTNAME_LABEL,,}: the LaunchAgent runs /bin/bash 3.2,
        # where ,, is a "bad substitution" and this email was never built.
        local unreachable_host_lower
        unreachable_host_lower=$(echo "${HOSTNAME_LABEL}" | tr '[:upper:]' '[:lower:]')
        send_email \
          "[${HOSTNAME_LABEL}] Plex server unreachable" \
          "The Plex server at ${PLEX_URL} has been unreachable for ${failures} consecutive checks ($((failures * 5)) minutes).

Please verify Plex is running:
  ssh operator@${unreachable_host_lower} 'pgrep -f \"Plex Media Server\"'" || true
      fi
    else
      log "WARNING: Plex unreachable (${failures}/${CONSECUTIVE_FAILURE_THRESHOLD} before alert)"
    fi
    return 0
  fi

  # Step 2b: Can Plex read its media? Runs before the fast path below, which
  # returns early on almost every cycle.
  check_media_access "${token}"

  # Step 3: Fast-path hash check
  local current_hash
  current_hash=$(printf '%s' "${xml}" | shasum -a 256 | cut -d' ' -f1)
  local stored_hash
  stored_hash=$(alert_state_get "response_hash" "")

  if [[ "${current_hash}" == "${stored_hash}" ]]; then
    # No change — check if heartbeat is due
    maybe_heartbeat
    return 0
  fi

  # Step 4: Parse prefs (hash changed, need detailed comparison)
  local current_prefs
  if ! current_prefs=$(parse_prefs_xml "${xml}"); then
    log "ERROR: Failed to parse Plex prefs XML — preserving last known good state"
    return 0
  fi

  # Step 5: Load golden config
  local golden_prefs
  golden_prefs=$(load_golden) || exit 1

  # Step 6: Compare
  local drift_found=false
  local drift_report=""
  local new_settings_json="{}"

  # Read state once before the loop to avoid repeated file reads
  local cached_state
  cached_state=$(alert_state_read)

  while IFS='=' read -r golden_key golden_value; do
    [[ -z "${golden_key}" ]] && continue

    # Find current value for this key (awk for exact match — avoids regex injection)
    local current_value
    current_value=$(echo "${current_prefs}" | awk -F= -v k="${golden_key}" '$1 == k {print substr($0, length(k)+2); exit}') || true

    # Build settings entry (use --arg for safe key interpolation)
    local was_alerted alerted_value
    was_alerted=$(echo "${cached_state}" | jq -r --arg k "${golden_key}" '.settings[$k].alerted // false' 2>/dev/null) || was_alerted="false"
    alerted_value=$(echo "${cached_state}" | jq -r --arg k "${golden_key}" '.settings[$k].alerted_value // empty' 2>/dev/null) || alerted_value=""

    if [[ "${current_value}" != "${golden_value}" ]]; then
      drift_found=true

      if [[ "${was_alerted}" != "true" ]] || [[ "${alerted_value}" != "${current_value}" ]]; then
        # New drift or drift changed — need to alert
        log "DRIFT DETECTED: ${golden_key} golden=${golden_value} current=${current_value}"
        drift_report="${drift_report}
  ${golden_key}
    Golden:  ${golden_value}
    Current: ${current_value}
"
        new_settings_json=$(echo "${new_settings_json}" | jq \
          --arg k "${golden_key}" \
          --arg v "${current_value}" \
          '.[$k] = {"current": $v, "alerted": true, "alerted_value": $v}')
      else
        # Already alerted for this exact drift — preserve state, stay quiet
        new_settings_json=$(echo "${new_settings_json}" | jq \
          --arg k "${golden_key}" \
          --arg v "${current_value}" \
          '.[$k] = {"current": $v, "alerted": true, "alerted_value": $v}')
      fi
    else
      # Setting matches golden — check if it was previously drifted
      if [[ "${was_alerted}" == "true" ]]; then
        log "RESOLVED: ${golden_key} returned to golden value (${golden_value})"
        send_email \
          "[${HOSTNAME_LABEL}] Plex setting drift resolved" \
          "The following setting has returned to its golden configuration value:

  ${golden_key}: ${golden_value}

No action required." || true
      fi

      new_settings_json=$(echo "${new_settings_json}" | jq \
        --arg k "${golden_key}" \
        --arg v "${current_value}" \
        '.[$k] = {"current": $v, "alerted": false, "alerted_value": null}')
    fi
  done <<<"${golden_prefs}"

  # Step 7: Send drift alert email if new drifts found
  if [[ -n "${drift_report}" ]]; then
    local hostname_lower
    hostname_lower=$(echo "${HOSTNAME_LABEL}" | tr '[:upper:]' '[:lower:]')

    local email_body="The following Plex settings have drifted from the golden configuration:
${drift_report}
To review:   ssh operator@${hostname_lower} plex-watchdog-ctl status
To accept:   ssh operator@${hostname_lower} plex-watchdog-ctl accept
To revert:   ssh operator@${hostname_lower} plex-watchdog-ctl revert"

    if send_email "[${HOSTNAME_LABEL}] Plex setting drift detected" "${email_body}"; then
      log "Drift alert email sent to ${MONITORING_EMAIL}"
    else
      log "ERROR: Failed to send drift alert email"
    fi
  fi

  # Step 8: Save state
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local last_heartbeat
  last_heartbeat=$(alert_state_get "last_heartbeat" "${now}")

  # Update these keys in place. Rebuilding the file would drop the media
  # check's .media_check_failures and .transitions.
  local base_state
  base_state=$(alert_state_read)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"${base_state}" || base_state='{}'

  local new_state
  new_state=$(jq \
    --arg lp "${now}" \
    --arg lh "${last_heartbeat}" \
    --arg rh "${current_hash}" \
    --argjson cf 0 \
    --argjson settings "${new_settings_json}" \
    '.last_poll = $lp
      | .last_heartbeat = $lh
      | .response_hash = $rh
      | .consecutive_failures = $cf
      | .settings = $settings' <<<"${base_state}")

  alert_state_write "${new_state}"

  if [[ "${drift_found}" == "false" ]]; then
    maybe_heartbeat
  fi
}

# ---------------------------------------------------------------------------
# Heartbeat — log once per hour that everything is OK
# ---------------------------------------------------------------------------

maybe_heartbeat() {
  local last_heartbeat
  last_heartbeat=$(alert_state_get "last_heartbeat" "1970-01-01T00:00:00Z")

  local now_epoch last_epoch
  now_epoch=$(date +%s)

  # Convert ISO timestamp to epoch (macOS date). -u: the stored value is UTC;
  # parsed as local time, it lands in the future west of UTC.
  last_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${last_heartbeat}" '+%s' 2>/dev/null) || last_epoch=0

  local elapsed=$((now_epoch - last_epoch))
  if [[ ${elapsed} -ge ${HEARTBEAT_INTERVAL_SECONDS} ]]; then
    local setting_count
    setting_count=$(load_golden 2>/dev/null | wc -l | tr -d ' ')
    log "OK: ${setting_count} settings monitored, no drift"

    # Update heartbeat timestamp in state
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local state
    state=$(alert_state_read | jq --arg lh "${now}" '.last_heartbeat = $lh')
    alert_state_write "${state}"
  fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main "$@"
