# PIA VPN — credentials, port forwarding, and region selection

Covers the PIA VPN layer beneath containerized Transmission: where the account
credentials live, how to rotate them, how port forwarding is supposed to work,
and how to diagnose it when it stops.

For the media-processing pipeline that runs after a download completes, see
[transmission-filebot-README.md](transmission-filebot-README.md).

## Architecture

Transmission runs inside the `transmission-vpn` container
(`haugene/transmission-openvpn`) on the `transmission-vm` Podman machine, owned
by the `operator` account. All of its traffic egresses through an OpenVPN
tunnel to PIA. If the tunnel drops, the container's killswitch stops traffic
rather than leaking it.

Two separate things are often confused when debugging:

- **The tunnel** — carries all outbound traffic. When this breaks, nothing
  reaches the internet at all.
- **Port forwarding** — asks PIA to open an inbound port so remote peers can
  connect *to* us. When only this breaks, downloads still work but run
  outbound-only.

## Credential chain

The PIA account password flows through four places. Each one has to be updated
during a rotation, in order.

```
1Password  ──prep-airdrop.sh──▶  macOS keychain  ──setup script──▶  .env  ──podman run──▶  container
```

| Stage | Location | Notes |
| --- | --- | --- |
| Source of truth | 1Password item (`ONEPASSWORD_PIA_ITEM`) | Read only during prep, on the dev Mac |
| Server storage | Keychain `pia-account-<hostname>` | Stored as `username:password`, colon-delimited |
| Container input | `~operator/containers/transmission/.env` | Mode `0600`, owned `operator:staff` |
| Runtime | Container environment | Unavoidably plaintext; OpenVPN needs it |

`.env` is passed with `--env-file`, never as inline `-e` flags, so the password
does not appear in `ps` output on the host.

## Rotating the PIA password

Do these in order. Skipping step 2 is the usual mistake — the container reads
the keychain-derived `.env`, not 1Password, so a rotation that stops at
1Password leaves the server authenticating with the old password until the next
full re-provision.

### 1. Change the password at PIA and in 1Password

Rotate it in the PIA account portal, then update the 1Password item so future
provisioning runs pick up the new value.

### 2. Update the keychain on the server

On TILSIT, as the account that owns the entry:

```bash
security add-generic-password -U \
  -s "pia-account-tilsit" \
  -a "tilsit" \
  -w
```

Omitting a value after `-w` makes `security` prompt for it interactively, which
keeps the password out of shell history and the process table. At the prompt,
enter the full colon-delimited pair:

```
p3462742:NEW_PASSWORD_HERE
```

`-U` updates the existing entry instead of failing on a duplicate.

Verify the entry is present (this prints metadata, not the secret):

```bash
security find-generic-password -s "pia-account-tilsit" -a "tilsit"
```

### 3. Regenerate `.env` and recreate the container

```bash
sudo ./app-setup/podman-transmission-setup.sh
```

This re-reads the keychain, rewrites `.env` at mode 600, and recreates the
container.

**The container must be recreated, not restarted.** `--env-file` is read at
creation time only, so `podman restart` keeps the old credential in the
existing container's environment.

### 4. Verify

```bash
# Tunnel established and egressing through PIA
sudo -u operator podman exec transmission-vpn curl -s https://ipinfo.io/ip

# No auth failures in the log
sudo -u operator podman logs --tail 50 transmission-vpn | grep -i "auth"
```

A wrong password shows up as `AUTH_FAILED` in the container log, with the
tunnel repeatedly reconnecting.

## Port forwarding

PIA's next-generation port forwarding is a two-step flow, implemented in the
image's `/etc/openvpn/pia/update-port.sh`:

1. `POST https://www.privateinternetaccess.com/gtoken/generateToken` with the
   account credentials, returning a bearer token.
2. `GET https://<tunnel-gateway>:19999/getSignature` with that token, returning
   a signed payload containing the assigned port, then `bindPort` to reserve
   it.

The assigned port is then pushed into Transmission with
`transmission-remote -p <port>`.

### `port_forward=true` cannot be trusted

PIA publishes a region list at
`https://serverlist.piaservers.net/vpninfo/servers/v4` with a per-region
`port_forward` boolean. **That flag is advisory and is known to be wrong.**

Verified 2026-08-23: the Panama region advertises `port_forward: true` while
serving nothing on port 19999 — every host in the region refuses the
connection, including the `meta` and `ovpnudp` servers PIA itself advertises
for that region. 103 of 158 regions carry the flag, so it is useful as a
first-pass filter and nothing more.

The only reliable test is to establish a tunnel and ask. That is what
[`app-setup/templates/pia-pf-probe.sh`](../../app-setup/templates/pia-pf-probe.sh)
does:

```bash
# Probe the default shortlist
sudo -u operator ./app-setup/templates/pia-pf-probe.sh

# Probe specific regions
sudo -u operator ./app-setup/templates/pia-pf-probe.sh ca_toronto netherlands

# Sweep everything advertising PF (slow — roughly 90s per region)
sudo -u operator ./app-setup/templates/pia-pf-probe.sh --all --out results.csv
```

The probe runs in its own throwaway container and does not disturb the live
`transmission-vpn` container or any download in progress.

It reads credentials from the same `.env` the live container uses, and passes
them into the probe container as environment variables on the `podman exec`
rather than interpolating them into command strings — so they stay out of the
process table, matching the `--env-file` protection described above.

The probe container runs with `--privileged`, `--device /dev/net/tun`, and
`CREATE_TUN_DEVICE=false`, mirroring the live container. That last one is
load-bearing: Podman already provides the TUN device, and without it the image
tries to create its own, fails with `cannot remove '/dev/net/tun': Device or
resource busy`, and exits before attempting a tunnel.

Changing regions means setting `PIA_VPN_REGION` (default `panama`) and
recreating the container.

### Region names: image config vs PIA API

`OPENVPN_CONFIG` takes the name of a bundled `.ovpn` file in the image, which
is **not always PIA's API region id**. The API calls them `nl_amsterdam`,
`ch_switzerland`, and `sweden`; the image ships `netherlands`, `switzerland`,
and `se_stockholm`.

An unknown name fails quietly from the outside — the container prints its
167-line config list and exits, so anything watching only tunnel state sees a
timeout indistinguishable from a dead endpoint. This cost a full survey run on
2026-08-23; five regions reported as failures were fine under their real names.

List the valid names with:

```bash
sudo -u operator podman run --rm \
  docker.io/haugene/transmission-openvpn:latest ls /etc/openvpn/pia/
```

Reconciling the two namespaces, and detecting drift as PIA adds or removes
endpoints, is tracked in issue #159.

### Verified working regions

Probed 2026-08-23. Ports are per-session and will differ on reconnect; the
point is that each region returned one.

| Region (image config name) | Port | Gateway |
| --- | --- | --- |
| `ca_toronto` | 27251 | 10.17.112.1 |
| `ca_vancouver` | 28284 | 10.7.112.1 |
| `netherlands` | 34475 | 10.13.112.1 |
| `de_frankfurt` | 46014 | 10.135.192.1 |
| `de_berlin` | 32697 | 10.34.192.1 |
| `switzerland` | 47931 | 10.116.192.1 |
| `romania` | 47898 | 10.107.192.1 |
| `se_stockholm` | 43172 | 10.80.192.1 |

`panama` — the region this server was pinned to until 2026-08-23 — remains the
only one observed serving no port forwarding at all. **TILSIT now runs
`ca_toronto`**, which reserved port 50454 on first connect and verified open.

### On the hardcoded PF port

`update-port.sh` targets port 19999 on the tunnel gateway. That number is a
convention from PIA's reference implementation, not something PIA advertises:
their server list publishes ports for every other service (`wg` 1337, `meta`
443/8080, `ovpnudp` 8080/853/123/53) but nothing for port forwarding.

So a refused connection on 19999 proves only that nothing is listening *there*.
Panama failing while eight other regions succeeded makes "Panama serves no PF"
the overwhelmingly likely reading — but if PIA ever moves the service, every
region would look dead to this script and the probe would report a false
negative across the board. Tracked on issue #159.

## Diagnosing "torrents won't start"

Symptoms and what they mean, in the order worth checking.

### Is it the tunnel or just port forwarding?

```bash
sudo -u operator podman exec transmission-vpn curl -s https://ipinfo.io/ip
```

A PIA exit IP means the tunnel is fine and the problem is narrower.

### Check the listen port

```bash
transmission-remote localhost:9091 -si | grep -i "listen port"
```

`Listen port: 0` means port forwarding failed **and** took the peer port with
it. This is the failure mode that stops downloads entirely rather than merely
slowing them — see below.

### Check whether PF is reachable at all

```bash
GW=$(sudo -u operator podman exec transmission-vpn sh -c \
  "ip route | grep tun | grep -v src | head -1 | awk '{print \$3}'")
sudo -u operator podman exec transmission-vpn \
  curl --insecure -s -o /dev/null -w '%{http_code}\n' --max-time 6 \
  "https://${GW}:19999/getSignature"
```

An immediate connection refused (sub-100ms) means the region serves no PF at
all. Run the probe script to find one that does.

## Known failure mode: empty port zeroes Transmission

The upstream image's `update-port.sh` has an error-handling bug. When
`getSignature` fails it logs `the has been a fatal_error` and then **continues
anyway**, leaving `$pf_port` empty. That empty value reaches:

```bash
transmission-remote "$HOST" -p ""
```

which sets Transmission's listen port to 0. It then prints a success banner
with a blank port:

```
#######################
        SUCCESS
#######################
Port:
```

With no peer port, tracker announces fail and magnet links cannot retrieve
metadata over DHT, so downloads never start. The retry loop repeats this every
15 minutes, re-zeroing the port after any manual fix.

This is strictly worse than doing nothing: an unforwarded Transmission on a
valid port still downloads from seeders, just more slowly.

### How this is fixed here

The bundled updater cannot be patched in place: it lives at
`/etc/openvpn/pia/update-port.sh` inside the image, alongside the 167 `.ovpn`
region configs, so mounting over that directory to swap one file would hide
the configs and break region selection.

Instead `DISABLE_PORT_UPDATER=true` keeps it dormant, and
[`transmission-post-start.sh`](../../app-setup/templates/transmission-post-start.sh)
runs our own port-forwarding manager from the already-mounted `/scripts`
volume. It performs the same token → getSignature → bindPort flow, but hands
the result to
[`pia-port-guard.sh`](../../app-setup/templates/pia-port-guard.sh), which
refuses empty, non-numeric, `null`, zero, privileged, and out-of-range values
and leaves the existing port intact instead.

If the guard library is missing the manager exits rather than running
unguarded — an unforwarded Transmission beats a zeroed one.

Covered by `tests/pia-port-guard.bats` and
`tests/transmission-post-start.bats`.

#### Two container quirks worth knowing

**The post-start hook is called synchronously.** The image backgrounds its own
updater with `&` but invokes `/scripts/transmission-post-start.sh` inline. A
hook that blocks — as any lifetime loop does — hangs the rest of the startup
chain, leaving the tunnel negotiated but passing no traffic at all: DNS fails,
`curl` to a bare IP fails, and `Transmission startup script complete` never
appears in the log. The manager therefore backgrounds itself immediately and
returns. Diagnose by counting that line:

```bash
sudo -u operator podman logs transmission-vpn | grep -c "startup script complete"
# 0 means something in the startup chain is blocking
```

**Peer port randomization fights port forwarding.** The image defaults
`peer-port-random-on-start` to true, which picks a random port at each start
and silently replaces the one PIA assigned. `settings.json` and the running
listen port then disagree. The setup script now pins
`TRANSMISSION_PEER_PORT_RANDOM_ON_START=false`.

## Monitoring note

Port-forwarding loss is not always visible from download activity. Well-seeded
torrents continue to work unforwarded via outbound connections, so a monitor
that only asks "are downloads moving?" will miss it. Assert on the listen port
directly:

```bash
transmission-remote localhost:9091 -si | grep -i "listen port"
# Alert when this reports 0
```

Observed 2026-08-21 → 2026-08-23: port forwarding was broken for roughly 47
hours before it was noticed, and only became visible when a newly added magnet
link failed to resolve.

## Related

- Issue #159 — dynamic VPN endpoint selection, including PF verification as a
  gating criterion
- [transmission-filebot-README.md](transmission-filebot-README.md) — the
  post-download processing pipeline
