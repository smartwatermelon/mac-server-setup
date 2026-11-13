# 8. Verify

Goal: confirm that Plex runs as `operator`, reads the NAS share, and plays your first movie.

Do steps 1 to 3 in Terminal or iTerm as `operator` on the Mac mini, or over SSH from the dev Mac with `ssh operator@macmini.local`.

## Steps

1. Confirm that the NAS share is mounted for `operator`. The mount agent retries every two minutes, so wait a few minutes after the restart:

    ```bash
    mount -t nfs
    ```

    The output includes `/Users/operator/.local/mnt/Media`.

2. Confirm that you can see your movie on the share:

    ```bash
    ls /Users/operator/.local/mnt/Media
    ```

3. Confirm that Plex runs as `operator`:

    ```bash
    ps -axo user=,comm= | grep "Plex Media Server"
    ```

    Each line starts with `operator`.

4. On the Mac mini, in the `operator` session, open a browser at `http://localhost:32400/web`.
5. Sign in with your Plex account and give the server a name.
6. Add a Movies library. For its folder, choose the folder that holds your movie, under `/Users/operator/.local/mnt/Media`.
7. Wait for Plex to scan the folder. Your movie appears in the library.
8. Play the movie.

!!! note
    Steps 4 to 8 happen in the Plex web app, not in this project's scripts. The Plex screens can change between Plex versions.

For Plex settings, library paths and troubleshooting, see [Plex setup](../components/plex.md).

## Check

The movie plays. You can also open `http://macmini.local:32400/web` from another computer on your LAN.

You have finished the tutorial. To add more parts, go back to step 8 of [Run app setup](06-run-app-setup.md).

Next: [Stack matrix](../stack-matrix.md)
