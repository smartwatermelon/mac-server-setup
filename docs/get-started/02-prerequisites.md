# 2. Check the prerequisites

Goal: have the hardware, network, accounts and tools that setup needs, before you configure anything.

## Steps

1. Get an Apple Silicon Mac mini that you can erase. Connect a display, a keyboard and a network cable. `first-boot.sh` must run in a local desktop session, not over SSH.
2. Get a dev Mac with an administrator account. You run `prep-airdrop.sh` there. If you choose script-based Wi-Fi setup, the script reads the current Wi-Fi password from the System keychain, and macOS asks for an administrator password.
3. Make sure that the dev Mac has [Homebrew](https://brew.sh). The next steps use `brew install`.
4. On the dev Mac, install the 1Password CLI:

    ```bash
    brew install 1password-cli
    ```

5. Make sure that `jq` is on the dev Mac. If this command prints nothing, run `brew install jq`:

    ```bash
    command -v jq
    ```

    `openssl` comes with macOS. `prep-airdrop.sh` uses it to make a random operator password when the operator item is not in 1Password yet.

6. Make sure that the dev Mac has an Ed25519 SSH key. `prep-airdrop.sh` reads only `~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`. If the key does not exist, create it:

    ```bash
    ls ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -C "you@example.com"
    ```

    Also make sure that `~/.ssh/known_hosts` exists. `prep-airdrop.sh` runs `ssh-keygen -R`, which fails when the file is missing, and the script then stops:

    ```bash
    touch ~/.ssh/known_hosts
    ```

6. Clone this repository on the dev Mac:

    ```bash
    git clone https://github.com/smartwatermelon/mac-server-setup.git
    ```

7. On the NAS, export the media share over NFS to the Mac mini. Setup mounts `<NAS_HOSTNAME>:/<NAS_VOLUME>/<NAS_SHARE_NAME>`. The host mount uses the `resvport` option, so the NAS can require a reserved port. The Transmission VM (optional) needs the export to allow non-privileged ports.
8. Put at least one movie file on the share. Step 8 plays it.
9. Create a free Plex account at plex.tv, if you do not have one. You sign in to it in step 8.

## Check

1. `op --version` prints a version number on the dev Mac.
2. `showmount -e nas.local` on the dev Mac lists your share. Replace `nas.local` with your NAS hostname.
3. The movie file is on the share.
4. The SSH files exist on the dev Mac:

    ```bash
    ls ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub ~/.ssh/known_hosts
    ```

To see which parts you need, read the [stack matrix](../reference/stack-matrix.md). You check `config/config.conf` and the 1Password items in [Configure](03-configure.md).

Next: [Configure](03-configure.md)
