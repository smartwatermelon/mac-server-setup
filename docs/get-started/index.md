# Get started

This tutorial takes you from a spare Mac mini to the first movie that plays in Plex. Do the steps in order. Each page ends with a link to the next one.

The tutorial uses these names. Replace them with your own values.

| Name | Meaning |
| --- | --- |
| `MACMINI` | The server name (`SERVER_NAME` in config). The server is `macmini.local` on your network. |
| `admin` | The administrator account that you create on the Mac mini. |
| `operator` | The service account that setup creates. It logs in automatically and runs the media apps. |
| dev Mac | The Mac where you keep this repository and run `prep-airdrop.sh`. |

## Steps

1. [Choose your stack](01-choose-stack.md): decide which parts you install. (dev Mac)
2. [Check the prerequisites](02-prerequisites.md): get the hardware, accounts and tools ready. (dev Mac and NAS)
3. [Configure](03-configure.md): write `config/config.conf` and the 1Password items. (dev Mac)
4. [Build the setup package](04-build-package.md): run `prep-airdrop.sh`. (dev Mac)
5. [Run first boot](05-first-boot.md): run `first-boot.sh` on the Mac mini. (`admin`, at the Mac mini)
6. [Run app setup](06-run-app-setup.md): set up Plex and the other apps, right after first boot. (`admin`, at the Mac mini)
7. [Log in as operator](07-operator-login.md): restart and let the operator account log in. Plex starts. (`operator`, automatic)
8. [Verify](08-verify.md): play your first movie. (`operator`)

Package installation in step 5 takes the most time.

Next: [Choose your stack](01-choose-stack.md)
