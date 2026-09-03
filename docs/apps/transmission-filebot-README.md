# Transmission-FileBot Media Processing Pipeline

> Imported from `smartwatermelon/transmission-filebot` (archived 2026-04-03).
> For full git history, see the archived repository.

This file provides operational reference for the Transmission-FileBot
media processing pipeline.

> **Note**: Common protocols and standards are in `~/.claude/CLAUDE.md` (global
> configuration). This file contains only project-specific additions and modifications.
>
> **For reviewers**: The global configuration file may not be accessible during review.
> This is expected - the global file provides common standards across all projects.

## Project Overview

Transmission-Plex Media Manager: A bash-based automation system that integrates Transmission BitTorrent client with FileBot and Plex Media Server. When downloads complete, it automatically cleans, organizes, renames media files, and triggers Plex library updates.

**Stack**: Pure Bash 5.x, strict POSIX compliance, zero external frameworks, comprehensive BATS test coverage

## Architecture

### Core Components

1. **transmission-done.sh** - Main processing script (1,390 lines)
   - Entry point triggered by Transmission on download completion
   - Orchestrates cleanup → FileBot processing → Plex notification
   - Contains inline test suite (run with `TEST_MODE=true`)
   - Triple-mode design: production execution, inline test harness, BATS test support

2. **install.sh** - Interactive installation wizard (478 lines)
   - Dependency checking and installation
   - Plex server validation and token authentication
   - Auto-detects Plex library paths and presents as menu
   - Generates `~/.config/transmission-done/config.yml`
   - Creates symlink at `~/.local/bin/transmission-done`

3. **run_tests.sh** - BATS test runner (122 lines)
   - Executes comprehensive test suite
   - Auto-installs bats-core if missing
   - Runs unit tests (test/unit/*.bats)
   - Runs integration tests (test/integration/*.bats)
   - 114 total tests covering all functionality

4. **config.yml** - YAML configuration
   - Located at `~/.config/transmission-done/config.yml` (production)
   - Or `./config.yml` (local development override)
   - Contains paths, Plex credentials, logging settings

### Test Infrastructure

**Structure**:

```text
test/
├── test_helper.bash           - Shared test utilities and assertions
├── unit/                      - Unit tests (84 tests)
│   ├── test_error_logging.bats
│   ├── test_file_safety.bats
│   ├── test_filebot.bats
│   ├── test_mode_detection.bats
│   ├── test_plex_api.bats
│   └── test_type_detection.bats
└── integration/               - Integration tests (30 tests)
    ├── test_manual_mode.bats
    ├── test_movie_workflow.bats
    └── test_tv_workflow.bats
```

**Test modes**:

- `TEST_MODE=true` - Inline tests in transmission-done.sh
- `TEST_RUNNER=true` - BATS test execution mode
- `./run_tests.sh` - Runs full BATS suite (114 tests)

### Processing Flow

```text
Transmission download completes
  ↓
transmission-done.sh triggered with TR_TORRENT_* env vars
  ↓
Config validation (read_config)
  ↓
Cleanup phase (cleanup_torrent)
  - Removes .nfo, .exe, .txt files
  ↓
Media detection (process_media)
  - Pattern matching: S01E01 → TV, (19|20)XX → Movie
  - Tries most likely type first, falls back if needed
  ↓
FileBot processing
  - TV: TheTVDB database → {plex} format
  - Movie: TheMovieDB database → {plex} format
  - Actions: move, artwork, metadata, subtitles
  ↓
Plex notification (trigger_plex_scan)
  - Section 1 (movies) or Section 2 (TV shows)
  - Retry logic: 3 attempts, 5s delays
  ↓
Cleanup empty directories
```

### Key Design Patterns

- **Strict mode everywhere**: `set -euo pipefail` with `IFS=$'\n\t'`
- **Test mode injection**: Functions check `TEST_MODE` flag and mock external calls
- **Config precedence**: Local ./config.yml → User ~/.config/transmission-done/config.yml
- **Retry with exponential backoff**: `plex_make_request` supports configurable retries
- **Pattern-based media type detection**: Filename analysis before attempting FileBot processing
- **stdout/stderr separation**: All user messages to stderr, only data to stdout

### Duplicate handling and quality upgrades

FileBot runs with `--conflict auto`, which **skips** rather than overwrites when
a download renames onto a path that already holds a file. The download is then
classified `already-in-plex` by `classify_failure()` and moved to
`triage/already-in-plex/`. Nothing is overwritten and nothing is lost.

`media-compare.sh` decides which of the two copies is better, so that the
download is not left sitting in triage waiting for someone to compare them by
hand (issue #178). It is a sourced library, like `pia-port-guard.sh`, and is
optional: when the file is absent, `transmission-done.sh` keeps its previous
behaviour of triaging every duplicate.

**Pairing.** The download and the library file it collides with are read from
FileBot's own conflict message, which names both paths:

```text
[AUTO] Skipped [SOURCE] because [DEST] already exists
[IMPORT] Destination file already exists: DEST (SOURCE)
```

FileBot has already matched the download to a title and worked out the exact
destination, so taking the pair from its output is authoritative. Guessing it
back from filenames is not. Anything unparsable yields no pair, and the
download goes to triage as before.

**Comparison ladder.** `ffprobe` (from the `ffmpeg` formula, already in
`config/formulae.txt`) reads the attributes. The first rule that separates the
two files decides:

1. Identical bytes → keep (a size check first, then `cmp`)
2. Video resolution, as width × height → more pixels wins
3. Video bitrate → higher wins, past a 10% noise margin
4. Audio channels → more wins
5. File size → larger wins, as a last resort only

**Everything uncertain resolves to keep.** A wrong "replace" destroys the better
copy; a wrong "keep" costs disk space and a triage entry. Those are not
symmetric, so an unreadable file, a probe timeout, or a tie on every rule all
leave the library alone.

**Replacement** is ordered so the library is never short an episode: the
incumbent moves to `triage/quarantine/` first, then the candidate moves into its
place, and a failure of the second move restores the first. Quarantined files
are pruned after `MEDIA_COMPARE_RETENTION_DAYS` (default 14).

A Plex rescan fires only when something was actually replaced — this code runs
on every duplicate, and a scan with nothing to find is wasted work.

**Configuration** (environment variables, all with working defaults):

| Variable | Default | Purpose |
| --- | --- | --- |
| `MEDIA_COMPARE_DRY_RUN` | `false` | Log decisions, change nothing |
| `MEDIA_COMPARE_RETENTION_DAYS` | `14` | Quarantine lifetime |
| `MEDIA_COMPARE_BITRATE_MARGIN` | `10` | Percent difference before bitrate decides |
| `MEDIA_COMPARE_TIMEOUT` | `30` | Seconds before an ffprobe read is abandoned |
| `MEDIA_COMPARE_FFPROBE` | `${HOMEBREW_PREFIX}/bin/ffprobe` | Probe binary |

Tests live in `tests/media-compare.bats` and probe real media synthesised by
`ffmpeg` rather than mocking `ffprobe`, so a wrong `-show_entries` spec or a
misread field name fails the suite instead of passing it.

### Critical Environment Variables

When Transmission invokes the script, it provides:

- `TR_TORRENT_DIR` - Download location (required)
- `TR_TORRENT_NAME` - Torrent name (required)
- `TR_TORRENT_HASH`, `TR_TORRENT_ID` - Identifiers
- `TR_TIME_LOCALTIME` - Completion timestamp
- Limited `PATH` - Script explicitly adds `/usr/local/bin:/opt/homebrew/bin`
- No `HOME` variable - Script uses `config.yml:paths.default_home` fallback

The script's `validate_environment` function enforces these requirements.

## Development Commands

### Testing

```bash
# Run full BATS test suite (110 tests)
./run_tests.sh

# Run only unit tests
bats test/unit/*.bats

# Run only integration tests
bats test/integration/*.bats

# Run inline tests (legacy, use run_tests.sh instead)
TEST_MODE=true ./transmission-done.sh

# Test specific scenario with mocked environment
TR_TORRENT_DIR=/path/to/test \
TR_TORRENT_NAME="Test.Show.S01E01" \
TEST_MODE=true \
./transmission-done.sh
```

### Installation & Configuration

```bash
# Run installation wizard (checks deps, validates Plex, generates config)
./install.sh

# Validate config file syntax
yq eval '.' ~/.config/transmission-done/config.yml

# Test Plex connectivity
curl -H "X-Plex-Token: YOUR_TOKEN" http://localhost:32400/identity
```

### Linting

```bash
# Check shell script quality (must be clean, no disable directives)
shellcheck transmission-done.sh install.sh run_tests.sh

# Check test scripts
shellcheck test/test_helper.bash
shellcheck test/unit/*.bats
shellcheck test/integration/*.bats

# Verify executable permissions
chmod +x transmission-done.sh install.sh run_tests.sh
```

### Debugging

```bash
# Watch processing logs in real-time
tail -f ~/.local/state/transmission-processing.log

# Inspect Transmission environment (add to script temporarily)
env > /tmp/transmission-env.log

# Verify Plex library sections
curl -H "X-Plex-Token: YOUR_TOKEN" http://localhost:32400/library/sections
```

## Configuration File Structure

```yaml
version: 1.0
paths:
  default_home: /Users/username  # HOME fallback for Transmission context
plex:
  server: http://localhost:32400  # Plex server URL
  token: abc123xyz                # Obtained during install.sh
  media_path: /path/to/plex/media # Target directory for organized media
logging:
  file: .local/state/transmission-processing.log  # Relative to home
  max_size: 10485760  # Bytes (10MB) - triggers log rotation
```

## Important Constraints

### Bash Script Rules (from Andrew's guidelines)

1. **GNU Bash 5.x compatible only** - No Bash 3.x fallbacks
2. **All shellcheck issues must be resolved** - Errors, warnings, AND info
3. **NEVER use `# shellcheck disable` directives**
4. **Critical**: Never use `((var++))` with `set -e` - when var=0, this exits silently. Use `((var += 1))` instead
5. **Remove unused variables completely** - Don't suppress with `_var` or shellcheck disables
6. **stdout/stderr discipline**: User messages to stderr (`>&2`), only data to stdout for capture with `$(...)`

### Testing Philosophy

- Tests are NOT optional - every behavior change requires test updates
- Test mode mocks external dependencies (Plex API, FileBot, df, stat)
- Tests run in isolated temp directories (`TEST_TEMP_DIR`)
- BATS tests use custom assertions in test_helper.bash
- Expected: 114 tests passing (84 unit + 30 integration)

### Plex API Hardcoded Sections

The script assumes:

- Section ID 1 = Movies
- Section ID 2 = TV Shows

If your Plex has different IDs, modify `trigger_plex_scan` function.

### FileBot Requirements

- Licensed version required (free trial won't work for automation)
- Must be in PATH or at `/usr/local/bin/filebot` or `/opt/homebrew/bin/filebot`
- Format string `{plex}` is Plex-optimized naming convention
- Database selection: `TheTVDB` for TV, `TheMovieDB` for movies

## NAS Storage Configuration

When media files are stored on a NAS (e.g., Synology) mounted via NFS, the NFS export settings are critical for FileBot to successfully move files.

### NFS Export Requirements

The NFS rule on the NAS shared folder must be configured as follows:

| Setting | Required Value | Why |
|---------|---------------|-----|
| Privilege | **Read/Write** | FileBot needs to move files and create directories |
| Squash | **Map all users to admin** | See UID mapping below |
| Security | **sys** | Standard AUTH_SYS authentication |
| Enable asynchronous | **Yes** | Performance |
| Allow non-privileged ports | **Yes** | Required for macOS NFS clients |
| Allow subfolder access | **Yes** | Media lives in subdirectories |

### UID Mapping Explained

NFS permission checks happen **server-side**, not client-side. The macOS `noowners` mount option only affects local display — the NAS still enforces permissions based on the UID it receives.

The challenge: macOS user UIDs (typically 501, 502) don't match Synology user UIDs (admin = 1024, other users = 1025+). With "No mapping" squash, the NAS receives the macOS UID and checks it against file ownership — which will fail because no Synology user has UID 501/502.

**"Map all users to admin"** solves this by mapping all NFS requests to the Synology admin user (UID 1024), which has full access to the shared folder.

### Directory Permissions

With "Map all users to admin" squash, **directories must be `rwxrwxrwx` (777)**. This is because:

- All NFS requests arrive as UID 1024 (Synology admin)
- Files/directories may be owned by different UIDs depending on what created them
- The admin user needs write access via the "other" permission bits
- This is acceptable for a media server on a firewalled LAN

If directories become non-writable (e.g., after an accidental `chmod 755`), fix from the NAS via SSH:

```bash
# On the Synology (requires sudo even for admin user):
sudo find /volume1/MediaShare/Media/ -type d -exec chmod 777 {} +
```

**Do NOT attempt `chmod` from the NFS client** — it will fail silently or with "Operation not permitted". Always SSH into the NAS.

### NFS Attribute Cache

After changing permissions or ownership on the NAS, the NFS client will serve stale metadata from its attribute cache. To pick up changes:

```bash
# Unmount and remount the NFS share:
sudo diskutil unmount force /path/to/mount
sudo mount -t nfs -o noowners nas.local:/volume1/share /path/to/mount
```

### Synology ACLs

Synology DSM defaults to "Windows ACL" mode on shared folders, which adds an ACL layer on top of UNIX permissions. The `+` suffix in `ls -la` output on the NAS indicates ACLs are present. These ACLs can **deny writes even when UNIX permissions allow them**. If experiencing unexplained permission issues, check the shared folder's permission model in DSM Control Panel → Shared Folder → Edit → Advanced.

### Containerized Transmission Setup

When Transmission runs in a container (e.g., podman/haugene), it cannot directly invoke macOS scripts. The `transmission-trigger-watcher.sh` daemon bridges this gap:

1. Container writes trigger files to a host-mounted directory on download completion
2. The watcher daemon polls for trigger files every 60 seconds
3. On finding a trigger, it maps the container's `/data` path to the macOS NFS mount path
4. It invokes `transmission-done.sh` with the correct `TR_TORRENT_*` environment variables
5. Dead-letter handling: after 5 failures, triggers are moved to `.dead` for manual inspection

### VirtioFS NFS Access and Full Disk Access

The Podman VM shares host directories into the container via VirtioFS. For NFS-backed
paths (like `/Users/operator/.local/mnt/DSMedia`), macOS enforces TCC/sandbox
restrictions on the `com.apple.Virtualization.VirtualMachine` XPC service that
handles VirtioFS I/O.

**Symptom:** Container shows "Operation not permitted" on `/data/` while the
host NFS mount works fine. `stat()` succeeds but `opendir()` fails (EPERM).
Other VirtioFS mounts to local paths (`/scripts`, `/config`, `/watch`) work.

**Root cause:** The Virtualization.framework XPC service lacks Full Disk Access
(FDA). On startup, VirtioFS opens directory handles that work for days/weeks.
When the NFS server's idle timeout expires those handles, the XPC service
must re-open them — and gets blocked by the sandbox.

**Fix:** Grant FDA to the Virtualization.framework binary via System Settings >
Privacy & Security > Full Disk Access:

```text
/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/
  com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/
  com.apple.Virtualization.VirtualMachine
```

**Defense in depth:** The supervision loop in `podman-machine-start.sh` includes
a `/data/` read health check. If `/data/` is inaccessible for 3 consecutive
checks (15 minutes at 300s intervals), the loop automatically cycles the Podman
VM and recreates the container to obtain fresh VirtioFS handles.

> **Note:** This is the same class of issue as the LaunchAgent NFS `opendir()`
> EPERM (fixed 2026-04-04 by granting FDA to `/bin/bash`). macOS Tahoe
> enforces NFS access restrictions at the kernel level for any process
> without FDA, including system XPC services.

### "podman-remote would like to access files on a network volume"

A separate grant (`kTCCServiceSystemPolicyNetworkVolumes`, per-user) is keyed
on the `podman-remote` that ran `podman machine start`, because macOS holds
that process responsible for the VM's VirtioFS access. Homebrew's
`podman-remote` changes path and code hash on every `brew upgrade`, so the
grant died daily and the supervisor blocked on the prompt after every VM
start. The supervisor now runs podman from a stably-signed mirror at
`/usr/local/stable/podman/bin`, maintained by the daily upgrade job. Full
write-up, evidence and operations: `docs/apps/stable-signing-README.md`.

### Every podman call is bounded by a timeout

The supervision loop is single-threaded: it calls `ensure_machine`,
`ensure_container`, and `check_data_access` synchronously. A podman command
that never returns therefore freezes the whole loop — no health checks, no
recovery, no log output.

That is not hypothetical. On 2026-08-16 the `/data/` health check correctly
detected a VirtioFS failure and triggered its documented recovery. The
recovery's `podman run -d` was issued through a Homebrew-upgraded 6.1.0 CLI
while a leftover 6.0.2 `gvproxy`, orphaned by the upgrade seven days earlier,
still held the machine's socket paths. That `podman run` hung and was still
running 27 hours later. Nothing was listening on port 9091 the entire time.

Two changes close that hole:

- **`podman_t` wraps every podman invocation in `timeout(1)`.** Command
  timeouts default to 60s, machine operations to 180s; override with
  `PODMAN_CMD_TIMEOUT` / `PODMAN_MACHINE_TIMEOUT`. A timeout is logged as
  `TIMEOUT: 'podman run -d' exceeded 180s and was killed` — deliberately
  distinct from an ordinary failure, because not being able to tell a hang
  from a failure is what made the outage take 27 hours to spot. The caller
  treats a timeout like any other failure and retries next cycle.

  `timeout(1)` is required, not optional. It comes from `coreutils`, which
  `config/formulae.txt` installs. If it is missing the loop exits at startup
  with instructions rather than running unsupervised. A `perl -e 'alarm'`
  fallback was tried and rejected: SIGALRM kills perl but leaves the command's
  children running, so they hold the command-substitution pipe open and
  `state=$(podman_t ... machine inspect)` blocks forever regardless.

- **`reap_machine_helpers` verifies the helper processes actually exited.**
  `podman machine stop` returning 0 does not mean `gvproxy` and `vfkit` are
  gone — the 6.0.2 `gvproxy` in the August incident survived for seven days.
  Before any machine start, and after the recovery path's machine stop, any
  surviving helper whose argv names `transmission-vm` gets SIGTERM, then
  SIGKILL if it ignores that. The match is scoped to the machine name so other
  podman machines on the host are untouched.

**Podman version drift is the underlying trigger.** A `brew upgrade` replaces
the CLI without restarting the running VM or its helpers. The timeout and reap
changes make the resulting mismatch recoverable rather than fatal; they do not
prevent the drift itself. After upgrading podman, cycle the machine:

```bash
launchctl kickstart -k "gui/$(id -u)/com.tilsit.podman-transmission-vm"
```

## Common Gotchas

1. **PATH issues**: Transmission runs scripts with minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). Script adds `/usr/local/bin:/opt/homebrew/bin` explicitly for Homebrew tools.

2. **Config location**: Script checks `./config.yml` first (development), then `~/.config/transmission-done/config.yml` (production). Keep secrets out of repo - use config.yml.template.

3. **Log rotation**: Happens on every script run if log exceeds `max_size`. Old log moved to `.log.old` (overwrites previous).

4. **Media type detection**: Pattern matching is case-insensitive but looks for specific formats. If filename has neither TV episode markers nor year, script tries movie first, then TV as fallback.

5. **Plex token exposure**: config.yml contains plaintext token. NEVER commit real config.yml (use config.yml.template).

6. **Test mode environment**: `TEST_RUNNER=true` bypasses Transmission variable validation during BATS test execution. Don't use in production.

7. **Command substitution**: Use `var=$(function)` to capture stdout. Functions must send user messages to stderr (`>&2`), not stdout, to avoid contamination.

8. **FileBot `[MOVE]` output parsing**: FileBot uses the same `[MOVE]` prefix for both successful and failed moves. A successful move logs `[MOVE] from [X] to [Y]`, while a failed move logs `[MOVE] from [X] to [Y] failed due to I/O error [...]`. When counting moved files, always exclude lines containing "failed" — use `grep "\[MOVE\]" | grep -vc "failed"`, not `grep -c "\[MOVE\]"`.

9. **NFS permission errors appear as FileBot I/O errors**: If FileBot reports `Access Denied` with details like `(rwxrwxrwx 502:20 file.mkv -> r-xr-xr-x 502:20 Season 02)`, the issue is NAS-side directory permissions, not FileBot configuration. See the NAS Storage Configuration section.

## Dependencies

All must be available in PATH:

- **yq** (`brew install yq`) - YAML parsing, required for config
- **xmlstarlet** (`brew install xmlstarlet`) - XML parsing for Plex API responses
- **jq** (`brew install jq`) - JSON parsing for Plex API authentication
- **curl** (pre-installed on macOS) - HTTP requests
- **bats-core** (`brew install bats-core`) - Test framework
- **filebot** (licensed) - Media organization engine
- **find**, **grep**, **stat**, **df** - Standard Unix utilities

The `install.sh` wizard checks and can auto-install missing dependencies.

## Transmission Integration

Configure in Transmission:

1. Preferences → Downloading tab
2. Check "Run script when download completes"
3. Enter symlink path: `~/.local/bin/transmission-done`
   (or direct path: `/path/to/transmission-done.sh`)

Ensure script is executable: `chmod +x transmission-done.sh`

## Security Notes

- **config.yml contains sensitive data**: Plex token grants full server access
- **Git ignore prevents accidental commits**: config.yml in .gitignore
- **Template provided**: config.yml.template shows structure without secrets
- **Token validation**: install.sh validates token before saving
- **Symlink safety**: install.sh refuses to overwrite regular files, only symlinks

## CI/CD Pipeline

GitHub Actions workflow (`.github/workflows/test.yml`):

- **BATS Unit Tests** - Runs test/unit/*.bats
- **BATS Integration Tests** - Runs test/integration/*.bats
- **Inline Tests** - Runs TEST_MODE=true ./transmission-done.sh
- **ShellCheck Validation** - Lints all shell scripts
- **Test Summary** - Aggregates results

All 114 tests must pass before merging PRs.

## Recent Major Changes

- **PR #23**: Fixed false success detection — FileBot `[MOVE] ... failed` lines were counted as successes, masking I/O errors (e.g., NFS permission denied)
- **PR #21**: Corrected torrent path and Plex scan section detection
- **PR #11**: Installer now queries Plex for library paths, improved symlink handling
- **PR #10**: Fixed stdout/stderr separation in install.sh (critical bug fix)
- **PR #8**: Simplified test runner to only require bats-core
- **PR #2**: Implemented comprehensive BATS test suite
