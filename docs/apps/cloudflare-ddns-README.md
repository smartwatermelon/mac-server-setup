# Cloudflare DDNS Updater

Keeps the public `A` record for `EXTERNAL_HOSTNAME` in sync with the server's
current public IPv4 address. Runs every 5 minutes as a LaunchDaemon.

## Why this exists

External access to the server is name-based (`tilsit.vip`) rather than IP-based.
When the ISP rotates the WAN IP, the Cloudflare record must follow, otherwise
remote access (Plex, Transmission, the dashboard) breaks.

An earlier DDNS implementation lived inside `plex-vpn-bypass.sh`, which was
retired 2026-03 when the host-level PIA split-tunnel stack was replaced by a
VPN-inside-the-container architecture. The A record then drifted silently.
This updater is the standalone replacement.

## Architecture

```text
/Library/LaunchDaemons/com.<hostname>.cloudflare-ddns.plist
  (StartInterval = 300s, runs as root)
    → /usr/local/bin/cloudflare-ddns
        ├─ read CF_API_TOKEN from System keychain (same entry Caddy uses)
        ├─ GET https://api.ipify.org (fallback: ifconfig.me, icanhazip.com)
        ├─ GET /zones/<ZONE>/dns_records/<RECORD>  → current A-record content
        ├─ if equal: log heartbeat every 3600s, exit 0
        └─ if differs: PATCH /zones/<ZONE>/dns_records/<RECORD>, log result
```

The daemon runs as root so it can call
`security find-generic-password -s cloudflare-api-token -a <EXTERNAL_HOSTNAME>`
against the System keychain. The token never lands on disk.

## Files (in `mac-server-setup`)

- `app-setup/cloudflare-ddns-setup.sh` — deploy script; sources `config.conf`,
  validates inputs, substitutes placeholders, installs the daemon, bootstraps
  it, and tails the log for confirmation.
- `app-setup/templates/cloudflare-ddns.sh` — updater script template.
- `app-setup/templates/com.cloudflare-ddns.plist` — LaunchDaemon plist template.
- `tests/cloudflare-ddns.bats` — unit tests (IP validator, JSON parser,
  branch coverage for the main loop with mocked network).

## Deployed paths (on TILSIT)

- `/usr/local/bin/cloudflare-ddns` (mode 0755, root-owned)
- `/Library/LaunchDaemons/com.<hostname>.cloudflare-ddns.plist` (mode 0644)
- `/Users/operator/.local/state/cloudflare-ddns.log` — log file
- `/Users/operator/.local/state/cloudflare-ddns.state` — `last_ip` +
  `last_heartbeat` epoch

## Configuration

Set these in `app-setup/config/config.conf` before running setup:

```bash
EXTERNAL_HOSTNAME="tilsit.vip"
CLOUDFLARE_ZONE_ID="<32-char hex zone ID>"
CLOUDFLARE_RECORD_ID="<32-char hex record ID>"
```

The token itself must already be in the System keychain (installed by
`caddy-setup.sh` / Task 1 of the Cloudflare DNS-01 migration checklist).
The DDNS setup script checks for the entry and fails loudly if absent.

Find the zone/record IDs from the Cloudflare dashboard or via:

```bash
CF_TOKEN=$(op read 'op://Personal/.../API/zone DNS API token')
# Zone ID
curl -sH "Authorization: Bearer ${CF_TOKEN}" \
  'https://api.cloudflare.com/client/v4/zones?name=tilsit.vip' \
  | python3 -m json.tool | grep -E '"id"|"name"'
# Record ID (after filling in zone ID above)
curl -sH "Authorization: Bearer ${CF_TOKEN}" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A" \
  | python3 -m json.tool
unset CF_TOKEN
```

## Deploy / redeploy

```bash
# On TILSIT, from the app-setup directory
cd ~/mac-server-setup/app-setup
sudo ./cloudflare-ddns-setup.sh
```

The script is idempotent: if the daemon is already loaded it is bootout'd
before bootstrap. First cycle runs immediately on load (`RunAtLoad=true`).

## Operations

```bash
# Status
sudo launchctl print system/com.tilsit.cloudflare-ddns | head

# Force a run now (skip the 5-minute interval)
sudo launchctl kickstart -k system/com.tilsit.cloudflare-ddns

# Tail the log
tail -f /Users/operator/.local/state/cloudflare-ddns.log

# Manual one-shot (bypasses the daemon, same effect)
sudo /usr/local/bin/cloudflare-ddns

# Stop
sudo launchctl bootout system/com.tilsit.cloudflare-ddns

# Verify current A record from outside the LAN
dig +short tilsit.vip @1.1.1.1
```

## Expected log lines

```text
[2026-04-19 10:00:01] [cloudflare-ddns] INFO heartbeat ok — public=67.5.105.43 matches tilsit.vip
[2026-04-19 12:05:03] [cloudflare-ddns] INFO IP change detected: tilsit.vip 67.5.105.43 → 67.5.110.22
[2026-04-19 12:05:04] [cloudflare-ddns] INFO cloudflare A-record updated: tilsit.vip → 67.5.110.22
[2026-04-19 13:10:02] [cloudflare-ddns] WARN could not determine public IP from any provider — will retry next cycle
```

Heartbeats fire at most once per hour when nothing changes, so a silent log
is itself a red flag.

## Troubleshooting

### `cloudflare-api-token not found in System keychain`

The Caddy setup stores this. Verify:

```bash
sudo security find-generic-password -s cloudflare-api-token -a tilsit.vip \
  /Library/Keychains/System.keychain
```

If missing, re-run the Caddy cloudflare checklist Task 1 or add manually:

```bash
sudo security add-generic-password -U \
  -s 'cloudflare-api-token' -a 'tilsit.vip' \
  -w '<token>' /Library/Keychains/System.keychain
```

### `cloudflare GET failed` / `cloudflare PATCH failed`

The log includes the Cloudflare response JSON. Common causes:

- Token revoked or expired → regenerate in Cloudflare dashboard and update
  the keychain entry.
- Token missing `Zone:DNS:Edit` permission on the relevant zone.
- Zone or record ID drifted (e.g., record deleted and recreated) → look up
  fresh IDs and redeploy.

### `could not determine public IP from any provider`

All three external providers unreachable. Usually a transient upstream
outage; the next cycle (5 min) will retry. If persistent:

- `curl -v https://api.ipify.org` from TILSIT directly.
- Check whether a local DNS or firewall rule is in the way (PIA split
  tunnel is gone, but VPN changes can recur).

### Record still stale after deploy

`RunAtLoad=true` means the first cycle fires immediately on bootstrap. If
the record still shows the old IP:

```bash
tail -20 /Users/operator/.local/state/cloudflare-ddns.log
sudo launchctl kickstart -k system/com.tilsit.cloudflare-ddns
```

If the log shows `INFO heartbeat ok — public=X matches ...`, the record
matches what the script saw. Your cache or the client resolver may still
hold the old answer; dig directly at Cloudflare (`@1.1.1.1`) to confirm.

## Tests

```bash
bats tests/cloudflare-ddns.bats
```

Covers: IPv4 validation, JSON parsing (top-level, dot-path, missing field,
malformed), main loop with mocked keychain/public-IP/Cloudflare calls for
both the no-change and change branches, plus failure modes (missing token,
unreachable IP providers, Cloudflare 4xx).
