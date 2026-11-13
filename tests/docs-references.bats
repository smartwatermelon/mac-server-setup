#!/usr/bin/env bats
#
# Drift guard for doc moves (#205): every docs/...md path that code, tests,
# config or CLAUDE.md names must exist. Moving a doc without updating its
# references fails here, not in a user's terminal or an alert email.
#
# Run with: bats tests/docs-references.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SELF="tests/docs-references.bats"

# Print "file<TAB>docs-path" for each repo docs/...md path named in the
# given files. Repo-relative forms count: docs/x.md, ./docs/x.md and
# ${VAR}/docs/x.md. Another tree's docs folder (~/.claude/docs/x.md,
# site/docs/x.md) does not.
doc_refs() {
  grep -oHE '[-A-Za-z0-9_.~/{}$]*docs/[A-Za-z0-9_./-]+\.md' "$@" \
    | awk -F: '{ t = $2; p = index(t, "docs/"); pre = substr(t, 1, p - 1)
        if (pre == "" || pre == "./" || pre ~ /\}\/$/) print $1 "\t" substr(t, p) }' || true
}

# Print "file: path" for each named docs path that does not exist,
# relative to the current directory.
missing_refs() {
  local file path
  while IFS=$'\t' read -r file path; do
    [[ -f "${path}" ]] || printf '%s: %s\n' "${file}" "${path}"
  done < <(doc_refs "$@" || true)
}

# Print the referencing files: tracked code, tests, config, CLAUDE.md and
# root scripts, minus this file (its examples are not references).
sources() {
  local f
  while IFS= read -r f; do
    # A tracked symlink to a directory is not a file to scan.
    [[ -f "${REPO_DIR}/${f}" && "${f}" != "${SELF}" ]] && printf '%s\n' "${f}"
  done < <(git -C "${REPO_DIR}" ls-files app-setup scripts tests config CLAUDE.md '*.sh' || true)
}

@test "doc_refs: finds a path in a comment and in alert text" {
  printf '%s\n' '# See docs/apps/x-README.md' 'echo "docs: docs/a/b.md"' \
    "cp \"\${D}/docs/c.md\" ./docs/e.md" >"${BATS_TEST_TMPDIR}/s.sh"
  run doc_refs "${BATS_TEST_TMPDIR}/s.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\t'"docs/apps/x-README.md"* ]]
  [[ "${output}" == *$'\t'"docs/a/b.md"* ]]
  [[ "${output}" == *$'\t'"docs/c.md"* ]]
  [[ "${output}" == *$'\t'"docs/e.md"* ]]
}

@test "doc_refs: paths into other trees' docs folders are not counted" {
  printf 'see ~/.claude/docs/X.md and site/docs/y.md\n' >"${BATS_TEST_TMPDIR}/s.sh"
  run doc_refs "${BATS_TEST_TMPDIR}/s.sh"
  [ -z "${output}" ]
}

@test "known bad: a reference to a missing doc is reported" {
  cd "${REPO_DIR}"
  printf '# See docs/no-such-page.md and docs/stack-matrix.md\n' >"${BATS_TEST_TMPDIR}/s.sh"
  run missing_refs "${BATS_TEST_TMPDIR}/s.sh"
  [ "${output}" = "${BATS_TEST_TMPDIR}/s.sh: docs/no-such-page.md" ]
}

@test "sources: the scan covers code, tests, config and CLAUDE.md" {
  run sources
  [[ "${output}" == *"CLAUDE.md"* ]]
  [[ "${output}" == *"prep-airdrop.sh"* ]]
  [[ "${output}" == *"app-setup/"* ]]
  [[ "${output}" != *"${SELF}"* ]]
}

@test "every docs path named in code, tests, config and CLAUDE.md exists" {
  cd "${REPO_DIR}"
  mapfile -t files < <(sources || true)
  [ "${#files[@]}" -gt 0 ]
  run missing_refs "${files[@]}"
  echo "${output}"
  [ -z "${output}" ]
}
