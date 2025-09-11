#!/usr/bin/env bash
#
# start-plex.sh - Simple Plex Media Server launcher
#
# This script simply launches Plex Media Server. The SMB mount is handled
# independently by a separate LaunchAgent that runs every 2 minutes.
#
# Author: Claude
# Version: 2.0 (Simplified)
# Created: 2025-08-21

set -euo pipefail

# Launch Plex Media Server using macOS open command
# This properly integrates with macOS and handles all startup requirements
open "/Applications/Plex Media Server.app"
