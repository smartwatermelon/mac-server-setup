# Keychain-Based Credential Management Implementation Plan

## Overview

Replace plaintext credential files with macOS Keychain storage for secure credential transfer.

## Implementation Strategy

### Phase 1: prep-airdrop.sh Changes

#### Keychain Services

- `mac-server-setup-operator-{SERVER_NAME_LOWER}`
- `mac-server-setup-plex-nas-{SERVER_NAME_LOWER}`
- `mac-server-setup-timemachine-{SERVER_NAME_LOWER}`
- `mac-server-setup-wifi-{SERVER_NAME_LOWER}`

#### Functions to Add

```bash
# Store credential in Keychain with verification
store_keychain_credential() {
    local service="$1"
    local account="$2" 
    local password="$3"
    local description="$4"
    
    # Store in Keychain
    security add-generic-password \
        -s "${service}" \
        -a "${account}" \
        -w "${password}" \
        -D "${description}" \
        -T "/System/Library/CoreServices/Keychain Access.app" \
        -U
    
    # Immediately verify by reading back
    local retrieved_password
    retrieved_password=$(security find-generic-password \
        -s "${service}" \
        -a "${account}" \
        -w 2>/dev/null)
    
    if [[ "${password}" == "${retrieved_password}" ]]; then
        echo "✅ Credential stored and verified in Keychain: ${service}"
        return 0
    else
        collect_error "Keychain credential verification failed for ${service}"
        return 1
    fi
}

# Create Keychain manifest for server
create_keychain_manifest() {
    cat >"${OUTPUT_PATH}/config/keychain_manifest.conf" <<EOF
# Keychain service identifiers for credential retrieval
KEYCHAIN_OPERATOR_SERVICE="mac-server-setup-operator-${SERVER_NAME_LOWER}"
KEYCHAIN_PLEX_NAS_SERVICE="mac-server-setup-plex-nas-${SERVER_NAME_LOWER}"
KEYCHAIN_TIMEMACHINE_SERVICE="mac-server-setup-timemachine-${SERVER_NAME_LOWER}"
KEYCHAIN_WIFI_SERVICE="mac-server-setup-wifi-${SERVER_NAME_LOWER}"
KEYCHAIN_ACCOUNT="${SERVER_NAME_LOWER}"
EOF
    chmod 600 "${OUTPUT_PATH}/config/keychain_manifest.conf"
}
```

### Phase 2: first-boot.sh Changes

#### Keychain Verification Function

```bash
# Verify Keychain access and credentials after Apple ID setup
verify_keychain_credentials() {
    set_section "Verifying Keychain Credentials Access"
    
    # Load keychain manifest
    local manifest_file="${SETUP_DIR}/config/keychain_manifest.conf"
    if [[ ! -f "${manifest_file}" ]]; then
        collect_error "Keychain manifest not found: ${manifest_file}"
        return 1
    fi
    
    # shellcheck source=/dev/null
    source "${manifest_file}"
    
    # Test each required credential with retry logic
    local max_attempts=30
    local attempt=1
    local credentials_available=false
    
    show_log "Waiting for iCloud Keychain sync to complete..."
    show_log "This may take up to 5 minutes after Apple ID setup"
    
    while [[ ${attempt} -le ${max_attempts} ]]; do
        log "Keychain verification attempt ${attempt}/${max_attempts}"
        
        # Check each credential
        local all_credentials_found=true
        
        # Operator credential (required)
        if ! security find-generic-password -s "${KEYCHAIN_OPERATOR_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w >/dev/null 2>&1; then
            log "  ❌ Operator credential not yet available"
            all_credentials_found=false
        else
            log "  ✅ Operator credential available"
        fi
        
        # Plex NAS credential (required)
        if ! security find-generic-password -s "${KEYCHAIN_PLEX_NAS_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w >/dev/null 2>&1; then
            log "  ❌ Plex NAS credential not yet available"
            all_credentials_found=false
        else
            log "  ✅ Plex NAS credential available"  
        fi
        
        # TimeMachine credential (optional)
        if security find-generic-password -s "${KEYCHAIN_TIMEMACHINE_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w >/dev/null 2>&1; then
            log "  ✅ TimeMachine credential available"
        else
            log "  ⚠️ TimeMachine credential not available (may be optional)"
        fi
        
        # WiFi credential (optional) 
        if security find-generic-password -s "${KEYCHAIN_WIFI_SERVICE}" -a "${KEYCHAIN_ACCOUNT}" -w >/dev/null 2>&1; then
            log "  ✅ WiFi credential available"
        else
            log "  ⚠️ WiFi credential not available (may be optional)"
        fi
        
        if [[ "${all_credentials_found}" == "true" ]]; then
            show_log "✅ All required credentials available in Keychain"
            credentials_available=true
            break
        fi
        
        log "Waiting 10 seconds for Keychain sync..."
        sleep 10
        ((attempt++))
    done
    
    if [[ "${credentials_available}" == "false" ]]; then
        collect_error "Required credentials not available in Keychain after ${max_attempts} attempts"
        show_log "This may indicate:"
        show_log "1. Apple ID setup was not completed"
        show_log "2. iCloud Keychain is not enabled"
        show_log "3. Network connectivity issues preventing sync"
        return 1
    fi
    
    return 0
}

# Secure credential retrieval function
get_keychain_credential() {
    local service="$1"
    local account="$2"
    
    local credential
    credential=$(security find-generic-password \
        -s "${service}" \
        -a "${account}" \
        -w 2>/dev/null)
    
    if [[ -n "${credential}" ]]; then
        echo "${credential}"
        return 0
    else
        collect_error "Failed to retrieve credential from Keychain: ${service}"
        return 1
    fi
}
```

### Phase 3: Credential Usage Updates

#### Replace operator account creation

```bash
create_operator_account() {
    # Load keychain manifest
    source "${SETUP_DIR}/config/keychain_manifest.conf"
    
    # Get credential securely
    local operator_password
    operator_password=$(get_keychain_credential "${KEYCHAIN_OPERATOR_SERVICE}" "${KEYCHAIN_ACCOUNT}")
    
    # Create account
    sudo -p "[Account setup] Enter password to create operator account: " \
        sysadminctl -addUser "${OPERATOR_USERNAME}" \
        -fullName "${OPERATOR_FULLNAME}" \
        -password "${operator_password}" \
        -hint "See 1Password ${ONEPASSWORD_OPERATOR_ITEM} for password" 2>/dev/null
    
    # Verify password
    if dscl /Local/Default -authonly "${OPERATOR_USERNAME}" "${operator_password}"; then
        show_log "✅ Password verification successful"
    else
        collect_error "Password verification failed"
        unset operator_password
        return 1
    fi
    
    # Clear from memory immediately
    unset operator_password
}
```

### Phase 4: App-Setup Script Updates

#### plex-setup.sh credential handling

```bash
# Replace plex_nas.conf file loading with Keychain retrieval
load_nas_credentials() {
    # Load keychain manifest from parent setup directory
    local manifest_file="../config/keychain_manifest.conf"
    if [[ -f "${manifest_file}" ]]; then
        # shellcheck source=/dev/null
        source "${manifest_file}"
        
        # Get credentials from Keychain
        PLEX_NAS_USERNAME=$(get_keychain_credential "${KEYCHAIN_PLEX_NAS_SERVICE}" "${KEYCHAIN_ACCOUNT}" | cut -d: -f1)
        local plex_nas_password
        plex_nas_password=$(get_keychain_credential "${KEYCHAIN_PLEX_NAS_SERVICE}" "${KEYCHAIN_ACCOUNT}" | cut -d: -f2-)
        
        # Use credentials immediately in script template
        configure_mount_script "${plex_nas_password}"
        
        # Clear from memory
        unset plex_nas_password
    else
        # Fallback to existing file-based method
        load_nas_credentials_from_file
    fi
}
```

## Security Benefits

1. ✅ No plaintext credential files transferred
2. ✅ Encrypted storage in macOS Keychain
3. ✅ Automatic sync via iCloud Keychain  
4. ✅ Immediate verification of stored credentials
5. ✅ Proper credential cleanup from memory
6. ✅ Graceful fallback for optional credentials
7. ✅ Comprehensive error handling and retry logic

## Implementation Timeline

1. **Immediate**: Add Keychain functions to prep-airdrop.sh
2. **Phase 1**: Replace operator credential handling
3. **Phase 2**: Add Keychain verification to first-boot.sh  
4. **Phase 3**: Update plex-setup.sh credential handling
5. **Phase 4**: Update TimeMachine credential handling
6. **Testing**: Verify end-to-end credential flow

## Backward Compatibility

- Keep existing file-based credential loading as fallback
- Gradual migration allows testing of individual components
- Original 1Password integration remains unchanged
