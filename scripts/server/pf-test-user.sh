#!/usr/bin/env bash
#
# pf-test-user.sh - Verify PF user-based filtering on this macOS version
#
# This script is the go/no-go gate for Stage 4 (kernel-level VPN kill-switch).
# It creates a throwaway system user, loads a PF rule blocking that user on en0,
# tests whether the kernel enforces the rule, and cleans up completely.
#
# RESULTS:
#   If _pftest curl times out AND your curl succeeds -> PF user filtering works.
#   If _pftest curl succeeds -> PF user filtering is not functional on this OS.
#
# MUST be run with sudo on the TARGET server.
# DO NOT run on the development machine.
#
# Usage: sudo ./pf-test-user.sh
#
# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-02-12

set -euo pipefail

# Ensure running as root
current_uid=$(id -u)
if [[ "${current_uid}" -ne 0 ]]; then
  echo "This script must be run as root (use sudo)."
  echo "Usage: sudo $0"
  exit 1
fi

# Test user configuration
TEST_USER="_pftest"
TEST_UID="299"
TEST_ANCHOR="pftest"
CURL_TIMEOUT=5
TEST_URL="http://example.com"

# Track what we created for cleanup
USER_CREATED=false
ANCHOR_LOADED=false
PF_WAS_ENABLED=false
CLEANUP_DONE=false

# Cleanup function — idempotent, safe to call multiple times.
# Registered as EXIT trap AND called explicitly before verdict output.
cleanup() {
  if [[ "${CLEANUP_DONE}" == "true" ]]; then
    return 0
  fi
  CLEANUP_DONE=true

  echo ""
  echo "=== Cleanup ==="

  # Remove PF anchor rules
  if [[ "${ANCHOR_LOADED}" == "true" ]]; then
    echo "Flushing PF anchor '${TEST_ANCHOR}'..."
    pfctl -a "${TEST_ANCHOR}" -F rules 2>/dev/null || true
    echo "  Done"
  fi

  # Disable PF if we enabled it and it wasn't enabled before
  if [[ "${PF_WAS_ENABLED}" == "false" ]]; then
    echo "Restoring PF to disabled state..."
    pfctl -d 2>/dev/null || true
    echo "  Done"
  fi

  # Delete test user
  if [[ "${USER_CREATED}" == "true" ]]; then
    echo "Deleting test user ${TEST_USER}..."
    dscl . -delete "/Users/${TEST_USER}" 2>/dev/null || true
    echo "  Done"
  fi

  echo "Cleanup complete."
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Check if PF is already enabled
# ---------------------------------------------------------------------------

echo "=== PF User-Based Filtering Test ==="
macos_version=$(sw_vers -productVersion)
kernel_version=$(uname -r)
echo "macOS version: ${macos_version}"
echo "Kernel: ${kernel_version}"
echo ""

echo "Step 1: Checking PF state..."
if pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
  PF_WAS_ENABLED=true
  echo "  PF is already enabled"
else
  PF_WAS_ENABLED=false
  echo "  PF is not enabled (will enable for test)"
fi

# ---------------------------------------------------------------------------
# Step 2: Create throwaway test user
# ---------------------------------------------------------------------------

echo ""
echo "Step 2: Creating test user ${TEST_USER} (UID ${TEST_UID})..."

# Check if UID is already in use
if dscl . -list /Users UniqueID | awk -v uid="${TEST_UID}" '$2 == uid {found=1} END {exit !found}'; then
  echo "  ERROR: UID ${TEST_UID} is already in use. Pick a different TEST_UID."
  exit 1
fi

# Check if user already exists
if dscl . -read "/Users/${TEST_USER}" 2>/dev/null; then
  echo "  WARNING: User ${TEST_USER} already exists, deleting first..."
  dscl . -delete "/Users/${TEST_USER}"
fi

dscl . -create "/Users/${TEST_USER}"
dscl . -create "/Users/${TEST_USER}" UniqueID "${TEST_UID}"
dscl . -create "/Users/${TEST_USER}" PrimaryGroupID 20
dscl . -create "/Users/${TEST_USER}" UserShell /bin/bash
dscl . -create "/Users/${TEST_USER}" NFSHomeDirectory /tmp
dscl . -create "/Users/${TEST_USER}" Password "*"
USER_CREATED=true
echo "  Created ${TEST_USER} with UID ${TEST_UID}"

# ---------------------------------------------------------------------------
# Step 3: Load PF rule blocking _pftest on en0
# ---------------------------------------------------------------------------

echo ""
echo "Step 3: Loading PF rule to block ${TEST_USER} on en0..."

echo "block drop out quick on en0 proto tcp user ${TEST_USER}" | pfctl -a "${TEST_ANCHOR}" -f -
ANCHOR_LOADED=true

# Enable PF if not already enabled
pfctl -e 2>/dev/null || true

echo "  PF anchor '${TEST_ANCHOR}' loaded"
echo "  Rule: block drop out quick on en0 proto tcp user ${TEST_USER}"

# Verify anchor loaded
echo ""
echo "  Loaded rules:"
pfctl -a "${TEST_ANCHOR}" -s rules 2>/dev/null | while IFS= read -r line; do
  echo "    ${line}"
done

# ---------------------------------------------------------------------------
# Step 4: Test — _pftest should be BLOCKED
# ---------------------------------------------------------------------------

echo ""
echo "Step 4: Testing ${TEST_USER} connectivity (should be BLOCKED)..."
echo "  Running: sudo -u ${TEST_USER} curl --max-time ${CURL_TIMEOUT} ${TEST_URL}"

blocked_test_result=0
if sudo -u "${TEST_USER}" curl -s -o /dev/null --max-time "${CURL_TIMEOUT}" "${TEST_URL}" 2>&1; then
  blocked_test_result=1
  echo "  RESULT: Connection SUCCEEDED (PF did NOT block)"
else
  echo "  RESULT: Connection FAILED/TIMED OUT (PF blocked as expected)"
fi

# ---------------------------------------------------------------------------
# Step 5: Test — current user should NOT be blocked
# ---------------------------------------------------------------------------

echo ""
echo "Step 5: Testing current user connectivity (should NOT be blocked)..."
echo "  Running: curl --max-time ${CURL_TIMEOUT} ${TEST_URL}"

allowed_test_result=0
if curl -s -o /dev/null --max-time "${CURL_TIMEOUT}" "${TEST_URL}" 2>&1; then
  echo "  RESULT: Connection SUCCEEDED (not affected by rule)"
else
  allowed_test_result=1
  echo "  RESULT: Connection FAILED (unexpected — rule may be too broad)"
fi

# ---------------------------------------------------------------------------
# Verdict — cleanup runs via EXIT trap after script exits
# ---------------------------------------------------------------------------

echo ""
echo "==========================================="

# Determine human-readable test results
if [[ ${blocked_test_result} -eq 0 ]]; then
  blocked_desc="blocked (good)"
else
  blocked_desc="not blocked (bad)"
fi

if [[ ${allowed_test_result} -eq 0 ]]; then
  allowed_desc="allowed (good)"
else
  allowed_desc="blocked (bad)"
fi

# Run cleanup before printing verdict (idempotent — EXIT trap is safety net)
cleanup

exit_code=0

if [[ ${blocked_test_result} -eq 0 ]] && [[ ${allowed_test_result} -eq 0 ]]; then
  echo "VERDICT: PASS — PF user-based filtering WORKS on this macOS version."
  echo ""
  echo "  ${TEST_USER} was blocked on en0 while other users were unaffected."
  echo "  You can proceed with Stage 4 (kernel-level VPN kill-switch)."
  echo "==========================================="
  exit_code=0
elif [[ ${blocked_test_result} -eq 1 ]] && [[ ${allowed_test_result} -eq 0 ]]; then
  echo "VERDICT: FAIL — PF user keyword is NOT functional."
  echo ""
  echo "  ${TEST_USER} was NOT blocked despite the PF rule."
  echo "  Stage 4 is not viable on this macOS version."
  echo "  Stay with Stage 1+2 (PIA inversion + VPN monitor)."
  echo "==========================================="
  exit_code=1
else
  echo "VERDICT: INCONCLUSIVE — unexpected test results."
  echo ""
  echo "  Blocked test: ${blocked_desc}"
  echo "  Allowed test: ${allowed_desc}"
  echo "  Check network connectivity and try again."
  echo "==========================================="
  exit_code=2
fi

# EXIT trap fires cleanup() automatically
exit "${exit_code}"
