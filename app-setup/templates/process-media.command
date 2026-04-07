#!/usr/bin/env bash

# Strict mode
set -euo pipefail
# nosemgrep: bash.lang.security.ifs-tampering.ifs-tampering -- safe strict-mode idiom
IFS=$'\n\t'

# Change to script directory
cd "$(dirname "$0")" || exit 1

# Clear screen for cleaner output
clear

# Header
echo "========================================"
echo "  Transmission-Plex Media Processor"
echo "========================================"
echo ""

# Run the main script (disable errexit to capture exit code for user display)
set +e
./transmission-done.sh
exit_code=$?
set -e

# Show result
echo ""
echo "========================================"
if [[ ${exit_code} -eq 0 ]]; then
  echo "  ✓ Processing completed successfully"
else
  echo "  ✗ Processing failed (exit code: ${exit_code})"
  echo "  Check log for details"
fi
echo "========================================"
echo ""

# Keep window open on error
if [[ ${exit_code} -ne 0 ]]; then
  printf 'Press Enter to close...'
  read -r
fi

exit "${exit_code}"
