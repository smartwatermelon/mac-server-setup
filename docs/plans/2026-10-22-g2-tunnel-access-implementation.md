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
2. `cloudflared` JWT check (`access.required`). It proves only that the
   request carries a valid token from **this** Access application.
   - It blocks everyone if the application is deleted or replaced, because
     no valid token for that AUD can then exist.
   - It does **not** help if the policy is widened (for example to "any
     Google account" or "Everyone"). Then every visitor gets a valid token,
     and this check passes them.
3. Origin email check in Caddy (Task 2b decides whether it ships). The
   tunnel site returns 403 unless `Cf-Access-Authenticated-User-Email` is
   exactly the allowed address. This is the only layer that still holds if
   the policy is widened. It is safe only if Cloudflare overwrites the
   header for Access applications, so a client cannot forge it. The docs do
   not say this, so Task 2b tests it first.
4. Policy-drift watchdog (Task 8). It reads the Access application and
   policy through the API and alerts on any change from the expected rule.
   It does not block, but it shrinks the window from "until noticed" to one
   check interval.
5. Caddy listener bound to `127.0.0.1` only. Nothing off-host can reach it.

**Deliberately not used:** `basic_auth` on the tunnel listener. An earlier
review suggested it as a second layer, but it brings back the browser
password pop-up after Google sign-in, which is the problem #209 exists to
solve. Layers 3 and 4 cover a widened policy without a second prompt; layer
2 covers a deleted application.

**Accepted residual risk if Task 2b fails** (the header turns out to be
forgeable, so layer 3 is dropped): a widened policy exposes Transmission
until the watchdog alerts and the policy is fixed. Transmission has no auth
of its own. Andrew must accept this explicitly at Task 2b, or the plan adds
a JWT-validating check at the origin instead.

### Caddy trap to avoid

`cloudflared` connects from loopback. The existing `(common_config)` auth
matcher excludes loopback, so importing it on the tunnel site would apply no
auth at all. The tunnel site must not depend on `remote_ip` for its
security. Its security comes from layers 1–5.

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
   - Consent screen: External; scopes `openid`, `email`, `profile`.
     **Publish the app** (these basic scopes need no Google verification).
     Do not leave it in Testing. In Testing, Google itself blocks every
     account that is not a test user. The denial test in Task 6 would then
     pass without ever reaching the Access policy.
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
3. Read the tunnel configuration back from the API. Confirm that
   `originRequest.access.required` is `true` with the right `teamName` and
   `audTag`. Cloudflare documents `access` as config-file YAML, and this
   readback is what proves it took effect on a remotely managed tunnel. Do
   not start Task 5 until it passes.
4. **Andrew** copies the tunnel token from the dashboard and enters it at a
   prompt on TILSIT. Claude must not fetch the token through the API or MCP,
   because the value would then land in the session transcript. The command
   must also not put the token on the command line, where it would show in
   `ps` and shell history. The existing `cloudflare-ddns-setup.sh` passes
   `-w '<token>'` and has exactly that problem, so do not copy it here.
   - Use `sudo security add-generic-password -s cloudflare-tunnel-token -a
     tilsit.vip ... -w` with `-w` given no value, so `security` prompts for
     the token. Test the exact argument order on a scratch keychain first.
     If the keychain path comes after a bare `-w`, `security` may read the
     path as the password.
   - Claude then checks only that the item exists (exit status, no `-w`).
   - **Production change**, keychain only; nothing routes yet.
5. Andrew stores a copy in 1Password (Automation vault) for rebuilds.

### Task 2b: Test whether the email header can be forged (before cutover)

This decides whether layer 3 ships. It uses a throwaway hostname, so
`tilsit.vip` is never exposed.

1. Create a temporary Access application on `accesstest.tilsit.vip` with a
   deliberately **open** policy (any Google account; or Andrew plus a second
   Google account he owns). Route it through the same tunnel to a loopback
   echo listener that logs request headers (for example a temporary Caddy
   site that logs `{header.Cf-Access-Authenticated-User-Email}`).
2. Sign in as the second account. Send a request that carries a forged
   `Cf-Access-Authenticated-User-Email: andrew.rich@gmail.com` header, for
   example with curl and the session cookie, or a browser header extension.
3. Read the origin log.
   - If the logged value is the second account's real email, Cloudflare
     overwrote the forged header. Layer 3 is safe, and it ships.
   - If the forged value arrives, layer 3 is unsafe. Drop it, and record
     Andrew's decision on the residual risk (see "Layered checks").
4. Delete the test application, its policy, its DNS record, its ingress
   rule, and the echo site. Confirm each one is gone.

### Task 3: Repo changes (branch, tests, PR)

1. `app-setup/templates/cloudflared-wrapper.sh`: read the token from the
   System keychain, `export TUNNEL_TOKEN`, then
   `exec /opt/homebrew/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run`.
   Pick the metrics port at build time after checking it is free.
2. `app-setup/templates/com.cloudflare.tunnel.plist`: LaunchDaemon (root),
   `KeepAlive`, `RunAtLoad`. Logs go to
   `/Users/__OPERATOR_USERNAME__/.local/state/cloudflared/`, as the Caddy
   daemon's do. launchd does not create missing log directories, so the
   setup script runs `mkdir -p` before `bootstrap`.
   Use a label different from `com.cloudflare.cloudflared`, so a later
   `cloudflared service install` cannot collide with it.
3. `app-setup/cloudflared-setup.sh`: `brew install cloudflared` (as the
   admin account). Check the keychain item. Deploy the wrapper and plist,
   then `bootstrap` the daemon. Follow `caddy-setup.sh`.
4. `Caddyfile`: split the routes out of `(common_config)` into a
   `(site_routes)` snippet that holds the landing page, `/transmission/`,
   the QuickConnect redirects, and the `log` directive. Leave `/media` out
   of it. `log` moves into `site_routes` so that the tunnel site writes the
   same access log. Without it, the origin keeps no record of tunnel
   requests, and Task 6's "nothing reached the origin" check has no data.
   `(common_config)` keeps the LAN matchers, `basic_auth`, the `/media`
   handler, and `import site_routes`. Add the tunnel site:

   ```caddyfile
   http://:8080 {
       bind 127.0.0.1
       route {
           # Layer 3, only if Task 2b showed the header cannot be forged.
           @not_allowed not header Cf-Access-Authenticated-User-Email __ACCESS_ALLOWED_EMAIL__
           respond @not_allowed 403
           import site_routes
       }
   }
   ```

   The `route` block is what makes the email check run first. Outside a
   `route`, Caddy sorts directives into a fixed order. `redir` would then
   run before `respond`, and `respond` before `reverse_proxy`, which happens
   to work today but breaks silently if `site_routes` gains a `handle`.
   Inside `route`, directives run in the order written. This was tested on
   a scratch Caddy on 2026-10-22. With no header or a wrong email, `/`,
   `/romano` and `/transmission/` all returned 403. With the allowed email,
   each request reached its route. Repeat the check with `caddy adapt` on
   the real template at build time. The allowed address is a template
   placeholder, following the repo's no-hardcoded-names rule.

   `/media` must not be in `site_routes`. Through the tunnel every request
   comes from loopback, so the `/media` handler's `@not_local` guard would
   let it through. A `respond` deny added on the tunnel site would not help
   either: Caddy orders `handle_path` before `respond`, so the proxy would
   run first. Without the handler, `/media` on the tunnel site falls through
   to `file_server` and returns 404.
5. Tests (`tests/caddyfile.bats`): the tunnel site binds `127.0.0.1`, does
   not import `common_config`, and has no `/media` handler. `site_routes`
   has none either. If layer 3 ships, the email check is the first
   directive inside the tunnel site's `route`. The existing matcher tests
   still pass. Each new test must fail against a known-bad Caddyfile
   before it counts. Add BATS for the wrapper (keychain miss → non-zero exit
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

1. Stop DDNS so it cannot fight the change, and keep it stopped across a
   reboot. Its plist stays in `/Library/LaunchDaemons` with `RunAtLoad`, so
   `bootout` alone would undo itself at the next boot.
   `sudo launchctl bootout system/com.tilsit.cloudflare-ddns`, then
   `sudo launchctl disable system/com.tilsit.cloudflare-ddns`.
2. Record the current A record for rollback: ID, content, TTL, and
   `proxied` (expected `false`).
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
4. **Test the rule denies the wrong people.** Andrew signs in with a
   second Google account that is not on the list.
   - The denial must be **Cloudflare's** block page, and it must appear in
     the Access audit log as a policy denial. Google's "Access blocked"
     page means the OAuth app is still in Testing (Task 0), and the Access
     policy was never tested.
   - The Caddy access log for the tunnel site must show **no** request in
     that time window. The request must stop at the edge, not at the
     origin.
5. **Test the rule against its own contents.** Claude reads the
   application and policy back through the API and checks them against the
   expected rule. The check is the same one the drift watchdog will run:
   - Action allow, one include rule, email `andrew.rich@gmail.com`.
   - No `everyone`, `email_domain`, `any_valid_service_token` or group
     selectors.
   - IdP list is Google only.
   - The domain is `tilsit.vip`.
6. If layer 3 shipped: from TILSIT, request `http://127.0.0.1:8080/` with
   no email header (expect 403) and with the allowed email (expect 200).
   This confirms that Caddy enforces the check.
7. Andrew checks the Access audit log for the allowed and the denied
   attempts.
8. `tilsit.local` on the LAN is unchanged (200, no prompt).

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
2. Add an Access policy-drift watchdog, on the same pattern as the Plex
   settings drift monitor (`plex-watchdog.sh`).
   - **If Task 2b dropped layer 3, build this watchdog before Task 5.** It
     is then the only check against a widened policy, so it must be running
     before the hostname goes live.
   - Every 15 minutes it reads the `tilsit.vip` Access application and
     policy, using a separate read-only API token (Access: Apps and Policies
     Read) kept in the System keychain. Andrew enters that token at a
     prompt, the same way as the tunnel token.
   - It compares them with the expected rule from Task 6 step 5, and sends
     an alert through `alert_transition` on any difference. It also alerts
     when the application is missing.
   - It also alerts when the API itself fails several times in a row, so a
     broken check cannot look like a healthy rule.
   - BATS cases use fixture JSON: the expected rule passes; a widened
     include (`everyone`, a second email, an email domain) fails; a missing
     application fails; an extra IdP fails; an API error fails.
   - **Live test, once:** add a second email to the policy, confirm the
     alert arrives, then remove it again and confirm the recovery alert.
     Do this only with Andrew present, because the policy is briefly wider.
3. New `docs/apps/cloudflare-tunnel-README.md`: architecture, token chain,
   Access objects (names, AUD), how to revoke a session, rollback.
4. Add a service section for the tunnel files in `CLAUDE.md`.
5. Update `caddy-README.md` (tunnel site) and `cloudflare-ddns-README.md`
   (retired, and why).

## Rollback

Any time before Task 7:

1. Delete the CNAME and recreate the A record with the recorded values,
   **`proxied: false`**. A proxied record cannot carry port 24443, so the
   old path would not work through it.
2. The recreated record has a new ID, and `CF_RECORD_ID` is a deploy-time
   placeholder. Re-run `cloudflare-ddns-setup.sh` so the daemon gets the
   new ID. Then `sudo launchctl enable system/com.tilsit.cloudflare-ddns`
   and `bootstrap` it.
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
