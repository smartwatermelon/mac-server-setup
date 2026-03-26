# Plex Settings Watchdog

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Monitor Plex server preferences against a curated "golden" configuration. Alert via email when settings drift. Provide a CLI tool to accept or revert changes.

**Motivation:** On 2026-03-25, `TranscoderCanOnlyRemuxVideo` was changed from `0` to `1` (cause unknown), breaking Plex Web playback with "not enough power to play video." This went undetected until a user reported it. A watchdog would have caught it within 5 minutes.

**Architecture:** Four components deployed by two setup scripts:

1. **`msmtp`** — lightweight SMTP relay configured for Gmail. Shared email facility, reusable by any future monitoring script. Deployed by its own setup script.
2. **`plex-watchdog`** — polling daemon (LaunchAgent, every 5 minutes). Fetches current Plex prefs via REST API, compares against golden config, emails on drift.
3. **`plex-watchdog-ctl`** — CLI tool with `status`, `accept`, `revert`, and `refresh` commands.
4. **`golden.conf`** — curated desired-state config with commented reference of all available Plex settings.

**Tech Stack:** bash, curl, xmllint (ships with macOS), msmtp, jq, launchd

**Known limitation:** The LaunchAgent uses `LimitLoadToSessionType: Aqua`, meaning the watchdog only runs when a GUI session is active. If the server is operating headless (SSH-only, no GUI login), the watchdog will not start. This is consistent with all other LaunchAgents in this repo.

---

## File Layout

### In the repo (source)

```
app-setup/msmtp-setup.sh                      # shared email facility setup (standalone)
app-setup/plex-watchdog-setup.sh               # watchdog setup script
app-setup/templates/plex-watchdog.sh           # polling daemon template
app-setup/templates/plex-watchdog-ctl.sh       # CLI tool template
app-setup/templates/plex-golden.conf.template  # golden config template
```

### On the server (deployed)

```
~/.config/plex-watchdog/golden.conf            # active golden config
~/.config/plex-watchdog/state.json             # poll state, alert dedup, failure counter
~/.config/plex-watchdog/token                  # Plex token (mode 600, embedded at setup)
~/.config/msmtp/config                         # SMTP config with embedded password (mode 600)
~/.local/bin/plex-watchdog                     # polling script
~/.local/bin/plex-watchdog-ctl                 # CLI tool
~/.local/state/plex-watchdog.log               # log file (rotated by logrotate)
~/.local/state/msmtp.log                       # msmtp log (rotated by logrotate)
~/Library/LaunchAgents/com.<host>.plex-watchdog.plist
```

> **Credential pattern:** This project embeds credentials in config files with
> restrictive permissions (mode 600) rather than using macOS Keychain at runtime.
> The operator keychain cannot be unlocked from non-interactive contexts
> (LaunchAgents, `sudo -iu`). See `docs/keychain-credential-management.md`.

---

## Task 1: Set up msmtp as a shared email facility

This is a standalone setup script (`app-setup/msmtp-setup.sh`) so that future monitoring scripts can reuse email without depending on the Plex watchdog.

**Files:**

- Create: `app-setup/msmtp-setup.sh`

### Step 1: Install msmtp and jq via Homebrew

Skip if already installed. Use existing Homebrew patterns from the codebase.

### Step 2: Configure msmtp for Gmail

- Check macOS keychain for existing `msmtp-gmail` credential
- If not found:
  - Display: "To create a Gmail App Password, visit: <https://myaccount.google.com/apppasswords>"
  - Display: "Note: App Passwords require 2FA to be enabled on your Google account."
  - Prompt for the app password
  - Store in keychain: `security add-generic-password -a "$MONITORING_EMAIL" -s msmtp-gmail -w "$APP_PASSWORD"`
- Write `~/.config/msmtp/config`:

  ```
  defaults
  auth           on
  tls            on
  tls_trust_file /etc/ssl/cert.pem
  logfile        ~/.local/state/msmtp.log

  account        gmail
  host           smtp.gmail.com
  port           587
  from           noreply@<HOSTNAME>
  user           <MONITORING_EMAIL>
  passwordeval   security find-generic-password -s msmtp-gmail -w

  account default : gmail
  ```

- Set permissions: `chmod 600 ~/.config/msmtp/config`

**Note on `from` address:** Gmail will override the `from` field with the authenticated sender address. The `noreply@<HOSTNAME>` value is cosmetic and will not appear in delivered mail. This is documented here so it is not surprising later. If the SMTP provider changes from Gmail, the `from` address will need to be a valid domain.

### Step 3: Send test email

Send a test email to `MONITORING_EMAIL` with subject `[<HOSTNAME>] Monitoring email configured`. Fail setup if delivery fails.

### Step 4: Add log rotation entries

Add `*-msmtp.log` to `config/logrotate.conf` alongside the existing log patterns.

---

## Task 2: Create the golden config template

**Files:**

- Create: `app-setup/templates/plex-golden.conf.template`

### Step 1: Define the template structure

The template contains category groupings, section headers, and inline comments, but no values — values are populated at setup time by reading from the live Plex server.

Format (`key: value` with `#` comments — this is NOT shell-sourceable, do not use `KEY="value"` format):

```conf
# Plex server settings reference:
# https://support.plex.tv/articles/201105343-advanced-hidden-server-settings/
#
# Uncomment a setting to monitor it. The watchdog will alert if Plex's
# current value differs from the value listed here.
#
# Format: SettingName: value
# Lines starting with # are ignored. Only uncommented lines are monitored.
#
# Run `plex-watchdog-ctl refresh` after a Plex update to discover new settings.

# === Transcoder ===

# Disable video transcoding — only remux (repackage) containers
TranscoderCanOnlyRemuxVideo: 0

# Video quality preset for transcoding (0 = automatic)
# TranscoderQuality: __VALUE__

# Seconds of video to buffer ahead during transcoding
# TranscoderThrottleBuffer: __VALUE__

# Use hardware-accelerated video decoding
# HardwareAcceleratedCodecs: __VALUE__

# Use hardware-accelerated video encoding
# HardwareAcceleratedEncoders: __VALUE__

# Minimum CRF for H.264 encoding (lower = higher quality, 0-51 scale)
# TranscoderH264MinimumCRF: __VALUE__

# H.264 encoding speed preset
# TranscoderH264Preset: __VALUE__

# Enable HDR tone mapping for transcoded streams
# TranscoderToneMapping: __VALUE__

# Maximum simultaneous transcodes (0 = unlimited)
# TranscodeCountLimit: __VALUE__

# === Network ===

# Max upload rate per WAN stream in kbps (0 = unlimited)
# WanPerStreamMaxUploadRate: __VALUE__

# Max simultaneous streams per remote user (0 = unlimited)
# WanPerUserStreamCount: __VALUE__

# === Library ===

# Percentage watched before marking as played (0-100)
# LibraryVideoPlayedThreshold: __VALUE__

# === Security ===

# Allow media deletion from Plex UI (0 = disabled, 1 = enabled)
# allowMediaDeletion: __VALUE__

# Allow sharing with other Plex users
# allowSharing: __VALUE__

# === Internal / feature flags (not recommended to monitor) ===
# These are Plex-internal settings that change between versions.
# Monitoring them will likely produce noise on Plex updates.
#
# (populated at setup time by plex-watchdog-setup.sh)
```

---

## Task 3: Create the polling daemon

**Files:**

- Create: `app-setup/templates/plex-watchdog.sh`

### Step 1: Implement the poll cycle

The script runs once per invocation (LaunchAgent calls it every 5 minutes via `StartInterval`):

1. **Read Plex token** from macOS keychain: `security find-generic-password -s plex-watchdog-token -w`
2. **Fast-path hash check** — fetch prefs XML via `curl -s "http://localhost:32400/:/prefs?X-Plex-Token=$TOKEN"`, compute `shasum` of the response, compare against the hash stored in `state.json`. If unchanged, skip to step 7 (no parsing needed on the happy path — this is 99.9% of runs).
3. **Parse prefs with xmllint** — on hash mismatch, use `xmllint --xpath` to extract `id` and `value` attributes from each `Setting` element. This handles XML entities (`&amp;`, `&quot;`, etc.) correctly. Do NOT use grep/awk/sed to parse XML.
4. **Load golden config** — read `golden.conf`, skip comment lines and blank lines, parse `key: value` pairs
5. **Compare** — for each monitored setting (uncommented in golden.conf), check current value against golden value
6. **Handle drift:**
   - **New drift detected** (setting drifted, not yet in `state.json` alerts or `alerted_value` differs):
     - Log: `DRIFT DETECTED: TranscoderCanOnlyRemuxVideo golden=0 current=1`
     - Send email via `msmtp` to `MONITORING_EMAIL`:
       - Subject: `[<HOSTNAME>] Plex setting drift detected`
       - Body: what changed, golden vs current value, and instructions:

         ```
         The following Plex settings have drifted from the golden configuration:

           TranscoderCanOnlyRemuxVideo
             Golden:  0
             Current: 1

         To review:   ssh operator@<hostname> plex-watchdog-ctl status
         To accept:   ssh operator@<hostname> plex-watchdog-ctl accept
         To revert:   ssh operator@<hostname> plex-watchdog-ctl revert
         ```

     - Update `state.json` alert entry for this setting
   - **Previously-drifted setting returns to golden on its own** — clear from alert state, log it, send a "resolved" email
   - **Already alerted, same drift** — do not re-email. Log nothing (quiet).
7. **Save state** — update `state.json` with current values of monitored settings, response hash, and timestamp. Write to temp file then `mv` (atomic).
8. **Heartbeat** — once per hour (check `last_heartbeat` in state file), log a single `OK: N settings monitored, no drift` line. Otherwise, silence on no-drift runs.

### State file schema

Single file at `~/.config/plex-watchdog/state.json`:

```json
{
  "last_poll": "2026-03-25T14:30:00Z",
  "last_heartbeat": "2026-03-25T14:00:00Z",
  "response_hash": "a1b2c3d4e5...",
  "consecutive_failures": 0,
  "settings": {
    "TranscoderCanOnlyRemuxVideo": {
      "current": "1",
      "alerted": true,
      "alerted_value": "1"
    }
  }
}
```

The `settings` map is rebuilt from scratch on each successful poll. Alert entries are preserved across polls to prevent re-emailing. The `alerted_value` field ensures that if a setting drifts to value A (alerted), then drifts further to value B, a new alert is sent.

### Error handling

- **Plex unreachable** (curl fails): increment `consecutive_failures` in state. Log warning. Email only after 3 consecutive failures (15 minutes). On success, reset `consecutive_failures` to 0. This avoids false alerts during Plex restarts/updates.
- **golden.conf missing or empty**: log error, exit 1.
- **msmtp fails**: log error with msmtp exit code, continue monitoring. Do not block drift detection on email failure.
- **xmllint fails**: log error (possible Plex API change), do not update state (preserves last known good state).

---

## Task 4: Create the CLI tool

**Files:**

- Create: `app-setup/templates/plex-watchdog-ctl.sh`

All commands read the Plex token from macOS keychain (`plex-watchdog-token`) and parse XML with `xmllint`.

### Step 1: Implement `status` command

Fetch current Plex prefs, load golden config, display a table:

```
Setting                       Golden    Current   Status
TranscoderCanOnlyRemuxVideo   0         1         DRIFTED
HardwareAcceleratedCodecs     1         1         OK
```

Exit code 0 if all OK, exit code 1 if any drift.

### Step 2: Implement `accept` command

For each drifted setting:

- Read golden.conf into memory
- Update the value for the drifted setting(s)
- Write to `golden.conf.tmp`, then `mv golden.conf.tmp golden.conf` (atomic)
- Clear alert entries from `state.json` (also via atomic write)
- Log: `ACCEPTED: TranscoderCanOnlyRemuxVideo 0 -> 1`

### Step 3: Implement `revert` command

For each drifted setting:

- Verify Plex is reachable before attempting any PUTs (fail early if not)
- `curl -X PUT "http://localhost:32400/:/prefs?<setting>=<golden_value>&X-Plex-Token=$TOKEN"`
- Verify the revert took effect by re-fetching the setting
- If verification fails: log error with actual vs expected value, do NOT clear alert state for that setting (so the next poll will re-alert), report failure to the user
- If verification succeeds: clear alert entry from `state.json`, log: `REVERTED: TranscoderCanOnlyRemuxVideo 1 -> 0`

### Step 4: Implement `refresh` command

- Fetch all current Plex prefs via `xmllint`
- Back up current golden.conf to `golden.conf.bak`
- Read all uncommented (monitored) lines from golden.conf, preserving their golden values
- Regenerate the commented-out section with updated values and any new settings
- If a monitored setting no longer exists in Plex's prefs: log a warning (`WARNING: monitored setting 'FooBar' no longer exists in Plex prefs — kept in golden.conf but may be stale`)
- Write to `golden.conf.tmp`, then `mv` (atomic)
- Log count of new/removed settings discovered
- Display a diff between old and new golden.conf for the user to review

---

## Task 5: Create the setup script and LaunchAgent

**Files:**

- Create: `app-setup/plex-watchdog-setup.sh`

### Step 1: Prerequisites

- Source `config/config.conf` for `MONITORING_EMAIL`, `HOSTNAME`, etc.
- Verify msmtp is configured (check for `~/.config/msmtp/config`). If not, instruct user to run `msmtp-setup.sh` first.
- Verify Plex is running and reachable (`curl -s http://localhost:32400/identity`)

### Step 2: Store Plex token in keychain

- Read token from `/Users/operator/.config/transmission-done/config.yml` as seed source
- Store in macOS keychain: `security add-generic-password -a plex-watchdog -s plex-watchdog-token -w "$TOKEN"`
- This decouples the watchdog from the transmission config file at runtime. If the token changes, re-run setup.

### Step 3: Deploy scripts

- Copy templates to `~/.local/bin/plex-watchdog` and `~/.local/bin/plex-watchdog-ctl`
- Substitute template variables (`__HOSTNAME__`, `__MONITORING_EMAIL__`, etc.)
- Token is NOT baked into scripts — read from keychain at runtime
- `chmod +x` both scripts

### Step 4: Generate initial golden config

- Fetch all Plex prefs via `xmllint`
- Generate `~/.config/plex-watchdog/golden.conf` from template, populating `__VALUE__` placeholders with current server values
- Initialize `state.json` with empty settings map and zero failure counter

### Step 5: Create and load LaunchAgent

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.<hostname>.plex-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/operator/.local/bin/plex-watchdog</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/Users/operator/.local/state/plex-watchdog.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/operator/.local/state/plex-watchdog.log</string>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
```

Validate with `plutil -lint`, load with `launchctl load`.

### Step 6: Add log rotation

Add `*-plex-watchdog.log` to `config/logrotate.conf` alongside the existing log patterns.

### Step 7: Verify deployment

- Run one poll cycle manually
- Confirm log output shows heartbeat
- Confirm no false drift alerts on first run (golden was just generated from current state)

---

## Future Enhancements (v2)

- **Webhook accept/revert:** Email contains clickable links routed through Caddy to `plex-watchdog-ctl accept` / `revert`
- **Multiple notification channels:** Slack, Discord, ntfy.sh
- **Expanded monitoring:** Other services beyond Plex (Transmission settings, NFS mount config, etc.)
- **Per-setting accept/revert:** Handle mixed accept-some-revert-others in a single pass
- **Heartbeat email:** Periodic (daily/weekly) email confirming the watchdog is running, to monitor the monitor
