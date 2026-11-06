#!/usr/bin/env bats
#
# Tests for pending-move-cleanup.sh — the hourly sweep of Transmission's
# pending-move directory.
#
# The script's safety contract is that only entries confirmed absent from
# Transmission's torrent list are deleted. The case that broke it: with the
# incomplete directory disabled and partial renaming on, Transmission writes
# a single-file torrent as "<name>.part" until it completes. That basename
# never equals the torrent name, so the sweep deleted a download that was
# still in progress (Seven Psychopaths, 2026-09-05, plus several episodes
# before it).
#
# Run with: bats tests/pending-move-cleanup.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE="${REPO_DIR}/app-setup/templates/pending-move-cleanup.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  MOCK_BIN_DIR="${TEST_TMPDIR}/bin"
  mkdir -p "${MOCK_BIN_DIR}"

  # HOME drives the pending-move path and the log path.
  export HOME="${TEST_TMPDIR}/home"
  PENDING_MOVE="${HOME}/.local/mnt/TestShare/Media/Torrents/pending-move"
  mkdir -p "${PENDING_MOVE}" "${HOME}/.local/state"
  export PENDING_MOVE

  # The curl mock serves torrent names from this file, one per line.
  export RPC_NAMES_FILE="${TEST_TMPDIR}/names"
  : >"${RPC_NAMES_FILE}"

  write_curl_mock
  render_template
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

render_template() {
  CLEANUP="${TEST_TMPDIR}/pending-move-cleanup.sh"
  sed \
    -e "s|__SERVER_NAME__|TESTHOST|g" \
    -e "s|__TRANSMISSION_HOST_PORT__|9091|g" \
    -e "s|__NAS_SHARE_NAME__|TestShare|g" \
    -e "s|__OPERATOR_HOME__|${HOME}|g" \
    "${TEMPLATE}" >"${CLEANUP}"
  chmod +x "${CLEANUP}"
  export CLEANUP
}

# curl mock: serves the CSRF handshake on `-D -`, then a torrent-get response
# built from RPC_NAMES_FILE.
write_curl_mock() {
  cat >"${MOCK_BIN_DIR}/curl" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "${arg}" == "-D" ]]; then
    printf 'HTTP/1.1 409 Conflict\r\nX-Transmission-Session-Id: testtoken\r\n\r\n'
    exit 0
  fi
done

python3 - "${RPC_NAMES_FILE}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    names = [line.rstrip("\n") for line in f if line.strip()]
# Compact separators: the script matches the literal '"result":"success"',
# which is how Transmission itself emits it.
print(json.dumps({"arguments": {"torrents": [{"name": n} for n in names]},
                  "result": "success"}, separators=(",", ":")))
PY
MOCK
  chmod +x "${MOCK_BIN_DIR}/curl"
}

@test "keeps an in-progress .part file whose torrent is still active" {
  local name="Seven Psychopaths 2012 1080p WEB-DL HEVC x265-RMTeam.mkv"
  echo "${name}" >"${RPC_NAMES_FILE}"
  echo "partial" >"${PENDING_MOVE}/${name}.part"

  run "${CLEANUP}"
  [ "$status" -eq 0 ]
  [ -f "${PENDING_MOVE}/${name}.part" ]
  [[ "$output" != *"Removing orphaned entry"* ]]
}

@test "removes a .part file whose torrent is gone from Transmission" {
  echo "Something Else.mkv" >"${RPC_NAMES_FILE}"
  echo "partial" >"${PENDING_MOVE}/Old Download.mkv.part"

  run "${CLEANUP}"
  [ "$status" -eq 0 ]
  [ ! -e "${PENDING_MOVE}/Old Download.mkv.part" ]
  [[ "$output" == *"Removing orphaned entry: Old Download.mkv.part"* ]]
}

@test "keeps a completed file and directory whose torrents are active" {
  printf '%s\n' "Show.S01E01.mkv" "Movie.Dir" >"${RPC_NAMES_FILE}"
  echo "done" >"${PENDING_MOVE}/Show.S01E01.mkv"
  mkdir -p "${PENDING_MOVE}/Movie.Dir"

  run "${CLEANUP}"
  [ "$status" -eq 0 ]
  [ -f "${PENDING_MOVE}/Show.S01E01.mkv" ]
  [ -d "${PENDING_MOVE}/Movie.Dir" ]
  [[ "$output" == *"0 removed, 2 still tracked"* ]]
}

@test "removes an entry absent from Transmission" {
  echo "Active.mkv" >"${RPC_NAMES_FILE}"
  mkdir -p "${PENDING_MOVE}/Orphan.Dir"

  run "${CLEANUP}"
  [ "$status" -eq 0 ]
  [ ! -e "${PENDING_MOVE}/Orphan.Dir" ]
}

@test "deletes nothing when Transmission RPC is unreachable" {
  cat >"${MOCK_BIN_DIR}/curl" <<'MOCK'
#!/usr/bin/env bash
exit 7
MOCK
  mkdir -p "${PENDING_MOVE}/Orphan.Dir"

  run "${CLEANUP}"
  [ "$status" -eq 0 ]
  [ -d "${PENDING_MOVE}/Orphan.Dir" ]
  [[ "$output" == *"Cannot reach Transmission RPC"* ]]
}

# rm mock that behaves like rm -rf on the NFS mount when a file is still held
# open: it removes everything except .nfs.* files, then fails with "Directory
# not empty" if any remain. It records its arguments and refuses any path
# outside the test's temp dir.
write_nfs_rm_mock() {
  cat >"${MOCK_BIN_DIR}/rm-nfs" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_TMPDIR}/rm-calls"
target="${*: -1}"
case "${target}" in
  "${TEST_TMPDIR}"/*) ;;
  *) echo "rm-nfs: refusing ${target}" >&2; exit 99 ;;
esac
if [[ -d "${target}" ]]; then
  find "${target}" -mindepth 1 ! -type d ! -name '.nfs.*' -exec /bin/rm -f {} +
  find "${target}" -mindepth 1 -depth -type d -empty -exec /bin/rmdir {} +
  if [[ -n "$(find "${target}" -name '.nfs.*' -print -quit)" ]]; then
    echo "rm: ${target}: Directory not empty" >&2
    exit 1
  fi
  /bin/rmdir "${target}"
else
  /bin/rm -f "${target}"
fi
MOCK
  chmod +x "${MOCK_BIN_DIR}/rm-nfs"
  export RM_BIN="${MOCK_BIN_DIR}/rm-nfs"
}

@test "an orphan held open by NFS does not abort the sweep or fail the run" {
  write_nfs_rm_mock
  : >"${RPC_NAMES_FILE}"
  # "A..." sorts first so a set -e abort would skip "Z.Orphan".
  mkdir -p "${PENDING_MOVE}/A.Held" "${PENDING_MOVE}/Z.Orphan"
  echo "gone" >"${PENDING_MOVE}/A.Held/movie.avi"
  echo "open" >"${PENDING_MOVE}/A.Held/.nfs.20051025.93a8"
  echo "x" >"${PENDING_MOVE}/Z.Orphan/file.mkv"

  run "${CLEANUP}"
  [ "$status" -eq 0 ]
  [ ! -e "${PENDING_MOVE}/Z.Orphan" ]
  [ ! -e "${PENDING_MOVE}/A.Held/movie.avi" ]
  [ -f "${PENDING_MOVE}/A.Held/.nfs.20051025.93a8" ]
  [[ "$output" == *"Left in place: A.Held"* ]]
  [[ "$output" == *"1 removed, 0 still tracked by Transmission, 1 held open"* ]]
}

@test "a directory holding only .nfs.* files is skipped without rm or a log line" {
  write_nfs_rm_mock
  : >"${RPC_NAMES_FILE}"
  mkdir -p "${PENDING_MOVE}/Held.Dir/sub"
  echo "open" >"${PENDING_MOVE}/Held.Dir/.nfs.20051026.93a8"
  echo "open" >"${PENDING_MOVE}/Held.Dir/sub/.nfs.20051027.93a8"

  run "${CLEANUP}"
  [ "$status" -eq 0 ]
  [ -d "${PENDING_MOVE}/Held.Dir" ]
  [ ! -e "${TEST_TMPDIR}/rm-calls" ]
  [ -z "$output" ]
}

@test "a directory with .nfs.* and a real file is still removed" {
  write_nfs_rm_mock
  : >"${RPC_NAMES_FILE}"
  mkdir -p "${PENDING_MOVE}/Mixed.Dir"
  echo "open" >"${PENDING_MOVE}/Mixed.Dir/.nfs.1"
  echo "real" >"${PENDING_MOVE}/Mixed.Dir/real.mkv"

  run "${CLEANUP}"
  [ "$status" -eq 0 ]
  grep -qF "${PENDING_MOVE}/Mixed.Dir" "${TEST_TMPDIR}/rm-calls"
  [ ! -e "${PENDING_MOVE}/Mixed.Dir/real.mkv" ]
}

@test "a removal that fails for another reason is logged and fails the run" {
  cat >"${MOCK_BIN_DIR}/rm-fail" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_TMPDIR}/rm-calls"
echo "rm: Permission denied" >&2
exit 1
MOCK
  chmod +x "${MOCK_BIN_DIR}/rm-fail"
  export RM_BIN="${MOCK_BIN_DIR}/rm-fail"
  : >"${RPC_NAMES_FILE}"
  mkdir -p "${PENDING_MOVE}/A.Stuck" "${PENDING_MOVE}/B.Stuck"
  echo "x" >"${PENDING_MOVE}/A.Stuck/file.mkv"

  run "${CLEANUP}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: could not remove A.Stuck"* ]]
  [[ "$output" == *"ERROR: could not remove B.Stuck"* ]]
  [[ "$output" == *"2 failed"* ]]
}
