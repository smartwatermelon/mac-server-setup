# AirDrop Prep Instructions

The `airdrop-prep.sh` script prepares a complete setup package on your development Mac that will be transferred to the Mac Mini for automated configuration.

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

Create these items in your 1Password vault before running the prep script:

#### Operator Account Credentials

> **Item Type**: Login
>
> **Title**: "MACMINI operator" (or as configured in `config.conf`)
>
> **Username**: operator
>
> **Password**: Auto-generated secure password

The script will create this item in 1Password automatically if it doesn't exist, but you can create it manually with your preferred password.

#### Time Machine Backup Credentials

> **Item Type**: Login  
>
> **Title**: "TimeMachine" (or as configured)
>
> **Username**: Your NAS/backup server username
>
> **Password**: Your NAS/backup server password
>
> **URL**: `smb://your-nas-ip/TimeMachine` (or appropriate backup URL)

#### Plex NAS Credentials (Optional)

> **Item Type**: Login  
>
> **Title**: "Plex NAS" (or as configured)
>
> **Username**: Your media NAS username (e.g., "plex")
>
> **Password**: Your media NAS password
>
> **URL**: `nas.local` (or your NAS hostname - optional)

If this item is not found, the Plex setup will fall back to an interactive password prompt. Note that interactive prompts display as GUI dialogs on the desktop, not in the terminal.

#### Apple ID Credentials

> **Item Type**: Login
>
> **Title**: "Apple" (or as configured)
>
> **Username**: Your Apple ID email
>
> **Password**: Your Apple ID password

## Running AirDrop Prep

### Basic Usage

```bash
./airdrop-prep.sh
```

This creates a `macmini-setup` directory in your home folder with all necessary files.

### Custom Output Path (Optional)

```bash
./airdrop-prep.sh ~/custom-setup-path
```

### WiFi Configuration Strategy

The script offers two WiFi configuration approaches:

#### Option 1: Migration Assistant (Recommended)

Select this if you plan to use Migration Assistant's iPhone/iPad option during macOS setup. This automatically transfers WiFi credentials from your iOS device.

- **Advantages**: Seamless, secure, no credential handling
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
├── ssh_keys/
│   ├── authorized_keys           # Admin SSH access
│   └── operator_authorized_keys  # Operator SSH access
├── scripts/
│   ├── first-boot.sh            # Main setup script
│   ├── operator-first-login.sh  # Operator customization (runs automatically)
│   └── app-setup/               # Application installers
├── config/
│   ├── config.conf              # Server settings
│   ├── formulae.txt             # Homebrew packages
│   ├── casks.txt                # Homebrew applications
│   ├── dev_fingerprint.conf     # Safety check data
│   ├── operator_password        # Operator account password
│   ├── timemachine.conf         # Backup configuration
│   ├── apple_id_password.url    # One-time Apple ID link
│   └── wifi_network.conf        # WiFi credentials (only if script-based config)
└── app-setup/
    ├── config/
    │   └── plex_nas.conf        # Plex NAS credentials  
    └── plex-setup.sh            # Plex setup script
└── README.md                    # Setup instructions
```

## Security Features

**Development Machine Fingerprint**: Prevents accidental execution of setup scripts on your development Mac.

**Credential Encryption**: Sensitive data is stored with restrictive permissions (600) in the `config/` directory.

**One-time URLs**: Apple ID password uses 1Password's view-once sharing feature.

**SSH Key Isolation**: Separate key files for admin and operator accounts.

**Conditional Components**: WiFi configuration is only included when using script-based WiFi configuration (not Migration Assistant).

## Transfer to Mac Mini

1. **Complete macOS Setup Wizard** on the Mac Mini first
2. **Enable AirDrop:** Press Cmd-Shift-R to open AirDrop, and select "Allow me to be discovered by: Everyone"
3. **AirDrop the entire macmini-setup folder** from your development Mac
   > You can use [airdrop-cli](https://github.com/vldmrkl/airdrop-cli) (requires Xcode) to AirDrop files from the command line!
   > Install: (`brew install --HEAD vldmrkl/formulae/airdrop-cli`)
4. The folder will appear in `~/Downloads/macmini-setup` on the Mac Mini
5. Proceed with [First Boot Instructions](first-boot.md)

## Troubleshooting

### Error Collection and Summary

The AirDrop preparation script includes comprehensive error and warning collection:

- **Real-time display**: Errors and warnings show immediately during preparation
- **End-of-preparation summary**: Consolidated review of all issues when preparation completes
- **Context tracking**: Each issue shows which preparation section it occurred in

Example summary output:
```
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
