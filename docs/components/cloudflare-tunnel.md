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

Optional, when HOME_ASSISTANT_* is set (see "Home Assistant" below):
  ha.example.com → the same Access application, tunnel and Caddy site
  → Caddy hands the whole host to Home Assistant (192.168.21.20:8123)

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
  dashboard link redirects. It has no `/media` handler, so `/media` on the
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
`MONITORING_EMAIL`. Optional: `HOME_ASSISTANT_HOSTNAME`,
`HOME_ASSISTANT_UPSTREAM` (see [Home Assistant](#home-assistant)).

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
| Application `destinations` | exactly `[{type: public, uri: example.com}]`, plus `ha.example.com` when `HOME_ASSISTANT_HOSTNAME` is set (compared without order or case). With the key empty, an absent field is not drift. With it set, the field is required. |
| Application `self_hosted_domains` | when present, the same hostnames as `destinations` |
| Application `allowed_idps` | exactly `[<Google IdP id>]` (an empty list allows every IdP, including one-time PIN) |
| Application `policies[].id` | exactly `[<policy id>]`: no second policy, ours not detached |
| Policy `decision` | `allow` |
| Policy `include` | exactly `[{"email": {"email": "<allowed email>"}}]` (email compared without case) |
| Policy `require`, `exclude` | empty |
| Tunnel `config.ingress` | exactly two rules: `example.com` (hostname compared without case) → `http://127.0.0.1:8080` with `originRequest` exactly `{access: {required: true, teamName: <team>, audTag: [<AUD>]}}`; then `http_status:404`. A second hostname, a path rule, or a catch-all that serves anything is drift. With `HOME_ASSISTANT_HOSTNAME` set, exactly three: the `example.com` rule, then the same rule for `ha.example.com`, then `http_status:404`. |
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

## Home Assistant

Optional. Home Assistant (HA) gets its own hostname, such as
`ha.example.com`, behind the same Access application, the same tunnel and
the same Caddy tunnel site. HA cannot run under a URL path, so it needs its
own hostname at `/`. The feature is off until both config keys are set:

- `HOME_ASSISTANT_HOSTNAME`: the full hostname. It must be a lower-case
  subdomain of `EXTERNAL_HOSTNAME`, so the same Cloudflare zone and Access
  team cover it.
- `HOME_ASSISTANT_UPSTREAM`: HA as `host:port`, such as
  `192.168.21.20:8123`. Use an IP address. A `.local` name works, but its
  mDNS lookup can take about 5 s from the server, and `caddy-setup.sh`
  warns about it. IPv6 addresses are not accepted.

`caddy-setup.sh` and `access-policy-watchdog-setup.sh` stop on a bad value
before they write anything. With both keys empty, the rendered Caddyfile and
landing page are byte for byte the same as before the feature existed
(`tests/caddy-home-assistant.bats` checks this).

**Browser only.** The HA phone app and inbound webhooks cannot pass the
Google sign-in at Cloudflare Access, so they do not work through
`ha.example.com`. At home, use the LAN URL, such as
`http://192.168.21.20:8123`.

### What protects the HA path

The same layers as the main host, plus HA's own login:

1. Cloudflare Access: the same application, policy and allowed email.
2. cloudflared JWT check: the HA ingress rule has the same
   `access.required`, team name and AUD tag. The drift watchdog alerts if it
   does not.
3. Caddy email check: the HA route is inside `handle @access_user`, so a
   request without the allowed email gets 403 before HA sees it.
4. Drift watchdog: with the key set, it expects exactly the two hostnames on
   the application and exactly the two ingress rules (plus the catch-all).
5. Loopback bind: unchanged.

Inside `handle @access_user` the tunnel site has two mutually exclusive
`handle` blocks:

```caddyfile
@home_assistant host ha.example.com
handle @home_assistant {
    reverse_proxy 192.168.21.20:8123 {
        header_up X-Forwarded-For {http.request.header.Cf-Connecting-IP}
        header_up X-Forwarded-Proto https
        header_up -Cf-Access-Jwt-Assertion
        header_up Cookie "(^|;\s*)CF_Authorization=[^;]*" ""
        header_up Cookie "^;\s*" ""
    }
}
handle {
    import site_routes
}
```

- The HA host serves only HA: no landing page, no `/transmission/`, no
  dashboard-link redirects. A plain `import site_routes` next to the HA
  handle would not do: Caddy sorts `redir` ahead of `handle`, so
  `/transmission` and the link redirects would run on the HA host first.
- The main host never reaches HA. Every other host goes to `site_routes`,
  as before.
- The HA route exists only on the loopback tunnel site. The `:443` sites,
  the catch-all and `(common_config)` do not have it, so
  `ha.example.com` on the LAN listener is not proxied to HA.
- `X-Forwarded-For`: every request reaches Caddy from cloudflared on
  loopback. By default Caddy would send `127.0.0.1` for every visitor, and
  an HA login ban would then lock out everyone. The route sets it to
  `Cf-Connecting-IP`, the visitor's address, which Cloudflare sets at the
  edge. The listener is loopback-only, so only cloudflared can send it.
  This uses `header_up` and not the global `trusted_proxies` and
  `client_ip_headers` options: those would change every site, and the
  off-state Caddyfile.
- `X-Forwarded-Proto https`: the hop from cloudflared is plain http, so
  Caddy would send `http`. The visitor used https at Cloudflare.
- The Access token is not passed to HA: the route drops
  `Cf-Access-Jwt-Assertion` and the `CF_Authorization` cookie, and keeps
  the other cookies. Both hostnames share one application and one AUD tag,
  so the token may also be accepted for `example.com` (not tested). HA does
  not need it.
- `Host` and `X-Forwarded-Host` stay `ha.example.com` (Caddy's defaults).
  Websockets work without extra settings.

The host matcher depends on cloudflared passing the visitor's `Host`
header to Caddy, which is its default. Step 8 below checks it: if the
`Host` were rewritten, `ha.example.com` would show the landing page.
This is not yet tested through the live tunnel.

### Turn it on

Do these steps in order. Steps 1 to 3 are in Cloudflare. The deployed
watchdog does not expect the new hostname yet, so it sends a drift email
after step 1 (a watchdog from before this feature, after step 2). Step 5
resolves it.

Between step 3 and step 6, the deployed Caddy does not know the HA
hostname yet, so `ha.example.com` shows the main site. It is behind the
same Access policy and email check as `example.com`, so nothing new is
exposed, but do not leave it in this state.

1. **Access application.** In Zero Trust, open the `example.com`
   application. Add `ha.example.com` as a second public hostname
   (destination). Keep `example.com` first. Do not add a policy: the
   existing policy, identity provider and AUD tag cover both hostnames.
2. **Tunnel route.** In the tunnel's published application routes, add
   `ha.example.com` → `http://127.0.0.1:8080`. Turn on Access protection
   with the same team name and AUD tag as the `example.com` route. Make sure
   it is before the `http_status:404` catch-all.
3. **DNS.** A proxied CNAME `ha` → `<tunnel id>.cfargotunnel.com`, the same
   target as `example.com`. The dashboard can create it with the route.
4. **Config keys.** Set `HOME_ASSISTANT_HOSTNAME` and
   `HOME_ASSISTANT_UPSTREAM` in `config.conf` on the server.
5. **Watchdog.** `sudo ./access-policy-watchdog-setup.sh`. It reads the
   keys from `config.conf`. Its `--check` must pass. If it does not, the
   output names the difference. The script has already written the new
   watchdog file by then and only skips the reload, so an agent that is
   already loaded runs the new file on its next run and keeps alerting
   until you fix it. The check that reads `destinations` with two hostnames
   is **not yet confirmed against the live API**; the tests use fixtures.
6. **Caddy.** Deploy it as for any Caddyfile change
   (`./run-app-setup.sh --only caddy-setup.sh`). `caddy-setup.sh` reads the
   keys from its environment, not from `config.conf`. Before the restart,
   check that the keys arrived:
   `sudo grep -c '@home_assistant' /Users/operator/.config/caddy/Caddyfile`
   must print 2. If it prints 0, the deploy rendered the off state, and
   `ha.example.com` would keep showing the main site. Then
   `sudo launchctl kickstart -k system/com.caddyserver.caddy`.
7. **Home Assistant.** HA rejects a request that carries
   `X-Forwarded-For` from a proxy it does not trust, and logs the proxy's
   address. In HA's network settings (since 2026.8 they are in the UI, not
   in YAML), turn on "Trust X-Forwarded-For" and add this server's LAN IP to
   "Trusted proxies". Take the address from that log line. Make this change
   from the LAN URL.
8. **Check.** In a browser that is signed in to Access:
   - `https://ha.example.com/` shows the HA login.
   - `https://ha.example.com/transmission/` is an HA page, not
     Transmission.
   - `https://example.com/` is the dashboard, with a "Home Assistant" link.
   - In HA, the login log shows your public address, not `127.0.0.1` and
     not the server's LAN IP.

### Turn it off

1. Delete the `ha.example.com` tunnel route. This cuts off the hostname at
   once.
2. Delete the `ha` CNAME and remove `ha.example.com` from the Access
   application.
3. Empty both `HOME_ASSISTANT_*` keys. Run
   `sudo ./access-policy-watchdog-setup.sh`, then deploy Caddy again and
   kickstart it. With the keys empty, the Caddyfile is the same as before
   the feature.
4. Optional: remove the trusted proxy in HA.

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
bats tests/caddyfile.bats              # tunnel site and site_routes; HA routing (live)
bats tests/caddy-home-assistant.bats   # HA keys, off-state render, HA only on :8080
bats tests/cloudflared-wrapper.bats    # token via env only; keychain miss
bats tests/access-policy-watchdog.bats # expected rule and ingress, widenings, 404, API errors
bats tests/tunnel-watchdog.bats        # /ready 200, 503, no answer; failure streak; recovery
```

The watchdog tests run the rendered script with `/bin/bash` (bash 3.2, as
launchd runs it) against a curl mock and fixtures in
`tests/fixtures/cloudflare-access/`.
