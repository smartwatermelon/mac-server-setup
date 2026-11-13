# 3. Configure

Goal: write `config/config.conf` and the 1Password items that `prep-airdrop.sh` reads.

Do all steps on the dev Mac, in the root of your clone.

## Steps

1. Copy the template:

    ```bash
    cp config/config.conf.template config/config.conf
    ```

2. Sign in to 1Password and find your vault ID:

    ```bash
    op signin
    op vault list
    ```

3. In `config/config.conf`, set the server name and the vault:

    ```bash
    SERVER_NAME="MACMINI"
    OPERATOR_USERNAME="operator"
    OP_VAULT_ID="your-vault-id"
    ```

4. In that vault, create these Login items. The item titles must match the `ONEPASSWORD_*_ITEM` values in your config. Change the values or the titles so that they agree.
    - `ONEPASSWORD_OPERATOR_ITEM`: the operator password. If the item does not exist, `prep-airdrop.sh` creates it with a random password.
    - `ONEPASSWORD_PLEX_NAS_ITEM`: the NAS username and password. Put the NAS hostname in the item's first URL field.
    - `ONEPASSWORD_APPLEID_ITEM`: the Apple Account for the server. Mark this item as a favorite. `prep-airdrop.sh` searches only favorite Login items for it.
    - `ONEPASSWORD_TIMEMACHINE_ITEM` (optional): the Time Machine share username and password, with the share URL in the first URL field.
    - `ONEPASSWORD_OPENSUBTITLES_ITEM` (optional): the OpenSubtitles account for FileBot.
5. Set the NAS keys. The export path that `showmount -e` printed in the prerequisites check must be `/<NAS_VOLUME>/<NAS_SHARE_NAME>`:

    ```bash
    NAS_HOSTNAME="nas.local"
    NAS_USERNAME="plex"
    NAS_SHARE_NAME="Media"
    NAS_VOLUME="volume2"
    ```

6. Set the alert address:

    ```bash
    MONITORING_EMAIL="you@example.com"
    ```

7. Set the LAN keys, even if you do not install Transmission or Caddy now:

    ```bash
    LAN_SUBNET="192.168.20.0/22"
    SERVER_LAN_IP="192.168.21.10"
    ```

8. If you want Transmission later, create a PIA Login item and set `ONEPASSWORD_PIA_ITEM` to its title. Set `PIA_VPN_REGION` to a region near you that supports port forwarding. `prep-airdrop.sh` copies the PIA credentials only when this key is set, and `podman-transmission-setup.sh` stops without them.
9. Leave the remote access keys empty for now: the Cloudflare keys, `EXTERNAL_HOSTNAME`, `BASICAUTH_*` and `HOME_LINK*`.
10. Optional: edit the Homebrew lists, `config/formulae.txt` and `config/casks.txt`. Put one formula or cask on each line. `setup-package-installation.sh` skips blank lines and lines that start with `#`. Do not remove an entry that a component needs. For example, `podman-transmission-setup.sh` needs `timeout` from `coreutils`.

The [configuration keys reference](../reference/config-keys.md) describes every key.

Set every key in `config/config.conf`, not in your shell. `prep-airdrop.sh`, `first-boot.sh` and each app setup script source the file, so a key in the file replaces a value that you exported. This includes `FILEBOT_LICENSE_FILE`, the `DROPBOX_*` keys, `USE_ITERM2` and `TERMINAL_PROFILE_FILE`.

## Check

1. The file has no syntax errors and has your values:

    ```bash
    bash -n config/config.conf && (source config/config.conf && echo "${SERVER_NAME} ${ONEPASSWORD_VAULT}")
    ```

2. 1Password finds each item. Run this for each item title:

    ```bash
    (source config/config.conf && op item get "${ONEPASSWORD_PLEX_NAS_ITEM}" --vault "${ONEPASSWORD_VAULT}" --fields username)
    ```

3. The Apple item is a favorite. This command prints its ID:

    ```bash
    (source config/config.conf && op item list --categories Login --vault "${ONEPASSWORD_VAULT}" --favorite --format=json | jq -r --arg t "${ONEPASSWORD_APPLEID_ITEM}" '.[] | select(.title == $t) | .id')
    ```

## More than one server

`SERVER_NAME` names the package folder (`~/<server name>-setup`, lowercased) and the keychain services in the package, so each server needs its own value. Keep one config file for each server, and copy the right one into place before you run `prep-airdrop.sh`:

```bash
cp ~/server-configs/mediaserver.conf config/config.conf
./prep-airdrop.sh
```

Give each server its own 1Password items, or point the `ONEPASSWORD_*_ITEM` keys at shared ones. To give a server a network name that differs from `SERVER_NAME`, set `HOSTNAME_OVERRIDE`.

## Keep a copy of your config

Git ignores `config/config.conf`, so a fresh clone does not have it. Keep a copy in a private place, for example a private repository or a 1Password secure note. With that file and the 1Password items, you can build the package again and set up a new or rebuilt server from the start. Keep a backup of the dev Mac SSH key too: the package installs it on the server.

Next: [Build the setup package](04-build-package.md)
