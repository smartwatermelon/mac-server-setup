# Plex Settings Watchdog

Monitors Plex server preferences against a curated golden configuration and sends email alerts when settings drift.

## Overview

The watchdog polls the Plex REST API every 5 minutes, comparing current settings against a golden config file. When a monitored setting changes, it sends an email with the drift details and instructions to accept or revert.

Two setup scripts deploy four components:

| Script | What it deploys |
|--------|----------------|
| `msmtp-setup.sh` | Shared email facility (Gmail SMTP via msmtp) |
| `plex-watchdog-setup.sh` | Polling daemon, CLI tool, golden config, LaunchAgent |

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

After a Plex update, new settings may appear. Refresh the golden config to pick them up:

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

1. Fetch Plex prefs XML via REST API
2. **Fast path**: compare SHA-256 hash against stored hash — if unchanged, skip to heartbeat check (this is 99.9% of runs)
3. Parse XML with `xmllint` (handles entities like `&amp;` correctly)
4. Compare each monitored setting against golden config
5. Send email on new drift; send "resolved" email when drift clears
6. Save state atomically (temp file + mv)
7. Log a heartbeat once per hour when there's no drift

### Alert deduplication

The watchdog tracks which drifts have been emailed in `state.json`. It only emails when:

- A setting drifts to a value not previously alerted
- A previously-drifted setting returns to its golden value (sends a "resolved" email)

### Error handling

- **Plex unreachable**: logs a warning, emails only after 3 consecutive failures (15 minutes)
- **msmtp failure**: logs error, continues monitoring (email failure doesn't block drift detection)
- **xmllint failure**: logs error, preserves last known good state

## Credential management

Credentials are embedded in config files with restrictive permissions (mode 600, owned by operator) rather than stored in macOS Keychain. This is because the operator keychain cannot be unlocked from non-interactive contexts like LaunchAgents. See [Keychain Management](../keychain-credential-management.md) for details on this project-wide pattern.

| Credential | Location | Protection |
|-----------|----------|------------|
| Plex token | `~/.config/plex-watchdog/token` | mode 600, operator:staff |
| Gmail App Password | `~/.config/msmtp/config` | mode 600, operator:staff |

## Configuration reference

| Variable | Source | Description |
|----------|--------|-------------|
| `MONITORING_EMAIL` | `config/config.conf` | Email address for alert delivery |
| `SERVER_NAME` | `config/config.conf` | Used in email subject prefix (e.g., `[TILSIT]`) |
| `OPERATOR_USERNAME` | `config/config.conf` | User account that runs the watchdog |

## Logs

| Log | Location | Contents |
|-----|----------|----------|
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

**No email received**: Check msmtp log:

```bash
sudo tail -20 /Users/operator/.local/state/msmtp.log
```

Common issues: Gmail App Password expired or revoked, 2FA disabled on the Google account.

**Status shows drift on fresh deploy**: This shouldn't happen since the golden config is generated from current values at setup time. Run `plex-watchdog-ctl refresh` to regenerate.

**"xmllint not found"**: Should be pre-installed on macOS. Verify with `which xmllint`.

## Testing

27 BATS unit tests in `tests/plex-watchdog.bats`:

```bash
bats tests/plex-watchdog.bats
```

Tests cover golden config parsing, XML parsing with entity handling, drift detection, state management, atomic writes, and token file operations. All use fixtures — no live Plex server required.

Integration test tracking: #87 (email delivery), #88 (live Plex end-to-end), #89 (LaunchAgent/permissions).
