#!/usr/bin/env bats
#
# Tests for app-setup/templates/stable-sign.sh.
#
# stable-sign.sh mirrors selected Homebrew formulae into a fixed prefix and
# re-signs named binaries with a local identity so macOS TCC grants survive
# `brew upgrade` (docs/apps/stable-signing-README.md).
#
# codesign, security and sudo are mocked in ${TEST_TMPDIR}/bin. The codesign
# mock records each signature as a trailing "#SIG:" line inside the binary
# (so it travels with the bytes, like a real signature) and verifies `-R=`
# requirements against it, so tests can assert on the identifier and
# certificate that were actually applied. rsync and openssl are the real
# tools.
#
# Run with: bats tests/stable-sign.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE="${REPO_DIR}/app-setup/templates/stable-sign.sh"

CERT_SHA1="c04dd12c1a8c4c99a0eab5618f56d7ea4c0d821b"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  MOCK_BIN_DIR="${TEST_TMPDIR}/bin"
  mkdir -p "${MOCK_BIN_DIR}"

  # Render the template the way setup-auto-updates.sh does.
  SCRIPT="${TEST_TMPDIR}/stable-sign.sh"
  sed -e 's|__HOSTNAME_LOWER__|testhost|g' -e 's|__HOSTNAME__|TESTHOST|g' "${TEMPLATE}" >"${SCRIPT}"
  chmod +x "${SCRIPT}"

  export HOMEBREW_PREFIX="${TEST_TMPDIR}/brew"
  export STABLE_ROOT="${TEST_TMPDIR}/stable"
  export KEYCHAIN="${TEST_TMPDIR}/System.keychain"
  export SIGNING_IDENTITY="TESTHOST Local Code Signing"
  export IDENTIFIER_PREFIX="local.testhost.stable"

  # Mock state: identity exists when this file exists.
  IDENTITY_FILE="${TEST_TMPDIR}/identity.present"
  CODESIGN_LOG="${TEST_TMPDIR}/codesign.calls"
  : >"${CODESIGN_LOG}"
  export IDENTITY_FILE CODESIGN_LOG

  make_fake_formula "6.1.1"
  write_mocks
  export PATH="${MOCK_BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# A fake Homebrew podman: Cellar/podman/<ver>/{bin,libexec/podman} with the
# same shape as the real formula, including the relative podman symlink.
make_fake_formula() {
  local ver="$1"
  local cellar="${HOMEBREW_PREFIX}/Cellar/podman/${ver}"
  mkdir -p "${cellar}/bin" "${cellar}/libexec/podman" "${HOMEBREW_PREFIX}/opt"
  printf '#!/bin/sh\necho podman-remote %s\n' "${ver}" >"${cellar}/bin/podman-remote"
  printf '#!/bin/sh\necho helper\n' >"${cellar}/bin/podman-mac-helper"
  printf '#!/bin/sh\necho vfkit\n' >"${cellar}/libexec/podman/vfkit"
  printf '#!/bin/sh\necho gvproxy\n' >"${cellar}/libexec/podman/gvproxy"
  chmod +x "${cellar}/bin/"* "${cellar}/libexec/podman/"*
  ln -sf podman-remote "${cellar}/bin/podman"
  ln -sfn "../Cellar/podman/${ver}" "${HOMEBREW_PREFIX}/opt/podman"
}

write_mocks() {
  # sudo: drop -n / -p <prompt> and run the command as-is.
  cat >"${MOCK_BIN_DIR}/sudo" <<'MOCK_EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) shift ;;
    -p) shift 2 ;;
    -v) exit 0 ;;
    *) break ;;
  esac
done
exec "$@"
MOCK_EOF

  # security: find-identity / find-certificate answer from IDENTITY_FILE;
  # import creates it.
  cat >"${MOCK_BIN_DIR}/security" <<MOCK_EOF
#!/usr/bin/env bash
case "\$1" in
  find-identity)
    if [[ -f "\${IDENTITY_FILE}" ]]; then
      echo "  1) ${CERT_SHA1^^} \"${SIGNING_IDENTITY}\""
      echo "     1 identities found"
    else
      echo "     0 identities found"
    fi
    ;;
  find-certificate)
    [[ -f "\${IDENTITY_FILE}" ]] || exit 44
    echo "SHA-1 hash: ${CERT_SHA1^^}"
    echo "keychain: \"${KEYCHAIN}\""
    ;;
  import)
    touch "\${IDENTITY_FILE}"
    echo "1 identity imported."
    ;;
  *) exit 1 ;;
esac
MOCK_EOF

  # codesign. Like a real signature, the mock's lives inside the file so it
  # travels with the bytes through the temp-copy-and-mv sequence:
  #   -f -s ID --identifier X --keychain K FILE  -> append "#SIG:X|<sha1>"
  #   -v -R=<req> FILE                            -> compare req to that line
  cat >"${MOCK_BIN_DIR}/codesign" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$*" >>"\${CODESIGN_LOG}"
if [[ "\$1" == "-f" ]]; then
  ident=""; file=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --identifier) ident="\$2"; shift 2 ;;
      -f|-s|--keychain) [[ "\$1" == "-f" ]] && shift || shift 2 ;;
      *) file="\$1"; shift ;;
    esac
  done
  [[ -f "\${IDENTITY_FILE}" ]] || { echo "no identity" >&2; exit 1; }
  grep -v '^#SIG:' "\${file}" >"\${file}.unsigned" || true
  cat "\${file}.unsigned" >"\${file}"; rm -f "\${file}.unsigned"
  echo "#SIG:\${ident}|${CERT_SHA1}" >>"\${file}"
  exit 0
fi
if [[ "\$1" == "-v" ]]; then
  req="\${2#-R=}"; file="\$3"
  have=\$(grep '^#SIG:' "\${file}" 2>/dev/null | tail -1)
  [[ -n "\${have}" ]] || exit 1
  ident=\$(sed -n 's/^identifier "\([^"]*\)".*/\1/p' <<<"\${req}")
  cert=\$(sed -n 's/.*certificate root = H"\([0-9a-f]*\)".*/\1/p' <<<"\${req}")
  [[ "\${have}" == "#SIG:\${ident}|\${cert}" ]]
  exit \$?
fi
exit 1
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/"*
}

sig_of() {
  grep '^#SIG:' "${STABLE_ROOT}/podman/bin/$1" 2>/dev/null | tail -1 | sed 's/^#SIG://' || true
}

# ---------------------------------------------------------------------------
# Rendering and argument handling
# ---------------------------------------------------------------------------

@test "template renders with no placeholder left behind" {
  run grep -c '__[A-Z_]*__' "${SCRIPT}"
  [ "${output}" -eq 0 ]
  run bash -n "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "unknown option exits 2" {
  run "${SCRIPT}" --bogus
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"Unknown option"* ]]
}

@test "--check fails when the signing identity does not exist" {
  run "${SCRIPT}" --check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"signing identity"*"not found"* ]]
}

# ---------------------------------------------------------------------------
# First run
# ---------------------------------------------------------------------------

@test "first run creates the identity, mirrors the formula and signs the target" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"signing identity created"* ]]
  [ -f "${IDENTITY_FILE}" ]

  # Everything in bin/ and libexec/ is mirrored, symlink kept relative.
  [ -x "${STABLE_ROOT}/podman/bin/podman-remote" ]
  [ -x "${STABLE_ROOT}/podman/bin/podman-mac-helper" ]
  [ -x "${STABLE_ROOT}/podman/libexec/podman/vfkit" ]
  [ -x "${STABLE_ROOT}/podman/libexec/podman/gvproxy" ]
  [ "$(readlink "${STABLE_ROOT}/podman/bin/podman")" == "podman-remote" ]

  # The target got the stable identifier and the local certificate.
  [ "$(sig_of podman-remote)" == "local.testhost.stable.podman-remote|${CERT_SHA1}" ]
  [ "$(cat "${STABLE_ROOT}/podman/.source-version")" == "../Cellar/podman/6.1.1" ]
}

@test "the stable copy is a real file, not a link back into the Cellar" {
  # A symlink would resolve to the versioned Cellar path and TCC would key
  # the grant on that - the exact thing this script exists to avoid.
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ ! -L "${STABLE_ROOT}/podman/bin/podman-remote" ]
  [ ! -L "${STABLE_ROOT}/podman/bin" ]
  [ ! -L "${STABLE_ROOT}/podman" ]
}

@test "only listed binaries are re-signed; vfkit and gvproxy keep their signatures" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  # vfkit carries the com.apple.security.virtualization entitlement, which a
  # plain `codesign -f` would strip. Neither helper may be touched.
  run grep -E 'vfkit|gvproxy|podman-mac-helper' "${CODESIGN_LOG}"
  [ "${status}" -ne 0 ]
  run grep -l '^#SIG:' "${STABLE_ROOT}/podman/libexec/podman/vfkit" \
    "${STABLE_ROOT}/podman/libexec/podman/gvproxy" "${STABLE_ROOT}/podman/bin/podman-mac-helper"
  [ -z "${output}" ]
}

@test "signing happens on a temp copy that replaces the file, never in place" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  run grep -E '^-f .*\.stable-sign\.tmp$' "${CODESIGN_LOG}"
  [ "${status}" -eq 0 ]
  # No temp file left behind.
  run find "${STABLE_ROOT}" -name '*.stable-sign.tmp'
  [ -z "${output}" ]
}

@test "--check reports OK and exits 0 after a successful run" {
  "${SCRIPT}" >/dev/null
  run "${SCRIPT}" --check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"podman-remote "*" OK   identifier \"local.testhost.stable.podman-remote\" and certificate root = H\"${CERT_SHA1}\""* ]]
}

# ---------------------------------------------------------------------------
# Idempotency and upgrade handling
# ---------------------------------------------------------------------------

@test "a second run with nothing changed does not re-sign" {
  "${SCRIPT}" >/dev/null
  : >"${CODESIGN_LOG}"

  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"podman: current"*"nothing to do"* ]]
  run grep -c '^-f' "${CODESIGN_LOG}"
  [ "${output}" -eq 0 ]
}

@test "a brew upgrade (opt link moved) triggers a re-sync and re-sign" {
  "${SCRIPT}" >/dev/null
  make_fake_formula "6.2.0"
  : >"${CODESIGN_LOG}"

  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"synced ../Cellar/podman/6.2.0"* ]]
  [ "$(cat "${STABLE_ROOT}/podman/.source-version")" == "../Cellar/podman/6.2.0" ]
  [ "$("${STABLE_ROOT}/podman/bin/podman-remote")" == "podman-remote 6.2.0" ]
  # Same identifier and certificate as before: the requirement is stable.
  [ "$(sig_of podman-remote)" == "local.testhost.stable.podman-remote|${CERT_SHA1}" ]
}

@test "--check exits 1 when the mirror is behind the installed formula" {
  "${SCRIPT}" >/dev/null
  make_fake_formula "6.2.0"

  run "${SCRIPT}" --check
  [ "${status}" -eq 1 ]
}

@test "a stable copy whose signature no longer matches is re-signed even if the version is unchanged" {
  "${SCRIPT}" >/dev/null
  # Simulate a tampered/ad-hoc signature on the stable copy.
  echo "#SIG:a.out|deadbeef" >>"${STABLE_ROOT}/podman/bin/podman-remote"

  run "${SCRIPT}" --check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"STALE"* ]]

  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(sig_of podman-remote)" == "local.testhost.stable.podman-remote|${CERT_SHA1}" ]
}

@test "--force re-signs an up-to-date mirror" {
  "${SCRIPT}" >/dev/null
  : >"${CODESIGN_LOG}"

  run "${SCRIPT}" --force
  [ "${status}" -eq 0 ]
  run grep -c '^-f' "${CODESIGN_LOG}"
  [ "${output}" -eq 1 ]
}

@test "a formula that is not installed is skipped, not fatal" {
  rm -rf "${HOMEBREW_PREFIX}/opt/podman"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"podman: not installed, skipping"* ]]
}

@test "files removed upstream are removed from the mirror" {
  "${SCRIPT}" >/dev/null
  rm "${HOMEBREW_PREFIX}/opt/podman/bin/podman-mac-helper"
  make_fake_formula "6.2.0"
  rm "${HOMEBREW_PREFIX}/Cellar/podman/6.2.0/bin/podman-mac-helper"

  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ ! -e "${STABLE_ROOT}/podman/bin/podman-mac-helper" ]
}

@test "a codesign failure is fatal and leaves no half-signed temp file" {
  # Identity file vanishes after ensure_identity ran once: codesign mock
  # refuses to sign without it. Use a wrapper script that removes it just
  # before codesign runs.
  touch "${IDENTITY_FILE}"
  cat >"${MOCK_BIN_DIR}/codesign.real" <"${MOCK_BIN_DIR}/codesign"
  cat >"${MOCK_BIN_DIR}/codesign" <<'MOCK_EOF'
#!/usr/bin/env bash
[[ "$1" == "-f" ]] && exit 1
exec "$(dirname "$0")/codesign.real" "$@"
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/codesign" "${MOCK_BIN_DIR}/codesign.real"

  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"codesign failed"* ]]
  run find "${STABLE_ROOT}" -name '*.stable-sign.tmp'
  [ -z "${output}" ]
  # The stamp is dropped before the sync starts, so an interrupted run can
  # never leave a half-updated mirror that reads as current.
  [ ! -e "${STABLE_ROOT}/podman/.source-version" ]
}

@test "an interrupted sync leaves the mirror stale, not current" {
  "${SCRIPT}" >/dev/null
  make_fake_formula "6.2.0"
  cat >"${MOCK_BIN_DIR}/codesign.real" <"${MOCK_BIN_DIR}/codesign"
  cat >"${MOCK_BIN_DIR}/codesign" <<'MOCK_EOF'
#!/usr/bin/env bash
[[ "$1" == "-f" ]] && exit 1
exec "$(dirname "$0")/codesign.real" "$@"
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/codesign" "${MOCK_BIN_DIR}/codesign.real"

  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [ ! -e "${STABLE_ROOT}/podman/.source-version" ]
  run "${SCRIPT}" --check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"synced from <never>"* ]]
}

@test "sudo denial on first run is fatal and creates neither identity nor mirror" {
  # Unattended run on a fresh box with no NOPASSWD rule: `sudo -n` fails.
  cat >"${MOCK_BIN_DIR}/sudo" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "sudo: a password is required" >&2
exit 1
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/sudo"

  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"security import failed"* ]]
  [ ! -f "${IDENTITY_FILE}" ]
  [ ! -e "${STABLE_ROOT}" ]
}

@test "sudo denial when creating the stable root is fatal" {
  touch "${IDENTITY_FILE}"
  cat >"${MOCK_BIN_DIR}/sudo" <<'MOCK_EOF'
#!/usr/bin/env bash
exit 1
MOCK_EOF
  chmod +x "${MOCK_BIN_DIR}/sudo"

  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"could not create ${STABLE_ROOT}"* ]]
  [ ! -e "${STABLE_ROOT}/podman" ]
}

@test "a source change with identical size and mtime is still copied (checksum, not quick-check)" {
  "${SCRIPT}" >/dev/null
  # podman-mac-helper is mirrored verbatim, so source and stable copy have
  # identical size; give them identical mtime too, then change one byte.
  local src="${HOMEBREW_PREFIX}/opt/podman/bin/podman-mac-helper"
  local dst="${STABLE_ROOT}/podman/bin/podman-mac-helper"
  printf '#!/bin/sh\necho helpeX\n' >"${src}"
  touch -r "${dst}" "${src}"
  [ "$(stat -f %z "${src}")" -eq "$(stat -f %z "${dst}")" ]
  [ "$(stat -f %m "${src}")" -eq "$(stat -f %m "${dst}")" ]

  run "${SCRIPT}" --force
  [ "${status}" -eq 0 ]
  [ "$("${dst}")" == "helpeX" ]
}

@test "--check treats an uninstalled formula as skipped, not stale" {
  touch "${IDENTITY_FILE}"
  rm -rf "${HOMEBREW_PREFIX}/opt/podman"
  run "${SCRIPT}" --check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not installed (skipped)"* ]]
}

# A fake Homebrew coreutils: g-prefixed binaries plus the unprefixed
# `timeout -> gtimeout` link the supervisor relies on.
make_fake_coreutils() {
  local ver="$1"
  local cellar="${HOMEBREW_PREFIX}/Cellar/coreutils/${ver}"
  mkdir -p "${cellar}/bin"
  printf '#!/bin/sh\necho gtimeout %s\n' "${ver}" >"${cellar}/bin/gtimeout"
  printf '#!/bin/sh\necho gdate\n' >"${cellar}/bin/gdate"
  chmod +x "${cellar}/bin/"*
  ln -sf gtimeout "${cellar}/bin/timeout"
  ln -sfn "../Cellar/coreutils/${ver}" "${HOMEBREW_PREFIX}/opt/coreutils"
}

@test "coreutils gtimeout is mirrored and signed; the timeout link resolves to it" {
  # timeout is the outermost non-Apple binary in the supervisor's process
  # chain, so macOS holds it responsible for the VM's network-volume access.
  make_fake_coreutils "9.11"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"coreutils: synced ../Cellar/coreutils/9.11"* ]]
  [ "$(grep '^#SIG:' "${STABLE_ROOT}/coreutils/bin/gtimeout" | sed 's/^#SIG://')" \
    == "local.testhost.stable.gtimeout|${CERT_SHA1}" ]
  [ "$(readlink "${STABLE_ROOT}/coreutils/bin/timeout")" == "gtimeout" ]
  run grep -l '^#SIG:' "${STABLE_ROOT}/coreutils/bin/gdate"
  [ -z "${output}" ]

  run "${SCRIPT}" --check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"timeout "*"link -> gtimeout (signed)"* ]]
}

@test "--check shows where the bare podman link points" {
  "${SCRIPT}" >/dev/null
  run "${SCRIPT}" --check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"podman "*"link -> podman-remote (signed)"* ]]
  [[ "${output}" == *"(1 other entries in bin/ keep their Homebrew signature)"* ]]
  [[ "${output}" != *"podman-mac-helper"* ]]
}
