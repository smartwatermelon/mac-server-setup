# FileBot license

FileBot renames finished downloads and moves them into the Plex library. The automated pipeline needs a paid FileBot license, because the trial does not work for automation. You put the license file on the dev Mac, `prep-airdrop.sh` copies it into the setup package, and [`app-setup/filebot-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/filebot-setup.sh) activates it for the `operator` account on the server.

## Before you start

1. Buy a FileBot license at [filebot.net](https://www.filebot.net/). FileBot gives you the license as a file. The setup script looks for license files that end in `.psm`.
2. Save the license file on the dev Mac, outside the repo checkout. Do not commit it.
3. In `config/config.conf` on the dev Mac, set `FILEBOT_LICENSE_FILE` to the absolute path of that file:

    ```bash
    FILEBOT_LICENSE_FILE="/Users/you/Documents/FileBot_License.psm"
    ```

    The path is on the dev Mac, the machine where you run `prep-airdrop.sh`. See [Configuration keys](../reference/config-keys.md#filebot-license-file-optional).

## Set it up

1. On the dev Mac, as your own user, build the package from the repo folder:

    ```bash
    ./prep-airdrop.sh
    ```

    When `FILEBOT_LICENSE_FILE` is set and the file exists, [`prep-airdrop.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/prep-airdrop.sh) copies it to `app-setup/config/<file name>` in the package, sets its mode to 600, and adds it to the package manifest as an optional file. The output shows `FileBot license file copied to app-setup/config/<file name>`. When the file does not exist, the script warns and goes on without it.

2. Copy the package to the server and run first boot, as in [Get started](../get-started/index.md). First boot puts the package's `app-setup` folder at `~/app-setup` for `admin`.
3. On the server, as `admin`, run the FileBot script:

    ```bash
    cd ~/app-setup
    ./run-app-setup.sh --only filebot-setup.sh
    ```

    The script finds the license file in this order:

    1. The path given with `--license-file PATH`, if you run `filebot-setup.sh` directly with that option.
    2. The `FILEBOT_LICENSE_FILE` path. On the server, the dev Mac path usually does not exist.
    3. A file with the same name in `~/app-setup/config/`. This is where the package puts it.
    4. When `FILEBOT_LICENSE_FILE` is empty, the first `*.psm` file in `~/app-setup/config/`.

    Then the script does these things:

    1. It creates `/Users/operator/.config/filebot/` and copies the license file there, owned by `operator`.
    2. It runs `filebot --license <file>` as `operator` to activate the license.

4. Enter the `admin` password when the script asks for it. Each `sudo` step shows a `[FileBot setup]` prompt.

To activate a license on a server that is already set up, copy the license file to the server and run the script with the path:

```bash
cd ~/app-setup
./filebot-setup.sh --license-file /Users/admin/Downloads/FileBot_License.psm
```

!!! note
    When the script finds no license file, it warns `No FileBot license file found - FileBot will run in evaluation mode` and goes on. The download pipeline then fails at the FileBot step. `transmission-done.sh` logs a `LICENSE: FileBot license issue detected` line when FileBot output mentions a license, trial or activation problem.

## Check

1. The setup output shows `FileBot license applied successfully`, and the summary says `Licensed version - full functionality available`.
2. The license file is in the operator's FileBot folder:

    ```bash
    sudo ls -l /Users/operator/.config/filebot/
    ```

3. FileBot reports the license for `operator`. FileBot's built-in `sysinfo` script prints a `License` line:

    ```bash
    sudo -iu operator filebot -script fn:sysinfo
    ```

4. After a download finishes, the processing log has no `LICENSE` line:

    ```bash
    sudo grep LICENSE /Users/operator/.local/state/transmission-processing.log
    ```

    No output means that no license problem was logged.

## Related

- [Transmission and FileBot](transmission-filebot.md): the processing pipeline that uses FileBot.
- [Build the package](../get-started/04-build-package.md)
- [Configuration keys](../reference/config-keys.md)
- [Logs](../reference/logs.md)
- [Scripts](../reference/scripts.md)
