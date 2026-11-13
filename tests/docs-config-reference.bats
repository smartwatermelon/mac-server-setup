#!/usr/bin/env bats
#
# scripts/docs/gen-config-reference.sh (#205): every config.conf.template key
# needs a description, and docs/reference/config-keys.md must match the
# template. Run with: bats tests/docs-config-reference.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
GEN="${REPO_DIR}/scripts/docs/gen-config-reference.sh"

tmpl() { cat >"${BATS_TEST_TMPDIR}/t.conf"; }

@test "the committed page matches the template" {
  run "${GEN}" --check
  echo "${output}"
  [ "${status}" -eq 0 ]
}

@test "known bad: a key with no description fails and is named" {
  printf '# Section\nGOOD="1"  # described\nBARE="2"\n' | tmpl
  run "${GEN}" "${BATS_TEST_TMPDIR}/t.conf" "${BATS_TEST_TMPDIR}/out.md"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"BARE"* ]]
  [[ "${output}" != *"GOOD"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/out.md" ]
}

@test "known bad: a stale page fails --check" {
  printf '# Section\nA="1"  # first\n' | tmpl
  "${GEN}" "${BATS_TEST_TMPDIR}/t.conf" "${BATS_TEST_TMPDIR}/out.md"
  printf '# Section\nA="1"  # first\nB="2"  # added later\n' | tmpl
  run "${GEN}" --check "${BATS_TEST_TMPDIR}/t.conf" "${BATS_TEST_TMPDIR}/out.md"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"out of date"* ]]
}

@test "a missing page fails --check" {
  printf '# Section\nA="1"  # first\n' | tmpl
  run "${GEN}" --check "${BATS_TEST_TMPDIR}/t.conf" "${BATS_TEST_TMPDIR}/none.md"
  [ "${status}" -eq 1 ]
}

@test "an unreadable template exits 2" {
  run "${GEN}" "${BATS_TEST_TMPDIR}/no-such.conf" "${BATS_TEST_TMPDIR}/out.md"
  [ "${status}" -eq 2 ]
}

@test "descriptions come from inline, above-key and indented comments" {
  printf '%s\n' '# Header, no keys' '' '# Sect' '# Intro line.' 'A="x"  # inline' '' '# Two' \
    'B=""' '  # indented first' '  # Second sentence' \
    '  # and wraps' '# above C' 'C="1"' | tmpl
  run "${GEN}" "${BATS_TEST_TMPDIR}/t.conf" "${BATS_TEST_TMPDIR}/out.md"
  [ "${status}" -eq 0 ]
  page="$(cat "${BATS_TEST_TMPDIR}/out.md")"
  [[ "${page}" == *$'## Sect\n\nIntro line.\n'* ]]
  [[ "${page}" == *"| \`A\` | \`x\` | inline |"* ]]
  [[ "${page}" == *"| \`B\` | (empty) | indented first<br>Second sentence and wraps |"* ]]
  [[ "${page}" == *"| \`C\` | \`1\` | above C |"* ]]
  [[ "${page}" != *"Header"* ]]
}

@test "pipes, angle brackets and URLs in a description are escaped" {
  printf '%s\n' '# S' 'A=""  # a | b <team>' 'U=""  # (e.g. https://x.example/u1)' | tmpl
  run "${GEN}" "${BATS_TEST_TMPDIR}/t.conf" "${BATS_TEST_TMPDIR}/out.md"
  [ "${status}" -eq 0 ]
  grep -qF "| \`A\` | (empty) | a \\| b &lt;team&gt; |" "${BATS_TEST_TMPDIR}/out.md"
  grep -qF "| \`U\` | (empty) | (e.g. \`https://x.example/u1\`) |" "${BATS_TEST_TMPDIR}/out.md"
}
