#!/usr/bin/env bash
#
# access-policy-watchdog: emails when Access or tunnel config for
# __EXTERNAL_HOSTNAME__ changes. See docs/components/cloudflare-tunnel.md.

# Usage: access-policy-watchdog [--check]
# --check prints the result only. Exit 0 match, 1 drift or missing, 2 API
# unreadable.

# Placeholders are filled in by access-policy-watchdog-setup.sh.
# The LaunchAgent runs /bin/bash 3.2: no bash 4 features.

# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-10-22

set -euo pipefail

# launchd's PATH has no Homebrew. See docs/components/monitoring.md.
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
TUNNEL_ID="__CLOUDFLARE_TUNNEL_ID__"
TEAM_NAME="__CLOUDFLARE_ACCESS_TEAM_NAME__"
AUD_TAG="__CLOUDFLARE_ACCESS_AUD_TAG__"
# Caddy's tunnel-only site (http://:8080 in the Caddyfile); a test keeps the two equal.
TUNNEL_ORIGIN_SERVICE="http://127.0.0.1:8080"

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
    local hint=""
    if [[ "${name}" == "tunnel" ]] && [[ "${code}" == "401" || "${code}" == "403" ]]; then
      hint=". The read-only token also needs Cloudflare Tunnel: Read"
    fi
    printf 'error:%s request returned HTTP %s%s%s' "${name}" "${code}" "${msg:+ (${msg})}" "${hint}"
  elif ! jq -e '.success == true and (.result | type == "object")' "${body_file}" >/dev/null 2>&1; then
    printf 'error:%s response is not a successful Cloudflare result' "${name}"
  else
    printf 'ok'
  fi
}

# ---------------------------------------------------------------------------
# The comparison. Prints one line per difference; prints nothing when the
# application, the policy and the tunnel ingress match exactly.
# ---------------------------------------------------------------------------

evaluate_rule() {
  local app_file="$1" policy_file="$2" tunnel_file="$3"
  jq -n -r \
    --slurpfile a "${app_file}" \
    --slurpfile p "${policy_file}" \
    --slurpfile t "${tunnel_file}" \
    --arg domain "${APP_DOMAIN}" \
    --arg idp "${IDP_ID}" \
    --arg policy "${POLICY_ID}" \
    --arg email "${ALLOWED_EMAIL}" \
    --arg origin "${TUNNEL_ORIGIN_SERVICE}" \
    --arg team "${TEAM_NAME}" \
    --arg aud "${AUD_TAG}" \
    '
    def lc: ascii_downcase;
    # An email rule with the address in lower case; any other rule unchanged.
    def norm_rule:
      if type == "object" and keys == ["email"]
        and (.email | type) == "object" and (.email | keys) == ["email"]
        and (.email.email | type) == "string"
      then {email: {email: (.email.email | lc)}}
      else . end;

    # A rule with its hostname in lower case; anything else unchanged.
    def norm_ingress:
      if type == "object" and (.hostname | type) == "string"
      then .hostname |= lc else . end;

    ($a[0].result // {}) as $app
    | ($p[0].result // {}) as $pol
    | ($t[0].result.config // {}) as $cfg
    # Exact shape, not a list of bad rules: a second hostname, a path rule,
    # access.required off, or a catch-all that serves anything all differ.
    | [ {hostname: ($domain | lc), service: $origin,
         originRequest: {access: {required: true, teamName: $team, audTag: [$aud]}}},
        {service: "http_status:404"} ] as $want_ingress
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
         | if $x != [] then "Policy exclude is \($x | tojson), expected none." else empty end),

        (($cfg.ingress // []) as $ing
         | if ($ing | map(norm_ingress)) != $want_ingress
           then "Tunnel ingress is \($ing | tojson), expected \($want_ingress | tojson)."
           else empty end),

        # WARP routing would route private networks (the LAN) through the
        # tunnel, past Access and Caddy.
        (if ($cfg["warp-routing"].enabled // false) != false
         then "Tunnel warp-routing is \($cfg["warp-routing"] | tojson), expected disabled. It would route private networks through the tunnel."
         else empty end),

        (($cfg | keys - ["ingress", "warp-routing"]) as $extra
         | if $extra != []
           then "Tunnel config has unexpected settings \($extra | tojson): \($cfg | with_entries(select(.key | IN($extra[]))) | tojson)."
           else empty end)
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
    log "OK: ${APP_DOMAIN} Access application, policy and tunnel ingress match the expected rule"
    state_set last_ok_log "${now}"
  fi
}

# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------

dashboard_hint() {
  printf '%s' "Zero Trust dashboard: Access > Applications > ${APP_DOMAIN},
Access > Policies, and Networks > Tunnels (published application routes).
To cut off current sessions, revoke them in Zero Trust (Users / Access
sessions). To cut off the origin, stop the tunnel daemon on the server.
See https://smartwatermelon.github.io/mac-server-setup/components/cloudflare-tunnel/"
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
    "The watchdog that checks the Cloudflare Access rule and tunnel ingress for
${APP_DOMAIN} has failed to read them on ${failures} checks in a row (checked
every 15 minutes). Until it can read them again, a widened policy or a new
unprotected tunnel route would go unnoticed.

Last error: ${api_error}

Common causes: the read-only API token was revoked or expired, or lacks a
permission (HTTP 401 or 403; it needs Access: Apps and Policies Read and
Cloudflare Tunnel: Read), or the Cloudflare API is down.
Token file: ${TOKEN_FILE}
Log:        ${LOG_FILE}" \
    "RESOLVED: [${HOSTNAME_LABEL}] Access policy watchdog reads Cloudflare again" \
    "The watchdog can read the Access rule for ${APP_DOMAIN} again. No action required." || true
}

handle_missing() {
  local is_bad="$1" what="$2"
  alert_transition "access_missing" "${is_bad}" \
    "[${HOSTNAME_LABEL}] Cloudflare Access or tunnel object for ${APP_DOMAIN} is missing" \
    "The Cloudflare API returned 404 (not found) for: ${what}

If the Access application is gone, ${APP_DOMAIN} is either unreachable
(cloudflared rejects requests with no valid token for the old application)
or, if a new application or tunnel route was set up without it, unprotected.
If the tunnel is gone, the tunnel daemon cannot connect and ${APP_DOMAIN}
shows a Cloudflare error page. Check now.

$(dashboard_hint)
Log: ${LOG_FILE}" \
    "RESOLVED: [${HOSTNAME_LABEL}] Cloudflare Access and tunnel objects for ${APP_DOMAIN} are back" \
    "The Access application, policy and tunnel for ${APP_DOMAIN} can be read again." || true
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
  body="The Cloudflare Access rule or tunnel ingress for ${APP_DOMAIN} differs
from the expected rule:

${listed}
Expected: allow only ${ALLOWED_EMAIL}, through the Google identity provider
only, with this one policy attached. The tunnel routes only ${APP_DOMAIN}, to
${TUNNEL_ORIGIN_SERVICE} with access.required on, then a 404 catch-all, and
private-network (WARP) routing is off.

Through the tunnel there is no other login in front of Transmission. If you
did not make this change, put the policy back and revoke active sessions.

$(dashboard_hint)
Log: ${LOG_FILE}"

  if [[ "${is_bad}" == "true" ]]; then
    log "DRIFT: ${diffs//$'\n'/ | }"
  fi

  alert_transition "policy_drift" "${is_bad}" \
    "[${HOSTNAME_LABEL}] Cloudflare Access or tunnel config for ${APP_DOMAIN} changed" \
    "${body}" \
    "RESOLVED: [${HOSTNAME_LABEL}] Cloudflare Access or tunnel config for ${APP_DOMAIN} matches again" \
    "The Access application, policy and tunnel ingress for ${APP_DOMAIN} match the expected rule again.
No action required." || true

  if [[ "${is_bad}" != "true" ]]; then
    state_del drift_fingerprint
    return 0
  fi

  if [[ "${was_alerted}" == "true" ]] && [[ -n "${old_fp}" ]] && [[ "${old_fp}" != "${new_fp}" ]]; then
    if alert_send "[${HOSTNAME_LABEL}] Cloudflare Access or tunnel config for ${APP_DOMAIN} changed again" "${body}"; then
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
  TUNNEL_FILE=$(mktemp "${CONFIG_DIR}/tunnel.XXXXXX")
  trap 'rm -f "${APP_FILE:-}" "${POLICY_FILE:-}" "${TUNNEL_FILE:-}"' EXIT
  local app_file="${APP_FILE}" policy_file="${POLICY_FILE}" tunnel_file="${TUNNEL_FILE}"

  local app_code app_rc=0 policy_code policy_rc=0 tunnel_code tunnel_rc=0
  app_code=$(api_get "/accounts/${ACCOUNT_ID}/access/apps/${APP_ID}" "${app_file}" "${token}") || app_rc=$?
  policy_code=$(api_get "/accounts/${ACCOUNT_ID}/access/policies/${POLICY_ID}" "${policy_file}" "${token}") || policy_rc=$?
  tunnel_code=$(api_get "/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "${tunnel_file}" "${token}") || tunnel_rc=$?
  unset token

  local app_status policy_status tunnel_status
  app_status=$(classify_response "application" "${app_rc}" "${app_code}" "${app_file}")
  policy_status=$(classify_response "policy" "${policy_rc}" "${policy_code}" "${policy_file}")
  tunnel_status=$(classify_response "tunnel" "${tunnel_rc}" "${tunnel_code}" "${tunnel_file}")

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
  case "${tunnel_status}" in
    error:*) api_error="${api_error:+${api_error}; }${tunnel_status#error:}" ;;
    missing) missing="${missing:+${missing}, and }the tunnel ${TUNNEL_ID}" ;;
    *) ;;
  esac

  local diffs=""
  # A malformed response makes jq fail. Under set -e that ended the run
  # with no log and no alert, so count it as an API failure.
  if [[ -z "${api_error}" ]] && [[ -z "${missing}" ]]; then
    diffs=$(evaluate_rule "${app_file}" "${policy_file}" "${tunnel_file}") \
      || api_error="the application, policy or tunnel response has an unexpected shape"
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
    echo "OK: ${APP_DOMAIN} Access application, policy and tunnel ingress match the expected rule"
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
