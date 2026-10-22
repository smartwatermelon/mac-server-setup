# Plex Settings Watchdog

Monitors Plex server preferences against a curated golden configuration and sends email alerts when settings drift.

## Overview

The watchdog polls the Plex REST API every 5 minutes, comparing current settings against a golden config file. When a monitored setting changes, it sends an email with the drift details and instructions to accept or revert.

Each poll also asks Plex whether it can read its newest movie or episode on disk. See [Media access check](#media-access-check).

When Plex does not answer for 3 polls in a row, the watchdog restarts it. See [Automatic restart](#automatic-restart). Each poll also keeps the `/Users/Shared/PlexMediaServer` data link in place. See [Data directory link](#data-directory-link).

Two setup scripts deploy four components:

| Script                   | What it deploys                                       |
|--------------------------|-------------------------------------------------------|
| `msmtp-setup.sh`         | Shared email facility (Gmail SMTP via msmtp)          |
| `plex-watchdog-setup.sh` | Polling daemon, CLI tool, golden config, LaunchAgent  |

## Setup

Run from the `app-setup/` directory as admin:

```bash
# Step 1: Set up email (prompts for Gmail App Password)
./msmtp-setup.sh

# Step 2: Deploy the watchdog
./plex-watchdog-setup.sh
```

Both scripts will prompt for `MONITORING_EMAIL` if not already configured in `config/config.conf`.

### Prerequisites

- Plex running and accessible on `localhost:32400`
- Plex token available in `/Users/operator/.config/transmission-done/config.yml`
- Gmail account with 2FA enabled and an App Password created at <https://myaccount.google.com/apppasswords>

### What gets deployed

```text
~/.config/plex-watchdog/golden.conf     # Monitored settings and their expected values
~/.config/plex-watchdog/state.json      # Poll state, alert deduplication
~/.config/plex-watchdog/token           # Plex API token (mode 600)
~/.config/msmtp/config                  # Gmail SMTP config with embedded password (mode 600)
~/.local/bin/plex-watchdog              # Polling daemon
~/.local/bin/plex-watchdog-ctl          # CLI tool
~/Library/LaunchAgents/com.<host>.plex-watchdog.plist
```

## Usage

### Checking status

```bash
sudo -iu operator plex-watchdog-ctl status
```

```text
Setting                                  Golden          Current         Status
-------                                  ------          -------         ------
TranscoderCanOnlyRemuxVideo              0               0               OK

All monitored settings match golden configuration.
```

### When drift is detected

The watchdog sends an email like:

```text
Subject: [TILSIT] Plex setting drift detected

The following Plex settings have drifted from the golden configuration:

  TranscoderCanOnlyRemuxVideo
    Golden:  0
    Current: 1

To review:   ssh operator@tilsit plex-watchdog-ctl status
To accept:   ssh operator@tilsit plex-watchdog-ctl accept
To revert:   ssh operator@tilsit plex-watchdog-ctl revert
```

### Accepting changes

If the change was intentional, update the golden config to match:

```bash
sudo -iu operator plex-watchdog-ctl accept
```

This updates `golden.conf` with the current Plex values and clears the alert state.

### Reverting changes

Push the golden config values back to Plex:

```bash
sudo -iu operator plex-watchdog-ctl revert
```

This sends a PUT to the Plex API for each drifted setting and verifies the change took effect.

### Refreshing after Plex updates

Plex Media Server updates are applied manually (server version updates are
set to "Ask me" — see `docs/apps/plex-setup-README.md#server-update-policy`).
After you install one, new settings may appear. Refresh the golden config to pick them up:

```bash
sudo -iu operator plex-watchdog-ctl refresh
```

This preserves your monitored settings and their golden values, updates the commented-out reference section with current values, and warns if any monitored setting no longer exists.

## Golden config

The golden config at `~/.config/plex-watchdog/golden.conf` works like a commented nginx config. Uncomment a setting to start monitoring it:

```conf
# === Transcoder ===

# Disable video transcoding — only allow remuxing
TranscoderCanOnlyRemuxVideo: 0

# Use hardware-accelerated video codecs
# HardwareAcceleratedCodecs: 1

# Enable HDR tone mapping for transcoded streams
# TranscoderToneMapping: 1
```

Settings are organized into categories: Transcoder, Network, Library, Media Analysis, Security, Maintenance, DLNA, Cinema Trailers, Server Identity, and Internal.

The template is at `app-setup/templates/plex-golden.conf.template`. Values are populated from the live Plex server at setup time.

## How it works

### Poll cycle

The daemon runs once per LaunchAgent invocation (every 5 minutes):

1. Check the [data directory link](#data-directory-link)
2. Fetch Plex prefs XML via REST API. If that fails, count the failure; at 3 in a row, go to [automatic restart](#automatic-restart). If it works, reset the count (and send a recovery email if an alert went out).
3. Run the [media access check](#media-access-check). This runs before the fast path, so it runs on every poll.
4. **Fast path**: compare SHA-256 hash against stored hash — if unchanged, skip to heartbeat check (this is 99.9% of runs)
5. Parse XML with `xmllint` (handles entities like `&amp;` correctly)
6. Compare each monitored setting against golden config
7. Send email on new drift; send "resolved" email when drift clears
8. Save state atomically (temp file + mv). Only the drift keys are updated; the media check's keys are kept.
9. Log a heartbeat once per hour when there's no drift

### Media access check

Plex can answer its API while it cannot open a single file. On 2026-09-17 a
macOS privacy prompt blocked Plex's access to the NAS for 19 hours, and
nothing alerted (issue #199). So each poll asks Plex itself to check a file:

1. `GET /library/recentlyAdded` (first 10 items). Take the first `<Video>`
   (a movie or an episode). TV seasons come back as `<Directory>`, which has no
   file to check.
2. `GET /library/metadata/<ratingKey>?checkFiles=1`, with a 30 s timeout.
   Plex then checks the file on disk and sets `exists` and `accessible` on each
   `<Part>`.

The check fails on `exists="0"`, on `accessible="0"`, or when Plex does not
answer in 30 s (a blocked read can hang rather than fail). Two failures in a
row send one email, `[<host>] Plex cannot read media files`, with the title,
the file path and the result. The email repeats every 12 hours while the
failure lasts. When a check passes again, a `RESOLVED:` email goes out.

The check does not read the NAS itself. The watchdog runs as `/bin/bash`,
which is a different privacy (TCC) identity from Plex. It could read the NAS
while Plex is blocked, or the reverse.

These cases skip the check, log a `WARNING: media check skipped` line, and do
not count as a failure:

- no movie or episode in the recent list
- any other request error, for example a 404 when the item was removed
  between the two requests
- no `exists`/`accessible` attributes in the answer
- Plex unreachable. The "Plex server unreachable" alert covers that case, and
  an open media alert stays open (no false recovery email).

State: `.media_check_failures` and `.transitions.media_unreachable` in
`state.json`. The alert uses `alert_transition` from the shared alert library
(see `monitoring-README.md`).

### Automatic restart

On 2026-10-22 Plex deadlocked at 00:00:24 during its nightly database
maintenance. The Butler "Optimizing database" task finished, then an EPG
migration took every database session while the scheduled library scan
started. The process stayed up at 0% CPU and answered nothing (later only
HTTP 503) until it was killed at 08:39. It cannot recover by itself, so the
watchdog restarts it.

When the prefs request fails for 3 polls in a row (10 to 15 minutes), the
watchdog:

1. Sends SIGTERM to `Plex Media Server`, waits 10 s, then sends SIGKILL.
   Plex ignores SIGTERM even when healthy (on 2026-10-22 a fresh, working
   instance was still running 30 s after SIGTERM), so expect SIGKILL.
2. Stops the helper processes the same way (plug-ins, DLNA, tuner,
   `Plex EAE Service`). They outlive a killed server and keep their ports.
3. Checks the [data directory link](#data-directory-link).
4. Starts Plex with `open -a "/Applications/Plex Media Server.app"`, and with
   `PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR` removed from the environment
   (`open` passes its environment to the app).
5. Waits up to 90 s for `/identity` to answer, and emails the result.

It uses `open`, not the binary, because an app started by `open` is its own
launchd job. launchd stops a LaunchAgent's child processes when the agent
exits (see the header of the supervisor wrapper in
`podman-transmission-setup.sh`, about `vfkit`). It does not use
`launchctl kickstart` on the Plex LaunchAgent: `open` on a running app does
nothing, and a hung Plex is a running app.

Limits:

| Case | What happens |
| --- | --- |
| Restart works | Email `Plex was unresponsive and has been restarted`. The failure count is reset. |
| Plex does not answer within 90 s of the start | Email `Plex unreachable; automatic restart failed`. No more restarts until Plex answers. |
| Plex fails again less than 1 hour after a restart | Email `Plex still unreachable after an automatic restart`. No more restarts until Plex answers. |
| `~/.config/plex-watchdog/no-restart` exists | No restart. The plain `Plex server unreachable` email goes out once, at the threshold. |
| Prefs fail but `/identity` answers | No restart: Plex is up, and the usual cause is a revoked token. Email `Plex answers, but the watchdog cannot read its settings` once, at the threshold. During the 2026-10-22 hang `/identity` did not answer either. |
| Plex answers again after an alert | Email `RESOLVED: Plex server reachable again`. |

Turn restarts off for maintenance, and back on after:

```bash
sudo -u operator touch /Users/operator/.config/plex-watchdog/no-restart
sudo -u operator rm /Users/operator/.config/plex-watchdog/no-restart
```

State: `.consecutive_failures`, `.last_restart_epoch` (the last attempt) and
`.restart_gave_up` in `state.json`. A successful poll resets
`.consecutive_failures` and clears `.restart_gave_up`. Before 2026-10-22 only
Step 8 reset the count, and the fast path skips Step 8. After an outage with
unchanged prefs the count stayed high, so the next outage was never alerted.

To find out why Plex hung, read the Plex log
(`~operator/Library/Logs/Plex Media Server/Plex Media Server.log`, rotated to
`.1.log` to `.5.log`) for the time before the restart. Repeated `N threads are
waiting on db connections held by threads: …` lines mean the database
deadlock described above.

### Data directory link

`/Users/Shared/PlexMediaServer/Plex Media Server` must be a link to
`~operator/Library/Application Support/Plex Media Server`, where Plex keeps
its data.

Two things start Plex at operator login. The Plex app's own login item starts
it with its default data directory. The `com.<host>.plexmediaserver`
LaunchAgent runs `start-plex.sh`, which runs `open` with
`PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR=/Users/Shared/PlexMediaServer`. On
TILSIT the login item had always won, and the LaunchAgent's `open` only
reached the running app. On 2026-10-22 the LaunchAgent started Plex while that
path did not exist. Plex created a new, empty, unclaimed server there, and
every client saw no libraries. The same path is Plex's
`ButlerDatabaseBackupPath`, so the nightly database backups had never been
written ("Database backup path … does not exist, skipping").

With the link, both start paths and the backup path reach the real data.
`plex-setup.sh` creates the link (`ensure_plex_data_link`). Each watchdog poll
checks it:

- Missing: created. Logs `REPAIRED: created …`.
- A link to another place: repointed. Logs `REPAIRED: … pointed at …`.
- A real directory: not changed, because Plex may be running from it. Alert
  `Plex data directory link is broken` (key `data_link`, reminder every 12
  hours), and a recovery email when it is fixed.
- The real data directory does not exist: not checked. Logs a `WARNING`.

### Alert deduplication

The watchdog tracks which drifts have been emailed in `state.json`. It only emails when:

- A setting drifts to a value not previously alerted
- A previously-drifted setting returns to its golden value (sends a "resolved" email)

### Error handling

- **Plex unreachable**: logs a warning; after 3 consecutive failures (10 to 15 minutes) restarts Plex and emails the result, see [Automatic restart](#automatic-restart)
- **Plex cannot read media**: emails after 2 consecutive failed media checks (10 minutes), see [Media access check](#media-access-check)
- **msmtp failure**: logs error, continues monitoring (email failure doesn't block drift detection)
- **xmllint failure**: logs error, preserves last known good state

## Credential management

Credentials are embedded in config files with restrictive permissions (mode 600, owned by operator) rather than stored in macOS Keychain. This is because the operator keychain cannot be unlocked from non-interactive contexts like LaunchAgents. See [Keychain Management](../keychain-credential-management.md) for details on this project-wide pattern.

| Credential | Location | Protection |
| ----------- | ---------- | ------------ |
| Plex token | `~/.config/plex-watchdog/token` | mode 600, operator:staff |
| Gmail App Password | `~/.config/msmtp/config` | mode 600, operator:staff |

## Configuration reference

| Variable | Source | Description |
| ---------- | -------- | ------------- |
| `MONITORING_EMAIL` | `config/config.conf` | Email address for alert delivery |
| `SERVER_NAME` | `config/config.conf` | Used in email subject prefix (e.g., `[TILSIT]`) |
| `OPERATOR_USERNAME` | `config/config.conf` | User account that runs the watchdog |

## Logs

| Log | Location | Contents |
| ----- | ---------- | ---------- |
| Watchdog | `~/.local/state/plex-watchdog.log` | Drift events, heartbeats, errors |
| msmtp | `~/.local/state/msmtp.log` | Email send attempts and results |
| Setup | `~/.local/state/<host>-msmtp-setup.log` | msmtp installation log |
| Setup | `~/.local/state/<host>-plex-watchdog-setup.log` | Watchdog deployment log |

All logs are rotated by logrotate (entries in `config/logrotate.conf`).

## Troubleshooting

**Watchdog not running**: Check if the LaunchAgent is loaded:

```bash
sudo launchctl print gui/$(id -u operator)/com.<hostname>.plex-watchdog
```

If state is "not running", it will fire on the next 5-minute interval. To trigger immediately:

```bash
sudo -iu operator bash ~/.local/bin/plex-watchdog
```

**No email received**: First look for `ERROR` lines in the watchdog log
(`/Users/operator/.local/state/plex-watchdog.log`). A send that fails before
msmtp starts (for example, msmtp not found) leaves no entry in msmtp's log. Then
check msmtp's log:

```bash
sudo tail -20 /Users/operator/.local/state/msmtp.log
```

Common issues: Gmail App Password expired or revoked, 2FA disabled on the Google account.
See `monitoring-README.md` for the shared alert library and how to send a test
alert under launchd's PATH.

**Status shows drift on fresh deploy**: This shouldn't happen since the golden config is generated from current values at setup time. Run `plex-watchdog-ctl refresh` to regenerate.

**"xmllint not found"**: Should be pre-installed on macOS. Verify with `which xmllint`.

## Testing

61 BATS tests in `tests/plex-watchdog.bats`, and 8 in `tests/plex-data-link.bats` for the setup side of the data link:

```bash
bats tests/plex-watchdog.bats
bats tests/plex-data-link.bats
```

Tests cover golden config parsing, XML parsing with entity handling, drift detection, state management, atomic writes, token file operations, full poll cycles under launchd's PATH, the media access check, automatic restart, and the data directory link. The curl mock answers each Plex URL from a fixture in `tests/fixtures/`. No live Plex server is required.

`pgrep`, `pkill`, `open` and `sleep` are mocked in every test, not only the restart tests. The tests also run on the Plex server itself, where a real `pkill` would stop the real Plex.

Integration test tracking: #87 (email delivery), #88 (live Plex end-to-end), #89 (LaunchAgent/permissions).
