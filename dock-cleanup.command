#!/bin/bash
#
# dock-cleanup.command - One-time dock cleanup script for operator account
#
# This script cleans up the operator's dock; requires dockutil.
# https://github.com/kcrawford/dockutil
# Double-click to run.

echo "Cleaning up dock for operator account..."

# Make sure Dock is ready to be updated
killall Dock
until pgrep Dock; do sleep 1; done

# Clean up dock, add iTerm, and restart Dock
while /opt/homebrew/bin/dockutil --find Messages; do
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
    --add /Applications/iTerm.app \
    --add /System/Applications/Passwords.app \
    2>/dev/null || true
  sleep 1
done
