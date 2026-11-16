#!/usr/bin/env bats
#
# Tests for the first-boot.sh summary and FileVault offer (#251).
# Run with: bats tests/first-boot-summary.bats
#
# 1. Modules run as child processes. Their errors and warnings must reach
#    the final summary through SETUP_ERRORS_FILE and SETUP_WARNINGS_FILE.
# 2. A FileVault disable that succeeds must not leave an error behind.
#
# Functions are extracted from the scripts. fdesetup, sudo and
# disable_filevault are stubbed as shell functions, so no test can change
# FileVault on the host. No test runs the whole script.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SERVER_DIR="${REPO_DIR}/scripts/server"
FIRST_BOOT="${SERVER_DIR}/first-boot.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export CALLS="${TEST_TMPDIR}/calls"
  export SETUP_ERRORS_FILE="${TEST_TMPDIR}/errors"
  export SETUP_WARNINGS_FILE="${TEST_TMPDIR}/warnings"
  : >"${CALLS}"
  : >"${SETUP_ERRORS_FILE}"
  : >"${SETUP_WARNINGS_FILE}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# extract <file> <function>: print one function definition from a script.
extract() {
  sed -n "/^$2() {\$/,/^}\$/p" "$1"
}

# harness <out>: write the common stubs and the first-boot.sh functions.
harness() {
  local out="$1" fn
  {
    cat <<'STUBS'
set -euo pipefail
show_log() { echo "$*"; }
log() { echo "$*"; }
sudo() { echo "REAL-SUDO $*" >>"${CALLS}"; return 99; }
fdesetup() {
  local n
  n=$(($(cat "${TEST_TMPDIR}/fde_n" 2>/dev/null || echo 0) + 1))
  echo "${n}" >"${TEST_TMPDIR}/fde_n"
  if [[ -f "${TEST_TMPDIR}/fde_${n}" ]]; then
    cat "${TEST_TMPDIR}/fde_${n}"
  else
    cat "${TEST_TMPDIR}/fde_last"
  fi
}
disable_filevault() {
  echo "disable" >>"${CALLS}"
  local rc
  rc=$(head -1 "${TEST_TMPDIR}/disable_rc")
  sed -i.bak 1d "${TEST_TMPDIR}/disable_rc"
  return "${rc}"
}
COLLECTED_ERRORS=()
COLLECTED_WARNINGS=()
LOG_FILE=/example/first-boot.log
STUBS
    for fn in collect_error collect_warning show_collected_issues filevault_state check_filevault_compatibility; do
      extract "${FIRST_BOOT}" "${fn}"
    done
  } >"${out}"
  for fn in collect_error collect_warning show_collected_issues filevault_state check_filevault_compatibility; do
    grep -q "^${fn}() {\$" "${out}"
  done
  # The stubbed disable_filevault must be the only definition.
  local defs
  defs=$(grep -c '^disable_filevault() {$' "${out}" || true)
  [ "${defs}" -eq 1 ]
}

# fde <status...>: successive `fdesetup status` outputs; the last repeats.
fde() {
  local i=0 s
  for s in "$@"; do
    i=$((i + 1))
    printf '%s\n' "${s}" >"${TEST_TMPDIR}/fde_${i}"
    printf '%s\n' "${s}" >"${TEST_TMPDIR}/fde_last"
  done
}

# run_filevault <force> <answers> <disable rcs...>
run_filevault() {
  local force="$1" answers="$2" fn="${TEST_TMPDIR}/fv.sh"
  shift 2
  printf '%s\n' "$@" 0 >"${TEST_TMPDIR}/disable_rc"
  harness "${fn}"
  {
    echo "FORCE=${force} USER=tester TEST_TMPDIR='${TEST_TMPDIR}'"
    echo 'check_filevault_compatibility'
    echo 'show_collected_issues'
  } >>"${fn}"
  run bash "${fn}" <<<"${answers}"
}

# --- summary ----------------------------------------------------------------

summary() {
  local fn="${TEST_TMPDIR}/sum.sh"
  harness "${fn}"
  echo 'show_collected_issues' >>"${fn}"
  run "${BASH_UNDER_TEST:-bash}" "${fn}"
}

@test "summary: no errors anywhere reports success" {
  summary
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no errors or warnings"* ]]
}

@test "summary: module errors and warnings from the files are counted and listed" {
  echo "[setup-ssh-access.sh:10] SSH: ssh failed" >>"${SETUP_ERRORS_FILE}"
  echo "[setup-firewall.sh:20] Firewall: fw warn" >>"${SETUP_WARNINGS_FILE}"
  summary
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 errors and 1 warnings"* ]]
  [[ "${output}" == *"ssh failed"* ]]
  [[ "${output}" == *"fw warn"* ]]
}

@test "summary: unset file variables still work" {
  unset SETUP_ERRORS_FILE SETUP_WARNINGS_FILE
  summary
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no errors or warnings"* ]]
}

@test "summary: works under the system bash 3.2" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  echo "[m.sh:1] S: from file" >>"${SETUP_ERRORS_FILE}"
  BASH_UNDER_TEST=/bin/bash summary
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 errors and 0 warnings"* ]]
}

@test "first-boot.sh exports the files before the first summary" {
  export_line=$(awk '$0 == "export SETUP_ERRORS_FILE SETUP_WARNINGS_FILE" { print NR; exit }' "${FIRST_BOOT}")
  first_summary=$(awk '$0 == "  show_collected_issues" { print NR; exit }' "${FIRST_BOOT}")
  [ -n "${export_line}" ]
  [ -n "${first_summary}" ]
  [ "${export_line}" -lt "${first_summary}" ]
}

@test "every module that collects errors appends them to SETUP_ERRORS_FILE" {
  local m fn count=0
  for m in "${SERVER_DIR}"/setup-*.sh; do
    grep -q '^collect_error() {$' "${m}" || continue
    count=$((count + 1))
    fn="${TEST_TMPDIR}/mod.sh"
    {
      echo 'set -euo pipefail'
      echo 'show_log() { :; }'
      extract "${m}" collect_error
      echo 'collect_error "boom from module"'
    } >"${fn}"
    : >"${SETUP_ERRORS_FILE}"
    run bash "${fn}"
    [ "${status}" -eq 0 ] || {
      echo "${m}: status ${status}"
      return 1
    }
    grep -q 'boom from module' "${SETUP_ERRORS_FILE}" || {
      echo "${m} does not append to SETUP_ERRORS_FILE"
      return 1
    }
  done
  [ "${count}" -ge 15 ]
}

@test "every module that collects warnings appends them to SETUP_WARNINGS_FILE" {
  local m fn
  for m in "${SERVER_DIR}"/setup-*.sh; do
    grep -q '^collect_warning() {$' "${m}" || continue
    fn="${TEST_TMPDIR}/mod.sh"
    {
      echo 'set -euo pipefail'
      echo 'show_log() { :; }'
      extract "${m}" collect_warning
      echo 'collect_warning "warn from module"'
    } >"${fn}"
    : >"${SETUP_WARNINGS_FILE}"
    run bash "${fn}"
    grep -q 'warn from module' "${SETUP_WARNINGS_FILE}" || {
      echo "${m} does not append to SETUP_WARNINGS_FILE"
      return 1
    }
  done
}

# --- FileVault --------------------------------------------------------------

@test "filevault_state classifies fdesetup output" {
  fn="${TEST_TMPDIR}/st.sh"
  extract "${FIRST_BOOT}" filevault_state >"${fn}"
  cat >>"${fn}" <<'EOF'
for s in "FileVault is On." "FileVault is Off." \
  "FileVault is On.
Decryption in progress: Percent completed = 12.00" \
  "Decryption in progress: Pending" "something else"; do
  filevault_state "${s}"
done
EOF
  run bash "${fn}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf 'on\noff\ndecrypting\ndecrypting\nunknown')" ]
}

@test "FileVault off: no error" {
  fde "FileVault is Off."
  run_filevault false ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no errors or warnings"* ]]
  [ ! -s "${CALLS}" ]
}

@test "FileVault on, disable succeeds and decryption starts: no error" {
  fde "FileVault is On." "FileVault is On.
Decryption in progress: Pending"
  run_filevault false "y" 0
  [ "${status}" -eq 0 ]
  grep -qx disable "${CALLS}"
  [[ "${output}" == *"no errors or warnings"* ]]
}

@test "FileVault on, disable succeeds and status is Off: no error" {
  fde "FileVault is On." "FileVault is Off."
  run_filevault false "y" 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no errors or warnings"* ]]
}

@test "FileVault on, first disable fails, second succeeds: no error" {
  fde "FileVault is On." "FileVault is Off."
  run_filevault false "yy" 1 0
  [ "${status}" -eq 0 ]
  disables=$(grep -c '^disable$' "${CALLS}" || true)
  [ "${disables}" -eq 2 ]
  [[ "${output}" == *"no errors or warnings"* ]]
}

@test "FileVault on, user declines: one error and one warning" {
  fde "FileVault is On."
  run_filevault false "n"
  [ "${status}" -eq 0 ]
  [ ! -s "${CALLS}" ]
  [[ "${output}" == *"1 errors and 1 warnings"* ]]
  [[ "${output}" == *"incompatible with auto-login"* ]]
}

@test "FileVault on, force mode: one error and one warning, no disable" {
  fde "FileVault is On."
  run_filevault true ""
  [ "${status}" -eq 0 ]
  [ ! -s "${CALLS}" ]
  [[ "${output}" == *"1 errors and 1 warnings"* ]]
}

@test "FileVault already decrypting at start: no error" {
  fde "FileVault is On.
Decryption in progress: Percent completed = 40.00"
  run_filevault false ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no errors or warnings"* ]]
}
