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
CADDYFILE="${REPO_DIR}/app-setup/templates/Caddyfile"

# Print the body of the @external_auth_required matcher block.
auth_matcher_block() {
  awk '/^\t@external_auth_required \{$/{flag=1; next} flag && /^\t\}$/{flag=0} flag{print}' "${CADDYFILE}"
}

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
  [ "$(grep -c 'import common_config' "${CADDYFILE}")" -eq 2 ]
}

@test "transmission proxy: targets IPv4 loopback, matching the 127.0.0.1-only publish" {
  grep -qF 'reverse_proxy /transmission/* 127.0.0.1:9091 {' "${CADDYFILE}"
}
