<!-- markdownlint-disable MD013 -->

# Stack matrix

This project was built for one server. This page tells you which parts you
need, which you can skip, and which you can replace with your own choice.

Status key:

- **Required**: setup does not work without it.
- **Optional**: you can leave it out. The table says how.
- **Replaceable**: the project uses one product, but you can change it. Expect
  to edit scripts, not only config.

## How setup handles a part you skip

Read this before the table.

`app-setup/run-app-setup.sh` runs every `*-setup.sh` script in `app-setup/`.
It does not read config to decide which ones to run. Most optional scripts
exit with an error when their config keys are empty, and the run stops at
the first error.

To skip a part, choose one:

1. Run only the scripts you want: `./run-app-setup.sh --only plex-setup.sh`.
2. Run everything with `--continue-on-error`, and ignore the failures of the
   parts you skipped.

A config switch per part does not exist yet.

## Base system

`prep-airdrop.sh` runs on your dev Mac. `scripts/server/first-boot.sh` runs
on the new Mac Mini.

| Part | Status | Config keys | Notes | Docs |
| --- | --- | --- | --- | --- |
| Apple Silicon Mac Mini | Required | `SERVER_NAME`, `OPERATOR_USERNAME`, `HOSTNAME_OVERRIDE` | Another Mac can work, but only the Mac Mini is tested. | [Prerequisites](prerequisites.md) |
| 1Password CLI | Replaceable, with work | `ONEPASSWORD_VAULT`, `ONEPASSWORD_*_ITEM` | `prep-airdrop.sh` reads every credential from 1Password with `op`. It creates the operator item if it is missing. To use another password manager, edit `prep-airdrop.sh`. | [Keychain credential management](keychain-credential-management.md) |
| Operator account | Required | `OPERATOR_USERNAME`, `ONEPASSWORD_OPERATOR_ITEM` | The service account that runs the media apps. | [Operator](operator.md) |
| Time Machine backup | Optional | `ONEPASSWORD_TIMEMACHINE_ITEM` | If the 1Password item is missing, prep prints a warning and skips it. | [Prerequisites](prerequisites.md) |
| Apple ID | Optional | `ONEPASSWORD_APPLEID_ITEM` | Prep looks for the item among 1Password favorites. | [Prerequisites](prerequisites.md) |
| Terminal profile, iTerm2 | Optional | `TERMINAL_PROFILE_FILE`, `USE_ITERM2` | Leave both empty or `false` to skip. | No doc yet |
| Homebrew packages | Required | `config/formulae.txt`, `config/casks.txt` | Edit the lists to add or remove packages. | [Configure](get-started/03-configure.md) |

## Media apps

Scripts are listed in the order `run-app-setup.sh` runs them.

| Part | Status | Config keys | Notes | Docs |
| --- | --- | --- | --- | --- |
| NAS with an NFS share | Required | `NAS_HOSTNAME`, `NAS_USERNAME`, `NAS_SHARE_NAME`, `NAS_VOLUME`, `ONEPASSWORD_PLEX_NAS_ITEM` | Plex and Transmission both use the share. The mount path is `<NAS_HOSTNAME>:/<NAS_VOLUME>/<NAS_SHARE_NAME>`, which is how Synology exports a share. Another NAS works if its export path fits that shape. | [Plex setup](components/plex.md) |
| rclone + Dropbox | Optional | `DROPBOX_SYNC_FOLDER`, `DROPBOX_LOCAL_PATH`, `DROPBOX_SYNC_INTERVAL` | Syncs `.torrent` files to the watch folder. Not needed when Catch uses magnet links (`CATCH_USE_MAGNETS="true"`). `rclone-setup.sh` exits with an error when `DROPBOX_SYNC_FOLDER` is empty. | [rclone setup](components/rclone.md) |
| Transmission in Podman | Required for downloads | `LAN_SUBNET`, `TRANSMISSION_HOST_PORT` | Runs the `haugene/transmission-openvpn` container in a Podman VM. | [Transmission + FileBot](components/transmission-filebot.md) |
| PIA VPN | Replaceable, with work | `ONEPASSWORD_PIA_ITEM`, `PIA_VPN_REGION` | `OPENVPN_PROVIDER=PIA` is fixed in `podman-transmission-setup.sh`. The port-forwarding probe, guard and watchdog work with PIA only. The container supports other providers, but this project does not set them up. | [PIA VPN](components/pia-vpn.md) |
| FileBot | Required for library sorting | `FILEBOT_LICENSE_FILE`, `ONEPASSWORD_OPENSUBTITLES_ITEM` | Renames finished downloads and moves them into the Plex library. FileBot needs a paid license. If the license file is missing, setup only warns. OpenSubtitles login is skipped when its credentials are missing. | [Transmission + FileBot](components/transmission-filebot.md) |
| Catch (RSS) | Optional | `CATCH_FEEDS_URL`, `CATCH_HISTORY_CUTOFF_DAYS`, `CATCH_USE_MAGNETS` | Gets new episodes from a feed such as ShowRSS. With no feed URL, Catch installs and starts with no feeds. | No doc yet |
| Plex Media Server | Required | `NAS_*`, `PLEX_MIGRATE_FROM` | `PLEX_MIGRATE_FROM` is optional. It copies an existing Plex server's data. | [Plex setup](components/plex.md) |

## Remote access

| Part | Status | Config keys | Notes | Docs |
| --- | --- | --- | --- | --- |
| Caddy reverse proxy | Optional | `EXTERNAL_HOSTNAME`, `SERVER_LAN_IP`, `BASICAUTH_USERNAME`, `BASICAUTH_HASH` | Gives HTTPS on the LAN and a dashboard. `caddy-setup.sh` exits with an error when any of these four keys is empty. It also needs a Cloudflare API token in the keychain for DNS-01 certificates. | [Caddy](components/caddy.md) |
| Cloudflare domain | Required by Caddy, DDNS and Tunnel | `EXTERNAL_HOSTNAME`, `CLOUDFLARE_ZONE_ID` | A domain whose DNS is on Cloudflare. | [Caddy](components/caddy.md) |
| Cloudflare DDNS | Optional | `CLOUDFLARE_ZONE_ID`, `CLOUDFLARE_RECORD_ID`, `DDNS_RECORD_NAME` | Keeps one DNS record on your home IP. Needed only for the home VPN. | [Cloudflare DDNS](components/cloudflare-ddns.md) |
| Cloudflare Tunnel + Access | Optional | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_TUNNEL_ID`, `CLOUDFLARE_ACCESS_*`, `ACCESS_ALLOWED_EMAIL`, `TUNNEL_METRICS_PORT` | Lets you reach the server from outside without opening a port. Its watchdogs need msmtp. | [Cloudflare Tunnel](components/cloudflare-tunnel.md) |
| Home VPN | Optional | (none in this repo) | Runs on the NAS (Synology VPN Server), not on the Mac Mini. It needs Cloudflare DDNS to keep its hostname on your home IP. | [Home VPN](components/home-vpn.md) |
| Synology QuickConnect links | Optional | `QUICKCONNECT_ROMANO`, `QUICKCONNECT_BERKSWELL` | Dashboard links to two named NAS units on the original server. Leave them empty. | [Caddy](components/caddy.md) |

## Monitoring and extras

| Part | Status | Config keys | Notes | Docs |
| --- | --- | --- | --- | --- |
| msmtp alert email | Optional, but the watchdogs need it | `MONITORING_EMAIL` | Sends through Gmail (`smtp.gmail.com`) with a Gmail App Password. For another mail provider, edit `msmtp-setup.sh`. | [Monitoring](components/monitoring.md) |
| Plex watchdog | Optional | `MONITORING_EMAIL` | Needs msmtp. | [Plex watchdog](components/plex-watchdog.md) |
| Transmission watchdogs | Installed with Transmission | (none) | The PIA port watchdog and the stall watchdog. They need msmtp to send email. | [Monitoring](components/monitoring.md) |
| Stable signing | Installed with auto-updates | (none) | Keeps macOS privacy grants for Homebrew binaries after each upgrade. | [Stable signing](components/stable-signing.md) |
| TVmaze scrobble | Optional | `TVMAZE_USERNAME`, `PLEX_ACCOUNT_TITLE`, `PLEX_ACCOUNT_ID`, `TVMAZE_SCROBBLE_PORT` | Marks Plex plays as watched on TVmaze. `tvmaze-scrobble-setup.sh` exits with an error when the username keys are empty. | [TVmaze scrobble](components/tvmaze-scrobble.md) |
| Backblaze | Optional | (none) | Installed as a Homebrew cask. You sign in by hand. | No doc yet |

## Values to change in the template

`config/config.conf.template` has some values from the original server. Change
these before your first run:

- `OP_VAULT_ID`: the original owner's 1Password vault ID. Use your own vault ID
  or vault name.
- `PIA_VPN_REGION`: picked for a server in the Pacific Northwest. Choose a
  region near you that supports port forwarding.
- `QUICKCONNECT_ROMANO`, `QUICKCONNECT_BERKSWELL`: leave empty.
