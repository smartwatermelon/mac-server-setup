# Media pipeline problems

This page covers what happens after a download finishes: the trigger watcher, `transmission-done` and FileBot, triage, the hourly `pending-move/` cleanup, and Catch. Run the checks as `admin` on the server.

For how the pipeline works, see [Transmission and FileBot](../apps/transmission-filebot-README.md). In short, a finished download moves like this:

1. Inside the container, `transmission-post-done.sh` writes a trigger file named after the torrent hash to `~operator/containers/transmission/config/triggers/`.
2. The `com.<hostname>.transmission-trigger-watcher` LaunchAgent looks in that folder every 60 seconds. For each trigger it maps the container path `/data` to `/Users/operator/.local/mnt/<share>` and runs `~operator/.local/bin/transmission-done`.
3. `transmission-done` runs FileBot, moves the files into the library, and asks Plex to scan. If FileBot cannot place a download, `transmission-done` moves it to `Media/Torrents/triage/`.
4. On success, the watcher removes the torrent from Transmission but keeps its files. The hourly `pending-move-cleanup` removes the files later, after VirtioFS has released them.

## A finished download is not processed

**Cause**

1. The trigger watcher is not running.
2. The NAS is not mounted on the host, so the mapped path does not exist. The watcher logs a warning and tries again on the next poll.
3. `transmission-done` failed 5 times. The watcher renamed the trigger to `<hash>.dead` and stopped trying.

**Check**

```bash
sudo launchctl print gui/$(id -u operator)/com.<hostname>.transmission-trigger-watcher | grep -E 'state|last exit'
sudo ls -la /Users/operator/containers/transmission/config/triggers/
sudo tail -40 /Users/operator/.local/state/<hostname>-transmission-trigger-watcher.log
```

- A file named only with a hash is waiting. A `<hash>.retry.<n>` file counts failed attempts. A `<hash>.dead` file was given up.
- `macOS path does not exist` in the watcher log means the NAS is not mounted.
- `Done script failed for:` lines name the download. The reason is in `~/.local/state/transmission-processing.log` of the `operator` account.

**Fix**

1. If the watcher is not running, restart it:

    ```bash
    sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.transmission-trigger-watcher
    ```

2. If the NAS is not mounted, fix the mount. See [Plex libraries are empty or files show as unavailable](plex.md#plex-libraries-are-empty-or-files-show-as-unavailable).
3. Fix the cause in `transmission-processing.log`. Then rename the dead trigger back to its hash, and the watcher picks it up within 60 seconds:

    ```bash
    sudo mv /Users/operator/containers/transmission/config/triggers/<hash>.dead \
      /Users/operator/containers/transmission/config/triggers/<hash>
    ```

## A download went to triage instead of the library

**Cause**

`transmission-done` moves a download to a folder under `Media/Torrents/triage/` when it cannot place it:

- `already-in-plex/`: FileBot matched it, but the library already has that file. Media-compare has handled it, and no email is sent.
- `no-match/`: FileBot could not identify it, or the year guard refused a movie match because the year in the release name is not the year of the match.
- `failed/`: another error, for example a network, license or permission problem.

**Check**

```bash
sudo -iu operator ls "/Users/operator/.local/mnt/<share>/Media/Torrents/triage/no-match" \
  "/Users/operator/.local/mnt/<share>/Media/Torrents/triage/failed"
sudo grep -E 'YEAR MISMATCH|LICENSE|triage|Error' /Users/operator/.local/state/transmission-processing.log | tail -30
```

`YEAR MISMATCH:` lines show a refused movie match. `LICENSE` lines show a FileBot license problem. The lines before each `triage` line show FileBot's output for that download.

**Fix**

1. For a year mismatch where the match was correct, rename the file or folder so that its year matches the database, then process it by hand.
2. For a name that FileBot cannot read, rename it to a clear `Title (Year)` or `Show S01E01` form, then process it by hand.
3. To process a folder by hand, run `transmission-done` with no `TR_TORRENT_*` variables in Terminal in the `operator` desktop session. It starts in manual mode and asks for the folder:

    ```bash
    ~/.local/bin/transmission-done
    ```

4. For `failed/`, fix the cause first. See the license and permission sections below.

## No email arrives for a download that could not be processed

**Cause**

`transmission-done` emails `alerts.email` from its `config.yml` for each download that it moves to `no-match/` or `failed/`. If the key is missing, or the alert library is missing, it triages the download and logs that it sent no email. A `config.yml` written before this feature has no `alerts.email` until setup runs again.

**Check**

```bash
sudo -iu operator yq eval '.alerts.email' /Users/operator/.config/transmission-done/config.yml
sudo grep 'No alerts.email in config' /Users/operator/.local/state/transmission-processing.log | tail -5
```

`null` means the key is missing.

**Fix**

1. Run `transmission-filebot-setup.sh` again. It writes `alerts.email` from `MONITORING_EMAIL`.
2. Or add the key by hand to `/Users/operator/.config/transmission-done/config.yml`:

    ```yaml
    alerts:
      email: you@example.com
    ```

3. If email still does not arrive, check msmtp. See [Monitoring](monitoring.md#no-alert-email-arrives).

## FileBot reports a license problem

**Cause**

FileBot needs a license for automated use. The license file was not installed, or it expired.

**Check**

```bash
sudo -iu operator filebot --license
sudo grep -A4 'LICENSE' /Users/operator/.local/state/transmission-processing.log | tail -10
```

**Fix**

1. Install the license file for `operator`. `prep-airdrop.sh` adds it to the package when `FILEBOT_LICENSE_FILE` is set, and `filebot-setup.sh` installs it.
2. Run `filebot-setup.sh --license-file <path>` again with the license file.
3. Process the downloads in `triage/failed/` by hand.

## FileBot fails with Access Denied or I/O errors on the NAS

**Cause**

The NAS refuses the write. NFS checks permissions on the NAS, not on the Mac. The NFS export must map all users to the NAS admin user, and the media folders must be writable by that user. A `[MOVE] ... failed due to I/O error` line or an `Access Denied` line with a permission string points here.

**Check**

```bash
sudo grep -E 'Access Denied|I/O error|Permission denied' /Users/operator/.local/state/transmission-processing.log | tail -10
```

**Fix**

1. Check the NFS rule of the shared folder on the NAS: read and write, map all users to admin, non-privileged ports allowed, subfolder access allowed.
2. Fix folder permissions on the NAS itself, over SSH to the NAS. A `chmod` from the Mac does not work on this mount.
3. See [NAS storage configuration](../apps/transmission-filebot-README.md#nas-storage-configuration).

## transmission-done has been running for over 45 minutes

**Cause**

Normal runs take seconds to a few minutes. A long run usually waits for a macOS privacy prompt "bash would like to access files on a network volume". macOS holds the first non-Apple binary in the chain responsible for FileBot's reads. The watcher puts the stably-signed bash at `/usr/local/stable/bash/bin` first so that the grant survives `brew upgrade`. `stall-watchdog` emails `transmission-done has been running for over 45 minutes`.

**Check**

```bash
ps -axo pid=,etime=,command= | grep '[t]ransmission-done'
/usr/local/bin/<hostname>-stable-sign.sh --check
```

The second column is the elapsed time. `--check` exits 1 if the stable bash copy is stale.

**Fix**

1. Look at the desktop for a privacy prompt, and click Allow.
2. Do not kill `transmission-done`. Stopping FileBot during a move can lose the file.
3. If the stable copy is stale, run `/usr/local/bin/<hostname>-stable-sign.sh`.

See [Stable signing](../apps/stable-signing-README.md).

## A download was deleted from pending-move before it was processed

**Cause**

`pending-move-cleanup.sh` runs every hour. It removes entries in `pending-move/` whose names Transmission no longer lists. An earlier version compared names without removing the `.part` suffix that single-file downloads have while they are written, so it could delete a download in progress. The current template removes the suffix before it compares, but the deployed copy at `~operator/.local/bin/pending-move-cleanup.sh` changes only when you deploy again.

**Check**

```bash
sudo tail -30 /Users/operator/.local/state/<hostname>-pending-move-cleanup.log
sudo grep -c '%.part' /Users/operator/.local/bin/pending-move-cleanup.sh
```

`Removing orphaned entry:` lines name what the script removed. `Left in place:` lines name entries that it kept because only `.nfs.*` files remain. A count of `0` from the second command means the deployed script is older than the fix.

**Fix**

1. Run `podman-transmission-setup.sh` again to deploy the current cleanup script.
2. A file that was deleted while a process still had it open may survive as a hidden `.nfs.*` file in `pending-move/`. The NFS client keeps a deleted, open file under that name. This recovery is not automated, and it works only while the file is still open. Compare its size with the torrent's size before you use it.
3. If the sizes match, move it back to the torrent's real name in `pending-move/`, and rename the torrent's `.dead` trigger back to its hash, as in [A finished download is not processed](#a-finished-download-is-not-processed).

## Old folders build up in pending-move

**Cause**

The cleanup skips a cycle when it cannot reach the Transmission RPC. It also keeps folders that Transmission still lists, and folders that hold only `.nfs.*` files.

**Check**

```bash
sudo launchctl print gui/$(id -u operator)/com.<hostname>.pending-move-cleanup | grep -E 'state|last exit|run interval'
sudo grep -E 'Cleanup complete|Cannot reach' /Users/operator/.local/state/<hostname>-pending-move-cleanup.log | tail -5
```

`Cleanup complete:` gives the counts of removed, tracked, held and failed entries. `Cannot reach Transmission RPC` means Transmission was down. See [Transmission web UI does not load](transmission-vpn.md#transmission-web-ui-does-not-load).

**Fix**

1. Make sure that Transmission answers.
2. Folders that hold only `.nfs.*` files clear after VirtioFS releases the files, which can take hours. The cleanup removes them on a later run.

## Catch finds new episodes but Transmission does not add them

**Cause**

1. Catch is not running. Its LaunchAgent starts it at login and does not restart it.
2. Catch has no feed. `catch-setup.sh` adds a feed only when `CATCH_FEEDS_URL` is set.
3. A magnet link reached `TransmissionMagnetHandler.app`, but the Transmission RPC did not answer. The handler shows the notification `Could not connect to Transmission`.

**Check**

```bash
pgrep -fl Catch.app
sudo launchctl print gui/$(id -u operator)/com.<hostname>.catch | grep -E 'state|last exit'
sudo -iu operator defaults read org.giorgiocalderolla.Catch feeds
```

No process means Catch is not running. An empty feed list means no feed is set.

**Fix**

1. Start Catch by hand in the `operator` session, or restart its agent:

    ```bash
    sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.catch
    ```

2. Set `CATCH_FEEDS_URL` in `config.conf` and run `catch-setup.sh` again.
3. If the handler cannot reach Transmission, fix Transmission first. See [Transmission web UI does not load](transmission-vpn.md#transmission-web-ui-does-not-load).
