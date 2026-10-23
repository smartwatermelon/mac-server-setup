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
# is exactly "$1 {". Top-level blocks start in column 0 and close with "}".
top_block() {
  awk -v open="$1 {" '$0 == open {flag=1; next} flag && /^\}$/ {flag=0} flag {print}' "${CADDYFILE}"
}

# Comment lines removed (stdin to stdout), so a comment that names /media or
# common_config does not count.
without_comments() { grep -v '^[[:space:]]*#' || true; }

tunnel_site() { top_block 'http://:8080'; }
site_routes() { top_block '(site_routes)'; }

@test "auth matcher: the @external_auth_required block exists" {
  [ -n "$(auth_matcher_block)" ]
}

@test "auth matcher: is keyed on source IP, never on host" {
  run grep -E '^[[:space:]]*host[[:space:]]' <<<"$(auth_matcher_block)"
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
  [ "$(without_comments <"${CADDYFILE}" | grep -cE '^[[:space:]]*import common_config$')" -eq 2 ]
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
  [ -n "$(tunnel_site)" ]
}

@test "tunnel site: binds to 127.0.0.1 only" {
  local binds
  binds=$(tunnel_site | without_comments | grep -E '^[[:space:]]*bind[[:space:]]' || true)
  [ "${binds}" = "$(printf '\tbind 127.0.0.1')" ]
}

@test "tunnel site: does not import common_config" {
  run grep -E 'import[[:space:]]+common_config' <<<"$(tunnel_site | without_comments)"
  [ "${status}" -ne 0 ]
}

@test "tunnel site: imports site_routes only inside the allowed-email handle" {
  local handle_body
  handle_body=$(tunnel_site | awk '/^\thandle @access_user \{$/{f=1; next} f && /^\t\}$/{f=0} f')
  [ "$(printf '%s\n' "${handle_body}" | without_comments | sed '/^[[:space:]]*$/d')" = "$(printf '\t\timport site_routes')" ]
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
  body=$(tunnel_site | awk '/^\thandle \{$/{f=1; next} f && /^\t\}$/{f=0} f' | without_comments)
  [ "${body}" = "$(printf '\t\trespond 403')" ]
}

@test "tunnel site: has no /media handler" {
  run grep -F '/media' <<<"$(tunnel_site | without_comments)"
  [ "${status}" -ne 0 ]
}

@test "tunnel site: does not key anything on remote_ip" {
  run grep -F 'remote_ip' <<<"$(tunnel_site | without_comments)"
  [ "${status}" -ne 0 ]
}

@test "site_routes: has no /media handler and no remote_ip matcher" {
  local body
  body=$(site_routes | without_comments)
  [ -n "${body}" ]
  run grep -E '/media|remote_ip' <<<"${body}"
  [ "${status}" -ne 0 ]
}

@test "access_log: holds the log, imported by common_config and the tunnel site" {
  top_block '(access_log)' | without_comments | grep -qE '^[[:space:]]*log \{$'
  run grep -qE '^[[:space:]]*log \{$' <<<"$(site_routes | without_comments)"
  [ "${status}" -ne 0 ]
  top_block '(common_config)' | without_comments | grep -qE '^[[:space:]]*import access_log$'
  tunnel_site | without_comments | grep -qE '^[[:space:]]*import access_log$'
}

# Behaviour, not text: run the tunnel site on a scratch Caddy and probe it.
# Skipped where caddy is not installed. The upstream is a dead port, so a
# request that reaches the Transmission proxy shows as 502.
@test "tunnel site (live caddy): 403 without the allowed email, routes with it" {
  command -v caddy >/dev/null || skip "caddy not installed"
  local dir port pid code
  dir=$(mktemp -d)
  port=$((20000 + RANDOM % 20000))
  mkdir -p "${dir}/www" && echo landing >"${dir}/www/index.html"
  {
    printf '{\n\tadmin off\n}\n'
    top_block '(site_routes)' | sed '1s/^/(site_routes) {\n/;$s/$/\n}/'
    top_block '(access_log)' | sed '1s/^/(access_log) {\n/;$s/$/\n}/'
    top_block 'http://:8080' | sed "1s/^/http:\/\/:${port} {\n/;\$s/\$/\n}/"
  } | sed -e "s|__ACCESS_ALLOWED_EMAIL__|allowed@example.com|" \
    -e "s|__QUICKCONNECT_[A-Z]*__|https://qc.example/|" \
    -e "s|127.0.0.1:9091|127.0.0.1:9|" \
    -e "s|/usr/local/var/log/caddy/|${dir}/|" \
    -e "s|/usr/local/var/www|${dir}/www|" >"${dir}/Caddyfile"
  caddy run --config "${dir}/Caddyfile" --adapter caddyfile >"${dir}/caddy.out" 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:${port}/" && break
    sleep 0.3
  done
  probe() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
  local ok=(-H 'Cf-Access-Authenticated-User-Email: allowed@example.com')
  local bad=(-H 'Cf-Access-Authenticated-User-Email: other@example.com')
  local results=""
  for path in / /transmission /transmission/web/ /romano /media/; do
    results+="${path} none=$(probe "http://127.0.0.1:${port}${path}")"
    results+=" bad=$(probe "${bad[@]}" "http://127.0.0.1:${port}${path}")"
    results+=" ok=$(probe "${ok[@]}" "http://127.0.0.1:${port}${path}")"$'\n'
  done
  kill "${pid}"
  wait "${pid}" 2>/dev/null || true
  rm -rf "${dir}"
  echo "${results}"
  code=$(printf '%s' "${results}")
  [ "${code}" = "$(printf '%s\n' \
    '/ none=403 bad=403 ok=200' \
    '/transmission none=403 bad=403 ok=301' \
    '/transmission/web/ none=403 bad=403 ok=502' \
    '/romano none=403 bad=403 ok=302' \
    '/media/ none=403 bad=403 ok=404')" ]
}

@test "site_routes: imported by common_config and by the tunnel site only" {
  [ "$(without_comments <"${CADDYFILE}" | grep -cE '^[[:space:]]*import site_routes$')" -eq 2 ]
  top_block '(common_config)' | without_comments | grep -qE '^[[:space:]]*import site_routes$'
}

@test "common_config: still holds the LAN-only /media handler" {
  top_block '(common_config)' | grep -qF 'handle_path /media/* {'
}
