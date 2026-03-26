# Containerized Transmission (haugene + Podman) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace PIA Desktop + split tunnel + shell script monitoring stack with a single
haugene/transmission-openvpn container running inside Podman, giving kernel-level VPN
enforcement and eliminating the NE proxy consent problem entirely.

**Architecture:** haugene/transmission-openvpn bundles OpenVPN + Transmission + PIA port
forwarding into one container running in a Podman Linux VM (`podman machine`, rootful mode).
The container's `/data` bind-mounts the macOS NAS SMB mount. The existing macOS
`transmission-done.sh` script continues running on the host, triggered by trigger files the
container writes to the NAS on torrent completion. Migration runs in three phases:
Phase 1 = parallel validation (port 9092), Phase 2 = cutover (port 9091), Phase 3 = decommission.

**Tech Stack:** Podman ≥4.7.0 (Homebrew formula, CLI-only, rootful machine), Podman Compose
(built-in since 4.7.0), haugene/transmission-openvpn, bash, macOS keychain (security CLI), launchd.

---

## Background and Key Decisions

This plan implements the proposal in `docs/container-transmission-proposal.md`.

**Why Podman instead of OrbStack:**
Podman is a Homebrew formula (CLI tool); OrbStack is a Cask (GUI app whose daemon is tied to
the Aqua session). On a headless server managed over SSH, a CLI daemon is the correct
primitive: `podman machine start` is a plain command that launchd can manage directly.
OrbStack's startup goes through Login Items and its GUI process, which is opaque to launchctl.

**Why rootful Podman machine:**
haugene requires `CAP_NET_ADMIN` and `/dev/net/tun` to run OpenVPN inside the container.
Podman's default machine mode is rootless (containers run as a non-root user inside the
Linux VM), which blocks NET_ADMIN. `--rootful` makes containers run as root inside the VM.
This is appropriate for a single-purpose server where intra-VM multi-user isolation is not
a concern. The VM itself is isolated from macOS.

**Why haugene/transmission-openvpn instead of gluetun + linuxserver/transmission:**
- Single container instead of two
- PIA port forwarding handled automatically (no companion script needed)
- Battle-tested (4.5k stars, v5.3.2, active maintenance)
- Server uses non-US PIA endpoint (Panama) — port forwarding works with PIA OpenVPN on non-US servers
- OpenVPN vs WireGuard performance difference is irrelevant for a 24/7 background seeder

**Why the done script stays on macOS (not ported to Linux):**
The existing `transmission-done.sh` uses macOS-specific tooling: `arch` (Homebrew prefix),
BSD `stat -f%z`, FileBot via `/opt/homebrew/bin/filebot`. Rather than porting it,
the container writes a trigger file to the NAS (shared with macOS via SMB bind-mount).
A macOS LaunchAgent polls for trigger files and invokes the existing done script unchanged.

**NAS mount approach:** Use macOS bind-mount of `~/.local/mnt/DSMedia` into the container
at `/data`. If VirtioFS doesn't expose the SMB content (open question §5.1 from proposal),
fall back to mounting the SMB share from within the Podman VM's `/etc/fstab`.
**Must be validated with `podman run --rm -v ~/.local/mnt/DSMedia:/test alpine ls /test`
before proceeding past Task 4.**

**Credential storage:** PIA account credentials (username + password) written to
`~/containers/transmission/.env` (mode 600) during setup, retrieved from macOS keychain.
The `.env` file persists across reboots — no credential injection needed at container
startup time. Credentials are stored in the keychain as a combined `username:password` string
per the project convention; the setup script splits them with `cut`.

**`restart: unless-stopped` behavior:** This policy keeps the container running if it exits
or the daemon restarts within a running Podman machine. It does NOT restart the container
when the Podman machine itself starts (e.g., after a reboot). The machine-start LaunchAgent
must therefore run `podman compose up -d` after the machine is ready.

---

## Phase 1: Repo Implementation (Tasks 1–8)

These tasks create and modify files in the repo. No server changes yet.

---

### Task 1: Update proposal doc and plan.md

**Purpose:** Mark the proposal as active with the haugene decision recorded.

**Files:**
- Modify: `docs/container-transmission-proposal.md` (header only)
- Modify: `plan.md` (Next Priorities section)

**Step 1: Update proposal status**

Change the header of `docs/container-transmission-proposal.md`:

```
**Status:** Active — approved for implementation 2026-03-08
**Decision:** haugene/transmission-openvpn (not gluetun + linuxserver/transmission)
  Rationale: single container, automatic PIA port forwarding, battle-tested.
  Server uses Panama PIA endpoint (non-US = port forwarding supported with OpenVPN).
```

**Step 2: Update plan.md Next Priorities**

In `plan.md`, under `## Next Priorities → Immediate`, add:

```
1. **Containerized Transmission (haugene + Podman)** — implementation plan at
   `docs/plans/2026-03-08-containerized-transmission.md`. Phase 1 = parallel validation.
```

**Step 3: Shellcheck (nothing to check — no shell scripts modified)**

**Step 4: Commit**

```bash
git add docs/container-transmission-proposal.md plan.md
git commit -m "docs: mark container-transmission proposal as active (haugene decision)"
```

---

### Task 2: Add PIA credentials to config and prep-airdrop.sh

**Purpose:** PIA account credentials (username + password) must be in the keychain on the
server so `podman-transmission-setup.sh` can write them to `.env`.

**Files:**
- Modify: `config/config.conf.template`
- Modify: `prep-airdrop.sh`

**Background:** `prep-airdrop.sh` retrieves credentials from 1Password and stores them in an
external keychain for transfer to the server. The keychain naming convention is
`{service}-{SERVER_NAME_LOWER}` (e.g. `pia-account-tilsit`). Per the project convention,
credentials are stored as a combined `username:password` string, with the account field set
to `${SERVER_NAME_LOWER}`. Currently PIA Desktop manages its own auth internally —
haugene needs the raw account credentials.

**Step 1: Add variables to config.conf.template**

In `config/config.conf.template`, find the `# VPN and Transmission configuration` section.
Add after it:

```bash
# Container-based Transmission (Podman + haugene)
# Used by podman-transmission-setup.sh. Leave empty if using native Transmission.
ONEPASSWORD_PIA_ITEM=""          # 1Password item name holding PIA account credentials
PIA_VPN_REGION="panama"          # PIA server region for haugene (must support port forwarding)
LAN_SUBNET="192.168.1.0/24"      # Local network CIDR for Transmission web UI access
```

**Step 2: Add PIA credential retrieval to prep-airdrop.sh**

Find the credential retrieval block in `prep-airdrop.sh` (near the `OP_TIMEMACHINE_ENTRY`
lines). Add PIA retrieval after the existing entries, guarded by the variable being set:

The pattern in prep-airdrop.sh is: retrieve from 1Password with `op item get`, then call
`store_external_keychain_credential`. Follow the exact same pattern as the other credentials.
Combine the PIA username and password as `username:password` in the password field.
Use account field `${SERVER_NAME_LOWER}`, service name `pia-account-${SERVER_NAME_LOWER}`.

Guard with: `if [[ -n "${ONEPASSWORD_PIA_ITEM}" ]]; then ... fi`

**Step 3: Shellcheck**

```bash
shellcheck prep-airdrop.sh config/config.conf.template
```

Expected: zero warnings, zero errors.

**Step 4: Commit**

```bash
git add config/config.conf.template prep-airdrop.sh
git commit -m "feat(container): add PIA credential retrieval to prep-airdrop and config template"
```

---

### Task 3: Create the Docker Compose template

**Purpose:** The compose.yml that defines the haugene container. Stored in the repo as a
template with `__VARIABLE__` placeholders; deployed to `~/containers/transmission/` on the
server by `podman-transmission-setup.sh`.

**Files:**
- Create: `app-setup/containers/transmission/compose.yml`

**Step 1: Create the directory**

```bash
mkdir -p app-setup/containers/transmission
```

**Step 2: Verify the PIA config name for your region in haugene v5**

Before writing the compose template, confirm the exact config identifier. Run:

```bash
# On a machine with Podman/Docker available:
docker run --rm --entrypoint ls haugene/transmission-openvpn:latest /etc/openvpn/pia/ | grep -i panama
```

Expected output: a filename like `panama.ovpn` or `PIA - Panama.ovpn`. The value used in
`OPENVPN_CONFIG` must match the filename stem (without `.ovpn`). If the output is
`PIA - Panama.ovpn`, the config value is `PIA - Panama`. Update `PIA_VPN_REGION` in
`config.conf.template` to match the exact stem.

Also verify arm64 support (Apple Silicon server):

```bash
docker manifest inspect haugene/transmission-openvpn:latest | grep -A2 '"platform"' | grep 'arm64\|aarch64'
```

If arm64 is absent, pin to the last known arm64-capable tag (check
https://github.com/haugene/docker-transmission-openvpn/releases). Document the finding
in the compose.yml header comment.

**Step 3: Create compose.yml**

```yaml
# ~/containers/transmission/compose.yml
# Deployed by podman-transmission-setup.sh. Template placeholders replaced at deploy time.
# __SERVER_NAME__    → server hostname (e.g. TILSIT)
# __PIA_VPN_REGION__ → PIA server region (e.g. PIA - Panama — must match /etc/openvpn/pia/ stem)
# __LAN_SUBNET__     → local network CIDR (e.g. 192.168.1.0/24)
# __OPERATOR_HOME__  → operator home directory (e.g. /Users/operator)
# __PUID__           → operator UID (e.g. 502)
# __PGID__           → operator primary GID (e.g. 20)
# __TZ__             → timezone (e.g. America/Los_Angeles)

services:
  transmission:
    image: haugene/transmission-openvpn:latest
    container_name: transmission-vpn
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - OPENVPN_PROVIDER=PIA
      - OPENVPN_CONFIG=__PIA_VPN_REGION__
      - OPENVPN_USERNAME=${PIA_USERNAME}
      - OPENVPN_PASSWORD=${PIA_PASSWORD}
      - LOCAL_NETWORK=__LAN_SUBNET__
      - PUID=__PUID__
      - PGID=__PGID__
      - TZ=__TZ__
      - TRANSMISSION_DOWNLOAD_DIR=/data/Media/Torrents/pending-move
      - TRANSMISSION_INCOMPLETE_DIR=/data/Media/Torrents/incomplete
      - TRANSMISSION_WATCH_DIR=/data/Media/Torrents/watch
      - TRANSMISSION_WATCH_DIR_ENABLED=true
      - TRANSMISSION_RATIO_LIMIT_ENABLED=false
      - TRANSMISSION_ENCRYPTION=2
      - TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false
      - TRANSMISSION_RPC_WHITELIST_ENABLED=false
      - TRANSMISSION_SCRIPT_TORRENT_DONE_ENABLED=true
      - TRANSMISSION_SCRIPT_TORRENT_DONE_FILENAME=/scripts/transmission-post-done.sh
      - CREATE_TUN_DEVICE=true
      - LOG_TO_STDOUT=true
    volumes:
      - __OPERATOR_HOME__/.local/mnt/DSMedia:/data
      - __OPERATOR_HOME__/containers/transmission/scripts:/scripts
      - __OPERATOR_HOME__/containers/transmission/config:/config
    ports:
      - "9091:9091"
    restart: unless-stopped
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
```

**Notes on key settings:**
- `TRANSMISSION_WATCH_DIR` replaces the current `~/.local/sync/dropbox` watch directory.
  The rclone sync target must be updated to point here (see Task 8).
- `TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=false` is safe because `LOCAL_NETWORK`
  restricts access to the LAN only. The existing native Transmission.app also had
  no authentication.
- `LOG_TO_STDOUT=true` routes container logs to `podman logs transmission-vpn`.
- Port 9091 is the final state. During Phase 1 parallel run, operator temporarily
  edits this to 9092 before deploying.
- `restart: unless-stopped` restarts the container within a running Podman machine but
  does NOT restart it after the machine itself restarts. The machine-start LaunchAgent
  handles that (see Task 6).

**Step 4: Shellcheck (N/A — YAML file)**

**Step 5: Commit**

```bash
git add app-setup/containers/transmission/compose.yml
git commit -m "feat(container): add haugene transmission Docker Compose template"
```

---

### Task 4: Create the container-side done trigger script

**Purpose:** Runs inside the haugene container when a torrent completes. Writes a trigger
file to the NAS (shared with macOS) containing torrent metadata. The macOS trigger watcher
(Task 5) picks this up and invokes the existing `transmission-done.sh`.

**Files:**
- Create: `app-setup/templates/transmission-post-done.sh`

**Step 1: Create the script**

```bash
#!/usr/bin/env bash
#
# transmission-post-done.sh - Container-side torrent completion trigger
#
# Runs inside the haugene/transmission-openvpn container when a torrent finishes.
# Writes a trigger file to /data/.done/ (NAS-mounted) that the macOS
# transmission-trigger-watcher.sh LaunchAgent picks up to invoke FileBot processing.
#
# Environment variables provided by Transmission:
#   TR_TORRENT_DIR    — parent download directory in container (e.g. /data/Media/Torrents/pending-move)
#                       NOTE: this is the directory containing the torrent, NOT a path that
#                       includes the torrent name. TR_TORRENT_NAME is the entry within it.
#   TR_TORRENT_NAME   — torrent name (file or directory within TR_TORRENT_DIR)
#   TR_TORRENT_HASH   — torrent hash (unique identifier, used as trigger filename)
#   TR_APP_VERSION    — Transmission version
#
# Usage: Configured via TRANSMISSION_SCRIPT_TORRENT_DONE_FILENAME in compose.yml.
#   Not intended for manual execution.

set -euo pipefail

DONE_DIR="/data/.done"
mkdir -p "${DONE_DIR}"

# Write trigger file named by hash to avoid collisions
TRIGGER_FILE="${DONE_DIR}/${TR_TORRENT_HASH}"

printf 'TR_TORRENT_NAME=%s\nTR_TORRENT_DIR=%s\nTR_TORRENT_HASH=%s\n' \
    "${TR_TORRENT_NAME}" \
    "${TR_TORRENT_DIR}" \
    "${TR_TORRENT_HASH}" \
    > "${TRIGGER_FILE}"

printf '[%s] [transmission-post-done] Trigger written: %s (%s)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "${TR_TORRENT_NAME}" \
    "${TR_TORRENT_HASH}"
```

**Note on path mapping:** `TR_TORRENT_DIR` inside the container is the parent download
directory under `/data` (e.g. `/data/Media/Torrents/pending-move`). The macOS watcher
maps this to the NAS mount by replacing `/data` with `~/.local/mnt/DSMedia`. The full
path to the content is `${TR_TORRENT_DIR}/${TR_TORRENT_NAME}` — same semantics the
existing `transmission-done.sh` already uses.

**Step 2: Shellcheck**

```bash
shellcheck app-setup/templates/transmission-post-done.sh
```

Expected: zero warnings, zero errors.

**Step 3: Commit**

```bash
git add app-setup/templates/transmission-post-done.sh
git commit -m "feat(container): add container-side torrent completion trigger script"
```

---

### Task 5: Create the macOS trigger watcher script

**Purpose:** Runs as a macOS LaunchAgent. Polls `~/.local/mnt/DSMedia/.done/` every 60
seconds, reads trigger files written by the container, maps container paths to macOS NAS
paths, and invokes the existing `transmission-done.sh` for each completed torrent.

**Template placeholders:**
- `__SERVER_NAME__` → server hostname for logging

**Files:**
- Create: `app-setup/templates/transmission-trigger-watcher.sh`

**Step 1: Create the script**

```bash
#!/usr/bin/env bash
#
# transmission-trigger-watcher.sh - macOS trigger file watcher for containerized Transmission
#
# Polls ~/.local/mnt/DSMedia/.done/ for trigger files written by the
# transmission-post-done.sh script running inside the haugene container.
# On finding a trigger file, maps the container path to the macOS NAS mount path
# and invokes transmission-done.sh with the appropriate environment variables.
#
# Runs as a persistent daemon via com.<hostname>.transmission-trigger-watcher LaunchAgent.
# Replaces the native Transmission.app "Done Script" mechanism used before containerization.
#
# Template placeholders (replaced during deployment):
#   __SERVER_NAME__ → server hostname for logging
#
# Author: Andrew Rich <andrew.rich@gmail.com>

set -euo pipefail

SERVER_NAME="__SERVER_NAME__"
HOSTNAME_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"${SERVER_NAME}")"

DONE_DIR="${HOME}/.local/mnt/DSMedia/.done"
DONE_SCRIPT="${HOME}/.local/bin/transmission-done.sh"
LOG_FILE="${HOME}/.local/state/${HOSTNAME_LOWER}-transmission-trigger-watcher.log"
MAX_LOG_SIZE=5242880  # 5MB
POLL_INTERVAL=60
MAX_RETRIES=5         # Trigger files retained up to this many poll cycles on failure

# Container-to-macOS path prefix mapping
CONTAINER_DATA_PREFIX="/data"
MACOS_NAS_PREFIX="${HOME}/.local/mnt/DSMedia"

mkdir -p "$(dirname "${LOG_FILE}")"

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [trigger-watcher] %s\n' "${timestamp}" "$1" | tee -a "${LOG_FILE}"
}

rotate_log() {
    if [[ -f "${LOG_FILE}" ]]; then
        local size
        size=$(stat -f%z "${LOG_FILE}" 2>/dev/null || echo "0")
        if [[ "${size}" -gt ${MAX_LOG_SIZE} ]]; then
            mv "${LOG_FILE}" "${LOG_FILE}.old"
            log "Log rotated"
        fi
    fi
}

# Map container-internal path to macOS NAS mount path
map_container_path() {
    local container_path="$1"
    echo "${MACOS_NAS_PREFIX}${container_path#${CONTAINER_DATA_PREFIX}}"
}

process_trigger() {
    local trigger_file="$1"
    local name dir hash

    # Parse trigger file (KEY=VALUE lines).
    # grep returns exit 1 on no match; || true prevents set -e exit with empty result.
    name=$(grep '^TR_TORRENT_NAME=' "${trigger_file}" | cut -d= -f2- || true)
    dir=$(grep '^TR_TORRENT_DIR=' "${trigger_file}" | cut -d= -f2- || true)
    hash=$(grep '^TR_TORRENT_HASH=' "${trigger_file}" | cut -d= -f2- || true)

    if [[ -z "${name}" ]] || [[ -z "${dir}" ]] || [[ -z "${hash}" ]]; then
        log "ERROR: Malformed trigger file ${trigger_file} — skipping"
        rm -f "${trigger_file}"
        return 1
    fi

    # Check retry count (stored as .retry.<n> suffix files)
    local retry_count=0
    retry_count=$(find "$(dirname "${trigger_file}")" \
        -name "${hash}.retry.*" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${retry_count}" -ge "${MAX_RETRIES}" ]]; then
        log "ERROR: Trigger file ${hash} failed ${MAX_RETRIES} times — moving to .dead"
        mv "${trigger_file}" "${DONE_DIR}/${hash}.dead"
        find "${DONE_DIR}" -name "${hash}.retry.*" -delete 2>/dev/null || true
        return 1
    fi

    # Map container path to macOS path
    local macos_dir
    macos_dir=$(map_container_path "${dir}")

    log "Processing: ${name} (hash: ${hash})"
    log "  Container path: ${dir}"
    log "  macOS path:     ${macos_dir}"

    if [[ ! -d "${macos_dir}" ]]; then
        log "WARNING: macOS path does not exist: ${macos_dir} — NAS may not be mounted"
        return 1
    fi

    if [[ ! -x "${DONE_SCRIPT}" ]]; then
        log "ERROR: Done script not found or not executable: ${DONE_SCRIPT}"
        return 1
    fi

    # Invoke the existing macOS done script with Transmission's env vars
    if TR_TORRENT_NAME="${name}" \
       TR_TORRENT_DIR="${macos_dir}" \
       TR_TORRENT_HASH="${hash}" \
       "${DONE_SCRIPT}"; then
        log "Done script succeeded for: ${name}"
        rm -f "${trigger_file}"
        find "${DONE_DIR}" -name "${hash}.retry.*" -delete 2>/dev/null || true
    else
        local next_retry=$(( retry_count + 1 ))
        log "ERROR: Done script failed for: ${name} (retry ${next_retry}/${MAX_RETRIES})"
        touch "${DONE_DIR}/${hash}.retry.${next_retry}"
        return 1
    fi
}

trap 'log "Trigger watcher stopping (signal received)"; exit 0' INT TERM

log "=========================================="
log "Transmission trigger watcher starting"
log "=========================================="
log "Server: ${SERVER_NAME}"
log "Done dir: ${DONE_DIR}"
log "Poll interval: ${POLL_INTERVAL}s"

loop_count=0
while true; do
    ((loop_count += 1))

    if [[ $((loop_count % 60)) -eq 0 ]]; then
        rotate_log
    fi

    if [[ -d "${DONE_DIR}" ]]; then
        # Process any trigger files present (skip .retry.* and .dead files)
        while IFS= read -r -d '' trigger_file; do
            process_trigger "${trigger_file}" || true
        done < <(find "${DONE_DIR}" -maxdepth 1 -type f \
            ! -name '*.retry.*' ! -name '*.dead' -print0 2>/dev/null)
    fi

    sleep "${POLL_INTERVAL}"
done
```

**Step 2: Shellcheck**

```bash
shellcheck app-setup/templates/transmission-trigger-watcher.sh
```

Expected: zero warnings, zero errors.

**Step 3: Commit**

```bash
git add app-setup/templates/transmission-trigger-watcher.sh
git commit -m "feat(container): add macOS trigger watcher for containerized Transmission done events"
```

---

### Task 6: Create podman-transmission-setup.sh

**Purpose:** The main setup script. Installs Podman (≥4.7.0), creates the Podman machine
(rootful, named `transmission-vm`), creates the container directory structure, deploys
compose.yml and scripts (with variable substitution), writes the `.env` credentials file,
creates LaunchAgents for machine start and the trigger watcher, and validates the setup.

This script follows the existing `app-setup/*-setup.sh` pattern exactly: reads config.conf,
uses `log()` / `section()` / `collect_error()` / `check_success()`, supports `--force`.

**Files:**
- Create: `app-setup/podman-transmission-setup.sh`

The script sections, in order:

**Sections:**

1. Header, shebang, `set -euo pipefail`, argument parsing (`--force`), config loading
   (same boilerplate as other setup scripts — copy from `plex-setup.sh` or `catch-setup.sh`)

2. **Install Podman** (if not present) and verify minimum version:
   ```bash
   section "Podman Installation"
   if ! command -v podman >/dev/null 2>&1; then
       brew install podman
   fi

   # Require Podman ≥4.7.0 for built-in compose (podman compose)
   PODMAN_VERSION=$(podman --version | awk '{print $3}')
   PODMAN_MAJOR=$(cut -d. -f1 <<< "${PODMAN_VERSION}")
   PODMAN_MINOR=$(cut -d. -f2 <<< "${PODMAN_VERSION}")
   if [[ "${PODMAN_MAJOR}" -lt 4 ]] || \
      { [[ "${PODMAN_MAJOR}" -eq 4 ]] && [[ "${PODMAN_MINOR}" -lt 7 ]]; }; then
       collect_error "Podman ${PODMAN_VERSION} is too old; need ≥4.7.0 for built-in compose"
   fi
   ```

3. **Initialize the rootful Podman machine:**
   ```bash
   section "Podman Machine Setup"
   # Check if machine already exists
   if ! podman machine inspect transmission-vm >/dev/null 2>&1; then
       # Rootful mode required for CAP_NET_ADMIN (OpenVPN inside container)
       podman machine init \
           --rootful \
           --cpus 2 \
           --memory 2048 \
           --disk-size 20 \
           transmission-vm
       log "Podman machine 'transmission-vm' initialized (rootful)"

       # Register as the default connection so 'podman compose' targets this machine
       podman system connection default transmission-vm
       log "Podman default connection set to transmission-vm"
   else
       log "Podman machine 'transmission-vm' already exists — skipping init"
   fi

   MACHINE_STATE=$(podman machine inspect transmission-vm --format '{{.State}}' 2>/dev/null || echo "unknown")
   if [[ "${MACHINE_STATE}" != "running" ]]; then
       podman machine start transmission-vm
       log "Podman machine started"
   else
       log "Podman machine already running"
   fi
   ```

   **Important:** The machine is named `transmission-vm` (not the default `podman-machine-default`)
   to make its purpose explicit and allow coexistence with any future machines.

4. **Create container directory structure:**
   ```
   ~/containers/transmission/
   ~/containers/transmission/config/
   ~/containers/transmission/scripts/
   ```
   With permissions 700 on the root, 755 on subdirectories.

5. **Read PIA credentials from keychain and write .env file:**
   ```bash
   # Credentials stored as "username:password" combined string per project keychain convention.
   # Account field = ${HOSTNAME_LOWER}, service = pia-account-${HOSTNAME_LOWER}.
   PIA_CREDS=$(security find-generic-password \
       -s "pia-account-${HOSTNAME_LOWER}" \
       -a "${HOSTNAME_LOWER}" \
       -w 2>/dev/null || true)
   if [[ -z "${PIA_CREDS}" ]]; then
       collect_error "PIA credentials not found in keychain (service: pia-account-${HOSTNAME_LOWER}, account: ${HOSTNAME_LOWER})"
   else
       PIA_USERNAME=$(cut -d: -f1 <<< "${PIA_CREDS}")
       PIA_PASSWORD=$(cut -d: -f2- <<< "${PIA_CREDS}")
       ENV_FILE="${OPERATOR_HOME}/containers/transmission/.env"
       printf 'PIA_USERNAME=%s\nPIA_PASSWORD=%s\n' "${PIA_USERNAME}" "${PIA_PASSWORD}" \
           | sudo -iu "${OPERATOR_USERNAME}" tee "${ENV_FILE}" >/dev/null
       sudo chmod 600 "${ENV_FILE}"
       sudo chown "${OPERATOR_USERNAME}:staff" "${ENV_FILE}"
       log ".env written with PIA credentials (600)"
       unset PIA_CREDS PIA_USERNAME PIA_PASSWORD
   fi
   ```

6. **Deploy compose.yml** (from `app-setup/containers/transmission/compose.yml` with sed
   substitution):
   Variables to substitute: `__SERVER_NAME__`, `__PIA_VPN_REGION__`, `__LAN_SUBNET__`,
   `__OPERATOR_HOME__`, `__PUID__`, `__PGID__`, `__TZ__`.
   - `PUID` = `id -u "${OPERATOR_USERNAME}"`
   - `PGID` = `id -g "${OPERATOR_USERNAME}"`
   - `TZ` = `$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')` — fallback to `America/Los_Angeles`

7. **Deploy transmission-post-done.sh** (template → `~/containers/transmission/scripts/`):
   ```bash
   sudo cp "${SCRIPT_DIR}/templates/transmission-post-done.sh" \
       "${OPERATOR_HOME}/containers/transmission/scripts/transmission-post-done.sh"
   sudo chmod 755 "${OPERATOR_HOME}/containers/transmission/scripts/transmission-post-done.sh"
   sudo chown "${OPERATOR_USERNAME}:staff" \
       "${OPERATOR_HOME}/containers/transmission/scripts/transmission-post-done.sh"
   ```

8. **Deploy transmission-trigger-watcher.sh** (template → `~/.local/bin/` with __SERVER_NAME__
   substitution, same pattern as other template deployments):
   ```bash
   WATCHER_DEST="${OPERATOR_HOME}/.local/bin/transmission-trigger-watcher.sh"
   sed "s/__SERVER_NAME__/${SERVER_NAME}/g" \
       "${SCRIPT_DIR}/templates/transmission-trigger-watcher.sh" \
       | sudo -iu "${OPERATOR_USERNAME}" tee "${WATCHER_DEST}" >/dev/null
   sudo chmod 755 "${WATCHER_DEST}"
   sudo chown "${OPERATOR_USERNAME}:staff" "${WATCHER_DEST}"
   ```

9. **Deploy podman-machine-start.sh** wrapper script (to `~/.local/bin/`):

   This script starts the Podman machine AND brings up the compose stack.
   Separate from the setup script — it will be invoked by the LaunchAgent on each login.

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   # Start the Podman machine and bring up the transmission container stack.
   # Invoked by com.__HOSTNAME_LOWER__.podman-transmission-vm LaunchAgent.

   MACHINE_STATE=$(podman machine inspect transmission-vm --format '{{.State}}' 2>/dev/null || echo "unknown")
   if [[ "${MACHINE_STATE}" != "running" ]]; then
       podman machine start transmission-vm
   fi

   # Wait for the machine socket to be ready (up to 30s)
   for _ in $(seq 1 30); do
       if podman info >/dev/null 2>&1; then
           break
       fi
       sleep 1
   done

   cd "__OPERATOR_HOME__/containers/transmission"
   podman compose --env-file .env up -d
   ```

   Deploy with `__HOSTNAME_LOWER__` and `__OPERATOR_HOME__` substituted at deploy time.
   Place at `~/.local/bin/podman-machine-start.sh`, mode 755.

10. **Create two LaunchAgents** (same heredoc pattern as `transmission-setup.sh`):

    **a) `com.${HOSTNAME_LOWER}.podman-transmission-vm`** — starts the Podman machine and
    compose stack at login:
    - `RunAtLoad: true`, `KeepAlive: false`
    - `ProgramArguments: [/bin/bash, ~/.local/bin/podman-machine-start.sh]`
    - `StandardOutPath` / `StandardErrorPath` to `~/.local/state/`

    **b) `com.${HOSTNAME_LOWER}.transmission-trigger-watcher`** — the done-script watcher:
    - `RunAtLoad: true`, `KeepAlive: true`
    - Runs independently of the Podman machine (it just polls NAS files)

11. **Validate NAS bind mount** (critical check from proposal §5.1):
    ```bash
    section "Validating NAS bind mount through Podman VirtioFS"
    NAS_MOUNT="${OPERATOR_HOME}/.local/mnt/DSMedia"
    if [[ -d "${NAS_MOUNT}" ]]; then
        test_result=$(podman run --rm \
            -v "${NAS_MOUNT}:/test:ro" \
            alpine ls /test 2>&1) || true
        if [[ -n "${test_result}" ]]; then
            log "NAS bind mount: OK — VirtioFS exposes mounted content"
            log "  Contents: ${test_result}"
        else
            collect_warning "NAS bind mount: EMPTY — VirtioFS may not see SMB mount content"
            collect_warning "  Fallback required: mount SMB from within Podman VM /etc/fstab"
            collect_warning "  See docs/container-transmission-proposal.md §5.1"
        fi
    else
        collect_warning "NAS mount not present at ${NAS_MOUNT} — ensure mount-nas-media runs first"
    fi
    ```

12. **Start the container stack:**
    ```bash
    cd "${OPERATOR_HOME}/containers/transmission"
    podman compose --env-file .env up -d
    ```

13. **Summary section** (using `show_collected_issues` like other setup scripts).

**Step 1: Write the script** following the above specification.

**Step 2: Shellcheck**

```bash
shellcheck app-setup/podman-transmission-setup.sh
```

Expected: zero warnings, zero errors.

**Step 3: Commit**

```bash
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(container): add podman-transmission-setup.sh"
```

---

### Task 7: Update run-app-setup.sh and rclone watch directory

**Purpose:** Register the new setup script in the app orchestrator and note the rclone
sync target change needed for Phase 2 cutover.

**Files:**
- Modify: `app-setup/run-app-setup.sh`

**Step 1: Add podman-transmission-setup.sh to SCRIPT_ORDER**

In `run-app-setup.sh`, find the `SCRIPT_ORDER` associative array. Add:

```bash
SCRIPT_ORDER["podman-transmission-setup.sh"]="2.5:Container-based VPN torrent client (Podman + haugene)"
```

The `2.5` ordering places it after `transmission-setup.sh` (2) and before `filebot-setup.sh`
(3) in discovery ordering. The orchestrator uses numeric prefix for sorting.

Also update the comment block at the top of the file listing the scripts.

**Step 2: Rclone watch directory note**

The current rclone sync writes torrent files to `~/.local/sync/dropbox/`. The native
Transmission.app watches this directory (`AutoImport`). The haugene container watches
`/data/Media/Torrents/watch/` (= `~/.local/mnt/DSMedia/Media/Torrents/watch/` on macOS).

**Action for Phase 2 cutover** (not done now — document in script header):
- Update rclone-setup.sh or rclone config to sync to the NAS watch path instead
- OR add a second sync target
- This is a Phase 2 prerequisite, flagged in the podman-transmission-setup.sh header comment

For now, the container's watch dir is an additional watch location. During Phase 1 parallel
run, torrent files can be manually copied to the NAS watch dir for testing.

**Step 3: Shellcheck**

```bash
shellcheck app-setup/run-app-setup.sh
```

Expected: zero warnings, zero errors.

**Step 4: Commit**

```bash
git add app-setup/run-app-setup.sh
git commit -m "feat(container): register podman-transmission-setup.sh in app orchestrator"
```

---

### Task 8: Update docs and plan.md

**Purpose:** Close the loop on documentation.

**Files:**
- Modify: `plan.md`
- Modify: `docs/container-transmission-proposal.md`

**Step 1: Update plan.md**

Move the container Transmission item from "Next Priorities → Immediate" to a new
"In Progress" section. Add a table row in "Running Services" with status "Deploying (Phase 1)".
Note the rclone watch directory change as a Phase 2 prerequisite.

**Step 2: Update proposal doc**

Mark §5.1 (NAS bind mount), §5.3 (credentials), §5.4 (port forwarding) as resolved.
Update §5.2 (startup ordering) as "handled — machine-start LaunchAgent runs compose up".
Update §5.5 (config migration) with the approach: active torrents manually re-added via web UI.
Update §5.6 (remote access) as resolved (Podman exposes port 9091 to host automatically).

**Step 3: Commit**

```bash
git add plan.md docs/container-transmission-proposal.md
git commit -m "docs: update plan and proposal with Phase 1 implementation status"
```

---

## Phase 1: Server Validation (Operational — on tilsit)

These steps are performed on the server after the repo changes are deployed.
Not repo tasks, but documented here for completeness.

**Before starting Phase 1:**
- Ensure NAS is mounted: `ls ~/.local/mnt/DSMedia/Media/`
- AirDrop the new package to tilsit (run `prep-airdrop.sh` with PIA credentials
  added to 1Password first)

**Phase 1 steps:**

1. Run `podman-transmission-setup.sh` with port temporarily changed to 9092
   in compose.yml before running (or add a `--port` flag in a future iteration)
2. Verify NAS bind mount output from the validation step
3. Confirm `podman logs transmission-vpn` shows VPN connected and Transmission running
4. Check `podman exec transmission-vpn curl -s ifconfig.io` returns a non-local,
   non-US IP (should be PIA Panama exit IP)
5. Test kill switch: `podman exec transmission-vpn kill -9 $(pgrep openvpn)` —
   confirm Transmission traffic stops (verify with `podman exec transmission-vpn curl ifconfig.io`)
6. Verify port forwarding: check Transmission web UI at `http://tilsit.local:9092`
   shows a non-default peer port
7. Run both stacks (native + container) in parallel for several days to build confidence

**Phase 1 success criteria:**
- Container Transmission downloads a test torrent to NAS path correctly
- VPN kill switch stops traffic within 1 second of VPN drop
- PIA port forwarding active and Transmission listening port matches

---

## Phase 2: Cutover (Operational — after Phase 1 validated)

1. Update `rclone-setup.sh` sync target to `~/.local/mnt/DSMedia/Media/Torrents/watch/`
2. Stop native Transmission.app
3. Migrate active torrents: export `.torrent` files, re-add via container web UI
4. Change container port from 9092 to 9091 in compose.yml, restart stack
5. **Reset macOS default handlers** for magnet links and `.torrent` files. The native
   Transmission.app was registered as the system handler; it must be replaced with the
   container web UI URL (`http://tilsit.local:9091`). Use `duti` or
   `LSSetDefaultHandlerForURLScheme` to deregister `org.m0k.transmission` for the
   `magnet` URL scheme, then configure the browser (or a small shim app) to open magnet
   links as `http://tilsit.local:9091/transmission/web/#add?url=<magnet>`. Verify with
   `duti -x magnet` before and after.
6. **Update Caddy reverse proxy** (separate repo — must be complete before declaring job
   done). Add a route so `http://tilsit.local/transmission` (or
   `https://tilsit.vip/transmission`) reverse-proxies to `http://localhost:9091`.
   This decouples the web UI from the raw container port and gives it a stable path.
   Track as a blocking prerequisite: do not declare Phase 2 complete until the Caddy
   config is merged and deployed.
7. Confirm operation for several days

---

## Phase 3: Decommission (Repo changes — after Phase 2 stable)

**In transmission-setup.sh:** Remove or gate behind `--legacy` flag the sections that deploy:
- `com.<hostname>.vpn-monitor` LaunchAgent + `vpn-monitor.sh` script
- `com.<hostname>.pia-proxy-consent` LaunchAgent + `pia-proxy-consent.sh` script
- `com.<hostname>.pia-monitor` LaunchAgent + `pia-split-tunnel-monitor.sh` script
- `com.<hostname>.plex-vpn-bypass` LaunchDaemon + `plex-vpn-bypass.sh` script

**On server:** Unload and remove legacy LaunchAgents/Daemons, remove PIA Desktop.app.

---

## Verification Checklist

Before each commit:
```
□ shellcheck passes with zero warnings/errors on modified scripts
□ Template placeholders follow __UPPER_SNAKE_CASE__ convention
□ New LaunchAgent plists validated with plutil -lint
□ .env file never committed (add to .gitignore if needed)
□ Credentials never hardcoded — always read from keychain
□ Commit message follows conventional format
```

---

*Plan by Claude Sonnet 4.6 — 2026-03-08 (revised for code review findings)*
