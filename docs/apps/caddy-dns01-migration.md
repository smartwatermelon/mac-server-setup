# Migrate External TLS to DNS-01 Challenge (Cloudflare)

## Why This Is Needed

The current setup uses Let's Encrypt with TLS-ALPN-01 / HTTP-01 challenges, which
require Let's Encrypt validators to reach Caddy on **standard ports 443 or 80** from
the internet. Since port 24443 is forwarded (not 443), ACME challenges fail during
certificate renewal. Opening port 443 temporarily works but exposes the server to
constant scanning on a well-known port.

**DNS-01 challenge** proves domain ownership by creating a DNS TXT record — no
inbound ports needed. Caddy handles this automatically with a DNS provider plugin.

This migration also replaces `wellington.sytes.net` (No-IP) with your own domain on
Cloudflare's free DNS, giving you full DNS control and free dynamic DNS updates.

## Overview

1. Register a domain and add it to Cloudflare (free tier)
2. Create a Cloudflare API token
3. Set up dynamic DNS (replaces No-IP DUC)
4. Build Caddy with the Cloudflare DNS plugin
5. Update the Caddyfile
6. Update the LaunchDaemon environment
7. Deploy and verify

---

## Step 1: Register a Domain and Add to Cloudflare

### Register a domain

Any registrar works (Cloudflare Registrar, Namecheap, Porkbun, etc.). Pick something
cheap — many TLDs are ~$10/year. Example: `richlab.net`, `tilsit.dev`, etc.

### Add the domain to Cloudflare

1. Create a free Cloudflare account at <https://dash.cloudflare.com/sign-up>
2. Click **Add a site** and enter your new domain
3. Select the **Free** plan
4. Cloudflare will scan existing DNS records (there won't be any for a new domain)
5. Cloudflare gives you two nameservers (e.g., `ada.ns.cloudflare.com`)
6. Go to your registrar and **change the nameservers** to the ones Cloudflare provided
7. Wait for propagation (usually minutes, can take up to 24 hours)
8. Cloudflare will confirm the domain is active

### Create DNS records

In Cloudflare DNS settings, add:

| Type | Name              | Content         | Proxy  | TTL  |
|------|-------------------|-----------------|--------|------|
| A    | `@` (root)        | (your public IP)| DNS only (gray cloud) | Auto |
| A    | `www` (optional)  | (your public IP)| DNS only (gray cloud) | Auto |

**Important**: Use **DNS only** (gray cloud), not **Proxied** (orange cloud). Proxied
mode routes traffic through Cloudflare's network, which breaks direct port-forwarded
access on non-standard ports like 24443.

The IP address will be managed automatically by the DDNS script (Step 3).

## Step 2: Create a Cloudflare API Token

1. Go to <https://dash.cloudflare.com/profile/api-tokens>
2. Click **Create Token**
3. Use the **Edit zone DNS** template, or create a custom token with:
   - **Permissions**: Zone → DNS → Edit
   - **Zone Resources**: Include → Specific zone → (your domain)
4. Click **Continue to summary** → **Create Token**
5. Copy the token — you won't see it again

Save the token somewhere safe (1Password, etc.). You'll need it for both Caddy and
the DDNS script.

## Step 3: Set Up Dynamic DNS (Replaces No-IP DUC)

You need something to update the Cloudflare A record when your public IP changes,
just like No-IP DUC does today.

### Option A: cloudflare-ddns (recommended)

Install via Homebrew on tilsit:

```bash
brew install cloudflare-ddns
```

Or use the Docker image: `timothymiller/cloudflare-ddns`

Or use the Python script directly:
<https://github.com/timothymiller/cloudflare-ddns>

Create a config file at `/Users/operator/.config/cloudflare-ddns/config.json`:

```json
{
  "cloudflare": [
    {
      "authentication": {
        "api_token": "YOUR_CLOUDFLARE_API_TOKEN"
      },
      "zone_id": "YOUR_ZONE_ID",
      "subdomains": [
        {
          "name": "",
          "proxied": false
        }
      ]
    }
  ],
  "a": true,
  "aaaa": false,
  "purgeUnknownRecords": false,
  "ttl": 300
}
```

Find your **Zone ID** on the Cloudflare dashboard sidebar for your domain (Overview page,
bottom-right under "API").

Set it up as a LaunchAgent or cron job to run every 5 minutes.

### Option B: Simple shell script

Create `/Users/operator/.local/bin/cloudflare-ddns.sh`:

```bash
#!/bin/bash
# Cloudflare DDNS updater
# Runs via cron/LaunchAgent every 5 minutes

CF_API_TOKEN="YOUR_TOKEN"
ZONE_ID="YOUR_ZONE_ID"
RECORD_NAME="yourdomain.com"

# Get current public IP
CURRENT_IP=$(curl -s https://api.ipify.org)

# Get current DNS record
RECORD=$(curl -s -X GET \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${RECORD_NAME}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json")

RECORD_ID=$(echo "$RECORD" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])")
RECORD_IP=$(echo "$RECORD" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['content'])")

# Update only if IP changed
if [ "$CURRENT_IP" != "$RECORD_IP" ]; then
  curl -s -X PUT \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${CURRENT_IP}\",\"ttl\":300,\"proxied\":false}" \
    > /dev/null
  echo "$(date): Updated DNS to ${CURRENT_IP}"
fi
```

### Transition period

Keep No-IP DUC running alongside the new DDNS until you've verified everything works.
Once confirmed, disable No-IP DUC.

## Step 4: Build Caddy with the Cloudflare DNS Plugin

The current Caddy installation (`/opt/homebrew/bin/caddy` v2.10.2) does not include
the Cloudflare DNS module. You need to build a custom binary.

### Install xcaddy

```bash
brew install xcaddy
```

Or if Go is installed:

```bash
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
```

### Build custom Caddy

```bash
xcaddy build --with github.com/caddy-dns/cloudflare
```

This produces a `caddy` binary in the current directory.

### Replace the system Caddy

```bash
# Stop Caddy first
sudo launchctl unload /Library/LaunchDaemons/com.caddyserver.caddy.plist

# Back up the original
sudo cp /opt/homebrew/bin/caddy /opt/homebrew/bin/caddy.orig

# Install the custom build
sudo cp ./caddy /opt/homebrew/bin/caddy
sudo chmod +x /opt/homebrew/bin/caddy

# Verify the module is present
caddy list-modules | grep cloudflare
# Should show: dns.providers.cloudflare
```

**Note**: `brew upgrade caddy` will overwrite your custom build. After upgrading Caddy
via Homebrew, you'll need to rebuild with xcaddy. Consider pinning:
`brew pin caddy`.

## Step 5: Update the Caddyfile

Edit `/Users/operator/.config/caddy/Caddyfile`.

### Change the external site block

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

With (substituting your actual domain):

```caddyfile
# External access with automatic HTTPS (Let's Encrypt via DNS-01)
yourdomain.com {
 tls {
  dns cloudflare {env.CF_API_TOKEN}
 }
 import common_config
}
```

### Update the external auth matcher

In the `(common_config)` snippet, update the hostname in `@external_auth_required`:

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
  host yourdomain.com
 }
```

### Update the header comment

Update the security configuration comment at the top to reflect the new hostname.

## Step 6: Update the LaunchDaemon Environment

The LaunchDaemon at `/Library/LaunchDaemons/com.caddyserver.caddy.plist` needs the
Cloudflare API token added to its environment variables.

Edit the plist to add `CF_API_TOKEN` to the `EnvironmentVariables` dict:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>HOSTNAME</key>
    <string>tilsit</string>
    <key>HOME</key>
    <string>/Users/operator</string>
    <key>USER</key>
    <string>operator</string>
    <key>CF_API_TOKEN</key>
    <string>YOUR_CLOUDFLARE_API_TOKEN</string>
</dict>
```

## Step 7: Clean Up Stale ACME State and Deploy

### Clear the old ACME data

The staging ACME account has already been removed (Feb 20, 2026). If needed, clear
everything for a fully fresh start:

```bash
# Remove all ACME data (Caddy will re-register on next start)
rm -rf "/Users/operator/Library/Application Support/Caddy/acme/"
rm -rf "/Users/operator/Library/Application Support/Caddy/certificates/acme-v02.api.letsencrypt.org-directory"
```

The internal/local certificates (for tilsit.local, localhost, 10.0.15.15) will be
untouched.

### Validate the new config

```bash
HOSTNAME=tilsit CF_API_TOKEN=your_token /opt/homebrew/bin/caddy validate \
  --config /Users/operator/.config/caddy/Caddyfile
```

### Restart Caddy

```bash
sudo launchctl unload /Library/LaunchDaemons/com.caddyserver.caddy.plist
sudo launchctl load /Library/LaunchDaemons/com.caddyserver.caddy.plist
```

### Verify certificate issuance

Watch the error log for successful certificate obtainment:

```bash
tail -f /Users/operator/.local/state/caddy/caddy-error.log | grep -i 'wellington\|yourdomain\|acme\|certif\|obtain'
```

You should see:

```text
"msg":"obtaining certificate","identifier":"yourdomain.com"
"msg":"certificate obtained successfully","identifier":"yourdomain.com"
```

If you see DNS challenge errors, check that:

- `CF_API_TOKEN` is set correctly in the LaunchDaemon
- The Cloudflare API token has Zone DNS Edit permissions
- The domain's nameservers point to Cloudflare

### Test external access

```bash
curl -sk https://yourdomain.com:24443 --resolve yourdomain.com:24443:127.0.0.1
```

### Update No-IP / port forwarding

Once verified:

1. Disable or remove the No-IP DUC client
2. Update any bookmarks or clients from `wellington.sytes.net:24443` to
   `yourdomain.com:24443`
3. No changes needed to port forwarding rules (24443 stays as-is)

---

## Rollback

If something goes wrong:

1. Restore the original Caddy binary:

   ```bash
   sudo cp /opt/homebrew/bin/caddy.orig /opt/homebrew/bin/caddy
   ```

2. Revert the Caddyfile changes (restore `wellington.sytes.net` block with the
   original ACME issuer config)

3. Remove `CF_API_TOKEN` from the LaunchDaemon plist

4. Restart Caddy:

   ```bash
   sudo launchctl unload /Library/LaunchDaemons/com.caddyserver.caddy.plist
   sudo launchctl load /Library/LaunchDaemons/com.caddyserver.caddy.plist
   ```

5. Temporarily open port 443 through NAT to allow TLS-ALPN-01 challenge, then close
   after cert is obtained (knowing it will break again at renewal in ~60 days)

---

## Quick Fix: Temporary Port 443 (Without Full Migration)

If you need external access working NOW before doing the full migration:

1. Forward port 443 through Quantum NID and Deco router to tilsit:443
2. Clear ACME state (already done as of Feb 20, 2026):

   ```bash
   rm -rf "/Users/operator/Library/Application Support/Caddy/acme/acme-staging-v02.api.letsencrypt.org-directory"
   ```

3. Restart Caddy — it will obtain a cert via production Let's Encrypt
4. Once cert is obtained, you can close port 443
5. Cert is valid for 90 days; renewal will fail when port 443 is closed

This buys time but does not solve the underlying problem.
