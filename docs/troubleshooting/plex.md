# Plex problems

This page covers Plex Media Server, the NAS mount that Plex reads, the Plex watchdog, and the Plex to TVmaze sync. Run the checks as `admin` on the server unless a step says otherwise.

For how these parts work, see [Plex setup](../components/plex.md), [Plex watchdog](../components/plex-watchdog.md) and [TVmaze scrobble](../components/tvmaze-scrobble.md).

## Plex does not answer on port 32400

**Cause**

1. The `operator` account is not logged in. Plex and the NAS mount start from `operator` LaunchAgents, which start only in a desktop session of that account.
2. Plex is running but hung. On one server the Plex database deadlocked after its weekly database optimization, and Plex stopped answering every request.
3. The Plex watchdog restarted Plex once, Plex stopped answering again within an hour, and the watchdog stopped trying.

**Check**

```bash
pgrep -fl 'Plex Media Server'
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 http://localhost:32400/identity
sudo launchctl print gui/$(id -u operator)/com.<hostname>.plexmediaserver | grep -E 'state|last exit'
```

- No process from `pgrep` and `000` from `curl` means Plex is not running.
- A process from `pgrep` and `000` or `503` from `curl` means Plex is running but does not answer.
- `200` means Plex answers. Look at the client or the network instead.
- An error from `launchctl print` means the agent is not loaded, usually because `operator` is not logged in.

Then read what the watchdog did, and look for the deadlock signature in the Plex log:

```bash
sudo grep -iE 'restart|unreachable' /Users/operator/.local/state/plex-watchdog.log | tail -20
sudo grep -c 'threads are waiting on db connections' \
  "/Users/operator/Library/Logs/Plex Media Server/Plex Media Server.log"
```

`not restarting again` means the watchdog gave up and waits for you. `Not restarting Plex: an update may be running` means it waits for an update. `Automatic restart is off` means the file `~/.config/plex-watchdog/no-restart` exists in the `operator` account. A count above zero from the second command points to a database deadlock.

**Fix**

1. If `operator` is not logged in, restart the Mac mini. `operator` logs in automatically.
2. If Plex is hung, wait for the watchdog. It restarts Plex after 3 failed polls (about 15 minutes), unless a Plex update or a `brew upgrade` is in progress.
3. To restart Plex by hand, open Terminal in the `operator` desktop session (at the Mac mini or through Screen Sharing). Plex ignores SIGTERM, so stop it and its helpers with SIGKILL, then start it with `open`, as the watchdog does:

    ```bash
    pkill -KILL -f 'MacOS/Plex Media Server$'
    pkill -KILL -f 'Plex Media Server\.app/Contents/|Plex EAE Service'
    env -u PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR open -a "/Applications/Plex Media Server.app"
    ```

4. Confirm that Plex opened its real database, not an empty one:

    ```bash
    lsof -p "$(pgrep -f 'MacOS/Plex Media Server$')" | grep library.db
    ```

    The path must be under `/Users/operator/Library/Application Support/Plex Media Server`.

5. When Plex answers again, the watchdog clears its "gave up" state on its next poll.

## Plex shows an empty, unclaimed server

**Cause**

The Plex LaunchAgent starts Plex with `PLEX_MEDIA_SERVER_APPLICATION_SUPPORT_DIR=/Users/Shared/PlexMediaServer`. The real Plex data is in `~/Library/Application Support/Plex Media Server` of the `operator` account. The link `/Users/Shared/PlexMediaServer/Plex Media Server` must point at the real data. If the link is missing or is a real folder, a Plex that the LaunchAgent starts creates a new, empty server there. The nightly database backups can also go to the wrong place.

**Check**

```bash
ls -ld "/Users/Shared/PlexMediaServer/Plex Media Server"
lsof -p "$(pgrep -f 'MacOS/Plex Media Server$')" | grep library.db
sudo grep -E 'data link|REPAIRED' /Users/operator/.local/state/plex-watchdog.log | tail -5
```

The first line must start with `l` and end with `-> /Users/operator/Library/Application Support/Plex Media Server`. A line that starts with `d` means a real folder is in the way. The `lsof` line shows which database the running Plex uses.

**Fix**

1. If the link points at the wrong place or is missing, wait up to 5 minutes. The watchdog repairs it and logs `REPAIRED`.
2. If it is a real folder, the watchdog does not touch it. Move it aside:

    ```bash
    sudo mv "/Users/Shared/PlexMediaServer/Plex Media Server" \
      "/Users/Shared/PlexMediaServer/Plex Media Server.stray"
    ```

3. Wait for the next watchdog run to create the link.
4. If the running Plex uses the empty database, restart Plex as in [Plex does not answer on port 32400](#plex-does-not-answer-on-port-32400), and check the `lsof` line again.

## Plex libraries are empty or files show as unavailable

**Cause**

1. The NAS share is not mounted in the `operator` account. The mount agent retries every 2 minutes, but it cannot mount while the NAS is unreachable.
2. A macOS privacy prompt about network volume access is open on the desktop, and Plex waits for it.
3. The NAS export does not allow the server, or it does not allow non-privileged ports.

The Plex watchdog checks this with a real file read. After 2 failed checks it sends the email `Plex cannot read media files`.

**Check**

```bash
mount -t nfs
sudo -iu operator ls /Users/operator/.local/mnt/<share>
sudo launchctl print gui/$(id -u operator)/com.<hostname>.mount-nas-media | grep -E 'state|last exit'
sudo tail -20 /Users/operator/.local/state/<hostname>-mount.log
```

- `mount -t nfs` must list `/Users/operator/.local/mnt/<share>`.
- `NFS mount failed` or `Failed to establish network connectivity` in the mount log means the NAS did not answer or refused the mount.
- If the mount is listed but `ls` hangs or fails with `Operation not permitted`, look at the desktop for a privacy prompt. See [A privacy prompt blocks the server](monitoring.md#a-privacy-prompt-blocks-the-server).

**Fix**

1. Make sure that the NAS is on and reachable: `ping -c 3 <NAS hostname>`.
2. Run the mount agent now instead of waiting for its next run:

    ```bash
    sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.mount-nas-media
    ```

    The script returns at once when the share is already mounted. It does not unmount a working mount.

3. If the mount still fails, check the NFS export on the NAS. It must allow the server's address, read and write access, and non-privileged ports. See [NAS storage configuration](../components/transmission-filebot.md#nas-storage-configuration).
4. If a privacy prompt is open, click Allow.

Do not unmount the share on the host to "refresh" it. Plex reads from it, and the Transmission container sees it through VirtioFS.

## The Plex watchdog reports settings drift

**Cause**

A Plex setting changed from the value in the golden config. Someone changed it in the Plex web app, or a Plex update changed it.

**Check**

```bash
sudo -iu operator plex-watchdog-ctl status
sudo grep 'DRIFT DETECTED' /Users/operator/.local/state/plex-watchdog.log | tail -10
```

`status` shows the golden and current value of each monitored setting.

**Fix**

1. To keep the new value, run `sudo -iu operator plex-watchdog-ctl accept`.
2. To put the golden value back into Plex, run `sudo -iu operator plex-watchdog-ctl revert`.
3. If a fresh setup reports drift, run `sudo -iu operator plex-watchdog-ctl refresh` to read all settings again.

## The Plex watchdog does not run

**Cause**

The watchdog is an `operator` LaunchAgent. It runs only while `operator` is logged in, and only if its plist is loaded.

**Check**

```bash
sudo launchctl print gui/$(id -u operator)/com.<hostname>.plex-watchdog | grep -E 'state|last exit|run interval'
sudo tail -5 /Users/operator/.local/state/plex-watchdog.log
```

`state = not running` between runs is normal: the job runs every 300 seconds and exits. An error from `launchctl print` means the job is not loaded. The log has an `OK:` heartbeat line about once an hour when nothing is wrong.

**Fix**

1. If the job is not loaded, load it:

    ```bash
    sudo launchctl bootstrap gui/$(id -u operator) \
      /Users/operator/Library/LaunchAgents/com.<hostname>.plex-watchdog.plist
    ```

2. To run it now, run `sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.plex-watchdog`. A run can send email and can restart a Plex that does not answer.
3. If the log says `alert library not found` or `token file not found`, run `plex-watchdog-setup.sh` again.

## The watchdog says Plex answers /identity but the prefs request fails

**Cause**

The Plex token in `~/.config/plex-watchdog/token` of the `operator` account was revoked or changed. `/identity` needs no token, so Plex looks alive, but every authenticated request fails. The watchdog does not restart Plex in this case.

**Check**

```bash
sudo -iu operator bash -c \
  'curl -s -o /dev/null -w "%{http_code}\n" -H "X-Plex-Token: $(cat ~/.config/plex-watchdog/token)" http://localhost:32400/:/prefs'
```

`200` means the token works. `401` means the token must be replaced.

**Fix**

1. Put a valid token in `plex.token` of `/Users/operator/.config/transmission-done/config.yml`. `plex-watchdog-setup.sh` reads the token from that file.
2. Run `plex-watchdog-setup.sh` again. It checks the token and writes the token file at mode 600.

## Plex waits for an administrator password during an update

**Cause**

The Plex app in `/Applications` is owned by `root`. The Plex updater cannot write it, so it opens a password dialog on the desktop and waits. `plex-setup.sh` gives `operator` ownership of the app so that updates install without a dialog. The daily `brew upgrade` job skips the Plex cask for the same reason.

**Check**

```bash
stat -f '%Su:%Sg' "/Applications/Plex Media Server.app"
sudo -iu operator defaults read com.plexapp.plexmediaserver ButlerTaskUpdateServer
```

The owner must be `operator:staff`, and the setting must be `always`.

**Fix**

1. Answer the dialog on the desktop, if one is open.
2. Run `plex-setup.sh` again, or give `operator` ownership of the app:

    ```bash
    sudo chown -R operator:staff "/Applications/Plex Media Server.app"
    ```

    A change of owner changes the time stamp of the Plex binary. The watchdog then waits 30 minutes before it restarts Plex.

## Watched episodes do not appear on TVmaze

**Cause**

1. The Plex webhook is not set, or it points at the wrong address.
2. The listener is not running.
3. The worker cannot match the show, or TVmaze refused the request.

**Check**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:32599/
sudo grep -E 'webhook:|SYNCED|FAILED|ERROR' /Users/operator/.local/state/tvmaze-scrobble.log | tail -20
```

`200` means the listener answers. No `webhook:` lines after a play means Plex did not send the webhook. `FAILED:` and `ERROR:` lines give the reason for each episode.

**Fix**

1. In the Plex web app, signed in as the server owner, open Settings, then Webhooks. Add `http://127.0.0.1:32599/plex`.
2. If the listener does not answer, restart it:

    ```bash
    sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.tvmaze-scrobble
    ```

3. To sync plays that the webhook missed, run the reconcile job now:

    ```bash
    sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.tvmaze-reconcile
    ```

4. For `ERROR` lines about credentials or the Plex token, run `tvmaze-scrobble-setup.sh` or `plex-watchdog-setup.sh` again, as the line says.
