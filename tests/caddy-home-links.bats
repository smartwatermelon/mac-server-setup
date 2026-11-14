#!/usr/bin/env bats
#
# Tests for the optional dashboard links in app-setup/caddy-setup.sh (#265):
# resolve_home_links and substitute_template, the code between the
# "# BEGIN home links" and "# END home links" markers.
# Run with: bats tests/caddy-home-links.bats
#
# The links used to be two fixed NAS keys. The HOME_LINK1_* and HOME_LINK2_*
# keys replace them. An old key alone must stop caddy-setup.sh, so a deploy
# never changes the dashboard labels or link paths without notice.
#
# Only the marked block is extracted. caddy-setup.sh itself is never run: it
# writes to /usr/local and /Library. Renders go to a temp dir.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP="${REPO_DIR}/app-setup/caddy-setup.sh"
TEMPLATES="${REPO_DIR}/app-setup/templates"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  OUT="${TEST_TMPDIR}/out"
  RENDER="${TEST_TMPDIR}/render.sh"
  {
    awk '/^# BEGIN home links$/{f=1} f{print} /^# END home links$/{exit}' "${SETUP}"
    cat <<'RUN'
HOSTNAME="testhost"
HOSTNAME_LOWER="testhost"
OPERATOR_USERNAME="operator"
EXTERNAL_HOSTNAME="example.com"
SERVER_LAN_IP="10.0.15.15"
BASICAUTH_USERNAME="user"
BASICAUTH_HASH="hash"
NAS_SHARE_NAME="Media"
ACCESS_ALLOWED_EMAIL="allowed@example.com"
resolve_home_links || exit 1
resolve_home_assistant || exit 1
mkdir -p "$1"
substitute_template "${TEMPLATES}/Caddyfile" "$1/Caddyfile"
substitute_template "${TEMPLATES}/www/index.html" "$1/index.html"
substitute_template "${TEMPLATES}/caddy-health.sh" "$1/caddy-health.sh"
RUN
  } >"${RENDER}"
  grep -q '^resolve_home_links() {' "${RENDER}"
  grep -q '^substitute_template() {' "${RENDER}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# render [KEY=value ...]: render the three templates with only these keys set.
# /bin/bash, as caddy-setup.sh's shebang: 3.2 on macOS.
render() {
  run env -i PATH="${PATH}" TEMPLATES="${TEMPLATES}" "$@" /bin/bash "${RENDER}" "${OUT}"
}

# No marker line and no __PLACEHOLDER__ may survive a render.
assert_clean_render() {
  run grep -nE '@@(BEGIN|END)_HOME_|__[A-Z0-9_]+__' "${OUT}/Caddyfile" "${OUT}/index.html" "${OUT}/caddy-health.sh"
  echo "${output}"
  [ "${status}" -eq 1 ]
}

# Nothing rendered at all: the stop came before any write.
assert_refused() {
  echo "${output}"
  [ "${status}" -ne 0 ]
  [ ! -e "${OUT}" ]
}

@test "caddy-setup checks the links before its first write" {
  local check first_write
  check=$(awk '/^resolve_home_links \|\| exit 1$/ {print NR; exit}' "${SETUP}")
  first_write=$(awk '/^(install|mkdir|cp|chown) / {print NR; exit}' "${SETUP}")
  [ -n "${check}" ] && [ -n "${first_write}" ]
  [ "${check}" -lt "${first_write}" ]
}

@test "no links set: no redirect, no dashboard section, no health probe" {
  render
  [ "${status}" -eq 0 ]
  assert_clean_render
  run grep -E '^[[:space:]]*redir /' "${OUT}/Caddyfile"
  [ "${status}" -eq 1 ]
  run grep -F '<h3>Links</h3>' "${OUT}/index.html"
  [ "${status}" -eq 1 ]
  grep -qx 'HOME_LINK_PATHS=""' "${OUT}/caddy-health.sh"
}

@test "both links set: redirects, dashboard links and health probes" {
  render HOME_LINKS_TITLE="My Links" \
    HOME_LINK1_NAME="File Server" HOME_LINK1_PATH=files HOME_LINK1_URL=https://files.example.com:5001/ \
    HOME_LINK2_NAME=Router HOME_LINK2_PATH=router HOME_LINK2_URL=https://router.example.com
  [ "${status}" -eq 0 ]
  assert_clean_render
  grep -qxF $'\tredir /files https://files.example.com:5001/ 302' "${OUT}/Caddyfile"
  grep -qxF $'\tredir /files/ https://files.example.com:5001/ 302' "${OUT}/Caddyfile"
  grep -qxF $'\tredir /router https://router.example.com 302' "${OUT}/Caddyfile"
  grep -qF '<h3>My Links</h3>' "${OUT}/index.html"
  grep -qF '<a href="/files" target="files">File Server</a>' "${OUT}/index.html"
  grep -qF '<a href="/router" target="router">Router</a>' "${OUT}/index.html"
  grep -qx 'HOME_LINK_PATHS="files router"' "${OUT}/caddy-health.sh"
}

@test "empty URL: that link and its redirect are left out" {
  render HOME_LINK1_NAME=Files HOME_LINK1_PATH=files \
    HOME_LINK2_NAME=Router HOME_LINK2_PATH=router HOME_LINK2_URL=https://router.example.com
  [ "${status}" -eq 0 ]
  assert_clean_render
  run grep -F '/files' "${OUT}/Caddyfile" "${OUT}/index.html"
  [ "${status}" -eq 1 ]
  grep -qF '<a href="/router" target="router">Router</a>' "${OUT}/index.html"
  grep -qF '<h3>Links</h3>' "${OUT}/index.html"
  grep -qx 'HOME_LINK_PATHS="router"' "${OUT}/caddy-health.sh"
}

@test "an & in the URL is written as is" {
  render HOME_LINK1_NAME=Files HOME_LINK1_PATH=files HOME_LINK1_URL='https://files.example.com/?a=1&b=2'
  [ "${status}" -eq 0 ]
  grep -qxF $'\tredir /files https://files.example.com/?a=1&b=2 302' "${OUT}/Caddyfile"
}

@test "old key alone: stops before writing and prints the lines to add" {
  render QUICKCONNECT_ROMANO=https://old.example.com/one
  assert_refused
  [[ "${output}" == *"QUICKCONNECT_ROMANO is set"* ]]
  [[ "${output}" == *'HOME_LINK1_NAME="<label>"'* ]]
  [[ "${output}" == *'HOME_LINK1_PATH="<path>"'* ]]
  [[ "${output}" == *'HOME_LINK1_URL="https://old.example.com/one"'* ]]
  [[ "${output}" == *"remove QUICKCONNECT_ROMANO"* ]]
}

@test "second old key alone: stops and names slot 2" {
  render QUICKCONNECT_BERKSWELL=https://old.example.com/two
  assert_refused
  [[ "${output}" == *"QUICKCONNECT_BERKSWELL is set"* ]]
  [[ "${output}" == *'HOME_LINK2_URL="https://old.example.com/two"'* ]]
}

@test "old key with only the name set: still stops" {
  render QUICKCONNECT_ROMANO=https://old.example.com/one HOME_LINK1_NAME=Files
  assert_refused
}

@test "old key with the new name and path: uses them, takes the old URL, warns" {
  render QUICKCONNECT_ROMANO=https://old.example.com/one HOME_LINK1_NAME=Files HOME_LINK1_PATH=files
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"QUICKCONNECT_ROMANO is deprecated"* ]]
  assert_clean_render
  grep -qxF $'\tredir /files https://old.example.com/one 302' "${OUT}/Caddyfile"
  grep -qF '<a href="/files" target="files">Files</a>' "${OUT}/index.html"
}

@test "old key and all new keys: the new URL wins, with the warning" {
  render QUICKCONNECT_ROMANO=https://old.example.com/one \
    HOME_LINK1_NAME=Files HOME_LINK1_PATH=files HOME_LINK1_URL=https://new.example.com/
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"deprecated"* ]]
  grep -qxF $'\tredir /files https://new.example.com/ 302' "${OUT}/Caddyfile"
  run grep -F 'old.example.com' "${OUT}/Caddyfile"
  [ "${status}" -eq 1 ]
}

@test "known bad paths are refused before writing" {
  local bad
  for bad in 'a/b' 'a b' 'x{y}' 'a;b' '../up' 'media' 'Transmission'; do
    render HOME_LINK1_NAME=Files HOME_LINK1_PATH="${bad}" HOME_LINK1_URL=https://files.example.com/
    assert_refused
    [[ "${output}" == *"HOME_LINK1_PATH"* ]]
  done
}

@test "the same path twice is refused" {
  render HOME_LINK1_NAME=A HOME_LINK1_PATH=files HOME_LINK1_URL=https://a.example.com/ \
    HOME_LINK2_NAME=B HOME_LINK2_PATH=files HOME_LINK2_URL=https://b.example.com/
  assert_refused
  [[ "${output}" == *"HOME_LINK2_PATH"* ]]
}

@test "a URL set with no name or no path is refused" {
  render HOME_LINK1_PATH=files HOME_LINK1_URL=https://files.example.com/
  assert_refused
  [[ "${output}" == *"HOME_LINK1_NAME"* ]]
  render HOME_LINK1_NAME=Files HOME_LINK1_URL=https://files.example.com/
  assert_refused
  [[ "${output}" == *"HOME_LINK1_PATH"* ]]
}

@test "known bad URLs are refused before writing" {
  local bad
  for bad in 'http://files.example.com/' 'files.example.com' 'https://a b' \
    'https://a|b' 'https://a{b}' 'https://a"b' "https://a'b" 'https://a\b' 'https://a#frag' 'https://'; do
    render HOME_LINK1_NAME=Files HOME_LINK1_PATH=files HOME_LINK1_URL="${bad}"
    assert_refused
    [[ "${output}" == *"HOME_LINK1_URL"* ]]
  done
}

@test "known bad labels are refused before writing" {
  local bad
  for bad in '<b>x</b>' 'a&b' 'a|b' 'a"b'; do
    render HOME_LINK1_NAME="${bad}" HOME_LINK1_PATH=files HOME_LINK1_URL=https://files.example.com/
    assert_refused
    [[ "${output}" == *"HOME_LINK1_NAME"* ]]
  done
  render HOME_LINKS_TITLE='<i>x</i>'
  assert_refused
  [[ "${output}" == *"HOME_LINKS_TITLE"* ]]
}
