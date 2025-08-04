# First Boot Instructions

The `first-boot.sh` script performs complete automated setup of your Mac Mini server after the macOS Setup Wizard is complete.

## Before You Begin

### Complete macOS Setup Wizard

1. **Connect power and peripherals** to Mac Mini
2. **Follow macOS Setup Wizard** completely
3. **Create your admin account** (this becomes the primary administrator)
4. **Complete Apple ID setup** if prompted, or skip to do later
5. **Reach the desktop** before proceeding

### Transfer Setup Files

1. **AirDrop the complete tilsit-setup folder** from your development Mac
2. The folder appears in `~/Downloads/tilsit-setup` on the Mac Mini
3. **Do not run the script yet** - read the sections below first

## Understanding the Setup Process

The script performs these major configuration steps:

**System Security**: TouchID sudo, SSH access, firewall configuration
**User Management**: Operator account creation, automatic login setup  
**Network Configuration**: WiFi connection, hostname setting
**Power Management**: Server-optimized power settings
**Package Installation**: Homebrew, essential tools and applications
**Application Preparation**: Setup directory structure for containerized apps

## Running First Boot Setup

### Standard Setup

```bash
cd ~/Downloads/tilsit-setup/scripts
chmod +x first-boot.sh
./first-boot.sh
```

The script runs interactively, prompting for confirmation at key steps.

### Command Line Options

**Force Mode** (skip all prompts):
```bash
./first-boot.sh --force
```

**Skip Software Updates** (faster setup):
```bash
./first-boot.sh --skip-update
```

**Skip Package Installation**:
```bash
./first-boot.sh --skip-homebrew --skip-packages
```

**Combination Example**:
```bash
./first-boot.sh --force --skip-update
```

## Critical Setup Steps

### SSH Access Configuration

The script enables SSH and configures key-based authentication. If you see a **Full Disk Access** prompt:

1. **System Settings opens** to the Full Disk Access section
2. **Finder opens** showing Terminal.app in Applications/Utilities
3. **Drag Terminal** from Finder into the Full Disk Access list
4. **Close this Terminal window completely**
5. **Open a new Terminal window** and re-run the script

> **Why This Happens**: macOS requires explicit permission for Terminal to modify system SSH settings.

### Apple ID Configuration  

If Apple ID wasn't configured during Setup Wizard:

1. **One-time password link opens** in your browser (from 1Password)
2. **Copy your Apple ID password** before it expires
3. **System Settings opens** to Apple ID section
4. **Enter credentials** and complete verification steps
5. **Return to Terminal** when finished

The script waits for you to complete Apple ID setup before continuing.

### WiFi Network Setup

**If using Migration Assistant WiFi**: No action needed - already configured.

**If using script-based WiFi**: The script automatically connects using transferred credentials.

**If manual WiFi needed**: System Settings opens to WiFi section for manual configuration.

## Monitoring Setup Progress

### Log Window

The script automatically opens a second Terminal window showing live setup logs:

```
[2025-08-04 10:30:15] ====== Starting Mac Mini M2 'TILSIT' Server Setup ======
[2025-08-04 10:30:16] Running as user: admin
[2025-08-04 10:30:16] ✅ TouchID sudo configuration
[2025-08-04 10:30:18] ✅ SSH has been enabled successfully
```

**Keep this window open** to monitor progress and troubleshoot issues.

### Setup Phases

**Phase 1**: System configuration (5-10 minutes)
- TouchID, SSH, hostname, power settings

**Phase 2**: Package installation (15-30 minutes)  
- Xcode Command Line Tools, Homebrew, packages

**Phase 3**: Application preparation (2-5 minutes)
- Directory setup, dock cleanup, final configuration

## Expected Prompts and Interactions

### Password Prompts

**TouchID Sudo Setup**: Enter your admin password to configure TouchID authentication.

**SSH Configuration**: May require admin password for system modifications.

**Package Installation**: Sudo prompts for Homebrew and system package installation.

### User Confirmations

**WiFi Configuration**: Confirm network setup if manual configuration needed.

**Apple ID Setup**: Confirm when Apple ID configuration is complete.

**Reboot Decision**: Choose whether to reboot immediately after setup.

## Post-Setup Verification

### Test SSH Access

From your development Mac:
```bash
# Test admin access
ssh admin@tilsit.local

# Test operator access (after reboot)
ssh operator@tilsit.local
```

### Verify Services

**Homebrew Installation**:
```bash
brew --version
which brew
```

**TouchID Sudo**:
```bash
sudo -k  # Clear sudo cache
sudo echo "TouchID test"  # Should prompt for TouchID
```

### Check Logs

Setup logs are saved to `~/.local/state/tilsit-setup.log`:
```bash
tail -f ~/.local/state/tilsit-setup.log
```

## Troubleshooting

### Script Fails with "Safety Abort"

This means you're trying to run the script on your development Mac instead of the Mac Mini:
- **Solution**: Transfer files to Mac Mini via AirDrop and run there

### SSH Enable Fails

**Error**: "Could not enable remote login"
- **Cause**: Full Disk Access not granted to Terminal
- **Solution**: Follow the Full Disk Access steps above

### Homebrew Installation Hangs

**Symptoms**: No progress during Homebrew installation
- **Solution**: Check internet connectivity, try manual installation:
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

### Package Installation Failures

**Individual packages fail**: This is normal - the script continues with other packages
- **Review**: Check `brew doctor` output in logs for issues
- **Retry**: Run `brew install <package-name>` manually later

### Apple ID Verification Issues

**Two-factor authentication prompts**: Use your iPhone/iPad to approve verification codes
- **Backup codes**: Have your Apple ID backup codes ready if needed
- **Timeout**: The one-time password link expires - generate a new one from 1Password

### Time Machine Configuration Fails

**Invalid credentials**: Verify 1Password Time Machine item has correct URL and credentials
- **Network access**: Ensure Mac Mini can reach your NAS/backup server
- **SMB version**: Some older NAS devices require SMB version adjustments

## Next Steps

After successful first boot setup:

1. **Reboot the system** (recommended)
2. **Login as operator** (automatic after reboot)
3. **Follow [Operator Setup Instructions](operator-setup.md)**
4. **Run application setup scripts** in `~/app-setup/`

The Mac Mini is now ready for containerized application deployment and service configuration.