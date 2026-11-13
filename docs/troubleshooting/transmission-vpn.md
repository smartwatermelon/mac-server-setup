# Transmission and VPN problems

This page covers the `transmission-vm` Podman machine, the `transmission-vpn` container, the PIA VPN tunnel, port forwarding, and the container's access to the NAS through VirtioFS. Run the checks as `admin` on the server. The Podman machine belongs to `operator`, so every `podman` command runs through `sudo -iu operator`.

For how these parts work, see [Transmission and FileBot](../apps/transmission-filebot-README.md), [PIA VPN](../apps/pia-vpn-README.md), [Storage and VirtioFS](../explanation/storage-virtiofs.md) and [Stable signing](../apps/stable-signing-README.md).

How the stack is supervised: the LaunchAgent `com.<hostname>.podman-transmission-vm` runs `~/.local/bin/podman-machine-start.sh` in the `operator` account. The script never exits. It waits up to 120 seconds for the NAS mount, starts the VM, creates the container, and then checks both every 300 seconds. If the container is not running, it removes it and runs it again. If `/data/` in the container cannot be read 3 times in a row, it stops the container and the VM and starts both again. The host NAS mount is not touched.

The supervisor logs to `~/.local/state/<hostname>-podman-vm-stdout.log` and `-stderr.log`, and writes `~/.local/state/<hostname>-supervisor-status.json` once per cycle.

## Transmission web UI does not load

**Cause**

1. The supervisor is not running, for example because `operator` is not logged in.
2. The supervisor stopped at startup. It exits when the NAS mount is not there after 120 seconds, or when `timeout` from coreutils is missing. launchd starts it again after 30 seconds.
3. The VM or the container failed to start, and the supervisor retries each cycle.
4. A `podman` command hung. The supervisor kills it after 60 seconds (180 seconds for machine commands) and retries on the next cycle.

**Check**

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 http://127.0.0.1:9091/transmission/web/
sudo launchctl print gui/$(id -u operator)/com.<hostname>.podman-transmission-vm | grep -E 'state|last exit|runs'
sudo -iu operator podman machine list
sudo -iu operator podman ps -a --filter name=transmission-vpn
sudo tail -30 /Users/operator/.local/state/<hostname>-podman-vm-stdout.log
sudo cat /Users/operator/.local/state/<hostname>-supervisor-status.json
```

- `200` from `curl` means Transmission answers on loopback. If the browser still fails, the problem is in Caddy. See [Remote access](remote-access.md).
- A healthy supervisor shows `state = running` and has never exited. A `last exit code` with a low `runs` count and `state = not running` means it stopped.
- In the supervisor log, `FATAL: NFS mount not available` means the NAS mount is missing. `FATAL: timeout(1) not found` means coreutils is missing. `TIMEOUT: 'podman ...' exceeded` means a podman command hung. `ensure_machine failed` or `ensure_container failed` names the step that failed.
- In the status file, `consecutive_failures` counts failed cycles, and `updated_at` is the time of the last cycle in epoch seconds.

**Fix**

1. If `operator` is not logged in, restart the Mac mini.
2. If the NAS mount is missing, fix it first. See [Plex libraries are empty or files show as unavailable](plex.md#plex-libraries-are-empty-or-files-show-as-unavailable).
3. If coreutils is missing, install it with `brew install coreutils`.
4. If the supervisor is not running, restart it:

    ```bash
    sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.podman-transmission-vm
    ```

5. If the container is missing or stopped, wait up to 5 minutes. The supervisor creates it again on its next cycle.
6. If the log shows a privacy prompt or the supervisor waits with no new lines, look at the desktop. See [A privacy prompt blocks the server](monitoring.md#a-privacy-prompt-blocks-the-server).

## The VPN does not connect

**Cause**

1. PIA rejects the account password. This happens after a password change at PIA that did not reach the server.
2. `PIA_VPN_REGION` names an OpenVPN config that the image does not have. The image region names are not always the same as the PIA API region names. With an unknown name the container prints its config list and exits.

**Check**

```bash
sudo -iu operator podman logs --tail 100 transmission-vpn | grep -iE 'AUTH_FAILED|error|config'
sudo -iu operator podman exec transmission-vpn curl -s --max-time 10 ifconfig.io
sudo -iu operator podman inspect transmission-vpn --format '{{.State.Health.Status}}'
```

- `AUTH_FAILED`, with the tunnel connecting again and again, means a wrong password.
- An address from `curl` means the tunnel is up and traffic leaves through PIA.
- `unhealthy` means the web UI health check failed 3 times. Podman restarts the container when that happens.

**Fix**

For a wrong password:

1. Update the password at PIA and in 1Password.
2. Update the `admin` login keychain on the server. Leave the value after `-w` empty, so that `security` asks for it. Enter `username:password`:

    ```bash
    security add-generic-password -U -s "pia-account-<hostname>" -a "<hostname>" -w
    ```

3. Run `podman-transmission-setup.sh` again from `~/app-setup` as `admin`. It reads the keychain, writes `~operator/containers/transmission/.env` at mode 600, and creates the container again.
4. Restart the supervisor as described in [A change to .env or to the podman run options has no effect](#a-change-to-env-or-to-the-podman-run-options-has-no-effect).

For a wrong region:

1. List the region names that the image knows. This starts a short-lived container:

    ```bash
    sudo -iu operator podman run --rm docker.io/haugene/transmission-openvpn:latest ls /etc/openvpn/pia/
    ```

2. Set `PIA_VPN_REGION` in `config.conf` to a name from the list, without the `.ovpn` suffix.
3. Do steps 3 and 4 above.

A `podman restart` is not enough in either case. The container reads `.env` and its `-e` options only when it is created.

## New torrents do not start, or stay at 0 percent

**Cause**

PIA port forwarding is lost. Downloads that are already running continue more slowly, but with no reachable peer port, tracker announces fail and magnet links cannot get their metadata. Causes include:

1. The region does not serve port forwarding. PIA's `port_forward` flag in its server list is not reliable.
2. PIA's token endpoint fails. On 2026-10-12 the legacy endpoint returned HTTP 500 for over an hour. The port forwarding manager now tries the v2 endpoint first.
3. PIA did not issue a port. The port guard then keeps the old port and logs `REFUSING to apply invalid port forwarding result`.

`pia-port-watchdog` emails `Transmission port forwarding lost` after 3 bad checks in a row, 15 minutes apart.

**Check**

Read the peer port and ask Transmission whether the port is open:

```bash
rpc=http://127.0.0.1:9091/transmission/rpc
sid=$(curl -s -D - "${rpc}" | awk 'tolower($0) ~ /^x-transmission-session-id:/{gsub(/\r/,""); print $2; exit}')
curl -s "${rpc}" -H "X-Transmission-Session-Id: ${sid}" \
  --data-raw '{"method":"session-get","arguments":{"fields":["peer-port"]}}'; echo
curl -s "${rpc}" -H "X-Transmission-Session-Id: ${sid}" --data-raw '{"method":"port-test"}'; echo
```

- `"peer-port":0` means no port is set.
- `"port-is-open":false` means a port is set, but nothing outside can reach it.

Then read the manager's own log lines and the watchdog log:

```bash
sudo -iu operator podman logs --tail 200 transmission-vpn | grep 'pia-port'
sudo tail -20 /Users/operator/.local/state/<hostname>-pia-port-watchdog.log
```

`Token request (v2) failed` or `returned no token` lines carry the HTTP status and PIA's message.

**Fix**

1. If the token requests fail with HTTP 5xx, wait. The manager retries on its own, and the guard keeps the existing port in the meantime.
2. If the region serves no port forwarding, test other regions with the probe. It runs in its own container and does not touch the live one:

    ```bash
    sudo -iu operator /Users/operator/containers/transmission/scripts/pia-pf-probe.sh
    sudo -iu operator /Users/operator/containers/transmission/scripts/pia-pf-probe.sh ca_vancouver netherlands
    ```

3. Set `PIA_VPN_REGION` in `config.conf` to a region that returned a port. Then run `podman-transmission-setup.sh` again and restart the supervisor, as in [A change to .env or to the podman run options has no effect](#a-change-to-env-or-to-the-podman-run-options-has-no-effect).
4. After the change, check `port-is-open` again, and add a well-seeded test torrent.

## Transmission reports Permission denied, or /data is empty in the container

**Cause**

The container reads the NAS through VirtioFS, from the host mount at `/Users/operator/.local/mnt/<share>`. VirtioFS access can fail while the host mount still works:

1. The host mount is missing, so `/data` in the container is an empty folder.
2. The Virtualization framework service has no Full Disk Access. It can `stat()` files on the NAS but not list folders. Cached handles can hide this for days.
3. A macOS privacy prompt "would like to access files on a network volume" is open. This happens after a `brew upgrade` when the supervisor runs a podman or gtimeout copy that is not the stably-signed one.

**Check**

```bash
mount -t nfs
sudo -iu operator podman exec transmission-vpn ls /data/
sudo grep -E 'inaccessible|RECOVERY|restored' /Users/operator/.local/state/<hostname>-podman-vm-stdout.log | tail -10
/usr/local/bin/<hostname>-stable-sign.sh --check
```

- `Operation not permitted` from `ls`, while the host mount is listed, points to cause 2 or 3.
- `WARNING: /data/ inaccessible inside container (failure n/3)` lines show the supervisor's count. `RECOVERY: cycling VM` shows it cycled the VM.
- `--check` exits 1 if a stably-signed copy is stale.

**Fix**

1. Fix the host mount first, if it is missing. See [Plex libraries are empty or files show as unavailable](plex.md#plex-libraries-are-empty-or-files-show-as-unavailable).
2. Look at the desktop for a privacy prompt and click Allow.
3. If `--check` reports a stale copy, run the stable-sign script to refresh it:

    ```bash
    /usr/local/bin/<hostname>-stable-sign.sh
    ```

4. If the cause is Full Disk Access, add this binary in System Settings, Privacy and Security, Full Disk Access:

    ```text
    /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
    ```

5. Wait for the supervisor. After 3 failed checks (about 15 minutes) it stops the container and the VM and starts both again, which gives VirtioFS fresh handles.
6. To cycle the VM now, stop the supervisor, stop the machine, and load the supervisor again. The supervisor stops any leftover `gvproxy` or `vfkit` helpers before it starts the machine:

    ```bash
    sudo launchctl bootout gui/$(id -u operator)/com.<hostname>.podman-transmission-vm
    sudo -iu operator podman machine stop transmission-vm
    sudo launchctl bootstrap gui/$(id -u operator) \
      /Users/operator/Library/LaunchAgents/com.<hostname>.podman-transmission-vm.plist
    ```

Do not unmount the host NAS share to fix this. Plex reads from it. Cycle only the VM and the container.

## A change to .env or to the podman run options has no effect

**Cause**

The container gets its `.env` and its `-e` options when it is created. `podman restart` does not read them again. The supervisor also keeps the `podman run` options that it read when it started. If the supervisor is not restarted after a change, the next container that it creates gets the old options.

**Check**

Compare the live container with the deployed files:

```bash
sudo -iu operator podman inspect transmission-vpn \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | sort
sudo grep -E '^[[:space:]]+-e ' /Users/operator/.local/bin/podman-machine-start.sh
```

A value in the wrapper that is not in the live environment means that the container must be created again.

**Fix**

1. Make sure that nothing important is downloading.
2. Run `podman-transmission-setup.sh` again from `~/app-setup` as `admin`. It writes `.env` and the wrapper, and creates the container again.
3. Restart the supervisor so that it reads the new wrapper:

    ```bash
    sudo launchctl kickstart -kp gui/$(id -u operator)/com.<hostname>.podman-transmission-vm
    ```

    Expect a short interruption. If the VM stops, the new supervisor starts it again.

4. Check the live environment again with `podman inspect`.
5. Expect a new forwarded port. Check `port-is-open` as in [New torrents do not start, or stay at 0 percent](#new-torrents-do-not-start-or-stay-at-0-percent).

## The supervisor log shows TIMEOUT lines again and again

**Cause**

A `brew upgrade` replaced the podman CLI, but the running VM and its helper processes are from the old version. A helper that outlived its machine can hold the machine's socket paths, and new podman commands then hang. The supervisor kills each hung command and retries, but it cannot fix a version mismatch on its own.

**Check**

```bash
sudo grep -E 'TIMEOUT|stale machine helpers' /Users/operator/.local/state/<hostname>-podman-vm-stdout.log | tail -10
pgrep -fl 'gvproxy|vfkit'
sudo -iu operator podman version
```

`podman version` shows the client and server versions. Different versions, or helpers whose command line names `transmission-vm` while the machine is stopped, confirm the cause.

**Fix**

1. Cycle the VM with the `bootout`, `podman machine stop` and `bootstrap` steps in [Transmission reports Permission denied, or /data is empty in the container](#transmission-reports-permission-denied-or-data-is-empty-in-the-container).
2. Check the supervisor log for `entering supervision loop` and no new `TIMEOUT` lines.

## Completed downloads disappear from pending-move

**Cause**

The container writes downloads straight into `Media/Torrents/pending-move/` on the NAS. The incomplete folder is off on purpose. With it on, Transmission renames finished files from one folder to another across VirtioFS and the soft NFS mount. VirtioFS can report that rename as a success while NFS fails it, and the file is lost from both folders.

**Check**

```bash
sudo -iu operator podman inspect transmission-vpn \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'INCOMPLETE_DIR|DOWNLOAD_DIR'
```

The output must show `TRANSMISSION_INCOMPLETE_DIR_ENABLED=false` and `TRANSMISSION_DOWNLOAD_DIR=/data/Media/Torrents/pending-move`.

**Fix**

1. Do not turn on the incomplete folder, in the web UI or in the `podman run` options.
2. If the values are wrong, run `podman-transmission-setup.sh` again and restart the supervisor, as in [A change to .env or to the podman run options has no effect](#a-change-to-env-or-to-the-podman-run-options-has-no-effect).

For files that the hourly cleanup removed, see [Media pipeline](media-pipeline.md#a-download-was-deleted-from-pending-move-before-it-was-processed).
