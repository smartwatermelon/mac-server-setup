#!/usr/bin/env bats
#
# Tests for the podman-machine-start.sh supervisor loop (#123).
#
# podman-machine-start.sh is not a standalone file in the repo — it's a
# heredoc written out at deploy time by app-setup/podman-transmission-setup.sh
# (the `sudo tee "${MACHINE_START_DEST}" >/dev/null <<WRAPPER ... WRAPPER`
# block). This test extracts that heredoc body and re-expands it the same
# way the real deploy script does (unescaped ${VAR} tokens are deploy-time
# substitutions; \${VAR} tokens are escaped and become the deployed script's
# own runtime variables), using fixed test values in place of the real
# deploy-time variables (NFS_MOUNT_POINT, OPERATOR_HOME, HOST_PORT, etc.).
#
# A scripted `podman` mock is placed first in PATH and logs every invocation
# to $BATS_TMPDIR/podman.calls so tests can assert call order/counts without
# a real Podman machine or VM.
#
# Run with: bats tests/podman-machine-start.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/app-setup/podman-transmission-setup.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  MOCK_BIN_DIR="${TEST_TMPDIR}/bin"
  mkdir -p "${MOCK_BIN_DIR}"

  NFS_MOUNT_POINT="${TEST_TMPDIR}/nfs"
  OPERATOR_HOME="${TEST_TMPDIR}/home"
  mkdir -p "${NFS_MOUNT_POINT}" "${OPERATOR_HOME}/containers/transmission/scripts" \
    "${OPERATOR_HOME}/containers/transmission/config" "${OPERATOR_HOME}/containers/transmission/watch"
  touch "${OPERATOR_HOME}/containers/transmission/.env"

  CALLS_FILE="${TEST_TMPDIR}/podman.calls"
  : >"${CALLS_FILE}"
  export CALLS_FILE

  # State the podman mock reads/writes to decide how to respond. Backed by
  # files (not env vars) because each `podman` invocation is a fresh
  # process — mutations must persist across calls within a test.
  MACHINE_STATE_FILE="${TEST_TMPDIR}/machine.state"
  CONTAINER_EXISTS_FILE="${TEST_TMPDIR}/container.exists"
  CONTAINER_RUNNING_FILE="${TEST_TMPDIR}/container.running"
  export MACHINE_STATE_FILE CONTAINER_EXISTS_FILE CONTAINER_RUNNING_FILE

  set_mock_state "stopped" "false" "false"

  extract_and_render_wrapper
  write_podman_mock
  write_mount_mock
}

# ---------------------------------------------------------------------------
# The wrapper's wait_for_nfs() checks `/sbin/mount | grep -q " on <mount> "`
# before entering the supervision loop. A plain mkdir'd tempdir is never a
# real mount, so shim `mount` to report NFS_MOUNT_POINT as mounted --
# exercising wait_for_nfs()'s real grep logic without requiring an actual
# filesystem mount in the test sandbox.
# ---------------------------------------------------------------------------
write_mount_mock() {
  cat >"${MOCK_BIN_DIR}/mount" <<MOCK_EOF
#!/usr/bin/env bash
echo "nfs-server:/export/path on ${NFS_MOUNT_POINT} (nfs)"
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/mount"
}

set_mock_state() {
  echo "$1" >"${MACHINE_STATE_FILE}"
  echo "$2" >"${CONTAINER_EXISTS_FILE}"
  echo "$3" >"${CONTAINER_RUNNING_FILE}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Extract the WRAPPER heredoc body from podman-transmission-setup.sh and
# re-expand its deploy-time ${VAR} tokens using test values, mirroring
# exactly what `sudo tee ... <<WRAPPER` does at real deploy time.
# ---------------------------------------------------------------------------
extract_and_render_wrapper() {
  local raw
  raw=$(awk '/^sudo tee "\$\{MACHINE_START_DEST\}" >\/dev\/null <<WRAPPER$/{flag=1; next} /^WRAPPER$/{flag=0} flag' "${SETUP_SCRIPT}")

  if [[ -z "${raw}" ]]; then
    echo "Failed to extract WRAPPER heredoc from ${SETUP_SCRIPT}" >&2
    return 1
  fi

  # These are consumed indirectly by the `eval "cat <<RENDER_EOF ..."` below
  # (shellcheck can't trace variable use through eval), so they're exported
  # rather than declared local/plain -- exported vars are assumed to have
  # external consumers and don't trip SC2034.
  # HOMEBREW_PREFIX's /bin subdirectory must resolve to MOCK_BIN_DIR so the
  # wrapper's own `export PATH="${HOMEBREW_PREFIX}/bin:..."` line picks up
  # the mocks first.
  export HOSTNAME_LOWER="testhost"
  export HOST_PORT="9091"
  export PIA_REGION="panama"
  export LAN="192.168.1.0/24"
  export PUID="501"
  export PGID="20"
  export TZ_VALUE="America/Los_Angeles"
  export HOMEBREW_PREFIX="${TEST_TMPDIR}"

  WRAPPER_SCRIPT="${TEST_TMPDIR}/podman-machine-start.sh"
  eval "cat <<RENDER_EOF
${raw}
RENDER_EOF" >"${WRAPPER_SCRIPT}"

  # wait_for_nfs() checks the real absolute path /sbin/mount, which can't be
  # PATH-shimmed. Rewrite to a bare `mount` invocation so the test's mock
  # (placed first in PATH) is used instead, without touching the real
  # /sbin/mount logic covered elsewhere. This is the only line altered from
  # what deploy actually writes.
  if ! grep -q '/sbin/mount' "${WRAPPER_SCRIPT}"; then
    echo "Expected /sbin/mount in rendered wrapper -- extraction may be stale" >&2
    return 1
  fi
  sed -i.bak 's#/sbin/mount#mount#' "${WRAPPER_SCRIPT}"
  rm -f "${WRAPPER_SCRIPT}.bak"

  chmod +x "${WRAPPER_SCRIPT}"
}

# ---------------------------------------------------------------------------
# Scripted podman mock: logs every invocation, responds based on state
# recorded in MACHINE_STATE_FILE / CONTAINER_EXISTS_FILE / CONTAINER_RUNNING_FILE
# (files, not env vars, so state persists across the mock's separate process
# invocations within a single test).
# ---------------------------------------------------------------------------
write_podman_mock() {
  cat >"${MOCK_BIN_DIR}/podman" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "$*" >>"${CALLS_FILE}"

# Dispatch on the full argument list (not just "$1 $2") so callers that pass
# extra flags -- e.g. `machine inspect transmission-vm --format '{{.State}}'`
# -- are matched by pattern rather than having those flags silently ignored.
case "$*" in
  "machine inspect"*)
    cat "${MACHINE_STATE_FILE}"
    exit 0
    ;;
  "machine start"*)
    echo "running" >"${MACHINE_STATE_FILE}"
    exit 0
    ;;
  "machine stop"*)
    echo "stopped" >"${MACHINE_STATE_FILE}"
    exit 0
    ;;
esac

case "$1" in
  info)
    exit 0
    ;;
  container)
    # podman container exists transmission-vpn
    [[ "$(cat "${CONTAINER_EXISTS_FILE}")" == "true" ]] && exit 0 || exit 1
    ;;
  inspect)
    if [[ "$(cat "${CONTAINER_RUNNING_FILE}")" == "true" ]]; then
      echo "true"
    else
      echo "false"
    fi
    exit 0
    ;;
  rm)
    exit 0
    ;;
  run)
    echo "true" >"${CONTAINER_EXISTS_FILE}"
    echo "true" >"${CONTAINER_RUNNING_FILE}"
    exit 0
    ;;
  exec)
    # check_data_access: podman exec transmission-vpn ls /data/
    exit 0
    ;;
  stop)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/podman"
}

call_count() {
  local pattern="$1"
  # grep -c prints "0" (correct) but exits 1 on zero matches. `|| true`
  # normalizes the exit status to 0 without affecting the printed count
  # (unlike `|| echo 0`, which would double-print on a real zero-match case).
  grep -Fc "${pattern}" "${CALLS_FILE}" 2>/dev/null || true
}

run_wrapper_briefly() {
  # Run under `timeout` with a short SUPERVISE_INTERVAL so the loop executes
  # a couple of iterations before being killed.
  SUPERVISE_INTERVAL=1 timeout 5 "${WRAPPER_SCRIPT}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "wrapper extraction: heredoc renders a syntactically valid script" {
  run bash -n "${WRAPPER_SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "wrapper extraction: deploy-time variables are substituted, not left literal" {
  run cat "${WRAPPER_SCRIPT}"
  [[ "${output}" == *"${NFS_MOUNT_POINT}"* ]]
  [[ "${output}" != *'${NFS_MOUNT_POINT}'* ]]
  [[ "${output}" == *"com.testhost.podman-transmission-vm"* ]]
}

@test "wrapper extraction: runtime variables remain escaped (not deploy-time substituted)" {
  run cat "${WRAPPER_SCRIPT}"
  [[ "${output}" == *'SUPERVISE_INTERVAL=${SUPERVISE_INTERVAL:-300}'* ]]
}

@test "supervisor: calls machine start exactly once when initial state is stopped" {
  set_mock_state "stopped" "true" "true"

  run run_wrapper_briefly

  local start_calls
  start_calls=$(call_count "machine start transmission-vm")
  [ "${start_calls}" -eq 1 ]
}

@test "supervisor: does not call machine start again once state is running" {
  set_mock_state "running" "true" "true"

  run run_wrapper_briefly

  local start_calls
  start_calls=$(call_count "machine start transmission-vm")
  [ "${start_calls}" -eq 0 ]
}

@test "supervisor: runs podman run for transmission-vpn exactly once when container is missing" {
  set_mock_state "running" "false" "false"

  run run_wrapper_briefly

  local run_calls
  run_calls=$(grep -c '^run -d' "${CALLS_FILE}" || true)
  [ "${run_calls}" -eq 1 ]
}

@test "supervisor: does not call podman run again once the container exists and is running" {
  set_mock_state "running" "true" "true"

  run run_wrapper_briefly

  local run_calls
  run_calls=$(grep -c '^run -d' "${CALLS_FILE}" || true)
  [ "${run_calls}" -eq 0 ]
}

@test "supervisor: does not exit on its own -- termination is caused by timeout, not the script" {
  set_mock_state "running" "true" "true"

  run run_wrapper_briefly

  # `timeout` returns 124 when it had to kill the command, confirming the
  # wrapper was still alive (in its `while true` supervision loop) and did
  # not exit voluntarily within the 5s budget.
  [ "${status}" -eq 124 ]
}

@test "supervisor: loop runs multiple health-check iterations before being killed" {
  set_mock_state "running" "true" "true"

  run run_wrapper_briefly

  # Each iteration calls `podman machine inspect` at minimum via
  # ensure_machine(). With SUPERVISE_INTERVAL=1 under a 5s timeout, expect
  # at least the initial pre-loop check plus 2+ loop iterations.
  local inspect_calls
  inspect_calls=$(call_count "machine inspect transmission-vm")
  [ "${inspect_calls}" -ge 2 ]
}
