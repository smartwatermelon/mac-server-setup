# Code Review: plex-setup.sh (Post-1.0 Improvement Plan)

**Date:** 2025-09-12  
**Script:** `app-setup/plex-setup.sh`  
**Lines of Code:** 1,654  
**Review Type:** Post-1.0 Maintenance & Improvement Assessment  

## Executive Summary

The `plex-setup.sh` script is a functionally robust and feature-complete solution for Plex Media Server deployment with migration capabilities. While it demonstrates excellent security practices and comprehensive error handling, it shows clear signs of iterative development that have resulted in structural complexity impacting long-term maintainability.

**Overall Assessment:** B+ (Good functionality, needs structural improvement)

## Strengths

### ✅ Security & Best Practices

- **Exceptional credential handling**: Keychain integration, memory cleanup, masked logging
- **Proper privilege escalation**: Contextual sudo prompts with descriptive messages  
- **Input validation**: Command line arguments, port numbers, hostnames
- **Safe database operations**: Backups, integrity checks, transaction-like behavior
- **File permissions**: Correct ownership and permissions for multi-user access
- **Zero shellcheck issues**: Perfect compliance with shell scripting standards

### ✅ Error Handling & Logging

- **Comprehensive error collection**: Immediate display with end-of-run summary
- **Graceful degradation**: Continues operation when non-critical components fail
- **Detailed context tracking**: Line numbers, section identification, script context
- **User-friendly diagnostics**: Clear troubleshooting suggestions and guidance

### ✅ Feature Completeness

- **Migration capabilities**: Both local and remote with SSH connectivity testing
- **Port conflict resolution**: Automatic detection and custom port configuration
- **Multi-user support**: Per-user LaunchAgents and shared configurations
- **Network discovery**: Automatic scanning for existing Plex servers
- **Database path updates**: Comprehensive SQLite operations for migration

## Critical Issues Requiring Improvement

### 🔴 HIGH PRIORITY: Function Organization & Size

**Problem:** Violation of single responsibility principle with overly large functions.

**Specific Issues:**

- `main()`: 287 lines (lines 1355-1641) - handles multiple distinct phases
- `setup_persistent_smb_mount()`: 171 lines (lines 376-546) - complex nested logic
- `migrate_plex_from_host()`: 98 lines (lines 783-881) - multiple concerns mixed
- `update_migrated_library_paths()`: 147 lines (lines 1031-1177) - complex database operations

**Impact:**

- Difficult to test individual features in isolation
- Hard to debug specific functionality
- Maintenance requires understanding entire large functions
- Code reuse is limited

**Recommended Refactoring:**

```bash
# Current main() should be broken into logical phases:
main() {
  setup_prerequisites
  handle_migration_setup  
  perform_installation
  apply_configuration
  display_completion_summary
}

# Extract nested functionality:
setup_persistent_smb_mount() {
  validate_mount_safety
  retrieve_nas_credentials  
  configure_mount_script
  deploy_user_mounts
  test_immediate_mount
}
```

### 🟡 MEDIUM PRIORITY: Complex Conditional Logic

**Problem:** Deeply nested conditionals make logic flow hard to follow.

**Specific Issues:**

- Migration decision logic: 130 lines of nested conditions (lines 1371-1501)
- Port configuration: 3 different code paths with inconsistent patterns
- Flag validation: Could be simplified with better structure

**Current Problematic Pattern:**

```bash
# Lines 1371-1501: Complex nested migration logic
if [[ "${SKIP_MIGRATION}" != "true" && -z "${MIGRATE_FROM}" ]]; then
  if [[ "${MIGRATE}" == "true" ]] || confirm "Do you want to migrate..."; then
    # 100+ lines of deeply nested logic with multiple branches
    if [[ -n "${discovered_servers}" ]]; then
      # Another 50+ lines of server selection logic
    fi
  fi
fi
```

**Recommended Strategy Pattern:**

```bash
determine_migration_strategy() {
  if [[ "${SKIP_MIGRATION}" == "true" ]]; then
    echo "skip"
  elif [[ -n "${MIGRATE_FROM}" ]]; then
    echo "remote:${MIGRATE_FROM}"  
  elif [[ "${MIGRATE}" == "true" ]] || confirm "Migrate from existing server?" "n"; then
    echo "interactive"
  else
    echo "fresh"
  fi
}

# Usage in main():
case "$(determine_migration_strategy)" in
  "skip") log "Starting fresh installation" ;;
  "remote:"*) migrate_from_remote "${strategy#remote:}" ;;
  "interactive") handle_interactive_migration ;;
  "fresh") setup_fresh_installation ;;
esac
```

### 🟡 MEDIUM PRIORITY: Variable Scope & Management

**Problem:** Global variable modification within nested functions creates hidden dependencies.

**Specific Issues:**

- Line 697: `MIGRATE_FROM="${local_hostname}"` - global modification in `test_ssh_connection()`
- Line 807: `TARGET_PLEX_PORT=$((SOURCE_PLEX_PORT + 1))` - global assignment in migration function
- Sensitive variables persist longer than necessary in memory
- Missing `local` declarations in some functions

**Impact:**

- Functions have hidden side effects
- Difficult to reason about variable state
- Potential security implications for credential variables

**Recommended Approach:**

```bash
# Return values instead of modifying globals:
resolve_hostname() {
  local host="$1"
  # Resolution logic here
  echo "${resolved_hostname}"  # Return via stdout
}

# Usage:
MIGRATE_FROM=$(resolve_hostname "${MIGRATE_FROM}")
```

### 🟡 MEDIUM PRIORITY: Code Duplication

**Problem:** Similar patterns repeated throughout the script.

**Specific Examples:**

1. **plist Validation Pattern** (lines 508, 1302):

```bash
if sudo -iu "${target_user}" plutil -lint "${plist_file}"; then
  log "plist syntax validated"
else  
  collect_error "Invalid plist syntax"
fi
```

1. **SSH Connection Testing** - Similar logic in multiple functions
2. **Port Validation** - Repeated in 3 different locations with slight variations

**Recommended Utilities:**

```bash
validate_plist() {
  local plist_file="$1"
  local user="${2:-${USER}}"
  if sudo -iu "${user}" plutil -lint "${plist_file}" >/dev/null 2>&1; then
    log "✅ plist syntax validated: $(basename "${plist_file}")"
    return 0
  else
    collect_error "Invalid plist syntax: ${plist_file}"
    return 1
  fi
}

validate_port() {
  local port="$1"
  if [[ "${port}" =~ ^[0-9]+$ && "${port}" -gt 1024 && "${port}" -lt 65536 ]]; then
    return 0
  fi
  return 1
}
```

## Minor Issues

### 🟢 LOW PRIORITY: Magic Numbers & Hardcoded Values

**Issues:**

- Port ranges hardcoded: `1024`, `65536`
- Timeout values scattered: `3`, `5`, `10` seconds  
- Path patterns repeated: `Media/`, `.local/mnt/`

**Recommendation:** Define constants section:

```bash
# Configuration constants
readonly MIN_PORT=1025
readonly MAX_PORT=65535
readonly SSH_TIMEOUT=10
readonly DNS_DISCOVERY_TIMEOUT=3
readonly MEDIA_PATH_PATTERN="Media/"
readonly MOUNT_BASE=".local/mnt"
```

## Architectural Improvement Proposals

### 1. Phase-Based Execution Model

Replace monolithic `main()` with clear execution phases:

```bash
readonly SETUP_PHASES=(
  "validate_prerequisites"
  "determine_migration_strategy" 
  "setup_storage_mounts"
  "install_plex_application"
  "apply_configuration"
  "configure_autostart"
  "display_completion_info"
)

main() {
  for phase in "${SETUP_PHASES[@]}"; do
    set_section "Phase: ${phase//_/ }"
    if ! execute_phase "${phase}"; then
      collect_error "Failed in phase: ${phase}"
      exit 1
    fi
  done
}
```

### 2. Migration Strategy Abstraction

```bash
# Migration strategies as separate functions:
migration_strategy_skip() { log "Fresh installation selected"; }
migration_strategy_remote() { migrate_from_remote "$1"; }
migration_strategy_local() { apply_local_migration; }
migration_strategy_interactive() { handle_interactive_migration; }

# Clean dispatch:
execute_migration_strategy() {
  local strategy
  strategy=$(determine_migration_strategy)
  "migration_strategy_${strategy%%:*}" "${strategy#*:}"
}
```

### 3. Configuration Builder Pattern

Centralize configuration decisions:

```bash
build_plex_configuration() {
  local -a config_options=()
  
  [[ -n "${TARGET_PLEX_PORT:-}" ]] && config_options+=("--port=${TARGET_PLEX_PORT}")
  [[ -n "${PLEX_SERVER_NAME:-}" ]] && config_options+=("--name=${PLEX_SERVER_NAME}")
  [[ "${MIGRATE_FROM:-}" ]] && config_options+=("--migrated-from=${MIGRATE_FROM}")
  
  printf '%s\n' "${config_options[@]}"
}
```

## Database Operations Improvement

The `update_migrated_library_paths()` function handles complex SQLite operations and could benefit from:

1. **Extraction into separate module**: `plex-database-utils.sh`
2. **Transaction-based operations**: Ensure atomicity
3. **Better error recovery**: More granular rollback capabilities

```bash
# Proposed structure:
update_library_paths() {
  local db_path="$1" old_mount="$2" new_mount="$3"
  
  begin_database_transaction "${db_path}"
  update_section_locations "${db_path}" "${old_mount}" "${new_mount}"
  update_media_parts "${db_path}" "${old_mount}" "${new_mount}" 
  update_media_streams "${db_path}" "${old_mount}" "${new_mount}"
  commit_database_transaction "${db_path}"
}
```

## Testing Strategy for Refactoring

Given the complexity, create focused test scripts before refactoring:

### Unit Test Scripts (in `/tmp/`)

```bash
# /tmp/test-migration-strategy-logic.sh
# Test migration decision flow with various flag combinations

# /tmp/test-port-configuration.sh  
# Test port assignment and validation logic

# /tmp/test-database-path-updates.sh
# Test SQLite operations with mock database

# /tmp/test-ssh-hostname-resolution.sh
# Test hostname resolution and SSH connectivity

# /tmp/test-credential-handling.sh
# Test keychain operations and credential cleanup
```

## Refactoring Implementation Plan

### Phase 1: Function Decomposition (2-3 days)

**Priority:** HIGH - Addresses maintainability issues

1. Extract `main()` into 6-7 smaller functions (max 50 lines each)
2. Break down `setup_persistent_smb_mount()` into logical components
3. Split migration logic into separate functions per strategy
4. Extract database operations into dedicated functions

**Success Criteria:**

- No function longer than 75 lines
- Each function has single, clear responsibility
- All existing functionality preserved
- Zero shellcheck issues maintained

### Phase 2: Logic Simplification (1-2 days)  

**Priority:** MEDIUM - Improves readability and debugging

1. Implement migration strategy pattern
2. Centralize port configuration logic
3. Extract and deduplicate common patterns
4. Improve variable scoping

**Success Criteria:**

- Conditional nesting depth reduced by 50%
- No global variable modifications in nested functions
- Common patterns extracted into utilities

### Phase 3: Code Organization (1 day)

**Priority:** LOW - Polish and maintainability

1. Group related functions together
2. Add comprehensive function documentation  
3. Define constants section
4. Improve naming consistency

**Success Criteria:**

- Functions logically organized
- All magic numbers defined as constants
- Comprehensive inline documentation

## Quality Metrics Goals

**Current State:**

- Lines of Code: 1,654
- Longest Function: 287 lines (`main()`)
- Shellcheck Issues: 0 ✅
- Cyclomatic Complexity: High

**Target State (Post-1.0):**

- Lines of Code: <1,200 (25% reduction through deduplication)
- Longest Function: <75 lines
- Shellcheck Issues: 0 (maintained)
- Cyclomatic Complexity: Medium
- Function Count: ~35-40 (increased modularity)

## Risk Assessment

**Low Risk Refactoring:**

- Function extraction (preserves all logic)
- Variable scoping improvements
- Code deduplication
- Documentation additions

**Medium Risk Changes:**

- Migration strategy pattern implementation
- Database operation restructuring
- Configuration builder pattern

**Mitigation Strategy:**

1. Create comprehensive test suite before refactoring
2. Refactor incrementally with git commits at each stable state
3. Test each phase thoroughly before proceeding
4. Maintain functional equivalence throughout process

## Conclusion

The `plex-setup.sh` script represents excellent functional programming with room for significant structural improvement. The security practices, error handling, and feature completeness should be preserved while addressing the maintainability concerns identified in this review.

The recommended refactoring plan will result in a more maintainable, testable, and extensible codebase while preserving all existing functionality. This investment in code quality will pay dividends for future feature additions and maintenance efforts.

**Estimated Effort:** 4-6 days of focused development work  
**Risk Level:** Low (functionality preservation, incremental approach)  
**Business Value:** High (improved maintainability, easier debugging, enhanced testability)
