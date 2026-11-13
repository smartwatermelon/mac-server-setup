# Remote access problems

This page covers Caddy and its certificates, the `/media` file server, Cloudflare Tunnel and Access, the DDNS updater, and the home VPN. Run the checks as `admin` on the server unless a step says otherwise. In the examples, `example.com` is the public hostname (`EXTERNAL_HOSTNAME`).

For how these parts work, see [Caddy](../components/caddy.md), [TLS strategy](../explanation/tls-strategy.md), [Cloudflare Tunnel](../components/cloudflare-tunnel.md), [Tunnel security layers](../explanation/tunnel-security-layers.md), [Cloudflare DDNS](../components/cloudflare-ddns.md) and [Home VPN](../components/home-vpn.md).

## The LAN site does not load

**Cause**

1. Caddy is not running. The LaunchDaemon `com.caddyserver.caddy` runs `/usr/local/bin/caddy-wrapper.sh`. The wrapper exits when it cannot read `cloudflare-api-token` from the System keychain, and launchd tries again every 30 seconds.
2. The Caddyfile at `/Users/operator/.config/caddy/Caddyfile` is not valid.
3. The browser used a name that the Caddyfile does not know, or a bare IP address that is not the server's LAN address. The catch-all site answers those with 403 and `Access Denied: Invalid hostname or direct IP access not permitted`.

**Check**

```bash
sudo launchctl print system/com.caddyserver.caddy | grep -E 'state|last exit|pid'
sudo tail -30 /Users/operator/.local/state/caddy/caddy-error.log
/usr/local/bin/caddy-health.sh
```

- `state = running` with a `pid` means Caddy runs.
- `ERROR: cloudflare-api-token not found in System keychain` in the error log means the token is missing.
- `caddy-health.sh` tests the landing page, the HTTP redirect, the Transmission proxy, the CA download and the Caddy process, and marks each one OK or FAILED.

To check the Caddyfile without starting Caddy, use the same dummy token that `caddy-setup.sh` uses:

```bash
sudo HOSTNAME="$(hostname -s)" CF_API_TOKEN=dummy /opt/homebrew/bin/caddy validate \
  --config /Users/operator/.config/caddy/Caddyfile --adapter caddyfile
```

`Valid configuration` means the file is valid. Any other output names the line with the error.

**Fix**

1. If the token is missing, add it to the System keychain again. See [Cloudflare DDNS](../components/cloudflare-ddns.md) and [Credential chain](../explanation/credential-chain.md).
2. If the Caddyfile is not valid, run `sudo ./caddy-setup.sh` from `~/app-setup` to deploy it again from the template.
3. Restart Caddy:

    ```bash
    sudo launchctl kickstart -kp system/com.caddyserver.caddy
    ```

4. Use `https://<hostname>.local/` or the server's LAN address, for example `https://192.168.21.10/`.

## The browser says the LAN certificate is not trusted

**Cause**

The LAN site uses `tls internal`. Caddy signs its certificate with its own local CA, which your devices do not trust until you install the CA certificate.

**Check**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -k https://<hostname>.local/caddy-root-ca.crt
```

`200` means the CA certificate is published.

**Fix**

1. On each client, download `https://<hostname>.local/caddy-root-ca.crt`.
2. Install it, and mark it as trusted for SSL. On a Mac, use Keychain Access. On iOS, install the profile and then turn on full trust in Settings, General, About, Certificate Trust Settings.

## Links under /media fail

**Cause**

Caddy sends `/media/` to `media-server.py` on `127.0.0.1:9880`. That server runs as `operator` because Caddy runs as root and cannot read the NFS mount. If it is not running, or the NAS is not mounted, `/media` fails.

**Check**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9880/
sudo launchctl print system/com.<hostname>.media-server | grep -E 'state|last exit'
sudo tail -20 /Users/operator/.local/state/caddy/media-server.log
mount -t nfs
```

`000` from `curl` means the file server does not answer.

**Fix**

1. If the NAS is not mounted, fix the mount first. See [Plex libraries are empty or files show as unavailable](plex.md#plex-libraries-are-empty-or-files-show-as-unavailable).
2. Restart the file server:

    ```bash
    sudo launchctl kickstart -kp system/com.<hostname>.media-server
    ```

## Caddy cannot get a certificate for the public hostname

**Cause**

The public site uses a Let's Encrypt certificate through the DNS-01 challenge, with the Cloudflare API token. Issuance fails when:

1. The token is invalid or lacks `Zone:DNS:Edit` on the zone.
2. An old staging ACME account is reused. The Caddyfile sets the production CA with `dir`, but an old account under Caddy's `acme/` folder can still cause this.
3. Let's Encrypt checks the TXT record before it reaches Cloudflare's name servers. The template sets `propagation_delay 30s` and `propagation_timeout -1` for this.

**Check**

```bash
sudo grep -iE 'acme|obtain|certificate|error' /Users/operator/.local/state/caddy/caddy-error.log | tail -20
sudo security find-generic-password -s cloudflare-api-token -a example.com /Library/Keychains/System.keychain >/dev/null && echo "token present"
```

- `certificate obtained successfully` means issuance worked.
- `acme-staging-v02` in a log line means the staging CA was used.
- `No TXT record found` means the record was checked too early. Caddy tries 3 times, 60 seconds apart.
- The `security` command prints `token present` only if the keychain item exists. It does not print the token.

**Fix**

1. If the token is invalid, create a new one in the Cloudflare dashboard, with `Zone:DNS:Edit` on the zone, and store it in the System keychain again.
2. If the staging CA was used, clear the old `acme-staging*` and `acme-v02*` account folders in Caddy's data folder, then restart Caddy.
3. Restart Caddy:

    ```bash
    sudo launchctl kickstart -kp system/com.caddyserver.caddy
    ```

See "Troubleshooting Cert Issuance" in [Caddy](../components/caddy.md).

## The public hostname shows a Cloudflare error page

**Cause**

The Cloudflare Tunnel is down. The LaunchDaemon `com.<hostname>.cloudflare-tunnel` runs `/usr/local/bin/cloudflared-wrapper.sh`, which reads `cloudflare-tunnel-token` from the System keychain and starts `cloudflared`. Possible causes:

1. The token is not in the System keychain, so the wrapper exits.
2. `cloudflared` runs but has no connection to Cloudflare, for example during an internet outage.
3. Caddy is down, so the tunnel origin at `127.0.0.1:8080` does not answer.

`tunnel-watchdog` emails `Cloudflare Tunnel for example.com is down` after 3 failed checks, 1 minute apart. The LAN site is not affected.

**Check**

```bash
curl -s -w '\n%{http_code}\n' --max-time 5 http://127.0.0.1:20241/ready
sudo -H -u operator /bin/bash /Users/operator/.local/bin/tunnel-watchdog --check
sudo launchctl print system/com.<hostname>.cloudflare-tunnel | grep -E 'state|last exit'
sudo tail -50 /Users/operator/.local/state/cloudflared/cloudflared-error.log
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
```

- `/ready` returns `200` with a count of ready connections while the tunnel is up, and `503` when it has no connection. No answer means `cloudflared` is not running.
- `--check` prints the result, sends no email and changes no state. It exits 0 when the tunnel is ready.
- `ERROR: cloudflare-tunnel-token ... not found` in the error log means the token is missing.
- `403` from port 8080 is the expected answer for a request with no Access header. `000` means Caddy does not answer.

**Fix**

1. If the token is missing, store it in the System keychain again. See [Cloudflare Tunnel](../components/cloudflare-tunnel.md).
2. If Caddy does not answer, see [The LAN site does not load](#the-lan-site-does-not-load).
3. Restart the tunnel daemon:

    ```bash
    sudo launchctl kickstart -kp system/com.<hostname>.cloudflare-tunnel
    ```

## The public hostname returns 403 after sign-in

**Cause**

The Caddy tunnel site serves its routes only when the `Cf-Access-Authenticated-User-Email` header equals the one allowed email address. Any other request gets 403. Cloudflare Access sets the header after a sign-in. A 403 after a successful sign-in means the signed-in email is not the one in the Caddyfile, or the request did not come through Access.

**Check**

```bash
sudo grep '"status":403' /usr/local/var/log/caddy/access.log | tail -5
```

Look for the requests from the time of your sign-in, and for the request headers in each line.

**Fix**

1. Sign in with the allowed email address.
2. If the allowed address changed, change it in the Access policy and in `ACCESS_ALLOWED_EMAIL`, then run `sudo ./caddy-setup.sh` again and restart Caddy.

## The Access policy watchdog reports drift

**Cause**

`access-policy-watchdog` reads the Access application, the Access policy and the tunnel configuration from the Cloudflare API every 15 minutes. It compares each one with one exact expected rule. A change in the dashboard, even one that looks harmless, counts as drift. It also alerts when an object is missing or when the API cannot be read 3 times in a row.

**Check**

```bash
sudo -H -u operator /bin/bash /Users/operator/.local/bin/access-policy-watchdog --check
sudo grep -E 'DRIFT|MISSING|WARNING' /Users/operator/.local/state/access-policy-watchdog.log | tail -10
```

`--check` exits 0 when everything matches, 1 for drift or a missing object, and 2 when the API cannot be read. `DRIFT:` lines list each difference.

**Fix**

1. If the change was not yours, treat it as a security event. Revoke the active Access sessions in Zero Trust, and check who changed the policy.
2. Put the policy, the application or the tunnel ingress back to the expected rule in the Cloudflare dashboard. The rule is in "Drift watchdog" in [Cloudflare Tunnel](../components/cloudflare-tunnel.md).
3. If the API cannot be read, check the read-only token in `~/.config/access-policy-watchdog/token` of the `operator` account, and run `access-policy-watchdog-setup.sh` again.

## The DDNS record shows an old IP address

**Cause**

`com.<hostname>.cloudflare-ddns` runs every 5 minutes as root and updates the DNS-only record that the home VPN uses. It fails when:

1. `cloudflare-api-token` is missing from the System keychain.
2. The Cloudflare API rejects the request: the token was revoked or lacks `Zone:DNS:Edit`, or the record was deleted and created again with a new id.
3. No public IP provider answers. The script tries again on the next run.

**Check**

```bash
sudo tail -20 /Users/operator/.local/state/cloudflare-ddns.log
dig +short vpn.example.com @1.1.1.1
curl -s https://api.ipify.org; echo
```

- `heartbeat ok` means the record matches the public IP that the script saw.
- `cloudflare GET rejected` or `cloudflare PATCH rejected` lines include Cloudflare's response.
- `could not determine public IP from any provider` means the lookup failed.
- The `dig` answer must equal the `curl` answer.

**Fix**

1. For a missing or revoked token, store a valid token in the System keychain again.
2. For a record with a new id, update the record id in `config.conf` and run `sudo ./cloudflare-ddns-setup.sh` again.
3. Run an update now:

    ```bash
    sudo launchctl kickstart -kp system/com.<hostname>.cloudflare-ddns
    ```

4. If the log says `heartbeat ok` but a client still sees the old address, the client's resolver has the old answer cached.

## The home VPN connects at home but not from outside

**Cause**

The VPN client connects to `vpn.example.com`. That record must be an A record with Cloudflare proxying off (DNS only). A proxied record resolves to Cloudflare addresses, and Cloudflare does not carry the VPN port. A stale record points at an old home IP.

**Check**

From the client Mac:

```bash
dig +short vpn.example.com @1.1.1.1
```

The answer must be your home public IP. An answer in a Cloudflare range, such as an address that starts with `104.21.` or `2606:4700:`, means the record is proxied.

Then read the newest Tunnelblick log in `/Library/Application Support/Tunnelblick/Logs/`. A connection that stops at `TCP_CONNECT` to a Cloudflare address confirms it.

**Fix**

1. In the Cloudflare dashboard, set the record to DNS only.
2. If the address is old, see [The DDNS record shows an old IP address](#the-ddns-record-shows-an-old-ip-address).
3. Test from outside the LAN, for example from a phone hotspot with home Wi-Fi off.
