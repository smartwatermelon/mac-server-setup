# Monitoring problems

This page covers the watchdogs and the alert email that they send through msmtp. Run the checks as `admin` on the server.

The watchdogs are `operator` LaunchAgents: `plex-watchdog`, `pia-port-watchdog`, `stall-watchdog`, `access-policy-watchdog` and `tunnel-watchdog`. Each run is one poll: check, maybe send email, exit. All of them send email through the shared library `~/.local/lib/alert-lib.sh` and the msmtp config `~/.config/msmtp/config` in the `operator` account. Do not print the msmtp config: it holds the SMTP app password.

For how this works, see [Monitoring](../components/monitoring.md). For the labels and logs, see [LaunchAgents and LaunchDaemons](../reference/launchagents.md) and [Log files](../reference/logs.md).

## No alert email arrives

**Cause**

1. msmtp is not at the path that the library uses (`/opt/homebrew/bin/msmtp` on Apple silicon). launchd starts agents with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which has no Homebrew. Until September 2026 the watchdogs called a bare `msmtp` and hid its error, so every alert from launchd failed with no trace. They now set `PATH` themselves and use an absolute path.
2. The msmtp config is missing.
3. msmtp ran and the SMTP server refused the message, for example after the app password was revoked.
4. `MONITORING_EMAIL` is not set. Then `podman-transmission-setup.sh` does not install `pia-port-watchdog` and `stall-watchdog` at all.

**Check**

Look for `ERROR` lines in the watchdog's log, then for the send in msmtp's log:

```bash
sudo grep ERROR /Users/operator/.local/state/plex-watchdog.log | tail -5
sudo tail -5 /Users/operator/.local/state/msmtp.log
```

The `ERROR` line names the cause:

- `msmtp not found or not executable at <path>`: msmtp is not installed at that path.
- `msmtp config not found at <path>`: the config is missing.
- `msmtp (<path>) exited <n> sending '<subject>': <stderr>`: msmtp ran and failed. The stderr text gives the reason.
- `MONITORING_EMAIL is not set`: the watchdog has no recipient.
- `alert library not found at`: the watchdog stops on every run.

A send that fails before msmtp starts leaves no line in `msmtp.log`. A good send has `exitcode=EX_OK`.

**Fix**

1. If msmtp is missing, run `brew install msmtp`, or run `msmtp-setup.sh` again.
2. If the config is missing, or the password was revoked, create a new app password and run `msmtp-setup.sh --force` from `~/app-setup`.
3. If the alert library is missing, run the setup script that the `ERROR` line names.
4. Send a test alert in the same environment that launchd gives an agent. Use `sudo -u`, not `sudo -iu`: a login shell adds Homebrew to `PATH`, and the test then proves nothing about launchd.

    ```bash
    sudo -u operator /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME=/Users/operator \
      MONITORING_EMAIL=you@example.com \
      /bin/bash -c 'cd ~ && . ~/.local/lib/alert-lib.sh && alert_send "[macmini] test" "launchd PATH test"'
    ```

    Replace `you@example.com` with your `MONITORING_EMAIL`. On success the command prints nothing. Then check that the last line of `msmtp.log` has `exitcode=EX_OK`.

## A watchdog does not run

**Cause**

1. The `operator` account is not logged in. LaunchAgents start only in a desktop session.
2. The plist is not loaded, or was never installed.
3. The script exits at once, for example with `alert library not found`.

**Check**

```bash
for job in plex-watchdog pia-port-watchdog stall-watchdog access-policy-watchdog tunnel-watchdog; do
  printf '%s: ' "${job}"
  sudo launchctl print "gui/$(id -u operator)/com.<hostname>.${job}" >/dev/null 2>&1 && echo loaded || echo "not loaded"
done
sudo ls /Users/operator/Library/LaunchAgents/ | grep watchdog
```

`not loaded` for a plist that exists means the job must be loaded. A missing plist means the setup script did not install it.

**Fix**

1. Load a job whose plist exists:

    ```bash
    sudo launchctl bootstrap gui/$(id -u operator) \
      /Users/operator/Library/LaunchAgents/com.<hostname>.<job>.plist
    ```

2. After you change a plist, run `launchctl bootout` for the label first, then `bootstrap`.
3. If a plist is missing, run its setup script: `plex-watchdog-setup.sh`, `podman-transmission-setup.sh` (with `MONITORING_EMAIL` set), `access-policy-watchdog-setup.sh` or `tunnel-watchdog-setup.sh`.
4. To run a job now, run `sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.<job>`. A run can send email.

## A privacy prompt blocks the server

**Cause**

A macOS privacy (TCC) prompt, such as "would like to access files on a network volume", is open on the desktop. The process that asked waits until someone answers. One open prompt also delays other processes' network volume checks, so FileBot, the Transmission container and Plex can all stall behind it. A common trigger is a `brew upgrade` that replaced a binary that is not mirrored to `/usr/local/stable`.

`stall-watchdog` emails `macOS privacy prompt is blocking the server` when a prompt has been open for 5 minutes, and sends a reminder every 12 hours.

**Check**

```bash
sudo grep -E 'TCC prompt (opened|closed)' /Users/operator/.local/state/<hostname>-stall-watchdog.log | tail -10
/usr/local/bin/<hostname>-stable-sign.sh --check
```

`TCC prompt opened:` names the service and the binary that asked. `--check` exits 1 if a stably-signed copy is stale.

**Fix**

1. Answer the prompt on the desktop, at the Mac mini or through Screen Sharing. Click Allow for a binary that you expect.
2. If the binary is a Homebrew copy of podman, gtimeout or bash, run `/usr/local/bin/<hostname>-stable-sign.sh` so that the stable copy is current. See [Stable signing](../components/stable-signing.md).
3. If the email repeats but no prompt is on the desktop, the watchdog may have missed the answer. Find the prompt key, then remove it. The recovery email goes out on the next run:

    ```bash
    sudo -u operator /bin/bash -c '
      f=/Users/operator/.config/stall-watchdog/state.json
      jq ".tcc_prompts" "$f"'
    sudo -u operator /bin/bash -c '
      f=/Users/operator/.config/stall-watchdog/state.json
      jq "del(.tcc_prompts[\"<key>\"])" "$f" >"$f.tmp" && mv "$f.tmp" "$f"'
    ```

## stall-watchdog says the podman supervisor is failing or has stopped reporting

**Cause**

The podman supervisor writes `~/.local/state/<hostname>-supervisor-status.json` in the `operator` account once per cycle. `stall-watchdog` alerts `podman supervisor has failed n cycles in a row` at 3 failed cycles, and `podman supervisor has stopped reporting` when the file is an hour old. A missing file means "unknown", and nothing is alerted.

**Check**

```bash
sudo cat /Users/operator/.local/state/<hostname>-supervisor-status.json
date +%s
```

`last_error` names the step that failed. Compare `updated_at` with the current time from `date +%s`.

**Fix**

1. Follow [Transmission web UI does not load](transmission-vpn.md#transmission-web-ui-does-not-load).

## stall-watchdog cannot read the system log

**Cause**

`stall-watchdog` finds prompts by reading tccd lines with `log show`. If `log show` fails 3 runs in a row, it emails `stall-watchdog cannot read the system log`. It keeps its prompt state while the log is unreadable, so it does not lose a prompt.

**Check**

```bash
sudo grep -E "ERROR: '.*show'" /Users/operator/.local/state/<hostname>-stall-watchdog.log | tail -5
```

The line gives the exit code and the error text of `log show`.

**Fix**

1. Fix the cause in the error text. The recovery email goes out when a read works again.
2. Look at the desktop for an open prompt while the log is unreadable, because the watchdog cannot see new prompts.

## The same alert comes back every 12 hours

**Cause**

This is by design for alerts that use `alert_transition`: the media access check of `plex-watchdog`, and every check of `stall-watchdog`, `access-policy-watchdog` and `tunnel-watchdog`. While the condition stays bad, the watchdog sends the alert again every 12 hours with `[reminder]` in front of the subject. When the condition clears, it sends one `RESOLVED:` email.

**Check**

```bash
sudo grep -E 'ALERT sent|RESOLVED' /Users/operator/.local/state/<hostname>-stall-watchdog.log | tail -10
```

Each sent alert or reminder logs `ALERT sent: <key>: <subject>`. Each recovery logs `RESOLVED: <key>`.

**Fix**

1. Fix the condition that the alert names. The reminders stop at the recovery email.

## pia-port-watchdog sends no alert while port forwarding is down

**Cause**

1. Transmission does not answer. The watchdog then skips the cycle and does not count it, because a dead Transmission is not lost port forwarding.
2. The alert send failed. The watchdog does not mark the alert as sent, so it tries again every cycle while the outage continues.

**Check**

```bash
sudo tail -20 /Users/operator/.local/state/<hostname>-pia-port-watchdog.log
```

`Transmission RPC unreachable` means cause 1. `ERROR: failed to send alert email` means cause 2. `Port forwarding looks lost (n/3)` lines count toward the alert.

**Fix**

1. For cause 1, see [Transmission web UI does not load](transmission-vpn.md#transmission-web-ui-does-not-load).
2. For cause 2, see [No alert email arrives](#no-alert-email-arrives).
3. For the port forwarding itself, see [New torrents do not start, or stay at 0 percent](transmission-vpn.md#new-torrents-do-not-start-or-stay-at-0-percent).
