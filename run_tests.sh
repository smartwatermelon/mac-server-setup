#!/usr/bin/env bash

# Test runner for mac-server-setup
# Runs all BATS unit and integration tests

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Check and install dependencies
check_dependencies() {
  # Only dependency is bats-core
  # Note: This project uses custom test helpers, not bats-support/bats-assert
  if command -v bats &>/dev/null; then
    return 0
  fi

  # Report missing dependency
  echo -e "${RED}Missing required test dependency:${NC}"
  echo "  - bats-core"
  echo

  # Offer to install via Homebrew
  if ! command -v brew &>/dev/null; then
    echo -e "${RED}Error: Homebrew not found. Install from https://brew.sh/${NC}"
    echo "Then run: brew install bats-core"
    return 1
  fi

  echo -e "${YELLOW}Install bats-core with Homebrew? [y/N]:${NC} "
  read -r response

  case "${response}" in
    [yY][eE][sS] | [yY])
      echo -e "${BLUE}Installing: bats-core${NC}"
      if brew install bats-core; then
        echo -e "${GREEN}bats-core installed successfully.${NC}"
        echo
      else
        echo -e "${RED}Error: Failed to install bats-core${NC}"
        return 1
      fi
      ;;
    *)
      echo -e "${YELLOW}Installation cancelled. Please install manually:${NC}"
      echo "  brew install bats-core"
      return 1
      ;;
  esac

  return 0
}

if ! check_dependencies; then
  exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}mac-server-setup Test Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo

# Run unit tests
echo -e "${YELLOW}Running Unit Tests...${NC}"
echo -e "${BLUE}────────────────────────────────────────${NC}"
if bats tests/transmission-filebot/unit/*.bats; then
  echo -e "${GREEN}✓ Unit tests passed${NC}"
  UNIT_RESULT=0
else
  echo -e "${RED}✗ Unit tests failed${NC}"
  UNIT_RESULT=1
fi
echo

# Run integration tests
echo -e "${YELLOW}Running Integration Tests...${NC}"
echo -e "${BLUE}────────────────────────────────────────${NC}"
if bats tests/transmission-filebot/integration/*.bats; then
  echo -e "${GREEN}✓ Integration tests passed${NC}"
  INTEGRATION_RESULT=0
else
  echo -e "${RED}✗ Integration tests failed${NC}"
  INTEGRATION_RESULT=1
fi
echo

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"

if [[ ${UNIT_RESULT} -eq 0 ]]; then
  echo -e "Unit Tests:        ${GREEN}✓ PASSED${NC}"
else
  echo -e "Unit Tests:        ${RED}✗ FAILED${NC}"
fi

if [[ ${INTEGRATION_RESULT} -eq 0 ]]; then
  echo -e "Integration Tests: ${GREEN}✓ PASSED${NC}"
else
  echo -e "Integration Tests: ${RED}✗ FAILED${NC}"
fi

echo -e "${BLUE}========================================${NC}"

# Exit with failure if any tests failed
if [[ ${UNIT_RESULT} -ne 0 ]] || [[ ${INTEGRATION_RESULT} -ne 0 ]]; then
  echo -e "${RED}Some tests failed${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
