# Cloudflare Tunnel and Access (example.com)

`example.com` reaches the server through a Cloudflare Tunnel, behind
Cloudflare Access with Google sign-in. There is no inbound port and no
browser password prompt. `your-server.local` on the LAN does not change.

Issue #209 (gateway, decision G2). This build also delivers the routing
from #210 (decision R3): `example.com` works the same on the LAN and outside it,
because it no longer resolves to the home IP. Plan:
`docs/plans/2026-10-22-g2-tunnel-access-implementation.md`.

## Architecture

```text
Browser (anywhere, including LAN)
  → example.com  (proxied CNAME → <tunnel-id>.cfargotunnel.com)
  → Cloudflare Access  (Google sign-in; allow: one email address)
  → Cloudflare Tunnel  (outbound connection from YOUR_SERVER)
  → cloudflared on YOUR_SERVER  (rejects requests without a valid Access JWT)
  → Caddy http://127.0.0.1:8080  (tunnel-only site, loopback bind)
  → / landing page, /transmission/ → 127.0.0.1:9091

LAN only, unchanged:
  your-server.local → Caddy :443 (tls internal) → no auth from LAN
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
   app `accesstest.example.com`, since deleted): a signed-in request that
   sent `Cf-Access-Authenticated-User-Email: forgot@example.com` reached
   the origin with exactly one value, the real signed-in email. The forged
   value never arrived. Restored by Andrew on 2026-10-22, after an earlier
   draft dropped it.
4. **Drift watchdog** (below). It reads the application, the policy and the
   tunnel ingress every 15 minutes and emails on any change from the
   expected rule.
5. **Loopback bind.** Caddy's tunnel listener is `127.0.0.1:8080`, so
   nothing off-host can reach it.

**Not used, by decision:**

- An origin JWT check in Caddy. cloudflared already checks the JWT.
- `basic_auth` on the tunnel site. It brings back the browser password
  prompt after Google sign-in, which is the problem #209 exists to solve.

The watchdog also covers the tunnel's ingress rules. A new public hostname
routed to `:8080` without Access, or `access.required` turned off, would
still meet the email check (layer 3), but it now raises an alert as well.

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

See `caddy.md` for the rest of the Caddyfile.

## Cloudflare objects

All in the Cloudflare account that holds `example.com` (Free plan). The ids
are not secrets, but they are specific to one server, so they are not listed
here. The operator keeps them in `local/operator-notes.md` (gitignored). The
repo templates take them from `config.conf`.

| Object | Name | Id |
| --- | --- | --- |
| Account | `you@example.com's Account` | in the operator note |
| Zero Trust team | `your-team` (`your-team.cloudflareaccess.com`) | |
| Access application (self-hosted) | `example.com` | in the operator note |
| Application AUD tag | | in the operator note |
| Reusable Access policy (Allow) | `<hostname>-allow-<you>` | in the operator note |
| Identity provider | Google | in the operator note |
| Tunnel (remotely managed) | `<hostname>` | in the operator note |

The tunnel ingress (set in Cloudflare, not in this repo): `example.com` →
`http://127.0.0.1:8080` with `originRequest.access.required: true`, the team
name and the AUD tag; catch-all → `http_status:404`.

## Token chain

Two secrets, both in the System keychain (`/Library/Keychains/System.keychain`),
both entered by Andrew at a prompt so that the value is never in a command
line, shell history or a transcript.

| Item (service / account) | What | Read by |
| --- | --- | --- |
| `cloudflare-tunnel-token` / `example.com` | Tunnel token: anyone with it can run the tunnel | `cloudflared-wrapper.sh` (root, every start) |
| `cloudflare-access-readonly-token` / `example.com` | API token, Access: Apps and Policies Read, and Cloudflare Tunnel: Read | `access-policy-watchdog-setup.sh` (root, at deploy) |

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
system/com.<hostname>.cloudflare-tunnel`. The keychain command must let
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
| `app-setup/tunnel-watchdog-setup.sh` | (run with sudo) |
| `app-setup/templates/tunnel-watchdog.sh` | `~operator/.local/bin/tunnel-watchdog` (0700) |
| `app-setup/templates/com.tunnel-watchdog.plist` | `~operator/Library/LaunchAgents/com.<host>.tunnel-watchdog.plist` |
| `tests/cloudflared-wrapper.bats`, `tests/access-policy-watchdog.bats`, `tests/tunnel-watchdog.bats`, `tests/caddyfile.bats` | |

Logs: `~operator/.local/state/cloudflared/cloudflared-error.log` (cloudflared
logs to stderr), `~operator/.local/state/access-policy-watchdog.log`,
`~operator/.local/state/tunnel-watchdog.log`. All are in
`config/logrotate.conf`.

`config.conf` keys: `EXTERNAL_HOSTNAME`, `TUNNEL_METRICS_PORT` (default
20241, the first port cloudflared tries on its own; it was free on
2026-10-22), `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ACCESS_APP_ID`,
`CLOUDFLARE_ACCESS_POLICY_ID`, `CLOUDFLARE_ACCESS_IDP_ID`,
`ACCESS_ALLOWED_EMAIL`, `CLOUDFLARE_TUNNEL_ID`,
`CLOUDFLARE_ACCESS_TEAM_NAME`, `CLOUDFLARE_ACCESS_AUD_TAG`,
`MONITORING_EMAIL`.

## Tunnel daemon

`sudo ./cloudflared-setup.sh` (from `app-setup/`). It installs cloudflared
with Homebrew if it is missing (as the admin account that ran sudo), checks
that the keychain item exists (without printing it), checks that the
metrics port is free, creates the log directory (launchd does not), deploys
the wrapper and plist, bootstraps the daemon, and waits up to 60 s for
`/ready`.

```bash
sudo launchctl print system/com.<hostname>.cloudflare-tunnel | head
curl -s http://127.0.0.1:20241/ready          # 200 once connected to the edge
sudo launchctl kickstart -k system/com.<hostname>.cloudflare-tunnel
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
- `GET /accounts/<account>/cfd_tunnel/<tunnel id>/configurations`

and compares them with an exact expected shape. It is not a list of bad
selectors or rules, so a selector or setting Cloudflare adds later still
counts as drift.

| Check | Expected |
| --- | --- |
| Application `domain` | `example.com` |
| Application `allowed_idps` | exactly `[<Google IdP id>]` (an empty list allows every IdP, including one-time PIN) |
| Application `policies[].id` | exactly `[<policy id>]`: no second policy, ours not detached |
| Policy `decision` | `allow` |
| Policy `include` | exactly `[{"email": {"email": "<allowed email>"}}]` (email compared without case) |
| Policy `require`, `exclude` | empty |
| Tunnel `config.ingress` | exactly two rules: `example.com` (hostname compared without case) → `http://127.0.0.1:8080` with `originRequest` exactly `{access: {required: true, teamName: <team>, audTag: [<AUD>]}}`; then `http_status:404`. A second hostname, a path rule, or a catch-all that serves anything is drift. |
| Tunnel `config["warp-routing"].enabled` | `false` or absent. When on, the tunnel routes private networks (the LAN) past Access and Caddy. |
| Tunnel `config`, other keys | none (for example, a global `originRequest`) |

The origin `http://127.0.0.1:8080` is a constant in the watchdog, not a
config value, because the Caddyfile hard-codes the tunnel site's port. A
test fails if the two differ.

It sends mail through `alert_transition` (see `monitoring.md`):

| Key | Bad when | Notes |
| --- | --- | --- |
| `policy_drift` | any check above fails | The email lists each difference. If the differences change while the alert is open, one more email ("changed again"). Reminder every 12 h. Recovery email when the rule matches again. |
| `access_missing` | the application, the policy or the tunnel returns HTTP 404 | Alerts on the first poll: a 404 is a confirmed state, not a blip. |
| `api_failing` | 3 polls in a row could not read the API (network, 401/403, 5xx, a non-success body, or no token file). A 401/403 on the tunnel names the missing Cloudflare Tunnel: Read permission. | During a failure the drift and missing alerts are left exactly as they are. Resolving them would send a false all-clear while the policy may still be wide open. |

State: `~operator/.config/access-policy-watchdog/state.json`. The API token
reaches curl on stdin (`curl -K -`), never in its argument list, which `ps`
shows to every user.

### Why an operator LaunchAgent, not a root LaunchDaemon

Mail goes out through msmtp with operator's config
(`~operator/.config/msmtp/config`, mode 600, password inside). msmtp refuses
such a file unless the invoking user owns it ("contains secrets and therefore
must be owned by you"). A root daemon could read the API token from the
System keychain but could never send the alert: the silent failure this
repo already had once (`monitoring.md`, "The launchd PATH problem").
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
sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.access-policy-watchdog
tail -f /Users/operator/.local/state/access-policy-watchdog.log
```

## Tunnel health watchdog

The drift watchdog checks the Cloudflare configuration, not whether the
tunnel is up. When cloudflared stops or loses every edge connection,
`example.com` shows a Cloudflare error page to every visitor, and nothing on
the server notices. `tunnel-watchdog` covers that (issue #237).

It runs every 60 s (operator LaunchAgent, `com.<host>.tunnel-watchdog`,
RunAtLoad) and requests `http://127.0.0.1:<TUNNEL_METRICS_PORT>/ready`.
cloudflared answers 200 while at least one edge connection is registered,
and 503 when none is. No answer means the daemon is not running.

| Key | Bad when | Notes |
| --- | --- | --- |
| `tunnel_down` | 3 checks in a row (about 3 minutes) got a non-200 answer or no answer | One check that fails is not an alert: a reconnect or a daemon restart (`KeepAlive`, `brew upgrade`) takes seconds. Reminder every 12 h. Recovery email when `/ready` returns 200 again. |

It only alerts. It does not restart the daemon: launchd's `KeepAlive`
already does that, so an alert means a restart did not fix it.

The OK heartbeat (hourly) logs the number of ready connections, normally 4.
A lower number is still ready, so it does not alert, but the log shows it.

State: `~operator/.config/tunnel-watchdog/state.json`. Operator, not root,
for the same msmtp reason as the drift watchdog. No token is needed: the
metrics server listens on loopback with no authentication.

```bash
cd ~/Developer/mac-server-setup/app-setup
sudo ./tunnel-watchdog-setup.sh
sudo -H -u operator /bin/bash /Users/operator/.local/bin/tunnel-watchdog --check
tail -f /Users/operator/.local/state/tunnel-watchdog.log
```

The setup script uses the same `TUNNEL_METRICS_PORT` default and check as
`cloudflared-setup.sh` (a test keeps the defaults equal). It loads the agent
only if `--check` passes (exit 0 ready, 1 not ready; no mail, no state).

## Revocation

- Remove the email from the Access policy, or revoke active sessions in Zero
  Trust (Users / Access sessions).
- To cut off the origin entirely, stop the daemon
  (`sudo launchctl bootout system/com.<hostname>.cloudflare-tunnel`), or delete
  or rotate the tunnel.

## Rollback

Until the old WAN path is removed (plan Task 7):

1. Delete the `example.com` CNAME and recreate the A record with the recorded
   values, `proxied: false`. A proxied record cannot carry port 24443.
2. The new record has a new id. Update `CLOUDFLARE_RECORD_ID`, re-run
   `cloudflare-ddns-setup.sh`, then `sudo launchctl enable
   system/com.<hostname>.cloudflare-ddns` and bootstrap it.
3. The old `example.com:24443` path, with `basic_auth`, works again. The
   `example.com` site block stays in the Caddyfile for this reason.

Stopping only the tunnel daemon makes Cloudflare show an error page for
`example.com`. `your-server.local` does not change.

## Tests

```bash
bats tests/caddyfile.bats              # tunnel site and site_routes
bats tests/cloudflared-wrapper.bats    # token via env only; keychain miss
bats tests/access-policy-watchdog.bats # expected rule and ingress, widenings, 404, API errors
bats tests/tunnel-watchdog.bats        # /ready 200, 503, no answer; failure streak; recovery
```

The watchdog tests run the rendered script with `/bin/bash` (bash 3.2, as
launchd runs it) against a curl mock and fixtures in
`tests/fixtures/cloudflare-access/`.
