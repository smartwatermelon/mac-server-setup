# 1. Choose your stack

Goal: decide which parts of the stack you install, before you write any config.

## Steps

1. Read the [stack matrix](../stack-matrix.md). It lists each part as required, optional or replaceable.
2. Start with the minimum path. This tutorial installs only these parts:
    - an Apple Silicon Mac mini
    - 1Password and the 1Password CLI, on the dev Mac
    - the `operator` account
    - a NAS with an NFS share that holds your media
    - Plex Media Server
3. Write down each optional part that you want later, for example Transmission with PIA VPN, FileBot, Catch, Caddy or Cloudflare Tunnel. Step 6 shows how to add each part.
4. Read "How setup handles a part you skip" in the [stack matrix](../stack-matrix.md). It explains why step 6 runs one script at a time.

!!! note
    `run-app-setup.sh` has no config switch for each part. It runs every `*-setup.sh` script in `app-setup/` unless you use `--only`. Most optional scripts stop with an error when their config keys are empty.

## Check

You have a list of the parts that you want. The list includes at least the five parts in step 2.

Next: [Check the prerequisites](02-prerequisites.md)
