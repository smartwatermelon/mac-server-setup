#!/bin/bash
#
# dock-cleanup.command - One-time dock cleanup script for operator account
#
# This script cleans up the operator's dock and then deletes itself.
# Double-click to run.

echo "Cleaning up dock for operator account..."

# Clean up dock, add iTerm, and restart Dock
/opt/homebrew/bin/dockutil \
  --remove Messages \
  --remove Mail \
  --remove Maps \
  --remove Photos \
  --remove FaceTime \
  --remove Calendar \
  --remove Contacts \
  --remove Reminders \
  --remove Freeform \
  --remove TV \
  --remove Music \
  --remove News \
  --remove 'iPhone Mirroring' \
  --remove /System/Applications/Utilities/Terminal.app \
  --add /Applications/iTerm.app
