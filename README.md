# Mac Mini M2 Server Setup

This repository contains automated setup scripts for configuring a Mac Mini M2 as a home server with containerized applications.

## Overview

These scripts provide a comprehensive setup for a Mac Mini M2 server named TILSIT, focusing on:

- Base system configuration
- User account setup (admin and non-admin)
- Network optimization for server use
- NAS integration for media storage
- Container runtime setup (Docker with Colima)

## Usage

Refer to the documentation for detailed setup instructions and usage guidelines.

### Quick Start

For first-time setup, use Apple Configurator 2.18 to bootstrap the system, then run:

```bash
curl -L https://raw.githubusercontent.com/smartwatermelon/mac-server-setup/main/bootstrap.sh | bash
```

This will download and execute the bootstrap script, which will:
1. Install necessary dependencies
2. Clone this repository
3. Begin the automated setup process

## Repository Structure

```
mac-server-setup/
├── bootstrap.sh              # Initial bootstrap script
├── setup.sh                  # Main setup orchestration script
├── test_harness.sh           # Test harness for validation and rollback
├── config.yaml               # Central configuration file
└── scripts/
    ├── initial_setup.sh      # System configuration script
    ├── networking_setup.sh   # Network and remote access setup
    └── nas_setup.sh          # NAS mount configuration
```

## Configuration

All configurable settings are stored in `config.yaml`. Edit this file to match your specific requirements before running the setup scripts.

## License

Private repository - All rights reserved
