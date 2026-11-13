# Transmission first install

Transmission runs in a container behind a PIA VPN tunnel. [`app-setup/podman-transmission-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/podman-transmission-setup.sh) creates a Podman virtual machine named `transmission-vm` for the `operator` account, starts the `transmission-vpn` container from the `haugene/transmission-openvpn` image, and adds the LaunchAgents that keep both running. All container traffic goes through the OpenVPN tunnel to PIA. This page covers the first install. For credentials, port forwarding and regions after that, see [PIA VPN](../apps/pia-vpn-README.md).

## Before you start

1. **A PIA account in 1Password.** Make a 1Password item with `username` and `password` fields for your PIA account. Set `ONEPASSWORD_PIA_ITEM` to the item name before you run `prep-airdrop.sh`. The script reads `op://<vault>/<item>/username` and `op://<vault>/<item>/password` and stores them as one `username:password` entry, with the service name `pia-account-<hostname>`, in the package keychain. First boot imports that keychain. The setup script reads the entry from the `admin` keychain and stops with an error when it is missing.
2. **The config keys.** Set these in `config/config.conf`. See [Configuration keys](../reference/config-keys.md#vpn-and-transmission-configuration-optional).

    | Key | Default | What it does |
    | --- | --- | --- |
    | `ONEPASSWORD_PIA_ITEM` | (empty) | The 1Password item that holds the PIA credentials. |
    | `PIA_VPN_REGION` | `ca_vancouver` | The PIA region. Use the file name stem from the image's `/etc/openvpn/pia/` folder, not the PIA API region id. The region must serve port forwarding. |
    | `LAN_SUBNET` | `192.168.1.0/24` | Your LAN, in CIDR form, for example `192.168.20.0/22`. The container gets it as `LOCAL_NETWORK`. |
    | `TRANSMISSION_HOST_PORT` | `9091` | The host port for the Transmission web UI and RPC. It is bound to `127.0.0.1` only. |
    | `NAS_HOSTNAME`, `NAS_SHARE_NAME` | (none) | Required. The script stops when either one is empty, or has characters other than letters, digits, `.`, `-` and `_`. |
    | `MONITORING_EMAIL` | `your-email@example.com` | Needed for the two watchdogs. See step 4. |

3. **The NAS mount for `operator`.** The container's `/data` folder is `/Users/operator/.local/mnt/<NAS_SHARE_NAME>`, passed through from the host over VirtioFS. `plex-setup.sh` adds the `mount-nas-media` LaunchAgent that mounts it when `operator` logs in. When the share is not mounted, the script skips its mount test with a warning. The supervisor waits up to 120 seconds for the mount at each start.
4. **Alert email, if you want the watchdogs.** Set up [Alert email with msmtp](msmtp-alert-email.md) first. Without `MONITORING_EMAIL` and `/Users/operator/.config/msmtp/config`, the script skips the PIA port watchdog and the stall watchdog.

!!! warning
    The Caddyfile proxies `/transmission/` to `127.0.0.1:9091`, a fixed value. If you change `TRANSMISSION_HOST_PORT`, the web UI through Caddy stops working until you change the Caddyfile too.

## Set it up

1. Optional, but do it before the first container start: set up stable signing. On the server, as `admin` (the script refuses to run as root), run:

    ```bash
    ~/Downloads/macmini-setup/scripts/setup-auto-updates.sh
    ```

    `first-boot.sh` does not run this script. It installs `/usr/local/bin/<hostname>-stable-sign.sh`, creates a local code signing identity, and makes signed copies of Homebrew's `podman`, `coreutils` and `bash` under `/usr/local/stable/`. It also sets up the daily Homebrew upgrade, which signs the copies again after each upgrade. See [Stable signing](../apps/stable-signing-README.md) for why this is needed.

2. As `admin`, go to the app setup folder and run the Transmission script:

    ```bash
    cd ~/app-setup
    ./run-app-setup.sh --only podman-transmission-setup.sh
    ```

3. Enter the `admin` password when `sudo` asks for it.

4. Restart the server, or log out and log in as `operator`, so the LaunchAgents start.
5. Watch the operator desktop. macOS can show a prompt that a program "would like to access files on a network volume". Click Allow. The prompt names the program that macOS holds responsible for the VirtioFS access. With stable signing, it names a path under `/usr/local/stable/`, and the grant then survives Homebrew upgrades. Without stable signing, the prompt can come back after each upgrade, and the supervisor waits until someone answers it.

## What the script creates

The script does these things, in order:

1. It installs Podman with Homebrew if it is missing, and stops when the version is older than 4.7.0.
2. It creates the `transmission-vm` machine as `operator`, rootful, with 2 CPUs, 2 GB of memory and a 20 GB disk, unless it already exists. It makes `transmission-vm` the default connection and starts the machine.
3. It creates `/Users/operator/containers/transmission/` with the `config`, `scripts` and `watch` folders.
4. It reads the PIA entry from the keychain and writes `/Users/operator/containers/transmission/.env`, mode 600. The container gets the credentials from this file through `--env-file`, so they do not show in `ps` output.
5. It copies the container-side scripts to `containers/transmission/scripts/`: `transmission-post-done.sh`, the port forwarding manager `pia-port-guard.sh` with `transmission-post-start.sh`, and the region probe `pia-pf-probe.sh`. The image's own port updater is turned off with `DISABLE_PORT_UPDATER=true`.
6. It writes these scripts to `/Users/operator/.local/bin/`: `transmission-trigger-watcher.sh`, `pending-move-cleanup.sh`, `podman-machine-start.sh` (the supervisor), and, when alert email is set up, `pia-port-watchdog.sh` and `stall-watchdog.sh` with `~/.local/lib/alert-lib.sh`.
7. It writes the operator LaunchAgents. See [LaunchAgents](../reference/launchagents.md).

    | LaunchAgent | What it does |
    | --- | --- |
    | `com.<hostname>.podman-transmission-vm` | Runs the supervisor at login, always kept alive. |
    | `com.<hostname>.transmission-trigger-watcher` | Watches for finished downloads and runs FileBot processing. |
    | `com.<hostname>.pending-move-cleanup` | Runs every hour. |
    | `com.<hostname>.pia-port-watchdog` | Runs every 15 minutes, only with alert email. |
    | `com.<hostname>.stall-watchdog` | Runs every 2 minutes, only with alert email. |

8. When the NAS share is mounted, it runs a test `alpine` container that lists the share through VirtioFS.
9. When there were no errors and `.env` was written, it starts the `transmission-vpn` container with `podman run`.
10. It builds `/Users/operator/Applications/TransmissionMagnetHandler.app` and registers it as the handler for `magnet:` links. See [Catch](catch.md).

The script does not load the LaunchAgents. They start at the next operator login. The supervisor then checks the machine and the container every 300 seconds, and starts or creates them again when they are not running. When the container cannot read `/data` three times in a row, the supervisor restarts the VM. The supervisor never exits, because launchd stops the VM helper about 5 seconds after the agent's script exits.

!!! note
    The log of the setup script says that `curl -s ifconfig.io` "should return Panama PIA exit IP". That text is old. The default region is now `ca_vancouver`, and Panama serves no port forwarding. The exit IP belongs to the region that you set.

## Check

Run these checks as `admin`, after `operator` has logged in.

1. The container is up and healthy:

    ```bash
    sudo -iu operator podman ps --filter name=transmission-vpn
    ```

    The `STATUS` column shows `Up` and, after the 120-second start period, `(healthy)`.

2. Traffic leaves through PIA. This command prints the exit IP address, which must not be your home IP address:

    ```bash
    sudo -iu operator podman exec transmission-vpn curl -s https://ipinfo.io/ip
    ```

3. Port forwarding works. Ask Transmission for its listen port from inside the container:

    ```bash
    sudo -iu operator podman exec transmission-vpn transmission-remote localhost:9091 -si | grep -i 'listen port'
    ```

    A port number other than 0 means port forwarding works. `Listen port: 0` means it failed. See [Diagnosing "torrents won't start"](../apps/pia-vpn-README.md#diagnosing-torrents-wont-start).

4. The PIA credentials were not rejected. A wrong password shows up as `AUTH_FAILED` in the container log, so this command must print nothing. An empty result does not prove the tunnel is up; check 3 does that:

    ```bash
    sudo -iu operator podman logs transmission-vpn 2>&1 | grep -i 'auth_failed'
    ```

5. The supervisor is running its loop. The log shows `entering supervision loop`:

    ```bash
    sudo tail -n 20 /Users/operator/.local/state/macmini-podman-vm-stdout.log
    ```

6. If you set up stable signing, every signed copy is current. The command exits 0:

    ```bash
    /usr/local/bin/macmini-stable-sign.sh --check
    ```

7. The web UI opens at `https://macmini.local/transmission/` from the LAN, once Caddy is set up. Port 9091 answers on `127.0.0.1` only.

Replace `macmini` with your server name in lower case. The setup script's own log is `~/.local/state/macmini-apps.log`. Lines from this script contain `[podman-transmission]`.

## Related

- [PIA VPN](../apps/pia-vpn-README.md): the credential chain, password rotation, port forwarding and region choice.
- [Stable signing](../apps/stable-signing-README.md): the network-volume privacy grant and the `/usr/local/stable` copies.
- [Transmission and FileBot](../apps/transmission-filebot-README.md): what happens after a download finishes.
- [Monitoring](../apps/monitoring-README.md): the PIA port watchdog and the stall watchdog.
- [Alert email with msmtp](msmtp-alert-email.md)
- [Catch](catch.md)
- [Storage and VirtioFS](../explanation/storage-virtiofs.md)
- [Configuration keys](../reference/config-keys.md)
- [LaunchAgents](../reference/launchagents.md)
- [Logs](../reference/logs.md)
- [Ports](../reference/ports.md)
