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
9. Leave the remote access keys empty for now: the Cloudflare keys, `EXTERNAL_HOSTNAME`, `BASICAUTH_*` and `QUICKCONNECT_*`.

The [configuration keys reference](../reference/config-keys.md) describes every key. [Configuration](../configuration.md) has more examples.

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

Next: [Build the setup package](04-build-package.md)
