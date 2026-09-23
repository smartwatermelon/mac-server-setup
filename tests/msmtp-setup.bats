#!/usr/bin/env bats
#
# Tests for app-setup/msmtp-setup.sh.
#
# The msmtp config holds the Gmail app password, so it is mode 600 and owned
# by operator. The setup script runs as the admin user, who cannot read it.
# Every check of that file's contents must therefore go through
# `sudo -u <operator>`; a plain grep as admin fails, the script decides no
# password is configured, and it prompts for one again on every run.
#
# The script is rendered into a sandbox app-setup directory (it insists on
# being run from one), with OPERATOR_HOME pointed at the sandbox. The config
# file is mode 000 so the test user cannot read it directly, and the sudo
# mock grants read access only for the duration of a `sudo -u` command --
# the same split as admin vs. operator on the server.
#
# Run with: bats tests/msmtp-setup.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/app-setup/msmtp-setup.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR

  export HOME="${TEST_TMPDIR}/home"
  mkdir -p "${HOME}"

  APP_DIR="${TEST_TMPDIR}/app-setup"
  mkdir -p "${APP_DIR}/config" "${APP_DIR}/templates"
  cp "${REPO_DIR}/app-setup/templates/alert-lib.sh" "${APP_DIR}/templates/alert-lib.sh"
  cat >"${APP_DIR}/config/config.conf" <<'EOF'
SERVER_NAME="TESTHOST"
OPERATOR_USERNAME="testop"
MONITORING_EMAIL="ops@example.com"
EOF

  OPERATOR_HOME="${TEST_TMPDIR}/operator"
  export MSMTP_CONFIG="${OPERATOR_HOME}/.config/msmtp/config"
  mkdir -p "$(dirname "${MSMTP_CONFIG}")"

  sed -e "s|^OPERATOR_HOME=.*|OPERATOR_HOME=\"${OPERATOR_HOME}\"|" \
    "${SETUP_SCRIPT}" >"${APP_DIR}/msmtp-setup.sh"
  chmod +x "${APP_DIR}/msmtp-setup.sh"

  MOCK_BIN_DIR="${TEST_TMPDIR}/bin"
  mkdir -p "${MOCK_BIN_DIR}"
  export SUDO_LOG="${TEST_TMPDIR}/sudo.log"
  : >"${SUDO_LOG}"
  write_sudo_mock
  write_msmtp_mock
  write_brew_mock
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

teardown() {
  chmod 600 "${MSMTP_CONFIG}" 2>/dev/null || true
  rm -rf "${TEST_TMPDIR}"
}

# sudo mock. Logs every call. For `sudo -u`/`-iu <user> grep ...` it makes
# the config readable for that one command, standing in for operator's read
# access. Every other command (cp, chown, chmod, mkdir, the test send) is
# logged and reported as successful without running.
write_sudo_mock() {
  cat >"${MOCK_BIN_DIR}/sudo" <<'MOCK'
#!/usr/bin/env bash
echo "sudo $*" >>"${SUDO_LOG}"
as_user=false
if [[ "$1" == "-u" || "$1" == "-iu" ]]; then
  as_user=true
  shift 2
fi
if [[ "${as_user}" == "true" && "$(basename "$1")" == "grep" ]]; then
  chmod 600 "${MSMTP_CONFIG}"
  "$@"
  rc=$?
  chmod 000 "${MSMTP_CONFIG}"
  exit "${rc}"
fi
exit 0
MOCK
  chmod +x "${MOCK_BIN_DIR}/sudo"
}

write_msmtp_mock() {
  printf '#!/usr/bin/env bash\necho "msmtp version 0.0-test"\n' >"${MOCK_BIN_DIR}/msmtp"
  chmod +x "${MOCK_BIN_DIR}/msmtp"
}

# Installing anything would mean the script took a wrong turn.
write_brew_mock() {
  printf '#!/usr/bin/env bash\necho "unexpected brew $*" >&2\nexit 1\n' >"${MOCK_BIN_DIR}/brew"
  chmod +x "${MOCK_BIN_DIR}/brew"
}

# An operator-only config that already has a password, like the live one.
write_existing_config() {
  printf 'account gmail\nuser ops@example.com\npassword       not-a-real-secret\n' >"${MSMTP_CONFIG}"
  chmod 000 "${MSMTP_CONFIG}"
}

run_setup() {
  cd "${APP_DIR}" && ./msmtp-setup.sh "$@" </dev/null
}

@test "fixture: the test user cannot read the config directly" {
  write_existing_config
  run grep -q '^password ' "${MSMTP_CONFIG}"
  [ "$status" -ne 0 ]
}

@test "an existing operator-only config with a password is kept, with no prompt" {
  write_existing_config

  run run_setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists with embedded password"* ]]
  [[ "$output" == *"Keeping existing msmtp configuration"* ]]
  [[ "$output" != *"Gmail App Password is required"* ]]
  grep -q "^sudo -u testop grep" "${SUDO_LOG}"
}

@test "a config with no password line still asks for one" {
  printf 'account gmail\nuser ops@example.com\n' >"${MSMTP_CONFIG}"
  chmod 000 "${MSMTP_CONFIG}"

  run run_setup
  [ "$status" -ne 0 ]
  [[ "$output" == *"Gmail App Password is required"* ]]
  [[ "$output" != *"Keeping existing msmtp configuration"* ]]
}
