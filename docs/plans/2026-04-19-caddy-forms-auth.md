# Caddy Forms-Based Authentication Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Caddy's browser-native `basic_auth` challenge for external access with a form-based login that 1Password (and other password managers) can auto-fill.

**Motivation:** 1Password cannot auto-fill into browser basic-auth pop-ups. External access to `tilsit.vip` currently uses `basic_auth @external_auth_required` in the Caddyfile (lines 48–60 at time of writing), which triggers the pop-up. Switching to a form avoids that UX dead-end and matches how every other modern web service handles login.

**Architecture:** Rebuild the custom Caddy binary with the [`caddy-security`](https://github.com/greenpau/caddy-security) plugin alongside the existing `caddy-dns/cloudflare` module. caddy-security provides an authentication portal and `authorize` directive that together deliver a form login, JWT session cookie, and matcher-based bypass for the local network. All configuration stays in the Caddyfile. Single user, bcrypt-hashed password in the Caddyfile, no MFA.

**Tech Stack:** Caddy (custom build), `caddy-security` plugin, bcrypt, JWT (HS512), System keychain, LaunchDaemon.

**Scope boundaries:**

- **In scope:** form login for `tilsit.vip` external access; LAN traffic continues to bypass auth; existing TLS strategy (internal PKI + ACME/DNS-01) is unchanged.
- **Out of scope (deliberately):** multi-user, MFA/TOTP, OIDC/OAuth federation, account recovery flows, password rotation UX, admin CLI. If you want any of those later, they slot into caddy-security without rearchitecting.

**Known tradeoffs:**

- `caddy-security` releases lag Caddy core; if you `brew upgrade caddy`, the pinned custom build stays, but Caddy security patches require a rebuild with the plugin. You already accept this for `caddy-dns/cloudflare`; this adds one more module.
- JWT signing-key rotation invalidates all live sessions instantly. Acceptable for single-user home use.
- caddy-security's Caddyfile DSL is verbose and its own thing — expect the configuration diff to be 40–80 lines even for a minimal setup.

---

## File Layout

### In the repo (source)

```text
app-setup/caddy-setup.sh                       # +keychain check for JWT signing key, +placeholders
app-setup/templates/Caddyfile                  # -basic_auth, +security {} block, +authenticate/authorize
app-setup/templates/caddy-wrapper.sh           # +JWT_SIGNING_KEY injection from keychain
app-setup/templates/com.caddyserver.caddy.plist  # no change
docs/apps/caddy-README.md                      # +section on form auth / caddy-security
docs/apps/caddy-forms-auth-README.md           # new operations doc (see Task 8)
tests/                                         # BATS is optional here (no shell logic changes)
```

### On the server (deployed)

```text
/opt/homebrew/bin/caddy                        # rebuilt with caddy-security + caddy-dns/cloudflare
/opt/homebrew/bin/caddy.pre-forms-auth         # backup of current binary (rollback target)
/Users/operator/.config/caddy/Caddyfile        # updated config
/usr/local/bin/caddy-wrapper.sh                # reads two keychain entries now
System keychain:
  service=cloudflare-api-token  account=tilsit.vip           # existing
  service=caddy-jwt-signing-key account=tilsit.vip           # new (Task 3)
```

### Bootstrap credentials (1Password + keychain)

- New 1Password item: `Caddy external access - tilsit.vip` (or reuse an existing one). Contains the user/password the operator will type into the login form. 1Password will fill the form once it exists.
- New System keychain entry: JWT signing key, 256+ bits of randomness. Stays on TILSIT, never leaves.
- Existing System keychain entry: `cloudflare-api-token` — reused unchanged.

---

## Task 1: Add caddy-security to the custom binary build

Rebuild Caddy on the **dev machine** (not TILSIT) with both the Cloudflare DNS module and caddy-security, then rsync to TILSIT.

**Files:**

- Modify: `docs/apps/caddy-README.md` — extend the "Custom Caddy Build" section with the new download URL
- No code changes in this task

### Step 1: Build a binary with both modules

On the dev machine:

```bash
curl -L "https://caddyserver.com/api/download?os=darwin&arch=arm64&p=github.com%2Fcaddy-dns%2Fcloudflare&p=github.com%2Fgreenpau%2Fcaddy-security" \
  -o /tmp/caddy-forms
chmod +x /tmp/caddy-forms
/tmp/caddy-forms list-modules | grep -E "cloudflare|security"
```

Expected: `dns.providers.cloudflare` AND at least `security`, `http.handlers.authenticate`, `http.handlers.authorize` listed.

### Step 2: Stage on TILSIT, keep the old binary as rollback

```bash
rsync /tmp/caddy-forms operator@tilsit.local:/tmp/caddy-forms
```

On TILSIT as `operator`:

```bash
sudo cp /opt/homebrew/bin/caddy /opt/homebrew/bin/caddy.pre-forms-auth
sudo cp /tmp/caddy-forms /opt/homebrew/bin/caddy
/opt/homebrew/bin/caddy version
/opt/homebrew/bin/caddy list-modules | grep -E "cloudflare|security"
```

**Do not restart Caddy yet.** The deployed Caddyfile still uses `basic_auth`; the new binary is backward compatible with that directive, so Caddy will keep running — but you want to sequence the binary swap and Caddyfile swap so each can be tested independently.

### Step 3: Re-pin in Homebrew

As `andrewrich`:

```bash
/opt/homebrew/bin/brew unpin caddy || true
/opt/homebrew/bin/brew pin caddy
/opt/homebrew/bin/brew list --pinned | grep caddy
```

### Step 4: Commit the doc changes

```bash
git add docs/apps/caddy-README.md
git commit -m "docs(caddy): document custom build with caddy-security module"
```

---

## Task 2: Generate and install the JWT signing key

The session cookie is a signed JWT. We need a long-lived secret for HS512 signing.

**Files:** none (keychain + 1Password only)

### Step 1: Generate 64 random bytes, base64-encoded

On the dev machine:

```bash
JWT_KEY=$(openssl rand -base64 64 | tr -d '\n')
echo "length: ${#JWT_KEY}"   # expect ≥ 88
```

### Step 2: Stash in 1Password for recovery

Create 1Password item `Caddy JWT signing key - tilsit.vip`, Password field = the base64 string. You'll need this if you ever reinstall TILSIT.

### Step 3: Install into System keychain on TILSIT

From the dev machine:

```bash
ssh operator@tilsit.local "sudo security add-generic-password -U \
  -s 'caddy-jwt-signing-key' \
  -a 'tilsit.vip' \
  -w '${JWT_KEY}' \
  /Library/Keychains/System.keychain"
unset JWT_KEY
```

### Step 4: Verify retrieval

On TILSIT as `andrewrich`:

```bash
sudo security find-generic-password -s caddy-jwt-signing-key -a tilsit.vip \
  /Library/Keychains/System.keychain -w | wc -c
```

Expected: a single line, same length as `${#JWT_KEY}` + 1 (newline).

### Step 5: No commit — this task is keychain-only

---

## Task 3: Teach `caddy-wrapper.sh` to inject JWT_SIGNING_KEY

Same pattern as `CF_API_TOKEN`.

**Files:**

- Modify: `app-setup/templates/caddy-wrapper.sh`

### Step 1: Extend the wrapper

Current wrapper reads one key. Change to read two:

```bash
#!/usr/bin/env bash
# caddy-wrapper.sh — reads CF_API_TOKEN + JWT_SIGNING_KEY from System keychain,
# then exec's Caddy. Run as root via LaunchDaemon.
set -euo pipefail

keychain_read() {
  local service="$1" account="$2"
  security find-generic-password -s "${service}" -a "${account}" -w \
    /Library/Keychains/System.keychain
}

CF_API_TOKEN=$(keychain_read "cloudflare-api-token" "__EXTERNAL_HOSTNAME__") || {
  echo "ERROR: cloudflare-api-token not found in System keychain" >&2
  exit 1
}
JWT_SIGNING_KEY=$(keychain_read "caddy-jwt-signing-key" "__EXTERNAL_HOSTNAME__") || {
  echo "ERROR: caddy-jwt-signing-key not found in System keychain" >&2
  exit 1
}
export CF_API_TOKEN JWT_SIGNING_KEY

exec /opt/homebrew/bin/caddy run \
  --config /Users/__OPERATOR_USERNAME__/.config/caddy/Caddyfile \
  --adapter caddyfile
```

### Step 2: shellcheck + shfmt

```bash
shellcheck --severity=warning --exclude=SC2312 app-setup/templates/caddy-wrapper.sh
shfmt -d -i 2 -ci -bn app-setup/templates/caddy-wrapper.sh
```

Both should exit 0.

### Step 3: Commit

```bash
git add app-setup/templates/caddy-wrapper.sh
git commit -m "feat(caddy): inject JWT_SIGNING_KEY alongside CF_API_TOKEN"
```

---

## Task 4: Pick and hash the login password

**Files:** none (1Password + local hash)

### Step 1: Choose a password and stash in 1Password

Create a strong password. Save to 1Password as `Caddy external access - tilsit.vip` (field: password). This is what you'll type/autofill into the form.

### Step 2: Generate the bcrypt hash

```bash
caddy hash-password
```

(Or on any machine with Caddy, `caddy hash-password --plaintext '<your-password>'`.)

Expected output: `$2a$14$...` string. Save that string for Task 5. **Do not commit it.**

### Step 3: Add `BASICAUTH_HASH` replacement to `config.conf` (temporary holding spot)

You already keep `BASICAUTH_HASH` in `config/config.conf` (gitignored) for the old basic_auth directive. The new form-auth reuses the same hash format and the same config var — no new placeholder needed. Just update the value:

```bash
# In config/config.conf (already gitignored):
BASICAUTH_HASH='$2a$14$<new-hash-from-step-2>'
```

---

## Task 5: Rewrite the Caddyfile to use form auth

This is the biggest single change. The `common_config` snippet gets a new authentication portal and the external block swaps `basic_auth` for `authorize`.

**Files:**

- Modify: `app-setup/templates/Caddyfile`
- Modify: `app-setup/caddy-setup.sh` (validate the new JWT env var is set before substitution; add a `caddy validate` dummy value for `JWT_SIGNING_KEY`)

### Step 1: Add the `security` global block

Near the top of the Caddyfile, alongside the existing `pki` block inside the global `{ … }`:

```caddyfile
{
  pki {
    ca local {
      name "Home Server CA"
      intermediate_lifetime 90d
    }
  }

  security {
    local identity store localauth {
      realm local
      path /Users/__OPERATOR_USERNAME__/.config/caddy/users.json
    }

    authentication portal authp {
      crypto default token lifetime 86400
      crypto key sign-verify {$JWT_SIGNING_KEY}
      enable identity store localauth
      cookie domain __EXTERNAL_HOSTNAME__
      cookie lifetime 86400
      cookie samesite lax
      ui {
        links {
          "Dashboard" / icon "las la-home"
          "Sign Out" /auth/logout icon "las la-sign-out-alt"
        }
      }
      transform user {
        match origin local
        action add role authp/user
      }
    }

    authorization policy external_policy {
      set auth url https://__EXTERNAL_HOSTNAME__/auth/
      crypto key verify {$JWT_SIGNING_KEY}
      allow roles authp/user
    }
  }
}
```

### Step 2: Replace `basic_auth` with `authenticate` + `authorize`

Inside `(common_config)`, delete the existing `basic_auth @external_auth_required { ... }` block and replace with:

```caddyfile
# Authentication portal — serves the login form at /auth/
route /auth* {
  authenticate with authp
}

# Authorization gate — protects everything else on external access.
# @local_network already bypasses the match; @external_auth_required is
# preserved as the "needs auth" matcher.
route @external_auth_required {
  authorize with external_policy
}
```

Leave the `@local_network` / `@external_auth_required` matchers as they are (they still gate on remote IP + host).

### Step 3: Create `users.json` template

caddy-security's local store wants a JSON file. Create it as a template alongside Caddyfile:

`app-setup/templates/caddy-users.json`:

```json
{
  "users": [
    {
      "id": "__OPERATOR_USERNAME__",
      "username": "__BASICAUTH_USERNAME__",
      "password": "__BASICAUTH_HASH__",
      "email": "__MONITORING_EMAIL__",
      "roles": ["authp/user"],
      "enabled": true
    }
  ]
}
```

**Two edits to `caddy-setup.sh`:**

1. Extend the `substitute_template()` function body to cover the new placeholder. The existing sed list does not include `__MONITORING_EMAIL__`, so add it:

    ```bash
    -e "s|__MONITORING_EMAIL__|${MONITORING_EMAIL}|g" \
    ```

    and load `MONITORING_EMAIL` from `config.conf` near the top of the script (same pattern the existing vars use): `MONITORING_EMAIL="${MONITORING_EMAIL:-}"`.

2. Add the invocation that deploys `users.json`:

    ```bash
    substitute_template "${TEMPLATE_DIR}/caddy-users.json" "${DEPLOY_CONFIG_DIR}/users.json"
    chown "${OPERATOR_USERNAME}:staff" "${DEPLOY_CONFIG_DIR}/users.json"
    chmod 600 "${DEPLOY_CONFIG_DIR}/users.json"
    ```

**Mode 0600 is mandatory** — the file contains the bcrypt password hash.

### Step 4: Validate locally

On the dev machine (requires caddy-security binary, not the Homebrew stock one):

```bash
export HOSTNAME=TILSIT
export CF_API_TOKEN=dummy0token0for0validation0only000000000
export JWT_SIGNING_KEY=dummy0jwt0signing0key0for0validation0only00000000000000000000000
/tmp/caddy-forms validate --config /tmp/Caddyfile.substituted --adapter caddyfile
```

Expected: `Valid configuration`.

### Step 5: Commit

```bash
git add app-setup/templates/Caddyfile app-setup/templates/caddy-users.json app-setup/caddy-setup.sh
git commit -m "feat(caddy): replace basic_auth with caddy-security form-based portal"
```

---

## Task 6: Update `caddy-setup.sh` to require the new token

Add preflight checks mirroring the existing Cloudflare token check.

**Files:**

- Modify: `app-setup/caddy-setup.sh`

### Step 1: Add preflight check for `MONITORING_EMAIL`

The `users.json` template (Task 5 Step 3) uses `__MONITORING_EMAIL__`, so the value must be non-empty before substitution or the deployed file would contain a literal placeholder.

```bash
if [[ -z "${MONITORING_EMAIL:-}" ]]; then
  echo "❌ MONITORING_EMAIL is required (used for caddy-security user identity)"
  echo "   Set MONITORING_EMAIL in config/config.conf"
  exit 1
fi
```

### Step 2: Add keychain check

Near the existing keychain-entry check for `cloudflare-api-token`, add:

```bash
if ! security find-generic-password \
  -s "caddy-jwt-signing-key" \
  -a "${EXTERNAL_HOSTNAME}" \
  /Library/Keychains/System.keychain >/dev/null 2>&1; then
  echo "❌ Keychain entry not found:"
  echo "   service=caddy-jwt-signing-key account=${EXTERNAL_HOSTNAME}"
  echo
  echo "   Generate and install with:"
  echo "   JWT=\$(openssl rand -base64 64 | tr -d \\\\n)"
  echo "   sudo security add-generic-password -U \\"
  echo "     -s 'caddy-jwt-signing-key' -a '${EXTERNAL_HOSTNAME}' \\"
  echo "     -w \"\${JWT}\" /Library/Keychains/System.keychain"
  exit 1
fi
```

### Step 3: Update the `caddy validate` invocation with a dummy JWT key

The existing `DUMMY_TOKEN` pattern lets `caddy validate` run without real credentials. Extend it:

```bash
DUMMY_TOKEN="dummy0token0for0validation0only000000000"
DUMMY_JWT="dummy0jwt0signing0key0for0validation0only00000000000000000000000"
if HOSTNAME="${HOSTNAME}" \
   CF_API_TOKEN="${DUMMY_TOKEN}" \
   JWT_SIGNING_KEY="${DUMMY_JWT}" \
   "${CADDY_BIN}" validate --config "${DEPLOY_CONFIG_DIR}/Caddyfile" 2>&1; then
  echo "✓ Configuration valid"
else
  echo "❌ Configuration validation failed"
  exit 1
fi
```

### Step 4: shellcheck + shfmt

```bash
shellcheck --severity=warning --exclude=SC2312 app-setup/caddy-setup.sh
shfmt -d -i 2 -ci -bn app-setup/caddy-setup.sh
```

### Step 5: Commit

```bash
git add app-setup/caddy-setup.sh
git commit -m "feat(caddy-setup): require JWT signing key + email before deploy"
```

---

## Task 7: Deploy, test, document rollback

This is the cutover. Do it when you have 20 minutes of uninterrupted keyboard time — the external site is briefly unreachable during the restart.

### Step 1: Fresh Caddy binary already on TILSIT (from Task 1)

Verify:

```bash
/opt/homebrew/bin/caddy list-modules | grep -E "security|cloudflare" | wc -l
# expect ≥ 2
ls -l /opt/homebrew/bin/caddy.pre-forms-auth  # rollback binary exists
```

### Step 2: Back up the current deployed Caddyfile

**Do this before running `caddy-setup.sh` in the next step — otherwise the rollback in Step 7 has nothing to restore from.**

```bash
sudo -iu operator cp \
  ~/.config/caddy/Caddyfile \
  ~/.config/caddy/Caddyfile.pre-forms-auth.$(date +%Y%m%d)
ls -l /Users/operator/.config/caddy/Caddyfile.pre-forms-auth.*
```

Expected: one backup file listed with today's date.

### Step 3: Deploy the new Caddyfile

On TILSIT, from the repo:

```bash
cd app-setup
set -a; source config/config.conf; set +a
sudo -E ./caddy-setup.sh
```

Expected:

- `✓ Installed /Users/operator/.config/caddy/Caddyfile`
- `✓ Installed /Users/operator/.config/caddy/users.json` (mode 600)
- `✓ Configuration valid`

### Step 4: Restart Caddy

```bash
sudo launchctl kickstart -k system/com.caddyserver.caddy
sleep 5
sudo launchctl print system/com.caddyserver.caddy | grep -E "state|last exit code"
```

Expected: `state = running`, `last exit code = 0`.

### Step 5: Functional tests

```bash
# LAN access still bypasses auth
curl -ksI https://tilsit.local/ | head -3
# expect HTTP/2 200

# External path: unauthenticated hit redirects to /auth/
curl -ksI https://tilsit.vip:443/ | grep -E "HTTP|location"
# expect HTTP/2 302 + location: /auth/

# External path: /auth/ serves the login form
curl -ks https://tilsit.vip:443/auth/ | grep -qi '<form' && echo "form present"

# The old basic_auth WWW-Authenticate header must NOT appear
curl -ksI https://tilsit.vip:443/ | grep -i "www-authenticate" && echo "BUG: still sending basic_auth" || echo "basic_auth gone"
```

### Step 6: Browser test

From a device **off the LAN** (cellular, VPN off):

1. Visit `https://tilsit.vip/`
2. Expect redirect to `https://tilsit.vip/auth/`
3. Expect 1Password to offer to fill the saved credential
4. Submit → expect redirect back to `/` with a session cookie
5. Navigate to `/transmission/` — expect no re-prompt
6. Visit `/auth/logout` → expect session cleared

If any step fails, proceed to rollback.

### Step 7: Rollback plan (if anything is broken)

Relies on the backups created in Task 1 Step 2 (`/opt/homebrew/bin/caddy.pre-forms-auth`) and Task 7 Step 2 (`~/.config/caddy/Caddyfile.pre-forms-auth.YYYYMMDD`). Both must exist before you hit this step.

```bash
sudo cp /opt/homebrew/bin/caddy.pre-forms-auth /opt/homebrew/bin/caddy
sudo -iu operator cp ~/.config/caddy/Caddyfile.pre-forms-auth.$(date +%Y%m%d) ~/.config/caddy/Caddyfile
sudo launchctl kickstart -k system/com.caddyserver.caddy
```

### Step 8: Announce completion in commit

```bash
git add -A   # only the docs/templates that changed, no secrets
git commit -m "feat(caddy): cut over to caddy-security form auth"
```

---

## Task 8: Write the operations doc

Add a new service-README alongside `docs/apps/caddy-README.md`.

**Files:**

- Create: `docs/apps/caddy-forms-auth-README.md`
- Modify: `CLAUDE.md` — add a bullet to the "Service-Specific Documentation" section pointing at the new README

### Step 1: Topics to cover in `caddy-forms-auth-README.md`

- Where the login form lives (`/auth/`) and what a session cookie looks like
- How to rotate the JWT signing key (and the session-invalidation implication)
- How to change the password (regenerate bcrypt hash, edit `users.json` in place, `kickstart` Caddy)
- Why `BASICAUTH_USERNAME`/`BASICAUTH_HASH` kept their names even though basic-auth is gone (deliberate — avoids a config migration)
- How to temporarily disable auth for debugging (comment the `authorize` line, restart Caddy, never leave it that way)
- Rollback procedure from Task 7 Step 7

### Step 2: Add `CLAUDE.md` entry

Under the Caddy entry, mention the auth model is form-based via caddy-security and point at the new README. Keep it to two or three lines.

### Step 3: markdownlint

```bash
npx markdownlint-cli@0.47.0 --disable=MD013 docs/apps/caddy-forms-auth-README.md CLAUDE.md
```

### Step 4: Commit

```bash
git add docs/apps/caddy-forms-auth-README.md CLAUDE.md
git commit -m "docs(caddy): document form-auth operations and rollback"
```

---

## Effort Summary

| Task | Wall-clock |
|------|-----------|
| 1. Custom Caddy build | 30–60 min |
| 2. JWT signing key into keychain | 15 min |
| 3. Update `caddy-wrapper.sh` | 30 min |
| 4. Pick + hash password | 10 min |
| 5. Caddyfile rewrite + users.json | 2 hours |
| 6. `caddy-setup.sh` preflight | 30 min |
| 7. Deploy, test, verify 1Password flow | 30–60 min |
| 8. Docs | 45 min |
| **Total** | **~5–6 hours** (realistic one-morning project) |

---

## Risks Recap

1. **Browser-level basic_auth credential caching.** Once the new Caddyfile is live, browsers that cached the old basic-auth credential for `tilsit.vip` may keep sending `Authorization: Basic` headers in addition to following the redirect. caddy-security ignores them, but it can make the "first login after cutover" confusing. Tell any human user to close/reopen the browser after cutover.
2. **`caddy-security` Caddyfile DSL drift.** The plugin's syntax has changed across releases. Verify against the exact tag of `caddy-security` that `greenpau/caddy-security` latest resolves to when you execute Task 1 — pin to that tag in the README if the `?p=` download-API URL supports it.
3. **`enable identity store localauth` may need to be `enable identity_store localauth`** (underscore vs space) depending on plugin version. If `caddy validate` rejects the snippet in Task 5 Step 1, this is the first thing to try.
4. **`users.json` is sensitive.** Mode must be 0600. `caddy-setup.sh` enforces this, but verify after every redeploy: `ls -l ~/.config/caddy/users.json`.
5. **Keychain-access symmetry.** If you ever migrate TILSIT to a new machine, both `cloudflare-api-token` AND `caddy-jwt-signing-key` must be reinstalled. Add that to whatever disaster-recovery doc you maintain.

---

## Out-of-Scope Follow-Ups (park these, don't bundle)

- **MFA via TOTP.** `caddy-security` supports it; adds ~1 hour.
- **OIDC for remote family members.** Adds `google`/`github` as identity stores; deletes `users.json`. ~2 hours.
- **Session logout UI.** Currently `/auth/logout` works via direct URL; adding a dashboard button is UI-only work.
- **Remember-me cookie beyond 24 hours.** Lifetime is tunable in `token lifetime` and `cookie lifetime`; trivial but has security implications.
- **Per-path authorization.** e.g. allow `/health` unauthenticated even externally. caddy-security's policies support this; add a second `authorization policy` for the exempted paths.
