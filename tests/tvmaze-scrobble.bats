#!/usr/bin/env bats
#
# Tests for the Plex → TVmaze watched sync (issue #167):
#   app-setup/templates/tvmaze-scrobble.sh            (worker)
#   app-setup/templates/tvmaze-scrobble-listener.py   (webhook listener)
#   app-setup/tvmaze-scrobble-setup.sh                (placeholders only)
#
# Fully stubbed: curl is a mock that serves fixtures from
# tests/fixtures/tvmaze-scrobble/ by method and URL, and records its argv
# and stdin. alert_send is a stub library that writes to a mail log. No
# network, no email.
#
# Run with: bats tests/tvmaze-scrobble.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
TEMPLATE_DIR="${REPO_DIR}/app-setup/templates"
FIXTURES="${REPO_DIR}/tests/fixtures/tvmaze-scrobble"
SETUP_SCRIPT="${REPO_DIR}/app-setup/tvmaze-scrobble-setup.sh"
SECRET="SeCrEtKeY0123456789"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  export HOME="${TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.config/tvmaze-scrobble" "${HOME}/.config/plex-watchdog" \
    "${HOME}/.local/state" "${HOME}/.local/lib"
  printf 'testuser:%s\n' "${SECRET}" >"${HOME}/.config/tvmaze-scrobble/credentials"
  echo "plex-token-xyz" >"${HOME}/.config/plex-watchdog/token"

  export MAIL_LOG="${TEST_TMPDIR}/mail.log"
  : >"${MAIL_LOG}"
  cat >"${HOME}/.local/lib/alert-lib.sh" <<'LIB'
alert_send() {
  { echo "=== MAIL ==="; echo "Subject: $1"; echo "$2"; } >>"${MAIL_LOG}"
}
LIB

  export ROUTES="${TEST_TMPDIR}/routes"
  : >"${ROUTES}"
  write_curl_mock

  export CURL_BIN="${TEST_TMPDIR}/curl"
  JQ_BIN="$(command -v jq)"
  export JQ_BIN
  export SLEEP_BIN=true
  export RECONCILE_PAUSE=0

  WORKER="${TEST_TMPDIR}/tvmaze-scrobble"
  sed \
    -e 's|__HOSTNAME__|TESTHOST|g' \
    -e 's|__MONITORING_EMAIL__|ops@example.com|g' \
    -e 's|__PLEX_ACCOUNT_TITLE__|Andrew Rich|g' \
    -e 's|__PLEX_ACCOUNT_ID__|1|g' \
    "${TEMPLATE_DIR}/tvmaze-scrobble.sh" >"${WORKER}"

  STATE="${HOME}/.local/state/tvmaze-scrobble"
  LOG="${HOME}/.local/state/tvmaze-scrobble.log"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# route METHOD URL_SUBSTRING HTTP_CODE FIXTURE: the first matching route
# answers. HTTP_CODE "fail" makes curl exit 7 (no connection).
route() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"${ROUTES}"
}

# A bare `! grep` mid-test does not fail a bats test; a function's status does.
not_grep() {
  ! grep "$@"
}

write_curl_mock() {
  cat >"${TEST_TMPDIR}/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_TMPDIR}/curl_argv"
{ echo "--- stdin ---"; cat; } >>"${TEST_TMPDIR}/curl_stdin"
method=GET url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
while IFS=$'\t' read -r m sub code fixture; do
  [[ "${m}" == "${method}" ]] || continue
  [[ "${url}" == *"${sub}"* ]] || continue
  [[ "${code}" == "fail" ]] && exit 7
  if [[ -n "${fixture}" ]]; then cat "${fixture}"; fi
  printf '\n%s' "${code}"
  exit 0
done <"${ROUTES}"
echo "curl mock: no route for ${method} ${url}" >>"${TEST_TMPDIR}/curl_unrouted"
printf '\n404'
MOCK
  chmod +x "${TEST_TMPDIR}/curl"
}

# /bin/bash, as launchd runs it: on macOS that is bash 3.2.
run_webhook() {
  /bin/bash "${WORKER}" <"$1"
}

curl_calls() {
  cat "${TEST_TMPDIR}/curl_argv" 2>/dev/null || true
}

mail_count() {
  grep -c '^=== MAIL ===$' "${MAIL_LOG}" || true
}

scrobble_calls() {
  grep -c 'scrobble/shows' "${TEST_TMPDIR}/curl_argv" 2>/dev/null || true
}

# synced_list: the synced state as one sorted, space-separated line.
synced_list() {
  sort -o "${TEST_TMPDIR}/synced.sorted" "${STATE}/synced"
  tr '\n' ' ' <"${TEST_TMPDIR}/synced.sorted"
}

# history_fixture: plex-history.json with viewedAt values relative to now.
history_fixture() {
  local now out="${TEST_TMPDIR}/history.json"
  now=$(date +%s)
  sed \
    -e "s|\"RECENT_1\"|$((now - 3 * 86400))|" \
    -e "s|\"RECENT_2\"|$((now - 2 * 86400))|g" \
    -e "s|\"RECENT_3\"|$((now - 3600))|" \
    -e "s|\"OLD\"|$((now - 30 * 86400))|" \
    "${FIXTURES}/plex-history.json" >"${out}"
  echo "${out}"
}

# ---------------------------------------------------------------------------
# Webhook mode
# ---------------------------------------------------------------------------

@test "webhook: another account's play makes no calls and exits 0" {
  run run_webhook "${FIXTURES}/payload-other-account.json"
  [ "${status}" -eq 0 ]
  [ -z "$(curl_calls || true)" ]
  [ "$(mail_count || true)" -eq 0 ]
}

@test "webhook: a non-episode or non-JSON payload is ignored" {
  local movie="${TEST_TMPDIR}/movie.json"
  jq '.Metadata.type = "movie"' "${FIXTURES}/payload-scrobble.json" >"${movie}"
  run run_webhook "${movie}"
  [ "${status}" -eq 0 ]
  echo 'not json' >"${TEST_TMPDIR}/bad"
  run run_webhook "${TEST_TMPDIR}/bad"
  [ "${status}" -eq 1 ]
  [ -z "$(curl_calls || true)" ]
}

@test "webhook: TVDB id matches, one scrobble with thetvdb_id, no alert" {
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 0 ]
  [ "$(scrobble_calls || true)" -eq 1 ]
  grep -q 'scrobble/shows?thetvdb_id=298905' "${TEST_TMPDIR}/curl_argv"
  grep -q '"season":16,"episode":10,"type":0,"marked_at":1793000000' "${TEST_TMPDIR}/curl_argv"
  grep -q 'SYNCED: Taskmaster S16E10 via thetvdb_id=298905, TVmaze episode 2981234' "${LOG}"
  grep -qx 5001 "${STATE}/synced"
  [ "$(mail_count || true)" -eq 0 ]
}

@test "webhook: TVDB no match falls through to IMDb" {
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST thetvdb_id= 422 "${FIXTURES}/tvmaze-scrobble-nomatch.json"
  route POST imdb_id= 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 0 ]
  [ "$(scrobble_calls || true)" -eq 2 ]
  grep -q 'SYNCED: Taskmaster S16E10 via imdb_id=tt4934214' "${LOG}"
  [ "$(mail_count || true)" -eq 0 ]
}

@test "webhook: a TVmaze 404 also falls through" {
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST thetvdb_id= 404 ""
  route POST imdb_id= 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 0 ]
  grep -q 'via imdb_id=' "${LOG}"
}

@test "webhook: only a TMDB id, one exact title match, scrobble by tvmaze_id" {
  route GET /library/metadata/22096 200 "${FIXTURES}/plex-show-tmdb-only.json"
  route GET search/shows 200 "${FIXTURES}/tvmaze-search-one.json"
  route POST tvmaze_id=1520 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run run_webhook "${FIXTURES}/payload-title-fallback.json"
  [ "${status}" -eq 0 ]
  [ "$(scrobble_calls || true)" -eq 1 ]
  grep -q 'search/shows?q=The%20Great%20British%20Bake%20Off' "${TEST_TMPDIR}/curl_argv"
  grep -q 'SYNCED: The Great British Bake Off S15E03 via tvmaze_id=1520 (title)' "${LOG}"
  [ "$(mail_count || true)" -eq 0 ]
}

@test "webhook: no exact title match, alert names show and SxxEyy" {
  route GET /library/metadata/22096 200 "${FIXTURES}/plex-show-tmdb-only.json"
  route GET search/shows 200 "${FIXTURES}/tvmaze-search-none.json"
  run run_webhook "${FIXTURES}/payload-title-fallback.json"
  [ "${status}" -eq 1 ]
  [ "$(scrobble_calls || true)" -eq 0 ]
  [ "$(mail_count || true)" -eq 1 ]
  grep -q '^Subject: TVmaze sync failed: The Great British Bake Off S15E03$' "${MAIL_LOG}"
  grep -q "no TVmaze show named exactly" "${MAIL_LOG}"
  grep -qx 6001 "${STATE}/failed"
}

@test "webhook: two exact title matches, no guess, alert" {
  route GET /library/metadata/22096 200 "${FIXTURES}/plex-show-tmdb-only.json"
  route GET search/shows 200 "${FIXTURES}/tvmaze-search-two.json"
  run run_webhook "${FIXTURES}/payload-title-fallback.json"
  [ "${status}" -eq 1 ]
  [ "$(scrobble_calls || true)" -eq 0 ]
  grep -q '^Subject: TVmaze sync failed: The Great British Bake Off S15E03$' "${MAIL_LOG}"
  grep -q "2 TVmaze shows named" "${MAIL_LOG}"
}

@test "webhook: 401 alerts at once and does not fall through" {
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows 401 "${FIXTURES}/tvmaze-unauthorized.json"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 1 ]
  [ "$(scrobble_calls || true)" -eq 1 ]
  not_grep -q search/shows "${TEST_TMPDIR}/curl_argv"
  [ "$(mail_count || true)" -eq 1 ]
  grep -q '^Subject: TVmaze sync failed: Taskmaster S16E10$' "${MAIL_LOG}"
  grep -q 'rejected the credentials' "${MAIL_LOG}"
}

@test "webhook: TVmaze unreachable is an error, no fall-through, alert" {
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows fail ""
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 1 ]
  [ "$(scrobble_calls || true)" -eq 1 ]
  grep -q 'no answer from TVmaze (curl exit 7)' "${MAIL_LOG}"
}

@test "webhook: Plex lookup failure still tries the title search" {
  route GET /library/metadata/11208 fail ""
  route GET search/shows 200 "${FIXTURES}/tvmaze-search-none.json"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 1 ]
  grep -q 'Plex show lookup (key 11208) failed' "${MAIL_LOG}"
}

@test "credentials and the Plex token never appear in curl argv or the log" {
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST thetvdb_id= 422 "${FIXTURES}/tvmaze-scrobble-nomatch.json"
  route POST imdb_id= 401 "${FIXTURES}/tvmaze-unauthorized.json"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  not_grep -q "${SECRET}" "${TEST_TMPDIR}/curl_argv"
  not_grep -q plex-token-xyz "${TEST_TMPDIR}/curl_argv"
  not_grep -q "${SECRET}" "${LOG}"
  not_grep -q "${SECRET}" "${MAIL_LOG}"
  # They do reach curl, on stdin.
  grep -q "user = \"testuser:${SECRET}\"" "${TEST_TMPDIR}/curl_stdin"
  grep -q 'header = "X-Plex-Token: plex-token-xyz"' "${TEST_TMPDIR}/curl_stdin"
}

@test "webhook: missing lastViewedAt uses the current time" {
  local p="${TEST_TMPDIR}/p.json"
  jq 'del(.Metadata.lastViewedAt)' "${FIXTURES}/payload-scrobble.json" >"${p}"
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run run_webhook "${p}"
  [ "${status}" -eq 0 ]
  not_grep -q 'marked_at":1793000000' "${TEST_TMPDIR}/curl_argv"
  grep -q '"marked_at":1[0-9]\{9\}' "${TEST_TMPDIR}/curl_argv"
}

# ---------------------------------------------------------------------------
# Reconcile mode
# ---------------------------------------------------------------------------

@test "reconcile: first run seeds the window and scrobbles nothing" {
  route GET status/sessions/history 200 "$(history_fixture || true)"
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 0 ]
  [ "$(scrobble_calls || true)" -eq 0 ]
  [ -e "${STATE}/seeded" ]
  [ "$(synced_list || true)" = "7001 7002 7003 " ]
  grep -q 'first run, seeded 3 episodes' "${LOG}"
  grep -q 'accountID=1' "${TEST_TMPDIR}/curl_argv"
  [ "$(mail_count || true)" -eq 0 ]
}

@test "reconcile: a webhook sync before the first run does not block seeding" {
  mkdir -p "${STATE}"
  echo 5001 >"${STATE}/synced"
  route GET status/sessions/history 200 "$(history_fixture || true)"
  run /bin/bash "${WORKER}" --reconcile
  [ "$(scrobble_calls || true)" -eq 0 ]
  [ "$(synced_list || true)" = "5001 7001 7002 7003 " ]
}

@test "reconcile: the seed leaves an already-failed episode out, so it is retried" {
  mkdir -p "${STATE}"
  echo 7002 >"${STATE}/failed"
  route GET status/sessions/history 200 "$(history_fixture || true)"
  run /bin/bash "${WORKER}" --reconcile
  [ "$(synced_list || true)" = "7001 7003 " ]
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 0 ]
  grep -q 'SYNCED: Taskmaster S16E08' "${LOG}"
}

@test "missing jq: logs why and exits 1" {
  JQ_BIN=/nonexistent/jq run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 1 ]
  grep -q 'ERROR: jq not found' "${LOG}"
}

@test "reconcile: already-synced episodes are skipped" {
  mkdir -p "${STATE}"
  touch "${STATE}/seeded"
  printf '7001\n7002\n7003\n' >"${STATE}/synced"
  route GET status/sessions/history 200 "$(history_fixture || true)"
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 0 ]
  [ "$(scrobble_calls || true)" -eq 0 ]
  not_grep -q library/metadata "${TEST_TMPDIR}/curl_argv"
}

@test "reconcile: a missed episode is synced and recorded; others and old plays ignored" {
  mkdir -p "${STATE}"
  touch "${STATE}/seeded"
  printf '7001\n7003\n' >"${STATE}/synced"
  route GET status/sessions/history 200 "$(history_fixture || true)"
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 0 ]
  [ "$(scrobble_calls || true)" -eq 1 ]
  grep -q '"season":16,"episode":8' "${TEST_TMPDIR}/curl_argv"
  grep -q 'SYNCED: Taskmaster S16E08' "${LOG}"
  grep -qx 7002 "${STATE}/synced"
  # Not the movie, not account 2, not the 30-day-old play.
  not_grep -qx 8001 "${STATE}/synced"
  not_grep -qx 7009 "${STATE}/synced"
  not_grep -qx 6999 "${STATE}/synced"
  [ "$(mail_count || true)" -eq 0 ]
}

@test "reconcile: a failing episode emails once, then only logs" {
  mkdir -p "${STATE}"
  touch "${STATE}/seeded"
  printf '7001\n7003\n' >"${STATE}/synced"
  route GET status/sessions/history 200 "$(history_fixture || true)"
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows 422 "${FIXTURES}/tvmaze-scrobble-nomatch.json"
  route GET search/shows 200 "${FIXTURES}/tvmaze-search-none.json"
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 1 ]
  [ "$(mail_count || true)" -eq 1 ]
  grep -q '^Subject: TVmaze sync failed: Taskmaster S16E08$' "${MAIL_LOG}"
  grep -qx 7002 "${STATE}/failed"
  run /bin/bash "${WORKER}" --reconcile
  [ "$(mail_count || true)" -eq 1 ]
  grep -q 'already emailed for Plex key 7002' "${LOG}"
  not_grep -qx 7002 "${STATE}/synced"
}

@test "reconcile: an episode the webhook already emailed about is not emailed again" {
  route GET /library/metadata/22096 200 "${FIXTURES}/plex-show-tmdb-only.json"
  route GET search/shows 200 "${FIXTURES}/tvmaze-search-none.json"
  run run_webhook "${FIXTURES}/payload-title-fallback.json"
  [ "$(mail_count || true)" -eq 1 ]
  touch "${STATE}/seeded"
  local h="${TEST_TMPDIR}/h.json" now
  now=$(date +%s)
  jq --argjson t "$((now - 60))" '{MediaContainer: {Metadata: [{ratingKey: "6001", type: "episode",
    grandparentTitle: "The Great British Bake Off", grandparentKey: "/library/metadata/22096",
    parentIndex: 15, index: 3, viewedAt: $t, accountID: 1}]}}' -n >"${h}"
  route GET status/sessions/history 200 "${h}"
  run /bin/bash "${WORKER}" --reconcile
  [ "$(mail_count || true)" -eq 1 ]
}

@test "reconcile: a row with no show key keeps its fields and uses the title search" {
  mkdir -p "${STATE}"
  touch "${STATE}/seeded"
  local h="${TEST_TMPDIR}/h.json" now
  now=$(date +%s)
  jq -n --argjson t "$((now - 60))" '{MediaContainer: {Metadata: [{ratingKey: "6001", type: "episode",
    grandparentTitle: "The Great British Bake Off", parentIndex: 15, index: 3, viewedAt: $t, accountID: 1}]}}' >"${h}"
  route GET status/sessions/history 200 "${h}"
  route GET search/shows 200 "${FIXTURES}/tvmaze-search-one.json"
  route POST tvmaze_id=1520 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 0 ]
  grep -q '"season":15,"episode":3' "${TEST_TMPDIR}/curl_argv"
  grep -q 'SYNCED: The Great British Bake Off S15E03 via tvmaze_id=1520 (title)' "${LOG}"
}

@test "missing credentials: one email across runs, again after a fix and a new break" {
  rm "${HOME}/.config/tvmaze-scrobble/credentials"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 1 ]
  [ "$(mail_count || true)" -eq 1 ]
  grep -q '^Subject: \[TESTHOST\] TVmaze sync is not working$' "${MAIL_LOG}"
  touch "${STATE}/seeded"
  printf '7001\n7003\n' >"${STATE}/synced"
  route GET status/sessions/history 200 "$(history_fixture || true)"
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 1 ]
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "$(mail_count || true)" -eq 1 ]
  # Fixed: the marker clears, so a later break emails again.
  printf 'testuser:%s\n' "${SECRET}" >"${HOME}/.config/tvmaze-scrobble/credentials"
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows 200 "${FIXTURES}/tvmaze-scrobble-ok.json"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 0 ]
  not_grep -qx config:credentials "${STATE}/failed"
  rm "${HOME}/.config/tvmaze-scrobble/credentials"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "$(mail_count || true)" -eq 2 ]
}

@test "reconcile: a missing Plex token emails once" {
  rm "${HOME}/.config/plex-watchdog/token"
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 1 ]
  run /bin/bash "${WORKER}" --reconcile
  [ "$(mail_count || true)" -eq 1 ]
  grep -q 'Plex token not readable' "${MAIL_LOG}"
}

@test "webhook: a per-item 429 stops the chain instead of falling through" {
  local rl="${TEST_TMPDIR}/429.json"
  echo '[{"code":429,"message":"Too Many Requests"}]' >"${rl}"
  route GET /library/metadata/11208 200 "${FIXTURES}/plex-show-all-ids.json"
  route POST scrobble/shows 207 "${rl}"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 1 ]
  [ "$(scrobble_calls || true)" -eq 1 ]
  not_grep -q search/shows "${TEST_TMPDIR}/curl_argv"
}

@test "reconcile: Plex history unreachable logs and exits 1, no email" {
  route GET status/sessions/history fail ""
  run /bin/bash "${WORKER}" --reconcile
  [ "${status}" -eq 1 ]
  [ "$(mail_count || true)" -eq 0 ]
  [ ! -e "${STATE}/seeded" ]
  grep -q 'Plex history request failed' "${LOG}"
}

# ---------------------------------------------------------------------------
# --check and robustness
# ---------------------------------------------------------------------------

@test "--check: passes when TVmaze accepts the key" {
  route GET auth/validate 200 ""
  run /bin/bash "${WORKER}" --check
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"OK: TVmaze accepted the credentials"* ]]
  [ "$(mail_count || true)" -eq 0 ]
}

@test "--check: fails on 401 and on a missing credentials file" {
  route GET auth/validate 401 "${FIXTURES}/tvmaze-unauthorized.json"
  run /bin/bash "${WORKER}" --check
  [ "${status}" -eq 1 ]
  rm "${HOME}/.config/tvmaze-scrobble/credentials"
  run /bin/bash "${WORKER}" --check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"credentials file"* ]]
}

@test "an unknown argument exits 64" {
  run /bin/bash "${WORKER}" --bogus
  [ "${status}" -eq 64 ]
}

@test "missing alert library: exits 1 and logs why" {
  rm "${HOME}/.local/lib/alert-lib.sh"
  run run_webhook "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 1 ]
  grep -q 'ERROR: alert library not found' "${LOG}"
}

@test "TEST_RUNNER=true skips the entry point" {
  run env TEST_RUNNER=true /bin/bash "${WORKER}" --bogus
  [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Listener
# ---------------------------------------------------------------------------

# post_to_listener FIXTURE: start the listener in-process on a free port,
# POST the fixture as Plex does (multipart, field "payload"), and wait
# briefly for the stub worker.
post_to_listener() {
  local stub="${TEST_TMPDIR}/worker-stub"
  printf '#!/bin/bash\ncat >"%s/worker-stdin"\n' "${TEST_TMPDIR}" >"${stub}"
  /usr/bin/env python3 -I - "${TEMPLATE_DIR}/tvmaze-scrobble-listener.py" "${stub}" "$1" <<'PY'
import importlib.util, sys, threading, time, urllib.request, uuid
spec = importlib.util.spec_from_file_location("listener", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.Handler.worker = sys.argv[2]
server = mod.HTTPServer(("127.0.0.1", 0), mod.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
payload = open(sys.argv[3], "rb").read()
b = uuid.uuid4().hex
body = (
    "--{b}\r\nContent-Disposition: form-data; name=\"payload\"\r\n"
    "Content-Type: application/json\r\n\r\n".format(b=b).encode()
    + payload
    + "\r\n--{b}\r\nContent-Disposition: form-data; name=\"thumb\"; filename=\"t.jpg\"\r\n"
    "Content-Type: image/jpeg\r\n\r\n".format(b=b).encode()
    + b"\xff\xd8\xff\x00binary"
    + "\r\n--{b}--\r\n".format(b=b).encode()
)
req = urllib.request.Request(
    "http://127.0.0.1:{}/".format(server.server_port), data=body,
    headers={"Content-Type": "multipart/form-data; boundary=" + b})
resp = urllib.request.urlopen(req, timeout=5)
print(resp.status, resp.read().decode().strip())
time.sleep(1)
PY
}

@test "listener: media.play is answered 200 and ignored" {
  run post_to_listener "${FIXTURES}/payload-play.json"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"200 ignored"* ]]
  [ ! -e "${TEST_TMPDIR}/worker-stdin" ]
}

@test "listener: media.scrobble for an episode runs the worker with the payload" {
  run post_to_listener "${FIXTURES}/payload-scrobble.json"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"200 ok"* ]]
  [[ "${output}" == *"scrobble: Taskmaster S16E10 (account 'Andrew Rich'"* ]]
  [ "$(jq -r '.Metadata.ratingKey' "${TEST_TMPDIR}/worker-stdin" || true)" = "5001" ]
}

@test "listener: binds loopback only" {
  grep -q 'HTTPServer(("127.0.0.1", args.port)' "${TEMPLATE_DIR}/tvmaze-scrobble-listener.py"
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

@test "rendered worker has no placeholders left" {
  run grep -n '__[A-Z_]*__' "${WORKER}"
  [ "${status}" -eq 1 ]
}

@test "setup script substitutes every placeholder the templates use" {
  local tpl ph phs
  for tpl in tvmaze-scrobble.sh com.tvmaze-scrobble.plist com.tvmaze-reconcile.plist; do
    phs=$(grep -o '__[A-Z_]*__' "${TEMPLATE_DIR}/${tpl}" | sort -u || true)
    [ -n "${phs}" ]
    while IFS= read -r ph; do
      grep -qF -- "-e \"s|${ph}|" "${SETUP_SCRIPT}" || {
        echo "setup script does not substitute ${ph} (${tpl})"
        return 1
      }
    done <<<"${phs}"
  done
}

@test "the plists are valid and run the right programs" {
  local p tpl
  for tpl in com.tvmaze-scrobble.plist com.tvmaze-reconcile.plist; do
    p="${TEST_TMPDIR}/${tpl}"
    sed -e 's|__HOSTNAME_LOWER__|testhost|g' -e 's|__OPERATOR_USERNAME__|opuser|g' \
      -e 's|__TVMAZE_SCROBBLE_PORT__|32599|g' "${TEMPLATE_DIR}/${tpl}" >"${p}"
    if command -v plutil >/dev/null 2>&1; then
      plutil -lint "${p}"
    fi
    not_grep -q '__[A-Z_]*__' "${p}"
  done
  grep -q '<string>/usr/bin/python3</string>' "${TEST_TMPDIR}/com.tvmaze-scrobble.plist"
  grep -q '<string>32599</string>' "${TEST_TMPDIR}/com.tvmaze-scrobble.plist"
  grep -q '<string>--reconcile</string>' "${TEST_TMPDIR}/com.tvmaze-reconcile.plist"
  local interval
  interval=$(grep -A1 StartInterval "${TEST_TMPDIR}/com.tvmaze-reconcile.plist")
  [[ "${interval}" == *'<integer>3600</integer>'* ]]
}

@test "listener and setup script default to the same port" {
  grep -q 'TVMAZE_SCROBBLE_PORT", "32599"' "${TEMPLATE_DIR}/tvmaze-scrobble-listener.py"
  grep -q 'TVMAZE_SCROBBLE_PORT:-32599' "${SETUP_SCRIPT}"
}
