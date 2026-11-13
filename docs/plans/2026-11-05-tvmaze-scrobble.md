# Plex → TVmaze watched sync (issue #167)

Date: 2026-11-05. Status: approved design, implemented (reconcile added the same day).

## Goal

When Andrew finishes a TV episode in Plex on TILSIT, mark the same episode
watched on his TVmaze account. Failures email him.

## Verified facts (2026-11-05)

- The Plex server has Plex Pass (`myPlexSubscription: True`), so webhooks are available.
  The webhook URL is set by hand in the Plex web app (Settings → Webhooks, account level).
- TVmaze auth: HTTP Basic, username `admin`, password = API key. The account is
  free (`GET /v1/auth/validate` → `{"premium":0}`).
- `POST /v1/scrobble/shows?thetvdb_id=298905` with body
  `[{"season":16,"episode":10,"type":0,"marked_at":<epoch>}]` returned 200 on the
  free account. Response is a JSON array of `{code, result|errors, input}`;
  HTTP 200 = all marked, 207 = partial, 422 = none.
- `/scrobble/shows` accepts `tvmaze_id`, `thetvdb_id`, or `imdb_id` (query) plus
  `season`+`episode` or `airdate` (body). It does not accept TMDB ids.
- Show-level GUIDs come from `GET /library/metadata/<grandparentRatingKey>`
  (`Guid[].id`: `tvdb://N`, `imdb://ttN`, `tmdb://N`). Some shows have only
  `tmdb://` (The Great British Bake Off, key 22096). Taskmaster (11208) has all three.
- API key is in the admin keychain: service `tvmaze-tilsit`, account `admin`.
  Source of truth: `op://<vault>/<item>/API Key`.
- `/usr/bin/python3` is 3.9.6 (no `cgi` removal issue, but do not rely on `cgi`);
  `/usr/bin/jq` exists. LaunchAgents run `/bin/bash` 3.2.

## Design decisions (Andrew, 2026-11-05)

1. Show matching order: TVDB id → IMDb id → TVmaze exact-title search. Fall
   through to the next step when an id is missing OR TVmaze reports no match.
   Title fallback scrobbles only when exactly one TVmaze show's name equals the
   Plex title (case-insensitive, trimmed); otherwise skip.
2. Any episode that cannot be synced (no match, TVmaze error, network error)
   is logged and emailed, one email per episode, via `alert-lib.sh`
   `alert_send`. Batching is a possible later change, not now.
3. Only Andrew's Plex plays sync. His sister's account plays are ignored.
4. (Added 2026-11-05) Plex does not resend webhooks, so an hourly reconcile
   pass over Plex watch history syncs plays missed while the listener was
   down. See "Reconcile" below.

## Architecture

```
Plex Media Server --POST multipart (payload=JSON)--> 127.0.0.1:<port>
  tvmaze-scrobble-listener.py   (thin: parse, filter, hand off, always 200)
      | stdin: payload JSON
      v
  tvmaze-scrobble.sh            (all logic: Plex GUID lookup, TVmaze calls,
                                 logging, alert email; BATS-tested)
```

- **Listener** (`app-setup/templates/tvmaze-scrobble-listener.py`, `/usr/bin/python3`,
  stdlib only). Binds `127.0.0.1` only. Parses `multipart/form-data` with the
  `email` package (not `cgi`). Field `payload` is JSON. Accepts only
  `event == "media.scrobble"` and `Metadata.type == "episode"`; everything else
  → 200 and ignored. Runs the worker as a subprocess with the payload JSON on
  stdin, without waiting for it to finish (Plex must get a fast 200). Logs one
  line per accepted event.
- **Worker** (`app-setup/templates/tvmaze-scrobble.sh`, bash 3.2 compatible).
  Steps:
  1. Read payload from stdin with jq. Check `Account.title` equals
     `__PLEX_ACCOUNT_TITLE__` (placeholder, set at deploy). If not, exit 0 silently.
     (Plex's webhook `Account.id` is a plex.tv id, not the server-local
     `accountID` seen in history, so filter on title. Log the id too, so it
     can be switched later.)
  2. Read `grandparentTitle`, `grandparentRatingKey`, `parentIndex` (season),
     `index` (episode), `lastViewedAt` if present (else now).
  3. `GET http://127.0.0.1:32400/library/metadata/<grandparentRatingKey>` with
     the Plex token (read from the existing
     `/Users/operator/.config/plex-watchdog/token`, path a placeholder/variable),
     `Accept: application/json`; extract `tvdb://` and `imdb://` ids.
  4. Try `POST /v1/scrobble/shows?thetvdb_id=…`, then `?imdb_id=…`, then title:
     `GET https://api.tvmaze.com/search/shows?q=<urlencoded title>`, pick the
     single exact name match, `POST /v1/scrobble/shows?tvmaze_id=…`.
     "No match" from TVmaze = HTTP 404 or a 422 whose array item has a non-200
     `code`. Network failure / 5xx / 401 = error (do not fall through on 401:
     alert immediately, the key is bad). As built, every error (no answer,
     401, 429, 5xx) stops the chain: another id would not help.
  5. Success → one log line: show, SxxEyy, which id matched, TVmaze episode_id.
     Failure → log line + `alert_send "TVmaze sync failed: <show> SxxEyy" <body>`
     where body lists every attempt and its result.
  - All external commands injected: `CURL_BIN`, `JQ_BIN`, and the alert function
    via sourcing `ALERT_LIB` path. `TEST_RUNNER=true` skips the entry point
    (same pattern as `cloudflare-ddns.sh`).
  - Credentials: `~/.config/tvmaze-scrobble/credentials` (mode 600, operator),
    one line `admin:<key>`. Passed to curl with `-K -` on stdin, never on
    argv, never logged.
- **Reconcile** (`tvmaze-scrobble.sh --reconcile`), run hourly by a second
  LaunchAgent `com.__HOSTNAME_LOWER__.tvmaze-reconcile` (StartInterval 3600,
  RunAtLoad), deployed by the same setup script.
  - Reads `GET /status/sessions/history/all?sort=viewedAt:desc&accountID=<id>`
    (plus `viewedAt>=<cutoff>`, an optimization only). History filters on the
    server-local `accountID`, config `PLEX_ACCOUNT_ID` (default 1,
    placeholder `__PLEX_ACCOUNT_ID__`), not the webhook `Account.title`.
  - Keeps rows with `type == "episode"`, that account, and `viewedAt` within
    `RECONCILE_LOOKBACK_DAYS` (default 7), filtered in jq; one row per
    ratingKey. `grandparentKey` (`/library/metadata/N`) gives the show key.
  - Syncs each episode not in the state file with the same code as the
    webhook path, 2 s apart (TVmaze rate limit).
  - State in `~/.local/state/tvmaze-scrobble/`: `synced` and `failed`, one
    episode ratingKey per line, and a `seeded` marker. The key is the
    ratingKey alone, not `ratingKey:viewedAt`: the webhook may lack
    `lastViewedAt`, and a rewatch needs no second scrobble.
  - First run (no `seeded` marker): add every episode in the window to
    `synced`, scrobble nothing, log the count, create the marker. The marker
    is separate from `synced` because a webhook play may create `synced`
    before the first reconcile run.
  - Failures: both paths email only if the key is not in `failed`, then add
    it. Later failures are logged only. Reconcile keeps retrying within the
    window.
- **LaunchAgent** `com.__HOSTNAME_LOWER__.tvmaze-scrobble` (operator, KeepAlive,
  RunAtLoad) running the listener. Log: `~/.local/state/tvmaze-scrobble.log`.
  Must set PATH / use absolute paths (see `docs/apps/monitoring-README.md`
  on launchd PATH and msmtp).
- **Setup script** `app-setup/tvmaze-scrobble-setup.sh`, modelled on
  `tunnel-watchdog-setup.sh`: sudo, reads `config.conf`, validates
  `MONITORING_EMAIL`, `TVMAZE_USERNAME`, `PLEX_ACCOUNT_TITLE`,
  `TVMAZE_SCROBBLE_PORT` (default 32599, must be free), reads the key from the
  admin keychain (`tvmaze-${HOSTNAME_LOWER}`), writes credentials file 600 owned
  by operator, substitutes placeholders, installs to `~/.local/bin`, loads the
  agent with `launchctl bootout`/`bootstrap` into `gui/<operator uid>`.
  Prints the webhook URL Andrew must add in Plex.
- **Config**: add `TVMAZE_USERNAME`, `PLEX_ACCOUNT_TITLE`, `TVMAZE_SCROBBLE_PORT`
  to the config template with comments.
- **prep-airdrop / 1Password**: the 1Password item's `username` field is the
  email, which TVmaze rejects. Do NOT read the username from 1Password; it comes
  from `TVMAZE_USERNAME` in config. If prep-airdrop gains a TVmaze step, it
  copies only the `API Key` field.
- **Docs**: `docs/apps/tvmaze-scrobble-README.md` (what it does, matching order,
  where logs are, how to set the Plex webhook, how to test with a canned
  payload, how to rotate the key) and a CLAUDE.md "Service-Specific
  Documentation" entry.

## Tests (BATS, `tests/tvmaze-scrobble.bats`)

Fully stubbed: no real network, no real email. Stub curl records its argv and
returns canned responses from `tests/fixtures/tvmaze-scrobble/`.

1. Non-matching account → no curl calls, exit 0.
2. TVDB id present and TVmaze 200 → one scrobble call with `thetvdb_id`, success log, no alert.
3. TVDB 404/422-no-match → falls to IMDb → success.
4. Only TMDB id → title search; exactly one exact match → scrobble with `tvmaze_id`.
5. Title search with zero or multiple exact matches → alert sent, subject names show and SxxEyy.
6. 401 from TVmaze → alert, no fall-through.
7. Credential never appears in curl argv or the log.
8. Listener: a canned multipart body with `media.play` is ignored; with
   `media.scrobble` + episode the worker is invoked (python test via bats,
   worker path overridden by env to a stub).
9a. Reconcile: first run seeds and scrobbles nothing; a webhook sync before
    the first run does not block the seed; already-synced episodes are
    skipped; a missed one is synced; other accounts, movies and plays older
    than the window are ignored; a failing episode emails once, then only
    logs (also across the webhook and reconcile paths).
9. Template placeholder sweep: no `__[A-Z_]*__` left after substitution in the
   setup script's rendered output (or reuse an existing sweep test).

## Deploy (human gates)

1. Andrew adds config keys to live `config.conf`; runs the setup script (sudo).
2. Andrew adds the webhook URL in Plex web → Settings → Webhooks.
3. Andrew watches the last 10% of an already-watched episode; check log for success.
4. Check the first reconcile run logged `first run, seeded N episodes` and
   scrobbled nothing.
5. Confirm one forced failure emails (e.g. run the worker with a canned payload
   for a nonexistent show).

## Out of scope

Two-way sync, retroactive history import, batching emails, the
`transmission-openvpn:latest` pin.
