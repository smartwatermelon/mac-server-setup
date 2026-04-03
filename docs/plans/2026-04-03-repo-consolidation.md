# Repo Consolidation: Merge tilsit-caddy and transmission-filebot into mac-server-setup

**Date**: 2026-04-03
**Status**: Planned
**Author**: Andrew Rich + Claude

## Motivation

Caddy and Transmission-FileBot are essential, integral parts of the media server
system. Maintaining them as separate repositories creates friction without benefit:
separate CI, separate PRs, cross-repo references that break, duplicated Claude
review workflows. Consolidating into mac-server-setup makes the system one coherent
codebase.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Post-merge fate of source repos | Archive on GitHub | Preserves history, prevents confusion |
| Git history | Clean import (no merged histories) | Archived repos keep full history; merged histories create confusing interleaved logs |
| Directory structure | Integrate into existing conventions | No new top-level dirs; files go to `app-setup/`, `app-setup/templates/`, `tests/`, `docs/` |
| Merge order | tilsit-caddy first, then transmission-filebot | Simpler merge first validates the pattern |
| CLAUDE.md content | Move to `docs/apps/` with mandatory references in main CLAUDE.md | Protocol-level directives, not footnotes |
| CI | Add BATS job to existing `ci.yml`; drop subsidiary workflows | Existing lint jobs cover new files automatically |
| TEST_MODE in transmission-done.sh | Remove (known debt) | Complex, fragile; BATS suite is the real safety net. Revisit if coverage gaps emerge. |
| install.sh | Rename to `transmission-filebot-setup.sh` in `app-setup/` | Distinct from `filebot-setup.sh` (installs FileBot app vs configures pipeline) |
| PIA VPN bypass content | Strip from imported Caddy docs | Host-level PIA is gone; only VPN-in-Pod remains |

## File Mapping: tilsit-caddy

| Source (tilsit-caddy) | Destination (mac-server-setup) | Notes |
|---|---|---|
| `caddy-setup.sh` | `app-setup/caddy-setup.sh` | Peer to plex-setup.sh |
| `Caddyfile` | `app-setup/templates/Caddyfile` | Deployed by caddy-setup.sh |
| `caddy-wrapper.sh` | `app-setup/templates/caddy-wrapper.sh` | CF_API_TOKEN injection |
| `caddy-health.sh` | `app-setup/templates/caddy-health.sh` | Health check script |
| `media-server.py` | `app-setup/templates/media-server.py` | NFS file server |
| `LaunchDaemons/*.plist` | `app-setup/templates/` | Both caddy and media-server plists |
| `www/*` | `app-setup/templates/www/` | Dashboard static assets |
| `caddy-root-ca.crt` | `app-setup/templates/caddy-root-ca.crt` | Internal CA cert |
| `simple/` | Drop | Troubleshooting scratch |
| `CLAUDE.md` | `docs/apps/caddy-README.md` | Strip PIA VPN bypass content |
| `README.md` | Fold into `docs/apps/caddy-README.md` | |
| `MIGRATE-TO-DNS01.md` | `docs/apps/caddy-dns01-migration.md` | Historical reference |
| `docs/plans/*` | `docs/plans/` | Merge into existing plans dir |
| `docs/cloudflare-migration-checklist.md` | `docs/apps/caddy-cloudflare-checklist.md` | Completed checklist |
| `.github/workflows/*` | Drop | mac-server-setup CI covers these |

## File Mapping: transmission-filebot

| Source (transmission-filebot) | Destination (mac-server-setup) | Notes |
|---|---|---|
| `transmission-done.sh` | `app-setup/templates/transmission-done.sh` | Strip TEST_MODE infrastructure |
| `install.sh` | `app-setup/transmission-filebot-setup.sh` | Pipeline configuration wizard |
| `run_tests.sh` | `run_tests.sh` (root) | Updated paths to `tests/transmission-filebot/` |
| `process-media.command` | `app-setup/templates/process-media.command` | Manual invocation wrapper |
| `config.yml.template` | `app-setup/templates/config.yml.template` | Pipeline config template |
| `test/test_helper.bash` | `tests/transmission-filebot/test_helper.bash` | Updated SCRIPT_DIR |
| `test/fixtures/` | `tests/transmission-filebot/fixtures/` | Test data |
| `test/unit/*.bats` | `tests/transmission-filebot/unit/*.bats` | Updated load paths |
| `test/integration/*.bats` | `tests/transmission-filebot/integration/*.bats` | Updated load paths |
| `CLAUDE.md` | `docs/apps/transmission-filebot-README.md` | Operational reference |
| `README.md` | Fold into `docs/apps/transmission-filebot-README.md` | |
| `CREATE_AUTOMATOR_APP.md` | `docs/apps/transmission-filebot-automator.md` | User guide |
| `.github/workflows/*` | Drop | BATS job added to ci.yml |
| `.gitignore` entries | Merge into mac-server-setup `.gitignore` | config.yml exclusion |

## CLAUDE.md Updates

The main CLAUDE.md gets a new **Service-Specific Documentation** section treated as
mandatory protocol-level directives (not footnotes):

```markdown
## Service-Specific Documentation

**MANDATORY: Before modifying any files related to these services,
read the corresponding documentation first.**

### Caddy (reverse proxy, TLS, dashboard)
**Files**: `app-setup/caddy-setup.sh`, `app-setup/templates/Caddyfile`,
`app-setup/templates/caddy-*.sh`, `app-setup/templates/media-server.py`,
`app-setup/templates/www/`
**Documentation**: `docs/apps/caddy-README.md`
**Covers**: TLS strategy (internal PKI + DNS-01 Cloudflare), custom Caddy build
with cloudflare module, CF_API_TOKEN injection chain, media file server
architecture (why Python not Caddy), DNS propagation timing

### Transmission-FileBot (media processing pipeline)
**Files**: `app-setup/templates/transmission-done.sh`,
`app-setup/transmission-filebot-setup.sh`, `app-setup/templates/config.yml.template`,
`app-setup/templates/process-media.command`, `tests/transmission-filebot/`
**Documentation**: `docs/apps/transmission-filebot-README.md`
**Covers**: FileBot invocation and output parsing, Plex API section IDs,
NFS/VirtioFS cache invalidation, Transmission's limited execution environment,
test architecture (BATS, TEST_RUNNER mode), file stability checks
```

## CI Changes

### Add to `.github/workflows/ci.yml`

```yaml
bats:
  runs-on: macos-latest
  needs: detect-changes
  if: needs.detect-changes.outputs.shell == 'true'
  steps:
    - uses: actions/checkout@v4
    - name: Install BATS
      run: brew install bats-core
    - name: Run all BATS tests
      run: bats tests/**/*.bats
```

Existing jobs that auto-cover new files:

- **shellcheck**: all `.sh` files (covers caddy scripts, transmission-done.sh)
- **shfmt**: all `.sh` files
- **html-tidy**: all `.html` files (covers Caddy dashboard)
- **flake8**: all `.py` files (covers media-server.py)

### Drop from subsidiary repos

- `tilsit-caddy/.github/workflows/*` (Claude review only, already in mac-server-setup)
- `transmission-filebot/.github/workflows/test.yml` (replaced by mac-server-setup ci.yml)
- `transmission-filebot/.github/workflows/claude.yml` (already in mac-server-setup)

## Test Directory Structure (Post-Merge)

```
tests/
├── plex-watchdog.bats                      # Existing
├── fixtures/                               # Existing plex-watchdog fixtures
│   ├── golden-basic.conf
│   ├── golden-multi.conf
│   └── plex-prefs-sample.xml
└── transmission-filebot/                   # New
    ├── test_helper.bash                    # Updated SCRIPT_DIR paths
    ├── fixtures/
    │   └── media/
    ├── unit/
    │   ├── test_mode_detection.bats
    │   ├── test_type_detection.bats
    │   ├── test_plex_api.bats
    │   ├── test_filebot.bats
    │   ├── test_error_logging.bats
    │   └── test_file_safety.bats
    └── integration/
        ├── test_tv_workflow.bats
        ├── test_movie_workflow.bats
        └── test_manual_mode.bats
```

## Path Audit Checklist

### tilsit-caddy paths to verify after import

- [ ] `caddy-setup.sh`: source paths for file copies (`./Caddyfile` etc. must resolve from `app-setup/`)
- [ ] `caddy-health.sh`: references deployed system paths only (no repo-relative)
- [ ] `caddy-wrapper.sh`: references deployed paths only
- [ ] `media-server.py`: standalone, no repo-relative paths
- [ ] LaunchDaemon plists: reference deployed paths only
- [ ] `www/index.html`: self-contained, no repo-relative paths
- [ ] `caddy-root-ca.crt`: static file, no paths

### transmission-filebot paths to verify after import

- [ ] `transmission-done.sh`: `SCRIPT_DIR` resolution still works from `app-setup/templates/`
- [ ] `transmission-done.sh`: TEST_MODE infrastructure fully removed
- [ ] `transmission-filebot-setup.sh`: path to `config.yml.template` updated
- [ ] `test_helper.bash`: `SCRIPT_DIR` updated to find `app-setup/templates/transmission-done.sh`
- [ ] Every `.bats` file: `load` paths for test_helper resolve correctly
- [ ] `run_tests.sh`: test directory paths updated to `tests/transmission-filebot/`
- [ ] `process-media.command`: references symlink, not repo path

### Systematic sweep after each merge commit

```bash
# Old repo-relative paths that should not exist
grep -rn '\./transmission-done\|/transmission-filebot/' tests/ app-setup/
grep -rn '\./Caddyfile\|\./caddy-\|/tilsit-caddy/' app-setup/
# Broken test helper loads
grep -rn 'load.*test_helper' tests/
# Unresolved placeholders
grep -rn '__[A-Z_]*__' app-setup/templates/
```

## Commit Structure

### Phase 1: tilsit-caddy (3 commits)

1. `feat: import tilsit-caddy into mac-server-setup`
   - Copy files per mapping, strip PIA content from docs
   - Reference: "Imported from smartwatermelon/tilsit-caddy (archived)"

2. `feat: integrate caddy into app-setup pipeline`
   - Fix paths in caddy-setup.sh
   - Add caddy to run-app-setup.sh dependency ordering
   - Update main CLAUDE.md with Caddy reference

3. `test: verify caddy integration`
   - Run and fix shellcheck/shfmt/html-tidy/flake8

### Phase 2: transmission-filebot (3 commits)

4. `feat: import transmission-filebot into mac-server-setup`
   - Copy files per mapping, strip TEST_MODE
   - Reference: "Imported from smartwatermelon/transmission-filebot (archived)"

5. `feat: integrate transmission-filebot into app-setup pipeline`
   - Fix all test paths and script references
   - Update main CLAUDE.md with transmission-filebot reference

6. `test: verify transmission-filebot integration`
   - Run and fix shellcheck/shfmt, run full BATS suite

### Phase 3: CI & cleanup (2 commits)

7. `ci: add BATS job to CI workflow`

8. `docs: update README and documentation for merged repos`

## Review Protocol

Every commit gets the full local review spectrum:

- **code-reviewer**: Standard code quality review
- **adversarial-reviewer**: Failure modes, edge cases, security
- **architect-review**: Structural integrity (especially commits 1-2 and 4-5)

Full-diff adversarial review before push:

```bash
git diff main..HEAD | claude --agent adversarial-reviewer -p --tools ""
```

## Post-Merge

- [ ] Full CI passes on PR
- [ ] Archive smartwatermelon/tilsit-caddy with "moved to mac-server-setup" notice
- [ ] Archive smartwatermelon/transmission-filebot with "moved to mac-server-setup" notice

## Known Debt

- **TEST_MODE removal**: If BATS coverage proves insufficient in the future, revisit
  how transmission-done.sh self-tests. The inline test infrastructure was stripped for
  complexity/fragility reasons, not because it was unnecessary.
