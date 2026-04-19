#!/usr/bin/env bats
#
# Tests for logrotate glob patterns in config/logrotate.conf.
#
# Catches the class of bug where a reverse-DNS LaunchAgent label log
# (e.g. com.tilsit.mount-nas-media.log) fails to match a hyphen-shaped
# glob (com.*-mount-nas-media.log). The 107MB unrotated mount-nas-media
# log discovered on 2026-04-18 was caused by exactly that mismatch.
#
# Run with: bats tests/logrotate-globs.bats
# Requires: logrotate (brew install logrotate)

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
CONFIG_SRC="${REPO_DIR}/config/logrotate.conf"

setup() {
  if ! command -v logrotate >/dev/null 2>&1; then
    skip "logrotate not installed (brew install logrotate)"
  fi
  TEST_TMPDIR=$(mktemp -d)
  STATE_DIR="${TEST_TMPDIR}/Users/operator/.local/state"
  mkdir -p "${STATE_DIR}"

  # Render the repo config so its /Users/*/.local/state/ prefix points at
  # our tempdir, and drop the `include` line (dir may not exist in CI).
  RENDERED_CONF="${TEST_TMPDIR}/logrotate.conf"
  sed \
    -e "s|/Users/\*|${TEST_TMPDIR}/Users/*|g" \
    -e '/^include /d' \
    "${CONFIG_SRC}" >"${RENDERED_CONF}"
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "${TEST_TMPDIR}"
}

# Returns 0 if logrotate -d lists the given absolute path as "considering log".
considers_file() {
  local path="$1"
  local out
  out=$(logrotate -d "${RENDERED_CONF}" 2>&1)
  grep -Fq "considering log ${path}" <<<"${out}"
}

# ---------------------------------------------------------------------------
# Positive cases: files that should be picked up by the rotation stanza.
# ---------------------------------------------------------------------------

@test "matches com.<host>.mount-nas-media.log (dot-form label)" {
  local f="${STATE_DIR}/com.tilsit.mount-nas-media.log"
  touch "${f}"
  considers_file "${f}"
}

@test "matches *-podman-vm-stdout.log" {
  local f="${STATE_DIR}/tilsit-podman-vm-stdout.log"
  touch "${f}"
  considers_file "${f}"
}

@test "matches *-podman-vm-stderr.log" {
  local f="${STATE_DIR}/tilsit-podman-vm-stderr.log"
  touch "${f}"
  considers_file "${f}"
}

@test "matches msmtp.log" {
  local f="${STATE_DIR}/msmtp.log"
  touch "${f}"
  considers_file "${f}"
}

@test "matches plex-watchdog.log" {
  local f="${STATE_DIR}/plex-watchdog.log"
  touch "${f}"
  considers_file "${f}"
}

@test "matches *-mount.log" {
  local f="${STATE_DIR}/tilsit-mount.log"
  touch "${f}"
  considers_file "${f}"
}

# ---------------------------------------------------------------------------
# Regression guard: the old hyphen-form glob would miss the dot-form label.
# This is a local sanity check on glob semantics, not a test of our config.
# If this ever fails, something about glob matching changed and the positive
# case above has probably silently regressed to matching for the wrong reason.
# ---------------------------------------------------------------------------

@test "regression: com.*-mount-nas-media.log does NOT match com.tilsit.mount-nas-media.log" {
  local bad_conf="${TEST_TMPDIR}/bad.conf"
  cat >"${bad_conf}" <<EOF
${STATE_DIR}/com.*-mount-nas-media.log {
    weekly
    missingok
}
EOF
  local f="${STATE_DIR}/com.tilsit.mount-nas-media.log"
  touch "${f}"
  run sh -c "logrotate -d '${bad_conf}' 2>&1 | grep -Fq 'considering log ${f}'"
  [ "${status}" -ne 0 ]
}
