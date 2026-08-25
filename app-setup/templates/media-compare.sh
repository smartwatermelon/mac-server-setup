# shellcheck shell=bash
#
# media-compare.sh — decide which of two copies of the same media to keep
#
# This is a sourced library, not an executable script; it defines functions and
# runs nothing on its own.
#
# When FileBot renames a download onto a path that already holds a file, it is
# run with `--conflict auto`, which skips rather than overwrites. The download
# is then classified `already-in-plex` and moved to triage for a human to look
# at (see classify_failure and triage_failed_torrent in transmission-done.sh).
# Nothing is lost and nothing good is overwritten, but nothing is decided
# either: the better copy sits in triage until somebody compares them by hand.
#
# This library makes that comparison. It reads objective attributes with
# ffprobe and applies a fixed ladder of rules, so the same two files always
# produce the same answer (issue #178).
#
# Deliberately NOT a general "which file is better" oracle. It answers one
# narrow question — this download versus the library copy of the same title —
# and answers "keep what we have" whenever it cannot tell. A wrong "replace"
# costs the better copy; a wrong "keep" costs disk space and a triage entry.
# Those are not symmetric, so every uncertain path resolves to keep.
#
# Usage (from transmission-done.sh):
#     source "${SCRIPT_DIR}/media-compare.sh"
#     decision="$(compare_media "${candidate}" "${incumbent}")"
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-08-25

# ---------------------------------------------------------------------------
# Configuration
#
# Deliberately not `readonly`: transmission-done.sh may be sourced more than
# once by the BATS helper, and re-sourcing a readonly assignment aborts the
# caller under `set -e` — the same reason pia-port-guard.sh avoids them.
# ---------------------------------------------------------------------------

# ffprobe ships in the ffmpeg keg, which config/formulae.txt already installs.
# Full path for the same reason FILEBOT and YQ use one: Transmission invokes
# its done-script with a minimal PATH that does not include Homebrew.
MEDIA_COMPARE_FFPROBE="${MEDIA_COMPARE_FFPROBE:-${HOMEBREW_PREFIX:-/opt/homebrew}/bin/ffprobe}"

# ffprobe on a large file over NFS can block. Bound it: a comparison that
# cannot be made in time resolves to "keep", which is the safe direction.
MEDIA_COMPARE_TIMEOUT="${MEDIA_COMPARE_TIMEOUT:-30}"

# Bitrate readings vary between two encodes of identical quality, and a
# difference under this fraction is noise rather than signal. 10% keeps the
# rule from flapping on files that are effectively the same.
MEDIA_COMPARE_BITRATE_MARGIN="${MEDIA_COMPARE_BITRATE_MARGIN:-10}"

# Log-only mode. When true, callers report what they would have done and change
# nothing. The issue asks for this for initial rollout.
MEDIA_COMPARE_DRY_RUN="${MEDIA_COMPARE_DRY_RUN:-false}"

# How long a displaced file stays in quarantine before it may be reaped.
MEDIA_COMPARE_RETENTION_DAYS="${MEDIA_COMPARE_RETENTION_DAYS:-14}"

# ---------------------------------------------------------------------------
# Attribute extraction
# ---------------------------------------------------------------------------

# Print one ffprobe field for a file, or nothing if it cannot be read.
#
# Every failure mode collapses to empty output: missing file, missing ffprobe,
# timeout, unparsable container, or a field ffprobe reports as "N/A". Callers
# treat empty as "unknown" and fall through to the next rule, so a partially
# readable file still gets compared on whatever did resolve.
media_probe_field() {
  local file="$1"
  local stream_spec="$2"
  local entry="$3"

  [[ -f "${file}" ]] || return 1
  [[ -x "${MEDIA_COMPARE_FFPROBE}" ]] || return 1

  # `|| true` is the point, not an oversight: every ffprobe failure -- timeout,
  # unreadable container, unknown stream -- must surface as empty output for the
  # caller to treat as "unknown", not as a non-zero status that would abort a
  # caller running under `set -e`.
  local raw
  raw="$(timeout "${MEDIA_COMPARE_TIMEOUT}" "${MEDIA_COMPARE_FFPROBE}" \
    -v error \
    -select_streams "${stream_spec}" \
    -show_entries "${entry}" \
    -of default=noprint_wrappers=1:nokey=1 \
    "${file}" 2>/dev/null | head -1 || true)"

  # ffprobe prints the literal string N/A for a field it knows about but cannot
  # fill in. That is not a number, and must not be compared as one.
  [[ -n "${raw}" && "${raw}" != "N/A" ]] || return 1

  printf '%s' "${raw}"
}

# Pixel count of the primary video stream — width * height rather than height
# alone, so anamorphic and letterboxed encodes compare on actual picture area.
media_resolution() {
  local file="$1"
  local width height
  width="$(media_probe_field "${file}" "v:0" "stream=width")" || return 1
  height="$(media_probe_field "${file}" "v:0" "stream=height")" || return 1
  [[ "${width}" =~ ^[0-9]+$ && "${height}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$((width * height))"
}

# Video bitrate in bits/sec.
#
# Falls back to the container's overall bitrate when the stream does not carry
# its own — common in Matroska, which often omits per-stream bitrate. The
# fallback is only meaningful against another file measured the same way, which
# is why the caller compares like with like and skips the rule if either side
# is unknown.
media_video_bitrate() {
  local file="$1"
  local rate
  if rate="$(media_probe_field "${file}" "v:0" "stream=bit_rate")" \
    && [[ "${rate}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${rate}"
    return 0
  fi
  if rate="$(media_probe_field "${file}" "v:0" "format=bit_rate")" \
    && [[ "${rate}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${rate}"
    return 0
  fi
  return 1
}

# Channel count of the primary audio stream (2 for stereo, 6 for 5.1).
media_audio_channels() {
  local file="$1"
  local channels
  channels="$(media_probe_field "${file}" "a:0" "stream=channels")" || return 1
  [[ "${channels}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${channels}"
}

# Size in bytes. stat is BSD here; the container never runs this library.
media_file_size() {
  local file="$1"
  [[ -f "${file}" ]] || return 1
  stat -f%z "${file}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Pairing a download with the library file it duplicates
# ---------------------------------------------------------------------------

# Read FileBot's conflict output and print `source<TAB>destination` for each
# skipped file, one pair per line.
#
# FileBot has already done the hard part. It matched the download to a title
# and worked out exactly which library path it collides with, then named both
# in the message it prints when `--conflict auto` declines to overwrite. Taking
# the pair from that message is authoritative; guessing it back from filenames
# is not. Anything this cannot parse yields no line, and the caller falls
# through to the existing triage behaviour.
#
# Two formats, with the paths in opposite orders:
#   [AUTO] Skipped [SOURCE] because [DEST] already exists
#   [IMPORT] Destination file already exists: DEST (SOURCE)
#
# The IMPORT form is genuinely ambiguous: `DEST (SOURCE)` cannot be split by
# pattern alone once both paths contain " (", which is routine for films —
# `/plex/The Thing (1982).mkv (/dl/The Thing (1982).mkv)` has three candidate
# split points and a greedy regex picks the wrong one, pairing a fragment of
# one path with a fragment of the other. Comparing and quarantining the wrong
# library file is the worst outcome this library can produce, so that case is
# resolved by checking the filesystem rather than by guessing: try each split
# and keep the one where both sides are real files.
parse_filebot_conflicts() {
  local filebot_output="$1"

  # The AUTO form is unambiguous -- both paths are bracket-delimited.
  printf '%s\n' "${filebot_output}" | sed -n \
    -e 's/^.*Skipped \[\(.*\)\] because \[\(.*\)\] already exists.*$/\1	\2/p'

  local line
  while IFS= read -r line; do
    [[ "${line}" == *"Destination file already exists: "* ]] || continue
    _emit_import_conflict "${line}"
  done <<<"${filebot_output}"
}

# Split one IMPORT-format line into `source<TAB>destination`, printing nothing
# if no split can be justified.
_emit_import_conflict() {
  local rest="${1#*Destination file already exists: }"
  rest="${rest%)}"

  # Walk the candidate split points left to right and take the first where both
  # halves name existing files. In production they always do -- FileBot just
  # looked at both of them.
  local probe="${rest}" prefix="" dest src
  while [[ "${probe}" == *" ("* ]]; do
    dest="${prefix}${probe%% (*}"
    src="${probe#* (}"
    if [[ -f "${dest}" && -f "${src}" ]]; then
      printf '%s\t%s\n' "${src}" "${dest}"
      return 0
    fi
    prefix="${dest} ("
    probe="${src}"
  done

  # Nothing validated -- either the files are gone, or this is a unit test with
  # synthetic paths. Fall back to the simple split, which is correct whenever
  # only one candidate point exists. A pair that is wrong here still cannot
  # destroy anything: compare_media requires both files to be readable, and
  # answers "keep" when either is not.
  if [[ "${rest}" == *" ("* ]]; then
    printf '%s\t%s\n' "${rest##* (}" "${rest% (*}"
  fi
}

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

# Compare two files that hold the same title and print a verdict:
#
#   replace   the candidate is better; the incumbent should be displaced
#   keep      the incumbent is better, identical, or the answer is unclear
#
# The reason is printed on a second line so callers can log why. Rules are
# applied in order and the first one that separates the files decides:
#
#   1. identical bytes    -> keep (nothing to gain, and a hash is conclusive)
#   2. resolution         -> more pixels wins
#   3. video bitrate      -> higher wins, past a noise margin
#   4. audio channels     -> more wins
#   5. size               -> larger wins, as a last resort
#
# Two files that tie on every rule return keep: with no evidence of an
# improvement, churning the library is the worse option.
compare_media() {
  local candidate="$1"
  local incumbent="$2"

  if [[ ! -f "${candidate}" ]]; then
    printf 'keep\ncandidate is not a readable file\n'
    return 0
  fi
  if [[ ! -f "${incumbent}" ]]; then
    # Nothing to compare against. Callers treat this as "no duplicate", but
    # answering "replace" here would be a claim this function cannot support.
    printf 'keep\nincumbent is not a readable file\n'
    return 0
  fi

  # Rule 1: identical content. Compare sizes first — cmp on two large files
  # over NFS is expensive, and differing sizes rule out identity outright.
  local cand_size inc_size
  cand_size="$(media_file_size "${candidate}")" || cand_size=""
  inc_size="$(media_file_size "${incumbent}")" || inc_size=""
  if [[ -n "${cand_size}" && "${cand_size}" == "${inc_size}" ]]; then
    if cmp -s "${candidate}" "${incumbent}"; then
      printf 'keep\nidentical file (byte-for-byte)\n'
      return 0
    fi
  fi

  # Rule 2: resolution.
  local cand_res inc_res
  cand_res="$(media_resolution "${candidate}")" || cand_res=""
  inc_res="$(media_resolution "${incumbent}")" || inc_res=""
  if [[ -n "${cand_res}" && -n "${inc_res}" && "${cand_res}" -ne "${inc_res}" ]]; then
    if [[ "${cand_res}" -gt "${inc_res}" ]]; then
      printf 'replace\nhigher resolution (%s vs %s pixels)\n' "${cand_res}" "${inc_res}"
    else
      printf 'keep\nlower resolution (%s vs %s pixels)\n' "${cand_res}" "${inc_res}"
    fi
    return 0
  fi

  # Rule 3: video bitrate, past the noise margin. Integer arithmetic only —
  # this runs under Transmission's shell, where bc may not exist.
  local cand_rate inc_rate
  cand_rate="$(media_video_bitrate "${candidate}")" || cand_rate=""
  inc_rate="$(media_video_bitrate "${incumbent}")" || inc_rate=""
  if [[ -n "${cand_rate}" && -n "${inc_rate}" ]]; then
    local margin=$((inc_rate * MEDIA_COMPARE_BITRATE_MARGIN / 100))
    if [[ "${cand_rate}" -gt $((inc_rate + margin)) ]]; then
      printf 'replace\nhigher video bitrate (%s vs %s bps)\n' "${cand_rate}" "${inc_rate}"
      return 0
    fi
    if [[ "${inc_rate}" -gt $((cand_rate + margin)) ]]; then
      printf 'keep\nlower video bitrate (%s vs %s bps)\n' "${cand_rate}" "${inc_rate}"
      return 0
    fi
  fi

  # Rule 4: audio channels.
  local cand_ch inc_ch
  cand_ch="$(media_audio_channels "${candidate}")" || cand_ch=""
  inc_ch="$(media_audio_channels "${incumbent}")" || inc_ch=""
  if [[ -n "${cand_ch}" && -n "${inc_ch}" && "${cand_ch}" -ne "${inc_ch}" ]]; then
    if [[ "${cand_ch}" -gt "${inc_ch}" ]]; then
      printf 'replace\nmore audio channels (%s vs %s)\n' "${cand_ch}" "${inc_ch}"
    else
      printf 'keep\nfewer audio channels (%s vs %s)\n' "${cand_ch}" "${inc_ch}"
    fi
    return 0
  fi

  # Rule 5: size, as a tiebreak. Only meaningful once the rules above found
  # nothing, so it never overrides a real quality signal.
  if [[ -n "${cand_size}" && -n "${inc_size}" && "${cand_size}" -ne "${inc_size}" ]]; then
    if [[ "${cand_size}" -gt "${inc_size}" ]]; then
      printf 'replace\nlarger file (%s vs %s bytes)\n' "${cand_size}" "${inc_size}"
    else
      printf 'keep\nsmaller file (%s vs %s bytes)\n' "${cand_size}" "${inc_size}"
    fi
    return 0
  fi

  printf 'keep\nno measurable difference\n'
  return 0
}

# ---------------------------------------------------------------------------
# Replacement
# ---------------------------------------------------------------------------

# Move the incumbent into quarantine and put the candidate in its place.
#
# Order matters and is not interchangeable. The incumbent is moved out first,
# so the library never holds two files for one slot; then the candidate is
# moved in. If the second move fails, the incumbent is restored — better to
# end where we started than to leave the library missing an episode.
#
# `mv` within one filesystem is atomic, so a reader either sees the old file or
# the new one. Across filesystems (the NAS is a separate mount) mv copies and
# unlinks, which is not atomic; the restore path is what covers that case.
replace_media_file() {
  local candidate="$1"
  local incumbent="$2"
  local quarantine_dir="$3"

  if [[ ! -f "${candidate}" ]]; then
    media_compare_log "Replace aborted: candidate missing (${candidate})"
    return 1
  fi
  if [[ ! -f "${incumbent}" ]]; then
    media_compare_log "Replace aborted: incumbent missing (${incumbent})"
    return 1
  fi

  if [[ "${MEDIA_COMPARE_DRY_RUN}" == "true" ]]; then
    media_compare_log "DRY RUN: would replace ${incumbent} with ${candidate}"
    return 0
  fi

  mkdir -p "${quarantine_dir}" 2>/dev/null || {
    media_compare_log "Replace aborted: cannot create quarantine ${quarantine_dir}"
    return 1
  }

  # Timestamp the quarantined name so repeated replacements of the same title
  # do not overwrite each other — the whole point of quarantine is that the
  # displaced file is still there to recover.
  local incumbent_name quarantined
  incumbent_name="$(basename "${incumbent}")"
  quarantined="${quarantine_dir}/${incumbent_name}.$(date +%Y%m%d-%H%M%S)"

  # A second-granularity timestamp is not unique on its own: an episode pack
  # replacing several files named alike can land twice in the same second, and
  # the second move would overwrite the first copy in quarantine -- destroying
  # the very file quarantine exists to preserve. Step aside if the name is
  # taken rather than clobbering it.
  local attempt=1
  while [[ -e "${quarantined}" ]]; do
    quarantined="${quarantine_dir}/${incumbent_name}.$(date +%Y%m%d-%H%M%S).${attempt}"
    attempt=$((attempt + 1))
    if [[ "${attempt}" -gt 100 ]]; then
      media_compare_log "Replace aborted: cannot find a free quarantine name for ${incumbent_name}"
      return 1
    fi
  done

  if ! mv "${incumbent}" "${quarantined}" 2>/dev/null; then
    media_compare_log "Replace aborted: could not quarantine ${incumbent}"
    return 1
  fi

  if ! mv "${candidate}" "${incumbent}" 2>/dev/null; then
    media_compare_log "Replace failed mid-way: restoring ${incumbent} from quarantine"
    if mv "${quarantined}" "${incumbent}" 2>/dev/null; then
      media_compare_log "Restored ${incumbent}; library is unchanged"
    else
      # Both moves failed. Say so loudly and name the file, because this is the
      # one path that leaves the library short an episode.
      media_compare_log "ERROR: ${incumbent} is missing; the original is at ${quarantined}"
    fi
    return 1
  fi

  media_compare_log "Replaced ${incumbent} (previous copy quarantined at ${quarantined})"
  return 0
}

# Delete quarantined files older than the retention window.
#
# Scoped to the quarantine directory and to regular files, and takes the
# directory as an argument rather than deriving it, so a caller cannot
# accidentally point this at a library path.
prune_quarantine() {
  local quarantine_dir="$1"
  local retention_days="${2:-${MEDIA_COMPARE_RETENTION_DAYS}}"

  [[ -d "${quarantine_dir}" ]] || return 0

  if [[ "${MEDIA_COMPARE_DRY_RUN}" == "true" ]]; then
    local due
    due="$(find "${quarantine_dir}" -type f -mtime "+${retention_days}" 2>/dev/null | wc -l | tr -d ' ' || true)"
    media_compare_log "DRY RUN: ${due} quarantined file(s) past ${retention_days}d retention"
    return 0
  fi

  local pruned=0
  while IFS= read -r stale; do
    [[ -n "${stale}" ]] || continue
    if rm -f "${stale}" 2>/dev/null; then
      pruned=$((pruned + 1))
    fi
  done < <(find "${quarantine_dir}" -type f -mtime "+${retention_days}" 2>/dev/null || true)

  if [[ "${pruned}" -gt 0 ]]; then
    media_compare_log "Pruned ${pruned} quarantined file(s) older than ${retention_days} days"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Logging
#
# transmission-done.sh defines log(); when sourced from there this delegates to
# it so decisions land in the same processing log as everything else. Standalone
# (tests, manual runs) it falls back to stderr rather than failing.
# ---------------------------------------------------------------------------
media_compare_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$1"
  else
    printf '[media-compare] %s\n' "$1" >&2
  fi
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

# Work every conflict FileBot reported, replacing library files that the
# download improves on.
#
# Prints the number of replacements made, so the caller knows whether a Plex
# rescan is warranted -- a scan with nothing to find is wasted work, and this
# runs on every duplicate.
#
# Returns 0 whether or not anything was replaced. A duplicate that loses the
# comparison is a normal outcome, not a failure, and the download still goes to
# triage either way.
process_duplicate_conflicts() {
  local filebot_output="$1"
  local quarantine_dir="$2"

  local replaced=0
  local candidate incumbent

  while IFS=$'\t' read -r candidate incumbent; do
    [[ -n "${candidate}" && -n "${incumbent}" ]] || continue

    local result verdict why
    result="$(compare_media "${candidate}" "${incumbent}")"
    verdict="$(printf '%s' "${result}" | head -1)"
    why="$(printf '%s' "${result}" | sed -n '2p')"

    if [[ "${verdict}" != "replace" ]]; then
      media_compare_log "Keeping library copy of $(basename "${incumbent}"): ${why}"
      continue
    fi

    media_compare_log "Upgrading $(basename "${incumbent}"): ${why}"
    if replace_media_file "${candidate}" "${incumbent}" "${quarantine_dir}"; then
      replaced=$((replaced + 1))
    fi
  done < <(parse_filebot_conflicts "${filebot_output}" || true)

  printf '%s' "${replaced}"
  return 0
}
