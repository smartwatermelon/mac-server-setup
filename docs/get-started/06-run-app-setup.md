# 6. Run app setup

Goal: right after first boot, set up Plex as `admin` with `run-app-setup.sh`, then add the optional apps that you chose in step 1.

Run app setup as `admin`, not as `operator`, and before the restart in step 7. The scripts and their config are in the `admin` home folder, in `~/app-setup`. The scripts use `sudo -u operator` to put files in the operator account. Plex and the NAS mount start when `operator` logs in, in step 7.

## Steps

1. Use the Terminal window that first boot opened after you clicked OK. If you closed it, open Terminal as `admin`.
2. Go to the app setup folder. The script stops if you run it from another folder:

    ```bash
    cd ~/app-setup
    ```

3. Set up Plex. Run only the Plex script:

    ```bash
    ./run-app-setup.sh --only plex-setup.sh
    ```

4. At "Do you want to migrate from an existing Plex server?", press Enter for a fresh install.
5. At "Proceed with app setup?", press Enter.
6. Enter the `admin` password when the script asks for it. The script uses it for the keychain and passes it to `plex-setup.sh`.
7. Wait for `All app setup scripts completed successfully`. The script mounts the NAS share for `admin`, and sets up the NAS mount and Plex to start when `operator` logs in. It does not start Plex now.
8. Optional: add the other parts that you chose in step 1. Run one script at a time, in this order. Skip the scripts for parts that you do not want:

    ```bash
    ./run-app-setup.sh --only rclone-setup.sh
    ./run-app-setup.sh --only podman-transmission-setup.sh
    ./run-app-setup.sh --only filebot-setup.sh
    ./run-app-setup.sh --only catch-setup.sh
    ./run-app-setup.sh --only caddy-setup.sh
    ./run-app-setup.sh --only cloudflare-ddns-setup.sh
    ```

    Before you run a script, read its row in the [stack matrix](../stack-matrix.md). Most of these scripts stop with an error when their config keys or credentials are missing.

!!! warning
    A plain `./run-app-setup.sh` runs every `*-setup.sh` script in the folder and stops at the first error. The first script is `rclone-setup.sh`, which stops when Dropbox is not configured. To run everything and skip past the failures, use `./run-app-setup.sh --continue-on-error`.

!!! note
    `run-app-setup.sh` adds `sudo` only for `caddy-setup.sh` and `cloudflare-ddns-setup.sh`. The scripts that are not in step 3 or step 8 run after the others, without `sudo`. Some of them, such as `cloudflared-setup.sh` and `tvmaze-scrobble-setup.sh`, must run as root. Run those by hand with `sudo`, as their pages describe: [Cloudflare Tunnel](../components/cloudflare-tunnel.md), [TVmaze scrobble](../components/tvmaze-scrobble.md) and [Monitoring](../components/monitoring.md). Some of them also need `operator` to be logged in, so run them after step 7.

For Plex options, see [Plex setup](../components/plex.md). For the download pipeline, see [Transmission and FileBot](../components/transmission-filebot.md) and [PIA VPN](../components/pia-vpn.md).

## Check

1. Each run ended with `✅ All app setup scripts completed successfully` in the terminal. That line is not written to the log. Right after a run, this command prints `0`:

    ```bash
    echo $?
    ```

    A failed run stops before it writes its `Failed:` count, so do not check the log for `Failed: 0`. The log is `~/.local/state/macmini-app-setup.log`.

2. The NAS share is mounted for `admin`:

    ```bash
    mount -t nfs
    ```

    The output includes `/Users/admin/.local/mnt/Media`.

3. The operator's Plex and mount LaunchAgents exist:

    ```bash
    sudo ls /Users/operator/Library/LaunchAgents/
    ```

    The output includes `com.macmini.plexmediaserver.plist` and `com.macmini.mount-nas-media.plist`.

Next: [Log in as operator](07-operator-login.md)
