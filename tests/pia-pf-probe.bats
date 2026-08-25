#!/usr/bin/env bats
#
# Tests for pia-pf-probe.sh — the one-shot region survey that reports which PIA
# regions actually serve port forwarding.
#
# The script exposes the same TEST_RUNNER hook cloudflare-ddns.sh uses: setting
# TEST_RUNNER=true before sourcing skips the `main "$@"` entry point, so the
# functions can be exercised individually with `podman` and `curl` stubbed out.
#
# Two failure modes drive this suite:
#
#   1. An empty region list must abort, not probe an empty region name. A
#      here-string always appends a newline, so `mapfile -t regions <<<""`
#      yields regions=("") — one empty element — which slips past a
#      `${#regions[@]} -gt 0` guard and emits a nonsense CSV row (issue #171).
#
#   2. `tunnel_timeout` is the script's catch-all for "no tunnel appeared",
#      which an unknown region name produces just as readily as a dead
#      endpoint. That ambiguity cost a full survey run (issue #174), so the row
#      format it emits is pinned here.
#
# Run with: bats tests/pia-pf-probe.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
PROBE="${REPO_DIR}/app-setup/templates/pia-pf-probe.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  MOCK_BIN_DIR="${TEST_TMPDIR}/bin"
  mkdir -p "${MOCK_BIN_DIR}"

  export CALL_LOG="${TEST_TMPDIR}/calls.log"
  : >"${CALL_LOG}"

  # Stub podman so no container is ever created. Behaviour is switched by
  # files rather than env vars because each invocation is a fresh process.
  export PODMAN_RUN_RC_FILE="${TEST_TMPDIR}/podman_run_rc"
  echo 0 >"${PODMAN_RUN_RC_FILE}"

  cat >"${MOCK_BIN_DIR}/podman" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALL_LOG}"
case "$1" in
  run)
    exit "$(cat "${PODMAN_RUN_RC_FILE}")"
    ;;
  exec)
    # Never report a tunnel gateway, so probe_region takes the timeout path.
    exit 0
    ;;
  rm)
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "${MOCK_BIN_DIR}/podman"

  # curl and jq only have to exist for require_deps; the tests that care about
  # region discovery stub list_pf_regions directly rather than going near the
  # network, so neither stub needs to produce meaningful output.
  local stub
  for stub in curl jq; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${MOCK_BIN_DIR}/${stub}"
    chmod +x "${MOCK_BIN_DIR}/${stub}"
  done

  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# Source the probe with its entry point disabled, so only definitions load.
load_probe() {
  export TEST_RUNNER=true
  # shellcheck source=/dev/null
  source "${PROBE}"
}

# ---------------------------------------------------------------------------
# Empty region list must abort (#171)
# ---------------------------------------------------------------------------

@test "an empty region list aborts instead of probing an empty region name" {
  # Reproduces the exact shape of the bug: --all with a list_pf_regions that
  # returns nothing, which is what a curl failure or a server list with no
  # port_forward=true entries produces.
  local script="${TEST_TMPDIR}/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'TEST_RUNNER=true'
    printf '%s\n' "source \"${PROBE}\""
    printf '%s\n' 'list_pf_regions() { printf ""; }'
    printf '%s\n' 'load_credentials() { PIA_USERNAME=u; PIA_PASSWORD=p; }'
    printf '%s\n' 'probe_region() { printf "PROBED:[%s]\n" "$1" >&2; printf "x,no,stub,,,\n"; }'
    printf '%s\n' 'cleanup_probe_container() { :; }'
    printf '%s\n' "main --all --out \"${TEST_TMPDIR}/out.csv\""
  } >"${script}"

  run bash "${script}"

  [ "$status" -ne 0 ]
  [[ "$output" == *"No regions advertising port_forward=true"* ]]
  # The decisive assertion: probe_region must never have been reached.
  [[ "$output" != *"PROBED:"* ]]
}

@test "mapfile on an empty here-string would otherwise yield one empty element" {
  # Pins the bash behaviour the guard exists to defeat. If this ever stops
  # being true the explicit -z check becomes dead code rather than load-bearing.
  local count first
  count=$(
    mapfile -t a <<<""
    echo "${#a[@]}"
  )
  first=$(
    mapfile -t a <<<""
    printf '[%s]' "${a[0]}"
  )
  [ "${count}" -eq 1 ]
  [ "${first}" = "[]" ]
}

@test "a populated region list is probed one region per line" {
  local script="${TEST_TMPDIR}/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'TEST_RUNNER=true'
    printf '%s\n' "source \"${PROBE}\""
    printf '%s\n' 'list_pf_regions() { printf "ca_vancouver\nde_frankfurt\n"; }'
    printf '%s\n' 'load_credentials() { PIA_USERNAME=u; PIA_PASSWORD=p; }'
    # An OK row so main's "nothing confirmed" exit-1 path is not what is under
    # test here; the region-to-row mapping is.
    printf '%s\n' 'probe_region() { printf "%s,yes,OK,40001,10.0.0.1,confirmed\n" "$1"; }'
    printf '%s\n' 'cleanup_probe_container() { :; }'
    printf '%s\n' "main --all --out \"${TEST_TMPDIR}/out.csv\""
  } >"${script}"

  run bash "${script}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 candidate regions"* ]]
  [[ "$output" == *"2/2 region(s) with working port forwarding"* ]]

  run grep -c . "${TEST_TMPDIR}/out.csv"
  # Header plus one row per region.
  [ "$output" -eq 3 ]

  run grep -q '^ca_vancouver,' "${TEST_TMPDIR}/out.csv"
  [ "$status" -eq 0 ]
  run grep -q '^de_frankfurt,' "${TEST_TMPDIR}/out.csv"
  [ "$status" -eq 0 ]
  # No empty-region row.
  run grep -q '^,' "${TEST_TMPDIR}/out.csv"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# CSV contract (#174)
# ---------------------------------------------------------------------------

@test "the CSV header names all six columns every row must fill" {
  local script="${TEST_TMPDIR}/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'TEST_RUNNER=true'
    printf '%s\n' "source \"${PROBE}\""
    printf '%s\n' 'load_credentials() { PIA_USERNAME=u; PIA_PASSWORD=p; }'
    printf '%s\n' 'probe_region() { printf "%s,no,stub,,,note\n" "$1"; }'
    printf '%s\n' 'cleanup_probe_container() { :; }'
    printf '%s\n' "main --out \"${TEST_TMPDIR}/out.csv\" ca_vancouver"
  } >"${script}"

  # Nothing confirmed, so main exits 1 by design — the header is still written.
  run bash "${script}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No region returned a usable forwarded port"* ]]

  run head -1 "${TEST_TMPDIR}/out.csv"
  [ "$output" = "region,tunnel_up,pf_status,port,gateway,notes" ]
}

@test "a container that never starts is reported as container_failed, not a tunnel problem" {
  load_probe
  echo 1 >"${PODMAN_RUN_RC_FILE}"
  # probe_region interpolates the credentials into the podman run flags; main
  # normally sets them via load_credentials.
  PIA_USERNAME=u
  PIA_PASSWORD=p

  run probe_region "bogus_region"
  [ "$status" -eq 0 ]
  [[ "$output" == "bogus_region,no,container_failed,,,could not start probe container" ]]
}

@test "a container that starts but never routes is reported as tunnel_timeout" {
  # This is the ambiguous row from #174: an unknown region name and a dead
  # endpoint are indistinguishable here. Pinning the format is what makes a
  # future disambiguation a visible, test-breaking change rather than a silent
  # one.
  load_probe
  echo 0 >"${PODMAN_RUN_RC_FILE}"
  PIA_USERNAME=u
  PIA_PASSWORD=p
  # Collapse the wait so the test does not sit through the real 90s timeout.
  # probe_region reads TUNNEL_TIMEOUT from the enclosing scope; assigning it on
  # the call keeps that dependency explicit.
  TUNNEL_TIMEOUT=0 run probe_region "ca_vancouver"
  [ "$status" -eq 0 ]
  [[ "$output" == "ca_vancouver,no,tunnel_timeout,,,no tunnel after 0s" ]]
}

# ---------------------------------------------------------------------------
# Credential loading
# ---------------------------------------------------------------------------

@test "credentials are read from PIA_ENV_FILE rather than the command line" {
  load_probe

  local env_file="${TEST_TMPDIR}/pia.env"
  printf 'PIA_USERNAME=p1234567\nPIA_PASSWORD=s3cr3t\n' >"${env_file}"

  PIA_ENV_FILE="${env_file}" load_credentials
  [ "${PIA_USERNAME}" = "p1234567" ]
  [ "${PIA_PASSWORD}" = "s3cr3t" ]
}

@test "a password containing '=' survives credential parsing intact" {
  # cut -d= -f2- keeps everything after the first '='; -f2 alone would truncate.
  load_probe

  local env_file="${TEST_TMPDIR}/pia.env"
  printf 'PIA_USERNAME=p1234567\nPIA_PASSWORD=a=b=c\n' >"${env_file}"

  PIA_ENV_FILE="${env_file}" load_credentials
  [ "${PIA_PASSWORD}" = "a=b=c" ]
}

@test "a missing env file fails loudly instead of probing without credentials" {
  load_probe

  run load_credentials
  # die() exits non-zero rather than returning, so run captures the exit.
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot read PIA env file"* ]]
}

@test "an env file missing PIA_PASSWORD is rejected" {
  load_probe

  local env_file="${TEST_TMPDIR}/pia.env"
  printf 'PIA_USERNAME=p1234567\n' >"${env_file}"

  PIA_ENV_FILE="${env_file}" run load_credentials
  [ "$status" -ne 0 ]
  [[ "$output" == *"PIA_PASSWORD missing"* ]]
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

@test "an unknown option is rejected rather than treated as a region name" {
  local script="${TEST_TMPDIR}/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'TEST_RUNNER=true'
    printf '%s\n' "source \"${PROBE}\""
    printf '%s\n' 'load_credentials() { PIA_USERNAME=u; PIA_PASSWORD=p; }'
    printf '%s\n' 'probe_region() { printf "%s,no,stub,,,\n" "$1"; }'
    printf '%s\n' 'cleanup_probe_container() { :; }'
    printf '%s\n' 'main --nonsense'
  } >"${script}"

  run bash "${script}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option: --nonsense"* ]]
}

@test "the TEST_RUNNER hook keeps sourcing side-effect free" {
  # If main ran on source, every test above would probe for real.
  run grep -E '^if \[\[ "\$\{TEST_RUNNER:-false\}" != "true" \]\]; then' "${PROBE}"
  [ "$status" -eq 0 ]
}
