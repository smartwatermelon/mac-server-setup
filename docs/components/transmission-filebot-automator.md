# Creating MediaProcessor.app Automator Droplet

This guide walks you through creating a drag-and-drop Automator application for processing media files.

## Prerequisites

- macOS with Automator (pre-installed on all Macs)
- This repository cloned (adjust the path in the script below to match your clone location)

## Step-by-Step Instructions

### 1. Open Automator

1. Press `⌘ + Space` to open Spotlight
2. Type "Automator" and press Enter
3. Automator will launch

### 2. Create New Application

1. In the template chooser, select **"Application"**
2. Click "Choose"

### 3. Configure Workflow

1. In the left sidebar, search for **"Run Shell Script"**
2. Drag **"Run Shell Script"** to the workflow area
3. Configure the action:
   - **Shell**: `/bin/bash`
   - **Pass input**: `as arguments`

4. Replace the default script content with:

```bash
#!/bin/bash

# Change to your mac-server-setup clone directory
REPO_DIR="${HOME}/Developer/mac-server-setup"
cd "${REPO_DIR}/app-setup/templates" || exit 1

# Process each dropped item
for media_dir in "$@"; do
    # Validate it's a directory
    if [[ ! -d "${media_dir}" ]]; then
        name=$(/usr/bin/printf '%s' "${media_dir}" | /usr/bin/sed "s/[\"\\\\]/\\\\&/g")
        osascript -e "display notification \"${name} is not a directory\" with title \"Media Processor\" sound name \"Basso\""
        continue
    fi

    # Export variables for compatibility with transmission-done.sh
    export TR_TORRENT_DIR="${media_dir}"
    export TR_TORRENT_NAME
    TR_TORRENT_NAME="$(basename "${media_dir}")"

    # Log the processing
    echo "Processing: ${media_dir}"

    # Run the main script
    safe_name=$(/usr/bin/printf '%s' "${TR_TORRENT_NAME}" | /usr/bin/sed "s/[\"\\\\]/\\\\&/g")
    if ./transmission-done.sh; then
        osascript -e "display notification \"Successfully processed ${safe_name}\" with title \"Media Processor\" sound name \"Glass\""
    else
        osascript -e "display notification \"Failed to process ${safe_name}\" with title \"Media Processor\" sound name \"Basso\""
    fi
done
```

### 4. Save the Application

1. Press `⌘ + S` or go to File → Save
2. **Save As**: `MediaProcessor`
3. **Where**: Choose your preferred location (recommended: `~/Applications/` or Desktop)
4. **File Format**: Should already be set to "Application"
5. Click "Save"

### 5. Test the Application

1. Find a test media directory (or create a dummy one)
2. Drag and drop the directory onto `MediaProcessor.app`
3. The app should:
   - Show a folder picker if you don't drag anything
   - Process the media files
   - Show a notification when complete
   - Play a sound (Glass for success, Basso for failure)

## Usage

### Drag-and-Drop Mode

1. Drag a folder containing media files onto `MediaProcessor.app`
2. The app will process all media files in that folder
3. You'll receive a notification when complete

### Double-Click Mode

1. Double-click `MediaProcessor.app`
2. A folder picker dialog will appear
3. Select the folder containing media files
4. The app will process the files
5. You'll receive a notification when complete

## Troubleshooting

### "MediaProcessor.app can't be opened"

This security warning may appear on first run:

1. Right-click (or Control-click) on `MediaProcessor.app`
2. Select "Open" from the context menu
3. Click "Open" in the security dialog
4. This only needs to be done once

### No notifications appearing

1. Open System Settings → Notifications
2. Find "Script Editor" or "Automator" in the list
3. Enable notifications for that application

### Script fails to run

1. Check that the path in the script matches your repository location
2. Verify `transmission-done.sh` is executable: `chmod +x transmission-done.sh`
3. Check Console.app for error messages

## Advanced: Creating App Icon

To add a custom icon to your Automator app:

1. Find or create an `.icns` file
2. Right-click `MediaProcessor.app` → "Get Info"
3. Drag your icon file onto the small icon in the top-left of the Info window
4. Close the Info window

## Additional Notes

- The app runs in manual mode (uses `prompt_for_directory()` if no items dropped)
- All processing logs are written to the configured log file
- The app inherits your user environment, so FileBot and other tools must be in your PATH
- Notifications use native macOS notification system
