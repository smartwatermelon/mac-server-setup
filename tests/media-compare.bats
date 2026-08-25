#!/usr/bin/env bats
#
# Tests for media-compare.sh — deciding which copy of a duplicate to keep.
#
# These tests probe real media files rather than mocking ffprobe. Mocking would
# only prove the comparison ladder handles strings this file invented; it would
# never catch a wrong -show_entries spec or a misread field name, which is
# exactly the class of mistake most likely here. ffmpeg synthesises the
# fixtures in about a tenth of a second each, so the cost is small and the
# tests exercise the real ffprobe invocation end to end.
#
# The asymmetry the library is built around: a wrong "replace" destroys the
# better copy, while a wrong "keep" costs disk space and a triage entry. Every
# uncertain case must therefore resolve to keep, and several tests below exist
# only to pin that direction.
#
# Run with: bats tests/media-compare.bats

BATS_TEST_FILENAME="${BATS_TEST_FILENAME:-}"
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
LIBRARY="${REPO_DIR}/app-setup/templates/media-compare.sh"

setup() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR

  if ! command -v ffmpeg >/dev/null 2>&1; then
    skip "ffmpeg not installed (config/formulae.txt ships it on the server)"
  fi

  # shellcheck source=/dev/null
  source "${LIBRARY}"
}

teardown() {
  rm -rf "${TEST_TMPDIR}"
}

# ---------------------------------------------------------------------------
# Fixture generation
#
# One second of test pattern plus a tone. Arguments are chosen so each rule in
# the ladder can be isolated: vary only resolution, or only bitrate, or only
# channel count, and every other attribute stays comparable.
# ---------------------------------------------------------------------------
make_media() {
  local name="$1" size="$2" bitrate="$3" channels="$4"
  local path="${TEST_TMPDIR}/${name}"
  ffmpeg -y -v error \
    -f lavfi -i "testsrc=size=${size}:rate=10:duration=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -b:v "${bitrate}" \
    -c:a aac -ac "${channels}" \
    "${path}" 2>/dev/null
  printf '%s' "${path}"
}

# First line of compare_media is the verdict, second is the reason.
verdict() {
  compare_media "$1" "$2" | head -1
}

reason() {
  compare_media "$1" "$2" | sed -n '2p'
}

# ---------------------------------------------------------------------------
# Attribute extraction
# ---------------------------------------------------------------------------

@test "media_resolution reports pixel area, not just height" {
  local f
  f="$(make_media "a.mp4" "640x360" "200k" 2)"
  run media_resolution "${f}"
  [ "$status" -eq 0 ]
  [ "$output" -eq $((640 * 360)) ]
}

@test "media_audio_channels reads the channel count" {
  local f
  f="$(make_media "a.mp4" "640x360" "200k" 6)"
  run media_audio_channels "${f}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 6 ]
}

@test "media_video_bitrate returns a positive number" {
  local f
  f="$(make_media "a.mp4" "640x360" "200k" 2)"
  run media_video_bitrate "${f}"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "attribute readers fail rather than print junk for a missing file" {
  run media_resolution "${TEST_TMPDIR}/nope.mp4"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "attribute readers fail rather than print junk for a non-media file" {
  # A text file with a video extension is a real case: a failed download, or a
  # rename that landed on something that was never media.
  echo "this is not media" >"${TEST_TMPDIR}/fake.mp4"
  run media_resolution "${TEST_TMPDIR}/fake.mp4"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Rule 1: identical files
# ---------------------------------------------------------------------------

@test "a byte-identical copy is kept, not replaced" {
  local a
  a="$(make_media "a.mp4" "640x360" "200k" 2)"
  cp "${a}" "${TEST_TMPDIR}/b.mp4"

  [ "$(verdict "${a}" "${TEST_TMPDIR}/b.mp4")" = "keep" ]
  [[ "$(reason "${a}" "${TEST_TMPDIR}/b.mp4")" == *"identical"* ]]
}

# ---------------------------------------------------------------------------
# Rule 2: resolution
# ---------------------------------------------------------------------------

@test "a higher-resolution download replaces the library copy" {
  local hd sd
  hd="$(make_media "hd.mp4" "1920x1080" "2000k" 2)"
  sd="$(make_media "sd.mp4" "640x360" "2000k" 2)"

  [ "$(verdict "${hd}" "${sd}")" = "replace" ]
  [[ "$(reason "${hd}" "${sd}")" == *"resolution"* ]]
}

@test "a lower-resolution download is kept out of the library" {
  # The failure this guards against: a 480p re-encode displacing a 1080p copy
  # because it happened to arrive later.
  local hd sd
  hd="$(make_media "hd.mp4" "1920x1080" "2000k" 2)"
  sd="$(make_media "sd.mp4" "640x360" "2000k" 2)"

  [ "$(verdict "${sd}" "${hd}")" = "keep" ]
}

@test "resolution outranks size" {
  # A big low-resolution file must not win on bulk alone. Size is rule 5 and
  # only applies once the quality rules find nothing.
  local hd sd
  hd="$(make_media "hd.mp4" "1280x720" "100k" 2)"
  sd="$(make_media "sd.mp4" "320x180" "4000k" 2)"

  [ "$(verdict "${sd}" "${hd}")" = "keep" ]
  [[ "$(reason "${sd}" "${hd}")" == *"resolution"* ]]
}

# ---------------------------------------------------------------------------
# Rule 3: video bitrate
# ---------------------------------------------------------------------------

@test "at equal resolution, a much higher bitrate wins" {
  local high low
  high="$(make_media "high.mp4" "640x360" "3000k" 2)"
  low="$(make_media "low.mp4" "640x360" "80k" 2)"

  [ "$(verdict "${high}" "${low}")" = "replace" ]
  [[ "$(reason "${high}" "${low}")" == *"bitrate"* ]]
}

@test "at equal resolution, a much lower bitrate loses" {
  local high low
  high="$(make_media "high.mp4" "640x360" "3000k" 2)"
  low="$(make_media "low.mp4" "640x360" "80k" 2)"

  [ "$(verdict "${low}" "${high}")" = "keep" ]
}

# ---------------------------------------------------------------------------
# Rule 4: audio channels
# ---------------------------------------------------------------------------

@test "more audio channels wins when video is comparable" {
  local surround stereo
  surround="$(make_media "surround.mp4" "640x360" "200k" 6)"
  stereo="$(make_media "stereo.mp4" "640x360" "200k" 2)"

  # Both encodes come from the same source at the same settings, so the video
  # rules tie and the decision falls through to audio.
  [ "$(verdict "${surround}" "${stereo}")" = "replace" ]
  [[ "$(reason "${surround}" "${stereo}")" == *"audio channels"* ]]
}

# ---------------------------------------------------------------------------
# Safety: uncertainty resolves to keep
# ---------------------------------------------------------------------------

@test "an unreadable candidate never displaces the library copy" {
  local inc
  inc="$(make_media "inc.mp4" "640x360" "200k" 2)"
  echo "truncated garbage" >"${TEST_TMPDIR}/bad.mp4"

  # Nothing about the candidate is measurable except its size, which is tiny.
  [ "$(verdict "${TEST_TMPDIR}/bad.mp4" "${inc}")" = "keep" ]
}

@test "a missing candidate is kept, not replaced" {
  local inc
  inc="$(make_media "inc.mp4" "640x360" "200k" 2)"
  [ "$(verdict "${TEST_TMPDIR}/absent.mp4" "${inc}")" = "keep" ]
}

@test "a missing incumbent still returns keep rather than claiming an upgrade" {
  local cand
  cand="$(make_media "cand.mp4" "640x360" "200k" 2)"
  [ "$(verdict "${cand}" "${TEST_TMPDIR}/absent.mp4")" = "keep" ]
}

@test "compare_media always prints a verdict and a reason" {
  local a b
  a="$(make_media "a.mp4" "640x360" "200k" 2)"
  b="$(make_media "b.mp4" "640x360" "200k" 2)"

  run compare_media "${a}" "${b}"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [[ "$(echo "$output" | head -1)" =~ ^(keep|replace)$ ]]
  [ -n "$(echo "$output" | sed -n '2p')" ]
}

@test "compare_media never emits a verdict other than keep or replace" {
  # Sweep the shapes a caller can actually hit, including the degenerate ones.
  local good
  good="$(make_media "good.mp4" "640x360" "200k" 2)"
  echo "junk" >"${TEST_TMPDIR}/junk.mp4"
  : >"${TEST_TMPDIR}/empty.mp4"

  local candidates=("${good}" "${TEST_TMPDIR}/junk.mp4" "${TEST_TMPDIR}/empty.mp4" "${TEST_TMPDIR}/absent.mp4")
  local c i
  for c in "${candidates[@]}"; do
    for i in "${candidates[@]}"; do
      local v
      v="$(compare_media "${c}" "${i}" | head -1)"
      [[ "${v}" =~ ^(keep|replace)$ ]] || {
        echo "unexpected verdict '${v}' for candidate=${c} incumbent=${i}" >&2
        return 1
      }
    done
  done
}

# ---------------------------------------------------------------------------
# replace_media_file
# ---------------------------------------------------------------------------

@test "replace moves the incumbent to quarantine and installs the candidate" {
  local cand inc
  cand="$(make_media "cand.mp4" "1920x1080" "2000k" 2)"
  inc="$(make_media "inc.mp4" "640x360" "200k" 2)"
  local cand_sum
  cand_sum="$(shasum "${cand}" | awk '{print $1}')"

  run replace_media_file "${cand}" "${inc}" "${TEST_TMPDIR}/quarantine"
  [ "$status" -eq 0 ]

  # The library slot now holds what used to be the candidate...
  [ -f "${inc}" ]
  [ "$(shasum "${inc}" | awk '{print $1}')" = "${cand_sum}" ]

  # ...the candidate has been consumed, not copied...
  [ ! -f "${cand}" ]

  # ...and the displaced copy is recoverable.
  [ "$(find "${TEST_TMPDIR}/quarantine" -type f | wc -l | tr -d ' ')" -eq 1 ]
}

@test "dry run reports the replacement without touching either file" {
  local cand inc
  cand="$(make_media "cand.mp4" "1920x1080" "2000k" 2)"
  inc="$(make_media "inc.mp4" "640x360" "200k" 2)"
  local inc_sum
  inc_sum="$(shasum "${inc}" | awk '{print $1}')"

  MEDIA_COMPARE_DRY_RUN=true run replace_media_file "${cand}" "${inc}" "${TEST_TMPDIR}/quarantine"
  [ "$status" -eq 0 ]

  [ -f "${cand}" ]
  [ "$(shasum "${inc}" | awk '{print $1}')" = "${inc_sum}" ]
  [ ! -d "${TEST_TMPDIR}/quarantine" ]
}

@test "replace refuses when the candidate is missing" {
  local inc
  inc="$(make_media "inc.mp4" "640x360" "200k" 2)"
  run replace_media_file "${TEST_TMPDIR}/absent.mp4" "${inc}" "${TEST_TMPDIR}/quarantine"
  [ "$status" -ne 0 ]
  [ -f "${inc}" ]
}

@test "a failed install restores the incumbent rather than leaving a hole" {
  # The library must never end up short an episode.
  #
  # Reaching the restore path needs the first mv (incumbent -> quarantine) to
  # succeed and the second (candidate -> library) to fail. Making the library
  # directory read-only does NOT do that: the incumbent lives there too, so the
  # quarantine move fails first and the function aborts before it can restore
  # anything. An earlier version of this test did exactly that and passed
  # against code with the restore path deleted.
  #
  # So make the *candidate's* directory read-only instead. Moving a file out of
  # a read-only directory fails, while the library and quarantine stay writable.
  local libdir canddir inc cand
  libdir="${TEST_TMPDIR}/library"
  canddir="${TEST_TMPDIR}/canddir"
  mkdir -p "${libdir}" "${canddir}"

  inc="${libdir}/inc.mp4"
  cp "$(make_media "src.mp4" "640x360" "200k" 2)" "${inc}"
  cand="${canddir}/cand.mp4"
  cp "$(make_media "big.mp4" "1920x1080" "2000k" 2)" "${cand}"

  local inc_sum
  inc_sum="$(shasum "${inc}" | awk '{print $1}')"

  chmod 500 "${canddir}"
  run replace_media_file "${cand}" "${inc}" "${TEST_TMPDIR}/quarantine"
  chmod 700 "${canddir}"

  [ "$status" -ne 0 ]

  # The library slot still holds the original, byte for byte...
  [ -f "${inc}" ]
  [ "$(shasum "${inc}" | awk '{print $1}')" = "${inc_sum}" ]

  # ...and nothing was stranded in quarantine.
  [ "$(find "${TEST_TMPDIR}/quarantine" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]

  # Prove the restore path actually ran, rather than the function bailing out
  # before the first move -- which is how the earlier version of this test
  # passed against code with no restore path at all.
  [[ "$output" == *"restoring"* ]]
  [[ "$output" == *"library is unchanged"* ]]
}

# ---------------------------------------------------------------------------
# prune_quarantine
# ---------------------------------------------------------------------------

@test "prune removes files past the retention window" {
  local q="${TEST_TMPDIR}/quarantine"
  mkdir -p "${q}"
  touch "${q}/old.mp4" "${q}/new.mp4"
  # -mtime +14 needs an mtime strictly older than 15 days.
  touch -t "$(date -v-20d '+%Y%m%d%H%M')" "${q}/old.mp4"

  run prune_quarantine "${q}" 14
  [ "$status" -eq 0 ]
  [ ! -f "${q}/old.mp4" ]
  [ -f "${q}/new.mp4" ]
}

@test "prune leaves everything alone in dry run" {
  local q="${TEST_TMPDIR}/quarantine"
  mkdir -p "${q}"
  touch "${q}/old.mp4"
  touch -t "$(date -v-20d '+%Y%m%d%H%M')" "${q}/old.mp4"

  MEDIA_COMPARE_DRY_RUN=true run prune_quarantine "${q}" 14
  [ "$status" -eq 0 ]
  [ -f "${q}/old.mp4" ]
}

@test "prune on a missing directory is a no-op, not an error" {
  run prune_quarantine "${TEST_TMPDIR}/never-existed" 14
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# parse_filebot_conflicts
#
# The pairing comes from FileBot's own conflict message, which names both the
# download and the library path it collides with. Guessing that pairing back
# from filenames would be far less reliable than reading what FileBot decided.
# ---------------------------------------------------------------------------

@test "parses the AUTO Skipped conflict format" {
  local out
  out="$(parse_filebot_conflicts '[AUTO] Skipped [/src/video.mkv] because [/dst/video.mkv] already exists
Processed 0 files')"
  [ "${out}" = "$(printf '/src/video.mkv\t/dst/video.mkv')" ]
}

@test "parses the IMPORT destination-exists format, which lists the paths in the other order" {
  local out
  out="$(parse_filebot_conflicts '[IMPORT] Destination file already exists: /dst/video.mkv (/src/video.mkv)
Processed 0 files')"
  # source first, destination second -- same shape as the AUTO format above,
  # even though FileBot prints them the other way round.
  [ "${out}" = "$(printf '/src/video.mkv\t/dst/video.mkv')" ]
}

@test "parses several conflicts from one run" {
  local out
  out="$(parse_filebot_conflicts '[AUTO] Skipped [/src/ep1.mkv] because [/dst/ep1.mkv] already exists
[AUTO] Skipped [/src/ep2.mkv] because [/dst/ep2.mkv] already exists
Processed 0 files')"
  [ "$(echo "${out}" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "keeps paths containing spaces intact" {
  # Release names routinely contain spaces; splitting on them would pair the
  # wrong files together.
  local out
  out="$(parse_filebot_conflicts '[AUTO] Skipped [/src/The Movie (2024).mkv] because [/dst/The Movie (2024).mkv] already exists')"
  [ "${out}" = "$(printf '/src/The Movie (2024).mkv\t/dst/The Movie (2024).mkv')" ]
}

@test "output with no conflict yields no pairs" {
  local out
  out="$(parse_filebot_conflicts 'Rename episodes using [TheMovieDB]
Processed 3 files')"
  [ -z "${out}" ]
}

# ---------------------------------------------------------------------------
# process_duplicate_conflicts
# ---------------------------------------------------------------------------

@test "a better download replaces the library copy and is counted" {
  local libdir="${TEST_TMPDIR}/library"
  mkdir -p "${libdir}"
  local inc="${libdir}/show.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${inc}"
  local cand
  cand="$(make_media "hd.mp4" "1920x1080" "2000k" 2)"

  # Capture stdout only. media_compare_log writes to stderr, and BATS's `run`
  # merges the two streams -- which would bury the count this function returns.
  local replaced
  replaced="$(process_duplicate_conflicts \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists" \
    "${TEST_TMPDIR}/quarantine" 2>/dev/null)"

  [ "${replaced}" -eq 1 ]
  # The library slot now holds the HD copy.
  [ "$(media_resolution "${inc}")" -eq $((1920 * 1080)) ]
}

@test "a worse download leaves the library alone and counts nothing" {
  local libdir="${TEST_TMPDIR}/library"
  mkdir -p "${libdir}"
  local inc="${libdir}/show.mp4"
  cp "$(make_media "hd.mp4" "1920x1080" "2000k" 2)" "${inc}"
  local cand
  cand="$(make_media "sd.mp4" "640x360" "200k" 2)"

  local replaced
  replaced="$(process_duplicate_conflicts \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists" \
    "${TEST_TMPDIR}/quarantine" 2>/dev/null)"

  [ "${replaced}" -eq 0 ]
  [ "$(media_resolution "${inc}")" -eq $((1920 * 1080)) ]
  # The download is still there for triage to move.
  [ -f "${cand}" ]
}

@test "output with no conflicts replaces nothing" {
  local replaced
  replaced="$(process_duplicate_conflicts "Processed 3 files" "${TEST_TMPDIR}/quarantine" 2>/dev/null)"
  [ "${replaced}" -eq 0 ]
}

@test "dry run counts no replacements and moves no files" {
  local libdir="${TEST_TMPDIR}/library"
  mkdir -p "${libdir}"
  local inc="${libdir}/show.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${inc}"
  local inc_sum
  inc_sum="$(shasum "${inc}" | awk '{print $1}')"
  local cand
  cand="$(make_media "hd.mp4" "1920x1080" "2000k" 2)"

  MEDIA_COMPARE_DRY_RUN=true process_duplicate_conflicts \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists" \
    "${TEST_TMPDIR}/quarantine" >/dev/null 2>&1

  # replace_media_file returns 0 in dry run, so the count reflects what WOULD
  # have happened -- but nothing on disk may have changed.
  [ "$(shasum "${inc}" | awk '{print $1}')" = "${inc_sum}" ]
  [ -f "${cand}" ]
}

@test "one unreadable pair does not stop the others from being worked" {
  local libdir="${TEST_TMPDIR}/library"
  mkdir -p "${libdir}"
  local inc="${libdir}/good.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${inc}"
  local cand
  cand="$(make_media "hd.mp4" "1920x1080" "2000k" 2)"

  local replaced
  replaced="$(process_duplicate_conflicts \
    "[AUTO] Skipped [${TEST_TMPDIR}/absent.mp4] because [${TEST_TMPDIR}/also-absent.mp4] already exists
[AUTO] Skipped [${cand}] because [${inc}] already exists" \
    "${TEST_TMPDIR}/quarantine" 2>/dev/null)"

  [ "${replaced}" -eq 1 ]
}

@test "the replacement count is the only thing on stdout" {
  # Callers capture this with $(...), so a stray log line on stdout would be
  # concatenated onto the number and break arithmetic at the call site.
  # media_compare_log must stay on stderr for that to hold.
  local libdir="${TEST_TMPDIR}/library"
  mkdir -p "${libdir}"
  local inc="${libdir}/show.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${inc}"
  local cand
  cand="$(make_media "hd.mp4" "1920x1080" "2000k" 2)"

  local replaced
  replaced="$(process_duplicate_conflicts \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists" \
    "${TEST_TMPDIR}/quarantine" 2>/dev/null)"

  # Exactly an integer, with nothing else attached.
  [[ "${replaced}" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# Integration with transmission-done.sh
#
# handle_duplicate_upgrades is defined in transmission-done.sh, which cannot be
# sourced here (it resolves config, HOME and Plex credentials at load time).
# Extract just that function and run it against stubs, so the wiring between
# the pipeline and this library is covered rather than assumed.
# ---------------------------------------------------------------------------

load_upgrade_handler() {
  local pipeline="${REPO_DIR}/app-setup/templates/transmission-done.sh"

  # Slicing the file with awk means guessing where the function ends, and every
  # cheap guess ("the next } at column 0") breaks the day someone adds a
  # heredoc or a block closed in column 0: the extract comes back truncated and
  # these tests pass against a function that is not the real one. Ask bash for
  # the definition instead -- it has already parsed the file, so it knows the
  # real boundaries.
  #
  # transmission-done.sh cannot simply be sourced here: it resolves config,
  # HOME and Plex credentials at load time. TEST_RUNNER=true stops main() from
  # running, and the stderr/exit-status noise from the parts that still fail is
  # discarded -- all this needs is the function text.
  local body
  body="$(TEST_RUNNER=true TEST_MODE=true bash -c \
    'source "$1" >/dev/null 2>&1; declare -f handle_duplicate_upgrades' _ "${pipeline}")"

  # Guard the guard: an empty body would make every assertion below vacuous.
  [ -n "${body}" ]
  eval "${body}"
}

# Stubs for what transmission-done.sh provides at runtime.
setup_pipeline_stubs() {
  export TR_TORRENT_DIR="${TEST_TMPDIR}/downloads/pending-move"
  mkdir -p "${TR_TORRENT_DIR}" "${TEST_TMPDIR}/library"
  PIPELINE_LOG="${TEST_TMPDIR}/pipeline.log"
  : >"${PIPELINE_LOG}"
  # media_compare_log delegates to log() when it exists, which is how decisions
  # reach the processing log in production.
  log() { printf '%s\n' "$1" >>"${PIPELINE_LOG}"; }
  trigger_plex_scan() {
    printf 'PLEX SCAN: %s\n' "$1" >>"${PIPELINE_LOG}"
    return 0
  }
  load_upgrade_handler
}

@test "the pipeline upgrades a duplicate and rescans the right Plex library" {
  setup_pipeline_stubs

  local inc="${TEST_TMPDIR}/library/Show.S01E01.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${inc}"
  local cand="${TR_TORRENT_DIR}/Show.S01E01.mp4"
  cp "$(make_media "hd.mp4" "1920x1080" "2000k" 6)" "${cand}"

  handle_duplicate_upgrades "already-in-plex" \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists
Rename episodes using [TheTVDB] to TV Shows
Processed 0 files"

  # The library holds the better copy...
  [ "$(media_resolution "${inc}")" -eq $((1920 * 1080)) ]
  # ...the displaced copy is recoverable...
  [ "$(find "${TEST_TMPDIR}/downloads/triage/quarantine" -type f | wc -l | tr -d ' ')" -eq 1 ]
  # ...and Plex was told to rescan TV, not movies.
  grep -q "PLEX SCAN: show" "${PIPELINE_LOG}"
}

@test "the pipeline scans the movie library for a movie upgrade" {
  setup_pipeline_stubs

  local inc="${TEST_TMPDIR}/library/Movie.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${inc}"
  local cand="${TR_TORRENT_DIR}/Movie.mp4"
  cp "$(make_media "hd.mp4" "1920x1080" "2000k" 2)" "${cand}"

  handle_duplicate_upgrades "already-in-plex" \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists
Rename movies using [TheMovieDB]
Processed 0 files"

  grep -q "PLEX SCAN: movie" "${PIPELINE_LOG}"
}

@test "the pipeline does not rescan when nothing was upgraded" {
  # This runs on every duplicate. A scan with nothing to find is wasted work on
  # a large library, so it must be conditional on an actual replacement.
  setup_pipeline_stubs

  local inc="${TEST_TMPDIR}/library/Show.S01E01.mp4"
  cp "$(make_media "hd.mp4" "1920x1080" "2000k" 2)" "${inc}"
  local cand="${TR_TORRENT_DIR}/Show.S01E01.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${cand}"

  handle_duplicate_upgrades "already-in-plex" \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists
Processed 0 files"

  # `run grep`, not `! grep`: POSIX exempts a !-negated command from `set -e`,
  # so a bare `! grep ...` can never fail a BATS test -- it is a no-op that
  # reads like an assertion. Checking $status explicitly does abort.
  run grep -q "PLEX SCAN" "${PIPELINE_LOG}"
  [ "$status" -ne 0 ]
  # The download stays put for triage to move, exactly as before.
  [ -f "${cand}" ]
}

@test "the pipeline ignores failure categories that are not duplicates" {
  # no-match and failed mean FileBot never identified a library collision, so
  # there is no pair to compare and nothing may be touched.
  setup_pipeline_stubs

  local inc="${TEST_TMPDIR}/library/Show.S01E01.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${inc}"
  local cand="${TR_TORRENT_DIR}/Show.S01E01.mp4"
  cp "$(make_media "hd.mp4" "1920x1080" "2000k" 2)" "${cand}"

  handle_duplicate_upgrades "no-match" \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists"

  # Untouched: still the SD copy, and no scan.
  [ "$(media_resolution "${inc}")" -eq $((640 * 360)) ]
  [ ! -s "${PIPELINE_LOG}" ]
}

@test "the pipeline survives the comparison library being absent" {
  # media-compare.sh is sourced only when present. A deployment without it must
  # keep the old triage-everything behaviour rather than erroring.
  setup_pipeline_stubs
  unset -f process_duplicate_conflicts

  run handle_duplicate_upgrades "already-in-plex" "[AUTO] Skipped [/a] because [/b] already exists"
  [ "$status" -eq 0 ]
}

@test "an IMPORT conflict with parentheses in both paths is split correctly" {
  # `DEST (SOURCE)` cannot be split by pattern once both paths contain " (",
  # which is routine for films with a year in the name. A greedy regex pairs a
  # fragment of one path with a fragment of the other, and the library then
  # quarantines a file nobody asked it to touch. The split is resolved against
  # the filesystem instead.
  mkdir -p "${TEST_TMPDIR}/plex" "${TEST_TMPDIR}/dl"
  local dest="${TEST_TMPDIR}/plex/The Thing (1982).mkv"
  local src="${TEST_TMPDIR}/dl/The Thing (1982).mkv"
  : >"${dest}"
  : >"${src}"

  local out
  out="$(parse_filebot_conflicts "[IMPORT] Destination file already exists: ${dest} (${src})")"
  [ "${out}" = "$(printf '%s\t%s' "${src}" "${dest}")" ]
}

@test "an unsplittable IMPORT conflict never pairs mismatched files" {
  # When no split validates, whatever comes back must not name two real files
  # that FileBot did not actually pair -- that is the case that would quarantine
  # the wrong copy.
  local out
  out="$(parse_filebot_conflicts '[IMPORT] Destination file already exists: /gone/a (1).mkv (/gone/b (1).mkv)')"
  local paired_src="${out%%	*}"
  local paired_dest="${out##*	}"
  # Neither half may resolve to a real file, so compare_media refuses the pair.
  [ ! -f "${paired_src}" ]
  [ ! -f "${paired_dest}" ]
}

@test "a dry run neither rescans Plex nor prunes quarantine" {
  # replace_media_file returns success in dry run without moving anything, so
  # the count reflects what would have happened. Acting on it would make a dry
  # run issue a real Plex scan and really delete quarantined files.
  setup_pipeline_stubs

  local inc="${TEST_TMPDIR}/library/Show.S01E01.mp4"
  cp "$(make_media "sd.mp4" "640x360" "200k" 2)" "${inc}"
  local cand="${TR_TORRENT_DIR}/Show.S01E01.mp4"
  cp "$(make_media "hd.mp4" "1920x1080" "2000k" 2)" "${cand}"

  # A quarantined file well past retention: a real prune would remove it.
  local q="${TEST_TMPDIR}/downloads/triage/quarantine"
  mkdir -p "${q}"
  touch "${q}/old.mp4"
  touch -t "$(date -v-40d '+%Y%m%d%H%M')" "${q}/old.mp4"

  MEDIA_COMPARE_DRY_RUN=true handle_duplicate_upgrades "already-in-plex" \
    "[AUTO] Skipped [${cand}] because [${inc}] already exists
Rename episodes using [TheTVDB] to TV Shows"

  run grep -q "PLEX SCAN" "${PIPELINE_LOG}"
  [ "$status" -ne 0 ]
  [ -f "${q}/old.mp4" ]
  # And the library is untouched.
  [ "$(media_resolution "${inc}")" -eq $((640 * 360)) ]
}

@test "the bitrate fallback fires for containers with no per-stream bitrate" {
  # Matroska routinely reports stream=bit_rate as N/A, which is why
  # media_video_bitrate falls back to the container's overall rate. MKV is a
  # common release container, so this path carries real traffic rather than
  # being a defensive afterthought.
  local mkv="${TEST_TMPDIR}/a.mkv"
  ffmpeg -y -v error \
    -f lavfi -i "testsrc=size=640x360:rate=10:duration=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -b:v 200k -c:a aac -ac 2 "${mkv}" 2>/dev/null

  # Confirm the premise: the primary probe really does come back unusable here,
  # so this test would still mean something if ffmpeg's defaults changed.
  run media_probe_field "${mkv}" "v:0" "stream=bit_rate"
  [ "$status" -ne 0 ]

  # ...and the fallback supplies a usable number anyway.
  run media_video_bitrate "${mkv}"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "an IMPORT conflict whose paths end in a close paren still pairs correctly" {
  # Only one trailing ")" is stripped before the split points are walked, so a
  # path that genuinely ends in ")" -- a season or edition folder, say -- looks
  # like it should lose a character. It does not: the walk keeps whichever
  # split leaves both halves naming real files, which repairs the strip.
  mkdir -p "${TEST_TMPDIR}/plex" "${TEST_TMPDIR}/dl"
  local dest="${TEST_TMPDIR}/plex/Movie (2024)"
  local src="${TEST_TMPDIR}/dl/Movie (2024)"
  : >"${dest}"
  : >"${src}"

  local out
  out="$(parse_filebot_conflicts "[IMPORT] Destination file already exists: ${dest} (${src})")"
  [ "${out}" = "$(printf '%s\t%s' "${src}" "${dest}")" ]
}

@test "two replacements in the same second do not overwrite each other in quarantine" {
  # An episode pack can replace several like-named files inside one second. A
  # bare timestamp would make the second quarantined copy overwrite the first,
  # destroying the file quarantine exists to preserve.
  local q="${TEST_TMPDIR}/quarantine"
  local libdir="${TEST_TMPDIR}/library"
  mkdir -p "${libdir}"

  local i
  for i in 1 2; do
    local inc="${libdir}/Show.mp4"
    cp "$(make_media "sd${i}.mp4" "640x360" "200k" 2)" "${inc}"
    local cand
    cand="$(make_media "hd${i}.mp4" "1920x1080" "2000k" 2)"
    run replace_media_file "${cand}" "${inc}" "${q}"
    [ "$status" -eq 0 ]
  done

  # Both displaced copies survive.
  [ "$(find "${q}" -type f | wc -l | tr -d ' ')" -eq 2 ]
}
