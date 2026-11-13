# Apple First-Boot Dialog Guide

This guide provides step-by-step instructions for navigating Apple's Setup Assistant dialogs during initial Mac Mini configuration and operator account first login.

## Admin Account Setup (Initial macOS Installation)

When setting up the Mac Mini for the first time, you'll encounter these Apple dialogs in sequence:

### 1. Language Selection

- **Action**: Select your preferred language
- **Recommendation**: Choose your primary language

### 2. Region Selection

- **Action**: Select your country/region
- **Recommendation**: Choose your current location for proper timezone and regional settings

### 3. Data Transfer & Migration

- **Action**: Choose transfer method
- **Options**:
  - **iPhone/iPad Transfer** ✅ Recommended if available (requires iOS device with backup)
  - **Time Machine Backup** (if you have an existing backup)
  - **Don't transfer any information now** (manual setup)
- **Note**: iPhone/iPad transfer can pre-configure WiFi, Apple ID, and other settings

### 4. Accessibility

- **Action**: Configure accessibility options
- **Recommendation**: Configure as needed for your requirements, or skip if not needed

### 5. Data & Privacy

- **Action**: Review Apple's privacy policy
- **Recommendation**: Continue after reading

### 6. Create Administrator Account

- **Full Name**: Will be pre-populated if you used iPhone/iPad transfer
- **Account Name**: Will be pre-populated if you used iPhone/iPad transfer
- **Password**: Create a strong password (you'll use this for first-boot setup)
- **Hint**: Optional password hint

### 7. Apple Account Configuration

#### 7.1 Terms & Conditions

- **Action**: Agree to Apple's Terms and Conditions
- **Recommendation**: Review and agree

#### 7.2 Customize Settings

##### 7.2.1 Location Services

- **Action**: Enable or disable location services
- **Recommendation**: Enable for timezone and system functionality

##### 7.2.2 Analytics & Improvement

- **Action**: Choose whether to share analytics with Apple
- **Recommendation**: Configure based on your privacy preferences

##### 7.2.3 Screen Time

- **Action**: Set up Screen Time monitoring
- **Recommendation**: Skip for server setup

##### 7.2.4 Apple Intelligence

- **Action**: Configure Apple's AI features
- **Recommendation**: Configure based on your preferences

##### 7.2.5 FileVault Disk Encryption

- **Action**: Choose whether to enable FileVault
- **⚠️ CRITICAL**: **Turn OFF FileVault!**
- **Reason**: FileVault prevents automatic login for the operator account
- **Note**: This is essential for proper server operation

##### 7.2.6 Touch ID

- **Action**: Set up Touch ID fingerprint authentication
- **Recommendation**: Set up for convenient sudo access during administration

##### 7.2.7 Apple Pay

- **Action**: Set up Apple Pay
- **Recommendation**: Configure based on your preferences

##### 7.2.8 Choose Your Look

- **Action**: Select Light, Dark, or Auto appearance
- **Recommendation**: Auto (adapts to time of day)

##### 7.2.9 Software Updates

- **Action**: Configure automatic update preferences
- **Recommendation**: Enable automatic security updates, manual for system updates

### 8. Continue Setup

- **Action**: Complete the setup process
- **Result**: Proceed to desktop

### 9. Desktop

- **Result**: macOS setup complete, ready for first-boot script execution

---

## Operator Account First Login

When the operator account logs in for the first time, they'll encounter a simplified Setup Assistant:

### 1. Accessibility

- **Action**: Configure accessibility options
- **Recommendation**: Configure as needed, or skip if not required

### 2. Apple Account

- **Action**: Sign in with Apple ID
- **⚠️ RECOMMENDATION**: **Skip this step**
- **Reason**: Server operations don't require operator Apple ID integration
- **Note**: You can always add this later if needed

### 3. Find My

- **Action**: Enable Find My for the device
- **Recommendation**: Configure based on your security preferences

### 4. Analytics & Improvement

- **Action**: Choose analytics sharing preferences
- **Recommendation**: Configure based on privacy preferences

### 5. Screen Time

- **Action**: Set up Screen Time
- **⚠️ RECOMMENDATION**: **Skip this step**
- **Reason**: Not relevant for server operation

### 6. Apple Intelligence

- **Action**: Configure Apple AI features
- **⚠️ RECOMMENDATION**: **Skip this step**
- **Reason**: Not needed for server operation, may impact performance

### 7. Touch ID Setup Assistant

- **Action**: Set up Touch ID
- **⚠️ RECOMMENDATION**: **Cancel/Skip this step**
- **Reason**: Operator account uses automatic login, Touch ID not typically needed

### 8. Choose Your Look

- **Action**: Select appearance theme
- **Recommendation**: Auto or user preference

### 9. Continue

- **Action**: Complete operator setup
- **Result**: Proceed to desktop

### 10. Desktop

- **Result**: Operator account setup complete, automatic application launch will begin

---

## Important Notes

### FileVault Warning

**CRITICAL**: Ensure FileVault is disabled during admin account setup. FileVault encryption prevents the automatic login functionality required for proper server operation.

### Account Purpose

- **Admin Account**: Used for system administration, setup, and maintenance
- **Operator Account**: Used for day-to-day server operation and automatic application launch

### Setup Timing

- Complete Apple dialogs **before** running `first-boot.sh`
- Operator dialogs appear automatically on first operator login after reboot

### Migration Assistant Benefits

Using iPhone/iPad transfer during initial setup can significantly reduce manual configuration by pre-populating:

- WiFi network settings
- Apple ID information
- Basic user account details
- System preferences

This reduces the overall setup time and ensures consistent configuration across your devices.
