# First Boot Instructions

The `first-boot.sh` script performs complete automated setup of your Mac Mini server after the macOS Setup Wizard is complete.

## Before You Begin

### Complete macOS Setup Wizard

1. **Connect power and peripherals** to Mac Mini
2. **Follow macOS Setup Wizard** completely
   > You can use the Migration Assistant to pre-configure your WiFi network and other settings using your iPhone or iPad.
   > _Sometimes_ this will also set up your Apple Account. But it's flakey.
3. **Create your admin account** (this becomes the primary administrator)
4. **Complete Apple ID setup** if prompted, or skip to do later
   * If your Apple ID password is long and complex, you can skip doing this now and use the 1Password one-time link later on in the process.
5. **Reach the desktop** before proceeding
6. **Enable AirDrop:** Press Cmd-Shift-R to open AirDrop, and select "Allow me to be discovered by: Everyone"

### Transfer Setup Files

1. **AirDrop the complete macmini-setup folder** from your development Mac

   > You can use [airdrop-cli](https://github.com/vldmrkl/airdrop-cli) (requires Xcode) to AirDrop files from the command line!
   > Install: `brew install --HEAD vldmrkl/formulae/airdrop-cli`

2. The folder appears in `~/Downloads/macmini-setup` on the Mac Mini (default name)

3. **Do not run the first-boot script yet** - read the sections below first

## Understanding the Setup Process

The script performs these major configuration steps:

* **System Security**: TouchID sudo, SSH access, firewall configuration
* **User Management**: Operator account creation, automatic login setup
* **Network Configuration**: WiFi connection, hostname setting
* **Power Management**: Server-optimized power settings
* **Package Installation**: Homebrew, essential tools and applications
* **Application Preparation**: Setup directory structure for native applications

## Running First Boot Setup

### Standard Setup

```bash
cd ~/Downloads/macmini-setup
./first-boot.sh
```

The script runs interactively, prompting for confirmation at key steps with sensible defaults:

* **Setup operations**: Default to Yes (Y/n) - press Enter to continue
* **Error recovery**: Default to No (y/N) - requires explicit confirmation to proceed

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
4. **The Terminal window should close;** ensure all Terminal windows are closed before continuing
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

**If using script-based WiFi**: The script automatically configures your WiFi network using transferred credentials.

**If manual WiFi needed**: System Settings opens to WiFi section for manual configuration.

## Monitoring Setup Progress

### Log Window

The script automatically opens a second Terminal window showing live setup logs:

```plaintext
[2025-08-04 10:30:15] ====== Starting Mac Mini Server Setup ======
[2025-08-04 10:30:16] Running as user: admin
[2025-08-04 10:30:16] ✅ TouchID sudo configuration
[2025-08-04 10:30:18] ✅ SSH has been enabled successfully
...
```

**Keep this window open** to monitor progress and troubleshoot issues.

### Setup Phases

**Phase 1**: System configuration (5-10 minutes)

* TouchID, SSH, hostname, power settings

**Phase 2**: Package installation (15-30 minutes)

* Xcode Command Line Tools, Homebrew, packages

**Phase 3**: Application preparation (2-5 minutes)

* Directory setup for native applications, dock cleanup, final configuration

## Expected Prompts and Interactions

### Password Prompts

**TouchID Sudo Setup**: Enter your admin password to configure TouchID authentication.

**SSH Configuration**: May require admin password for system modifications.

**Package Installation**: Sudo prompts for Homebrew and system package installation.

### User Confirmations

**Setup Continuation** (Y/n): Press Enter to proceed with server configuration.

**WiFi Configuration** (Y/n): Confirm network setup if manual configuration needed - defaults to Yes.

**Apple ID Setup** (Y/n): Confirm when Apple ID configuration is complete - defaults to Yes.

**Error Recovery** (y/N): After failures, choose whether to continue - defaults to No for safety.

**Reboot Decision**: Choose whether to reboot immediately after setup.

## Post-Setup Verification

### Test SSH Access

From your development Mac:

```bash
# Test admin access
ssh admin@macmini.local

# Test operator access (after reboot)
ssh operator@macmini.local
```

### Verify Services

**Homebrew Installation**:

```bash
which brew
brew --version
brew doctor
```

**TouchID Sudo**:

```bash
sudo -k  # Clear sudo cache
sudo echo "TouchID test"  # Should prompt for TouchID
```

### Check Logs

Setup logs are saved to `~/.local/state/macmini-setup.log`:

```bash
tail -f ~/.local/state/macmini-setup.log
```

## Troubleshooting

### Error Collection and Summary

The first-boot setup script includes comprehensive error and warning collection:

* **Real-time display**: Errors and warnings show immediately during setup
* **End-of-run summary**: Consolidated review of all issues when setup completes
* **Context tracking**: Each issue shows which setup section it occurred in

Example summary output:

```bash
====== SETUP SUMMARY ======
Setup completed, but 1 error and 2 warnings occurred:

ERRORS:
  ❌ Installing Homebrew Packages: Formula installation failed: some-package

WARNINGS:
  ⚠️ Configuring SSH Access: Remote Desktop setup failed or was cancelled
  ⚠️ Setting Up Operator Account: Password verification warning

Review the full log for details: ~/.local/state/macmini-setup.log
```

This summary helps identify issues that need attention without having to scroll through the entire setup log.

### Script Fails with "Safety Abort"

This means you're trying to run the script on your development Mac instead of the Mac Mini:

* **Solution**: Transfer files to Mac Mini via AirDrop and run there

> Do you think I did this more than a few times?

### SSH Enable Fails

**Error**: "Could not enable remote login"

* **Cause**: Full Disk Access not granted to Terminal
* **Solution**: Follow the Full Disk Access steps above

### Homebrew Installation Hangs

**Symptoms**: No progress during Homebrew installation

* **Solution**: Check internet connectivity, try manual installation:

  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

  Or install the [macOS Homebrew package](https://github.com/Homebrew/brew/releases/latest).

### Package Installation Failures

**Individual packages fail**: This is not unusual - the script continues with other packages

* **Review**: Check `brew doctor` output in logs for issues
* **Retry**: Run `brew install <package-name>` manually later

### Confirmation Prompt Behavior

**Quick Setup**: Most prompts default to Yes (Y/n) - just press Enter to continue with recommended actions.

**Safety Prompts**: Error recovery prompts default to No (y/N) - type 'y' and Enter to proceed after failures.

**Force Mode**: Use `--force` flag to skip all prompts for completely unattended installation.

### Apple ID Verification Issues

**Two-factor authentication prompts**: Use your iPhone/iPad to approve verification codes

* **Backup codes**: Have your Apple ID backup codes ready if needed
* **Timeout**: The one-time password link expires - generate a new one from 1Password

### Time Machine Configuration Fails

**Invalid credentials**: Verify 1Password Time Machine item has correct URL and credentials

* **Network access**: Ensure Mac Mini can reach your NAS/backup server
* **SMB version**: Some older NAS devices require SMB version adjustments

## Next Steps

After successful first boot setup:

1. **Reboot the system** (recommended)
2. **Login as operator** (automatic after reboot)
3. **Follow [Operator Setup Instructions](operator.md)**
4. **Run application setup scripts** in `~/app-setup/`

The Mac Mini is now ready for native application deployment and service configuration.
