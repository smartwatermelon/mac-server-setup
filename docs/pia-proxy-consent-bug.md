# PIA macOS Proxy Consent Bug — NE Signature Lost After Reboot

## Summary

After reboot, macOS intermittently loses the Network Extension (NE) proxy consent signature for PIA's split tunnel. When `NETransparentProxyManager.saveToPreferences()` finds `existing signature (null)`, macOS presents a "Would Like to Add Proxy Configurations" dialog requiring user interaction. On a headless server, no one is present to click "Allow", so split tunnel activation is blocked indefinitely.

The consent loss is intermittent — some reboots retain the signature, others do not.

## Affected Versions

| Component | Version |
|-----------|---------|
| PIA Desktop | 3.7.0+08412 |
| macOS | Sequoia 15.3 (Build 25D125, Darwin 25.3.0) |
| Architecture | Apple Silicon (Mac Mini) |
| Device Management | Non-supervised (not enrolled via MDM/DEP) |

## Two Separate Approval Gates

PIA's split tunnel requires two distinct macOS approvals:

| Gate | Persistence | Storage |
|------|-------------|---------|
| System Extension approval | Persistent across reboots | `/Library/SystemExtensions/` |
| Proxy Configuration consent | **Unreliable** — lost intermittently | NE framework preferences |

The System Extension remains `[activated enabled]` across reboots. Only the proxy consent signature is affected.

## Root Cause

When PIA starts its split tunnel, it calls `NETransparentProxyManager.saveToPreferences()` during the `piactl proxy sync` sequence. macOS checks the existing consent signature:

- **Healthy boot:** `existing signature {0x6ccfe4...}` (20 bytes) — consent remembered, no dialog
- **Failing boot:** `existing signature (null)` — consent lost, dialog presented

With a null signature, macOS returns `NEConfigurationErrorDomain Code=10 "permission denied"`. PIA enters a retry loop (spawning multiple processes in rapid succession), each attempt failing because the dialog remains unclicked.

## Unified Log Evidence

### Failing Boot (signature null)

```text
[11:30:45.992] Saving configuration PIA Split Tunnel with existing signature (null)
[11:30:46.xxx] NEConfigurationErrorDomain Code=10 "permission denied"
[11:30:47-50]  PIA retries 4+ times, all fail with permission denied
```

Each retry gets a new config UUID because the old one was rejected. PIA processes: 558, 572, 641, 643, 665 in rapid succession.

### Healthy Boot (signature present)

```text
[11:47:xx.xxx] Saving configuration PIA Split Tunnel with existing signature {0x6ccfe4...} (20 bytes)
[11:47:xx.xxx] unchanged, not saved
```

No dialog, no retries. The extension starts normally.

### Comparison

| Attribute | Failing (11:30) | Healthy (11:47) |
|-----------|-----------------|-----------------|
| Signature | `(null)` | `{0x6ccfe4...}` (20 bytes) |
| Save result | `permission denied` | `unchanged, not saved` |
| Dialog | Yes | No |
| Extension running | No | Yes |
| PIA processes | 3 (crash-loop) | 7 (normal) |

### Contributing Factor

During early boot, `neagent.lsproxy` fails with "No such process", suggesting the NE framework itself has a race condition at startup that may contribute to losing the prior approval.

## Impact on Headless Servers

On a headless Mac Mini server (no monitor, keyboard, or mouse), the consent dialog has no way to be dismissed. This means:

1. Split tunnel never activates after reboot
2. All VPN protection stages that depend on split tunnel (Stages 1, 1.5, 2, 3b) cannot function
3. Traffic routing is unpredictable until someone VNCs in and clicks "Allow"

## Solution: AppleScript Auto-Clicker (Stage 1a)

A LaunchAgent runs at login and polls for the consent dialog via AppleScript:

```bash
# Watches for up to 5 minutes (dialog appears within ~15s of boot)
# Checks UserNotificationCenter, SystemUIServer, SecurityAgent
# Falls back to scanning all processes
# Clicks "Allow" when found, exits
```

### Prerequisites

**Accessibility permission** must be granted for `/bin/bash` (the shell running the script):

System Settings > Privacy & Security > Accessibility > add `/bin/bash`

Without this permission, AppleScript cannot interact with UI elements.

### Files

| File | Purpose |
|------|---------|
| `~operator/.local/bin/pia-proxy-consent.sh` | Auto-clicker script (deployed from template) |
| `~/Library/LaunchAgents/com.<hostname>.pia-proxy-consent.plist` | LaunchAgent (RunAtLoad, no KeepAlive) |
| `~operator/.local/state/<hostname>-pia-proxy-consent.log` | Script log |

### Verification

```bash
# Check script ran at last login
cat ~/.local/state/tilsit-pia-proxy-consent.log

# Expected output (consent was needed):
# [2026-02-17 11:30:50] [pia-proxy-consent] Clicked Allow on PIA proxy consent dialog (process: UserNotificationCenter)
# [2026-02-17 11:30:50] [pia-proxy-consent] Consent granted. Exiting.

# Expected output (consent persisted — normal):
# [2026-02-17 11:30:50] [pia-proxy-consent] No dialog seen after 300s. Exiting (normal if consent persisted this boot).
```

### Rollback

```bash
launchctl unload ~/Library/LaunchAgents/com.tilsit.pia-proxy-consent.plist
```

## Capturing Diagnostic Logs

To collect unified log evidence of the NE consent issue:

```bash
# Filter for NE proxy configuration events around boot time
log show --predicate 'subsystem == "com.apple.networkextension"' \
    --start "$(date -v-5M '+%Y-%m-%d %H:%M:%S')" \
    --style syslog | grep -i "signature\|consent\|permission\|saveToPreferences"
```

## PIA Bug Report

Filed as a GitHub issue on [pia-foss/desktop](https://github.com/pia-foss/desktop/issues). The core issue is that `saveToPreferences()` is called on every `piactl proxy sync` invocation, and macOS does not reliably persist the consent across reboots on non-supervised devices.
