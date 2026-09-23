#!/usr/bin/env bash
#
# stall-watchdog.sh — alert when the server is blocked rather than broken
#
# On 2026-09-17 a macOS privacy (TCC) prompt asking whether bash could access a
# network volume sat unanswered on the desktop for 19 hours. FileBot, the
# Transmission container and Plex all waited on it, and nothing alerted:
# every watchdog checks for failure, and a process waiting on a dialog has not
# failed. #198 fixed that prompt's cause; this watchdog is the backstop for the
# next one (issue #199). It runs three checks, each with its own alert:
#
#   1. A TCC prompt open for 5 minutes or more. The user-domain tccd logs
#      AUTHREQ_PROMPTING when a dialog opens and AUTHREQ_RESULT with the same
#      msgID when it is answered. tccd's log lines do not survive long, so
#      open prompts are kept in this watchdog's own state until answered.
#   2. transmission-done running for more than 45 minutes. Normal runs take
#      seconds to a few minutes. It is never killed: killing FileBot mid-move
#      risks losing the file.
#   3. The podman supervisor failing repeatedly, or not reporting at all. The
#      supervisor loop writes a status file each cycle; a missing file means
#      "unknown" and alerts nothing, so this watchdog can be deployed before
#      the supervisor is restarted with the status-writing wrapper.
#
# Each invocation is a single poll cycle, driven by a LaunchAgent every two
# minutes. See docs/apps/monitoring-README.md.
#
# Must stay compatible with /bin/bash 3.2: the LaunchAgent runs it with
# /bin/bash.
#
# Template placeholders (replaced by podman-transmission-setup.sh at deploy time):
#   __SERVER_NAME__        → server hostname for logging (e.g. TILSIT)
#   __MONITORING_EMAIL__   → destination email address
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-09-23

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

SERVER_NAME="__SERVER_NAME__"
export MONITORING_EMAIL="__MONITORING_EMAIL__" # read by alert-lib.sh
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"

STATE_DIR="${HOME}/.config/stall-watchdog"
export STATE_FILE="${STATE_DIR}/state.json" # read by alert-lib.sh
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-stall-watchdog.log"
ALERT_LIB="${ALERT_LIB:-${HOME}/.local/lib/alert-lib.sh}"
SUPERVISOR_STATUS_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-supervisor-status.json"

# The unified-log CLI, by absolute path. `log` would be this script's own log()
# function. Overridable so the tests can feed it fixture lines.
TCC_LOG_BIN="${TCC_LOG_BIN:-/usr/bin/log}"

TCC_PROMPT_THRESHOLD_SECONDS=300
# Each scan starts a little before the previous one ended, so a line logged
# while the last scan ran is not missed. After a long gap (sleep, a stopped
# agent) catch up at most an hour: a 1-hour query takes about 3 s. A prompt
# that opened before that is expected, but not verified, to be logged again
# on the next access attempt (see "Not yet proven" in the monitoring README).
TCC_SCAN_OVERLAP_SECONDS=60
TCC_SCAN_MAX_LOOKBACK_SECONDS=3600
TCC_FIRST_SCAN_SECONDS=360
TCC_SCAN_FAILURE_THRESHOLD=3

DONE_MAX_SECONDS=2700

SUPERVISOR_FAILURE_THRESHOLD=3
# The supervisor loop sleeps 5 minutes between cycles, and a bad cycle can
# spend several bounded podman timeouts on top. An hour with no status update
# means the loop is hung or gone.
SUPERVISOR_STALE_SECONDS=3600

# A stall can last all day (the 2026-09-17 prompt lasted 19 hours). Resend an
# open alert twice a day rather than once and never again.
export ALERT_REMINDER_SECONDS=43200

HEARTBEAT_INTERVAL_SECONDS=3600

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [stall-watchdog] %s\n' "${timestamp}" "$1" >>"${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Shared alert library: alert_send, alert_transition, and the alert_state_*
# helpers on STATE_FILE. Deployed by podman-transmission-setup.sh.
# ---------------------------------------------------------------------------

if [[ ! -r "${ALERT_LIB}" ]]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  log "ERROR: alert library not found at ${ALERT_LIB} — cannot send alerts. Re-run podman-transmission-setup.sh"
  exit 1
fi
# shellcheck source=/dev/null
source "${ALERT_LIB}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# "3h 12m" from seconds ("9s" under a minute).
human_duration() {
  local s="$1"
  local d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
  if [[ ${d} -gt 0 ]]; then
    printf '%dd %dh %dm' "${d}" "${h}" "${m}"
  elif [[ ${h} -gt 0 ]]; then
    printf '%dh %dm' "${h}" "${m}"
  elif [[ ${m} -gt 0 ]]; then
    printf '%dm' "${m}"
  else
    printf '%ds' "${s}"
  fi
}

epoch_to_local() {
  date -r "$1" '+%Y-%m-%d %H:%M:%S %Z'
}

# ps etime ([[dd-]hh:]mm:ss) to seconds. 10# because "08" is not octal.
etime_seconds() {
  local e="$1" d=0 h=0 m=0 s=0 a b c
  if [[ "${e}" == *-* ]]; then
    d="${e%%-*}"
    e="${e#*-}"
  fi
  IFS=: read -r a b c <<<"${e}"
  if [[ -n "${c}" ]]; then
    h="${a}"
    m="${b}"
    s="${c}"
  else
    m="${a}"
    s="${b}"
  fi
  printf '%d' $((10#${d} * 86400 + 10#${h} * 3600 + 10#${m} * 60 + 10#${s}))
}

# ---------------------------------------------------------------------------
# Check 1: pending TCC prompts
#
# State: .tcc_prompts["<tccd pid>/<msgID>"] = {since, service, subject, tccd_pid}
#        .tcc_last_scan (epoch), .tcc_scan_failures
#
# The key includes tccd's own pid. A msgID is "<client pid>.<sequence>", and
# the same client (sandboxd, in the 09-23 prompt) talks to both the system
# tccd and the per-user one, each with its own sequence. A RESULT from the
# other tccd can carry the same msgID; matching on msgID alone would close a
# prompt that is still on screen.
#
# An open entry is never dropped just because it is old: that would send a
# false recovery email for a prompt still blocking the server. It is closed
# only by its RESULT line, or because the tccd that owns it has exited (the
# dialog went with it). To clear one by hand, see the monitoring README.
# ---------------------------------------------------------------------------

# Print {ts, pid, msg} per matching tccd line since START ("YYYY-MM-DD HH:MM:SS",
# local time). The final {"count":..,"finished":1} record has no eventMessage.
tcc_query() {
  local start="$1" contains="$2"
  local raw err_file err rc=0
  # stderr to a file, not into $raw: a warning mixed into the ndjson would make
  # the whole batch unparseable.
  err_file="$(mktemp)"
  raw="$("${TCC_LOG_BIN}" show --start "${start}" --style ndjson \
    --predicate "process == \"tccd\" AND eventMessage CONTAINS \"${contains}\"" 2>"${err_file}")" || rc=$?
  err="$(cat "${err_file}")"
  rm -f "${err_file}"
  if [[ ${rc} -ne 0 ]]; then
    log "ERROR: '${TCC_LOG_BIN} show' exited ${rc}: ${err//$'\n'/ | }"
    return 1
  fi
  jq -c 'select(.eventMessage != null)
    | {ts: .timestamp, pid: .processID, msg: .eventMessage}' <<<"${raw}" 2>/dev/null || {
    log "ERROR: could not parse '${TCC_LOG_BIN} show' output as ndjson"
    return 1
  }
}

# "2026-09-23 09:22:13.080738-0700" to epoch. The zone offset is honored, so
# the result does not depend on this process's TZ.
log_ts_epoch() {
  local trimmed
  trimmed="$(sed -E 's/\.[0-9]+//' <<<"$1")"
  date -j -f '%Y-%m-%d %H:%M:%S%z' "${trimmed}" '+%s' 2>/dev/null
}

tccd_alive() {
  local comm
  comm="$(ps -p "$1" -o comm= 2>/dev/null)" || return 1
  [[ "${comm}" == *tccd* ]]
}

# Set by scan_tcc for the recovery email.
TCC_CLOSED_TEXT=""

# Update .tcc_prompts from the log. Returns 1 if the log could not be read, in
# which case state is left exactly as it was.
scan_tcc() {
  local now="$1"
  local last_scan start
  last_scan="$(alert_state_get tcc_last_scan "")"
  if is_uint "${last_scan}"; then
    start=$((last_scan - TCC_SCAN_OVERLAP_SECONDS))
    if [[ ${start} -lt $((now - TCC_SCAN_MAX_LOOKBACK_SECONDS)) ]]; then
      start=$((now - TCC_SCAN_MAX_LOOKBACK_SECONDS))
    fi
  else
    start=$((now - TCC_FIRST_SCAN_SECONDS))
  fi
  local start_str
  start_str="$(date -r "${start}" '+%Y-%m-%d %H:%M:%S')"

  local prompts
  prompts="$(tcc_query "${start_str}" "AUTHREQ_PROMPTING")" || return 1

  local state
  state="$(alert_state_read)"

  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    local parsed id service subject pid ts since
    parsed="$(jq -r '
      (.msg | capture("msgID=(?<id>[^,]+), service=(?<service>[^,]+), subject=Sub:\\{(?<subject>[^}]*)\\}")) as $m
      | [(.pid | tostring), $m.id, $m.service, $m.subject, .ts] | @tsv' <<<"${line}" 2>/dev/null)" || parsed=""
    if [[ -z "${parsed}" ]]; then
      local raw_msg
      raw_msg="$(jq -r '.msg' <<<"${line}")" || raw_msg="${line}"
      log "WARNING: unrecognized AUTHREQ_PROMPTING line: ${raw_msg}"
      continue
    fi
    IFS=$'\t' read -r pid id service subject ts <<<"${parsed}"
    since="$(log_ts_epoch "${ts}")" || since="${now}"
    is_uint "${since}" || since="${now}"

    local key="${pid}/${id}" known
    known="$(jq -r --arg k "${key}" '.tcc_prompts[$k] // empty | .since' <<<"${state}")"
    if [[ -z "${known}" ]]; then
      log "TCC prompt opened: ${service} for ${subject} (tccd ${pid}, msgID ${id})"
      state="$(jq --arg k "${key}" --argjson si "${since}" --arg sv "${service}" \
        --arg sb "${subject}" --argjson tp "${pid}" \
        '.tcc_prompts[$k] = {since: $si, service: $sv, subject: $sb, tccd_pid: $tp}' <<<"${state}")"
    fi
  done <<<"${prompts}"

  TCC_CLOSED_TEXT=""
  local open_keys
  open_keys="$(jq -r '.tcc_prompts // {} | keys[]' <<<"${state}")"
  if [[ -n "${open_keys}" ]]; then
    local results answered
    results="$(tcc_query "${start_str}" "AUTHREQ_RESULT")" || return 1
    # "<tccd pid>/<msgID><TAB><log timestamp>" for every answer in the window.
    answered="$(jq -r '[(.pid | tostring) + "/" + (.msg | capture("msgID=(?<id>[^,]+),").id), .ts] | @tsv' \
      <<<"${results}" 2>/dev/null)" || answered=""

    local key
    while IFS= read -r key; do
      [[ -n "${key}" ]] || continue
      local entry reason="" owner answer_ts closed_at="${now}"
      entry="$(jq -c --arg k "${key}" '.tcc_prompts[$k]' <<<"${state}")"
      owner="$(jq -r '.tccd_pid' <<<"${entry}")"
      answer_ts="$(awk -F'\t' -v k="${key}" '$1 == k { print $2; exit }' <<<"${answered}")"
      if [[ -n "${answer_ts}" ]]; then
        reason="answered"
        closed_at="$(log_ts_epoch "${answer_ts}")" || closed_at="${now}"
        is_uint "${closed_at}" || closed_at="${now}"
      elif ! tccd_alive "${owner}"; then
        reason="its tccd process exited, taking the dialog with it"
      fi
      if [[ -n "${reason}" ]]; then
        local e_since e_service e_subject e_open e_opened
        e_since="$(jq -r '.since' <<<"${entry}")"
        e_service="$(jq -r '.service' <<<"${entry}")"
        e_subject="$(jq -r '.subject' <<<"${entry}")"
        e_open="$(human_duration $((closed_at - e_since)))"
        e_opened="$(epoch_to_local "${e_since}")"
        log "TCC prompt closed (${reason}): ${e_service} for ${e_subject}, open ${e_open}"
        TCC_CLOSED_TEXT+="  ${e_service} for ${e_subject}
    opened ${e_opened}, closed after ${e_open}: ${reason}
"
        state="$(jq --arg k "${key}" 'del(.tcc_prompts[$k])' <<<"${state}")"
      fi
    done <<<"${open_keys}"
  fi

  state="$(jq --argjson now "${now}" '.tcc_last_scan = $now | .tcc_scan_failures = 0' <<<"${state}")"
  alert_state_write "${state}"
  return 0
}

check_tcc() {
  local now
  now="$(date +%s)"

  if ! scan_tcc "${now}"; then
    local failures
    failures="$(alert_state_get tcc_scan_failures 0)"
    is_uint "${failures}" || failures=0
    failures=$((failures + 1))
    local state
    state="$(alert_state_read)"
    state="$(jq --argjson f "${failures}" '.tcc_scan_failures = $f' <<<"${state}")"
    alert_state_write "${state}"
    local unreadable=false
    [[ ${failures} -ge ${TCC_SCAN_FAILURE_THRESHOLD} ]] && unreadable=true
    alert_transition "tcc_log_unreadable" "${unreadable}" \
      "[${SERVER_NAME}] stall-watchdog cannot read the system log" \
      "stall-watchdog has failed to read tccd's log lines ${failures} times in a row, so it cannot see macOS privacy prompts.

Its log has the error: ${LOG_FILE}
Try: sudo -u $(id -un) /usr/bin/log show --last 5m --predicate 'process == \"tccd\"'" || true
    return 0
  fi
  alert_transition "tcc_log_unreadable" false "[${SERVER_NAME}] stall-watchdog cannot read the system log" "" || true

  local state stale_count
  state="$(alert_state_read)"
  stale_count="$(jq --argjson now "${now}" --argjson t "${TCC_PROMPT_THRESHOLD_SECONDS}" \
    '[.tcc_prompts // {} | to_entries[] | select($now - .value.since >= $t)] | length' <<<"${state}")"

  local bad=false body=""
  if [[ "${stale_count}" -gt 0 ]]; then
    bad=true
    local listing
    listing="$(jq -r --argjson now "${now}" '
      .tcc_prompts // {} | to_entries | sort_by(.value.since)[]
      | "  \(.value.service)\n    for \(.value.subject)\n    open \(($now - .value.since) / 60 | floor) min (tccd pid/msgID \(.key))"' <<<"${state}")"
    body="A macOS privacy prompt has been waiting for an answer for 5 minutes or more.
Whatever triggered it is blocked until someone answers it, and on this server
that usually means FileBot, Transmission or Plex.

Open prompts:
${listing}

Fix: log in to the ${SERVER_NAME} desktop (Screen Sharing works) and click Allow,
or Don't Allow if the program should not have access.

A second prompt that opens while this alert is active does not send a new
email; it shows up in this list and in the reminder. Reminders repeat every
12 hours while any prompt stays open.
Log: ${LOG_FILE}"
  fi

  alert_transition "tcc_prompt" "${bad}" \
    "[${SERVER_NAME}] macOS privacy prompt is blocking the server" \
    "${body}" \
    "RESOLVED: [${SERVER_NAME}] macOS privacy prompt answered" \
    "No macOS privacy prompt has been open for 5 minutes or more.

Closed this cycle:
${TCC_CLOSED_TEXT:-  (none recorded; the prompt may have been cleared by hand)}" || true
}

# ---------------------------------------------------------------------------
# Check 2: transmission-done running too long
# ---------------------------------------------------------------------------

check_done() {
  local out
  out="$(ps -axo pid=,etime=,command= 2>&1)" || {
    log "ERROR: ps failed: ${out}"
    return 0
  }

  local long="" pid etime cmd secs
  while read -r pid etime cmd; do
    [[ "${cmd}" == *transmission-done* ]] || continue
    [[ "${cmd}" == *stall-watchdog* ]] && continue
    is_uint "${pid}" || continue
    secs="$(etime_seconds "${etime}")"
    if [[ ${secs} -ge ${DONE_MAX_SECONDS} ]]; then
      long+="  pid ${pid}, running $(human_duration "${secs}"): ${cmd}
"
    fi
  done <<<"${out}"

  local bad=false
  [[ -n "${long}" ]] && bad=true
  alert_transition "done_running_long" "${bad}" \
    "[${SERVER_NAME}] transmission-done has been running for over 45 minutes" \
    "A transmission-done run normally takes seconds to a few minutes. These have
run for more than 45 minutes:

${long}
Common causes: a macOS privacy prompt waiting on the desktop, a hung NFS
mount, or FileBot stuck on a network call. Nothing has been killed: stopping
FileBot mid-move can lose the file.

Check: tail -50 ~/.local/state/transmission-processing.log
Log: ${LOG_FILE}" || true
}

# ---------------------------------------------------------------------------
# Check 3: podman supervisor
#
# The supervisor wrapper writes SUPERVISOR_STATUS_FILE at the end of every
# cycle: {consecutive_failures, last_error, updated_at (epoch)}.
# ---------------------------------------------------------------------------

check_supervisor() {
  if [[ ! -f "${SUPERVISOR_STATUS_FILE}" ]]; then
    # Unknown, not bad: the wrapper that writes this file is deployed only when
    # the supervisor is next restarted.
    return 0
  fi

  local status failures last_error updated
  status="$(cat "${SUPERVISOR_STATUS_FILE}")"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${status}"; then
    log "ERROR: ${SUPERVISOR_STATUS_FILE} is not a JSON object — skipping the supervisor check"
    return 0
  fi
  failures="$(jq -r '.consecutive_failures // 0' <<<"${status}")"
  last_error="$(jq -r '.last_error // ""' <<<"${status}")"
  updated="$(jq -r '.updated_at // empty' <<<"${status}")"
  is_uint "${failures}" || failures=0

  local now
  now="$(date +%s)"

  local failing=false
  [[ ${failures} -ge ${SUPERVISOR_FAILURE_THRESHOLD} ]] && failing=true
  alert_transition "supervisor_failing" "${failing}" \
    "[${SERVER_NAME}] podman supervisor has failed ${failures} cycles in a row" \
    "The supervisor that keeps the Transmission VM and container running has
failed ${failures} consecutive cycles.

Last error: ${last_error:-unknown}

Check: tail -50 ~/.local/state/${HOSTNAME_LOWER}-podman-vm-stdout.log
Status file: ${SUPERVISOR_STATUS_FILE}" || true

  local stale=false age_text="never"
  if is_uint "${updated}"; then
    local age updated_local
    age="$(human_duration $((now - updated)))"
    updated_local="$(epoch_to_local "${updated}")"
    age_text="${age} ago (${updated_local})"
    [[ $((now - updated)) -ge ${SUPERVISOR_STALE_SECONDS} ]] && stale=true
  else
    stale=true
  fi
  alert_transition "supervisor_stale" "${stale}" \
    "[${SERVER_NAME}] podman supervisor has stopped reporting" \
    "The supervisor loop writes a status file every cycle (about every 5 minutes).
It was last updated ${age_text}. The loop is hung, or its LaunchAgent is not
running.

Check: launchctl print gui/$(id -u)/com.${HOSTNAME_LOWER}.podman-transmission-vm
Restarting the supervisor restarts the VM: read docs/apps/monitoring-README.md
first." || true
}

# ---------------------------------------------------------------------------
# Heartbeat: log once an hour that the watchdog is alive. Stored as epoch
# seconds, so there is no timestamp to parse.
# ---------------------------------------------------------------------------

maybe_heartbeat() {
  local now last
  now="$(date +%s)"
  last="$(alert_state_get last_heartbeat 0)"
  is_uint "${last}" || last=0
  if [[ $((now - last)) -ge ${HEARTBEAT_INTERVAL_SECONDS} ]]; then
    local state open
    state="$(alert_state_read)"
    open="$(jq '.tcc_prompts // {} | length' <<<"${state}")"
    log "OK: running; ${open} TCC prompt(s) open"
    state="$(jq --argjson n "${now}" '.last_heartbeat = $n' <<<"${state}")"
    alert_state_write "${state}"
  fi
}

main() {
  mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")"
  check_tcc
  check_done
  check_supervisor
  maybe_heartbeat
}

# Entry point — skipped when sourced for tests (TEST_RUNNER=true)
if [[ "${TEST_RUNNER:-false}" != "true" ]]; then
  main "$@"
fi
