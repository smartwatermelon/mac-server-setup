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
> **Title**: "TILSIT operator" (or as configured in `config.conf`)
> 
> **Username**: operator
> 
> **Password**: Auto-generated secure password

The script will create this item automatically if it doesn't exist, but you can create it manually with your preferred password.

#### Time Machine Backup Credentials

> **Item Type**: Login  
> 
> **Title**: "PECORINO DS-413 - TimeMachine" (or as configured)
> 
> **Username**: Your NAS/backup server username
> 
> **Password**: Your NAS/backup server password
> 
> **URL**: `smb://your-nas-ip/TimeMachine` (or appropriate backup URL)

#### Apple ID Credentials

> **Item Type**: Login
> 
> **Title**: "Apple" (or as configured)
> 
> **Username**: Your Apple ID email
> 
> **Password**: Your Apple ID password

### TouchID Sudo (Optional)

If you want TouchID sudo on the Mac Mini, first enable it on your development Mac:

```bash
./create-touchid-sudo.sh
```

This creates `/etc/pam.d/sudo_local` which will be copied to the Mac Mini during setup.

## Running AirDrop Prep

### Basic Usage

```bash
./airdrop-prep.sh
```

This creates a `tilsit-setup` directory in your home folder with all necessary files.

### Custom Output Path

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

```
tilsit-setup/
├── ssh_keys/
│   ├── authorized_keys           # Admin SSH access
│   └── operator_authorized_keys  # Operator SSH access
├── scripts/
│   ├── first-boot.sh            # Main setup script
│   └── app-setup/               # Application installers
├── lists/
│   ├── formulae.txt             # Homebrew packages
│   └── casks.txt                # Homebrew applications
├── pam.d/
│   └── sudo_local               # TouchID sudo config
├── wifi/
│   └── network.conf             # WiFi credentials (if applicable)
├── URLs/
│   └── apple_id_password.url    # One-time Apple ID link
├── operator_password            # Operator account password
├── timemachine.conf            # Backup configuration
├── config.conf                 # Server settings
├── dev_fingerprint.conf        # Safety check data
├── dock-cleanup.command        # Operator dock script
└── README.md                   # Setup instructions
```

## Security Features

**Development Machine Fingerprint**: Prevents accidental execution of setup scripts on your development Mac.

**Credential Encryption**: Sensitive data is stored with restrictive permissions (600).

**One-time URLs**: Apple ID password uses 1Password's view-once sharing feature.

**SSH Key Isolation**: Separate key files for admin and operator accounts.

## Transfer to Mac Mini

1. **Complete macOS Setup Wizard** on the Mac Mini first
2. **AirDrop the entire tilsit-setup folder** from your development Mac
3. The folder will appear in `~/Downloads/tilsit-setup` on the Mac Mini
4. Proceed with [First Boot Instructions](first-boot.md)

## Troubleshooting

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

The script needs administrator access to retrieve WiFi passwords:
- Enter your Mac's administrator password when prompted
- Ensure you're running as an administrator user

### 1Password Item Not Found

Check that item titles exactly match your `config.conf` settings:
```bash
# List items in vault
op item list --vault "personal"

# Check specific item
op item get "TILSIT operator" --vault "personal"
```

### TouchID Sudo Missing

If you want TouchID sudo but the prep script reports it's missing:
```bash
# Check if file exists
ls -la /etc/pam.d/sudo_local

# Create it if needed
./create-touchid-sudo.sh
```