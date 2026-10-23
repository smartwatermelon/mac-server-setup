# Cloudflare Tunnel and Access (tilsit.vip)

`tilsit.vip` reaches the server through a Cloudflare Tunnel, behind
Cloudflare Access with Google sign-in. There is no inbound port and no
browser password prompt. `tilsit.local` on the LAN does not change.

Issue #209 (gateway, decision G2). This build also delivers the routing
from #210 (decision R3): `tilsit.vip` works the same on the LAN and outside it,
because it no longer resolves to the home IP. Plan:
`docs/plans/2026-10-22-g2-tunnel-access-implementation.md`.

## Architecture

```text
Browser (anywhere, including LAN)
  → tilsit.vip  (proxied CNAME → <tunnel-id>.cfargotunnel.com)
  → Cloudflare Access  (Google sign-in; allow: one email address)
  → Cloudflare Tunnel  (outbound connection from TILSIT)
  → cloudflared on TILSIT  (rejects requests without a valid Access JWT)
  → Caddy http://127.0.0.1:8080  (tunnel-only site, loopback bind)
  → / landing page, /transmission/ → 127.0.0.1:9091

LAN only, unchanged:
  tilsit.local → Caddy :443 (tls internal) → no auth from LAN
```

### What protects the tunnel path

1. **Access policy at the edge.** Google identity, one allowed email.
2. **cloudflared JWT check** (`originRequest.access.required: true` on the
   tunnel ingress, set in Cloudflare). It proves only that the request
   carries a valid token for **this** Access application. It blocks everyone
   if the application is deleted or replaced. It does **not** help if the
   policy is widened: every newly allowed visitor then gets a valid token.
3. **Origin email check** (Caddy). The tunnel site returns 403 unless
   `Cf-Access-Authenticated-User-Email` is exactly `ACCESS_ALLOWED_EMAIL`.
   This is the layer that still holds if the policy is widened. It depends
   on Cloudflare overwriting the header, so a signed-in client cannot forge
   it. Plan Task 2b tested that on 2026-10-22 through this tunnel (temporary
   app `accesstest.tilsit.vip`, since deleted): a signed-in request that
   sent `Cf-Access-Authenticated-User-Email: forgot@example.com` reached
   the origin with exactly one value, the real signed-in email. The forged
   value never arrived. Restored by Andrew on 2026-10-22, after an earlier
   draft dropped it.
4. **Policy-drift watchdog** (below). It reads the application and policy
   every 15 minutes and emails on any change from the expected rule.
5. **Loopback bind.** Caddy's tunnel listener is `127.0.0.1:8080`, so
   nothing off-host can reach it.

**Not used, by decision:**

- An origin JWT check in Caddy. cloudflared already checks the JWT.
- `basic_auth` on the tunnel site. It brings back the browser password
  prompt after Google sign-in, which is the problem #209 exists to solve.

**Not yet covered:** nothing watches the tunnel's ingress rules. A new public
hostname routed to `:8080` without Access, or `access.required` turned off,
would still meet the email check, but would not raise an alert. A follow-up
extends the drift watchdog to the ingress before cutover.

### The Caddy tunnel site

```caddyfile
http://:8080 {
    bind 127.0.0.1
    import access_log

    @access_user header Cf-Access-Authenticated-User-Email <allowed email>
    handle @access_user {
        import site_routes
    }
    handle {
        respond 403
    }
}
```

- It must not import `(common_config)`. cloudflared connects from loopback,
  and that snippet's auth matcher exempts loopback, so it would apply no
  auth. Its `/media` handler would also be reachable: the `@not_local` guard
  is keyed on `remote_ip`, and every tunnel request is local.
- `(site_routes)` holds the landing page, `/transmission/` and the
  QuickConnect redirects. It has no `/media` handler, so `/media` on the
  tunnel site falls through to `file_server` and returns 404.
- The routes sit inside `handle`, not at site level. Caddy sorts `redir`
  and `reverse_proxy` ahead of `handle`, so a route at site level would run
  before the email check. Inside a `handle`, Caddy sorts the routes the
  same way as on the other sites.
- Not a `route` block either: `route` runs directives in written order, and
  `file_server` comes first in `site_routes`, so it would answer every path.
- `(access_log)` is separate from `(site_routes)` because `log` is a
  site-level directive, which `handle` does not accept. The 403s are logged
  too.

See `caddy-README.md` for the rest of the Caddyfile.

## Cloudflare objects

All in the Cloudflare account that holds `tilsit.vip` (Free plan). None of
these ids are secrets. The repo templates take them from `config.conf`.

| Object | Name | Id |
| --- | --- | --- |
| Account | `Andrew.rich@gmail.com's Account` | `36e63f08a319513d2e3827ddf440fc71` |
| Zero Trust team | `tiny-pond-a15e` (`tiny-pond-a15e.cloudflareaccess.com`) | |
| Access application (self-hosted) | `tilsit.vip` | `fe8dcc7a-1780-4188-85f7-9e616399c721` |
| Application AUD tag | | `c88730643f7e5723b386e4f1c5d01a94951f7716336e16645a4387596876a37a` |
| Reusable Access policy (Allow) | `tilsit-allow-andrew` | `d19c2ab1-83b3-4037-8576-1ed1d0ed16ef` |
| Identity provider | Google | `1a5a2d40-f042-4543-a590-97095828cef7` |
| Tunnel (remotely managed) | `tilsit` | `f5373cb8-a4e3-4eff-b8ca-575b97faa36a` |

The tunnel ingress (set in Cloudflare, not in this repo): `tilsit.vip` →
`http://127.0.0.1:8080` with `originRequest.access.required: true`, the team
name and the AUD tag; catch-all → `http_status:404`.

## Token chain

Two secrets, both in the System keychain (`/Library/Keychains/System.keychain`),
both entered by Andrew at a prompt so that the value is never in a command
line, shell history or a transcript.

| Item (service / account) | What | Read by |
| --- | --- | --- |
| `cloudflare-tunnel-token` / `tilsit.vip` | Tunnel token: anyone with it can run the tunnel | `cloudflared-wrapper.sh` (root, every start) |
| `cloudflare-access-readonly-token` / `tilsit.vip` | API token, Access: Apps and Policies Read | `access-policy-watchdog-setup.sh` (root, at deploy) |

```text
System keychain
  → cloudflared-wrapper.sh  (security find-generic-password ... -w)
  → TUNNEL_TOKEN env var  (exported, then exec)
  → cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run
```

Do not use `cloudflared service install <token>`. It writes the token into
`/Library/LaunchDaemons/com.cloudflare.cloudflared.plist`, which is
world-readable. Our daemon uses a different label,
`com.<host>.cloudflare-tunnel`, so a later `service install` cannot collide
with it.

To rotate the tunnel token: rotate it in the dashboard (Networks > Tunnels),
replace the keychain item, then `sudo launchctl kickstart -k
system/com.tilsit.cloudflare-tunnel`. The keychain command must let
`security` prompt for the value. Test the argument order on a scratch
keychain first: if a keychain path follows a bare `-w`, `security` may take
the path as the password.

## Files

| Repo file | Deployed to |
| --- | --- |
| `app-setup/cloudflared-setup.sh` | (run with sudo) |
| `app-setup/templates/cloudflared-wrapper.sh` | `/usr/local/bin/cloudflared-wrapper.sh` (root, 0755) |
| `app-setup/templates/com.cloudflare-tunnel.plist` | `/Library/LaunchDaemons/com.<host>.cloudflare-tunnel.plist` (0644) |
| `app-setup/access-policy-watchdog-setup.sh` | (run with sudo) |
| `app-setup/templates/access-policy-watchdog.sh` | `~operator/.local/bin/access-policy-watchdog` (0700) |
| `app-setup/templates/com.access-policy-watchdog.plist` | `~operator/Library/LaunchAgents/com.<host>.access-policy-watchdog.plist` |
| `tests/cloudflared-wrapper.bats`, `tests/access-policy-watchdog.bats`, `tests/caddyfile.bats` | |

Logs: `~operator/.local/state/cloudflared/cloudflared-error.log` (cloudflared
logs to stderr), `~operator/.local/state/access-policy-watchdog.log`. Both
are in `config/logrotate.conf`.

`config.conf` keys: `EXTERNAL_HOSTNAME`, `TUNNEL_METRICS_PORT` (default
20241, the first port cloudflared tries on its own; it was free on
2026-10-22), `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ACCESS_APP_ID`,
`CLOUDFLARE_ACCESS_POLICY_ID`, `CLOUDFLARE_ACCESS_IDP_ID`,
`ACCESS_ALLOWED_EMAIL`, `MONITORING_EMAIL`.

## Tunnel daemon

`sudo ./cloudflared-setup.sh` (from `app-setup/`). It installs cloudflared
with Homebrew if it is missing (as the admin account that ran sudo), checks
that the keychain item exists (without printing it), checks that the
metrics port is free, creates the log directory (launchd does not), deploys
the wrapper and plist, bootstraps the daemon, and waits up to 60 s for
`/ready`.

```bash
sudo launchctl print system/com.tilsit.cloudflare-tunnel | head
curl -s http://127.0.0.1:20241/ready          # 200 once connected to the edge
sudo launchctl kickstart -k system/com.tilsit.cloudflare-tunnel
tail -f /Users/operator/.local/state/cloudflared/cloudflared-error.log
```

The plist has `KeepAlive` true, so launchd restarts cloudflared after any
exit (30 s throttle). After `brew upgrade cloudflared`, the new binary runs
from the next restart; kickstart the daemon to pick it up at once.

## Drift watchdog

`access-policy-watchdog` runs every 15 minutes (operator LaunchAgent,
`com.<host>.access-policy-watchdog`, RunAtLoad). It reads:

- `GET /accounts/<account>/access/apps/<app id>`
- `GET /accounts/<account>/access/policies/<policy id>`

and compares them with an exact expected shape. It is not a list of bad
selectors, so a selector Cloudflare adds later still counts as drift.

| Check | Expected |
| --- | --- |
| Application `domain` | `tilsit.vip` |
| Application `allowed_idps` | exactly `[<Google IdP id>]` (an empty list allows every IdP, including one-time PIN) |
| Application `policies[].id` | exactly `[<policy id>]`: no second policy, ours not detached |
| Policy `decision` | `allow` |
| Policy `include` | exactly `[{"email": {"email": "<allowed email>"}}]` (email compared without case) |
| Policy `require`, `exclude` | empty |

It sends mail through `alert_transition` (see `monitoring-README.md`):

| Key | Bad when | Notes |
| --- | --- | --- |
| `policy_drift` | any check above fails | The email lists each difference. If the differences change while the alert is open, one more email ("changed again"). Reminder every 12 h. Recovery email when the rule matches again. |
| `access_missing` | the application or the policy returns HTTP 404 | Alerts on the first poll: a 404 is a confirmed state, not a blip. |
| `api_failing` | 3 polls in a row could not read the API (network, 401/403, 5xx, a non-success body, or no token file) | During a failure the drift and missing alerts are left exactly as they are. Resolving them would send a false all-clear while the policy may still be wide open. |

State: `~operator/.config/access-policy-watchdog/state.json`. The API token
reaches curl on stdin (`curl -K -`), never in its argument list, which `ps`
shows to every user.

### Why an operator LaunchAgent, not a root LaunchDaemon

Mail goes out through msmtp with operator's config
(`~operator/.config/msmtp/config`, mode 600, password inside). msmtp refuses
such a file unless the invoking user owns it ("contains secrets and therefore
must be owned by you"). A root daemon could read the API token from the
System keychain but could never send the alert: the silent failure this
repo already had once (`monitoring-README.md`, "The launchd PATH problem").
So the watchdog follows `plex-watchdog`: the setup script (root) copies the
read-only token from the keychain to `~operator/.config/access-policy-watchdog/token`
(mode 600, through a redirect, never an argument). The token can only read
Access configuration.

### Deploy

```bash
cd ~/Developer/mac-server-setup/app-setup
sudo ./access-policy-watchdog-setup.sh
```

It validates the config values, copies the token, deploys `alert-lib.sh`,
the watchdog and the plist, then runs `access-policy-watchdog --check` as
operator in launchd's environment (`env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin`).
`--check` sends no mail and changes no state; exit 0 = match, 1 = drift or
missing, 2 = API not readable. The agent is loaded only if the check passes.

**Not yet confirmed against the live API:** that the application response
lists the reusable policy under `policies[].id` with the policy's own id.
The Cloudflare API reference shows `id` on each `policies` item, but this
repo has not read the live response. If it differs, the deploy check fails
with a `policies` difference, and the agent is not loaded. Task 6 step 5 of
the plan confirms it.

Run the plan's live test once, with Andrew present: add a second email to
the policy, confirm the alert arrives, remove it, confirm the recovery email.

```bash
sudo -u operator /bin/bash /Users/operator/.local/bin/access-policy-watchdog --check
sudo launchctl kickstart -kp gui/$(id -u operator)/com.tilsit.access-policy-watchdog
tail -f /Users/operator/.local/state/access-policy-watchdog.log
```

## Revocation

- Remove the email from the Access policy, or revoke active sessions in Zero
  Trust (Users / Access sessions).
- To cut off the origin entirely, stop the daemon
  (`sudo launchctl bootout system/com.tilsit.cloudflare-tunnel`), or delete
  or rotate the tunnel.

## Rollback

Until the old WAN path is removed (plan Task 7):

1. Delete the `tilsit.vip` CNAME and recreate the A record with the recorded
   values, `proxied: false`. A proxied record cannot carry port 24443.
2. The new record has a new id. Update `CLOUDFLARE_RECORD_ID`, re-run
   `cloudflare-ddns-setup.sh`, then `sudo launchctl enable
   system/com.tilsit.cloudflare-ddns` and bootstrap it.
3. The old `tilsit.vip:24443` path, with `basic_auth`, works again. The
   `tilsit.vip` site block stays in the Caddyfile for this reason.

Stopping only the tunnel daemon makes Cloudflare show an error page for
`tilsit.vip`. `tilsit.local` does not change.

## Tests

```bash
bats tests/caddyfile.bats              # tunnel site and site_routes
bats tests/cloudflared-wrapper.bats    # token via env only; keychain miss
bats tests/access-policy-watchdog.bats # expected rule, widenings, 404, API errors
```

The watchdog tests run the rendered script with `/bin/bash` (bash 3.2, as
launchd runs it) against a curl mock and fixtures in
`tests/fixtures/cloudflare-access/`.
