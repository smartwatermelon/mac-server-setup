# Alert email with msmtp

The server's watchdogs send alert email through msmtp, a small SMTP client, to a Gmail account. msmtp signs in to `smtp.gmail.com` with a Gmail App Password. [`app-setup/msmtp-setup.sh`](https://github.com/smartwatermelon/mac-server-setup/blob/main/app-setup/msmtp-setup.sh) installs msmtp, writes its config for the `operator` account, installs the shared alert library, and sends a test email under the same PATH that launchd gives a LaunchAgent.

## Before you start

1. Choose the Gmail account that sends and receives the alerts. msmtp signs in as `MONITORING_EMAIL` and sends each alert to `MONITORING_EMAIL`, so the App Password must belong to that same account.
2. Turn on 2-Step Verification for that Google account. Google offers App Passwords only when it is on.
3. Set `MONITORING_EMAIL` in `config/config.conf`:

    ```bash
    MONITORING_EMAIL="you@example.com"
    ```

    If the key is empty or still has the template value `your-email@example.com`, `msmtp-setup.sh` asks for an address and writes it into `~/app-setup/config/config.conf`. See [Configuration keys](../reference/config-keys.md#monitoring).

4. Set up msmtp before `podman-transmission-setup.sh` if you can. That script deploys the PIA port watchdog and the stall watchdog only when `MONITORING_EMAIL` is set and `/Users/operator/.config/msmtp/config` exists. If you set up msmtp later, run `podman-transmission-setup.sh` again.

## Set it up

1. Create the App Password. Sign in to the Google account at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords), enter a name such as `Mac Mini Server`, and create it. Google shows a 16-character password once. Keep the page open for the next steps.
2. On the server, as `admin`, go to the app setup folder:

    ```bash
    cd ~/app-setup
    ```

3. Run the script:

    ```bash
    ./msmtp-setup.sh
    ```

4. At `Enter Gmail App Password:`, type the 16 characters without the spaces, then press Enter. The script does not show what you type.

    You can also give the password with `--password PASSWORD`. The password is then in the command line and in your shell history, so the prompt is better.

5. Enter the `admin` password when `sudo` asks for it.

The script does these things:

1. It installs `msmtp` and `jq` with Homebrew, unless they are already installed.
2. It writes `/Users/operator/.config/msmtp/config`, owned by `operator`, mode 600. The App Password is in this file as plain text, because a LaunchAgent cannot unlock the operator keychain. Do not print the file. Its settings are:

    ```text
    defaults
    auth           on
    tls            on
    tls_trust_file /etc/ssl/cert.pem
    logfile        /Users/operator/.local/state/msmtp.log

    account        gmail
    host           smtp.gmail.com
    port           587
    from           operator@<hostname>
    user           <MONITORING_EMAIL>
    password       <App Password>

    account default : gmail
    ```

    Gmail replaces the `from` address with the account that signed in, so the `from` value has no effect.

3. It copies the alert library to `/Users/operator/.local/lib/alert-lib.sh`. Every watchdog sends email through its `alert_send` function, which finds msmtp by its absolute Homebrew path.
4. It sends a test email with the subject `[<hostname>] Monitoring email configured`. It sends it as `operator`, with only `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME` and `MONITORING_EMAIL` set. That is the environment of a LaunchAgent. If the test fails, the script stops with an error.

When a config with a password already exists, the script keeps it and does not ask for a password. To replace the App Password, run it with `--force`. The script then asks for the new password.

```bash
./msmtp-setup.sh --force
```

## Check

Run these checks as `admin`.

1. The setup output ends with `Test email sent successfully to you@example.com`, and the email is in the inbox.
2. Send a test alert under launchd's PATH. Replace `you@example.com` with your `MONITORING_EMAIL` value:

    ```bash
    sudo -u operator /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME=/Users/operator \
      MONITORING_EMAIL=you@example.com \
      /bin/bash -c 'cd ~ && . ~/.local/lib/alert-lib.sh && alert_send "[macmini] test" "launchd-PATH test"'
    ```

    On success the command prints nothing and exits 0. On failure it prints an `[alert-lib] ERROR: ...` line.

    Use `sudo -u`, not `sudo -iu`. A login shell adds Homebrew to PATH, and the test then proves nothing about launchd.

3. The last line of msmtp's log shows `exitcode=EX_OK`:

    ```bash
    sudo tail -1 /Users/operator/.local/state/msmtp.log
    ```

4. The config file is private to `operator`:

    ```bash
    sudo ls -l /Users/operator/.config/msmtp/config
    ```

    The output starts with `-rw-------` and shows `operator`.

If no email arrives, look for `ERROR` lines in the watchdog's log. The [Monitoring](monitoring.md#troubleshooting) page explains each error. An authentication failure in the error text often means that the App Password was revoked. Create a new one and run `./msmtp-setup.sh --force`.

## Related

- [Monitoring](monitoring.md): the watchdogs, the `alert-lib.sh` functions, and the launchd PATH problem.
- [Transmission first install](transmission-first-install.md): deploys the PIA port watchdog and the stall watchdog.
- [Configuration keys](../reference/config-keys.md)
- [Logs](../reference/logs.md)
- [LaunchAgents](../reference/launchagents.md)
