#!/usr/bin/env bats
#
# Tests for the optional Home Assistant host in app-setup/caddy-setup.sh:
# resolve_home_assistant and how substitute_template renders the
# @@BEGIN_HOME_ASSISTANT@@ parts of the Caddyfile and the landing page.
# The live routing tests are in caddyfile.bats.
# Run with: bats tests/caddy-home-assistant.bats
#
# The feature is off unless HOME_ASSISTANT_HOSTNAME and
# HOME_ASSISTANT_UPSTREAM are both set. Off, the render must be byte for
# byte what it was before the feature existed. Both values go into the
# Caddyfile unquoted, so anything that could add Caddyfile syntax must stop
# caddy-setup.sh before it writes a file.
#
# Only the "# BEGIN home links" block is extracted. caddy-setup.sh itself is
# never run: it writes to /usr/local and /Library.

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SETUP="${REPO_DIR}/app-setup/caddy-setup.sh"
TEMPLATES="${REPO_DIR}/app-setup/templates"

HA_ON=(HOME_ASSISTANT_HOSTNAME=ha.example.com HOME_ASSISTANT_UPSTREAM=192.168.1.20:8123)
LINKS_ON=(HOME_LINK1_NAME=Files HOME_LINK1_PATH=files "HOME_LINK1_URL=https://files.example.com/?a=1&b=2"
  HOME_LINK2_NAME=Router HOME_LINK2_PATH=router HOME_LINK2_URL=https://router.example.com)

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
  grep -q '^resolve_home_assistant() {' "${RENDER}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# render [KEY=value ...]: render the three templates with only these keys
# set. /bin/bash, as caddy-setup.sh's shebang: 3.2 on macOS.
render() {
  run env -i PATH="${PATH}" TEMPLATES="${TEMPLATES}" "$@" /bin/bash "${RENDER}" "${OUT}"
}

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

# sha256 of each rendered file, in a fixed order.
render_hashes() {
  (cd "${OUT}" && shasum -a 256 Caddyfile index.html caddy-health.sh)
}

# caddy adapt the rendered Caddyfile to JSON on stdout.
adapt() {
  HOSTNAME=testhost CF_API_TOKEN=dummy0token0for0validation0only000000000 \
    caddy adapt --config "${OUT}/Caddyfile" --adapter caddyfile 2>/dev/null
}

@test "caddy-setup checks the Home Assistant keys before its first write" {
  local check first_write
  check=$(awk '/^resolve_home_assistant \|\| exit 1$/ {print NR; exit}' "${SETUP}")
  first_write=$(awk '/^(install|mkdir|cp|chown) / {print NR; exit}' "${SETUP}")
  [ -n "${check}" ] && [ -n "${first_write}" ]
  [ "${check}" -lt "${first_write}" ]
}

# The hashes are of a render of commit 398302d (the last commit before this
# feature): its caddy-setup.sh block and templates, with the same inputs as
# render() above. They change only if the off-state output changes, which
# must not happen by accident.
@test "feature off: the render is byte for byte the pre-feature render (no links)" {
  render
  [ "${status}" -eq 0 ]
  assert_clean_render
  [ "$(render_hashes || true)" = "$(printf '%s\n' \
    '5c416a6363c40d680833c3468013574bb14ad4b829853d6edcee5f698fd0590d  Caddyfile' \
    '074c0826ca27a7a32a7b1438f1b2877c2c8e68c84201e8e02ea4df5d49571f71  index.html' \
    'bbeb5f0460679b2801f3d5e9f99b3c1248ca513299e21edc3b55b3414afcb457  caddy-health.sh' || true)" ]
}

@test "feature off: the render is byte for byte the pre-feature render (both links)" {
  render "${LINKS_ON[@]}"
  [ "${status}" -eq 0 ]
  assert_clean_render
  [ "$(render_hashes || true)" = "$(printf '%s\n' \
    '35a6b7d77df987b337fa1f607ecda6ebb8b7e1fc856cfc241828604fcf95ba0a  Caddyfile' \
    'af05dd933f8b386e8d0b16d458e37d7cc3f4f97a957dfbb3cdff7f36aca20748  index.html' \
    '58a0699d972b888b2c31d09a84a96e476c36dc8276c1f913c8445c3314006268  caddy-health.sh' || true)" ]
}

@test "feature off: no Home Assistant text anywhere in the render" {
  render
  run grep -niE 'home.?assistant|ha\.example' "${OUT}/Caddyfile" "${OUT}/index.html" "${OUT}/caddy-health.sh"
  [ "${status}" -eq 1 ]
}

@test "feature on: clean render, the route and the dashboard link" {
  render "${HA_ON[@]}" "${LINKS_ON[@]}"
  [ "${status}" -eq 0 ]
  assert_clean_render
  grep -qxF $'\t\t@home_assistant host ha.example.com' "${OUT}/Caddyfile"
  grep -qxF $'\t\t\treverse_proxy 192.168.1.20:8123 {' "${OUT}/Caddyfile"
  grep -qF '<li><a href="https://ha.example.com/" target="home-assistant">Home Assistant</a></li>' "${OUT}/index.html"
  # Only the tunnel site and the landing page change; the health check does not.
  [ "$(cd "${OUT}" && shasum -a 256 caddy-health.sh || true)" = \
    '58a0699d972b888b2c31d09a84a96e476c36dc8276c1f913c8445c3314006268  caddy-health.sh' ]
}

@test "feature on and off: caddy adapt accepts the render" {
  command -v caddy >/dev/null || skip "caddy not installed"
  render
  [ "${status}" -eq 0 ]
  adapt >/dev/null
  rm -rf "${OUT}"
  render "${HA_ON[@]}" "${LINKS_ON[@]}"
  [ "${status}" -eq 0 ]
  adapt >/dev/null
}

# (e) The HA upstream and host matcher exist only on the loopback tunnel
# listener: never on the :443 LAN and WAN sites or the catch-all.
@test "feature on: the HA upstream is only on the 127.0.0.1:8080 server" {
  command -v caddy >/dev/null || skip "caddy not installed"
  render "${HA_ON[@]}"
  [ "${status}" -eq 0 ]
  local json
  json=$(adapt)
  [ "$(jq -c '[.apps.http.servers[] | select(tostring | contains("192.168.1.20:8123")) | .listen]' <<<"${json}" || true)" = '[["127.0.0.1:8080"]]' ]
  [ "$(jq -c '[.apps.http.servers[] | select(tostring | contains("ha.example.com")) | .listen]' <<<"${json}" || true)" = '[["127.0.0.1:8080"]]' ]
  # And inside that server, only under the allowed-email match.
  [ "$(jq -c '[.apps.http.servers[] | select(.listen == ["127.0.0.1:8080"]) | .routes[]
    | select(tostring | contains("192.168.1.20:8123")) | .match]' <<<"${json}" || true)" = \
    '[[{"header":{"Cf-Access-Authenticated-User-Email":["allowed@example.com"]}}]]' ]
}

@test "one key without the other is refused before writing" {
  render HOME_ASSISTANT_HOSTNAME=ha.example.com
  assert_refused
  [[ "${output}" == *"HOME_ASSISTANT_HOSTNAME and HOME_ASSISTANT_UPSTREAM"* ]]
  render HOME_ASSISTANT_UPSTREAM=192.168.1.20:8123
  assert_refused
  [[ "${output}" == *"HOME_ASSISTANT_HOSTNAME and HOME_ASSISTANT_UPSTREAM"* ]]
}

@test "bad hostnames are refused before writing" {
  local bad
  for bad in 'HA.example.com' 'ha.example.org' 'example.com' 'haexample.com' 'ha..example.com' \
    '-ha.example.com' 'ha.example.com.' 'ha_x.example.com' 'ha example.com' 'ha.example.com}' \
    '{ha}.example.com' 'ha.example.com#' $'ha.example.com\nrespond 200' 'ha.example.com/x' \
    'https://ha.example.com' '*.example.com' 'ha.example.com,other.example.com'; do
    render HOME_ASSISTANT_HOSTNAME="${bad}" HOME_ASSISTANT_UPSTREAM=192.168.1.20:8123
    assert_refused
    [[ "${output}" == *"HOME_ASSISTANT_HOSTNAME"* ]]
  done
}

@test "bad upstreams are refused before writing" {
  local bad
  for bad in '192.168.1.20' 'http://192.168.1.20:8123' '192.168.1.20:8123/' '192.168.1.20:0' \
    '192.168.1.20:65536' '192.168.1.20:x' '300.1.1.1:8123' ':8123' '[::1]:8123' \
    'ha host:8123' 'ha}:8123' '192.168.1.20:8123 {' $'192.168.1.20:8123\nrespond 200' \
    '192.168.1.20:8123}' 'ha"x:8123' 'ha|x:8123' '-ha:8123' 'ha.:8123' \
    '1000.1.1.1:8123' '1.2.3:8123' '1.2.3.4.5:8123'; do
    render HOME_ASSISTANT_HOSTNAME=ha.example.com HOME_ASSISTANT_UPSTREAM="${bad}"
    assert_refused
    [[ "${output}" == *"HOME_ASSISTANT_UPSTREAM"* ]]
  done
}

@test "good values are accepted: IPv4, a hostname, a deeper subdomain" {
  local up
  for up in 10.0.0.5:8123 homeassistant:8123 ha-box.lan:443 192.168.1.20:65535; do
    rm -rf "${OUT}"
    render HOME_ASSISTANT_HOSTNAME=home.lab.example.com HOME_ASSISTANT_UPSTREAM="${up}"
    [ "${status}" -eq 0 ]
    grep -qxF $'\t\t\treverse_proxy '"${up}"' {' "${OUT}/Caddyfile"
  done
}

@test "a .local upstream renders, with a warning about slow lookups" {
  render HOME_ASSISTANT_HOSTNAME=ha.example.com HOME_ASSISTANT_UPSTREAM=homeassistant.local:8123
  [ "${status}" -eq 0 ]
  [[ "${output}" == *".local name"* ]]
  grep -qxF $'\t\t\treverse_proxy homeassistant.local:8123 {' "${OUT}/Caddyfile"
}
