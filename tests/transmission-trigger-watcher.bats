#!/usr/bin/env bats
#
# PATH order of transmission-trigger-watcher.sh. The watcher runs
# transmission-done (#!/usr/bin/env bash), and that bash is the binary macOS
# holds responsible for FileBot's reads on the NFS mount. It must be the
# stably-signed copy, or every Homebrew bash upgrade leaves a network-volume
# prompt that blocks FileBot. See docs/apps/stable-signing-README.md.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE="${REPO_DIR}/app-setup/templates/transmission-trigger-watcher.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  STABLE_DIR="${TEST_TMPDIR}/stable/bash/bin"
  mkdir -p "${STABLE_DIR}"
  printf '#!/bin/sh\necho stable-bash\n' >"${STABLE_DIR}/bash"
  chmod +x "${STABLE_DIR}/bash"
  BREW_DIR="${TEST_TMPDIR}/brew"
  mkdir -p "${BREW_DIR}/bin"
  printf '#!/bin/sh\necho homebrew-bash\n' >"${BREW_DIR}/bin/bash"
  chmod +x "${BREW_DIR}/bin/bash"

  # Only the PATH block, with the stable dir and Homebrew prefix pointed at
  # the fakes so the result does not depend on this host's Homebrew.
  PATH_BLOCK="${TEST_TMPDIR}/path-block.sh"
  sed -n '/^ARCH=/,/^export PATH=/p' "${TEMPLATE}" \
    | sed -e "s|^STABLE_BASH_BIN=.*|STABLE_BASH_BIN=\"${STABLE_DIR}\"|" \
      -e "s|HOMEBREW_PREFIX=\"[^\"]*\"|HOMEBREW_PREFIX=\"${BREW_DIR}\"|" >"${PATH_BLOCK}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

@test "the stable bash dir is first in the watcher's PATH" {
  run grep -E '^export PATH=' "${TEMPLATE}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == 'export PATH="${STABLE_BASH_BIN}:${HOMEBREW_PREFIX}/bin:'* ]]
  run grep -E '^STABLE_BASH_BIN=' "${TEMPLATE}"
  [ "${output}" == 'STABLE_BASH_BIN="/usr/local/stable/bash/bin"' ]
}

@test "#!/usr/bin/env bash children resolve to the stable bash" {
  run /bin/bash -c "source '${PATH_BLOCK}'; /usr/bin/env bash"
  [ "${status}" -eq 0 ]
  [ "${output}" == "stable-bash" ]
}

@test "without the stable mirror, children fall back to Homebrew bash, not /bin/bash" {
  rm -rf "${STABLE_DIR}"
  run /bin/bash -c "source '${PATH_BLOCK}'; /usr/bin/env bash"
  [ "${status}" -eq 0 ]
  [ "${output}" == "homebrew-bash" ]
}
