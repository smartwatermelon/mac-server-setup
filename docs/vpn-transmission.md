# Transmission + PIA VPN Setup on macOS (Multi-User, Leak-Proof)

This guide outlines a reliable method to run **Transmission GUI** on macOS through **Private Internet Access (PIA)** such that all torrent traffic is routed through the VPN, leaks are prevented, and other apps bypass the VPN.

---

## Requirements

- macOS 15.6.1 or later
- Administrator account (for initial PIA installation)
- Operator account (or any non-admin account for daily Transmission use)
- Private Internet Access (PIA) subscription
- Transmission 4.1.0-beta.2 (GUI version)

---

## Step 1: Install and Configure PIA (Admin Account)

1. Download and install the PIA macOS client from [PIA’s website](https://www.privateinternetaccess.com/download/mac-vpn).
2. Log in with your PIA credentials.
3. Enable **Launch on Startup**.
4. Enable **Split Tunnel**:
   - Mode: *Only VPN*
   - App: `Transmission`
   - All other apps: *Bypass VPN*
5. Enable **Advanced Kill Switch**: blocks all non-VPN traffic if VPN drops.
6. Choose a P2P-friendly server (for example, nearest international endpoint: Vancouver, BC, Canada).
7. Optionally, enable **Request Port Forwarding** if your server supports it.

> ✅ Tip: Advanced Kill Switch ensures Transmission cannot leak even if the VPN is disconnected.

---

## Step 2: Copy PIA Configurations to Operator Account

1. Locate PIA preferences in Admin account:

    ```text
    ~/Library/Application Support/com.privateinternetaccess.vpn/
    ~/Library/Preferences/com.privateinternetaccess.vpn.plist
    ```

2. Copy these files to the Operator account’s corresponding directories.
3. Adjust ownership if needed:

    ```bash
    sudo chown -R operator:staff /Users/operator/Library/Application\ Support/com.privateinternetaccess.vpn
    sudo chown operator:staff /Users/operator/Library/Preferences/com.privateinternetaccess.vpn.plist
    ```

4. Log in as Operator and launch PIA once. Confirm:

- Launch on Startup is enabled
- Auto-connect is active
- Advanced Kill Switch is on
- Split Tunnel is bound to Transmission

## Step 3: Verify VPN Binding and Traffic Routing

1. Launch Transmission before VPN (optional).
2. Use a Magnet IP Leak test (ipleak.net → Torrent Address Detection) to confirm Transmission traffic shows the VPN’s IP.
3. Confirm other apps bypass VPN as expected.
4. Reboot into Operator account and verify:

- PIA auto-starts and auto-connects
- Transmission only uses VPN
- Non-VPN apps continue using standard ISP traffic

> ✅ Tip: With Advanced Kill Switch, Transmission will not leak even if it launches before the VPN is up.

## Step 4: Port Forwarding (Optional, Recommended)

1. In PIA: Settings → Network → Request Port Forwarding → enable.
2. Reconnect VPN to receive assigned port.
3. Transmission: Preferences → Network → Incoming TCP Port → set to PIA-assigned port.
4. Click Test Port → should show “Open.”

> Note: PIA may assign a new port on each connection. For automation, a small shell script can sync the PIA-assigned port to Transmission on login.

## Notes & Best Practices

- Transmission GUI vs Daemon: GUI stores settings in `~/Library/Preferences/org.m0k.transmission.plist`, not `settings.json`.
- Kill Switch Behavior:
  - Advanced: Blocks all WAN traffic unless VPN is active (LAN still allowed).
  - Regular: Blocks only traffic outside VPN while connected.
- Auto-start Ordering: Advanced Kill Switch protects you even if Transmission launches first.
- Multi-User: Each macOS user who wants Transmission + VPN needs their own copy of the PIA preferences or must configure PIA in their account.

---

✅ Summary

- PIA VPN is always on and bound only to Transmission.
- Advanced Kill Switch prevents any leaks.
- Split Tunnel ensures other apps bypass VPN normally.
- Port Forwarding improves swarm connectivity (optional).
- Multi-user configuration supported by copying prefs or reconfiguring PIA per account.

This setup provides a *bulletproof, leak-free, per-app VPN environment* for torrenting on macOS with the Transmission GUI.
