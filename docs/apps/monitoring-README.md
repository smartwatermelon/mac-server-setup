# Monitoring: Watchdogs and Alert Email

The server's watchdogs are small poll-and-exit scripts run by operator
LaunchAgents. When something goes wrong they email `MONITORING_EMAIL` through
msmtp (Gmail SMTP). They all send that email through one shared library,
`alert-lib.sh`.

## Watchdogs

| Watchdog | LaunchAgent | Interval | Log | Deployed by |
| --- | --- | --- | --- | --- |
| `plex-watchdog` — Plex settings drift, Plex unreachable | `com.<host>.plex-watchdog` | 300 s, RunAtLoad | `~/.local/state/plex-watchdog.log` | `plex-watchdog-setup.sh` |
| `pia-port-watchdog.sh` — PIA port forwarding lost | `com.<host>.pia-port-watchdog` | 900 s | `~/.local/state/<host>-pia-port-watchdog.log` | `podman-transmission-setup.sh` |

Paths are under the operator's home (`/Users/operator`). Both LaunchAgents run
the script as `/bin/bash <script>` and send stdout and stderr to the same log
file. For the details of each check, see `plex-watchdog-README.md` and
`pia-vpn-README.md`.

Other files:

- `~/.local/lib/alert-lib.sh` — the shared library (mode 0644)
- `~/.config/msmtp/config` — msmtp account, with an embedded Gmail App Password
  (mode 600). Do not print this file.
- `~/.local/state/msmtp.log` — msmtp's own log: one line per send attempt, with
  `exitcode=EX_OK` on success

## The launchd PATH problem (fixed 2026-09)

launchd starts every agent with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Homebrew
(`/opt/homebrew/bin` on Apple Silicon) is not on it. msmtp is a Homebrew binary.

Before this fix, both watchdogs sent mail with a bare
`msmtp ... 2>/dev/null`. Under launchd, `msmtp` was "command not found" on
every run, and `2>/dev/null` discarded that error. So every alert from a
LaunchAgent failed silently, from the first watchdog deploy (plex-watchdog,
2026-03) until this fix. Nothing reached `msmtp.log` either, because msmtp
never started.

It stayed hidden because every manual check used a login shell.
`msmtp-setup.sh` sent its test email through `sudo -iu operator msmtp ...`, and
a login shell has Homebrew on PATH. So the setup test passed and the
LaunchAgents failed.

The fix has three parts:

1. Each watchdog sets PATH itself, near the top:
   `export PATH="${HOMEBREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin"`, with
   `HOMEBREW_PREFIX` derived from the CPU architecture. This is the same
   pattern as `transmission-trigger-watcher.sh`.
2. `alert_send` finds msmtp by absolute path. When a send fails, it logs an
   `ERROR` line that includes msmtp's stderr.
3. `msmtp-setup.sh` sends its test email through `alert_send` under
   `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which is the launchd
   environment. If launchd would fail, setup fails too.

Also: the LaunchAgents use `/bin/bash`, which is bash 3.2. The Plex-unreachable
email used `${HOSTNAME_LABEL,,}`, which bash 3.2 rejects as a "bad
substitution", so that email was never built. It now uses `tr`. Code that the
watchdogs run, including `alert-lib.sh`, must stay bash 3.2 compatible.

## alert-lib.sh

`app-setup/templates/alert-lib.sh` is a library: source it, do not run it. It
sets no shell options and does not change PATH. It uses `jq` and `date` from
the caller's PATH.

The caller sets:

- `MONITORING_EMAIL` — the recipient
- `STATE_FILE` — the JSON state file, for the state and transition functions.
  Its directory must exist.
- `log()` — optional. If defined, the library writes its log lines through it
  (so they use the watchdog's log format). If not, they go to stderr.

Optional overrides:

- `ALERT_MSMTP` — msmtp binary. Default `<HOMEBREW_PREFIX>/bin/msmtp`.
- `HOMEBREW_PREFIX` — default `/opt/homebrew` on arm64, else `/usr/local`
- `ALERT_MSMTP_CONFIG` — default `~/.config/msmtp/config`
- `ALERT_REMINDER_SECONDS` — used by `alert_transition` (see below)

Functions:

| Function | Behaviour |
| --- | --- |
| `alert_send SUBJECT BODY` | Sends one email (`Subject:` and `To:` headers, blank line, body). Returns 0 only if msmtp accepted it. On failure it logs an `ERROR` line with the reason (msmtp missing at `<path>`, config missing, or msmtp's exit code and stderr) and returns 1. |
| `alert_state_read` | Prints the state JSON, or `{}` if there is no state file. |
| `alert_state_get KEY [DEFAULT]` | Prints `.KEY` from the state, or DEFAULT if the value is missing, null or `false`. |
| `alert_state_write JSON` | Writes the state atomically (a temp file, then `mv`). |
| `alert_transition KEY IS_BAD SUBJECT BODY [RECOVERY_SUBJECT [RECOVERY_BODY]]` | Sends one alert when a condition goes bad, and one recovery email when it clears. See below. |

`alert_transition` keeps its state in `.transitions[KEY]` =
`{alerted, since, last_sent}` (`since` and `last_sent` are epoch seconds). It
does not change other keys in the state file, so you can call it for more than
one KEY in one run.

- Bad, not yet alerted: send the alert. Set `alerted` only if the send
  succeeded. If the send fails, it tries again on the next call.
- Bad, already alerted: no email. But if `ALERT_REMINDER_SECONDS` is set and
  that many seconds have passed since `last_sent`, it sends the alert again
  with `[reminder]` before the subject.
- Good, was alerted: send the recovery email (best effort), then remove the
  entry. The default subject is `RESOLVED: <SUBJECT>`.
- Good, not alerted: remove the entry, if one exists.

It returns 1 if an alert or reminder send failed, else 0. Under `set -e`, call
it as `alert_transition ... || true`.

The two current watchdogs use `alert_send` and the state functions, but keep
their own alert, dedupe and heartbeat logic. `alert_transition` is for new
checks.

## Send a test alert under launchd's PATH

Run this as an admin on the server. It uses the same environment that launchd
gives an agent:

```bash
sudo -u operator /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME=/Users/operator \
  MONITORING_EMAIL=you@example.com \
  /bin/bash -c 'cd ~ && . ~/.local/lib/alert-lib.sh && alert_send "[TILSIT] test" "launchd-PATH test"'
```

Replace `you@example.com` with the `MONITORING_EMAIL` value from
`app-setup/config/config.conf`. On success the command prints nothing and exits
0. On failure it prints an `[alert-lib] ERROR: ...` line to stderr.

Then read the last line of msmtp's log. It must show `exitcode=EX_OK`:

```bash
sudo tail -1 /Users/operator/.local/state/msmtp.log
```

Use `sudo -u`, not `sudo -iu`. A login shell adds Homebrew to PATH, and the
test then proves nothing about launchd.

## Troubleshooting

**No alert email arrived.** Look for `ERROR` lines in the watchdog's log. The
line tells you the cause:

- `msmtp not found or not executable at <path>` — msmtp is not installed at
  that path. Run `brew install msmtp`, or re-run `msmtp-setup.sh`.
- `msmtp config not found` — run `msmtp-setup.sh`.
- `msmtp (<path>) exited <n> sending '<subject>': <stderr>` — msmtp ran and
  failed. The stderr text gives the reason, for example an authentication
  failure after the App Password was revoked. Also see `msmtp.log`.
- `alert library not found at ~/.local/lib/alert-lib.sh` — the watchdog stops
  (exit 1) on every run. Re-run the setup script that deploys it
  (`msmtp-setup.sh`, `plex-watchdog-setup.sh` or
  `podman-transmission-setup.sh`).

**Where a failed alert goes.** `pia-port-watchdog` does not set `alerted` when
its send fails, so it tries again every cycle while the outage continues.
`plex-watchdog` keeps its original behaviour: it records the drift even if the
send failed, so a failed drift email is not sent again. The `ERROR` line in the
log is the record of the failure.

## Tests

```bash
bats tests/alert-lib.bats
bats tests/plex-watchdog.bats
bats tests/pia-port-watchdog.bats
```

Each watchdog test file has a "launchd PATH" test. It runs the rendered
watchdog as `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash <script>`,
with the msmtp mock only in a fake Homebrew prefix, and checks that the alert
is sent. These tests fail against the pre-fix templates.
