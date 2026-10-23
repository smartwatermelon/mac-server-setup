#!/usr/bin/env bats
#
# Tests for app-setup/templates/www/ and how caddy-setup.sh deploys it.
#
# caddy-setup.sh used to copy www/ with plain cp, so the landing page's
# QuickConnect links went out as literal __QUICKCONNECT_*__ hrefs and 404ed
# (deployed that way from 2026-04-19 to 2026-10-22).
#
# Run with: bats tests/www-templates.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
WWW_DIR="${WWW_DIR:-${REPO_DIR}/app-setup/templates/www}"
SETUP="${REPO_DIR}/app-setup/caddy-setup.sh"
CADDYFILE="${REPO_DIR}/app-setup/templates/Caddyfile"

@test "caddy-setup substitutes the www text files after copying them" {
  grep -qE 'for web_file in .*/www/"\*\.html .*/www/"\*\.webmanifest; do' "${SETUP}"
  grep -qE 'substitute_template "\$\{web_file\}"' "${SETUP}"
}

@test "every placeholder in a www text file is one caddy-setup substitutes" {
  local token missing=""
  while read -r token; do
    [[ -z "${token}" ]] && continue
    grep -qF "s|${token}|" "${SETUP}" || missing+="${token} "
  done < <(cat "${WWW_DIR}"/*.html "${WWW_DIR}"/*.webmanifest | grep -oE '__[A-Z_]+__' | sort -u)
  [ -z "${missing}" ] || {
    echo "not substituted: ${missing}"
    return 1
  }
}

@test "landing page QuickConnect links use the Caddy redirect paths" {
  local href
  for href in /romano /berkswell; do
    grep -qF "href=\"${href}\"" "${WWW_DIR}/index.html"
    grep -qE "^[[:space:]]*redir ${href} " "${CADDYFILE}"
  done
  run grep -F '__QUICKCONNECT_' "${WWW_DIR}/index.html"
  [ "${status}" -ne 0 ]
}
