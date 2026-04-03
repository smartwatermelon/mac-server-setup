# Caddy Reverse Proxy

> Imported from `smartwatermelon/tilsit-caddy` (archived 2026-04-03).
> For full git history, see the archived repository.

This file provides operational reference for the Caddy reverse proxy,
dashboard, and media file server components.

## Project Overview

Caddy web server configuration for the home server (Mac Mini). Serves a dashboard
landing page and reverse-proxies local services (Transmission, Romano Synology DSM,
Berkswell Synology DSM), with split internal/external access control.

## Key Commands

```bash
# Validate Caddyfile (requires custom caddy build with cloudflare module)
# Use a dummy token — must look like a real token to pass the cloudflare module's format check
HOSTNAME=$(hostname -s) CF_API_TOKEN=dummy0token0for0validation0only000000000 caddy validate --config Caddyfile

# Deploy everything (web assets, Caddyfile, wrapper, plist) and validate
sudo ./caddy-setup.sh

# Restart Caddy (via LaunchDaemon — injects CF_API_TOKEN from System keychain)
sudo launchctl kickstart -k system/com.caddyserver.caddy

# Stop Caddy
sudo launchctl bootout system/com.caddyserver.caddy

# Health check all endpoints
./caddy-health.sh

# Generate a bcrypt password hash for basic_auth
caddy hash-password
```

**Important:** Do not use `caddy reload` or `caddy start` directly — the Caddyfile
requires `CF_API_TOKEN` which is injected by `caddy-wrapper.sh` (run via the LaunchDaemon).
Always restart through `launchctl kickstart`.

## Architecture

### Caddyfile Structure

The Caddyfile uses three site blocks with a shared snippet:

1. **Catch-all `:443`** — Rejects direct IP access or unrecognized hostnames (403)
2. **Internal block** (`{$HOSTNAME}.local localhost 10.0.15.4`) — Uses `tls internal` (Caddy's built-in CA). Imports `common_config`
3. **External block** (`tilsit.vip`) — Uses Let's Encrypt DNS-01 via Cloudflare for public TLS. Imports `common_config`

The `(common_config)` snippet contains all shared logic:

- **Network matchers**: `@local_network` and `@external_network` based on `10.0.15.0/24`
- **Basic auth**: Only applied to `@external_auth_required` (external + `host tilsit.vip`)
- **Media file browser**: `/media/*` reverse-proxied to `localhost:9880` (Python file server, local network only)
- **Reverse proxies**: `/transmission/*` to `localhost:9091`
- **Static files**: Served from `/usr/local/var/www`
- **Logging**: JSON format to `/usr/local/var/log/caddy/access.log`

### Environment Variables

- `HOSTNAME` — **Required**. Used in site address (`{$HOSTNAME}.local`). Set via `hostname -s`
- `CF_API_TOKEN` — **Required** for Cloudflare DNS-01 cert issuance/renewal. Injected at runtime by `caddy-wrapper.sh` from the System keychain; never set in the plist or Caddyfile directly
- `SYNOLOGY_HOST` — Optional. Defaults to `pecorino.local`

### File Layout (in mac-server-setup)

- `app-setup/caddy-setup.sh` — Full deployment script: copies web assets, Caddyfile, wrapper script, and LaunchDaemon plists to their deployed locations, then validates config
- `app-setup/templates/Caddyfile` — Production config (the main file you'll edit)
- `app-setup/templates/caddy-wrapper.sh` — Reads `CF_API_TOKEN` from System keychain, exports it, then `exec`s Caddy. Deployed to `/usr/local/bin/caddy-wrapper.sh`
- `app-setup/templates/caddy-health.sh` — Tests landing page, proxies, certs, and process status
- `app-setup/templates/media-server.py` — Python HTTP file server for NFS media volume (binds to `127.0.0.1:9880`)
- `app-setup/templates/www/` — Static web root (dashboard `index.html`, favicons, manifest)
- `app-setup/templates/com.caddyserver.caddy.plist` — Caddy LaunchDaemon
- `app-setup/templates/com.tilsit.media-server.plist` — Media server LaunchDaemon
- `app-setup/templates/caddy-root-ca.crt` — Internal CA root certificate for client trust

### Deployment Path

Files are not served directly from the repo. `caddy-setup.sh` deploys everything to the correct locations:

- `www/*` → `/usr/local/var/www/` (web root)
- `Caddyfile` → `/Users/operator/.config/caddy/Caddyfile` (runtime config)
- `caddy-wrapper.sh` → `/usr/local/bin/caddy-wrapper.sh` (token injection wrapper)
- `media-server.py` → `/usr/local/bin/media-server.py` (NFS media file server)
- `LaunchDaemons/*.plist` → `/Library/LaunchDaemons/` (system services)

After deploying, restart both services:

```bash
sudo launchctl kickstart -k system/com.caddyserver.caddy
sudo launchctl kickstart -k system/com.tilsit.media-server
```

### Media File Server

The `/media/` path serves a file browser for the DSMedia NFS mount at `/Users/operator/.local/mnt/DSMedia`. Due to a macOS security restriction, Caddy cannot access NFS mounts directly — macOS blocks all launchd-spawned processes from NFS mounts unless the binary has **Full Disk Access** (FDA) granted in System Preferences → Privacy & Security → Full Disk Access.

Architecture: `media-server.py` (Python `http.server`) runs as a LaunchDaemon (`com.tilsit.media-server`) on `127.0.0.1:9880`. Caddy reverse-proxies `/media/*` to it. The `@not_local` matcher blocks external access with a 403.

**Prerequisite:** `/usr/bin/python3` must have Full Disk Access granted (done 2026-03-25). Without FDA, the media server will start but return "No permission to list directory" errors.

```bash
# Check media server status
sudo launchctl print system/com.tilsit.media-server | grep state

# Test directly
curl http://127.0.0.1:9880/

# Logs
cat /Users/operator/.local/state/caddy/media-server.log
```

### Custom Caddy Build

The deployed Caddy binary includes the `caddy-dns/cloudflare` DNS challenge module, which is **not** present in the Homebrew stock binary.

**Do not use xcaddy.** `xcaddy` is not available as a Homebrew formula. Use Caddy's official pre-built download API instead:

```bash
# Dev machine — download arm64 binary with cloudflare module
curl -L "https://caddyserver.com/api/download?os=darwin&arch=arm64&p=github.com%2Fcaddy-dns%2Fcloudflare" \
  -o /tmp/caddy-cloudflare
chmod +x /tmp/caddy-cloudflare

# Verify the module is present before deploying
/tmp/caddy-cloudflare list-modules | grep cloudflare
# Expected: dns.providers.cloudflare

rsync /tmp/caddy-cloudflare operator@tilsit.local:/tmp/caddy-cloudflare
```

On TILSIT (as `operator`):

```bash
sudo cp /opt/homebrew/bin/caddy /opt/homebrew/bin/caddy.homebrew-backup
sudo cp /tmp/caddy-cloudflare /opt/homebrew/bin/caddy
sudo chmod +x /opt/homebrew/bin/caddy
/opt/homebrew/bin/caddy version
/opt/homebrew/bin/caddy list-modules | grep cloudflare
```

**Caddy is pinned** (`brew pin caddy`) to prevent `brew upgrade` from overwriting the custom build. Run `brew pin caddy` as the `andrewrich` account (not `operator`) since Homebrew requires the admin account.

To update after a Caddy version bump: download a fresh binary from the API above, replace, and re-pin.

Check current binary: `/opt/homebrew/bin/caddy list-modules | grep cloudflare` (expect `dns.providers.cloudflare`)

---

## TLS Strategy

### LAN (Internal)

Caddy's internal PKI with 90-day intermediate certs (`intermediate_lifetime 90d` in global config). Clients must install `caddy-root-ca.crt` to trust these certs. The internal block matches `{$HOSTNAME}.local localhost 10.0.15.4` and uses `tls internal`.

### WAN (Let's Encrypt DNS-01 via Cloudflare)

No inbound ports needed — the DNS-01 challenge proves domain ownership by creating a TXT record at `_acme-challenge.tilsit.vip` via the Cloudflare API rather than serving a file over HTTP.

**Token injection chain:**

```text
System keychain (root-accessible)
  → caddy-wrapper.sh  (reads via `security find-generic-password`)
  → CF_API_TOKEN env var  (exported before exec)
  → Caddy process  (reads via {env.CF_API_TOKEN} in Caddyfile)
  → caddy-dns/cloudflare module  (makes Cloudflare API calls)
```

The token never appears in the LaunchDaemon plist (world-readable at `/Library/LaunchDaemons/`) or in the Caddyfile (readable by operator). The plist calls `/bin/bash /usr/local/bin/caddy-wrapper.sh`; the wrapper reads the token from the System keychain and `exec`s Caddy.

**Verify the LaunchDaemon is using the wrapper:**

```bash
sudo launchctl print system/com.caddyserver.caddy | grep -A3 "program ="
# Expected:
#   program = /bin/bash
#   arguments = {
#       /bin/bash
#       /usr/local/bin/caddy-wrapper.sh
```

**Verify the token is valid:**

```bash
CF_TOKEN=$(sudo security find-generic-password \
  -s cloudflare-api-token -a tilsit.vip -w \
  /Library/Keychains/System.keychain)
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  | python3 -m json.tool
unset CF_TOKEN
# Expected: "status": "active"
```

---

## certmagic DNS Propagation: Two Knobs

The `caddy-dns/cloudflare` module uses certmagic internally. certmagic has two separate knobs for DNS propagation that are easy to confuse:

### Environment Variable Syntax: `{$VAR}` vs `{env.VAR}`

**Critical:** There are two env var syntaxes in Caddy and they are NOT interchangeable in all contexts.

| Syntax | Processed by | When | Result in JSON config |
|--------|-------------|------|-----------------------|
| `{$CF_API_TOKEN}` | Caddyfile adapter | At parse time | Actual token value baked in |
| `{env.CF_API_TOKEN}` | Caddy runtime | At request time (HTTP handlers) | Literal string passed to module |

The `dns cloudflare` directive is a TLS module config value, not an HTTP handler. The cloudflare DNS module receives whatever string is in `api_token` and uses it as a Bearer token. If `{env.CF_API_TOKEN}` is used, the literal text `{env.CF_API_TOKEN}` is passed to the module, Cloudflare rejects it as an invalid token, and the DNS challenge fails silently — no TXT record is ever created, and Let's Encrypt returns HTTP 403.

**Always use `{$CF_API_TOKEN}` (dollar-sign form) for TLS/DNS module configuration.**

You can verify the active config was substituted correctly:

```bash
curl -s http://localhost:2019/config/apps/tls | python3 -c "
import sys, json
cfg = json.load(sys.stdin)
policies = cfg.get('automation', {}).get('policies', [])
for p in policies:
    if 'tilsit.vip' in p.get('subjects', []):
        print(json.dumps(p, indent=2))
"
```

If `api_token` shows `{env.CF_API_TOKEN}` (literal), the substitution failed. If it shows the actual token value, it's correct.

---

### `propagation_timeout`

Controls how long certmagic will **poll** the authoritative nameservers itself before giving up and signaling LE. Default is a few minutes.

**Setting on TILSIT:** `propagation_timeout -1` disables certmagic's own propagation poll entirely. certmagic creates the TXT record via the Cloudflare API, then immediately signals LE that the challenge is ready — without checking propagation itself. Let's Encrypt performs its own independent check from their servers.

This avoids issues where certmagic's direct TCP/53 queries to Cloudflare's authoritative nameservers may be blocked by network configuration or VPN routing.

### `propagation_delay`

A fixed sleep inserted **after** creating the TXT record via the API and **before** signaling LE that the challenge is ready. Default is 0 (no delay).

**Why this matters:** With `propagation_timeout -1`, certmagic notifies LE the instant the Cloudflare API call returns successfully. Cloudflare's authoritative nameservers may not have propagated the new TXT record to all resolvers by the time LE's servers query them. This creates a race: if LE polls before the record propagates, it gets a 403 "No TXT record found."

**`propagation_delay 30s` is required on TILSIT.** Without it, certmagic notifies LE immediately after the Cloudflare API call returns; LE's resolvers check before Cloudflare has propagated the record to its authoritative nameservers, resulting in HTTP 403 "No TXT record found" on every attempt. The current Caddyfile includes this.

```caddyfile
tilsit.vip {
    tls {
        issuer acme {
            dir https://acme-v02.api.letsencrypt.org/directory
            dns cloudflare {$CF_API_TOKEN}
            propagation_timeout -1
            propagation_delay 30s
        }
    }
    import common_config
}
```

certmagic retries cert issuance up to 3 times with 60-second gaps. A single propagation race is usually self-correcting on the first retry.

---

## ACME State Directory Structure

Caddy stores ACME data under `~/Library/Application Support/Caddy/` (as whatever user it runs as — `root` for the LaunchDaemon, so `/var/root/Library/Application Support/Caddy/`, but the plist sets `HOME=/Users/operator` so it ends up at `/Users/operator/Library/Application Support/Caddy/`).

```text
~/Library/Application Support/Caddy/
  certificates/
    local/                                           # Internal PKI certs — do NOT delete
    acme-v02.api.letsencrypt.org-directory/          # Production LE certs + keys
    acme-staging-v02.api.letsencrypt.org-directory/  # Staging LE certs + keys (if any)
  acme/
    acme-v02.api.letsencrypt.org-directory/          # Production ACME account keypair + registration
    acme-staging-v02.api.letsencrypt.org-directory/  # Staging ACME account keypair (if any)
  pki/
    authorities/
      local/                                         # Internal CA root + intermediate — do NOT delete
```

**Critical:** `certificates/` and `acme/` are separate trees. Deleting only `certificates/` removes the issued cert but leaves the ACME account data in `acme/`. On the next startup, Caddy finds the existing account and reuses it — including any stale staging account. You must clear **both** directories for each CA you want to reset.

### Clearing All ACME State (Both Staging and Production)

Run as `operator` (Caddy runs as root but writes to operator's home via the plist's `HOME` env var):

```bash
rm -rf "/Users/operator/Library/Application Support/Caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory"
rm -rf "/Users/operator/Library/Application Support/Caddy/certificates/acme-v02.api.letsencrypt.org-directory"
rm -rf "/Users/operator/Library/Application Support/Caddy/acme/acme-staging-v02.api.letsencrypt.org-directory"
rm -rf "/Users/operator/Library/Application Support/Caddy/acme/acme-v02.api.letsencrypt.org-directory"
```

Verify only `local/` remains:

```bash
ls "/Users/operator/Library/Application Support/Caddy/certificates/"
ls "/Users/operator/Library/Application Support/Caddy/acme/"
```

### Staging Account Pitfall

If Caddy ever ran without an explicit `dir` in the Caddyfile (e.g., during early testing), certmagic may have registered an account against the staging CA. The staging account persists in `acme/acme-staging-v02...`. On subsequent startups, if `dir` is still not set, Caddy may find and reuse the staging account, issuing untrusted certs.

**Always include an explicit `dir` pointing to the production CA:**

```caddyfile
issuer acme {
    dir https://acme-v02.api.letsencrypt.org/directory
    ...
}
```

Verifiable in the log: look for `"ca":"https://acme-v02.api.letsencrypt.org/directory"` (production) vs `"ca":"https://acme-staging-v02.api.letsencrypt.org/directory"` (staging).

---

## Troubleshooting Cert Issuance

### Symptom: staging CA used instead of production

Log shows `acme-staging-v02.api.letsencrypt.org`. Cause: stale staging ACME account in `acme/` directory, and missing explicit `dir` in Caddyfile.

Fix:

1. Add `dir https://acme-v02.api.letsencrypt.org/directory` to the `issuer acme` block
2. Clear both `acme/acme-staging*` and `acme/acme-v02*` directories
3. Reload Caddy

### Symptom: DNS propagation timeout (`dial tcp <ip>:53: i/o timeout`)

certmagic cannot reach Cloudflare's authoritative nameservers on TCP/53. This can be caused by network configuration, VPN routing, or firewall rules blocking direct DNS queries.

Fix: `propagation_timeout -1` in the `issuer acme` block.

### Symptom: "No TXT record found at _acme-challenge.tilsit.vip" (HTTP 403)

certmagic created the TXT record via the Cloudflare API but LE's resolvers checked before the record propagated from Cloudflare's authoritative NS.

Diagnosis:

- Verify the token is valid: `curl .../user/tokens/verify` (see command above)
- Verify the LaunchDaemon uses the wrapper: `sudo launchctl print system/com.caddyserver.caddy | grep -A3 "program ="`
- certmagic retries automatically (3 attempts, 60s apart) — a single failure is usually self-correcting

If it fails all 3 attempts: add `propagation_delay 30s` to the `issuer acme` block.

### Reading cert issuance logs

```bash
tail -f ~/.local/state/caddy/caddy-error.log | grep -i 'tilsit\|acme\|certif\|cloudflare\|obtain\|error'
```

Key log messages in order of a successful issuance:

```text
"msg":"obtaining certificate","identifier":"tilsit.vip"
"msg":"using ACME account","account_id":"https://acme-v02.api.letsencrypt.org/acme/acct/..."
"msg":"trying to solve challenge","challenge_type":"dns-01"
"msg":"certificate obtained successfully","identifier":"tilsit.vip"
```

### Verifying a live cert

```bash
curl -sk https://tilsit.vip:24443 -o /dev/null -w '%{http_code} %{ssl_verify_result}\n'
# Expected: 200 0  or  401 0
# ssl_verify_result=0 means the cert is trusted by the system
```
