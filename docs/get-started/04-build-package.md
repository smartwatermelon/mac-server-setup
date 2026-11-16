# 4. Build the setup package

Goal: run `prep-airdrop.sh` on the dev Mac to build the folder that you copy to the Mac mini.

## Steps

1. Open Terminal on the dev Mac and go to the root of your clone. The script copies the setup scripts from the current directory. This example assumes that you cloned into your home folder:

    ```bash
    cd ~/mac-server-setup
    ```

2. Make sure that no 1Password service account token is set. The script stops if `OP_SERVICE_ACCOUNT_TOKEN` is set:

    ```bash
    unset OP_SERVICE_ACCOUNT_TOKEN
    ```

3. Sign in to 1Password:

    ```bash
    op signin
    op whoami
    ```

4. Run the script:

    ```bash
    ./prep-airdrop.sh
    ```

5. If `~/macmini-setup` exists from an earlier run, the script asks whether to remove it. Type `y`.
6. At the Wi-Fi question, choose one:
    - Type `Y` to use Migration Assistant's iPhone or iPad option, or the wired network, on the Mac mini. No Wi-Fi credentials go into the package.
    - Type `n` to put the dev Mac's current Wi-Fi network in the package. macOS asks for an administrator password to read the Wi-Fi password from the System keychain. If the script cannot read it, the summary lists an error and the package has no Wi-Fi credentials.
7. Approve each 1Password prompt. The script reads each item and puts the credentials in an encrypted keychain file in the package.
8. Read the summary at the end. The script opens the package folder in Finder.

!!! note
    If `~/.ssh/known_hosts` exists, the script removes `macmini.local` from it, because the new server will have a new host key.

For details of each file in the package, see [AirDrop prep](prep-airdrop.md).

## Check

1. The last lines say `Setup Files Preparation Complete`. The summary lists no errors. Warnings for optional items that you did not create are expected.
2. The package has the main files:

    ```bash
    ls ~/macmini-setup/first-boot.sh ~/macmini-setup/DEPLOY_MANIFEST.txt ~/macmini-setup/config/mac-server-setup-db
    ```

3. This command lists each file that the script could not find. It prints nothing when every file is present. If it lists a file that you need, fix the cause and run the script again:

    ```bash
    grep '=MISSING' ~/macmini-setup/DEPLOY_MANIFEST.txt
    ```

Next: [Run first boot](05-first-boot.md)
