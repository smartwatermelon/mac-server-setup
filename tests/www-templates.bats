#!/usr/bin/env bats
#
# Tests for app-setup/templates/www/ and how caddy-setup.sh deploys it.
#
# caddy-setup.sh used to copy www/ with plain cp, so the landing page's
# NAS links went out as literal __PLACEHOLDER__ hrefs and 404ed (deployed
# that way from 2026-04-19 to 2026-10-22). Rendered output of the optional
# dashboard links is tested in caddy-home-links.bats.
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
  done < <(cat "${WWW_DIR}"/*.html "${WWW_DIR}"/*.webmanifest | grep -oE '__[A-Z0-9_]+__' | sort -u || true)
  [ -z "${missing}" ] || {
    echo "not substituted: ${missing}"
    return 1
  }
}

@test "landing page dashboard links use the Caddy redirect paths" {
  local n
  for n in 1 2; do
    grep -qF "href=\"/__HOME_LINK${n}_PATH__\"" "${WWW_DIR}/index.html"
    grep -qE "^[[:space:]]*redir /__HOME_LINK${n}_PATH__ __HOME_LINK${n}_URL__ 302$" "${CADDYFILE}"
  done
}

@test "every dashboard link marker opens and closes in each template" {
  local file marker
  for file in "${WWW_DIR}/index.html" "${CADDYFILE}"; do
    for marker in HOME_LINK1 HOME_LINK2; do
      [ "$(grep -c "@@BEGIN_${marker}@@" "${file}" || true)" -eq 1 ]
      [ "$(grep -c "@@END_${marker}@@" "${file}" || true)" -eq 1 ]
    done
  done
  [ "$(grep -c '@@BEGIN_HOME_LINKS@@' "${WWW_DIR}/index.html" || true)" -eq 1 ]
  [ "$(grep -c '@@END_HOME_LINKS@@' "${WWW_DIR}/index.html" || true)" -eq 1 ]
}

@test "Home Assistant link: one marked line that points to the HA hostname" {
  [ "$(grep -c '@@BEGIN_HOME_ASSISTANT@@' "${WWW_DIR}/index.html" || true)" -eq 1 ]
  [ "$(grep -c '@@END_HOME_ASSISTANT@@' "${WWW_DIR}/index.html" || true)" -eq 1 ]
  [ "$(awk '/@@BEGIN_HOME_ASSISTANT@@/{f=1; next} /@@END_HOME_ASSISTANT@@/{f=0} f' "${WWW_DIR}/index.html" || true)" = \
    '                    <li><a href="https://__HOME_ASSISTANT_HOSTNAME__/" target="home-assistant">Home Assistant</a></li>' ]
}
