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
| `stall-watchdog.sh` — server blocked on a privacy prompt, a long `transmission-done`, supervisor failing | `com.<host>.stall-watchdog` | 120 s, RunAtLoad | `~/.local/state/<host>-stall-watchdog.log` | `podman-transmission-setup.sh` |

Paths are under the operator's home (`/Users/operator`). All the LaunchAgents run
the script as `/bin/bash <script>` and send stdout and stderr to the same log
file. For the details of each check, see `plex-watchdog-README.md`,
`pia-vpn-README.md`, and [stall-watchdog](#stall-watchdog) below.

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

Each accepted alert or reminder logs `ALERT sent: <KEY>: <subject>`, and each
recovery logs `RESOLVED: <KEY>`, so the watchdog's own log shows every email
without cross-checking `msmtp.log`.

It returns 1 if an alert or reminder send failed, else 0. Under `set -e`, call
it as `alert_transition ... || true`.

plex-watchdog and pia-port-watchdog use `alert_send` and the state functions,
but keep their own alert, dedupe and heartbeat logic. stall-watchdog uses
`alert_transition` for all of its checks.

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

## stall-watchdog

Issue #199. On 2026-09-17 a macOS privacy (TCC) prompt about network-volume
access stayed open on the desktop for 19 hours. FileBot, the Transmission
container and Plex waited on it, and nothing alerted, because no check looked
for "blocked" as opposed to "failed". stall-watchdog runs every 2 minutes and
makes one `alert_transition` call per check:

| Key | Bad when | Notes |
| --- | --- | --- |
| `tcc_prompt` | a TCC prompt has been open for 5 minutes or more | The email lists every open prompt: service, binary, how long it has been open. Reminder every 12 hours. |
| `tcc_log_unreadable` | `log show` failed 3 runs in a row | State is left untouched on a failed read, so no prompt is lost. |
| `done_running_long` | a `transmission-done` process has run for over 45 minutes | Found with `ps -axo pid=,etime=,command=`. Never killed: stopping FileBot mid-move can lose the file. |
| `supervisor_failing` | the status file shows 3 or more consecutive failed cycles | See "Supervisor status file" below. |
| `supervisor_stale` | the status file has not been updated for an hour | The supervisor loop is hung, or its agent is not running. |

`ALERT_REMINDER_SECONDS` is 43200 for all of these. State is in
`~/.config/stall-watchdog/state.json`.

### How prompts are detected

The per-user `tccd` logs two lines per prompt, with the same `msgID`:

```text
AUTHREQ_PROMPTING: msgID=17928.48, service=kTCCServiceSystemPolicyNetworkVolumes, subject=Sub:{/usr/local/stable/bash/bin/bash}Resp:{...}
AUTHREQ_RESULT: msgID=17928.48, authValue=2, ...
```

The first is logged when the dialog opens, the second when someone answers it
(Allow or Don't Allow). Each run reads new `AUTHREQ_PROMPTING` lines since the
previous run (with 1 minute of overlap, and at most 1 hour of catch-up after a
gap), and records each prompt in `.tcc_prompts`. While a prompt is open, it
also reads `AUTHREQ_RESULT` lines over the same window. On TILSIT there are
about 39,000 RESULT lines a day, mostly from the system `tccd`, and about one
PROMPTING line, so RESULT lines are read only when needed.

Prompts are keyed `<tccd pid>/<msgID>`. The msgID is `<client pid>.<sequence>`,
and the same client (`sandboxd`) talks to both the system `tccd` and the
per-user one, each with its own sequence. A RESULT from the system `tccd` can
carry the same msgID as an open prompt, and must not close it.

A prompt closes on its own RESULT line, or when the `tccd` process that owns it
has exited. It is never dropped for being old: that would send a recovery email
while the dialog is still on screen. `tccd` log lines do not stay in the log
for long (the 09-17 lines were already gone by 09-23), which is why the
watchdog keeps its own state.

### Clearing a prompt by hand

If a RESULT line is missed (the log was unreadable for longer than the 1-hour
catch-up window), the prompt stays open and a reminder goes out every 12 hours.
After you check that no dialog is on the desktop, remove the entry. The recovery
email goes out on the next run. The path is spelled out because `sudo -u`
keeps your own HOME, so `~` would point at the wrong file:

```bash
sudo -u operator /bin/bash -c '
  f=/Users/operator/.config/stall-watchdog/state.json
  jq ".tcc_prompts" "$f"                                   # find the key
  jq "del(.tcc_prompts[\"<key>\"])" "$f" >"$f.tmp" && mv "$f.tmp" "$f"'
```

### Supervisor status file

The podman supervisor loop (the `podman-machine-start.sh` wrapper, written by
`podman-transmission-setup.sh`) rewrites
`~/.local/state/<host>-supervisor-status.json` once per cycle:

```json
{"consecutive_failures": 0, "last_error": "", "updated_at": 1790192010}
```

A cycle fails when `ensure_machine` or `ensure_container` fails, or when a VM
recovery restart fails. A data-access failure on its own does not count: that
check already escalates by cycling the VM. The wrapper sends no email.

**A missing file means "unknown", and nothing is alerted.** The wrapper change
takes effect only when the supervisor is restarted, and restarting it restarts
the VM. The header of the wrapper heredoc in `podman-transmission-setup.sh`
explains why the loop must never exit. So stall-watchdog can be deployed first, and the supervisor checks
start working at the next VM maintenance window.

### Deploying

Re-running all of `podman-transmission-setup.sh` also manages the container.
To deploy only the watchdog: render the template with the real
`__SERVER_NAME__` and `__MONITORING_EMAIL__`, install it to
`~operator/.local/bin/stall-watchdog.sh` (mode 755), write the plist from
section 9e of the setup script, and load it:

```bash
sudo launchctl bootstrap gui/$(id -u operator) \
  /Users/operator/Library/LaunchAgents/com.<host>.stall-watchdog.plist
```

To reload after changing the plist, `bootout` the label first. To rerun it
now, `sudo launchctl kickstart -kp gui/$(id -u operator)/com.<host>.stall-watchdog`.

### Live test (2026-09-23)

Run on TILSIT with an ad-hoc-signed copy of Homebrew bash at
`/Users/Shared/tcc-canary/probe2`, started by a temporary operator
LaunchAgent that ran `/bin/ls` on the NAS mount:

| Time | Event |
| --- | --- |
| 15:15:03 | tccd logged `AUTHREQ_PROMPTING`; the dialog opened and `ls` blocked |
| 15:16:46 | the watchdog recorded the prompt (`446/17928.161`) |
| 15:20:56 | alert email sent (first run after 5 minutes open) |
| 15:26:47 | Don't Allow clicked; `ls` failed with "Operation not permitted" |
| 15:27:04 | the watchdog closed the prompt ("open 11m") and logged `RESOLVED: tcc_prompt` |
| 15:27:06 | recovery email sent |

An earlier canary, answered with Allow after 34 seconds, was recorded and
closed without an email, as intended.

While the prompt was open, `podman ps`, `ls` of `/data` inside the VM, Plex
`checkFiles=1` on a library item, and operator's own `/bin/ls` of the NAS all
returned in under a second. **An open prompt blocks only the process it was
raised for**, not other network-volume access. So the 09-17 outage, which
stalled FileBot, Transmission and Plex, was not one prompt blocking all NAS
access. Each was probably waiting on a prompt of its own, or on a process that
was, but that is not confirmed.

To repeat the test, use a new path and signing identifier each time: once a
prompt is answered, tccd stores the answer for that binary and does not ask
again. `tccutil reset` takes a bundle ID and cannot remove these rows, but
they are inert once the binary is deleted.

### Not yet proven

- **Whether a prompt is logged again after a long gap.** A scan looks back at
  most an hour. If the agent was not running for longer than that while a
  prompt opened, the watchdog sees that prompt only if tccd logs it again,
  which is expected on the next access attempt but not verified.

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
bats tests/stall-watchdog.bats
bats tests/msmtp-setup.bats
bats tests/podman-machine-start.bats   # supervisor status file
```

Each watchdog test file has a "launchd PATH" test. It runs the rendered
watchdog as `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash <script>`,
with the msmtp mock only in a fake Homebrew prefix, and checks that the alert
is sent. These tests fail against the pre-fix templates.
