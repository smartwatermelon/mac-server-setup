#!/usr/bin/env bats
#
# Tests for app-setup/templates/Caddyfile access control.
#
# The WAN port forward reaches the same :443 listener as the internal site,
# and the client chooses the site with Host/SNI. Auth must therefore depend
# on source IP alone: a host-keyed matcher let an external client send the
# internal hostname and reach /transmission/ with no password (2026-10-22).
#
# Run with: bats tests/caddyfile.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
# CADDYFILE may be overridden to run these tests against a known-bad file.
CADDYFILE="${CADDYFILE:-${REPO_DIR}/app-setup/templates/Caddyfile}"

# Print the body of the @external_auth_required matcher block.
auth_matcher_block() {
  awk '/^\t@external_auth_required \{$/{flag=1; next} flag && /^\t\}$/{flag=0} flag{print}' "${CADDYFILE}"
}

# Print the body of a top-level block (snippet or site) whose opening line
# is exactly "$1 {", from file $2 (default CADDYFILE). Top-level blocks start
# in column 0 and close with "}".
top_block() {
  awk -v open="$1 {" '$0 == open {flag=1; next} flag && /^\}$/ {flag=0} flag {print}' "${2:-${CADDYFILE}}"
}

# Comment lines removed (stdin to stdout), so a comment that names /media or
# common_config does not count.
without_comments() { grep -v '^[[:space:]]*#' || true; }

tunnel_site() { top_block 'http://:8080'; }

# render_caddyfile OUT_DIR [KEY=value ...]: render the template to
# OUT_DIR/Caddyfile with caddy-setup.sh's own code, only these keys set.
render_caddyfile() {
  local out="$1"
  shift
  mkdir -p "${out}"
  {
    awk '/^# BEGIN home links$/{f=1} f{print} /^# END home links$/{exit}' "${REPO_DIR}/app-setup/caddy-setup.sh"
    cat <<'RUN'
EXTERNAL_HOSTNAME="example.com"
resolve_home_links || exit 1
resolve_home_assistant || exit 1
substitute_template "$1" "$2"
RUN
  } >"${out}/render.sh"
  env -i PATH="${PATH}" ACCESS_ALLOWED_EMAIL=allowed@example.com "$@" \
    /bin/bash "${out}/render.sh" "${CADDYFILE}" "${out}/Caddyfile"
}
site_routes() { top_block '(site_routes)'; }

@test "auth matcher: the @external_auth_required block exists" {
  [ -n "$(auth_matcher_block || true)" ]
}

@test "auth matcher: is keyed on source IP, never on host" {
  run grep -E '^[[:space:]]*host[[:space:]]' <<<"$(auth_matcher_block || true)"
  [ "${status}" -ne 0 ]
}

@test "auth matcher: excludes every LAN and loopback range" {
  local block
  block=$(auth_matcher_block)
  for range in 10.0.15.0/24 127.0.0.1/8 ::1/128 fe80::/10 fd00::/8; do
    grep -qF "not remote_ip ${range}" <<<"${block}"
  done
}

@test "basic_auth: applies through the shared snippet, so both sites get it" {
  grep -qE '^[[:space:]]*basic_auth @external_auth_required \{$' "${CADDYFILE}"
  [ "$(without_comments <"${CADDYFILE}" | grep -cE '^[[:space:]]*import common_config$' || true)" -eq 2 ]
}

@test "transmission proxy: targets IPv4 loopback, matching the 127.0.0.1-only publish" {
  grep -qF 'reverse_proxy /transmission/* 127.0.0.1:9091 {' "${CADDYFILE}"
}

# ---------------------------------------------------------------------------
# Cloudflare Tunnel site (G2, issue #209). cloudflared connects from
# loopback, so anything keyed on remote_ip treats every tunnel request as
# LAN. See "Caddy trap to avoid" in
# docs/plans/2026-10-22-g2-tunnel-access-implementation.md.
# ---------------------------------------------------------------------------

@test "tunnel site: the http://:8080 block exists" {
  [ -n "$(tunnel_site || true)" ]
}

@test "tunnel site: binds to 127.0.0.1 only" {
  local binds
  binds=$(tunnel_site | without_comments | grep -E '^[[:space:]]*bind[[:space:]]' || true)
  [ "${binds}" = "$(printf '\tbind 127.0.0.1')" ]
}

@test "tunnel site: does not import common_config" {
  run grep -E 'import[[:space:]]+common_config' <<<"$(tunnel_site | without_comments || true)"
  [ "${status}" -ne 0 ]
}

# The body of handle @access_user in the tunnel site of file $1, comments
# and blank lines removed.
access_user_body() {
  { top_block 'http://:8080' "$1" || true; } \
    | awk '/^\thandle @access_user \{$/{f=1; next} f && /^\t\}$/{f=0} f' \
    | without_comments | sed '/^[[:space:]]*$/d' || true
}

@test "tunnel site: imports site_routes only inside the allowed-email handle" {
  LIVE_DIR=$(mktemp -d)
  render_caddyfile "${LIVE_DIR}"
  [ "$(access_user_body "${LIVE_DIR}/Caddyfile" || true)" = "$(printf '\t\timport site_routes' || true)" ]
}

# With HOME_ASSISTANT_* set, the handle holds two mutually exclusive handles:
# the HA host goes only to HA, every other host only to site_routes.
@test "tunnel site: with Home Assistant on, the HA host and site_routes are exclusive handles" {
  LIVE_DIR=$(mktemp -d)
  render_caddyfile "${LIVE_DIR}" HOME_ASSISTANT_HOSTNAME=ha.example.com HOME_ASSISTANT_UPSTREAM=192.168.1.20:8123
  local want
  want=$(printf '%s\n' \
    $'\t\t@home_assistant host ha.example.com' \
    $'\t\thandle @home_assistant {' \
    $'\t\t\treverse_proxy 192.168.1.20:8123 {' \
    $'\t\t\t\theader_up X-Forwarded-For {http.request.header.Cf-Connecting-IP}' \
    $'\t\t\t\theader_up X-Forwarded-Proto https' \
    $'\t\t\t\theader_up -Cf-Access-Jwt-Assertion' \
    $'\t\t\t\theader_up Cookie "(^|;\\s*)CF_Authorization=[^;]*" ""' \
    $'\t\t\t\theader_up Cookie "^;\\s*" ""' \
    $'\t\t\t}' \
    $'\t\t}' \
    $'\t\thandle {' \
    $'\t\timport site_routes' \
    $'\t\t}')
  [ "$(access_user_body "${LIVE_DIR}/Caddyfile" || true)" = "${want}" ]
}

@test "tunnel site: @access_user is an exact match on the allowed email header" {
  local matchers
  matchers=$(tunnel_site | without_comments | grep -E '@access_user[[:space:]]+header' || true)
  [ "${matchers}" = "$(printf '\t@access_user header Cf-Access-Authenticated-User-Email __ACCESS_ALLOWED_EMAIL__')" ]
}

# Any directive at site level would run outside the email check: Caddy sorts
# redir and reverse_proxy ahead of handle. Only these lines may be there.
@test "tunnel site: site level holds only bind, the log, the matcher and two handles" {
  local top
  top=$(tunnel_site | without_comments | grep -E $'^\t[^\t]' || true)
  [ "${top}" = "$(printf '\tbind 127.0.0.1\n\timport access_log\n\t@access_user header Cf-Access-Authenticated-User-Email __ACCESS_ALLOWED_EMAIL__\n\thandle @access_user {\n\t}\n\thandle {\n\t}')" ]
}

@test "tunnel site: the catch-all handle responds 403" {
  local body
  body=$({ tunnel_site || true; } | { awk '/^\thandle \{$/{f=1; next} f && /^\t\}$/{f=0} f' || true; } | without_comments)
  [ "${body}" = "$(printf '\t\trespond 403')" ]
}

@test "tunnel site: has no /media handler" {
  run grep -F '/media' <<<"$(tunnel_site | without_comments || true)"
  [ "${status}" -ne 0 ]
}

@test "tunnel site: does not key anything on remote_ip" {
  run grep -F 'remote_ip' <<<"$(tunnel_site | without_comments || true)"
  [ "${status}" -ne 0 ]
}

@test "site_routes: has no /media handler and no remote_ip matcher" {
  local body
  body=$({ site_routes || true; } | without_comments)
  [ -n "${body}" ]
  run grep -E '/media|remote_ip' <<<"${body}"
  [ "${status}" -ne 0 ]
}

@test "access_log: holds the log, imported by common_config and the tunnel site" {
  { top_block '(access_log)' || true; } | { without_comments || true; } | grep -qE '^[[:space:]]*log \{$'
  run grep -qE '^[[:space:]]*log \{$' <<<"$(site_routes | without_comments || true)"
  [ "${status}" -ne 0 ]
  { top_block '(common_config)' || true; } | { without_comments || true; } | grep -qE '^[[:space:]]*import access_log$'
  { tunnel_site || true; } | { without_comments || true; } | grep -qE '^[[:space:]]*import access_log$'
}

# Behaviour, not text: run the tunnel site on a scratch Caddy and probe it.
# Skipped where caddy is not installed. The upstream is a dead port, so a
# request that reaches the Transmission proxy shows as 502.
LIVE_PID=""
LIVE_DIR=""
STUB_PID=""
teardown() {
  local pid
  for pid in "${LIVE_PID}" "${STUB_PID}"; do
    if [[ -n "${pid}" ]]; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  if [[ -n "${LIVE_DIR}" ]]; then
    rm -rf "${LIVE_DIR}"
  fi
}

@test "tunnel site (live caddy): 403 without the allowed email, routes with it" {
  command -v caddy >/dev/null || skip "caddy not installed"
  local dir port code
  dir=$(mktemp -d)
  LIVE_DIR="${dir}"
  port=$((20000 + RANDOM % 20000))
  mkdir -p "${dir}/www" && echo landing >"${dir}/www/index.html"
  # Render with caddy-setup.sh's own code: dashboard link 1 on, link 2 off.
  {
    awk '/^# BEGIN home links$/{f=1} f{print} /^# END home links$/{exit}' "${REPO_DIR}/app-setup/caddy-setup.sh"
    cat <<'RUN'
resolve_home_links || exit 1
resolve_home_assistant || exit 1
substitute_template "$1" "$2"
RUN
  } >"${dir}/render.sh"
  env -i PATH="${PATH}" ACCESS_ALLOWED_EMAIL=allowed@example.com \
    HOME_LINK1_NAME=Files HOME_LINK1_PATH=files HOME_LINK1_URL=https://qc.example/ \
    /bin/bash "${dir}/render.sh" "${CADDYFILE}" "${dir}/rendered"
  local rendered="${dir}/rendered"
  {
    printf '{\n\tadmin off\n}\n'
    { top_block '(site_routes)' "${rendered}" || true; } | sed '1s/^/(site_routes) {\n/;$s/$/\n}/' || true
    { top_block '(access_log)' "${rendered}" || true; } | sed '1s/^/(access_log) {\n/;$s/$/\n}/' || true
    { top_block 'http://:8080' "${rendered}" || true; } | sed "1s/^/http:\/\/:${port} {\n/;\$s/\$/\n}/" || true
  } | sed -e "s|127.0.0.1:9091|127.0.0.1:9|" \
    -e "s|/usr/local/var/log/caddy/|${dir}/|" \
    -e "s|/usr/local/var/www|${dir}/www|" >"${dir}/Caddyfile"
  caddy run --config "${dir}/Caddyfile" --adapter caddyfile >"${dir}/caddy.out" 2>&1 &
  LIVE_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:${port}/" && break
    sleep 0.3
  done
  probe() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
  local ok=(-H 'Cf-Access-Authenticated-User-Email: allowed@example.com')
  local bad=(-H 'Cf-Access-Authenticated-User-Email: other@example.com')
  local results=""
  for path in / /transmission /transmission/web/ /files /files/ /other /media/; do
    results+="${path} none=$(probe "http://127.0.0.1:${port}${path}")"
    results+=" bad=$(probe "${bad[@]}" "http://127.0.0.1:${port}${path}")"
    results+=" ok=$(probe "${ok[@]}" "http://127.0.0.1:${port}${path}")"$'\n'
  done
  echo "${results}"
  code=$(printf '%s' "${results}")
  [ "${code}" = "$(printf '%s\n' \
    '/ none=403 bad=403 ok=200' \
    '/transmission none=403 bad=403 ok=301' \
    '/transmission/web/ none=403 bad=403 ok=502' \
    '/files none=403 bad=403 ok=302' \
    '/files/ none=403 bad=403 ok=302' \
    '/other none=403 bad=403 ok=404' \
    '/media/ none=403 bad=403 ok=404')" ]
}

# Home Assistant on: a stub HA upstream (tests/fixtures/home-assistant/)
# records what reaches it. Skipped where caddy or python3 is missing, so it
# does not run in CI (bats.yml installs no caddy).
@test "tunnel site (live caddy): the Home Assistant host reaches only HA, behind the email check" {
  command -v caddy >/dev/null || skip "caddy not installed"
  command -v python3 >/dev/null || skip "python3 not installed"
  local dir port ha_port
  dir=$(mktemp -d)
  LIVE_DIR="${dir}"
  port=$((20000 + RANDOM % 20000))
  ha_port=$((port + 1))
  mkdir -p "${dir}/www" && echo landing >"${dir}/www/index.html"
  : >"${dir}/ha.log"
  python3 "${REPO_DIR}/tests/fixtures/home-assistant/upstream-stub.py" "${ha_port}" "${dir}/ha.log" &
  STUB_PID=$!
  render_caddyfile "${dir}" HOME_LINK1_NAME=Files HOME_LINK1_PATH=files HOME_LINK1_URL=https://qc.example/ \
    HOME_ASSISTANT_HOSTNAME=ha.example.com HOME_ASSISTANT_UPSTREAM="127.0.0.1:${ha_port}"
  local rendered="${dir}/Caddyfile"
  {
    printf '{\n\tadmin off\n}\n'
    { top_block '(site_routes)' "${rendered}" || true; } | sed '1s/^/(site_routes) {\n/;$s/$/\n}/' || true
    { top_block '(access_log)' "${rendered}" || true; } | sed '1s/^/(access_log) {\n/;$s/$/\n}/' || true
    { top_block 'http://:8080' "${rendered}" || true; } | sed "1s/^/http:\/\/:${port} {\n/;\$s/\$/\n}/" || true
  } | sed -e "s|127.0.0.1:9091|127.0.0.1:9|" \
    -e "s|/usr/local/var/log/caddy/|${dir}/|" \
    -e "s|/usr/local/var/www|${dir}/www|" >"${dir}/live.Caddyfile"
  grep -qF "reverse_proxy 127.0.0.1:${ha_port} {" "${dir}/live.Caddyfile"
  caddy run --config "${dir}/live.Caddyfile" --adapter caddyfile >"${dir}/caddy.out" 2>&1 &
  LIVE_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:${port}/" && break
    sleep 0.3
  done
  local base="http://127.0.0.1:${port}"
  local ha=(-H 'Host: ha.example.com') main=(-H 'Host: example.com')
  local ok=(-H 'Cf-Access-Authenticated-User-Email: allowed@example.com')
  local bad=(-H 'Cf-Access-Authenticated-User-Email: other@example.com')
  probe() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
  body() { curl -s "$@"; }

  # (a) The HA host without the allowed email: 403, and HA sees nothing.
  [ "$(probe "${ha[@]}" "${base}/" || true)" = "403" ]
  [ "$(probe "${ha[@]}" "${bad[@]}" "${base}/" || true)" = "403" ]
  [ "$(probe "${ha[@]}" "${bad[@]}" "${base}/transmission/" || true)" = "403" ]
  [ ! -s "${dir}/ha.log" ]

  # (b) With it: HA answers, and sees the visitor IP from Cf-Connecting-IP,
  # https, the original Host, and no Access token.
  [ "$(body "${ha[@]}" "${ok[@]}" -H 'Cf-Connecting-IP: 203.0.113.7' \
    -H 'X-Forwarded-For: 198.51.100.9' -H 'Cf-Access-Jwt-Assertion: secret-jwt' \
    -H 'Cookie: CF_Authorization=secret-cookie; keep=1' "${base}/" || true)" = "ha-upstream" ]
  local rec
  rec=$(tail -n 1 "${dir}/ha.log")
  echo "${rec}"
  [ "$(jq -r '."X-Forwarded-For"' <<<"${rec}" || true)" = "203.0.113.7" ]
  [ "$(jq -r '."X-Forwarded-Proto"' <<<"${rec}" || true)" = "https" ]
  [ "$(jq -r '.Host' <<<"${rec}" || true)" = "ha.example.com" ]
  [ "$(jq -r '."Cf-Access-Jwt-Assertion"' <<<"${rec}" || true)" = "null" ]
  [ "$(jq -r '.Cookie' <<<"${rec}" || true)" = "keep=1" ]
  local cookie
  for cookie in 'keep=1; CF_Authorization=secret-c2' 'a=1; CF_Authorization=secret-c3; b=2' 'CF_Authorization=secret-c4'; do
    body "${ha[@]}" "${ok[@]}" -H "Cookie: ${cookie}" "${base}/" >/dev/null
    jq -r '.Cookie' <<<"$(tail -n 1 "${dir}/ha.log" || true)" >>"${dir}/cookies"
  done
  [ "$(cat "${dir}/cookies" || true)" = "$(printf '%s\n' 'keep=1' 'a=1; b=2' '' || true)" ]
  run grep -F 'secret-' "${dir}/ha.log"
  [ "${status}" -ne 0 ]

  # (c) Every path on the HA host goes to HA: no Transmission, no landing
  # page, no dashboard-link redirect.
  local path
  for path in /transmission/ /transmission /files /media/ /index.html; do
    [ "$(body "${ha[@]}" "${ok[@]}" "${base}${path}" || true)" = "ha-upstream" ]
    [ "$(jq -r '.path' <<<"$(tail -n 1 "${dir}/ha.log" || true)" || true)" = "${path}" ]
  done

  # (d) The main host never reaches HA.
  local before
  before=$(wc -l <"${dir}/ha.log")
  [ "$(body "${main[@]}" "${ok[@]}" "${base}/" || true)" = "landing" ]
  [ "$(probe "${main[@]}" "${ok[@]}" "${base}/transmission/web/" || true)" = "502" ]
  [ "$(probe "${main[@]}" "${ok[@]}" "${base}/files" || true)" = "302" ]
  [ "$(probe "${main[@]}" "${ok[@]}" "${base}/other" || true)" = "404" ]
  [ "$(probe "${main[@]}" "${base}/" || true)" = "403" ]
  [ "$(wc -l <"${dir}/ha.log" || true)" -eq "${before}" ]

  # (g) A websocket upgrade passes through (101). The stub holds the
  # connection open, so curl ends on --max-time.
  local ws
  ws=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 2 "${ha[@]}" "${ok[@]}" \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${base}/api/websocket" || true)
  [ "${ws}" = "101" ]
  [ "$(jq -r '.Upgrade' <<<"$(tail -n 1 "${dir}/ha.log" || true)" || true)" = "websocket" ]
}

@test "site_routes: imported by common_config and by the tunnel site only" {
  [ "$(without_comments <"${CADDYFILE}" | grep -cE '^[[:space:]]*import site_routes$' || true)" -eq 2 ]
  { top_block '(common_config)' || true; } | { without_comments || true; } | grep -qE '^[[:space:]]*import site_routes$'
}

@test "common_config: still holds the LAN-only /media handler" {
  { top_block '(common_config)' || true; } | grep -qF 'handle_path /media/* {'
}
