# Setup problems

This page covers `prep-airdrop.sh` on the dev Mac, `first-boot.sh` on the new server, and `run-app-setup.sh` with the app setup scripts.

The first-boot log is `~/.local/state/<hostname>-setup.log` in the `admin` account. The app setup logs are `~/.local/state/<hostname>-app-setup.log` and `~/.local/state/<hostname>-apps.log`. See [Log files](../reference/logs.md).

## prep-airdrop.sh stops because OP_SERVICE_ACCOUNT_TOKEN is set

**Cause**

`prep-airdrop.sh` needs an interactive 1Password CLI sign-in. A 1Password service account token in the environment limits the CLI to the vaults of that service account, so the script refuses to run.

**Check**

```bash
[[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && echo "set" || echo "not set"
```

`set` means the script stops with `ERROR: OP_SERVICE_ACCOUNT_TOKEN is set`.

**Fix**

1. Run the script in a subshell without the token:

    ```bash
    ( unset OP_SERVICE_ACCOUNT_TOKEN; ./prep-airdrop.sh )
    ```

## prep-airdrop.sh cannot find a 1Password item

**Cause**

1. The 1Password CLI is not signed in.
2. A vault name or an item title in `config/config.conf` does not match 1Password exactly.

**Check**

```bash
op whoami
op item get "<item title>" --vault "<vault name>" --format json >/dev/null && echo "found"
```

An error from `op whoami` means the CLI is not signed in. An error from `op item get` means the title or the vault name is wrong. The names are case sensitive.

**Fix**

1. Run `op signin`.
2. Correct the `ONEPASSWORD_*` values in `config/config.conf` so that they match the vault and item titles exactly.
3. Run `prep-airdrop.sh` again.

For the full list of items, see [Prerequisites](../get-started/02-prerequisites.md) and [Configure](../get-started/03-configure.md).

## first-boot.sh says it requires a GUI session

**Cause**

You started `first-boot.sh` over SSH, or from another non-desktop session. The script creates accounts, changes System Settings and shows dialogs, so it needs the local desktop.

**Check**

```bash
launchctl managername
```

`Aqua` means a desktop session. `Background` or another value means the script stops with `This script requires a GUI session to run properly`.

**Fix**

1. Sign in at the Mac mini itself, or through Screen Sharing.
2. Open Terminal there and run `first-boot.sh` again.

## first-boot.sh stops with SAFETY ABORT

**Cause**

1. The setup folder was not made by `prep-airdrop.sh`, so it has no development machine fingerprint.
2. You ran `first-boot.sh` on the dev Mac. The script compares the hardware UUID with the fingerprint from `prep-airdrop.sh` and stops if they are equal.

**Check**

```bash
system_profiler SPHardwareDataType | grep "Hardware UUID"
```

Compare the output with the `Development fingerprint` line in the error. If they are the same, you are on the dev Mac.

**Fix**

1. On the dev Mac, run `prep-airdrop.sh` again to build a new package.
2. Copy the whole package folder to the new server.
3. Run `first-boot.sh` on the new server.

## first-boot.sh says required files are missing from the deploy package

**Cause**

The package on the server does not match its deploy manifest. A copy was interrupted, or files were removed from the folder after `prep-airdrop.sh` made it.

**Check**

Read the `Required file missing from deploy package:` lines in the terminal or in the first-boot log:

```bash
grep -E "Required file missing|validation failed" ~/.local/state/<hostname>-setup.log
```

Each line names one missing file.

**Fix**

1. On the dev Mac, run `prep-airdrop.sh` again.
2. Copy the complete new package to the server.
3. Run `first-boot.sh` again.

## first-boot.sh reports that FileVault is enabled

**Cause**

FileVault was turned on during macOS setup. FileVault prevents automatic login, and the `operator` account needs automatic login to start its services after a reboot.

**Check**

```bash
fdesetup status
```

`FileVault is On` confirms the cause.

**Fix**

1. At the script's offer to turn FileVault off, press Control-C to stop the script. Do not accept the offer: it records an error even when it works, and it can repeat while the disk is still decrypting. Answering `N` continues setup with FileVault on, and automatic login then fails.
2. Turn FileVault off in System Settings > Privacy & Security > FileVault, or run `sudo fdesetup disable`.
3. Wait until `fdesetup status` prints `FileVault is Off.` This can take an hour or more.
4. Run `first-boot.sh` again. See [step 5 of the tutorial](../get-started/05-first-boot.md).

## SSH to the server is refused or asks for a password

**Cause**

1. Remote Login is off.
2. The SSH keys were not in the package, so `authorized_keys` was not installed.
3. The application firewall blocks `sshd`. `first-boot.sh` turns the firewall on and allows `/usr/sbin/sshd`.

Setup does not turn off SSH password login. A password prompt means that the server did not accept your key.

**Check**

On the server:

```bash
sudo systemsetup -getremotelogin
ls -l ~/.ssh/authorized_keys
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps
```

`Remote Login: Off` means SSH is off. `No such file or directory` means no key was installed for this account. If the firewall list shows `/usr/sbin/sshd` as blocked, the firewall stops SSH.

**Fix**

1. On the dev Mac, make sure that `~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub` exist before you run `prep-airdrop.sh`.
2. Build the package again and run `first-boot.sh` again. It turns on Remote Login, installs the keys for `admin` and `operator`, and runs `setup-firewall.sh`, which allows `/usr/sbin/sshd` through the firewall.

## Touch ID does not work for operator

**Cause**

This is by design. On macOS, Touch ID and automatic login cannot be used together. The `admin` account has Touch ID. The `operator` account has automatic login.

**Check**

```bash
defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser
```

The output is `operator` when automatic login is set for that account.

**Fix**

1. Use the `operator` password, or work as `admin` and use `sudo -iu operator`.

## Passwords app rejects the operator password after a reboot

**Cause**

This is a known limitation of automatic login. In a session that automatic login started, the Passwords app rejects the correct password. It can also happen when `operator` has no SecureToken.

**Check**

```bash
sysadminctl -secureTokenStatus operator
```

The output must say `Secure token is ENABLED`. `first-boot.sh` grants the token.

**Fix**

1. If the token is not enabled, run the `sysadminctl -secureTokenOn` command that the first-boot log prints.
2. Log out of the `operator` account.
3. Log in again and type the password. The Passwords app then unlocks.

## brew is not found in a new terminal

**Cause**

The shell started before the Homebrew setup, or the shell profile was not read.

**Check**

```bash
ls -l ~/.bash_profile
echo "${PATH}"
```

`~/.bash_profile` is a link that the setup made. If `PATH` has no `/opt/homebrew/bin`, the profile was not read.

**Fix**

1. Close the terminal and open a new one, or run `source ~/.bash_profile`.

## run-app-setup.sh says it must be run from the app-setup directory

**Cause**

`run-app-setup.sh` checks the current folder and stops when you run it from another folder. It also stops when `config/config.conf` is not in that folder, which means that `first-boot.sh` did not finish.

**Check**

```bash
pwd
ls ~/app-setup/config/config.conf
```

`pwd` must print the `app-setup` folder.

**Fix**

1. Go to the folder and run the script from there:

    ```bash
    cd ~/app-setup
    ./run-app-setup.sh
    ```

2. If `config/config.conf` is missing, run `first-boot.sh` again until it finishes.

## run-app-setup.sh stops at the first script

**Cause**

A plain `./run-app-setup.sh` runs every `*-setup.sh` script and stops at the first error. The first script is `rclone-setup.sh`, which stops when `DROPBOX_SYNC_FOLDER` is empty. Most other scripts stop when their config keys or credentials are missing.

**Check**

```bash
grep -E "failed with exit code|not found" ~/.local/state/<hostname>-app-setup.log | tail -20
tail -50 ~/.local/state/<hostname>-apps.log
```

The first file names the script that failed. The second file shows the error from inside that script.

**Fix**

1. Run only the scripts you need, one at a time:

    ```bash
    ./run-app-setup.sh --only plex-setup.sh
    ```

2. Or run all of them and skip past failures:

    ```bash
    ./run-app-setup.sh --continue-on-error
    ```

3. Before you run a script, read its row in the [stack matrix](../reference/stack-matrix.md) and set the keys it needs.

See [Run app setup](../get-started/06-run-app-setup.md).
