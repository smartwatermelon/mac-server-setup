#!/usr/bin/env bats
#
# Tests for scripts/docs/check-sensitive.sh, and a scan of every public doc.
#
# The docs site is public, so no real address, object id, secret reference
# or personal email may appear in it (#205). The checker matches by shape,
# so this file holds no real value: the bad values below are synthetic, and
# the ids are built at run time.
#
# Run with: bats tests/docs-sensitive.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
CHECK="${REPO_DIR}/scripts/docs/check-sensitive.sh"
ALLOWLIST="${REPO_DIR}/tests/fixtures/docs-sensitive/allowlist.tsv"

# Print string $1 repeated $2 times.
rep() {
  local out="" i
  for ((i = 0; i < $2; i++)); do out+="$1"; done
  printf '%s' "${out}"
}

# Synthetic ids, built here so no id-shaped literal sits in this file.
HEX32="$(rep ab 16)"
HEX40="$(rep ab 20)"
HEX64="$(rep cd 32)"
OPID="$(rep a1 13)"
WORD26="$(rep ab 13)"
U1="$(rep c 8)"
U2="$(rep d 4)"
U3="$(rep e 4)"
U4="$(rep f 4)"
U5="$(rep 0 12)"
UUID="${U1}-${U2}-${U3}-${U4}-${U5}"

# Write stdin to a page in the test dir and print its path.
page() {
  local p="${BATS_TEST_TMPDIR}/page.md"
  cat >"${p}"
  printf '%s' "${p}"
}

@test "usage: no file is a usage error" {
  run "${CHECK}"
  [ "${status}" -eq 64 ]
}

@test "usage: an unreadable file fails, never passes as clean" {
  run "${CHECK}" "${BATS_TEST_TMPDIR}/missing.md"
  [ "${status}" -eq 2 ]
}

@test "usage: a missing allowlist fails" {
  p="$(page <<<'clean text')"
  run "${CHECK}" --allowlist "${BATS_TEST_TMPDIR}/none.tsv" "${p}"
  [ "${status}" -eq 2 ]
}

@test "clean: documentation ranges, loopback and resolvers pass" {
  p="$(page <<<'Use 192.0.2.10, 198.51.100.7, 203.0.113.0/24, 127.0.0.1, 1.1.1.1 and 10.0.0.0/8.')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "ipv4: a private LAN address is found" {
  p="$(page <<<'The server is at 10.9.8.7 on the LAN.')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *":1: ipv4: 10.9.8.7" ]]
}

@test "ipv4: a CIDR block keeps its prefix in the report" {
  p="$(page <<<'LAN_SUBNET=10.9.8.0/22')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ipv4: 10.9.8.0/22" ]]
}

@test "ipv4: a dotted number with an octet over 255 is not an address" {
  p="$(page <<<'Version 1.2.300.4 shipped.')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 0 ]
}

@test "id: a 32-hex id is found" {
  p="$(page <<<"account id: ${HEX32}")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id: ${HEX32}" ]]
}

@test "id: a UUID is found" {
  p="$(page <<<"app ${UUID}")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id: ${UUID}" ]]
}

@test "id: a 64-hex Access AUD tag is found" {
  p="$(page <<<"aud ${HEX64}")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id: ${HEX64}" ]]
}

@test "id: two ids joined by one character are both found" {
  p="$(page <<<"${HEX32}/${HEX32}")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  ids="$(grep -c ': id: ' <<<"${output}" || true)"
  [ "${ids}" -eq 2 ]
}

@test "id: ids inside hyphenated names are found" {
  p="$(page <<<"zone-${HEX32} and app-${UUID}-x")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id: ${HEX32}"* ]]
  [[ "${output}" == *"id: ${UUID}"* ]]
}

@test "id: a 40-hex commit SHA is not an id" {
  p="$(page <<<"commit ${HEX40}")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 0 ]
}

@test "team: a real Zero Trust team host is found" {
  p="$(page <<<'login at blue-fox-a1b2.cloudflareaccess.com')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"team: blue-fox-a1b2.cloudflareaccess.com" ]]
}

@test "team: the placeholder team host passes" {
  p="$(page <<<'login at your-team.cloudflareaccess.com')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 0 ]
}

@test "op: an op:// reference is found" {
  p="$(page <<<'op read "op://Vault/item/field"')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"op: op://Vault/item/field" ]]
}

@test "op: the bare scheme name alone is not a reference" {
  p="$(page <<<"Any \`op://\` reference is flagged.")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 0 ]
}

@test "opid: a 26-character 1Password id is found" {
  p="$(page <<<"OP_VAULT_ID=\"${OPID}\"")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"opid: ${OPID}" ]]
}

@test "opid: a 26-letter word with no digit is not an id" {
  p="$(page <<<"${WORD26}")"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 0 ]
}

@test "email: a personal address is found" {
  p="$(page <<<'Mail alerts to someone@realmail.test.')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"email: someone@realmail.test" ]]
}

@test "email: an ssh target on a real host name is found" {
  p="$(page <<<'ssh operator@myhost.local')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 1 ]
}

@test "email: placeholder domains and hosts pass" {
  p="$(page <<<'you@example.com admin@yourdomain.com operator@macmini.local ops@sub.example.org')"
  run "${CHECK}" "${p}"
  [ "${status}" -eq 0 ]
}

@test "allowlist: an exact path and match entry suppresses one finding" {
  p="$(page <<<'upstream 10.9.8.7 and 10.9.8.8')"
  printf '# comment\n%s\t10.9.8.7\n' "${p}" >"${BATS_TEST_TMPDIR}/allow.tsv"
  run "${CHECK}" --allowlist "${BATS_TEST_TMPDIR}/allow.tsv" "${p}"
  [ "${status}" -eq 1 ]
  [[ "${output}" != *"10.9.8.7"* ]]
  [[ "${output}" == *"10.9.8.8"* ]]
}

@test "allowlist: an entry for another path does not apply" {
  p="$(page <<<'upstream 10.9.8.7')"
  printf 'elsewhere/other.md\t10.9.8.7\n' >"${BATS_TEST_TMPDIR}/allow.tsv"
  run "${CHECK}" --allowlist "${BATS_TEST_TMPDIR}/allow.tsv" "${p}"
  [ "${status}" -eq 1 ]
}

# git pathspec * matches across /, so 'docs/*.md' covers every subdirectory.
# Same file set as the deploy job's check in .github/workflows/docs.yml.
@test "docs: no public page holds a sensitive value" {
  cd "${REPO_DIR}"
  mapfile -t pages < <(git ls-files 'docs/*.md' README.md)
  [ "${#pages[@]}" -gt 0 ]
  run "${CHECK}" --allowlist "${ALLOWLIST}" "${pages[@]}"
  echo "${output}"
  [ "${status}" -eq 0 ]
}
