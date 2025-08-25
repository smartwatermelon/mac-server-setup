#!/usr/bin/env bash
#
# test-sudo-timeout.sh - Test script to verify sudo timeout behavior
#
# This script tests sudo timeout configuration locally with short timeouts
# to verify the mechanism works before using longer timeouts in production.
#

set -euo pipefail

# Configuration
TEST_TIMEOUT=1  # 1 minute for testing
SUDOERS_FILE="/etc/sudoers.d/99_timeout_test"
CLEANUP_ON_EXIT=true

# Logging function
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $*"
}

# Cleanup function
cleanup() {
  if [[ "${CLEANUP_ON_EXIT}" == "true" ]] && [[ -f "${SUDOERS_FILE}" ]]; then
    log "Cleaning up test sudoers file..."
    sudo rm -f "${SUDOERS_FILE}" 2>/dev/null || true
    log "Test cleanup completed"
  fi
}

# Set trap for cleanup
trap cleanup EXIT

# Main test
main() {
  log "=== Sudo Timeout Test ==="
  log "This script will test sudo timeout with a ${TEST_TIMEOUT}-minute timeout"
  echo

  # Check if we're running with appropriate privileges
  if [[ $EUID -eq 0 ]]; then
    log "ERROR: Don't run this script as root - it needs to test sudo behavior"
    exit 1
  fi

  # Step 1: Check current sudo timeout settings
  log "Step 1: Checking current sudo timeout settings..."
  log "Current sudo -l output:"
  sudo -l | grep -i timeout || log "No timeout settings found"
  echo

  # Step 2: Create test timeout configuration
  log "Step 2: Creating test sudo timeout configuration (${TEST_TIMEOUT} minute)..."
  sudo -p "Enter password to create test timeout configuration: " tee "${SUDOERS_FILE}" >/dev/null <<EOF
# Test sudo timeout configuration - ${TEST_TIMEOUT} minute
Defaults timestamp_timeout=${TEST_TIMEOUT}
EOF
  # Fix permissions for sudoers file
  sudo chmod 0440 "${SUDOERS_FILE}"
  log "✅ Test configuration created"
  echo

  # Step 3: Verify configuration
  log "Step 3: Verifying configuration..."
  if [[ -f "${SUDOERS_FILE}" ]]; then
    log "Configuration file contents:"
    cat "${SUDOERS_FILE}" | while read -r line; do log "  ${line}"; done
  fi

  # Test sudoers validity
  if sudo visudo -c >/dev/null 2>&1; then
    log "✅ sudoers configuration is valid"
  else
    log "❌ sudoers configuration has errors!"
    exit 1
  fi
  echo

  # Step 4: Test sudo timestamp behavior
  log "Step 4: Testing sudo timestamp behavior..."
  
  # First sudo command (will ask for password)
  log "First sudo command (should ask for password):"
  sudo -n true 2>/dev/null && log "DEBUG: sudo timestamp already valid" || log "DEBUG: sudo timestamp invalid (expected)"
  sudo -p "Enter password for first test command: " true
  log "✅ First sudo command completed"
  echo

  # Second sudo command (should not ask for password if timeout works)
  log "Second sudo command immediately after (should NOT ask for password):"
  if sudo -n true 2>/dev/null; then
    log "✅ Second sudo command succeeded without password - timeout is working!"
  else
    log "❌ Second sudo command failed - timeout is NOT working!"
  fi
  echo

  # Step 5: Test timeout duration
  log "Step 5: Testing timeout duration..."
  log "Waiting 30 seconds to test if timeout persists..."
  sleep 30
  
  if sudo -n true 2>/dev/null; then
    log "✅ sudo timestamp still valid after 30 seconds"
  else
    log "❌ sudo timestamp expired after 30 seconds (timeout too short or not working)"
  fi
  echo

  # Step 6: Test different command types
  log "Step 6: Testing different sudo command types..."
  
  log "Testing 'sudo ls' command:"
  if sudo -n ls /etc >/dev/null 2>&1; then
    log "✅ 'sudo ls' succeeded without password"
  else
    log "❌ 'sudo ls' required password"
  fi

  log "Testing 'sudo -u \${USER}' command:"
  if sudo -n -u "${USER}" true 2>/dev/null; then
    log "✅ 'sudo -u' succeeded without password"
  else
    log "❌ 'sudo -u' required password"
  fi
  echo

  # Step 7: Show final status
  log "Step 7: Final timeout status check..."
  log "Final sudo -l output:"
  sudo -l | grep -i timeout || log "No timeout settings found"
  echo

  log "=== Test Complete ==="
  log "Test configuration will be cleaned up automatically"
}

# Confirmation prompt
echo "This script will test sudo timeout behavior with a ${TEST_TIMEOUT}-minute timeout."
echo "It will create a temporary sudoers file at ${SUDOERS_FILE}"
echo "and clean it up when done."
echo
read -p "Continue with the test? (y/N): " -n 1 -r response
echo

case "${response}" in
  [yY] | [yY][eE][sS]) main ;;
  *) log "Test cancelled by user"; exit 0 ;;
esac