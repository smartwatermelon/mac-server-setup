# mac-server-setup

Mac Mini media server provisioning system. Three-phase setup: prep (dev Mac),
first-boot (target), app-setup (applications). All scripts are idempotent.

## Environment Detection (PRIORITY)

**Before taking any action, determine which machine you are running on:**

```bash
hostname -s   # TILSIT = media server (target), anything else = dev machine
whoami        # andrewrich = admin, operator = service account
```

**Behavior by environment:**

| Environment | Role | Safe actions | Dangerous actions |
| --- | --- | --- | --- |
| **Dev machine** | Development, testing, prep | Edit code, run tests, commit, push | Never deploy, never touch services |
| **TILSIT (andrewrich)** | Server admin | Edit code, run tests, read service status | Do NOT modify running services without explicit permission |
| **TILSIT (operator)** | Service account | Read logs, check status | Do NOT modify anything |

**On TILSIT**: You are on the production media server. Services are running.
Do not restart, reconfigure, or redeploy services unless explicitly instructed.
Read-only operations (logs, status, config inspection) are always safe.

## Service-Specific Documentation

**MANDATORY: Before modifying any files related to these services,
read the corresponding documentation first.**

### Caddy (reverse proxy, TLS, dashboard)

**Files**: `app-setup/caddy-setup.sh`, `app-setup/templates/Caddyfile`,
`app-setup/templates/caddy-*.sh`, `app-setup/templates/media-server.py`,
`app-setup/templates/www/`, `app-setup/templates/com.caddyserver.caddy.plist`,
`app-setup/templates/com.media-server.plist`

**Documentation**: `docs/apps/caddy-README.md`

**Covers**: TLS strategy (internal PKI + DNS-01 Cloudflare), custom Caddy build
with cloudflare module, CF_API_TOKEN injection chain, media file server
architecture (why Python not Caddy), DNS propagation timing, certmagic
environment variable syntax (`{$VAR}` vs `{env.VAR}`), ACME state management

### Cloudflare DDNS (public A-record updater)

**Files**: `app-setup/cloudflare-ddns-setup.sh`,
`app-setup/templates/cloudflare-ddns.sh`,
`app-setup/templates/com.cloudflare-ddns.plist`,
`tests/cloudflare-ddns.bats`

**Documentation**: `docs/apps/cloudflare-ddns-README.md`

**Covers**: Why the PIA-era DDNS was retired and how the standalone daemon
replaces it, System keychain token reuse (same entry Caddy reads), public-IP
provider fallback chain, change-detection vs heartbeat log cadence, Cloudflare
API error modes, and the `TEST_RUNNER` hook that lets BATS mock network calls.

### PIA VPN (credentials, port forwarding, region selection)

**Files**: `app-setup/podman-transmission-setup.sh`,
`app-setup/templates/pia-pf-probe.sh`,
`app-setup/templates/pia-port-guard.sh`, `tests/pia-port-guard.bats`

**Documentation**: `docs/apps/pia-vpn-README.md`

**Covers**: PIA credential chain (1Password → keychain → .env → container) and
the password rotation procedure, next-generation port-forwarding flow, why
PIA's `port_forward` region flag cannot be trusted, the upstream
`update-port.sh` bug that zeroes Transmission's listen port on PF failure, and
diagnosing tunnel-vs-port-forwarding failures

### Transmission-FileBot (media processing pipeline)

**Files**: `app-setup/templates/transmission-done.sh`,
`app-setup/transmission-filebot-setup.sh`, `app-setup/templates/config.yml.template`,
`app-setup/templates/process-media.command`, `tests/transmission-filebot/`

**Documentation**: `docs/apps/transmission-filebot-README.md`

**Covers**: FileBot invocation and output parsing, Plex API section IDs,
NFS/VirtioFS cache invalidation, Transmission's limited execution environment,
test architecture (BATS, TEST_RUNNER mode), file stability checks

## Testing

```bash
# Run all BATS tests
bats tests/plex-watchdog.bats
bats tests/cloudflare-ddns.bats
bats tests/transmission-filebot/**/*.bats

# Lint all shell scripts
shellcheck app-setup/**/*.sh scripts/**/*.sh
shfmt -d -i 2 -ci -bn app-setup/**/*.sh scripts/**/*.sh
```

## Template Convention

Template files in `app-setup/templates/` use `__PLACEHOLDER__` tokens that are
substituted by the corresponding setup script at deploy time. Common placeholders:

- `__HOSTNAME__`, `__HOSTNAME_LOWER__` - Server name
- `__OPERATOR_USERNAME__` - Service account name
- `__NAS_SHARE_NAME__` - NAS media share name
- `__EXTERNAL_HOSTNAME__` - Public domain (e.g. tilsit.vip)
- `__SERVER_LAN_IP__` - Static LAN IP address

Always grep for `__[A-Z_]*__` in template files before committing to catch
unsubstituted placeholders.
