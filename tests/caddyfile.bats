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

@test "tunnel site: imports site_routes" {
  tunnel_site | without_comments | grep -qE '^[[:space:]]*import site_routes$'
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

@test "site_routes: holds the access log, so the tunnel site logs too" {
  site_routes | without_comments | grep -qE '^[[:space:]]*log \{$'
  run grep -qE '^[[:space:]]*log \{$' <<<"$(top_block '(common_config)' | without_comments)"
  [ "${status}" -ne 0 ]
}

@test "site_routes: imported by common_config and by the tunnel site only" {
  [ "$(without_comments <"${CADDYFILE}" | grep -cE '^[[:space:]]*import site_routes$')" -eq 2 ]
  top_block '(common_config)' | without_comments | grep -qE '^[[:space:]]*import site_routes$'
}

@test "common_config: still holds the LAN-only /media handler" {
  top_block '(common_config)' | grep -qF 'handle_path /media/* {'
}
