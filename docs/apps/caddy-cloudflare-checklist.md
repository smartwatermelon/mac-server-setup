# Cloudflare Migration — TILSIT Deployment Checklist

Commands run in your SSH session on TILSIT unless marked **Dev machine**.

**Status as of 2026-02-23:** Tasks 1, 2, 6, 7-1, 7-2 complete. Resume at **Task 7 retry**.

---

## ✅ Task 1: Store CF_API_TOKEN in System keychain — DONE

**Dev machine** — retrieve token and store it on TILSIT in one step:

```bash
# Dev machine
CF_TOKEN=$(op read "op://Personal/i3ld7outxdx2pxmw7w6zefhnta/API/zone DNS API token")
ssh operator@tilsit.local "sudo security add-generic-password \
  -U \
  -s 'cloudflare-api-token' \
  -a 'tilsit.vip' \
  -w '${CF_TOKEN}' \
  /Library/Keychains/System.keychain"
unset CF_TOKEN
```

Verify on TILSIT:

```bash
sudo security find-generic-password \
  -s "cloudflare-api-token" \
  -a "tilsit.vip" \
  -w \
  /Library/Keychains/System.keychain
```

Expected: token string printed, no error.

---

## ✅ Task 2: Install pre-built Caddy with Cloudflare module — DONE

**Dev machine** — download the official Caddy binary with the Cloudflare DNS plugin:

```bash
# Dev machine
curl -L "https://caddyserver.com/api/download?os=darwin&arch=arm64&p=github.com%2Fcaddy-dns%2Fcloudflare" \
  -o /tmp/caddy-cloudflare
chmod +x /tmp/caddy-cloudflare
/tmp/caddy-cloudflare list-modules | grep cloudflare
rsync /tmp/caddy-cloudflare operator@tilsit.local:/tmp/caddy-cloudflare
```

**As `operator`:**

```bash
sudo cp /opt/homebrew/bin/caddy /opt/homebrew/bin/caddy.homebrew-backup
sudo cp /tmp/caddy-cloudflare /opt/homebrew/bin/caddy
sudo chmod +x /opt/homebrew/bin/caddy
/opt/homebrew/bin/caddy version
/opt/homebrew/bin/caddy list-modules | grep cloudflare
```

**As `andrewrich`:**

```bash
/opt/homebrew/bin/brew pin caddy
/opt/homebrew/bin/brew list --pinned
```

Expected: `dns.providers.cloudflare` listed, `caddy` shown as pinned.

---

## ✅ Task 6: Deploy Caddy changes to TILSIT — DONE

### ✅ Step 1 — deploy caddy-wrapper.sh

```bash
# Dev machine
rsync /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1/caddy-wrapper.sh \
    operator@tilsit.local:/tmp/caddy-wrapper.sh
```

```bash
sudo cp /tmp/caddy-wrapper.sh /usr/local/bin/caddy-wrapper.sh
sudo chmod 755 /usr/local/bin/caddy-wrapper.sh
sudo chown root:wheel /usr/local/bin/caddy-wrapper.sh
```

### ✅ Step 2 — smoke test the wrapper

```bash
sudo /bin/bash /usr/local/bin/caddy-wrapper.sh --help 2>&1 | head -3
```

Expected: Caddy help text (not a keychain error).

### ✅ Step 3 — back up Caddyfile

```bash
cp ~/.config/caddy/Caddyfile ~/.config/caddy/Caddyfile.pre-cloudflare-$(date +%Y%m%d)
```

### ✅ Step 4 — validate on TILSIT

### ✅ Step 5 — move validated Caddyfile into place

### ✅ Step 6 — deploy updated LaunchDaemon plist

```bash
# Dev machine
rsync /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1/LaunchDaemons/com.caddyserver.caddy.plist \
    operator@tilsit.local:/tmp/com.caddyserver.caddy.plist
```

```bash
sudo cp /tmp/com.caddyserver.caddy.plist \
  /Library/LaunchDaemons/com.caddyserver.caddy.plist
sudo chown root:wheel /Library/LaunchDaemons/com.caddyserver.caddy.plist
sudo chmod 644 /Library/LaunchDaemons/com.caddyserver.caddy.plist
```

---

## ✅ Task 7: Clear stale ACME state + verify cert issuance — DONE

**Three rounds of failures, all now fixed and documented in CLAUDE.md:**

1. Staging ACME account reused → fixed: explicit `dir https://acme-v02...` in Caddyfile
2. `certmagic` TCP/53 timeout querying Cloudflare auth NS → fixed: `propagation_timeout -1` (PIA VPN blocks direct NS queries; LE does its own check)
3. `{env.CF_API_TOKEN}` not substituted at parse time → fixed: `{$CF_API_TOKEN}` (Caddyfile parse-time syntax)
4. Propagation race: LE checked before Cloudflare NS served the record → fixed: `propagation_delay 30s`

**Cert obtained successfully 2026-02-23. `ssl_verify_result=0` confirmed.**

### ✅ Step 1 — remove stale certs — DONE

### ✅ Step 2 — reload LaunchDaemon — DONE

### ✅ Step 3 — deploy fixed Caddyfile — DONE

```bash
# Dev machine
rsync /Users/andrewrich/Developer/tilsit/tilsit-caddy-v1/Caddyfile \
    operator@tilsit.local:/tmp/Caddyfile.new
```

Validate on TILSIT:

```bash
sudo CF_API_TOKEN=$(security find-generic-password \
  -s cloudflare-api-token -a tilsit.vip -w \
  /Library/Keychains/System.keychain) \
HOSTNAME=tilsit \
/opt/homebrew/bin/caddy validate \
  --config /tmp/Caddyfile.new \
  --adapter caddyfile
```

Expected: `Valid configuration`

Copy into place:

```bash
cp /tmp/Caddyfile.new ~/.config/caddy/Caddyfile
```

### ✅ Step 4 — clear ALL stale ACME state — DONE

### ✅ Step 5 — reload LaunchDaemon — DONE

### ✅ Step 6 — watch for cert issuance — DONE

### ✅ Step 7 — verify cert — DONE (`ssl_verify_result=0`)

---

## Reference: what was cleared and why

The following steps are retained for future reference if cert state needs to be reset again.

Both staging and production account/cert state must go, or Caddy may reuse the broken staging account:

```bash
rm -rf "/Users/operator/Library/Application Support/Caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory"
rm -rf "/Users/operator/Library/Application Support/Caddy/certificates/acme-v02.api.letsencrypt.org-directory"
rm -rf "/Users/operator/Library/Application Support/Caddy/acme/acme-staging-v02.api.letsencrypt.org-directory"
rm -rf "/Users/operator/Library/Application Support/Caddy/acme/acme-v02.api.letsencrypt.org-directory"
ls "/Users/operator/Library/Application Support/Caddy/certificates/"
ls "/Users/operator/Library/Application Support/Caddy/acme/"
```

Expected: only `local/` remains under `certificates/`; `acme/` directory empty or absent.

### Step 5 — reload LaunchDaemon

```bash
sudo launchctl unload /Library/LaunchDaemons/com.caddyserver.caddy.plist
sudo launchctl load /Library/LaunchDaemons/com.caddyserver.caddy.plist
```

### Step 6 — watch for cert issuance

```bash
tail -f ~/.local/state/caddy/caddy-error.log | grep -i 'tilsit\|acme\|certif\|cloudflare\|obtain\|error'
```

Expected within ~60 seconds (Let's Encrypt does its own propagation check from their servers):

```
"msg":"obtaining certificate","identifier":"tilsit.vip"
"msg":"certificate obtained successfully","identifier":"tilsit.vip"
```

If you see a `dns.providers.cloudflare` error or `forbidden`, check:

- Token has `Zone:DNS:Edit` permission for the `tilsit.vip` zone
- `dig NS tilsit.vip` returns Cloudflare nameservers

### Step 7 — verify cert

```bash
curl -sk https://tilsit.vip:24443 -o /dev/null -w '%{http_code} %{ssl_verify_result}\n'
```

Expected: `200 0` or `401 0` — `ssl_verify_result=0` means valid trusted cert.

---

## ✅ Task 9: Patch live plex-vpn-bypass.sh + verify DDNS — DONE

### Step 1 — prepare patched script

```bash
# Dev machine
cp /Users/andrewrich/Developer/mac-server-setup/app-setup/templates/plex-vpn-bypass.sh \
   /tmp/plex-vpn-bypass-new.sh

sed -i '' 's|__SERVER_NAME__|TILSIT|g'                                      /tmp/plex-vpn-bypass-new.sh
sed -i '' 's|__OPERATOR_USERNAME__|operator|g'                              /tmp/plex-vpn-bypass-new.sh
sed -i '' 's|__EXTERNAL_HOSTNAME__|tilsit.vip|g'                            /tmp/plex-vpn-bypass-new.sh
sed -i '' 's|__CLOUDFLARE_ZONE_ID__|32a24114b4febebab7385a9cdcf25842|g'     /tmp/plex-vpn-bypass-new.sh
sed -i '' 's|__CLOUDFLARE_RECORD_ID__|591eb1b23bfb66508417a5d27f7f77d1|g'   /tmp/plex-vpn-bypass-new.sh

grep '__[A-Z]' /tmp/plex-vpn-bypass-new.sh \
  && echo "ERROR: unsubstituted placeholders" \
  || echo "All substituted"

rsync /tmp/plex-vpn-bypass-new.sh operator@tilsit.local:/tmp/plex-vpn-bypass-new.sh
```

### Step 2 — deploy

```bash
sudo cp /tmp/plex-vpn-bypass-new.sh /usr/local/bin/plex-vpn-bypass.sh
sudo chmod 755 /usr/local/bin/plex-vpn-bypass.sh
sudo chown root:wheel /usr/local/bin/plex-vpn-bypass.sh
```

### Step 3 — restart daemon

```bash
sudo launchctl kickstart -k system/com.tilsit.plex-vpn-bypass
```

### Step 4 — verify DDNS in log

```bash
tail -20 /var/log/tilsit-plex-vpn-bypass.log
```

Expected:

```
Cloudflare DNS updated: tilsit.vip -> 67.5.106.16
Updating Plex customConnections to https://tilsit.vip:32400
Plex customConnections updated successfully
```

### Step 5 — verify A record

Run from **dev machine** — PIA blocks UDP/53 to external resolvers from TILSIT:

```bash
# Dev machine
dig +short tilsit.vip @1.1.1.1
```

Expected: `67.5.106.16`

---

## ✅ Task 10: Remove NoIP DUC — DONE

### Step 1 — remove from PIA split tunnel (GUI on TILSIT)

PIA → Settings → Split Tunnel → remove `/Applications/No-IP DUC.app` from Bypass VPN list → Save

### Step 2 — quit and uninstall

```bash
osascript -e 'quit app "No-IP DUC"'
```

Then drag `/Applications/No-IP DUC.app` to Trash, empty Trash.

### Step 3 — verify PIA reference config is clean

```bash
jq -r '[.. | strings | select(test("noip";"i"))] | if length == 0 then "NoIP not in reference" else .[] end' ~/.local/etc/pia-split-tunnel-reference.json
```

If NoIP still appears, save a new reference:

```bash
~/.local/bin/pia-split-tunnel-monitor.sh --save-reference
```
