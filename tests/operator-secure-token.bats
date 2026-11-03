#!/usr/bin/env bats
#
# Tests for operator_has_secure_token and ensure_operator_secure_token in
# scripts/server/first-boot.sh.
# Run with: bats tests/operator-secure-token.bats
#
# first-boot.sh created the operator account with sysadminctl -addUser and no
# admin credentials, so the account had no SecureToken and the Passwords app
# rejected its correct password (#231).
#
# The functions are extracted from the script. sysadminctl is a stub
# (SYSADMINCTL_BIN) that records its arguments and keeps the token state in a
# temp file, so no test changes the real system.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
FIRST_BOOT="${REPO_DIR}/scripts/server/first-boot.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TOKEN_STATE="${TEST_TMPDIR}/token"
  export CALLS="${TEST_TMPDIR}/calls"
  export GRANT_FILE="${TEST_TMPDIR}/grant-works"
  echo true >"${GRANT_FILE}"
  echo DISABLED >"${TOKEN_STATE}"
  : >"${CALLS}"

  export SYSADMINCTL_BIN="${TEST_TMPDIR}/sysadminctl"
  cat >"${SYSADMINCTL_BIN}" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${CALLS}"
case "$1" in
  -secureTokenStatus)
    echo "2026-11-03 sysadminctl[1:1] Secure token is $(cat "${TOKEN_STATE}") for user $2" >&2
    ;;
  -secureTokenOn)
    # Real sysadminctl can exit 0 without granting the token.
    if [[ "$(cat "${GRANT_FILE}")" == true ]]; then
      echo ENABLED >"${TOKEN_STATE}"
    else
      echo "Operation is not permitted without secure token unlock (pw=$4 admin=$8)." >&2
    fi
    ;;
esac
exit 0
STUB
  chmod +x "${SYSADMINCTL_BIN}"

  local fn="${TEST_TMPDIR}/fns.sh"
  cat >"${fn}" <<'STUBS'
sudo() {
  while [[ "$1" == "-p" ]]; do shift 2; done
  "$@"
}
log() { echo "log: $*"; }
collect_error() { echo "collect_error: $1"; }
STUBS
  sed -n '/^operator_has_secure_token() {/,/^}/p' "${FIRST_BOOT}" >>"${fn}"
  sed -n '/^ensure_operator_secure_token() {/,/^}/p' "${FIRST_BOOT}" >>"${fn}"
  grep -q '^operator_has_secure_token() {' "${fn}"
  grep -q '^ensure_operator_secure_token() {' "${fn}"
  # shellcheck source=/dev/null
  source "${fn}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

@test "operator_has_secure_token reads ENABLED from stderr" {
  echo ENABLED >"${TOKEN_STATE}"
  operator_has_secure_token operator
}

@test "operator_has_secure_token is false when DISABLED" {
  run operator_has_secure_token operator
  [ "$status" -ne 0 ]
}

@test "token already enabled: no grant is attempted" {
  echo ENABLED >"${TOKEN_STATE}"
  run ensure_operator_secure_token operator userpw admin adminpw
  [ "$status" -eq 0 ]
  ! grep -q -- "-secureTokenOn" "${CALLS}"
}

@test "token missing: grants it with the admin credentials" {
  run ensure_operator_secure_token operator userpw admin adminpw
  [ "$status" -eq 0 ]
  grep -qx -- "-secureTokenOn operator -password userpw -adminUser admin -adminPassword adminpw" "${CALLS}"
  local state
  state=$(cat "${TOKEN_STATE}")
  [ "${state}" = ENABLED ]
  [[ "$output" == *"log operator out and back in"* ]]
}

@test "grant exits 0 but the token stays off: reports an error" {
  echo false >"${GRANT_FILE}"
  run ensure_operator_secure_token operator userpw admin adminpw
  [ "$status" -eq 1 ]
  [[ "$output" == *"collect_error: Could not grant a SecureToken to operator"* ]]
  [[ "$output" == *"sudo sysadminctl -secureTokenOn operator"* ]]
}

@test "no admin password (force mode): reports an error, does not call -secureTokenOn" {
  run ensure_operator_secure_token operator userpw admin ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"collect_error: operator has no SecureToken"* ]]
  ! grep -q -- "-secureTokenOn" "${CALLS}"
}

@test "failed grant: the error keeps sysadminctl's reason" {
  echo false >"${GRANT_FILE}"
  run ensure_operator_secure_token operator userpw admin adminpw
  [[ "$output" == *"sysadminctl: Operation is not permitted without secure token unlock"* ]]
}

@test "passwords never appear in the error text, even when sysadminctl echoes them" {
  echo false >"${GRANT_FILE}"
  run ensure_operator_secure_token operator userpw admin adminpw
  [[ "$output" != *userpw* ]]
  [[ "$output" != *adminpw* ]]
}

@test "-addUser call passes the admin credentials when the password is known" {
  grep -qF "add_user_admin_args=(-adminUser \"\${ADMIN_USERNAME}\" -adminPassword \"\${ADMINISTRATOR_PASSWORD}\")" "${FIRST_BOOT}"
  grep -q -- "-addUser \"\\\${OPERATOR_USERNAME}\".*add_user_admin_args" "${FIRST_BOOT}"
}
