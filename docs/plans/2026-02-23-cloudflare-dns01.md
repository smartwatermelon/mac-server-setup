# Cloudflare DNS-01 Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace NoIP DUC + HTTP-01 cert renewal with Cloudflare DNS-01 challenge, eliminating
the manual port-opening requirement for Let's Encrypt renewals, and switch the external hostname
from `wellington.sytes.net` to `tilsit.vip` throughout.

**Architecture:** Caddy gets a custom build (xcaddy + `caddy-dns/cloudflare`) that handles DNS-01
challenges automatically. The CF_API_TOKEN is stored in the System keychain and injected at
runtime via a wrapper script — never written to the plist. `plex-vpn-bypass.sh` gains a
`update_cloudflare_dns()` function (reads token from keychain at runtime) that updates the
Cloudflare A record on IP change; Plex `customConnections` is updated once to the stable
hostname `tilsit.vip:32400` instead of a raw IP.

**Tech Stack:** Caddy v2.11.1 (custom xcaddy build), `caddy-dns/cloudflare` Caddy module,
Cloudflare DNS API, macOS System keychain (`security` CLI), bash shell scripts.

---

## Reference

| Item | Value |
|------|-------|
| Domain | `tilsit.vip` |
| Cloudflare Zone ID | `32a24114b4febebab7385a9cdcf25842` |
| Cloudflare A record ID | `591eb1b23bfb66508417a5d27f7f77d1` |
| CF_API_TOKEN (1Password) | `op://Personal/i3ld7outxdx2pxmw7w6zefhnta/API/zone DNS API token` |
| Caddy binary (TILSIT) | `/opt/homebrew/bin/caddy` (Homebrew symlink, v2.11.1) |
| Caddyfile (TILSIT) | `/Users/operator/.config/caddy/Caddyfile` |
| LaunchDaemon (TILSIT) | `/Library/LaunchDaemons/com.caddyserver.caddy.plist` |
| Caddy logs (TILSIT) | `~operator/.local/state/caddy/caddy-error.log` |
| plex-vpn-bypass template | `mac-server-setup/app-setup/templates/plex-vpn-bypass.sh` |

### Repos involved

- Primary: `/Users/andrewrich/Developer/tilsit/tilsit-caddy-v1/`
- Secondary: `/Users/andrewrich/Developer/mac-server-setup/`

**Manual steps** (require sudo on TILSIT, flagged `⚙️ TILSIT`) are interspersed with
repo changes. The plan is written so repo changes can be done first (and committed), then
deployed to TILSIT in one go.

---

## Task 1: Store CF_API_TOKEN in TILSIT System keychain

⚙️ **TILSIT — manual step** (requires sudo password)

### Step 1: SSH to TILSIT and add the token to System keychain

Retrieve the token from 1Password and store it in the System keychain so root-level
daemons can read it without it ever appearing in a plist or script:

```bash
ssh operator@tilsit.local
CF_TOKEN=$(op read "op://Personal/i3ld7outxdx2pxmw7w6zefhnta/API/zone DNS API token")
sudo security add-generic-password \
  -U \
  -s "cloudflare-api-token" \
  -a "tilsit.vip" \
  -w "${CF_TOKEN}" \
  /Library/Keychains/System.keychain
unset CF_TOKEN
```

### Step 2: Verify the token is readable by root

```bash
sudo security find-generic-password \
  -s "cloudflare-api-token" \
  -a "tilsit.vip" \
  -w \
  /Library/Keychains/System.keychain
```

Expected: the token string is printed, no error.

---

## Task 2: Build custom Caddy with Cloudflare DNS module on TILSIT

⚙️ **TILSIT — manual step**

The stock Homebrew `caddy` does not include third-party DNS modules. xcaddy builds a
custom binary with the plugin compiled in. Homebrew caddy is then pinned so auto-upgrade
(Stage 5 `brew upgrade`) doesn't silently overwrite the custom build.

### Step 1: Install xcaddy

```bash
ssh operator@tilsit.local
/opt/homebrew/bin/brew install xcaddy
```

Expected: xcaddy installed at `/opt/homebrew/bin/xcaddy`.

### Step 2: Build custom Caddy

```bash
cd /tmp
/opt/homebrew/bin/xcaddy build \
  --with github.com/caddy-dns/cloudflare
```

This takes 2–5 minutes (downloads Go, compiles caddy + plugin).
Expected: `caddy` binary in `/tmp`.

### Step 3: Verify the cloudflare module is present

```bash
/tmp/caddy list-modules | grep cloudflare
```

Expected output:

```
dns.providers.cloudflare
```

### Step 4: Back up the Homebrew binary and install the custom build

```bash
sudo cp /opt/homebrew/bin/caddy /opt/homebrew/bin/caddy.homebrew-backup
sudo cp /tmp/caddy /opt/homebrew/bin/caddy
sudo chmod +x /opt/homebrew/bin/caddy
/opt/homebrew/bin/caddy version
/opt/homebrew/bin/caddy list-modules | grep cloudflare
```

Expected: version string printed, `dns.providers.cloudflare` listed.

### Step 5: Pin Caddy in Homebrew

```bash
/opt/homebrew/bin/brew pin caddy
/opt/homebrew/bin/brew list --pinned
```

Expected: `caddy` shown as pinned. This prevents `brew upgrade` from reverting
to the stock binary. To rebuild after a Caddy release: `brew unpin caddy`,
upgrade with Homebrew, then repeat this task.

---

## Task 3: Write caddy-wrapper.sh (tilsit-caddy-v1 repo)

### Files

- Create: `caddy-wrapper.sh`

The wrapper reads CF_API_TOKEN from the System keychain and exports it before
exec-ing Caddy. This keeps the token out of the plist (which is world-readable:
`-rw-r--r-- 1 root wheel`).

### Step 1: Create the wrapper script

```bash
# In tilsit-caddy-v1 repo
```

Content of `caddy-wrapper.sh`:

```bash
#!/usr/bin/env bash
# caddy-wrapper.sh — reads CF_API_TOKEN from System keychain, then exec's Caddy.
# Run as root via LaunchDaemon. The token never appears in the plist or on disk.
set -euo pipefail

CF_API_TOKEN=$(security find-generic-password \
  -s "cloudflare-api-token" \
  -a "tilsit.vip" \
  -w \
  /Library/Keychains/System.keychain 2>/dev/null) || {
    echo "ERROR: cloudflare-api-token not found in System keychain" >&2
    exit 1
  }
export CF_API_TOKEN

exec /opt/homebrew/bin/caddy run \
  --config /Users/operator/.config/caddy/Caddyfile \
  --adapter caddyfile
```

### Step 2: Make it executable

```bash
chmod +x caddy-wrapper.sh
```

### Step 3: Validate it (dev machine — will fail at keychain lookup, that's expected)

```bash
shellcheck caddy-wrapper.sh
```

Expected: no warnings or errors.

### Step 4: Commit

```bash
git -C /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1 add caddy-wrapper.sh
git -C /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1 commit -m "feat(caddy): wrapper script reads CF_API_TOKEN from System keychain"
```

---

## Task 4: Update Caddyfile for tilsit.vip + DNS-01 TLS

### Files

- Modify: `Caddyfile`

Two changes: (1) replace `wellington.sytes.net` with `tilsit.vip` everywhere,
(2) swap the ACME HTTP issuer for Cloudflare DNS-01.

### Step 1: Update the security configuration comment

Replace:

```caddyfile
# External hostname: wellington.sytes.net
```

With:

```caddyfile
# External hostname: tilsit.vip
```

### Step 2: Update the `@external_auth_required` matcher in `(common_config)`

Replace:

```caddyfile
 @external_auth_required {
  not remote_ip 10.0.15.0/24
  not remote_ip 127.0.0.1/8
  not remote_ip fe80::/10
  host wellington.sytes.net
 }
```

With:

```caddyfile
 @external_auth_required {
  not remote_ip 10.0.15.0/24
  not remote_ip 127.0.0.1/8
  not remote_ip fe80::/10
  host tilsit.vip
 }
```

### Step 3: Replace the external site block

Replace:

```caddyfile
# External access with automatic HTTPS (Let's Encrypt)
wellington.sytes.net {
 tls {
  issuer acme {
   dir https://acme-v02.api.letsencrypt.org/directory
  }
 }
 import common_config
}
```

With:

```caddyfile
# External access with automatic HTTPS (Let's Encrypt via Cloudflare DNS-01)
tilsit.vip {
 tls {
  dns cloudflare {env.CF_API_TOKEN}
 }
 import common_config
}
```

### Step 4: Validate the Caddyfile

```bash
cd /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1
HOSTNAME=tilsit CF_API_TOKEN=placeholder caddy validate --config Caddyfile
```

Expected: `Valid configuration` (the token value doesn't matter for validation;
the cloudflare module only needs it at cert-issuance time).

Note: This requires the custom Caddy build (with cloudflare module) to be in
PATH on the dev machine, OR run the validate step on TILSIT after deploying.
If the dev machine has stock Caddy, skip this step and validate on TILSIT in
Task 6 instead.

### Step 5: Commit

```bash
git -C /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1 add Caddyfile
git -C /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1 commit -m "feat(caddy): migrate to tilsit.vip with Cloudflare DNS-01 TLS"
```

---

## Task 5: Update LaunchDaemon plist

### Files

- Modify: `LaunchDaemons/com.caddyserver.caddy.plist`

The plist currently calls caddy directly. Update it to call `caddy-wrapper.sh`
instead. Also update the path values to match TILSIT's actual layout (the repo
plist still has dev-machine paths from `boursin`).

### Step 1: Update `ProgramArguments` and `WorkingDirectory`

Replace the entire plist content with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Service identification -->
    <key>Label</key>
    <string>com.caddyserver.caddy</string>

    <!-- Run caddy-wrapper.sh which injects CF_API_TOKEN from System keychain -->
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/bin/caddy-wrapper.sh</string>
    </array>

    <!-- Working directory -->
    <key>WorkingDirectory</key>
    <string>/Users/operator/.config/caddy</string>

    <!-- Environment variables (CF_API_TOKEN is injected by caddy-wrapper.sh) -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOSTNAME</key>
        <string>tilsit</string>
        <key>HOME</key>
        <string>/Users/operator</string>
        <key>USER</key>
        <string>operator</string>
    </dict>

    <!-- Run at system startup -->
    <key>RunAtLoad</key>
    <true/>

    <!-- Keep alive and restart on failure -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <!-- Logging configuration -->
    <key>StandardOutPath</key>
    <string>/Users/operator/.local/state/caddy/caddy.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/operator/.local/state/caddy/caddy-error.log</string>

    <!-- Throttle restart attempts -->
    <key>ThrottleInterval</key>
    <integer>30</integer>

    <!-- Process management -->
    <key>ProcessType</key>
    <string>Interactive</string>

    <!-- Exit timeout -->
    <key>ExitTimeOut</key>
    <integer>30</integer>
</dict>
</plist>
```

### Step 2: Commit

```bash
git -C /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1 add LaunchDaemons/com.caddyserver.caddy.plist
git -C /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1 commit -m "feat(caddy): LaunchDaemon runs caddy-wrapper.sh, update paths for TILSIT"
```

---

## Task 6: Deploy Caddy changes to TILSIT

⚙️ **TILSIT — manual step** (requires sudo password)

### Step 1: Copy caddy-wrapper.sh to /usr/local/bin

```bash
scp /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1/caddy-wrapper.sh \
    operator@tilsit.local:/tmp/caddy-wrapper.sh

ssh operator@tilsit.local '
  sudo cp /tmp/caddy-wrapper.sh /usr/local/bin/caddy-wrapper.sh
  sudo chmod 755 /usr/local/bin/caddy-wrapper.sh
  sudo chown root:wheel /usr/local/bin/caddy-wrapper.sh
'
```

### Step 2: Test the wrapper reads the token correctly

```bash
ssh operator@tilsit.local 'sudo /usr/local/bin/caddy-wrapper.sh --help 2>&1 | head -3'
```

Expected: Caddy's help text (not a keychain error). The `--help` flag makes Caddy
exit immediately, so this is a safe smoke test.

### Step 3: Copy the updated Caddyfile to TILSIT

Back up the existing one first:

```bash
ssh operator@tilsit.local \
  'cp ~/.config/caddy/Caddyfile ~/.config/caddy/Caddyfile.pre-cloudflare-$(date +%Y%m%d)'

scp /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1/Caddyfile \
    operator@tilsit.local:/tmp/Caddyfile.new
```

### Step 4: Validate the new Caddyfile on TILSIT (with real token + custom caddy)

```bash
ssh operator@tilsit.local '
  sudo CF_API_TOKEN=$(security find-generic-password \
    -s cloudflare-api-token -a tilsit.vip -w \
    /Library/Keychains/System.keychain) \
  HOSTNAME=tilsit \
  /opt/homebrew/bin/caddy validate \
    --config /tmp/Caddyfile.new \
    --adapter caddyfile
'
```

Expected: `Valid configuration`

### Step 5: Move validated Caddyfile into place

```bash
ssh operator@tilsit.local \
  'cp /tmp/Caddyfile.new ~/.config/caddy/Caddyfile'
```

### Step 6: Deploy updated LaunchDaemon plist

```bash
scp /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1/LaunchDaemons/com.caddyserver.caddy.plist \
    operator@tilsit.local:/tmp/com.caddyserver.caddy.plist

ssh operator@tilsit.local '
  sudo cp /tmp/com.caddyserver.caddy.plist \
    /Library/LaunchDaemons/com.caddyserver.caddy.plist
  sudo chown root:wheel /Library/LaunchDaemons/com.caddyserver.caddy.plist
  sudo chmod 644 /Library/LaunchDaemons/com.caddyserver.caddy.plist
'
```

---

## Task 7: Clear stale ACME state, restart Caddy, verify cert issuance

⚙️ **TILSIT — manual step**

### Step 1: Remove stale ACME certificates for wellington.sytes.net

```bash
ssh operator@tilsit.local '
  rm -rf "/Users/operator/Library/Application Support/Caddy/certificates/acme-v02.api.letsencrypt.org-directory/wellington.sytes.net"
  rm -rf "/Users/operator/Library/Application Support/Caddy/acme/acme-v02.api.letsencrypt.org-directory"
  ls "/Users/operator/Library/Application Support/Caddy/certificates/"
'
```

Expected: only `local/` directory remains (internal CA certs for tilsit.local etc).

### Step 2: Reload the LaunchDaemon

```bash
ssh operator@tilsit.local '
  sudo launchctl unload /Library/LaunchDaemons/com.caddyserver.caddy.plist
  sudo launchctl load /Library/LaunchDaemons/com.caddyserver.caddy.plist
'
```

### Step 3: Watch the error log for cert issuance

```bash
ssh operator@tilsit.local \
  'tail -f ~/.local/state/caddy/caddy-error.log' \
  | grep -i 'tilsit\|acme\|certif\|cloudflare\|obtain\|error'
```

Expected within ~30 seconds:

```text
"msg":"obtaining certificate","identifier":"tilsit.vip"
"msg":"certificate obtained successfully","identifier":"tilsit.vip"
```

If you see `dns.providers.cloudflare` error or `forbidden`, check:

- Token has `Zone:DNS:Edit` permission for the `tilsit.vip` zone specifically
- Nameservers have fully propagated (test: `dig NS tilsit.vip` should return Cloudflare NS)

### Step 4: Verify the cert from outside

From the dev machine:

```bash
curl -sk https://tilsit.vip:24443 -o /dev/null -w '%{http_code} %{ssl_verify_result}\n'
```

Expected: `200 0` (or `401 0` if auth kicks in — either way, `ssl_verify_result=0` means
the cert is valid and trusted).

---

## Task 8: Add DDNS to plex-vpn-bypass.sh template (mac-server-setup repo)

### Files

- Modify: `mac-server-setup/app-setup/templates/plex-vpn-bypass.sh`

When the public IP changes, update the Cloudflare A record via API.
The CF_API_TOKEN is read from System keychain at runtime (daemon runs as root).
The Zone ID and external hostname are deploy-time template variables.

### Step 1: Add new template variables to the configuration section

After the existing `OPERATOR_USERNAME="__OPERATOR_USERNAME__"` line, add:

```bash
EXTERNAL_HOSTNAME="__EXTERNAL_HOSTNAME__"
CLOUDFLARE_ZONE_ID="__CLOUDFLARE_ZONE_ID__"
```

### Step 2: Add the new placeholder entries to the header comment

After the `__OPERATOR_USERNAME__` comment line, add:

```bash
#   - __EXTERNAL_HOSTNAME__: Public hostname for Plex customConnections and DDNS (e.g. tilsit.vip)
#   - __CLOUDFLARE_ZONE_ID__: Cloudflare zone ID for the external hostname
```

### Step 3: Add `update_cloudflare_dns()` function

Add this function in the "Plex Integration" section, after `update_plex_custom_connections()`:

```bash
# Update Cloudflare A record for the external hostname to the current public IP.
# Reads CF_API_TOKEN from System keychain at runtime (daemon runs as root).
update_cloudflare_dns() {
  local public_ip="$1"

  local cf_token
  cf_token=$(security find-generic-password \
    -s "cloudflare-api-token" \
    -a "${EXTERNAL_HOSTNAME}" \
    -w /Library/Keychains/System.keychain 2>/dev/null) || {
    log "WARNING: cloudflare-api-token not found in System keychain — skipping DNS update"
    return 1
  }

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
    "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records/__CLOUDFLARE_RECORD_ID__" \
    -H "Authorization: Bearer ${cf_token}" \
    -H "Content-Type: application/json" \
    --data "{\"content\":\"${public_ip}\",\"proxied\":false}" \
    --max-time 10)

  if [[ "${http_code}" == "200" ]]; then
    log "Cloudflare DNS updated: ${EXTERNAL_HOSTNAME} -> ${public_ip}"
    return 0
  else
    log "ERROR: Cloudflare DNS update returned HTTP ${http_code}"
    return 1
  fi
}
```

Note: `__CLOUDFLARE_RECORD_ID__` is a **third new template variable** — the Cloudflare
DNS record ID for the A record. Currently `591eb1b23bfb66508417a5d27f7f77d1` for
`tilsit.vip`. It is stable (doesn't change unless the record is deleted and recreated).
Add it to the template variable list and configuration section:

```bash
CLOUDFLARE_RECORD_ID="__CLOUDFLARE_RECORD_ID__"
```

And add to the header comment:

```bash
#   - __CLOUDFLARE_RECORD_ID__: Cloudflare DNS record ID for the A record
```

### Step 4: Update `update_plex_custom_connections()` to use hostname

Plex `customConnections` should use the stable hostname, not the raw IP. Update
the function so the URL uses `EXTERNAL_HOSTNAME` instead of the IP argument:

Replace:

```bash
update_plex_custom_connections() {
  local public_ip="$1"
  local custom_url="https://${public_ip}:32400"
```

With:

```bash
update_plex_custom_connections() {
  local public_ip="$1"
  local custom_url="https://${EXTERNAL_HOSTNAME}:32400"
```

This means Plex's remote address is stable. The function still accepts the IP
argument (used for logging), but no longer needs to be called on every IP change
— it just needs to be called once to set the hostname. The main loop logic can
stay the same.

### Step 5: Call `update_cloudflare_dns()` alongside Plex update in the main loop

In the main polling loop, find:

```bash
        if update_plex_custom_connections "${current_ip}"; then
          LAST_PUBLIC_IP="${current_ip}"
        else
          log "WARNING: Plex update failed — will retry next cycle"
        fi
```

Replace with:

```bash
        local dns_ok=true
        local plex_ok=true
        update_cloudflare_dns "${current_ip}" || dns_ok=false
        update_plex_custom_connections "${current_ip}" || plex_ok=false
        if [[ "${dns_ok}" == "true" ]] && [[ "${plex_ok}" == "true" ]]; then
          LAST_PUBLIC_IP="${current_ip}"
        else
          log "WARNING: DNS or Plex update failed — will retry next cycle"
        fi
```

Also call `update_cloudflare_dns` in the startup block (alongside the initial
`update_plex_custom_connections` call), so the A record is confirmed correct on
daemon start even if no IP change is detected:

```bash
  # Update DNS and Plex on startup to ensure both are current
  update_cloudflare_dns "${initial_ip}" \
    || log "WARNING: Initial Cloudflare DNS update failed — will retry on next change"
  update_plex_custom_connections "${initial_ip}" \
    || log "WARNING: Initial Plex update failed — will retry on next change"
```

### Step 6: Update `transmission-setup.sh` to substitute new template variables

In `app-setup/transmission-setup.sh`, after the existing `__OPERATOR_USERNAME__`
sed line, add:

```bash
  sudo sed -i '' "s|__EXTERNAL_HOSTNAME__|${EXTERNAL_HOSTNAME}|g" "${BYPASS_DEST}"
  sudo sed -i '' "s|__CLOUDFLARE_ZONE_ID__|${CLOUDFLARE_ZONE_ID}|g" "${BYPASS_DEST}"
  sudo sed -i '' "s|__CLOUDFLARE_RECORD_ID__|${CLOUDFLARE_RECORD_ID}|g" "${BYPASS_DEST}"
```

### Step 7: Add new variables to `config/config.conf.template`

```bash
# External access
EXTERNAL_HOSTNAME=""               # Public hostname (e.g. tilsit.vip)
CLOUDFLARE_ZONE_ID=""              # Cloudflare zone ID for external hostname
CLOUDFLARE_RECORD_ID=""            # Cloudflare A record ID for external hostname
```

### Step 8: Run shellcheck on both modified files

```bash
shellcheck /Users/andrewrich/Developer/mac-server-setup/app-setup/templates/plex-vpn-bypass.sh
shellcheck /Users/andrewrich/Developer/mac-server-setup/app-setup/transmission-setup.sh
```

Expected: zero warnings and errors.

### Step 9: Commit

```bash
cd /Users/andrewrich/Developer/mac-server-setup
git add app-setup/templates/plex-vpn-bypass.sh \
        app-setup/transmission-setup.sh \
        config/config.conf.template
git commit -m "feat(vpn): add Cloudflare DDNS to plex-vpn-bypass + use hostname for Plex customConnections"
```

---

## Task 9: Patch deployed plex-vpn-bypass.sh on TILSIT + verify DDNS

⚙️ **TILSIT — manual step**

The live script at `/usr/local/bin/plex-vpn-bypass.sh` was deployed before this
migration. Patch it by applying the template changes with the real values substituted.

### Step 1: Prepare the patched script on the dev machine

```bash
cp /Users/andrewrich/Developer/mac-server-setup/app-setup/templates/plex-vpn-bypass.sh \
   /tmp/plex-vpn-bypass-new.sh

# Substitute all template variables
sed -i '' 's|__SERVER_NAME__|TILSIT|g'                                      /tmp/plex-vpn-bypass-new.sh
sed -i '' 's|__OPERATOR_USERNAME__|operator|g'                              /tmp/plex-vpn-bypass-new.sh
sed -i '' 's|__EXTERNAL_HOSTNAME__|tilsit.vip|g'                            /tmp/plex-vpn-bypass-new.sh
sed -i '' 's|__CLOUDFLARE_ZONE_ID__|32a24114b4febebab7385a9cdcf25842|g'     /tmp/plex-vpn-bypass-new.sh
sed -i '' 's|__CLOUDFLARE_RECORD_ID__|591eb1b23bfb66508417a5d27f7f77d1|g'   /tmp/plex-vpn-bypass-new.sh

# Verify no unsubstituted placeholders remain
grep '__[A-Z]' /tmp/plex-vpn-bypass-new.sh && echo "ERROR: unsubstituted placeholders" || echo "All substituted"
```

### Step 2: Upload and deploy to TILSIT

```bash
scp /tmp/plex-vpn-bypass-new.sh operator@tilsit.local:/tmp/plex-vpn-bypass-new.sh

ssh operator@tilsit.local '
  sudo cp /tmp/plex-vpn-bypass-new.sh /usr/local/bin/plex-vpn-bypass.sh
  sudo chmod 755 /usr/local/bin/plex-vpn-bypass.sh
  sudo chown root:wheel /usr/local/bin/plex-vpn-bypass.sh
'
```

### Step 3: Restart the daemon

```bash
ssh operator@tilsit.local \
  'sudo launchctl kickstart -k system/com.tilsit.plex-vpn-bypass'
```

### Step 4: Verify DDNS update in log

```bash
ssh operator@tilsit.local \
  'tail -20 /var/log/tilsit-plex-vpn-bypass.log'
```

Expected to see:

```text
Cloudflare DNS updated: tilsit.vip -> 67.5.106.16
Updating Plex customConnections to https://tilsit.vip:32400
Plex customConnections updated successfully
```

### Step 5: Verify the A record from outside

```bash
dig +short tilsit.vip @1.1.1.1
```

Expected: `67.5.106.16`

---

## Task 10: Remove NoIP DUC

⚙️ **TILSIT — manual step** (PIA GUI)

### Step 1: Remove No-IP DUC from PIA split-tunnel bypass list

1. Open PIA → Settings → Split Tunnel
2. Remove `/Applications/No-IP DUC.app` from the Bypass VPN list
3. Save — PIA may reconnect briefly

### Step 2: Quit and uninstall No-IP DUC

```bash
ssh operator@tilsit.local 'osascript -e "quit app \"No-IP DUC\""'
```

Then on TILSIT: drag `/Applications/No-IP DUC.app` to Trash, empty Trash.

### Step 3: Verify PIA split-tunnel reference is clean

```bash
ssh operator@tilsit.local \
  'cat ~/.local/etc/pia-split-tunnel-reference.json | python3 -m json.tool | grep -i noip || echo "NoIP not in reference"'
```

If NoIP is still in the reference config, run:

```bash
ssh operator@tilsit.local \
  '~/.local/bin/pia-split-tunnel-monitor.sh --save-reference'
```

This saves the updated (NoIP-free) PIA config as the new reference, preventing
the Stage 1.5 watchdog from reverting the removal.

---

## Task 11: Update CLAUDE.md and plan.md

### Files

- Modify: `mac-server-setup/plan.md`
- Modify: `tilsit-caddy-v1/CLAUDE.md`

### Step 1: Update plan.md Known Issues and Next Priorities

Remove any remaining `wellington.sytes.net` references. Add note under Running Services
that Caddy now uses DNS-01 via `tilsit.vip`.

### Step 2: Update tilsit-caddy-v1/CLAUDE.md

- Update Architecture section: `wellington.sytes.net` → `tilsit.vip`
- Update TLS Strategy: note DNS-01 via Cloudflare, CF_API_TOKEN injected by wrapper
- Add note: caddy binary is a custom xcaddy build; run `brew info caddy` to check if
  pinned; rebuild procedure in `MIGRATE-TO-DNS01.md`

### Step 3: Commit both repos

```bash
git -C /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1 add CLAUDE.md
git -C /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1 commit -m "docs: update for tilsit.vip migration and xcaddy custom build"

git -C /Users/andrewrich/Developer/mac-server-setup add plan.md
git -C /Users/andrewrich/Developer/mac-server-setup commit -m "docs: update for Cloudflare DDNS migration"
```

---

## Rollback

If cert issuance fails and external access is broken:

1. Restore original Caddyfile: `cp ~/.config/caddy/Caddyfile.pre-cloudflare-* ~/.config/caddy/Caddyfile`
2. Restore original LaunchDaemon plist (calls caddy directly, no wrapper)
3. Restore Homebrew caddy: `sudo cp /opt/homebrew/bin/caddy.homebrew-backup /opt/homebrew/bin/caddy`
4. Reload: `sudo launchctl unload/load /Library/LaunchDaemons/com.caddyserver.caddy.plist`
5. Temporarily forward port 443 to TILSIT to allow TLS-ALPN-01 renewal (buys 90 days)

NoIP DUC: do NOT remove from PIA bypass list or uninstall until Tasks 7+9 are fully
verified working.
