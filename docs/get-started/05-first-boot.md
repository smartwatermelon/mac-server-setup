# 5. Run first boot

Goal: copy the package to the Mac mini and run `first-boot.sh` as `admin`, at the Mac mini's own display and keyboard.

## Steps

1. Turn on the Mac mini and complete Apple's Setup Assistant. Create the `admin` account. Do not turn on FileVault: it blocks the operator's automatic login. The [Apple first-boot dialog guide](apple-first-boot-dialogs.md) covers each dialog.
2. On the Mac mini, open AirDrop in Finder (Shift-Command-R) and set "Allow me to be discovered by" to Everyone.
3. On the dev Mac, AirDrop the `~/macmini-setup` folder to the Mac mini. It arrives in `~/Downloads/macmini-setup`.
4. On the Mac mini, open Terminal and go to the package:

    ```bash
    cd ~/Downloads/macmini-setup
    ```

5. Make sure that FileVault is off and the disk is fully decrypted:

    ```bash
    fdesetup status
    ```

    The output must be `FileVault is Off.` If FileVault is on, turn it off in System Settings > Privacy & Security > FileVault. Wait until `fdesetup status` prints `FileVault is Off.`, which can take an hour or more. Do not use the script's own offer to turn off FileVault: it records an error, and it can loop while decryption is still running.

6. Run the script. Do not run it over SSH: it stops unless it runs in a desktop session.

    ```bash
    ./first-boot.sh
    ```

7. Press Enter at "This script will configure your Mac Mini server. Continue?".
8. Enter the `admin` password when the script asks for it. Later `sudo` prompts show a label in brackets, such as `[SSH setup]`. Enter the `admin` password at each one.
9. Answer the Touch ID for `sudo` and Wi-Fi prompts.
10. If the SSH step asks you to give Terminal Full Disk Access, do these steps:
    1. Drag Terminal from the Finder window into the Full Disk Access list in System Settings.
    2. Close every Terminal window.
    3. Open a new Terminal window and run the script again:

        ```bash
        cd ~/Downloads/macmini-setup && ./first-boot.sh
        ```

11. Turn on Screen Sharing when the script opens System Settings. Then sign in to the Apple Account. The script opens a one-time 1Password link to the password.

12. Wait while the script installs the Command Line Tools, Homebrew and the packages. This part takes the longest.
13. At the end, a "Server Setup Complete" dialog opens. Click OK. A new Terminal window opens in `~/app-setup`. Keep it open. You run app setup in it in [tutorial step 6](06-run-app-setup.md), before any restart.

!!! warning
    Do not use `--force` on a first run. It skips the password prompt, and the keychain import needs that password.

For the prompts, options and errors in detail, see [First boot](first-boot.md).

## Check

1. The summary says `Setup completed successfully with no errors or warnings!`, or it lists only warnings that you understand. The summary does not count errors from the setup modules, so also search the full log:

    ```bash
    grep -E '❌|⚠️' ~/.local/state/macmini-setup.log
    ```

    Read each line that it prints. No output means no module reported a problem.
2. The `operator` account exists and logs in automatically:

    ```bash
    dscl . -read /Users/operator UserShell
    defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser
    ```

    The second command prints `operator`.

3. The app setup folder exists:

    ```bash
    ls ~/app-setup/run-app-setup.sh ~/app-setup/config/config.conf
    ```

4. From the dev Mac, SSH works with your key:

    ```bash
    ssh admin@macmini.local true
    ```

Next: [Run app setup](06-run-app-setup.md)
