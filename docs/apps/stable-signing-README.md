# Stable Signing: TCC Grants That Survive `brew upgrade`

**Files**: `app-setup/templates/stable-sign.sh`,
`scripts/server/setup-auto-updates.sh` (deploys it and hooks it into the daily
brew upgrade), `app-setup/podman-transmission-setup.sh` (puts the stable mirror
first in the supervisor's PATH), `tests/stable-sign.bats`,
`tests/podman-machine-start.bats`

**Deployed**: `/usr/local/bin/<hostname>-stable-sign.sh`, mirror tree under
`/usr/local/stable/<formula>/`, signing identity `"<HOSTNAME> Local Code
Signing"` in `/Library/Keychains/System.keychain`

## The problem

After every reboot or container recreate, macOS showed the operator desktop a
dialog: *"podman-remote" would like to access files on a network volume.* The
`podman-transmission-vm` supervisor blocked on it. On 2026-09-03 a routine
container recreate at 08:51 stalled until someone clicked Allow at 09:26.
Adding `podman-remote` to Full Disk Access did not help.

### Why the prompt exists

The Podman VM shares `/Users/operator/.local/mnt/<share>` (an NFS mount) into
the container over VirtioFS. The VirtioFS I/O is performed by Apple's
`com.apple.Virtualization.VirtualMachine` XPC service. When that service opens
a file on a network volume, macOS Tahoe checks the
`kTCCServiceSystemPolicyNetworkVolumes` privacy grant. XPC services are not
their own TCC client. macOS attributes the access to the *responsible
process*, and the rule observed on TILSIT is: **the first non-Apple binary
below the LaunchAgent's `/bin/bash`**. Everything under it inherits.

For the podman supervisor that chain is `timeout` (coreutils `gtimeout`)
-> `podman-remote` -> `vfkit`. Before the bounded-timeout change (2026-08-25)
the responsible binary was `podman-remote`, which is why the TCC database
holds one row per podman version. With only podman mirrored, the first
restart on 2026-09-03 prompted for `gtimeout` instead. LaunchAgents that run
Homebrew `bash` directly get a row for `bash` for the same reason. So every
Homebrew binary on the path from the LaunchAgent to the protected access
needs a stable copy.

### Why the grant keeps disappearing

A TCC row is keyed on two things:

| Column   | Value for a Homebrew binary                                |
| -------- | ---------------------------------------------------------- |
| `client` | Resolved path: `.../Cellar/podman/6.1.1/bin/podman-remote` |
| `csreq`  | Requirement derived from the signature: `cdhash H"..."`    |

Homebrew binaries are only ad-hoc linker-signed with the generic identifier
`a.out`, so the only requirement macOS can derive is the binary's cdhash.
Both the path and the cdhash change with every release. The daily brew
upgrade LaunchDaemon (04:30) therefore silently invalidates the grant, and the
next VM start or container recreate re-prompts.

### Why Full Disk Access did not help

FDA (`kTCCServiceSystemPolicyAllFiles`) is a different service in a different
database. It does not cover network volumes on Tahoe. Also, the entry was
added by the `/opt/homebrew/bin/podman-remote` symlink path, and TCC resolves
symlinks: the stored client path still pointed at the versioned Cellar path.

### What was verified before building this

All four rows below were measured on TILSIT on 2026-09-03, not inferred:
experiments with a tiny C program (`nvtest`) that opens a file on the NFS
mount from a LaunchAgent (rows 1 to 3, each cycled more than once), plus
re-signing the live `podman-remote` while its VM was running (row 4: one more
prompt appeared on the next access):

| Change                                                 | Prompts again? |
| ------------------------------------------------------ | -------------- |
| Rebuild ad-hoc binary at the same path                 | yes (cdhash)   |
| Self-signed identity + fixed identifier, same path     | no             |
| Same signature, copy to a different path               | yes (path)     |
| Re-sign the binary a running VM is responsible for     | once, then no  |
| Mirror podman only; `timeout` still from the Cellar    | yes (gtimeout) |

Signing with a self-signed identity changes the stored requirement to

```text
identifier "<id>" and certificate root = H"<cert sha1>"
```

which does not depend on the binary's contents. Combined with a fixed path,
the grant matches forever.

## The fix

`stable-sign.sh` keeps a *stable mirror* of each configured formula:

1. Drop the `.source-version` stamp, then `rsync -a --checksum --delete`
   `${HOMEBREW_PREFIX}/opt/<formula>/bin/` and `libexec/` into
   `/usr/local/stable/<formula>/`. The `opt/` link is Homebrew's
   version-independent pointer, so this always tracks the current release.
   `--checksum` matters because signing on a copy preserves the mtime, so
   rsync's size+mtime quick-check could otherwise leave a tampered stable
   copy in place. The relative `podman -> podman-remote` symlink is
   preserved (bare `podman` in the supervisor executes the signed file
   through it), and podman finds vfkit/gvproxy at `../libexec/podman`
   relative to itself.
2. Re-sign the binaries named in `STABLE_TARGETS` with the local identity
   and identifier `local.<hostname>.stable.<bin>`. The signing happens on a
   temp copy that is then `mv`'d over the original, so a running process
   keeps its old inode.
3. Verify with `codesign -v -R=<requirement>` and write
   `.source-version` (the `opt/` link target) so later runs are no-ops until
   Homebrew moves the link.

Consumers put `/usr/local/stable/<formula>/bin` ahead of `/opt/homebrew/bin`
in PATH. For Podman that is the `export PATH=` line of
`podman-machine-start.sh`, which lists the podman and coreutils mirrors.
Both `timeout` and `podman` are executed through Homebrew's own symlinks
(`timeout -> gtimeout`, `podman -> podman-remote`), so the kernel runs the
signed file and TCC keys on its path.

**Never signed**: vfkit (carries the `com.apple.security.virtualization`
entitlement, which `codesign -f` without `--entitlements` would strip) and
gvproxy. They are mirrored unchanged.

### The signing identity

Created headlessly on first run:

```bash
openssl req -x509 -newkey rsa:2048 -days 3650 ... -config cs.cnf  # EKU codeSigning
openssl pkcs12 -export ... -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -macalg sha1
sudo security import id.p12 -k /Library/Keychains/System.keychain \
  -T /usr/bin/codesign
```

Notes learned the hard way:

- OpenSSL 3's default PKCS#12 encryption is unreadable by `security import`
  ("MAC verification failed"). The legacy algorithms above work.
- `-T /usr/bin/codesign` is what lets codesign use the key without a GUI
  prompt from a LaunchDaemon. No `add-trusted-cert` or partition-list change
  is needed. `security find-identity -v` hides the identity as untrusted;
  codesign signs with it anyway, and TCC matches on the certificate hash, not
  on trust.
- The certificate is valid for 10 years (until 2036). Nothing warns before
  expiry; rotating it changes the requirement and costs exactly one
  re-prompt per binary.
- **The identity is a stable label, not a trust boundary.** The `-T
  /usr/bin/codesign` ACL applies to any local user, so the operator account
  can sign a binary that satisfies the exact requirement (verified). What
  keeps a forged binary from inheriting the grant is that TCC also keys on
  the path, and `/usr/local/stable` is writable only by the administrator.
  That is no weaker than the Homebrew binaries it replaces, whose ad-hoc
  cdhash anyone can produce, but do not read the signature as
  authentication.

## Operations

```bash
# State of every target; exit 1 if anything is stale. Also lists every
# other entry in bin/: symlinks with their target, and unsigned files.
/usr/local/bin/tilsit-stable-sign.sh --check

# Did the daily upgrade job's stable-sign step fail?
grep -E 'stable-sign|ERROR' ~/.local/state/tilsit-brew-upgrade.log | tail

# Refresh after a manual brew upgrade (the daily daemon does this itself)
/usr/local/bin/tilsit-stable-sign.sh

# Confirm the grant is keyed on the stable path and identity
sudo sqlite3 /Users/operator/Library/Application\ Support/com.apple.TCC/TCC.db \
  "select client, auth_value from access where service='kTCCServiceSystemPolicyNetworkVolumes'"
```

Expected once adopted: one final prompt for
`/usr/local/stable/coreutils/bin/gtimeout` (the responsible binary), then
none, across brew upgrades and reboots. Which binary the prompt names is the
quickest way to find the responsible process when a new one appears: the
row it leaves in the TCC database (query above) is the path to mirror.

### Adding another binary

Append `"<formula>:<bin>[,<bin>]"` to `STABLE_TARGETS` in the template,
redeploy with `scripts/setup-auto-updates.sh --force`, and make the consumer
use `/usr/local/stable/<formula>/bin/<bin>`. Check the whole process chain
from the LaunchAgent down: the first non-Apple binary is the one that needs
the stable copy, not the one that opens the file. Candidates: Homebrew `bash`
used by LaunchAgents that touch the NFS mount (currently covered by an FDA
grant on `/bin/bash`; see the note in `transmission-filebot-README.md`).

### Cleanup after adoption

Old TCC rows for the Cellar paths are harmless but can be removed in System
Settings > Privacy & Security > Files and Folders. The FDA entry for
`podman-remote` does nothing and can go too.

## Test architecture

`tests/stable-sign.bats` renders the template with test placeholders and runs
it against a fake Homebrew tree. `codesign`, `security` and `sudo` are mocked;
the codesign mock stores the identifier and certificate *inside* the file so
they travel with the bytes through the temp-copy-and-mv, exactly like a real
signature. `rsync` and `openssl` are real. `tests/podman-machine-start.bats`
checks the supervisor's PATH order and that a podman placed in the stable
directory is the one the loop executes.
