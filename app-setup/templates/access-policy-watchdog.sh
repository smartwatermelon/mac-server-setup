#!/usr/bin/env bash
#
# access-policy-watchdog: email when the Cloudflare Access rule for
# __EXTERNAL_HOSTNAME__ changes. See docs/apps/cloudflare-tunnel-README.md.

# Usage: access-policy-watchdog [--check]
# --check prints the result only. Exit 0 match, 1 drift or missing, 2 API
# unreadable.

# Placeholders are filled in by access-policy-watchdog-setup.sh.
# The LaunchAgent runs /bin/bash 3.2: no bash 4 features.

# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-10-22

set -euo pipefail

# launchd's PATH has no Homebrew. See docs/apps/monitoring-README.md.
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
export MONITORING_EMAIL="__MONITORING_EMAIL__" # read by alert-lib.sh
APP_DOMAIN="__EXTERNAL_HOSTNAME__"
ACCOUNT_ID="__CLOUDFLARE_ACCOUNT_ID__"
APP_ID="__CLOUDFLARE_ACCESS_APP_ID__"
POLICY_ID="__CLOUDFLARE_ACCESS_POLICY_ID__"
IDP_ID="__CLOUDFLARE_ACCESS_IDP_ID__"
ALLOWED_EMAIL="__ACCESS_ALLOWED_EMAIL__"

CF_API="https://api.cloudflare.com/client/v4"

CONFIG_DIR="${HOME}/.config/access-policy-watchdog"
# Read-only API token, copied from the System keychain by the setup script
# (mode 600). An operator agent cannot read the System keychain.
TOKEN_FILE="${CONFIG_DIR}/token"
export STATE_FILE="${CONFIG_DIR}/state.json" # read by alert-lib.sh
LOG_FILE="${HOME}/.local/state/access-policy-watchdog.log"
ALERT_LIB="${ALERT_LIB:-${HOME}/.local/lib/alert-lib.sh}"

# 3 failed polls (45 min): rides out an API blip, but a broken check cannot
# pass for a healthy rule for long.
API_FAILURE_THRESHOLD=3
HEARTBEAT_INTERVAL_SECONDS=3600
# alert_transition resends an open alert every 12 hours.
export ALERT_REMINDER_SECONDS=43200

CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=30

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] [access-policy-watchdog] %s\n' "${timestamp}" "$1" >>"${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Shared alert library: alert_send, alert_transition and the alert_state_*
# helpers on STATE_FILE. Deployed by access-policy-watchdog-setup.sh.
# ---------------------------------------------------------------------------

if [[ ! -r "${ALERT_LIB}" ]]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  log "ERROR: alert library not found at ${ALERT_LIB} — cannot send alerts. Re-run access-policy-watchdog-setup.sh"
  exit 1
fi
# shellcheck source=/dev/null
source "${ALERT_LIB}"

# ---------------------------------------------------------------------------
# Cloudflare API
# ---------------------------------------------------------------------------

read_token() {
  [[ -r "${TOKEN_FILE}" ]] || return 1
  local token
  token=$(tr -d '[:space:]' <"${TOKEN_FILE}")
  [[ -n "${token}" ]] || return 1
  printf '%s' "${token}"
}

# api_get PATH BODY_FILE TOKEN: body to BODY_FILE, prints the HTTP code,
# returns curl's exit code.
api_get() {
  # The token reaches curl on stdin (-K -), never in an argument list that
  # ps would show. printf is a builtin.
  local path="$1" body_file="$2" token="$3"
  local code="" rc=0
  code=$(printf 'header = "Authorization: Bearer %s"\n' "${token}" \
    | curl -sS -K - \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      -o "${body_file}" \
      -w '%{http_code}' \
      "${CF_API}${path}" 2>/dev/null) || rc=$?
  printf '%s' "${code:-000}"
  return "${rc}"
}

# classify_response NAME RC CODE BODY_FILE. Prints "ok" (200, success),
# "missing" (404: confirmed bad), or "error:<why>" (state unknown).
classify_response() {
  local name="$1" rc="$2" code="$3" body_file="$4"
  if [[ "${rc}" -ne 0 ]]; then
    printf 'error:%s request failed (curl exit %s)' "${name}" "${rc}"
  elif [[ "${code}" == "404" ]]; then
    printf 'missing'
  elif [[ "${code}" != "200" ]]; then
    local msg
    msg=$(jq -r '[.errors[]?.message] | join("; ")' "${body_file}" 2>/dev/null) || msg=""
    printf 'error:%s request returned HTTP %s%s' "${name}" "${code}" "${msg:+ (${msg})}"
  elif ! jq -e '.success == true and (.result | type == "object")' "${body_file}" >/dev/null 2>&1; then
    printf 'error:%s response is not a successful Cloudflare result' "${name}"
  else
    printf 'ok'
  fi
}

# ---------------------------------------------------------------------------
# The comparison. Prints one line per difference; prints nothing when the
# application and the policy match the expected rule exactly.
# ---------------------------------------------------------------------------

evaluate_rule() {
  local app_file="$1" policy_file="$2"
  jq -n -r \
    --slurpfile a "${app_file}" \
    --slurpfile p "${policy_file}" \
    --arg domain "${APP_DOMAIN}" \
    --arg idp "${IDP_ID}" \
    --arg policy "${POLICY_ID}" \
    --arg email "${ALLOWED_EMAIL}" \
    '
    def lc: ascii_downcase;
    # An email rule with the address in lower case; any other rule unchanged.
    def norm_rule:
      if type == "object" and keys == ["email"]
        and (.email | type) == "object" and (.email | keys) == ["email"]
        and (.email.email | type) == "string"
      then {email: {email: (.email.email | lc)}}
      else . end;

    ($a[0].result // {}) as $app
    | ($p[0].result // {}) as $pol
    | [
        (if (($app.domain // "") | tostring | lc) != ($domain | lc)
         then "Application domain is \($app.domain | tojson), expected \($domain | tojson)."
         else empty end),

        (($app.allowed_idps // []) as $i
         | if $i != [$idp]
           then "Application allowed_idps is \($i | tojson), expected [\($idp | tojson)]. An empty list allows every identity provider, including one-time PIN."
           else empty end),

        ((($app.policies // []) | map(.id? // .)) as $ids
         | if $ids != [$policy]
           then "Application policies are \($ids | tojson), expected only [\($policy | tojson)]."
           else empty end),

        (if ($pol.decision // null) != "allow"
         then "Policy decision is \($pol.decision | tojson), expected \"allow\"."
         else empty end),

        (($pol.include // []) as $inc
         | if ($inc | map(norm_rule)) != [{email: {email: ($email | lc)}}]
           then "Policy include is \($inc | tojson), expected [{\"email\":{\"email\":\($email | tojson)}}]."
           else empty end),

        (($pol.require // []) as $r
         | if $r != [] then "Policy require is \($r | tojson), expected none." else empty end),

        (($pol.exclude // []) as $x
         | if $x != [] then "Policy exclude is \($x | tojson), expected none." else empty end)
      ]
    | .[]
    '
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

# Set one top-level state key to a JSON value.
state_set() {
  local state
  state=$(alert_state_read)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"${state}" || state='{}'
  state=$(jq --arg k "$1" --argjson v "$2" '.[$k] = $v' <<<"${state}")
  alert_state_write "${state}"
}

state_del() {
  local state
  state=$(alert_state_read)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"${state}" || state='{}'
  state=$(jq --arg k "$1" 'del(.[$k])' <<<"${state}")
  alert_state_write "${state}"
}

maybe_heartbeat() {
  local now last
  now=$(date +%s)
  last=$(alert_state_get last_ok_log 0)
  [[ "${last}" =~ ^[0-9]+$ ]] || last=0
  if [[ $((now - last)) -ge ${HEARTBEAT_INTERVAL_SECONDS} ]]; then
    log "OK: ${APP_DOMAIN} Access application and policy match the expected rule"
    state_set last_ok_log "${now}"
  fi
}

# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------

dashboard_hint() {
  printf '%s' "Zero Trust dashboard: Access > Applications > ${APP_DOMAIN}, and
Access > Policies. To cut off current sessions, revoke them in Zero Trust
(Users / Access sessions).
See docs/apps/cloudflare-tunnel-README.md in mac-server-setup."
}

handle_api_result() {
  local api_error="$1"
  local failures
  failures=$(alert_state_get api_failures 0)
  [[ "${failures}" =~ ^[0-9]+$ ]] || failures=0
  if [[ -n "${api_error}" ]]; then
    failures=$((failures + 1))
    log "WARNING: Cloudflare API not readable (${failures}/${API_FAILURE_THRESHOLD}): ${api_error}"
  else
    failures=0
  fi
  state_set api_failures "${failures}"

  local is_bad=false
  [[ ${failures} -ge ${API_FAILURE_THRESHOLD} ]] && is_bad=true
  alert_transition "api_failing" "${is_bad}" \
    "[${HOSTNAME_LABEL}] Access policy watchdog cannot read Cloudflare" \
    "The watchdog that checks the Cloudflare Access rule for ${APP_DOMAIN} has
failed to read it on ${failures} checks in a row (checked every 15 minutes).
Until it can read the rule again, a widened policy would go unnoticed.

Last error: ${api_error}

Common causes: the read-only API token was revoked or expired (HTTP 401 or
403), or the Cloudflare API is down.
Token file: ${TOKEN_FILE}
Log:        ${LOG_FILE}" \
    "RESOLVED: [${HOSTNAME_LABEL}] Access policy watchdog reads Cloudflare again" \
    "The watchdog can read the Access rule for ${APP_DOMAIN} again. No action required." || true
}

handle_missing() {
  local is_bad="$1" what="$2"
  alert_transition "access_missing" "${is_bad}" \
    "[${HOSTNAME_LABEL}] Cloudflare Access object for ${APP_DOMAIN} is missing" \
    "The Cloudflare API returned 404 (not found) for: ${what}

If the Access application is gone, ${APP_DOMAIN} is either unreachable
(cloudflared rejects requests with no valid token for the old application)
or, if a new application or tunnel route was set up without it, unprotected.
Check now.

$(dashboard_hint)
Log: ${LOG_FILE}" \
    "RESOLVED: [${HOSTNAME_LABEL}] Cloudflare Access objects for ${APP_DOMAIN} are back" \
    "The Access application and policy for ${APP_DOMAIN} can be read again." || true
}

handle_drift() {
  local diffs="$1"
  local is_bad=false
  [[ -n "${diffs}" ]] && is_bad=true

  # alert_transition stays quiet while alerted, so a further change (say, a
  # wider policy) gets its own email.
  local was_alerted old_fp new_fp=""
  was_alerted=$(alert_state_get 'transitions.policy_drift.alerted' false)
  old_fp=$(alert_state_get drift_fingerprint "")
  if [[ "${is_bad}" == "true" ]]; then
    new_fp=$(printf '%s' "${diffs}" | shasum -a 256 | cut -d' ' -f1)
  fi

  local listed="" line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && listed="${listed}  - ${line}
"
  done <<<"${diffs}"

  local body
  body="The Cloudflare Access rule for ${APP_DOMAIN} differs from the expected rule:

${listed}
Expected: allow only ${ALLOWED_EMAIL}, through the Google identity provider
only, with this one policy attached.

Through the tunnel there is no other login in front of Transmission. If you
did not make this change, put the policy back and revoke active sessions.

$(dashboard_hint)
Log: ${LOG_FILE}"

  if [[ "${is_bad}" == "true" ]]; then
    log "DRIFT: ${diffs//$'\n'/ | }"
  fi

  alert_transition "policy_drift" "${is_bad}" \
    "[${HOSTNAME_LABEL}] Cloudflare Access policy for ${APP_DOMAIN} changed" \
    "${body}" \
    "RESOLVED: [${HOSTNAME_LABEL}] Cloudflare Access policy for ${APP_DOMAIN} matches again" \
    "The Access application and policy for ${APP_DOMAIN} match the expected rule again.
No action required." || true

  if [[ "${is_bad}" != "true" ]]; then
    state_del drift_fingerprint
    return 0
  fi

  if [[ "${was_alerted}" == "true" ]] && [[ -n "${old_fp}" ]] && [[ "${old_fp}" != "${new_fp}" ]]; then
    if alert_send "[${HOSTNAME_LABEL}] Cloudflare Access policy for ${APP_DOMAIN} changed again" "${body}"; then
      log "ALERT sent: policy_drift changed"
    else
      # Keep the old fingerprint so the next run tries again.
      return 0
    fi
  fi

  # Record what was reported, once the alert for it has gone out.
  local now_alerted
  now_alerted=$(alert_state_get 'transitions.policy_drift.alerted' false)
  if [[ "${now_alerted}" == "true" ]]; then
    # new_fp is a hex digest, so quoting it makes valid JSON.
    state_set drift_fingerprint "\"${new_fp}\""
  fi
}

# ---------------------------------------------------------------------------
# Main poll cycle
# ---------------------------------------------------------------------------

main() {
  local check_only=false
  if [[ "${1:-}" == "--check" ]]; then
    check_only=true
  elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--check]" >&2
    exit 64
  fi

  mkdir -p "${CONFIG_DIR}"
  mkdir -p "$(dirname "${LOG_FILE}")"

  local token
  if ! token=$(read_token); then
    log "ERROR: API token not found or empty at ${TOKEN_FILE} — re-run access-policy-watchdog-setup.sh"
    [[ "${check_only}" == "true" ]] && echo "ERROR: API token not found or empty at ${TOKEN_FILE}" >&2
    # Count it as an API failure, so a lost token still alerts.
    if [[ "${check_only}" != "true" ]]; then
      handle_api_result "API token file ${TOKEN_FILE} is missing or empty"
    fi
    exit 2
  fi

  # Globals, not locals: the EXIT trap runs after main has returned.
  APP_FILE=$(mktemp "${CONFIG_DIR}/app.XXXXXX")
  POLICY_FILE=$(mktemp "${CONFIG_DIR}/policy.XXXXXX")
  trap 'rm -f "${APP_FILE:-}" "${POLICY_FILE:-}"' EXIT
  local app_file="${APP_FILE}" policy_file="${POLICY_FILE}"

  local app_code app_rc=0 policy_code policy_rc=0
  app_code=$(api_get "/accounts/${ACCOUNT_ID}/access/apps/${APP_ID}" "${app_file}" "${token}") || app_rc=$?
  policy_code=$(api_get "/accounts/${ACCOUNT_ID}/access/policies/${POLICY_ID}" "${policy_file}" "${token}") || policy_rc=$?
  unset token

  local app_status policy_status
  app_status=$(classify_response "application" "${app_rc}" "${app_code}" "${app_file}")
  policy_status=$(classify_response "policy" "${policy_rc}" "${policy_code}" "${policy_file}")

  local api_error="" missing=""
  case "${app_status}" in
    error:*) api_error="${app_status#error:}" ;;
    missing) missing="the Access application ${APP_ID}" ;;
    *) ;;
  esac
  case "${policy_status}" in
    error:*) api_error="${api_error:+${api_error}; }${policy_status#error:}" ;;
    missing) missing="${missing:+${missing}, and }the Access policy ${POLICY_ID}" ;;
    *) ;;
  esac

  local diffs=""
  if [[ -z "${api_error}" ]] && [[ -z "${missing}" ]]; then
    diffs=$(evaluate_rule "${app_file}" "${policy_file}")
  fi

  if [[ "${check_only}" == "true" ]]; then
    if [[ -n "${missing}" ]]; then
      echo "MISSING: ${missing}"
      exit 1
    elif [[ -n "${api_error}" ]]; then
      echo "API ERROR: ${api_error}"
      exit 2
    elif [[ -n "${diffs}" ]]; then
      echo "DRIFT:"
      printf '%s\n' "${diffs}" | sed 's/^/  - /'
      exit 1
    fi
    echo "OK: ${APP_DOMAIN} Access application and policy match the expected rule"
    exit 0
  fi

  handle_api_result "${api_error}"

  if [[ -n "${missing}" ]]; then
    log "MISSING: ${missing} (HTTP 404)"
    handle_missing true "${missing}"
    return 0
  fi

  if [[ -n "${api_error}" ]]; then
    # Unknown state: leave drift and missing alerts open. A RESOLVED now
    # could be a false all-clear.
    return 0
  fi

  handle_missing false ""
  handle_drift "${diffs}"
  if [[ -z "${diffs}" ]]; then
    maybe_heartbeat
  fi
}

# Entry point — skipped when sourced for tests (TEST_RUNNER=true)
if [[ "${TEST_RUNNER:-false}" != "true" ]]; then
  main "$@"
fi
