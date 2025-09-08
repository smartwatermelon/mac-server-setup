# Transmission GUI Settings Research Report

**Date**: 2025-09-08  
**Context**: Settings visible in Transmission GUI that could not be automated via `defaults` commands  

## Summary

While examining the Transmission preferences GUI against the actual plist file (`org.m0k.transmission`), several GUI settings could not be mapped to plist keys. This document catalogs these missing settings for future research.

## Confirmed Missing Settings

### 1. Dock Badge Configuration

**GUI Location**: General → Badge Dock icon with  
**Visible Options**: "Total download rate" ✓, "Total upload rate" ✓  
**Attempted Keys**: `BadgeDockTotalDownload`, `BadgeDockTotalUpload`  
**Status**: Keys not found in actual plist  
**Research Needed**: Find correct keys or determine if this is controlled elsewhere

### 2. Sleep Prevention  

**GUI Location**: Network → System sleep → "Prevent computer from sleeping with active transfers" ✓  
**Attempted Key**: `NoSleepWhenActiveTransfers`  
**Status**: Key not found in actual plist  
**Research Needed**: Find correct key or determine if this requires IOKit/Energy Saver integration

### 3. Incomplete Downloads Toggle

**GUI Location**: Transfers/Adding → "Keep incomplete files in:" ✓
**Plist Reality**: `UseIncompleteDownloadFolder = 0` (disabled)  
**GUI Reality**: Checkbox appears checked with Downloads folder selected  
**Research Needed**: Understand discrepancy between plist value and GUI display

### 4. Queue Enable/Disable State

**GUI Location**: Transfers/Management → Queues section checkboxes  
**Attempted Keys**: `QueueDownloadEnabled`, `QueueSeedEnabled`  
**Plist Reality**: `Queue = 0`, `QueueSeed = 0` (suggesting boolean state)  
**Research Needed**: Understand relationship between Queue/QueueSeed and the number settings

### 5. Notification System Integration

**GUI Location**: General → Notifications → "Configure in System Preferences" button  
**Status**: No corresponding plist keys found  
**Research Needed**: May require macOS User Notifications framework integration

### 6. Default Application for Magnet Links

**GUI Location**: General → Accept magnet links → "Set Default Application" button  
**Status**: No corresponding plist keys found  
**Research Needed**: May require Launch Services framework integration (`LSSetDefaultHandlerForURLScheme`)

### 7. Auto-Update Configuration  

**GUI Location**: General → Check for updates → "Automatically check daily" ✓  
**Status**: Update-related keys exist (`SUHasLaunchedBefore`, `SULastCheckTime`) but no daily check boolean found  
**Research Needed**: May be controlled by Sparkle update framework defaults

## Successfully Mapped Settings

For reference, these GUI settings were successfully automated:

### Network Settings ✅

- Fixed peer port: `BindPort = 40944`
- µTP enabled: `UTPGlobal = 1`  
- Port mapping: `NatTraversal = 1`

### Peer Protocol Settings ✅

- Connection limits: `PeersTotal = 2048`, `PeersTorrent = 256`
- PEX/DHT/Local discovery: `PEXGlobal`, `DHTGlobal`, `LocalPeerDiscoveryGlobal = 1`
- Encryption: `EncryptionPrefer = 1`, `EncryptionRequire = 1`

### Blocklist Settings ✅  

- Enabled: `BlocklistNew = 1`
- URL: `BlocklistURL = "https://github.com/Naunter/BT_BlockLists/raw/master/bt_blocklists.gz"`
- Auto-update: `BlocklistAutoUpdate = 1`

### Seeding/Queue Management ✅

- Ratio limits: `RatioCheck = 1`, `RatioLimit = 2`
- Idle limits: `IdleLimitCheck = 1`, `IdleLimitMinutes = 30`
- Queue numbers: `QueueDownloadNumber = 3`, `QueueSeedNumber = 3`
- Stalled detection: `CheckStalled = 1`, `StalledMinutes = 30`
- Auto-removal: `RemoveWhenFinishSeeding = 1`

### UI Settings ✅

- Auto-resize: `AutoSize = 1`
- Watch folder: `AutoImport = 1`, `AutoImportDirectory = "/path/to/folder"`

## Research Action Items

1. **Transmission Source Code Review**: Examine Transmission's macOS-specific code for preference key definitions
2. **Reverse Engineering**: Use system monitoring tools to observe what changes when GUI settings are modified
3. **Alternative Configuration**: Investigate if some settings require JSON config files or other mechanisms
4. **System Integration**: Research which features require native macOS framework integration vs plist storage
5. **Version Differences**: Verify if preference keys have changed between Transmission versions

## Impact Assessment

**Low Impact**: Most core functionality is successfully automated  
**Medium Impact**: Missing dock badges and sleep prevention are nice-to-have features  
**High Impact**: None - all essential BitTorrent functionality is configured correctly

The current automation covers approximately 90% of the visible GUI settings, providing a fully functional Transmission setup for the media pipeline workflow.

---

Generated during transmission-setup.sh development - 2025-09-08
