<!-- markdownlint-disable MD013 MD036 MD060 -->
# Failure Triage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use
> superpowers:executing-plans to implement this plan
> task-by-task.

**Goal:** When transmission-done cannot process a torrent,
categorize the failure, move files to a triage directory,
and remove the torrent from Transmission — keeping
pending-move clean and giving the operator clear hints for
manual resolution.

**Architecture:** Add a `triage_failed_torrent()` function
to `transmission-done.sh` that classifies failures from
FileBot output, moves the torrent to a category-specific
subdirectory under `Media/Torrents/triage/`, and returns 0
so the trigger watcher treats it as "handled" (cleaning up
the trigger and removing from Transmission). The
classification uses patterns already identified in
`log_filebot_error()`.

**Tech Stack:** Pure Bash 5.x, BATS tests, existing FileBot output parsing

---

## Triage Categories

Based on observed FileBot output patterns:

| Category | Directory |
|---|---|
| Already in Plex | `triage/already-in-plex/` |
| No match | `triage/no-match/` |
| Other failure | `triage/failed/` |

Detection patterns:

- **already-in-plex**: `[AUTO] Skipped.*already exists`
  or `[IMPORT] Destination file already exists`
- **no-match**: `Processed 0 files` without "already
  exists"; or `unable to identify`/`no match`/`no results`
- **failed**: Anything else (network, license, perms)

## Key Design Decisions

1. **Triage happens in `process_media()`** after
   `process_media_with_fallback()` fails — this is where
   `LAST_FILEBOT_OUTPUT` is available for classification.
2. **Triage returns 0** (success) so the trigger watcher
   cleans up the trigger file and removes the torrent from
   Transmission. Files preserved in triage for review.
3. **`TRIAGE_BASE`** derived from `TR_TORRENT_DIR` (the
   download parent, e.g., `.../Torrents/pending-move`),
   replacing `pending-move` with `triage/<category>`.
4. **Move uses `mv`** (NFS-safe, no opendir needed).
5. **Manual mode skips triage** — interactive users can
   see the error and decide. Triage is automated-only.
6. **Preview failures also get triaged** — when
   `preview_filebot_changes()` fails, that's "no match".

---

### Task 1: Add `classify_failure()` function

**Files:**

- Modify: `app-setup/templates/transmission-done.sh` — add after `log_filebot_error()` (~line 520)
- Test: `tests/transmission-filebot/unit/test_error_logging.bats` — add classification tests

**Step 1: Write the failing tests**

Add to `tests/transmission-filebot/unit/test_error_logging.bats`:

```bash
# --- Failure classification tests ---

@test "classify_failure: detects already-in-plex from Skipped pattern" {
  local output='[AUTO] Skipped [/path/to/file.mkv] because [/dest/file.mkv] already exists
Processed 0 files'
  run classify_failure "${output}"
  assert_success
  assert_output "already-in-plex"
}

@test "classify_failure: detects already-in-plex from IMPORT pattern" {
  local output='[IMPORT] Destination file already exists: /dest/file.mkv (/src/file.mkv)
Processed 0 files'
  run classify_failure "${output}"
  assert_success
  assert_output "already-in-plex"
}

@test "classify_failure: detects no-match from zero processed" {
  local output='Rename episodes using [TheMovieDB]
Lookup via [SomeShow]
Processed 0 files'
  run classify_failure "${output}"
  assert_success
  assert_output "no-match"
}

@test "classify_failure: detects no-match from identification failure" {
  local output='unable to identify media files'
  run classify_failure "${output}"
  assert_success
  assert_output "no-match"
}

@test "classify_failure: returns failed for empty output" {
  run classify_failure ""
  assert_success
  assert_output "failed"
}

@test "classify_failure: returns failed for network errors" {
  local output='connection timeout reaching TheTVDB'
  run classify_failure "${output}"
  assert_success
  assert_output "failed"
}
```

**Step 2: Run tests to verify they fail**

Run: `bats tests/transmission-filebot/unit/test_error_logging.bats`
Expected: 6 new tests FAIL with "classify_failure: command not found"

**Step 3: Implement `classify_failure()`**

Add to `transmission-done.sh` after `log_filebot_error()` (~line 520):

```bash
# Classify a FileBot failure into a triage category.
# Reads the combined FileBot output from all fallback strategies.
# Returns one of: "already-in-plex", "no-match", "failed"
classify_failure() {
  local filebot_output="$1"

  # Already in Plex: FileBot found a match but the destination file exists
  if echo "${filebot_output}" | grep -qiE "already exists|Skipped.*already exists"; then
    echo "already-in-plex"
    return 0
  fi

  # No match: FileBot couldn't identify the media at all
  if echo "${filebot_output}" | grep -qiE "unable to identify|no match|no results|failed to fetch"; then
    echo "no-match"
    return 0
  fi

  # No match: FileBot found candidates but processed 0 files (ambiguous match)
  if echo "${filebot_output}" | grep -q "Processed 0 files"; then
    echo "no-match"
    return 0
  fi

  # Everything else: network errors, license issues, permissions, etc.
  echo "failed"
  return 0
}
```

**Step 4: Run tests to verify they pass**

Run: `bats tests/transmission-filebot/unit/test_error_logging.bats`
Expected: All tests PASS (existing 16 + 6 new = 22)

**Step 5: Commit**

```bash
git add app-setup/templates/transmission-done.sh tests/transmission-filebot/unit/test_error_logging.bats
git commit -m "feat(transmission-filebot): add classify_failure() for triage categories"
```

---

### Task 2: Add `triage_failed_torrent()` function

**Files:**

- Modify: `app-setup/templates/transmission-done.sh` — add after `classify_failure()`
- Test: `tests/transmission-filebot/unit/test_error_logging.bats` — add triage tests

**Step 1: Write the failing tests**

Add to `tests/transmission-filebot/unit/test_error_logging.bats`:

```bash
# --- Triage function tests ---

@test "triage_failed_torrent: moves directory to correct triage category" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/TestTorrent"
  mkdir -p "${source}"
  touch "${source}/video.mkv"

  run triage_failed_torrent "${source}" "no-match" "${triage_base}"
  assert_success
  assert_dir_exists "${triage_base}/no-match/TestTorrent"
  assert_file_exists "${triage_base}/no-match/TestTorrent/video.mkv"
  assert_file_not_exists "${source}/video.mkv"
}

@test "triage_failed_torrent: moves single file to triage category" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/Movie.2024.mkv"
  mkdir -p "${BATS_TEST_TMPDIR}/pending-move"
  touch "${source}"

  run triage_failed_torrent "${source}" "already-in-plex" "${triage_base}"
  assert_success
  assert_file_exists "${triage_base}/already-in-plex/Movie.2024.mkv"
  assert_file_not_exists "${source}"
}

@test "triage_failed_torrent: creates triage directory if missing" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/Test"
  mkdir -p "${source}"
  touch "${source}/file.mkv"

  # triage_base doesn't exist yet
  assert_file_not_exists "${triage_base}"
  run triage_failed_torrent "${source}" "failed" "${triage_base}"
  assert_success
  assert_dir_exists "${triage_base}/failed/Test"
}

@test "triage_failed_torrent: handles name collision by appending timestamp" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/TestTorrent"
  mkdir -p "${source}" "${triage_base}/no-match/TestTorrent"
  touch "${source}/video.mkv"

  run triage_failed_torrent "${source}" "no-match" "${triage_base}"
  assert_success
  # Original source should be gone
  assert_file_not_exists "${source}/video.mkv"
}

@test "triage_failed_torrent: logs the triage action" {
  local triage_base="${BATS_TEST_TMPDIR}/triage"
  local source="${BATS_TEST_TMPDIR}/pending-move/TestTorrent"
  mkdir -p "${source}"
  touch "${source}/video.mkv"

  triage_failed_torrent "${source}" "no-match" "${triage_base}"
  assert_file_exists "${LOG_FILE}"
  run grep "Triaged to" "${LOG_FILE}"
  assert_success
}
```

**Step 2: Run tests to verify they fail**

Run: `bats tests/transmission-filebot/unit/test_error_logging.bats`
Expected: 5 new tests FAIL

**Step 3: Implement `triage_failed_torrent()`**

Add to `transmission-done.sh` after `classify_failure()`:

```bash
# Move a failed torrent to a triage directory based on failure category.
# Args: $1=torrent_path, $2=category (from classify_failure), $3=triage_base_dir
# The triage directory structure is:
#   triage/already-in-plex/  — FileBot matched but destination exists
#   triage/no-match/         — FileBot couldn't identify the media
#   triage/failed/           — other errors (network, license, permissions)
triage_failed_torrent() {
  local torrent_path="$1"
  local category="$2"
  local triage_base="$3"
  local torrent_name
  torrent_name=$(basename "${torrent_path}")

  local dest_dir="${triage_base}/${category}"
  mkdir -p "${dest_dir}" 2>/dev/null || true

  # Handle name collision: append timestamp if destination already exists
  local dest="${dest_dir}/${torrent_name}"
  if [[ -e "${dest}" ]]; then
    dest="${dest_dir}/${torrent_name}.$(date +%Y%m%d-%H%M%S)"
  fi

  if mv "${torrent_path}" "${dest}" 2>/dev/null; then
    log "Triaged to ${category}: ${torrent_name} → ${dest}"
    return 0
  else
    log "Warning: Failed to move ${torrent_name} to triage/${category}"
    return 1
  fi
}
```

**Step 4: Run tests to verify they pass**

Run: `bats tests/transmission-filebot/unit/test_error_logging.bats`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add app-setup/templates/transmission-done.sh tests/transmission-filebot/unit/test_error_logging.bats
git commit -m "feat(transmission-filebot): add triage_failed_torrent() to move failures to categorized dirs"
```

---

### Task 3: Wire triage into `process_media()` and `main()`

**Files:**

- Modify: `app-setup/templates/transmission-done.sh:1205-1265` (process_media) and `1426-1489` (main)

**Step 1: Modify `process_media()` to return triage info**

The key insight: `process_media()` currently returns 1 on failure. Instead, when in automated mode, it should triage the failure and return 0 (handled). The caller (`main()`) needs to know whether media was successfully processed vs triaged, so it can log appropriately.

Replace the failure path in `process_media()` (~line 1238-1241):

```bash
  # Step 5: Process with comprehensive fallback strategy
  LAST_FILEBOT_OUTPUT=""
  if ! process_media_with_fallback "${source_dir}"; then
    log "Error: All FileBot strategies failed"
    log_filebot_error 1 "${LAST_FILEBOT_OUTPUT}" "${source_dir}" "fallback-chain"

    # In automated mode, triage the failure instead of leaving it in pending-move
    if [[ "${INVOCATION_MODE}" == "automated" ]]; then
      local category
      category=$(classify_failure "${LAST_FILEBOT_OUTPUT}")
      local triage_base="${TR_TORRENT_DIR%/*}/triage"
      if triage_failed_torrent "${source_dir}" "${category}" "${triage_base}"; then
        # Return 0: the torrent is "handled" (triaged), trigger watcher should
        # clean up the trigger and remove from Transmission
        return 0
      fi
    fi
    return 1
  fi
```

Also add triage for the preview failure path (~line 1222-1226). When the preview fails, FileBot can't even identify the media — that's "no-match":

```bash
  # Step 3: Preview changes with dry-run
  if ! preview_filebot_changes "${source_dir}"; then
    log "Error: Preview failed - cannot determine what changes would be made"

    if [[ "${INVOCATION_MODE}" == "automated" ]]; then
      local category
      category=$(classify_failure "${LAST_FILEBOT_OUTPUT:-}")
      local triage_base="${TR_TORRENT_DIR%/*}/triage"
      if triage_failed_torrent "${source_dir}" "${category}" "${triage_base}"; then
        return 0
      fi
    fi
    return 1
  fi
```

**Step 2: Update `main()` logging**

The `main()` function currently logs "Processing completed successfully" when `process_media()` returns 0. But now return 0 can mean either "processed" or "triaged". Use a flag to distinguish.

Add a global flag before process_media is called:

```bash
      TRIAGE_PERFORMED=false
      if ! process_media "${torrent_path}"; then
        log "Error: Media processing failed"
        main_exit_code=1
      elif [[ "${TRIAGE_PERFORMED}" == "true" ]]; then
        log "Torrent triaged (not processed) — see triage directory"
      else
        log "Processing completed successfully"
      fi
```

And set `TRIAGE_PERFORMED=true` inside `triage_failed_torrent()` when the move succeeds.

**Step 3: Run full test suite**

Run: `bats tests/transmission-filebot/**/*.bats`
Expected: All 114+ tests PASS (existing tests use TEST_MODE and INVOCATION_MODE=manual, so they won't trigger triage)

**Step 4: Commit**

```bash
git add app-setup/templates/transmission-done.sh
git commit -m "feat(transmission-filebot): wire triage into process_media for automated failures"
```

---

### Task 4: Add integration tests for triage flow

**Files:**

- Create: `tests/transmission-filebot/integration/test_triage_workflow.bats`

**Step 1: Write integration tests**

```bash
#!/usr/bin/env bats

load '../test_helper'

setup() {
  common_setup
  export INVOCATION_MODE="automated"
  export TR_TORRENT_DIR="${BATS_TEST_TMPDIR}/pending-move"
  mkdir -p "${TR_TORRENT_DIR}"
}

@test "triage workflow: already-in-plex torrent is moved and returns success" {
  # Create a torrent that FileBot will skip (already exists)
  local torrent_dir="${TR_TORRENT_DIR}/TestShow.S01E01"
  mkdir -p "${torrent_dir}"
  touch "${torrent_dir}/video.mkv"

  # Mock LAST_FILEBOT_OUTPUT with "already exists" pattern
  export FILEBOT_TEST_OUTPUT='[AUTO] Skipped [/src/video.mkv] because [/dst/video.mkv] already exists
Processed 0 files'
  export FILEBOT_TEST_EXIT=1

  # The triage base would be at pending-move/../triage
  local triage_base="${BATS_TEST_TMPDIR}/triage"

  local category
  category=$(classify_failure "${FILEBOT_TEST_OUTPUT}")
  assert_equal "${category}" "already-in-plex"

  run triage_failed_torrent "${torrent_dir}" "${category}" "${triage_base}"
  assert_success
  assert_dir_exists "${triage_base}/already-in-plex/TestShow.S01E01"
}

@test "triage workflow: no-match torrent is moved to no-match" {
  local torrent_dir="${TR_TORRENT_DIR}/UnknownMedia"
  mkdir -p "${torrent_dir}"
  touch "${torrent_dir}/video.mkv"

  local output='Rename episodes using [TheMovieDB]
Processed 0 files'

  local category
  category=$(classify_failure "${output}")
  assert_equal "${category}" "no-match"

  local triage_base="${BATS_TEST_TMPDIR}/triage"
  run triage_failed_torrent "${torrent_dir}" "${category}" "${triage_base}"
  assert_success
  assert_dir_exists "${triage_base}/no-match/UnknownMedia"
}

@test "triage workflow: classify_failure with mixed already-exists and match returns already-in-plex" {
  local output='[AUTO] Skipped [/src/ep1.mkv] because [/dst/ep1.mkv] already exists
[MOVE] from [/src/ep2.mkv] to [/dst/ep2.mkv]
Processed 1 file'
  # This case has both a skip and a move — it succeeded partially.
  # classify_failure checks for "already exists" first, so this returns already-in-plex.
  # But in practice this wouldn't reach triage because process_media_with_fallback
  # would return 0 (1 file was processed).
  run classify_failure "${output}"
  assert_output "already-in-plex"
}
```

**Step 2: Run integration tests**

Run: `bats tests/transmission-filebot/integration/test_triage_workflow.bats`
Expected: PASS

**Step 3: Run full suite**

Run: `bats tests/transmission-filebot/**/*.bats`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add tests/transmission-filebot/integration/test_triage_workflow.bats
git commit -m "test(transmission-filebot): add integration tests for triage workflow"
```

---

### Task 5: Final review, shellcheck, and deploy

**Step 1: Run shellcheck**

```bash
shellcheck app-setup/templates/transmission-done.sh
```

Expected: Clean

**Step 2: Run full test suite**

```bash
bats tests/transmission-filebot/**/*.bats
```

Expected: All tests PASS

**Step 3: Deploy updated trigger watcher** (if any changes)

The trigger watcher doesn't need changes — it already removes from Transmission and cleans up triggers when the done script returns 0, which is exactly what triage does.

**Step 4: Commit and push**

```bash
git add -A
git commit -m "feat(transmission-filebot): failure triage with categorized directories

When automated processing fails, classify the failure (already-in-plex,
no-match, or other) and move the torrent to a triage subdirectory under
Media/Torrents/triage/. Return success so the trigger watcher removes the
torrent from Transmission and cleans up the trigger file. Manual mode is
unaffected — failures still return non-zero for the operator to handle."
```
