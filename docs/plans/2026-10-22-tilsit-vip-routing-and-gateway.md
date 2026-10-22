# tilsit.vip Routing and Authenticated Gateway: Design

**Status:** proposal, not implemented. Needs a decision before any Caddy change.
**Date:** 2026-10-22
**Issues:** #210 (internal vs external routing), #209 (authenticated gateway).
**Affects:** #130 and `2026-04-19-caddy-forms-auth.md` (see "Consequence for #130").

## Goal

- #210: one way to reach the home tools that works on and off the home
  network, without a LAN authentication bypass that does not exist today.
- #209: a me-only gateway with a sign-in that 1Password can fill, linked from
  projectinsomnia.com, with clear trust boundaries, revocation, and failure
  behavior.

The two issues share one answer, so this document covers both.

## Current state (measured on TILSIT, 2026-10-22)

### Network path

```text
Internet ─ 67.5.100.185 ─ 192.168.0.1 (ISP gateway, lighttpd UI)
                              └─ 10.0.15.1 (LAN router, DHCP)
                                     └─ 10.0.15.15 TILSIT (Caddy :80, :443)
```

- The network is double-NATed. `traceroute` shows 10.0.15.1, then
  192.168.0.1, then the ISP. External access therefore needs a port-forward
  rule on both routers. Those rules are not visible from the shell.
- External clients use `tilsit.vip:24443`. This is inferred from the `Host`
  header (`tilsit.vip:24443`) on every external request in the access log.
  Caddy listens only on 443, so the routers forward WAN 24443 to TILSIT 443.
- `tilsit.vip` has an A record (67.5.100.185, the current public IP) and no
  AAAA record. TILSIT has no global IPv6 address, only ULA (`fd09:…`). The
  record is DNS-only (grey cloud): resolvers return the origin IP.
  `cloudflare-ddns.sh` updates `content` only and keeps `proxied` as set.
- From TILSIT, `https://tilsit.vip/` and `https://tilsit.vip:24443/` both time
  out. A LAN client cannot reach the public name. The cause may be missing NAT
  loopback or ISP filtering; the symptom is the same.

### DNS on the LAN

- DHCP (from 10.0.15.1) hands out two resolvers: 192.168.0.1 and
  149.112.112.112 (Quad9).
- 192.168.0.1 returns the public IP for `tilsit.vip`. It is the ISP gateway.
  Whether it can hold a local override record is unknown.

### Caddy

From `app-setup/templates/Caddyfile`:

| Site | Cert | Auth |
| --- | --- | --- |
| `:443` catch-all | — | 403 for unknown host or bare IP |
| `tilsit.local localhost 10.0.15.15` | `tls internal` (clients install `caddy-root-ca.crt`) | none from LAN |
| `tilsit.vip` | Let's Encrypt, DNS-01 via Cloudflare (SAN: `tilsit.vip` only) | `basic_auth` when not LAN |

- The LAN/external split is `remote_ip`: 10.0.15.0/24, loopback, `fe80::/10`,
  `fd00::/8`. Caddy sees the real client address because nothing proxies in
  front of it.
- `/media/*` returns 403 to non-LAN clients, on both sites.
- Routes: landing page, `/transmission/`, `/media/` (LAN only), and
  `/romano` and `/berkswell` redirects to Synology QuickConnect. Plex is not
  behind Caddy; clients use plex.tv.

### Usage

All retained access logs (2026-07-27 to 2026-10-22) show external traffic on
4 days, from 10 distinct IPs, about 90 requests in total. Almost all of it is
`/transmission/`. The design should be sized for one person who sometimes
checks downloads away from home.

### projectinsomnia.com

Netlify hosts it. Its DNS is at name.com, not Cloudflare. `gh` reports the
repo as `smartwatermelon/projectinsomnia`; #209 names
`twistedmelonman/projectinsomnia`. This document does not decide which is
current.

## Two traps every option must avoid

1. **A hop in front of Caddy that originates on loopback or the LAN removes
   all external auth.** If `cloudflared`, a local proxy, or any relay connects
   to Caddy from 127.0.0.1 or 10.0.15.0/24, `remote_ip` sees a "local"
   client. `basic_auth` is then skipped and the `/media/*` guard opens. Any
   option that adds such a hop must either give that traffic its own site
   block with no LAN bypass, or move the matchers to `client_ip` with
   `trusted_proxies`.
2. **Split-horizon DNS with a port mismatch.** If LAN DNS maps `tilsit.vip`
   to 10.0.15.15, then `https://tilsit.vip:24443` from the LAN hits a port
   Caddy does not listen on. One URL for both places needs the WAN forward on
   443, or Caddy also listening on 24443.

## #210: Routing options

### R1. Split-horizon DNS

LAN resolver answers `tilsit.vip → 10.0.15.15`. External DNS stays as is.

- For: LAN clients get the Let's Encrypt cert through SNI, so the internal CA
  install is no longer needed for that name. DNS-01 renewal does not care
  about LAN DNS. The `remote_ip` bypass stays exactly as it is today.
- Against: three blockers.
  - The ISP gateway may not support override records. The alternative is a
    new resolver (dnsmasq on TILSIT, or Synology DNS Server) and a DHCP change
    on 10.0.15.1.
  - DHCP also hands out Quad9. A client that uses the secondary resolver gets
    the public IP and times out. Results vary by client and by moment.
  - The port mismatch (trap 2) needs a router change too.

### R2. IP-aware redirect at projectinsomnia.com

A Netlify Edge Function at, for example, `projectinsomnia.com/tools`
compares the visitor IP with the current `tilsit.vip` A record (DNS over
HTTPS). A match means "at home": redirect to `https://tilsit.local/`.
Otherwise, redirect to `https://tilsit.vip:24443/`.

- For: no change to TILSIT, the routers, or LAN DNS. No new bypass.
- Against: two URLs and two certs stay in use. DDNS lag (up to the update
  interval after a public IP change) sends a home visitor to the external
  URL, which times out. It also adds logic to the public site.

### R3. One public name in front of Cloudflare

Put `tilsit.vip` behind Cloudflare (tunnel or proxied record; see G2). LAN
clients resolve `tilsit.vip` to Cloudflare, not to the home IP, so hairpin
and LAN DNS no longer matter. The same URL works everywhere, and the user
signs in everywhere.

- For: one URL, no LAN DNS work, no dependence on NAT loopback.
- Against: home traffic to `tilsit.vip` leaves the house and comes back.
  `tilsit.local` remains for fast LAN-only use, such as `/media/`.

**Recommendation for #210:** R3, done as part of G2. R1 and R2 each fix
routing only. R3 comes free with the recommended gateway.

## #209: Gateway options

All three keep `tilsit.local` and its LAN bypass unchanged.

### G1. Self-hosted form login (caddy-security, the #130 plan)

- Sign-in: form plus JWT cookie. 1Password can fill it.
- Exposure: TILSIT stays directly reachable on WAN 24443. Anyone can reach the
  login page, and a Caddy or plugin bug is exposed to the internet.
- Upkeep: a custom Caddy build with two plugins. `caddy-security` lags Caddy
  releases.
- Revocation: rotate the JWT signing key (logs out every session) or change
  the password.
- Failure: if the plugin config breaks, Caddy fails to start, and LAN access
  goes down with it.
- #210: no help. Needs R1 or R2 as well.

### G2. Cloudflare Tunnel plus Cloudflare Access (recommended)

`cloudflared` on TILSIT makes an outbound connection to Cloudflare.
Cloudflare serves `tilsit.vip`, applies an Access policy ("allow only these
email addresses"), and sends allowed requests down the tunnel.

- Sign-in: the Access login page, using an identity provider (Google, GitHub,
  or an email one-time code). 1Password fills an IdP login and stores
  passkeys.
- Exposure: no inbound port. The 24443 forwards on both routers can be
  removed. Unauthenticated traffic stops at Cloudflare and never reaches
  TILSIT.
- Trust boundary: Cloudflare decrypts the traffic at its edge. This is new.
  The tunnelled traffic is the Transmission UI and the landing page; Plex and
  the NAS do not pass through it.
- Trap 1 applies. `cloudflared` connects from loopback. It must target a
  dedicated Caddy listener (for example `http://127.0.0.1:8080`, bound to
  loopback only) whose site block imports the routes **without** the
  `remote_ip` bypass, and with `/media/*` denied. Keeping `basic_auth` on that
  listener as a second layer is cheap and works if Access is misconfigured.
- Upkeep: one more binary (`cloudflared`, Homebrew) and one LaunchDaemon. The
  stock Caddy build is enough; no new plugin. The Let's Encrypt cert for
  `tilsit.vip` is no longer needed once the forwards are removed. Cloudflare
  terminates public TLS.
- Revocation: remove the email from the Access policy, or revoke sessions in
  the Zero Trust dashboard. Session length is a policy setting.
- Failure: Cloudflare or tunnel down means external access is down, with a
  Cloudflare error page. LAN access through `tilsit.local` is not affected.
  A watchdog can alert on tunnel health (alert-lib pattern).
- #210: solves it (R3).
- Cost: Cloudflare offers a free Zero Trust plan. Its user limit and whether
  it covers this setup need checking at sign-up time.
- Constraint: as far as I can tell, Access and tunnel public hostnames need
  the hostname in a Cloudflare zone. `tilsit.vip` is already there.
  `tools.projectinsomnia.com` is not (name.com), so projectinsomnia.com links
  to `tilsit.vip` instead of hosting the tools under its own name.

A proxied record (orange cloud) without a tunnel is a weaker variant. It
keeps the inbound forward open, so the origin IP (published by the A record's
history) can bypass Access unless Caddy also checks the Access JWT or allows
only Cloudflare IP ranges. Cloudflare also proxies only a fixed set of HTTPS
ports (443, 2053, 2083, 2087, 2096, 8443), and 24443 is not one of them. The
tunnel avoids both problems.

### G3. Tailscale (or another mesh VPN)

- For: strongest isolation. No public surface at all.
- Against: every device needs the client, and a borrowed browser cannot
  connect. There is no "public site as entry point", which is the stated goal
  of #209. Good as an addition, not as the gateway.

## Recommendation

1. G2: Cloudflare Tunnel plus Access in front of `tilsit.vip`, with a
   loopback-only Caddy listener for the tunnel that has no LAN bypass.
2. This also closes #210 (R3).
3. projectinsomnia.com gets a "Tools" link to `https://tilsit.vip/`. The
   change belongs in the projectinsomnia repo.

## Consequence for #130

G2 replaces the `caddy-security` plan in `2026-04-19-caddy-forms-auth.md`.
If G2 is accepted, close #130 as superseded and mark that plan as such. If G1
is chosen instead, #130 stays, and #210 still needs R1 or R2.

## Rollout sketch for G2 (for a later implementation plan)

1. Create the Access application and policy for `tilsit.vip`.
2. Install `cloudflared` and add a LaunchDaemon. Store the tunnel token in
   the System keychain, following the `CF_API_TOKEN` pattern.
3. Add the loopback tunnel listener to the Caddyfile. Validate. Restart Caddy
   with explicit permission (production).
4. Point the tunnel's public hostname at the listener. The A record then
   gives way to the tunnel CNAME. Retire `cloudflare-ddns` only after the
   cutover works.
5. Test from outside: no session gets the Access page; a session reaches
   `/transmission/`; `/media/` returns 403.
6. Remove the 24443 forwards on both routers. Confirm that
   `67.5.100.185:24443` no longer answers.
7. Add a tunnel-health watchdog and update `docs/apps/caddy-README.md`.

Rollback: re-add the forwards and restore the A record. The existing
`tilsit.vip` site block stays in the Caddyfile until step 6 is proven.

## Open questions for Andrew

1. Is it acceptable for Cloudflare to terminate TLS for the Transmission UI?
2. Which Access sign-in: Google, GitHub, or email one-time code?
3. Should the NAS QuickConnect links stay on the landing page? They bypass
   this gateway completely and use Synology's own login.
