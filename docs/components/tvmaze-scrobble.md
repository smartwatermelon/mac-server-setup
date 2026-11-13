# TVmaze scrobble (Plex → TVmaze watched sync)

When Andrew finishes a TV episode in Plex, the same episode is marked
watched on his TVmaze account. An episode that cannot be synced is logged
and emailed once. Issue #167; design in
`docs/plans/2026-11-05-tvmaze-scrobble.md`.

## How it works

```text
Plex Media Server --POST multipart (payload=JSON)--> 127.0.0.1:32599
  tvmaze-scrobble-listener   python3, stdlib, LaunchAgent (KeepAlive)
      | payload JSON on stdin, not waited for
      v
  tvmaze-scrobble            bash worker: Plex GUIDs, TVmaze calls, state, email

  tvmaze-scrobble --reconcile   hourly LaunchAgent: Plex watch history for the
                                last 7 days, syncs any play the webhook missed
```

Two paths reach the same `sync_episode` function:

1. **Webhook** (seconds after a play ends). The listener accepts only
   `event == "media.scrobble"` with `Metadata.type == "episode"` and always
   answers fast. The worker then drops any play whose `Account.title` is not
   `PLEX_ACCOUNT_TITLE`. (The webhook's `Account.id` is a plex.tv id, not
   the server-local id; the worker logs it so the filter could move to it.)
2. **Reconcile** (hourly, and at load). Plex does not resend webhooks, so
   plays during a listener outage or a reboot would be lost. The reconcile
   run reads `/status/sessions/history/all` for the server-local
   `PLEX_ACCOUNT_ID` (1 is the server owner), keeps episodes viewed in the
   last `RECONCILE_LOOKBACK_DAYS` (7), and syncs each one not already in the
   `synced` state file. It waits 2 s between episodes (TVmaze allows about
   20 calls per 10 s).

### Show matching

1. `POST /v1/scrobble/shows?thetvdb_id=N` (from the show's `tvdb://` GUID).
2. `?imdb_id=ttN` (from `imdb://`).
3. `GET /search/shows?q=<title>`: if exactly one result's name equals the
   Plex show title (case-insensitive, outer spaces trimmed),
   `?tvmaze_id=N`. Zero or several exact matches: no guess, it fails.

The worker falls through to the next step when an id is missing, or TVmaze
says no match (HTTP 404, or 422/207 whose item code is not 200). It stops at
once on 401 (bad key), no answer, 429 or 5xx: another id would not help.
TMDB ids are not used: `/scrobble/shows` does not accept them (The Great
British Bake Off has only a `tmdb://` GUID and goes by title).

The show GUIDs come from `GET /library/metadata/<show key>?includeGuids=1`
on the local Plex server, with the token from
`~operator/.config/plex-watchdog/token` (deployed by
`plex-watchdog-setup.sh`). If Plex does not answer, the title search still
runs.

## Files on the server (operator account)

| Path | What |
| --- | --- |
| `~/.local/bin/tvmaze-scrobble-listener` | listener |
| `~/.local/bin/tvmaze-scrobble` | worker |
| `~/.local/lib/alert-lib.sh` | shared email library (`alert_send`) |
| `~/.config/tvmaze-scrobble/credentials` | `username:apikey`, mode 600 |
| `~/.local/state/tvmaze-scrobble.log` | log for both agents (rotated by logrotate) |
| `~/.local/state/tvmaze-scrobble/synced` | episode ratingKeys on TVmaze |
| `~/.local/state/tvmaze-scrobble/failed` | episode ratingKeys already emailed |
| `~/.local/state/tvmaze-scrobble/seeded` | marker: first reconcile run is done |
| `~/Library/LaunchAgents/com.<host>.tvmaze-scrobble.plist` | listener agent |
| `~/Library/LaunchAgents/com.<host>.tvmaze-reconcile.plist` | reconcile agent (3600 s) |

### State rules

- The key is the episode's Plex `ratingKey`, the same in the webhook
  (`Metadata.ratingKey`) and in history. A rewatch is not synced again.
- **First run.** The first reconcile run (no `seeded` marker) adds every
  episode in the window to `synced`, scrobbles nothing, and logs
  `first run, seeded N episodes`. This stops a fresh install from
  re-marking a week of old plays. The marker is separate from `synced`, so
  a webhook play before the first run cannot skip the seed.
- **Failures.** A failed episode is emailed once and its key goes into
  `failed`. Later failures of the same episode, from either path, are only
  logged (`already emailed for Plex key N`). Reconcile keeps retrying it
  every hour until it leaves the 7-day window. A later success adds it to
  `synced`.
- **Setup problems.** If the credentials file is missing or malformed, or
  the Plex token cannot be read, the worker sends one email titled
  `TVmaze sync is not working` and then only logs, until the problem clears.
  These are not per-episode failures and do not go into `failed`.
- To re-sync an episode, delete its line from `synced` and kick the
  reconcile agent. To forget all state, remove the directory; the next run
  seeds again.

## Credentials

TVmaze uses HTTP Basic: the TVmaze **username** (not the email) and the API
key. The free account can scrobble.

- Source of truth: 1Password `Automation/TVMaze`, field `API Key`. The
  item's `username` field is the email, which TVmaze rejects, so the
  username comes from `TVMAZE_USERNAME` in `config.conf`.
- The setup script reads the key from the admin's login keychain (service
  `tvmaze-<host>`, account `TVMAZE_USERNAME`) and writes the credentials
  file as operator with umask 077.
- The worker passes the credentials, and the Plex token, to curl as a
  config on stdin (`curl -K -`). They never appear on argv (visible in
  `ps`) or in the log.

### Rotating the key

1. Generate a new key on the TVmaze dashboard; update 1Password.
2. On the server, as the admin:
   `security add-generic-password -U -s tvmaze-<host> -a <username> -w`
   (it prompts for the key).
3. `sudo app-setup/tvmaze-scrobble-setup.sh` rewrites the credentials file,
   runs `--check`, and reloads the agents.

## Deploy

1. Add `TVMAZE_USERNAME`, `PLEX_ACCOUNT_TITLE`, `PLEX_ACCOUNT_ID` and
   (optional) `TVMAZE_SCROBBLE_PORT` to `config.conf`.
2. `sudo app-setup/tvmaze-scrobble-setup.sh`. It needs msmtp-setup.sh and
   plex-watchdog-setup.sh done and operator logged in. It fails if the port
   is taken by something else, and loads nothing if `--check` (TVmaze
   `/v1/auth/validate`) fails.
3. In the Plex web app, signed in as the server owner: Settings → Webhooks
   → Add Webhook → `http://127.0.0.1:32599/plex` (the script prints it).
   Webhooks need Plex Pass.

## Checking and testing

- Credentials: `sudo -H -u operator /bin/bash ~operator/.local/bin/tvmaze-scrobble --check`
- Log: `tail -f ~operator/.local/state/tvmaze-scrobble.log`. One
  `SYNCED:` line per episode names the show, SxxEyy, which id matched, and
  the TVmaze episode id. `FAILED:` lines list the reason.
- Run reconcile now: `sudo launchctl kickstart -kp gui/$(id -u operator)/com.<host>.tvmaze-reconcile`
- Listener health: `curl -s http://127.0.0.1:32599/` prints `ok`.
- Canned payload through the listener (Plex's format is multipart; plain
  JSON is accepted too for tests like this):

  ```bash
  curl -s -H 'Content-Type: application/json' \
    --data @tests/fixtures/tvmaze-scrobble/payload-scrobble.json \
    http://127.0.0.1:32599/plex
  ```

  Edit `Account.title` to match `PLEX_ACCOUNT_TITLE` first, or it is
  ignored. This marks a real episode on TVmaze.
- A forced failure (to see the email): set `grandparentTitle` to a show
  that does not exist and `grandparentRatingKey` to `0`.
- Tests: `bats tests/tvmaze-scrobble.bats` (curl and email are stubbed).

## Environment notes

- The agents run with launchd's PATH; the worker uses absolute paths
  (`/usr/bin/curl`, `/usr/bin/jq`) and is bash 3.2 compatible. Email goes
  through `alert-lib.sh`, which finds msmtp by absolute path. See
  `monitoring.md`.
- The listener uses `/usr/bin/python3` (3.9) and the `email` package for
  multipart, not the deprecated `cgi` module. It ignores SIGCHLD so the
  workers it never waits for do not become zombies.
