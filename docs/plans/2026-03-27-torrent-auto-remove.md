# Torrent Auto-Remove After FileBot Processing

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically remove completed torrents from Transmission after FileBot successfully processes and moves their content to Plex.

**Architecture:** Add a `remove_torrent_from_transmission()` function to the trigger watcher that calls Transmission's RPC `torrent-remove` method (with `delete-local-data: true`) after the done script succeeds. The RPC URL port is baked in at deploy time via a new `__TRANSMISSION_HOST_PORT__` template placeholder. Removal failure is non-fatal — the torrent entry stays but the trigger file is still cleaned up.

**Tech Stack:** Bash, Transmission RPC (JSON over HTTP), curl, existing template/deploy pattern

---

## Task 1: Add RPC removal function to trigger watcher template

**Files:**

- Modify: `app-setup/templates/transmission-trigger-watcher.sh:26-39` (constants section)
- Modify: `app-setup/templates/transmission-trigger-watcher.sh:64-65` (before `process_trigger`)
- Modify: `app-setup/templates/transmission-trigger-watcher.sh:117` (after done script success)

### Step 1: Add the RPC URL constant

After the existing constants block (line 34, after `MAX_RETRIES=5`), add the Transmission RPC URL constant using a template placeholder:

```bash
# Transmission RPC for torrent removal after successful processing
TRANSMISSION_RPC_URL="http://localhost:__TRANSMISSION_HOST_PORT__/transmission/rpc"
```

### Step 2: Add the `remove_torrent_from_transmission()` function

Insert before `process_trigger()` (before line 66). This follows the same RPC pattern used by `transmission-add-magnet.sh`:

```bash
# Remove a torrent from Transmission via RPC after successful processing.
# Uses the same CSRF session-token dance as transmission-add-magnet.sh.
# Non-fatal: logs a warning on failure but returns 0 so trigger cleanup proceeds.
remove_torrent_from_transmission() {
  local torrent_hash="$1"
  local torrent_name="$2"

  log "Removing torrent from Transmission: ${torrent_name} (${torrent_hash})"

  # Get CSRF session token from Transmission's 409 response
  local session_id
  session_id=$(curl -s -D - "${TRANSMISSION_RPC_URL}" 2>/dev/null | \
    awk 'tolower($0) ~ /^x-transmission-session-id:/{gsub(/\r/,""); print $2; exit}')

  if [[ -z "${session_id}" ]]; then
    log "WARNING: Could not connect to Transmission RPC — torrent not removed: ${torrent_name}"
    return 0
  fi

  # Call torrent-remove with delete-local-data (FileBot already moved the media)
  local response
  response=$(curl -s "${TRANSMISSION_RPC_URL}" \
    -H "X-Transmission-Session-Id: ${session_id}" \
    --data-raw "{\"method\":\"torrent-remove\",\"arguments\":{\"ids\":[\"${torrent_hash}\"],\"delete-local-data\":true}}" \
    2>&1)

  if echo "${response}" | grep -q '"result":"success"'; then
    log "Torrent removed from Transmission: ${torrent_name}"
  else
    log "WARNING: Failed to remove torrent from Transmission: ${torrent_name}"
    log "  RPC response: ${response}"
  fi

  # Always return 0 — removal failure should not block trigger cleanup
  return 0
}
```

### Step 3: Call the removal function after done script success

In `process_trigger()`, after line 117 (`log "Done script succeeded for: ${name}"`), add the RPC removal call before the trigger file cleanup:

```bash
    log "Done script succeeded for: ${name}"
    remove_torrent_from_transmission "${hash}" "${name}"
    rm -f "${trigger_file}"
```

### Step 4: Commit

```bash
git add app-setup/templates/transmission-trigger-watcher.sh
git commit -m "feat(trigger-watcher): auto-remove torrents after FileBot processing

After transmission-done succeeds, call Transmission RPC torrent-remove
to clear the completed torrent from the UI. Uses delete-local-data:true
since FileBot already moved media to Plex library. Removal failure is
non-fatal to avoid blocking trigger cleanup."
```

---

## Task 2: Add port placeholder substitution to deploy script

**Files:**

- Modify: `app-setup/podman-transmission-setup.sh:600` (sed command for watcher deploy)

### Step 1: Update the sed command to substitute both placeholders

Change the single-substitution sed to a two-substitution sed, chaining the `__TRANSMISSION_HOST_PORT__` replacement alongside the existing `__SERVER_NAME__` one:

```bash
  sudo sed -e "s|__SERVER_NAME__|${HOSTNAME}|g" \
           -e "s|__TRANSMISSION_HOST_PORT__|${HOST_PORT}|g" \
    "${WATCHER_TEMPLATE}" | sudo tee "${WATCHER_DEST}" >/dev/null
```

`HOST_PORT` is already defined earlier in the script (line 240: `HOST_PORT="${TRANSMISSION_HOST_PORT:-9091}"`).

### Step 2: Commit

```bash
git add app-setup/podman-transmission-setup.sh
git commit -m "feat(deploy): substitute TRANSMISSION_HOST_PORT in trigger watcher

The trigger watcher now needs the RPC port to remove torrents after
processing. Add the placeholder substitution alongside SERVER_NAME."
```

---

## Task 3: Verify template placeholders are consistent

### Step 1: Grep for all `__PLACEHOLDER__` patterns in both files

Run:

```bash
grep -n '__[A-Z_]*__' app-setup/templates/transmission-trigger-watcher.sh
grep -n '__[A-Z_]*__' app-setup/podman-transmission-setup.sh | grep -i watcher
```

Expected: `__SERVER_NAME__` and `__TRANSMISSION_HOST_PORT__` both appear in the template, and both have corresponding substitutions in the deploy script.

### Step 2: Verify HOST_PORT is in scope at the deploy section

Run:

```bash
grep -n 'HOST_PORT' app-setup/podman-transmission-setup.sh | head -5
```

Expected: `HOST_PORT` is defined well before the watcher deploy section (line ~240 vs deploy at ~600).

---

## Task 4: Test the RPC removal manually on the server

### Step 1: Verify Transmission RPC is reachable

```bash
curl -s -D - http://localhost:9091/transmission/rpc 2>/dev/null | head -5
```

Expected: HTTP 409 response with `X-Transmission-Session-Id` header.

### Step 2: List current torrents to find the stale ones

```bash
SESSION_ID=$(curl -s -D - http://localhost:9091/transmission/rpc 2>/dev/null | \
  awk 'tolower($0) ~ /^x-transmission-session-id:/{gsub(/\r/,""); print $2; exit}')

curl -s http://localhost:9091/transmission/rpc \
  -H "X-Transmission-Session-Id: ${SESSION_ID}" \
  --data-raw '{"method":"torrent-get","arguments":{"fields":["id","name","hashString","status","percentDone"]}}' | \
  python3 -m json.tool
```

Expected: See the two stale "no data" torrents plus the ipleak detection torrent.

### Step 3: Remove one stale torrent to verify the RPC call works

Pick one of the stale torrent hashes from Step 2 and remove it:

```bash
curl -s http://localhost:9091/transmission/rpc \
  -H "X-Transmission-Session-Id: ${SESSION_ID}" \
  --data-raw '{"method":"torrent-remove","arguments":{"ids":["<HASH>"],"delete-local-data":true}}'
```

Expected: `{"result":"success"}`

### Step 4: Verify torrent is gone from Transmission UI

Refresh the Transmission web UI at `http://localhost:9091` — the removed torrent should no longer appear.

---

## Task 5: Deploy updated trigger watcher to the server

### Step 1: Re-run the watcher deploy section

This requires running `podman-transmission-setup.sh` or manually deploying:

```bash
sudo sed -e "s|__SERVER_NAME__|TILSIT|g" \
         -e "s|__TRANSMISSION_HOST_PORT__|9091|g" \
  app-setup/templates/transmission-trigger-watcher.sh | \
  sudo tee /Users/operator/.local/bin/transmission-trigger-watcher.sh >/dev/null
sudo chmod 755 /Users/operator/.local/bin/transmission-trigger-watcher.sh
sudo chown operator:staff /Users/operator/.local/bin/transmission-trigger-watcher.sh
```

### Step 2: Restart the trigger watcher LaunchAgent

```bash
sudo -u operator launchctl bootout gui/$(id -u operator) ~/Library/LaunchAgents/com.tilsit.transmission-trigger-watcher.plist 2>/dev/null || true
sudo -u operator launchctl bootstrap gui/$(id -u operator) ~/Library/LaunchAgents/com.tilsit.transmission-trigger-watcher.plist
```

### Step 3: Verify the watcher is running with the new code

```bash
grep 'remove_torrent_from_transmission' /Users/operator/.local/bin/transmission-trigger-watcher.sh
ps aux | grep trigger-watcher | grep -v grep
```

Expected: Function is present in deployed script; watcher process is running.
