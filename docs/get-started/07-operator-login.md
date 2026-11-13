# 7. Log in as operator

Goal: restart the Mac mini, let `operator` log in automatically, and let Plex, the NAS mount and the one-time first-login script start.

At login, the operator's LaunchAgents from step 6 start Plex and mount the NAS share. The first-login script runs once. It sets up the operator's Dock, Terminal and iTerm2 preferences, and the `logrotate` service. It does not install or configure any apps.

## Steps

1. In the `admin` Terminal, restart the Mac mini:

    ```bash
    sudo shutdown -r now
    ```

2. Wait. The Mac mini logs in as `operator` without a password prompt.
3. Answer Apple's first-login dialogs for `operator`. The [operator account first login](apple-first-boot-dialogs.md#operator-account-first-login) section covers each one.
4. Wait for the first-login script to finish. It can show a progress window. It removes Mail, Messages and other apps from the Dock, and adds iTerm, Plex Media Server and Passwords.
5. Do not worry if the Dock has no media folder. The script adds the `Media` folder inside the NAS share only if the share is already mounted when the script reaches that step. It does not wait for the mount.

!!! note
    The first-login script runs once. At the end it moves its LaunchAgent to `~/.config/operator/`. To run it again, run `~/.local/bin/operator-first-login.sh` as `operator`.

## About the operator account

- The operator password is in 1Password, in the item that `ONEPASSWORD_OPERATOR_ITEM` names.
- `first-boot.sh` adds `operator` to the `admin` group, so `sudo` works with the operator password. Touch ID does not work for `operator`, because macOS does not allow Touch ID with automatic login. See [Setup problems](../troubleshooting/setup.md).
- `admin` and `operator` accept the same SSH key: the dev Mac's `~/.ssh/id_ed25519.pub`.
- The menu bar shows the Fast User Switching menu, with the name of the current user. Use it, or `ssh admin@macmini.local` from the dev Mac, to work as `admin`. Run app setup and `brew` commands as `admin`, because `admin` owns Homebrew.

## Check

Run check 1 on the dev Mac. Run the other checks as `operator`, in Terminal on the Mac mini or over SSH.

1. From the dev Mac, SSH to the operator account works with your key:

    ```bash
    ssh operator@macmini.local true
    ```

2. The first-login log ends with the completion line:

    ```bash
    tail -n 3 ~/.local/state/macmini-operator-login.log
    ```

    The output includes `=== Operator First-Login Setup Completed ===`.

3. The first-login LaunchAgent moved out of `~/Library/LaunchAgents`:

    ```bash
    ls ~/.config/operator/
    ```

    The output includes `com.macmini.operator-first-login.plist`.

4. Plex runs as `operator`:

    ```bash
    ps -axo user=,comm= | grep "Plex Media Server"
    ```

    Each line starts with `operator`.

Next: [Verify](08-verify.md)
