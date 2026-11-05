#!/usr/bin/env bash
#
# tvmaze-scrobble: mark a Plex TV episode watched on TVmaze.
# See docs/apps/tvmaze-scrobble-README.md.

# Usage: tvmaze-scrobble [--reconcile | --check] < payload.json

# No argument: one webhook payload on stdin. --reconcile: sync missed plays.

# --check: test the credentials; no scrobble, no email.

# Matching: TVDB id, IMDb id, then one exact TVmaze title match.

# An episode that cannot be synced is logged and emailed once.

# Exit codes: 0 synced, ignored or check passed; 1 not synced or check
# failed; 64 bad usage.

# Placeholders are filled in by tvmaze-scrobble-setup.sh.
# The LaunchAgents run /bin/bash 3.2: no bash 4 features.

# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-11-05

set -euo pipefail

# launchd's PATH has no Homebrew. See docs/apps/monitoring-README.md.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HOSTNAME_LABEL="__HOSTNAME__"
export MONITORING_EMAIL="__MONITORING_EMAIL__" # read by alert-lib.sh
# Webhook filter: Plex's webhook Account.title. Account.id there is a
# plex.tv id, not the server-local id that history uses.
PLEX_ACCOUNT_TITLE="__PLEX_ACCOUNT_TITLE__"
# Reconcile filter: the server-local accountID in Plex watch history.
PLEX_ACCOUNT_ID="__PLEX_ACCOUNT_ID__"

# Injectable for tests. Absolute paths: launchd's PATH is minimal.
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
SLEEP_BIN="${SLEEP_BIN:-/bin/sleep}"
MV_BIN="${MV_BIN:-/bin/mv}"

PLEX_URL="${PLEX_URL:-http://127.0.0.1:32400}"
TVMAZE_API="${TVMAZE_API:-https://api.tvmaze.com}"

CONFIG_DIR="${HOME}/.config/tvmaze-scrobble"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-${CONFIG_DIR}/credentials}"
PLEX_TOKEN_FILE="${PLEX_TOKEN_FILE:-${HOME}/.config/plex-watchdog/token}"
LOG_FILE="${HOME}/.local/state/tvmaze-scrobble.log"
STATE_DIR="${HOME}/.local/state/tvmaze-scrobble"
# One episode ratingKey per line. synced: on TVmaze. failed: emailed once.
SYNCED_FILE="${STATE_DIR}/synced"
FAILED_FILE="${STATE_DIR}/failed"
# Present after the first reconcile run has seeded SYNCED_FILE.
SEEDED_FILE="${STATE_DIR}/seeded"
ALERT_LIB="${ALERT_LIB:-${HOME}/.local/lib/alert-lib.sh}"

RECONCILE_LOOKBACK_DAYS="${RECONCILE_LOOKBACK_DAYS:-7}"
# Seconds between episodes in reconcile mode. TVmaze allows about 20 calls
# per 10 s per IP, and one episode can take 4 calls.
RECONCILE_PAUSE="${RECONCILE_PAUSE:-2}"

CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=20

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [tvmaze-scrobble] %s\n' "${timestamp}" "$1" >>"${LOG_FILE}"
}

# Named jq so every call below goes through JQ_BIN.
jq() {
  "${JQ_BIN}" "$@"
}

# ---------------------------------------------------------------------------
# State: one ratingKey per line
# ---------------------------------------------------------------------------

state_has() {
  [[ -f "$1" ]] && grep -qxF -- "$2" "$1"
}

state_add() {
  state_has "$1" "$2" || printf '%s\n' "$2" >>"$1"
}

state_remove() {
  state_has "$1" "$2" || return 0
  local tmp="$1.tmp.$$"
  grep -vxF -- "$2" "$1" >"${tmp}" || true
  "${MV_BIN}" "${tmp}" "$1"
}

# config_problem KEY MESSAGE: log, and email once until config_ok KEY.

# Without credentials or the Plex token nothing syncs, so this must not be silent.
config_problem() {
  log "ERROR: $2"
  state_has "${FAILED_FILE}" "$1" && return 0
  if alert_send "[${HOSTNAME_LABEL}] TVmaze sync is not working" "$2

Plex plays are not being synced to TVmaze until this is fixed. Re-run
tvmaze-scrobble-setup.sh; see docs/apps/tvmaze-scrobble-README.md.
The hourly reconcile run will catch up on plays from the last
${RECONCILE_LOOKBACK_DAYS} days. This is the only email until it is fixed.
Log: ${LOG_FILE}"; then
    state_add "${FAILED_FILE}" "$1"
  fi
}

config_ok() {
  state_remove "${FAILED_FILE}" "$1"
}

# ---------------------------------------------------------------------------
# Credentials. Passed to curl in a config on stdin (-K -), never on argv.
# ---------------------------------------------------------------------------

TVMAZE_CURL_CONFIG=""
PLEX_CURL_CONFIG=""

# curl config syntax: a quoted value takes \\ and \" escapes.
curl_quote() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "${v}"
}

load_tvmaze_credentials() {
  if [[ ! -r "${CREDENTIALS_FILE}" ]]; then
    log "ERROR: TVmaze credentials not readable at ${CREDENTIALS_FILE}. Re-run tvmaze-scrobble-setup.sh"
    return 1
  fi
  local cred
  cred=$(head -n 1 "${CREDENTIALS_FILE}" | tr -d '\r\n')
  if [[ "${cred}" != *?:?* ]]; then
    log "ERROR: ${CREDENTIALS_FILE} is not in the form username:apikey"
    return 1
  fi
  TVMAZE_CURL_CONFIG="user = $(curl_quote "${cred}")"
}

load_plex_token() {
  local token=""
  if [[ -r "${PLEX_TOKEN_FILE}" ]]; then
    token=$(tr -d '[:space:]' <"${PLEX_TOKEN_FILE}")
  fi
  if [[ -z "${token}" ]]; then
    log "ERROR: Plex token not readable at ${PLEX_TOKEN_FILE}. Run plex-watchdog-setup.sh"
    return 1
  fi
  PLEX_CURL_CONFIG="header = $(curl_quote "X-Plex-Token: ${token}")"
}

# ---------------------------------------------------------------------------
# HTTP. Each call sets HTTP_CODE, HTTP_BODY and CURL_RC, and never fails.
# The status code is the last line of curl's output, so no temp files.
# ---------------------------------------------------------------------------

HTTP_CODE="" HTTP_BODY="" CURL_RC=0

_split_response() {
  HTTP_CODE="${1##*$'\n'}"
  HTTP_BODY="${1%$'\n'*}"
  [[ "${HTTP_CODE}" =~ ^[0-9]{3}$ ]] || HTTP_CODE="000"
}

# http_request CONFIG METHOD URL [BODY]
http_request() {
  local config="$1" method="$2" url="$3" body="${4:-}"
  local out=""
  CURL_RC=0
  local -a args=(-sS --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}"
    -K - -X "${method}" -H "Accept: application/json" -w '\n%{http_code}')
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "${body}")
  fi
  out=$(printf '%s\n' "${config}" | "${CURL_BIN}" "${args[@]}" "${url}" 2>/dev/null) || CURL_RC=$?
  _split_response "${out}"
}

# ---------------------------------------------------------------------------
# Plex
# ---------------------------------------------------------------------------

# plex_show_ids SHOW_RATING_KEY: sets SHOW_TVDB and SHOW_IMDB (empty if
# absent) and PLEX_DETAIL. Returns 1 if Plex did not answer.
plex_show_ids() {
  SHOW_TVDB="" SHOW_IMDB="" PLEX_DETAIL=""
  http_request "${PLEX_CURL_CONFIG}" GET "${PLEX_URL}/library/metadata/$1?includeGuids=1"
  if [[ ${CURL_RC} -ne 0 ]] || [[ "${HTTP_CODE}" != "200" ]]; then
    PLEX_DETAIL="Plex show lookup (key $1) failed: HTTP ${HTTP_CODE}, curl exit ${CURL_RC}"
    return 1
  fi
  local guids
  guids=$(jq -r '.MediaContainer.Metadata[0].Guid[]?.id // empty' <<<"${HTTP_BODY}" 2>/dev/null) || guids=""
  local g
  while IFS= read -r g; do
    case "${g}" in
      tvdb://*) [[ -n "${SHOW_TVDB}" ]] || SHOW_TVDB="${g#tvdb://}" ;;
      imdb://*) [[ -n "${SHOW_IMDB}" ]] || SHOW_IMDB="${g#imdb://}" ;;
      *) ;; # tmdb:// and others: TVmaze does not accept them
    esac
  done <<<"${guids}"
  [[ "${SHOW_TVDB}" =~ ^[0-9]+$ ]] || SHOW_TVDB=""
  [[ "${SHOW_IMDB}" =~ ^tt[0-9]+$ ]] || SHOW_IMDB=""
  PLEX_DETAIL="Plex show ids: tvdb=${SHOW_TVDB:-none} imdb=${SHOW_IMDB:-none}"
  return 0
}

# ---------------------------------------------------------------------------
# TVmaze
# ---------------------------------------------------------------------------

# tvmaze_scrobble QUERY BODY: sets SCROBBLE_RESULT, SCROBBLE_DETAIL, EPISODE_ID.

# ok: item code 200. nomatch (try next id): 404, or 207/422 or item not 200.

# auth: 401, stop. error: no answer, 429, 5xx, stop.
tvmaze_scrobble() {
  local query="$1" body="$2"
  SCROBBLE_RESULT="" SCROBBLE_DETAIL="" EPISODE_ID=""
  http_request "${TVMAZE_CURL_CONFIG}" POST "${TVMAZE_API}/v1/scrobble/shows?${query}" "${body}"

  if [[ ${CURL_RC} -ne 0 ]]; then
    SCROBBLE_RESULT=error
    SCROBBLE_DETAIL="no answer from TVmaze (curl exit ${CURL_RC})"
    return 0
  fi

  local item_code item_msg
  item_code=$(jq -r 'if type == "array" then (.[0].code // empty) else empty end' <<<"${HTTP_BODY}" 2>/dev/null) || item_code=""
  item_msg=$(jq -r 'if type == "array" then .[0] else . end
    | [(.message // empty), ((.errors // {}) | tostring | select(. != "{}"))]
    | join(" ")' <<<"${HTTP_BODY}" 2>/dev/null) || item_msg=""
  item_msg="${item_msg//$'\n'/ }"

  case "${HTTP_CODE}" in
    200 | 207 | 422)
      if [[ "${item_code}" == "200" ]]; then
        SCROBBLE_RESULT=ok
        EPISODE_ID=$(jq -r '.[0].result.episode_id // empty' <<<"${HTTP_BODY}" 2>/dev/null) || EPISODE_ID=""
        SCROBBLE_DETAIL="marked watched (TVmaze episode ${EPISODE_ID:-unknown})"
      elif [[ "${item_code}" == "401" ]]; then
        SCROBBLE_RESULT=auth
        SCROBBLE_DETAIL="item code 401: TVmaze rejected the username or API key"
      elif [[ "${item_code}" == "429" ]] || [[ "${item_code}" =~ ^5[0-9][0-9]$ ]]; then
        # Rate limit or server error for the item: another id would not help.
        SCROBBLE_RESULT=error
        SCROBBLE_DETAIL="HTTP ${HTTP_CODE}, item code ${item_code}${item_msg:+: ${item_msg}}"
      else
        SCROBBLE_RESULT=nomatch
        SCROBBLE_DETAIL="HTTP ${HTTP_CODE}, item code ${item_code:-none}${item_msg:+: ${item_msg}}"
      fi
      ;;
    404)
      SCROBBLE_RESULT=nomatch
      SCROBBLE_DETAIL="HTTP 404${item_msg:+: ${item_msg}}"
      ;;
    401)
      SCROBBLE_RESULT=auth
      SCROBBLE_DETAIL="HTTP 401: TVmaze rejected the username or API key"
      ;;
    *)
      SCROBBLE_RESULT=error
      SCROBBLE_DETAIL="HTTP ${HTTP_CODE}${item_msg:+: ${item_msg}}"
      ;;
  esac
}

# tvmaze_find_show TITLE: sets FIND_DETAIL, and FOUND_ID if exactly one show

# has that name (case and outer spaces ignored). Returns 1 on HTTP error.
tvmaze_find_show() {
  local title="$1" q
  FOUND_ID="" FIND_DETAIL=""
  q=$(jq -rn --arg s "${title}" '$s | @uri')
  # Public endpoint: no credentials.
  http_request "" GET "${TVMAZE_API}/search/shows?q=${q}"
  if [[ ${CURL_RC} -ne 0 ]] || [[ "${HTTP_CODE}" != "200" ]]; then
    FIND_DETAIL="title search failed: HTTP ${HTTP_CODE}, curl exit ${CURL_RC}"
    return 1
  fi
  local ids count
  ids=$(jq -r --arg t "${title}" '
    def norm: ascii_downcase | sub("^\\s+"; "") | sub("\\s+$"; "");
    [.[]?.show | select(type == "object" and (.name // "" | norm) == ($t | norm)) | .id]
    | unique | map(tostring) | join(" ")' <<<"${HTTP_BODY}" 2>/dev/null) || ids=""
  count=$(printf '%s' "${ids}" | wc -w | tr -d '[:space:]')
  if [[ ${count} -eq 1 ]] && [[ "${ids}" =~ ^[0-9]+$ ]]; then
    FOUND_ID="${ids}"
    FIND_DETAIL="title search: one exact match, TVmaze show ${FOUND_ID}"
  elif [[ ${count} -eq 0 ]]; then
    FIND_DETAIL="title search: no TVmaze show named exactly '${title}'"
  else
    FIND_DETAIL="title search: ${count} TVmaze shows named '${title}' (ids ${ids}); not guessing"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Sync one episode
# ---------------------------------------------------------------------------

# sync_episode EPISODE_KEY SHOW SHOW_KEY SEASON EPISODE VIEWED_AT

# Returns 0 if synced. On failure: logs, emails once (key into FAILED_FILE).
sync_episode() {
  local ep_key="$1" show="$2" show_key="$3" season="$4" episode="$5" viewed_at="$6"
  local label attempts="" matched="" outcome="" detail=""
  label=$(printf '%s S%02dE%02d' "${show}" "$((10#${season}))" "$((10#${episode}))")

  local body
  body=$(jq -nc --argjson s "$((10#${season}))" --argjson e "$((10#${episode}))" \
    --argjson t "$((10#${viewed_at}))" '[{season: $s, episode: $e, type: 0, marked_at: $t}]')

  SHOW_TVDB="" SHOW_IMDB="" PLEX_DETAIL=""
  if [[ -n "${show_key}" ]] && plex_show_ids "${show_key}"; then
    :
  fi
  attempts="${PLEX_DETAIL:-Plex show lookup skipped: no show key}"

  # Each candidate is "param value". Empty ids are skipped.
  local -a candidates=()
  [[ -n "${SHOW_TVDB}" ]] && candidates+=("thetvdb_id ${SHOW_TVDB}")
  [[ -n "${SHOW_IMDB}" ]] && candidates+=("imdb_id ${SHOW_IMDB}")

  local c param value
  for c in ${candidates[@]+"${candidates[@]}"}; do
    param="${c%% *}"
    value="${c#* }"
    tvmaze_scrobble "${param}=${value}" "${body}"
    attempts="${attempts}
${param}=${value}: ${SCROBBLE_RESULT}: ${SCROBBLE_DETAIL}"
    case "${SCROBBLE_RESULT}" in
      ok)
        matched="${param}=${value}"
        outcome=ok
        break
        ;;
      nomatch) ;;
      *)
        outcome="${SCROBBLE_RESULT}"
        detail="${SCROBBLE_DETAIL}"
        break
        ;;
    esac
  done

  if [[ -z "${outcome}" ]]; then
    if tvmaze_find_show "${show}"; then
      attempts="${attempts}
${FIND_DETAIL}"
      if [[ -n "${FOUND_ID}" ]]; then
        tvmaze_scrobble "tvmaze_id=${FOUND_ID}" "${body}"
        attempts="${attempts}
tvmaze_id=${FOUND_ID}: ${SCROBBLE_RESULT}: ${SCROBBLE_DETAIL}"
        if [[ "${SCROBBLE_RESULT}" == "ok" ]]; then
          matched="tvmaze_id=${FOUND_ID} (title)"
          outcome=ok
        else
          outcome="${SCROBBLE_RESULT}"
          detail="${SCROBBLE_DETAIL}"
        fi
      else
        outcome=nomatch
        detail="${FIND_DETAIL}"
      fi
    else
      attempts="${attempts}
${FIND_DETAIL}"
      outcome=error
      detail="${FIND_DETAIL}"
    fi
  fi

  if [[ "${outcome}" == "ok" ]]; then
    log "SYNCED: ${label} via ${matched}, TVmaze episode ${EPISODE_ID:-unknown} (Plex key ${ep_key})"
    state_add "${SYNCED_FILE}" "${ep_key}"
    return 0
  fi

  log "FAILED: ${label} (Plex key ${ep_key}): ${detail}"
  if state_has "${FAILED_FILE}" "${ep_key}"; then
    log "  already emailed for Plex key ${ep_key}; not emailing again"
    return 1
  fi
  local hint=""
  if [[ "${outcome}" == "auth" ]]; then
    hint="
TVmaze rejected the credentials. Rotate the key: see
docs/apps/tvmaze-scrobble-README.md in mac-server-setup."
  fi
  if alert_send "TVmaze sync failed: ${label}" "[${HOSTNAME_LABEL}] Could not mark this episode watched on TVmaze:

  ${label}  (Plex key ${ep_key})

Attempts:
${attempts}
${hint}
Mark it by hand on tvmaze.com. The hourly reconcile run retries it for
${RECONCILE_LOOKBACK_DAYS} days but will not email about it again.
Log: ${LOG_FILE}"; then
    state_add "${FAILED_FILE}" "${ep_key}"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

run_webhook() {
  local payload
  payload=$(cat)
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${payload}"; then
    log "ERROR: payload on stdin is not a JSON object; ignored"
    return 1
  fi

  local fields
  fields=$(jq -r '[
      (.Account.title // ""), (.Account.id // "" | tostring),
      (.Metadata.type // ""), (.Metadata.ratingKey // "" | tostring),
      (.Metadata.grandparentRatingKey // "" | tostring),
      (.Metadata.parentIndex // "" | tostring), (.Metadata.index // "" | tostring),
      (.Metadata.lastViewedAt // "" | tostring)
    ] | join("\u001f")' <<<"${payload}")
  local title acct_id mtype ep_key show_key season episode viewed_at
  IFS=$'\037' read -r title acct_id mtype ep_key show_key season episode viewed_at <<<"${fields}"
  local show
  show=$(jq -r '.Metadata.grandparentTitle // ""' <<<"${payload}")

  if [[ "${title}" != "${PLEX_ACCOUNT_TITLE}" ]] || [[ "${mtype}" != "episode" ]]; then
    return 0
  fi
  log "webhook: ${show} S${season}E${episode} from account '${title}' (plex.tv id ${acct_id})"

  [[ "${viewed_at}" =~ ^[0-9]+$ ]] || viewed_at=$(date +%s)
  if [[ ! "${ep_key}" =~ ^[0-9]+$ ]] || [[ ! "${season}" =~ ^[0-9]+$ ]] \
    || [[ ! "${episode}" =~ ^[0-9]+$ ]] || [[ -z "${show}" ]]; then
    log "FAILED: payload lacks the show, season, episode or ratingKey (show='${show}' season='${season}' episode='${episode}' key='${ep_key}')"
    alert_send "TVmaze sync failed: ${show:-unknown show} S${season:-?}E${episode:-?}" \
      "[${HOSTNAME_LABEL}] A Plex play could not be synced: the webhook payload lacks the show, season, episode or ratingKey.
Log: ${LOG_FILE}" || true
    return 1
  fi
  [[ "${show_key}" =~ ^[0-9]+$ ]] || show_key=""

  if ! load_tvmaze_credentials; then
    config_problem config:credentials "TVmaze credentials missing or malformed at ${CREDENTIALS_FILE}; ${show} S${season}E${episode} was not synced"
    return 1
  fi
  config_ok config:credentials
  # Without the token the title search still works.
  load_plex_token || PLEX_CURL_CONFIG=""
  [[ -n "${PLEX_CURL_CONFIG}" ]] || show_key=""
  sync_episode "${ep_key}" "${show}" "${show_key}" "${season}" "${episode}" "${viewed_at}"
}

run_reconcile() {
  if ! load_plex_token; then
    config_problem config:plex-token "Plex token not readable at ${PLEX_TOKEN_FILE}; the hourly reconcile cannot read Plex history"
    return 1
  fi
  config_ok config:plex-token
  local now cutoff
  now=$(date +%s)
  cutoff=$((now - RECONCILE_LOOKBACK_DAYS * 86400))

  # viewedAt>= trims the response; the jq filter below is what is relied on.
  http_request "${PLEX_CURL_CONFIG}" GET \
    "${PLEX_URL}/status/sessions/history/all?sort=viewedAt:desc&accountID=${PLEX_ACCOUNT_ID}&viewedAt%3E=${cutoff}"
  if [[ ${CURL_RC} -ne 0 ]] || [[ "${HTTP_CODE}" != "200" ]]; then
    log "ERROR: reconcile: Plex history request failed (HTTP ${HTTP_CODE}, curl exit ${CURL_RC}); will retry next run"
    return 1
  fi

  # One row per episode: key, show key, season, episode, viewedAt, title.

  # Joined by \037, not tabs: read collapses adjacent tabs, shifting fields.
  local rows
  if ! rows=$(jq -r --argjson cutoff "${cutoff}" --arg acct "${PLEX_ACCOUNT_ID}" '
      [.MediaContainer.Metadata[]?
        | select(.type == "episode"
            and ((.accountID // "") | tostring) == $acct
            and ((.viewedAt // 0) | tonumber) >= $cutoff
            and (.ratingKey != null))]
      | sort_by(.viewedAt) | reverse | unique_by(.ratingKey | tostring)
      | sort_by(.viewedAt)
      | .[]
      | [(.ratingKey | tostring),
         ((.grandparentKey // "") | tostring | sub("^/library/metadata/"; "")),
         ((.parentIndex // "") | tostring), ((.index // "") | tostring),
         (.viewedAt | tostring),
         ((.grandparentTitle // "") | gsub("[\u001f\n]"; " "))]
      | join("\u001f")' <<<"${HTTP_BODY}"); then
    log "ERROR: reconcile: Plex history is not the expected JSON"
    return 1
  fi

  mkdir -p "${STATE_DIR}"

  if [[ ! -e "${SEEDED_FILE}" ]]; then
    local tmp="${SYNCED_FILE}.tmp.$$" n=0 key
    [[ -f "${SYNCED_FILE}" ]] && cat "${SYNCED_FILE}" >"${tmp}"
    while IFS=$'\037' read -r key _; do
      [[ -n "${key}" ]] || continue
      # Already failed (webhook before this run): leave it for the retries.
      state_has "${FAILED_FILE}" "${key}" && continue
      printf '%s\n' "${key}" >>"${tmp}"
      n=$((n + 1))
    done <<<"${rows}"
    touch "${tmp}"
    sort -u "${tmp}" -o "${tmp}"
    "${MV_BIN}" "${tmp}" "${SYNCED_FILE}"
    touch "${SEEDED_FILE}"
    log "reconcile: first run, seeded ${n} episodes from the last ${RECONCILE_LOOKBACK_DAYS} days as already synced; scrobbled nothing"
    return 0
  fi

  local key show_key season episode viewed_at show
  local checked=0 synced=0 failed=0 first=true
  while IFS=$'\037' read -r key show_key season episode viewed_at show; do
    [[ -n "${key}" ]] || continue
    checked=$((checked + 1))
    state_has "${SYNCED_FILE}" "${key}" && continue
    if [[ ! "${season}" =~ ^[0-9]+$ ]] || [[ ! "${episode}" =~ ^[0-9]+$ ]] || [[ -z "${show}" ]]; then
      log "reconcile: skipped Plex key ${key}: history row lacks show, season or episode"
      continue
    fi
    [[ "${show_key}" =~ ^[0-9]+$ ]] || show_key=""
    if [[ "${first}" == "true" ]]; then
      if ! load_tvmaze_credentials; then
        config_problem config:credentials "TVmaze credentials missing or malformed at ${CREDENTIALS_FILE}; the reconcile run synced nothing"
        return 1
      fi
      config_ok config:credentials
      first=false
    else
      "${SLEEP_BIN}" "${RECONCILE_PAUSE}"
    fi
    log "reconcile: missed play: ${show} S${season}E${episode} (Plex key ${key})"
    if sync_episode "${key}" "${show}" "${show_key}" "${season}" "${episode}" "${viewed_at}"; then
      synced=$((synced + 1))
    else
      failed=$((failed + 1))
    fi
  done <<<"${rows}"

  if [[ $((synced + failed)) -gt 0 ]]; then
    log "reconcile: ${checked} episodes in window, ${synced} synced, ${failed} failed"
  fi
  [[ ${failed} -eq 0 ]]
}

run_check() {
  local ok=true
  if load_tvmaze_credentials; then
    http_request "${TVMAZE_CURL_CONFIG}" GET "${TVMAZE_API}/v1/auth/validate"
    if [[ "${HTTP_CODE}" == "200" ]]; then
      echo "OK: TVmaze accepted the credentials"
    else
      echo "FAIL: TVmaze /v1/auth/validate returned HTTP ${HTTP_CODE} (curl exit ${CURL_RC})"
      ok=false
    fi
  else
    echo "FAIL: credentials file ${CREDENTIALS_FILE} missing or malformed"
    ok=false
  fi
  if load_plex_token; then
    echo "OK: Plex token file present"
  else
    echo "FAIL: Plex token not readable at ${PLEX_TOKEN_FILE}"
    ok=false
  fi
  [[ "${ok}" == "true" ]]
}

main() {
  mkdir -p "$(dirname "${LOG_FILE}")" "${STATE_DIR}"

  if [[ ! -r "${ALERT_LIB}" ]]; then
    log "ERROR: alert library not found at ${ALERT_LIB}. Re-run tvmaze-scrobble-setup.sh"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${ALERT_LIB}"

  if [[ ! -x "${JQ_BIN}" ]]; then
    log "ERROR: jq not found at ${JQ_BIN}; nothing can be synced"
    exit 1
  fi

  case "${1:-}" in
    "") run_webhook ;;
    --reconcile) run_reconcile ;;
    --check) run_check ;;
    *)
      echo "Usage: $0 [--reconcile | --check] (webhook payload on stdin)" >&2
      exit 64
      ;;
  esac
}

# Entry point — skipped when sourced for tests (TEST_RUNNER=true)
if [[ "${TEST_RUNNER:-false}" != "true" ]]; then
  main "$@"
fi
