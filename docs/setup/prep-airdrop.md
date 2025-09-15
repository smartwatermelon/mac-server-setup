# AirDrop Prep Instructions

The `prep-airdrop.sh` script prepares a complete setup package on your development Mac that will be transferred to the Mac Mini for automated configuration.

## Prerequisites

### Required Software

**1Password CLI** must be installed and authenticated:

```bash
# Install via Homebrew
brew install 1password-cli

# Authenticate (follow prompts)
op signin
```

> A future enhancement may include a pluggable password-management subsystem (i.e. allow use of other password managers). Unfortunately, Apple has not provided an API for the new Passwords app!

**SSH Keys** must be generated on your development Mac:

```bash
# Generate SSH key pair if you don't have one
ssh-keygen -t ed25519 -C "your-email@example.com"

# Default location: ~/.ssh/id_ed25519.pub
```

### Required 1Password Items

The system uses 1Password for initial credential retrieval during setup preparation, then securely transfers credentials via macOS Keychain Services. See [Keychain-Based Credential Management](../keychain-credential-management.md) for complete details.

Create these Login items in your 1Password vault before running the prep script:

- **Operator Account**: Username and password for day-to-day server access
- **Time Machine Backup**: NAS credentials with SMB URL for backup storage
- **Plex NAS**: Media server credentials (optional - prompts if missing)
- **Apple ID**: Your Apple ID for system setup

Item titles should match your `config.conf` settings (defaults: "operator", "TimeMachine", "Plex NAS", "Apple").

## Running AirDrop Prep

### Basic Usage

```bash
./prep-airdrop.sh
```

This creates a `macmini-setup` directory in your home folder with all necessary files.

### Custom Output Path (Optional)

```bash
./prep-airdrop.sh ~/custom-setup-path
```

### WiFi Configuration Strategy

The script offers two WiFi configuration approaches:

#### Option 1: Migration Assistant (Recommended)

Select this if you plan to use Migration Assistant's iPhone/iPad option during macOS setup. This automatically transfers WiFi credentials from your iOS device.

- **Advantages**: Seamless, secure, no credential handling
   > _Sometimes_ this will also set up your Apple Account. But it's flakey.
- **Requirements**: iPhone/iPad with same iCloud account

#### Option 2: Script-based Configuration

Select this to retrieve and transfer your current WiFi credentials automatically.

- **Advantages**: Works without iOS devices
- **Requirements**: Administrator password for keychain access
- **Security**: Credentials are encrypted and removed after transfer

## What Gets Created

The prep script creates a complete setup package:

```plaintext
macmini-setup/
├── app-setup/
│   ├── catch-setup.sh
│   ├── config/
│   │   ├── dropbox_sync.conf
│   │   ├── FileBot_License_XXXXXXXX.psm
│   │   ├── plex_nas.conf        # Plex NAS hostname configuration
│   │   └── rclone.conf
│   ├── filebot-setup.sh
│   ├── plex-setup.sh
│   ├── rclone-setup.sh
│   ├── run-app-setup.sh
│   ├── templates/
│   │   ├── mount-nas-media.sh
│   │   ├── start-plex.sh
│   │   ├── start-rclone.sh
│   │   └── transmission-done.sh
│   └── transmission-setup.sh
├── bash/                        # Bash config (if configured)
├── config/
│   ├── apple_id_password.url    # One-time Apple ID link
│   ├── casks.txt                # Homebrew applications
│   ├── config.conf              # Server settings
│   ├── dev_fingerprint.conf     # Safety check data
│   ├── formulae.txt             # Homebrew packages
│   ├── com.googlecode.iterm2.plist             # iTerm2 profile/settings (optional)
│   ├── keychain_manifest.conf   # Keychain service identifiers
│   ├── logrotate.conf
│   ├── mac-server-setup-db      # External keychain file
│   ├── Orangebrew.terminal      # Terminal.app profile (optional)
│   └── timemachine.conf         # Backup configuration
├── DEPLOY_MANIFEST.txt
├── first-boot.sh                # Main setup script
├── README.md                    # Setup instructions
├── scripts/
│   ├── operator-first-login.sh  # Operator customization (runs automatically)
│   ├── setup-apple-id.sh
│   ├── setup-application-preparation.sh
│   ├── setup-bash-configuration.sh
│   ├── setup-command-line-tools.sh
│   ├── setup-dock-configuration.sh
│   ├── setup-firewall.sh
│   ├── setup-hostname-volume.sh
│   ├── setup-log-rotation.sh
│   ├── setup-package-installation.sh
│   ├── setup-power-management.sh
│   ├── setup-remote-desktop.sh
│   ├── setup-shell-configuration.sh
│   ├── setup-ssh-access.sh
│   ├── setup-system-preferences.sh
│   ├── setup-terminal-profiles.sh
│   ├── setup-timemachine.sh
│   ├── setup-touchid-sudo.sh
│   └── setup-wifi-network.sh
└── ssh_keys/
    ├── authorized_keys           # Admin SSH access
    ├── id_ed25519
    ├── id_ed25519.pub
    └── operator_authorized_keys  # Operator SSH access
```

## Security Features

**Development Machine Fingerprint**: Prevents accidental execution of setup scripts on your development Mac.

**Keychain-Based Security**: Credentials stored in encrypted external keychain file for secure transfer (see [Credential Management](../keychain-credential-management.md)).

**One-time URLs**: Apple ID password uses 1Password's view-once sharing feature.

**SSH Key Isolation**: Separate key files for admin and operator accounts.

**Conditional Components**: WiFi configuration is only included when using script-based WiFi configuration (not Migration Assistant).

## Transfer to Mac Mini

1. **Complete macOS Setup Wizard** on the Mac Mini first
2. **Enable AirDrop:** Press Cmd-Shift-R to open AirDrop, and select "Allow me to be discovered by: Everyone"
3. **AirDrop the entire macmini-setup folder** from your development Mac
   > You can use [airdrop-cli](https://github.com/vldmrkl/airdrop-cli) (requires Xcode) to AirDrop files from the command line!
   > Install: `brew install --HEAD vldmrkl/formulae/airdrop-cli`
4. The folder will appear in `~/Downloads/macmini-setup` on the Mac Mini
5. Proceed with [First Boot Instructions](first-boot.md)

## Troubleshooting

### Error Collection and Summary

The AirDrop preparation script includes comprehensive error and warning collection:

- **Real-time display**: Errors and warnings show immediately during preparation
- **End-of-preparation summary**: Consolidated review of all issues when preparation completes
- **Context tracking**: Each issue shows which preparation section it occurred in

Example summary output:

```bash
====== AIRDROP PREPARATION SUMMARY ======
Preparation completed, but 2 warnings occurred:

WARNINGS:
  ⚠️ Copying SSH Keys: SSH private key not found at ~/.ssh/id_ed25519
  ⚠️ WiFi Network Configuration: Could not detect current WiFi network

Review issues above - some warnings may be expected if optional components are missing.
```

Many warnings during preparation are expected (missing optional components), while errors indicate critical issues that need resolution.

### 1Password Authentication Issues

```bash
# Check if signed in
op whoami

# Sign in if needed
op signin

# List vaults to verify access
op vault list
```

### SSH Key Not Found Error

Verify your SSH key location matches the script's expectation:

```bash
ls -la ~/.ssh/id_ed25519.pub
```

If your key is elsewhere, edit the `SSH_KEY_PATH` variable in the script.

### WiFi Keychain Access Denied

If you aren't using the Migration Assistant to pre-configure your WiFi network, the script needs administrator access to retrieve passwords:

- Enter your Mac's administrator password when prompted
- Ensure you're running as an administrator user

### 1Password Item Not Found

Check that item titles exactly match your `config.conf` settings:

```bash
# List items in vault
op item list --vault "personal"

# Check specific item
op item get "operator" --vault "personal"
```

### TouchID Sudo Configuration

TouchID sudo setup has been moved to the first-boot setup process on the Mac Mini. You'll be prompted during first-boot.sh execution whether to enable TouchID authentication for sudo commands. No TouchID configuration is needed during the airdrop preparation phase.
