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

# Print "file<TAB>docs-path" for each docs/...md path named in the given
# files. A path inside a URL or a longer path still counts.
doc_refs() {
  grep -oHE 'docs/[A-Za-z0-9_./-]+\.md' "$@" | sed -E 's/:/\t/' || true
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
  printf '# See docs/apps/x-README.md\necho "docs: docs/a/b.md"\n' >"${BATS_TEST_TMPDIR}/s.sh"
  run doc_refs "${BATS_TEST_TMPDIR}/s.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *$'\t'"docs/apps/x-README.md"* ]]
  [[ "${output}" == *$'\t'"docs/a/b.md"* ]]
}

@test "known bad: a reference to a missing doc is reported" {
  printf '# See docs/no-such-page.md\n' >"${BATS_TEST_TMPDIR}/s.sh"
  missing=0
  while IFS=$'\t' read -r _ path; do
    [[ -f "${REPO_DIR}/${path}" ]] || missing=$((missing + 1))
  done < <(doc_refs "${BATS_TEST_TMPDIR}/s.sh" || true)
  [ "${missing}" -eq 1 ]
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
  bad=()
  while IFS=$'\t' read -r file path; do
    [[ -f "${path}" ]] || bad+=("${file}: ${path}")
  done < <(doc_refs "${files[@]}" || true)
  printf '%s\n' "${bad[@]}"
  [ "${#bad[@]}" -eq 0 ]
}
