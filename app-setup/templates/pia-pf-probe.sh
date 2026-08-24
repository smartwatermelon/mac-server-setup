#!/usr/bin/env bash
#
# pia-pf-probe.sh — probe PIA regions for working port forwarding
#
# PIA's server list advertises a per-region `port_forward` boolean, but that
# flag is not reliable: the Panama region advertises port_forward=true while
# serving nothing on the PF API port (verified 2026-08-23, issue #159). The
# only trustworthy signal is establishing a tunnel and asking the PF API for a
# real port.
#
# This script connects to each candidate region in turn using a throwaway
# OpenVPN process, calls PIA's next-generation getSignature endpoint, and
# records whether a usable port came back. Results are written as CSV so the
# region-selection work in issue #159 has real data to rank against.
#
# The probe runs in its own container and never touches the live
# transmission-vpn container, so downloads in progress are unaffected.
#
# Usage:
#   ./pia-pf-probe.sh                     # probe the default shortlist
#   ./pia-pf-probe.sh ca_toronto netherlands
#   ./pia-pf-probe.sh --all               # every region advertising PF
#
# Region arguments are the image's OpenVPN config names, not PIA's API region
# ids; the two do not always agree. --all enumerates API ids and will report
# tunnel_timeout for any region whose config name differs (issue #159).
#   ./pia-pf-probe.sh --out results.csv
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-08-23

set -euo pipefail

# PIA publishes the authoritative region list here. The `port_forward` field is
# used only to build the candidate shortlist for --all; it is never treated as
# proof that forwarding works.
PIA_SERVER_LIST="https://serverlist.piaservers.net/vpninfo/servers/v4"
PIA_TOKEN_URL="https://www.privateinternetaccess.com/gtoken/generateToken"

# PF API listens on the tunnel gateway once a tunnel is established.
PF_PORT=19999

# Image already present on the server; reused so the probe pulls nothing new.
PROBE_IMAGE="docker.io/haugene/transmission-openvpn:latest"
PROBE_CONTAINER="pia-pf-probe"

# Regions worth testing first, all verified working 2026-08-23.
#
# These are the IMAGE's OpenVPN config names, which are not always PIA's API
# region ids: the API calls them nl_amsterdam / ch_switzerland / sweden, while
# the image ships netherlands / switzerland / se_stockholm. An unknown name
# does not fail loudly — the container prints its config list and exits, which
# this script can only observe as a tunnel timeout. See issue #159.
#
# `podman run --rm <image> ls /etc/openvpn/pia/` lists the valid names.
DEFAULT_REGIONS=(
  ca_toronto
  ca_vancouver
  netherlands
  de_frankfurt
  switzerland
  se_stockholm
  romania
)

# How long to wait for the tunnel to come up before giving up on a region.
TUNNEL_TIMEOUT=90

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

log() { printf '%s\n' "$*"; }
log_ts() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s %s\n' "${now}" "$*"
}
warn() { printf '⚠️  %s\n' "$*" >&2; }
die() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require_deps() {
  local missing=()
  local dep
  for dep in podman jq curl; do
    command -v "${dep}" >/dev/null 2>&1 || missing+=("${dep}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}"
  fi
}

# The probe needs the same PIA credentials the live container uses. Read them
# from the operator's env file rather than taking them on the command line, so
# the password never lands in shell history or the process table.
load_credentials() {
  local env_file="${PIA_ENV_FILE:-${HOME}/containers/transmission/.env}"

  [[ -r "${env_file}" ]] || die "Cannot read PIA env file: ${env_file}
   Set PIA_ENV_FILE to override, or run as the operator account."

  PIA_USERNAME="$(grep -E '^PIA_USERNAME=' "${env_file}" | cut -d= -f2-)"
  PIA_PASSWORD="$(grep -E '^PIA_PASSWORD=' "${env_file}" | cut -d= -f2-)"

  [[ -n "${PIA_USERNAME}" ]] || die "PIA_USERNAME missing from ${env_file}"
  [[ -n "${PIA_PASSWORD}" ]] || die "PIA_PASSWORD missing from ${env_file}"
}

# ---------------------------------------------------------------------------
# Region discovery
# ---------------------------------------------------------------------------

# Emit every region id whose advertised port_forward flag is true. This is a
# candidate filter only — each one still has to prove itself via probe.
list_pf_regions() {
  curl --silent --show-error --max-time 30 "${PIA_SERVER_LIST}" \
    | head -1 \
    | jq -r '.regions[] | select(.port_forward == true) | .id' \
    | sort
}

# ---------------------------------------------------------------------------
# Probe a single region
# ---------------------------------------------------------------------------

cleanup_probe_container() {
  podman rm -f "${PROBE_CONTAINER}" >/dev/null 2>&1 || true
}

# Bring up a throwaway tunnel for one region and report what the PF API says.
#
# Echoes a single CSV row:
#   region,tunnel_up,pf_status,port,gateway,notes
probe_region() {
  local region="$1"
  local tunnel_up="no"
  local port=""
  local gateway=""

  cleanup_probe_container

  # Flags mirror the live transmission-vpn container, which is the known-working
  # configuration on this host.
  #
  # CREATE_TUN_DEVICE=false is load-bearing: Podman already supplies
  # /dev/net/tun via --device, and without this the image tries to create it
  # itself, fails with "cannot remove '/dev/net/tun': Device or resource busy",
  # and the container exits before a tunnel is ever attempted.
  #
  # No ports are published: the probe needs no inbound access, and publishing
  # 9091 would collide with the live container.
  #
  # No --rm: it races with the explicit cleanup below, and a SIGKILLed script
  # would leave the container behind either way. cleanup_probe_container plus
  # the EXIT trap is the single cleanup path.
  if ! podman run -d \
    --name "${PROBE_CONTAINER}" \
    --privileged \
    --device /dev/net/tun:/dev/net/tun \
    -e "OPENVPN_PROVIDER=PIA" \
    -e "OPENVPN_CONFIG=${region}" \
    -e "OPENVPN_USERNAME=${PIA_USERNAME}" \
    -e "OPENVPN_PASSWORD=${PIA_PASSWORD}" \
    -e "CREATE_TUN_DEVICE=false" \
    -e "LOG_TO_STDOUT=true" \
    -e "TRANSMISSION_DOWNLOAD_DIR=/tmp" \
    "${PROBE_IMAGE}" >/dev/null 2>&1; then
    printf '%s,no,container_failed,,,could not start probe container\n' "${region}"
    return 0
  fi

  # Wait for the tunnel. A region with no reachable server never gets here.
  local waited=0
  while [[ ${waited} -lt ${TUNNEL_TIMEOUT} ]]; do
    gateway="$(podman exec "${PROBE_CONTAINER}" sh -c \
      "ip route 2>/dev/null | grep tun | grep -v src | head -1 | awk '{print \$3}'" 2>/dev/null || true)"
    if [[ -n "${gateway}" ]]; then
      tunnel_up="yes"
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  if [[ "${tunnel_up}" != "yes" ]]; then
    cleanup_probe_container
    printf '%s,no,tunnel_timeout,,,no tunnel after %ss\n' "${region}" "${TUNNEL_TIMEOUT}"
    return 0
  fi

  # Next-generation PIA port forwarding is a two-step flow: obtain a bearer
  # token from the account API, then present it to the PF service running on
  # the tunnel gateway.
  # Credentials are handed to the exec as environment variables rather than
  # interpolated into the command string, so they never appear in the
  # container's process table. This mirrors the --env-file protection the live
  # container relies on.
  local token
  token="$(podman exec \
    -e "PIA_USERNAME=${PIA_USERNAME}" \
    -e "PIA_PASSWORD=${PIA_PASSWORD}" \
    -e "PIA_TOKEN_URL=${PIA_TOKEN_URL}" \
    "${PROBE_CONTAINER}" sh -c \
    'curl --silent --show-error --request POST --max-time 15 \
       --user "${PIA_USERNAME}:${PIA_PASSWORD}" "${PIA_TOKEN_URL}" | jq -r .token' 2>/dev/null || true)"

  if [[ -z "${token}" || "${token}" == "null" ]]; then
    cleanup_probe_container
    printf '%s,yes,token_failed,,%s,could not obtain auth token\n' "${region}" "${gateway}"
    return 0
  fi

  # The PF endpoint uses a certificate valid for a PIA hostname rather than the
  # gateway IP we reach it by, so --insecure is required here. The token in the
  # request is what actually authenticates this call.
  local sig_response
  sig_response="$(podman exec \
    -e "PF_TOKEN=${token}" \
    -e "PF_URL=https://${gateway}:${PF_PORT}/getSignature" \
    "${PROBE_CONTAINER}" sh -c \
    'curl --insecure --get --silent --show-error --max-time 15 \
       --data-urlencode "token=${PF_TOKEN}" "${PF_URL}"' 2>/dev/null || true)"

  if [[ -z "${sig_response}" ]]; then
    cleanup_probe_container
    printf '%s,yes,no_pf_service,,%s,nothing listening on %s\n' \
      "${region}" "${gateway}" "${PF_PORT}"
    return 0
  fi

  local status
  status="$(printf '%s' "${sig_response}" | jq -r '.status // "unparseable"' 2>/dev/null || echo unparseable)"

  if [[ "${status}" != "OK" ]]; then
    cleanup_probe_container
    printf '%s,yes,%s,,%s,getSignature did not return OK\n' "${region}" "${status}" "${gateway}"
    return 0
  fi

  # A successful signature carries a base64 payload holding the assigned port.
  # Decoded inside the container, which is Linux, so GNU `base64 -d` applies;
  # running this step on macOS would need -D instead.
  local payload
  payload="$(jq -r '.payload' <<<"${sig_response}" 2>/dev/null || true)"
  port="$(podman exec -e "PF_PAYLOAD=${payload}" "${PROBE_CONTAINER}" sh -c \
    'printf %s "${PF_PAYLOAD}" | base64 -d | jq -r .port' 2>/dev/null || true)"

  cleanup_probe_container

  if [[ -z "${port}" || "${port}" == "null" ]]; then
    printf '%s,yes,OK_no_port,,%s,signature OK but payload had no port\n' "${region}" "${gateway}"
    return 0
  fi

  printf '%s,yes,OK,%s,%s,port forwarding confirmed\n' "${region}" "${port}" "${gateway}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local out_file="pia-pf-probe-results.csv"
  local regions=()
  local use_all=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        use_all=true
        shift
        ;;
      --out)
        out_file="${2:?--out requires a path}"
        shift 2
        ;;
      -h | --help)
        sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        regions+=("$1")
        shift
        ;;
    esac
  done

  require_deps
  load_credentials

  if [[ "${use_all}" == "true" ]]; then
    log "Fetching regions advertising port_forward=true..."
    local region_list
    region_list="$(list_pf_regions)"
    mapfile -t regions <<<"${region_list}"
    log "${#regions[@]} candidate regions"
  elif [[ ${#regions[@]} -eq 0 ]]; then
    regions=("${DEFAULT_REGIONS[@]}")
  fi

  [[ ${#regions[@]} -gt 0 ]] || die "No regions to probe"

  trap cleanup_probe_container EXIT

  printf 'region,tunnel_up,pf_status,port,gateway,notes\n' >"${out_file}"

  log_ts "Probing ${#regions[@]} region(s) — roughly $((${#regions[@]} * 90 / 60)) minutes"
  log ""

  local region row confirmed=0
  for region in "${regions[@]}"; do
    printf '  %-24s ' "${region}"
    row="$(probe_region "${region}")"
    printf '%s\n' "${row}" >>"${out_file}"

    local reported_port reported_status
    case "${row}" in
      *,OK,*)
        reported_port="$(cut -d, -f4 <<<"${row}")"
        printf '✅ port %s\n' "${reported_port}"
        confirmed=$((confirmed + 1))
        ;;
      *)
        reported_status="$(cut -d, -f3 <<<"${row}")"
        printf '❌ %s\n' "${reported_status}"
        ;;
    esac
  done

  log ""
  log_ts "Done — ${confirmed}/${#regions[@]} region(s) with working port forwarding"
  log "Results: ${out_file}"

  if [[ ${confirmed} -eq 0 ]]; then
    warn "No region returned a usable forwarded port."
    warn "If a broad sweep (--all) also comes back empty, PIA may have curtailed"
    warn "port forwarding for this account; running unforwarded is the fallback."
    return 1
  fi
}

# Entry point — skipped when sourced for tests (TEST_RUNNER=true)
if [[ "${TEST_RUNNER:-false}" != "true" ]]; then
  main "$@"
fi
