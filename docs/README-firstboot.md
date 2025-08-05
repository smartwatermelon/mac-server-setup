# Server Setup Files

This directory contains all the necessary files for setting up the Mac Mini M2 server.

## Contents

- `ssh_keys/`: SSH public keys for secure remote access
- `scripts/`: Setup scripts for the server
- `lists/`: Homebrew formulae and casks lists
- `pam.d/`: TouchID sudo configuration
- `URLs/`: Internet shortcuts used by Setup
- `wifi/`: WiFi network configuration
- `operator_password`: Operator account password
- `timemachine.conf` : Configuration information for Time Machine
- `config.conf`: Server configuration settings

## Setup Instructions

1. Complete the macOS setup wizard on the Mac Mini
2. AirDrop this entire folder to the Mac Mini (it will be placed in Downloads)
3. Open Terminal and run:

   ```bash
   cd ~/Downloads/${SERVER_NAME_LOWER}-setup/scripts
   chmod +x first-boot.sh
   ./first-boot.sh
   ```

4. Follow the on-screen instructions

For detailed instructions, refer to the complete runbook.

## Notes

- The operator account password is retrieved from 1Password using configured credentials
- After setup, you can access the server via SSH using the admin or operator account
- TouchID sudo will be enabled if the configuration file was available during preparation
- WiFi will be configured automatically using the saved network information
