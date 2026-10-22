# G2 Implementation Plan: Cloudflare Tunnel + Access for tilsit.vip

**Status:** plan, not executed.
**Date:** 2026-10-22
**Issues:** #209 (gateway, decision G2), #210 (routing, decision R3).
**Design:** `2026-10-22-tilsit-vip-routing-and-gateway.md`.
**Supersedes:** `2026-04-19-caddy-forms-auth.md` (#130, closed).

## Decisions already made

| Question | Answer |
| --- | --- |
| Gateway | G2: Cloudflare Tunnel plus Access |
| Routing | R3: `tilsit.vip` works everywhere; `tilsit.local` is LAN-only and unchanged |
| Cloudflare terminates TLS for the tunnelled tools | Accepted (it is inherent to G2) |
| Sign-in | Google (personal account, generic Google IdP, not Workspace) |
| QuickConnect links | Stay on the landing page |

## Facts this plan depends on (checked 2026-10-22)

- `tilsit.vip` is in Cloudflare account **`Andrew.rich@gmail.com's Account`**
  (`36e63f08…`, Free plan). The Cloudflare MCP connection in Claude Code was
  authenticated to a different account (`nightowlstudio`), which has no
  zones. It must be reconnected to the personal account before Task 1.
- `cloudflare-ddns.sh` updates one fixed record ID (`CF_RECORD_ID`). Once the
  A record is replaced by the tunnel CNAME, it would fail every cycle, so it
  is retired at cutover.
- `cloudflared service install <token>` on macOS writes the token into
  `/Library/LaunchDaemons/com.cloudflare.cloudflared.plist`, which is
  world-readable. This plan does not use `service install`. It follows the
  `caddy-wrapper.sh` pattern instead: the token lives in the System keychain
  and a wrapper exports it as `TUNNEL_TOKEN` before `exec`.
- `cloudflared` can require a valid Access JWT before proxying
  (`originRequest.access: {required: true, teamName, audTag}`, per
  Cloudflare's origin-parameters reference).
- Google as an IdP needs an OAuth client in Google Cloud Console, with the
  Zero Trust team domain as the authorized origin and
  `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback` as the
  redirect URI.

## Target architecture

```text
Browser (anywhere, including LAN)
  → tilsit.vip  (proxied CNAME → <tunnel-uuid>.cfargotunnel.com)
  → Cloudflare Access  (Google sign-in, allow: andrew.rich@gmail.com)
  → Cloudflare Tunnel  (outbound connection from TILSIT)
  → cloudflared on TILSIT  (rejects requests without a valid Access JWT)
  → Caddy http://127.0.0.1:8080  (tunnel-only site, loopback bind)
  → / landing page, /transmission/ → 127.0.0.1:9091

LAN only, unchanged:
  tilsit.local → Caddy :443 (tls internal) → no auth from LAN
```

### Layered checks on the tunnel path

1. Access policy at the edge (Google identity, one allowed email).
2. `cloudflared` JWT check (`access.required`). This still blocks if the
   Access application is deleted or its policy is widened by mistake.
3. Caddy listener bound to `127.0.0.1` only. Nothing off-host can reach it.

**Deliberately not used:** `basic_auth` on the tunnel listener. An earlier
review suggested it as a second layer, but it brings back the browser
password pop-up after Google sign-in, which is the problem #209 exists to
solve. Layer 2 covers the same failure case without a second prompt.

### Caddy trap to avoid

`cloudflared` connects from loopback. The existing `(common_config)` auth
matcher excludes loopback, so importing it on the tunnel site would apply no
auth at all. The tunnel site must not depend on `remote_ip` for its
security. Its security comes from layers 1–3.

## Tasks

Every task that changes production says so, and needs Andrew's go-ahead at
the time. "Andrew" marks steps only he can do (browser consoles, secrets,
routers).

### Task 0: Prerequisites (Andrew, about 20 minutes)

1. Reconnect the Cloudflare MCP to the personal account (`/mcp`, sign in as
   `andrew.rich@gmail.com`). Claude verifies with `whoami` and a zone lookup
   for `tilsit.vip`.
2. If Zero Trust is not yet set up on that account, open Zero Trust in the
   dashboard and pick a **team name** and the Free plan. Claude can then read
   the team domain from the API.
3. In Google Cloud Console, create the OAuth client:
   - Consent screen: External; scopes `openid`, `email`, `profile`. Add
     `andrew.rich@gmail.com` as a test user, or publish the app.
   - OAuth client type Web application. Origin
     `https://<team>.cloudflareaccess.com`. Redirect URI
     `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`.
4. In Zero Trust → Integrations → Identity providers, add **Google**, and
   paste the client ID and secret there. The secret goes only into the
   dashboard, never into chat or the repo. Store a copy in 1Password.
5. Select **Test** on the Google IdP and confirm the returned identity.

### Task 1: Access policy and application (Cloudflare, before any DNS change)

Creating these first means the hostname is protected the moment it starts
routing through the tunnel.

1. Create a reusable Access policy (`/access/policies`): action Allow,
   include email `andrew.rich@gmail.com`. Session duration 24 h (adjust
   later if it prompts too often).
2. Create a self-hosted Access application for `tilsit.vip` (whole host).
   Attach the policy. Allow only the Google IdP and turn on instant
   authentication, so users go straight to Google.
3. Record the application's AUD tag for Task 2.
4. Verify that the policy reads back as `reusable: true`.

### Task 2: Tunnel (Cloudflare + TILSIT keychain)

1. Create a remotely managed tunnel named `tilsit`.
2. Set its ingress through the API:
   - `tilsit.vip` → `http://127.0.0.1:8080`, with `originRequest.access`
     set to `required: true`, `teamName: <team>`, and `audTag: [<AUD>]`.
   - Catch-all → `http_status:404`.
3. Fetch the tunnel token and put it straight into the System keychain on
   TILSIT. Service `cloudflare-tunnel-token`, account `tilsit.vip`. Do not
   print it. **Production change** (keychain only; nothing routes yet).
4. Stash a copy in 1Password (Automation vault) for rebuilds.

### Task 3: Repo changes (branch, tests, PR)

1. `app-setup/templates/cloudflared-wrapper.sh`: read the token from the
   System keychain, `export TUNNEL_TOKEN`, then
   `exec /opt/homebrew/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run`.
   Pick the metrics port at build time after checking it is free.
2. `app-setup/templates/com.cloudflare.tunnel.plist`: LaunchDaemon (root),
   `KeepAlive`, `RunAtLoad`, logs under `/usr/local/var/log/cloudflared/`.
   Use a label different from `com.cloudflare.cloudflared`, so a later
   `cloudflared service install` cannot collide with it.
3. `app-setup/cloudflared-setup.sh`: `brew install cloudflared` (as the
   admin account). Check the keychain item. Deploy the wrapper and plist,
   then `bootstrap` the daemon. Follow `caddy-setup.sh`.
4. `Caddyfile`: split the routes out of `(common_config)` into a
   `(site_routes)` snippet that holds the landing page, `/transmission/`,
   and the QuickConnect redirects. Leave `/media` out of it.
   `(common_config)` keeps the LAN matchers, `basic_auth`, the `/media`
   handler, and `import site_routes`. Add the tunnel site:

   ```caddyfile
   http://:8080 {
       bind 127.0.0.1
       import site_routes
   }
   ```

   `/media` must not be in `site_routes`. Through the tunnel every request
   comes from loopback, so the `/media` handler's `@not_local` guard would
   let it through. A `respond` deny added on the tunnel site would not help
   either: Caddy orders `handle_path` before `respond`, so the proxy would
   run first. Without the handler, `/media` on the tunnel site falls through
   to `file_server` and returns 404.
5. Tests (`tests/caddyfile.bats`): the tunnel site binds `127.0.0.1`, does
   not import `common_config`, and has no `/media` handler. `site_routes`
   has none either. The existing matcher tests still pass. Add BATS for the wrapper (keychain miss → non-zero exit
   with a message) using the repo's `TEST_RUNNER` pattern.
6. Run `caddy validate` on the rendered template, the full BATS suite,
   shellcheck, and shfmt.
7. PR, review, merge-lock, merge.

### Task 4: Deploy the origin side (TILSIT, production)

1. Deploy the Caddyfile change, validate it, then
   `launchctl kickstart -k system/com.caddyserver.caddy`.
2. Check locally: `curl http://127.0.0.1:8080/` returns 200,
   `/transmission/web/` returns 200, `/media/` returns 404 (no handler on
   this site). From another LAN host, `10.0.15.15:8080` must refuse the
   connection.
3. Run `cloudflared-setup.sh`. Confirm in the dashboard that the tunnel
   shows healthy and that `/ready` on the metrics port returns 200.

Nothing public changes yet: DNS still points at the home IP.

### Task 5: Cutover (Cloudflare DNS, production, about 5 minutes)

1. `launchctl bootout` the `cloudflare-ddns` LaunchDaemon, so it cannot fight
   the change.
2. Record the current A record (ID, content, TTL) for rollback.
3. Delete the A record. Create a proxied CNAME
   `tilsit.vip → <tunnel-uuid>.cfargotunnel.com`.
4. Wait for the old A record's TTL (300 s) to expire.

### Task 6: Verify

1. Outside, from the transmission-vpn container's PIA exit:
   `https://tilsit.vip/` redirects to the Access login (302 to
   `<team>.cloudflareaccess.com`), not to the home IP.
2. LAN, from TILSIT: `https://tilsit.vip/` now behaves the same way. This
   is the R3 result: there is no hairpin timeout any more.
3. Andrew, on the phone over cellular and then on the LAN: Google sign-in,
   then the landing page, then `/transmission/` works. `/media/` returns
   404 through `tilsit.vip`; it is a LAN-only tool on `tilsit.local`.
   QuickConnect links work.
4. Sign in with a Google account that is not on the list. Access must deny
   it.
5. Andrew checks the Access audit log for both of those attempts.
6. `tilsit.local` on the LAN is unchanged (200, no prompt).

### Task 7: Close the inbound port (Andrew, routers)

1. Remove the WAN 24443 forward on 192.168.0.1 and on 10.0.15.1.
2. Claude confirms from the PIA exit that `67.5.100.185:24443` times out.
3. Until a follow-up PR (two weeks after cutover, if nothing went wrong),
   keep the `tilsit.vip` site block and its Let's Encrypt config in the
   Caddyfile as the rollback path. The follow-up then removes the block,
   the `cloudflare-ddns` daemon and its docs, and decides whether
   `CF_API_TOKEN` is still needed.

### Task 8: Monitoring and docs

1. Add a tunnel watchdog (LaunchAgent, alert-lib) that alerts when the
   metrics `/ready` endpoint stops returning 200. Use `alert_transition`, so
   it emails on change, not every cycle. BATS tests follow the other
   watchdogs.
2. New `docs/apps/cloudflare-tunnel-README.md`: architecture, token chain,
   Access objects (names, AUD), how to revoke a session, rollback.
3. Add a service section for the tunnel files in `CLAUDE.md`.
4. Mark `2026-04-19-caddy-forms-auth.md` as superseded at the top.
5. Update `caddy-README.md` (tunnel site) and `cloudflare-ddns-README.md`
   (retired, and why).

## Rollback

Any time before Task 7:

1. Delete the CNAME and recreate the A record with the recorded values.
   Update `CF_RECORD_ID` if the ID changed.
2. `bootstrap` the `cloudflare-ddns` daemon again.
3. The old `tilsit.vip:24443` path then works again, protected by
   `basic_auth` as today.

After Task 7, also re-add the router forwards.

Stopping the tunnel daemon alone makes Cloudflare show an error page for
`tilsit.vip`. LAN access through `tilsit.local` does not change.

## Revocation

- Remove the email from the Access policy, or revoke active sessions in Zero
  Trust (Users / Access sessions).
- To cut off the origin entirely, delete or rotate the tunnel (new token in
  the keychain).

## Time estimate

| Task | Who | Time |
| --- | --- | --- |
| 0 | Andrew | 20 min |
| 1–2 | Claude via MCP, with approvals | 20 min |
| 3 | Claude | 2 h including tests and review |
| 4–6 | Claude + Andrew | 45 min |
| 7 | Andrew | 10 min |
| 8 | Claude | 1 h |

## Open items to settle during the build

1. Session duration (24 h proposed).
2. Confirm that the Free Zero Trust plan covers this, at sign-up.
3. `brew upgrade` behavior for `cloudflared`. Decide whether the daemon
   needs a restart hook, or whether a reboot or `KeepAlive` restart picking
   up the new binary is enough.
