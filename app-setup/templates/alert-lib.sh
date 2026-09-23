# shellcheck shell=bash
#
# alert-lib.sh — shared alert email and JSON state helpers for the watchdogs
#
# SOURCED, not executed. Deployed to ~operator/.local/lib/alert-lib.sh (mode
# 0644) by msmtp-setup.sh, plex-watchdog-setup.sh and
# podman-transmission-setup.sh. See docs/apps/monitoring-README.md.
#
# Why this exists: the watchdogs used to call a bare `msmtp ... 2>/dev/null`.
# launchd starts agents with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which does not
# include Homebrew, so every alert sent from a LaunchAgent failed with "command
# not found" — and the 2>/dev/null threw the only evidence away. Interactive
# test sends passed because a login shell has Homebrew on PATH. This library
# resolves msmtp by absolute path and logs msmtp's stderr on failure.
#
# Must stay compatible with /bin/bash 3.2: the LaunchAgents run the watchdogs
# with /bin/bash. No associative arrays, no ${var,,}, no EPOCHSECONDS.
#
# It sets no shell options and does not change PATH. jq and date are resolved
# from the caller's PATH.
#
# Variables the caller sets:
#   MONITORING_EMAIL      recipient (required by alert_send)
#   STATE_FILE            JSON state file (required by the alert_state_* and
#                         alert_transition functions); its directory must exist
#   log()                 optional; used for log lines if defined, otherwise
#                         lines go to stderr
#
# Optional overrides:
#   ALERT_MSMTP             msmtp binary (default <HOMEBREW_PREFIX>/bin/msmtp)
#   HOMEBREW_PREFIX         default derived from the CPU: /opt/homebrew on
#                           arm64, /usr/local otherwise
#   ALERT_MSMTP_CONFIG      msmtp config (default ~/.config/msmtp/config)
#   ALERT_REMINDER_SECONDS  alert_transition resends a still-open alert after
#                           this many seconds (unset or 0: never)
#
# Functions:
#   alert_send SUBJECT BODY
#   alert_state_read
#   alert_state_get KEY [DEFAULT]
#   alert_state_write JSON
#   alert_transition KEY IS_BAD SUBJECT BODY [RECOVERY_SUBJECT [RECOVERY_BODY]]

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "alert-lib.sh is a library: source it, do not run it" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_alert_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$1"
  else
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [alert-lib] %s\n' "${timestamp}" "$1" >&2
  fi
}

# ---------------------------------------------------------------------------
# Email
# ---------------------------------------------------------------------------

_alert_msmtp_path() {
  if [[ -n "${ALERT_MSMTP:-}" ]]; then
    printf '%s' "${ALERT_MSMTP}"
    return 0
  fi

  local prefix="${HOMEBREW_PREFIX:-}"
  if [[ -z "${prefix}" ]]; then
    case "$(uname -m)" in
      arm64) prefix="/opt/homebrew" ;;
      *) prefix="/usr/local" ;;
    esac
  fi
  printf '%s' "${prefix}/bin/msmtp"
}

# Send one email. Returns 0 only if msmtp accepted the message. On any failure
# it logs an ERROR line saying why, including msmtp's own stderr, and returns 1.
alert_send() {
  local subject="$1"
  local body="$2"

  local msmtp
  msmtp="$(_alert_msmtp_path)"
  local config="${ALERT_MSMTP_CONFIG:-${HOME}/.config/msmtp/config}"

  if [[ -z "${MONITORING_EMAIL:-}" ]]; then
    _alert_log "ERROR: MONITORING_EMAIL is not set — cannot send email '${subject}'"
    return 1
  fi

  if [[ ! -x "${msmtp}" ]]; then
    _alert_log "ERROR: msmtp not found or not executable at ${msmtp} — cannot send email '${subject}'"
    return 1
  fi

  if [[ ! -f "${config}" ]]; then
    _alert_log "ERROR: msmtp config not found at ${config} — cannot send email '${subject}'"
    return 1
  fi

  # stderr goes into $err (for the log); msmtp's stdout is empty in send mode.
  local err=""
  local rc=0
  err="$(printf 'Subject: %s\nTo: %s\n\n%s\n' "${subject}" "${MONITORING_EMAIL}" "${body}" \
    | "${msmtp}" -C "${config}" "${MONITORING_EMAIL}" 2>&1 >/dev/null)" || rc=$?

  # One log line per call: fold msmtp's multi-line output.
  err="${err//$'\n'/ | }"

  if [[ ${rc} -ne 0 ]]; then
    _alert_log "ERROR: msmtp (${msmtp}) exited ${rc} sending '${subject}': ${err:-<no stderr>}"
    return 1
  fi

  if [[ -n "${err}" ]]; then
    _alert_log "WARNING: msmtp sent '${subject}' but wrote to stderr: ${err}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# JSON state (atomic write via temp+mv)
# ---------------------------------------------------------------------------

alert_state_read() {
  local file="${STATE_FILE:?alert-lib: STATE_FILE is not set}"
  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    echo '{}'
  fi
}

alert_state_write() {
  local state="$1"
  local file="${STATE_FILE:?alert-lib: STATE_FILE is not set}"
  local tmp="${file}.tmp.$$"
  printf '%s\n' "${state}" >"${tmp}"
  mv "${tmp}" "${file}"
}

# KEY is a jq path below the root (e.g. "alerted"). A missing, null or false
# value yields DEFAULT: jq's // operator treats false as absent.
alert_state_get() {
  local key="$1"
  local default="${2:-}"
  local val
  val=$(alert_state_read | jq -r ".${key} // empty" 2>/dev/null) || true
  printf '%s' "${val:-${default}}"
}

# ---------------------------------------------------------------------------
# Transition alerts
#
# alert_transition KEY IS_BAD SUBJECT BODY [RECOVERY_SUBJECT [RECOVERY_BODY]]
#
# Call once per run per condition. IS_BAD is "true" (or 1) when the condition
# is bad now, anything else when it is fine. State lives in
# .transitions[KEY] = {alerted, since, last_sent} in STATE_FILE (since and
# last_sent are epoch seconds). Other keys in the file are never touched.
#
#   bad,  not yet alerted   → send SUBJECT/BODY; mark alerted only if the send
#                             succeeded, so a failed send retries next call
#   bad,  already alerted   → quiet, unless ALERT_REMINDER_SECONDS is set and
#                             that long has passed since last_sent: then resend
#                             with "[reminder] " before the subject
#   good, was alerted       → send the recovery email (best effort), reset
#   good, never alerted     → reset
#
# Returns 1 if an alert or reminder send failed (it stays pending and is
# retried next call), else 0. Callers under set -e should use `|| true`.
# ---------------------------------------------------------------------------

alert_transition() {
  local key="$1"
  local is_bad="$2"
  local subject="$3"
  local body="$4"
  local recovery_subject="${5:-}"
  local recovery_body="${6:-}"

  local state
  state="$(alert_state_read)"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${state}"; then
    _alert_log "ERROR: state file ${STATE_FILE:-} is not a JSON object — starting it fresh"
    state='{}'
  fi

  local entry
  entry="$(jq -c --arg k "${key}" '.transitions[$k] // {}' <<<"${state}")"

  local alerted since last_sent
  alerted="$(jq -r '.alerted // false' <<<"${entry}")"
  since="$(jq -r '.since // empty' <<<"${entry}")"
  last_sent="$(jq -r '.last_sent // empty' <<<"${entry}")"
  # Both are epoch seconds; drop anything else (e.g. a hand-edited value).
  [[ "${since}" =~ ^[0-9]+$ ]] || since=""
  [[ "${last_sent}" =~ ^[0-9]+$ ]] || last_sent=""

  local now
  now="$(date +%s)"

  if [[ "${is_bad}" != "true" ]] && [[ "${is_bad}" != "1" ]]; then
    if [[ "${entry}" == "{}" ]]; then
      return 0
    fi
    if [[ "${alerted}" == "true" ]]; then
      _alert_log "RESOLVED: ${key}"
      local since_text="unknown"
      if [[ -n "${since}" ]]; then
        since_text="$(date -u -r "${since}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)" || since_text="${since}"
      fi
      alert_send \
        "${recovery_subject:-RESOLVED: ${subject}}" \
        "${recovery_body:-This condition has cleared:

  ${subject}

First seen: ${since_text}

No action required.}" || true
    fi
    state="$(jq --arg k "${key}" 'del(.transitions[$k])' <<<"${state}")"
    alert_state_write "${state}"
    return 0
  fi

  [[ -n "${since}" ]] || since="${now}"

  local send_subject=""
  if [[ "${alerted}" != "true" ]]; then
    send_subject="${subject}"
  elif [[ "${ALERT_REMINDER_SECONDS:-0}" =~ ^[0-9]+$ ]] \
    && [[ "${ALERT_REMINDER_SECONDS:-0}" -gt 0 ]] \
    && [[ -n "${last_sent}" ]] \
    && [[ $((now - last_sent)) -ge ${ALERT_REMINDER_SECONDS} ]]; then
    send_subject="[reminder] ${subject}"
  fi

  local rc=0
  if [[ -n "${send_subject}" ]]; then
    if alert_send "${send_subject}" "${body}"; then
      alerted=true
      last_sent="${now}"
    else
      rc=1
    fi
  fi

  [[ "${alerted}" == "true" ]] || alerted=false

  state="$(jq \
    --arg k "${key}" \
    --argjson al "${alerted}" \
    --argjson si "${since}" \
    --arg ls "${last_sent}" \
    '.transitions[$k] = {
      alerted: $al,
      since: $si,
      last_sent: (if $ls == "" then null else ($ls | tonumber) end)
    }' <<<"${state}")"
  alert_state_write "${state}"
  return "${rc}"
}
