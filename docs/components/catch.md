# Catch

Catch is a macOS menu bar app that reads an RSS feed of TV episodes, such as a ShowRSS feed, and hands each new item to a torrent client. [`app-setup/catch-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/catch-setup.sh) installs Catch for the `operator` account, writes its feed, save folder and history cutoff into its preferences, and adds a LaunchAgent that starts it when `operator` logs in. Catch is optional. The rest of the stack works without it.

## Before you start

1. Get the RSS feed URL for your shows, for example from your ShowRSS account page.
2. Set the Catch keys in `config/config.conf` on the dev Mac before you build the package, or in `~/app-setup/config/config.conf` on the server before you run the script:

    | Key | Default | What it does |
    | --- | --- | --- |
    | `CATCH_FEEDS_URL` | (empty) | The feed that Catch reads. When it is empty, Catch installs and starts with no feeds, and you add a feed in the app. |
    | `CATCH_HISTORY_CUTOFF_DAYS` | `7` | Catch does not download feed items older than this number of days. `0` turns the cutoff off, so Catch can download every item in the feed. |
    | `CATCH_USE_MAGNETS` | `true` | Meant to choose between magnet links and `.torrent` files. No script reads this key yet. See [Magnet links and .torrent files](#magnet-links-and-torrent-files). |
    | `DROPBOX_LOCAL_PATH` | (empty) | The folder where Catch saves `.torrent` files. When it is empty, the script uses `/Users/operator/.local/sync/dropbox`. |

3. For magnet links, set up Transmission first. `podman-transmission-setup.sh` installs the macOS magnet link handler that Catch hands magnet links to. See [Transmission first install](transmission-first-install.md).

All keys are listed in [Configuration keys](../reference/config-keys.md).

## Set it up

Run these steps as `admin` on the server.

1. Go to the app setup folder. The script stops if you run it from another folder:

    ```bash
    cd ~/app-setup
    ```

2. Run the Catch script:

    ```bash
    ./run-app-setup.sh --only catch-setup.sh
    ```

    The script does these things:

    1. It installs the `catch` Homebrew cask, unless it is already installed. First boot installs it from `config/casks.txt`, so this step usually finds it.
    2. It creates the save folder for `operator`.
    3. It deletes all of the operator's existing Catch preferences (`defaults delete org.giorgiocalderolla.Catch`). Then it writes the save folder (`savePath`), automatic update checks, and one feed named `ShowRSS` with the `CATCH_FEEDS_URL` address.
    4. When `CATCH_HISTORY_CUTOFF_DAYS` is more than 0, it adds one history entry named `SETUP_CUTOFF`, dated that many days ago. Catch treats items before that date as already downloaded.
    5. It writes the LaunchAgent `/Users/operator/Library/LaunchAgents/com.<hostname>.catch.plist`. The agent runs `/Applications/Catch.app/Contents/MacOS/Catch` at load and does not restart it if it quits.

3. Log in as `operator`, or restart the server so that `operator` logs in automatically. The script does not load the LaunchAgent, so Catch starts at the next operator login.
4. As `operator`, look for the Catch icon in the menu bar. Open its preferences and confirm the feed and the save folder.

!!! warning
    Each run of `catch-setup.sh` deletes the operator's Catch preferences first, including Catch's download history and any feeds that you added in the app. Only the `CATCH_FEEDS_URL` feed and the new cutoff entry come back.

## Magnet links and .torrent files

A feed item can be a magnet link or a link to a `.torrent` file. The repo handles the two cases differently.

- **Magnet links.** `podman-transmission-setup.sh` builds `~/Applications/TransmissionMagnetHandler.app` for `operator` and registers it as the handler for `magnet:` links. When Catch opens a magnet link, macOS passes it to that app. The app runs `~/.local/bin/transmission-add-magnet.sh`, which sends the link to Transmission through its RPC address, `http://localhost:9091/transmission/rpc` (the port is `TRANSMISSION_HOST_PORT`, 9091 by default). The script shows a macOS notification for success or failure.
- **.torrent files.** Catch saves the file to its save folder, which is `DROPBOX_LOCAL_PATH`. Transmission reads new torrents from `/Users/operator/containers/transmission/watch`. No script in the repo moves files from the save folder to the watch folder, so a saved `.torrent` file does not reach Transmission by itself.

`catch-setup.sh` does not set the Catch preference that controls what Catch does with magnet links, and no script reads `CATCH_USE_MAGNETS`. Check that preference in the Catch app.

## Check

Run these checks as `admin`.

1. The feed and the save folder are in the operator's Catch preferences:

    ```bash
    sudo -iu operator defaults read org.giorgiocalderolla.Catch feeds
    sudo -iu operator defaults read org.giorgiocalderolla.Catch savePath
    ```

    The first command prints your feed URL. The second prints the save folder.

2. The LaunchAgent exists and passes the plist check:

    ```bash
    sudo plutil -lint /Users/operator/Library/LaunchAgents/com.macmini.catch.plist
    ```

    The output ends with `OK`. Replace `macmini` with your server name in lower case.

3. After `operator` logs in, Catch is running:

    ```bash
    pgrep -lx Catch
    ```

    The output shows a process named `Catch`.

4. The setup log has no errors. The log is `~/.local/state/macmini-apps.log`. Lines from this script start with `[Catch Setup]`.

## Related

- [Transmission first install](transmission-first-install.md): the container and the magnet link handler.
- [rclone setup](../apps/rclone-setup-README.md): the Dropbox sync that uses the same local folder.
- [Configuration keys](../reference/config-keys.md)
- [LaunchAgents](../reference/launchagents.md)
- [Logs](../reference/logs.md)
- [Stack matrix](../stack-matrix.md)
