#!/usr/bin/env bash
#
# stable-sign.sh - Keep stably-signed, stably-located copies of Homebrew
# binaries so macOS privacy (TCC) grants survive `brew upgrade`.
#
# THE PROBLEM
#
# macOS keys a TCC grant ("podman-remote would like to access files on a
# network volume", Full Disk Access, etc.) on two things:
#
#   1. the executable's resolved on-disk path  (the row's `client` column), and
#   2. a code requirement derived from its signature (the `csreq` column).
#
# Homebrew binaries fail both. They live at a versioned Cellar path
# (/opt/homebrew/Cellar/podman/6.1.1/bin/podman-remote) that changes with
# every release, and they are only ad-hoc linker-signed with the generic
# identifier "a.out", so the only requirement macOS can derive is the
# binary's cdhash - which also changes with every release. Result: every
# `brew upgrade` silently invalidates the grant and the next time the
# binary (or a process it is responsible for, such as the Podman VM's
# Virtualization.framework helper) touches the protected resource, the
# user is prompted again. On an unattended server that prompt blocks the
# calling process until someone clicks Allow. Observed on TILSIT: a
# container recreate stalled 35 minutes on 2026-09-03 for exactly this.
#
# THE FIX
#
# For each configured formula, mirror its `bin/` (and `libexec/`, if any)
# from Homebrew's version-independent opt/ link into a fixed prefix
# (default /usr/local/stable/<formula>/), then re-sign the named binaries
# with a local self-signed code-signing identity and a fixed identifier.
# The designated requirement becomes
#
#   identifier "<prefix>.<bin>" and certificate root = H"<cert sha1>"
#
# which is stable across upgrades, and the path is stable too. macOS
# records the grant once and it keeps matching. Callers that need the
# grant must invoke the stable copy (e.g. put /usr/local/stable/podman/bin
# ahead of /opt/homebrew/bin in PATH).
#
# Only the binaries listed in STABLE_TARGETS are re-signed. Helpers copied
# alongside them (podman's vfkit, gvproxy) keep their original signatures -
# vfkit in particular carries the com.apple.security.virtualization
# entitlement, which `codesign -f` without --entitlements would strip.
#
# Re-signing is done on a temp copy that is then mv'd into place, so a
# running process keeps its old inode. Note that re-signing a binary that
# is the *responsible path* of a live process (a running VM) triggers one
# more prompt on that process's next protected access, because the stored
# requirement no longer matches. That happens once, at adoption time.
#
# USAGE
#
#   stable-sign.sh                 sync + sign anything whose source changed
#   stable-sign.sh --check         report state; exit 1 if anything is stale
#   stable-sign.sh --force         re-sync and re-sign even if unchanged
#   stable-sign.sh --ensure-identity   only create the signing identity
#
# Deployed to /usr/local/bin/__HOSTNAME_LOWER__-stable-sign.sh by
# scripts/server/setup-auto-updates.sh, which also runs it at the end of
# every daily brew upgrade. Runs as the administrator; needs sudo only to
# create the signing identity and the stable root the first time.
#
# SECURITY NOTE: the identity is a stable label, not a trust boundary. Its
# private key is imported with an ACL that lets /usr/bin/codesign use it for
# any local user, so every account on the machine can produce a binary that
# satisfies the requirement. The only thing that keeps an attacker from
# inheriting a grant is that TCC also keys on the path and the mirror is
# writable by the administrator only. That is the same boundary Homebrew's
# own binaries already have.
#
# Documentation: docs/apps/stable-signing-README.md

set -euo pipefail

HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
STABLE_ROOT="${STABLE_ROOT:-/usr/local/stable}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-__HOSTNAME__ Local Code Signing}"
IDENTIFIER_PREFIX="${IDENTIFIER_PREFIX:-local.__HOSTNAME_LOWER__.stable}"
KEYCHAIN="${KEYCHAIN:-/Library/Keychains/System.keychain}"
CERT_DAYS="${CERT_DAYS:-3650}"

# formula:bin[,bin...] - bin names under <formula>/bin/ that get re-signed.
# Everything in bin/ and libexec/ is mirrored; only these are re-signed.
# Names are split on commas and whitespace, so no spaces or glob characters.
#
# macOS attributes a protected access to the first non-Apple binary below
# the LaunchAgent's /bin/bash, so every Homebrew binary on that path needs a
# stable copy. The podman supervisor's chain is timeout (coreutils gtimeout)
# -> podman-remote -> vfkit; with only podman mirrored the prompt moved to
# gtimeout (measured 2026-09-03).
STABLE_TARGETS=(
  "podman:podman-remote"
  "coreutils:gtimeout"
)

MODE="sync"
FORCE=false
for arg in "$@"; do
  case "${arg}" in
    --check) MODE="check" ;;
    --force) FORCE=true ;;
    --ensure-identity) MODE="identity" ;;
    -h | --help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
  esac
done

# Scratch directory for private key material during identity creation.
# Removed on every exit path, including die().
WORK_DIR=""
cleanup() {
  if [[ -n "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S' || true)
  printf '[%s] [stable-sign] %s\n' "${ts}" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Signing identity
# ---------------------------------------------------------------------------

# The identity list is captured before it is searched. Piping it into
# `grep -q` (or an awk that exits on the first match) under pipefail fails at
# random: the reader exits early and `security` takes SIGPIPE writing its
# "N identities found" trailer.
identity_list() {
  # No -v: a self-signed identity reports CSSMERR_TP_NOT_TRUSTED and is
  # filtered out by -v, yet codesign uses it fine.
  security find-identity -p codesigning "${KEYCHAIN}" 2>/dev/null || true
}

identity_present() {
  local list
  list=$(identity_list)
  grep -q "\"${SIGNING_IDENTITY}\"" <<<"${list}"
}

# Hash of the identity (certificate + private key), taken from the identity
# list rather than find-certificate: a stray certificate with the same label
# but no key would otherwise be picked up, and codesign never signs with it.
cert_sha1() {
  local list
  list=$(identity_list)
  awk -v name="\"${SIGNING_IDENTITY}\"" 'index($0, name) {print tolower($2); exit}' <<<"${list}"
}

ensure_identity() {
  local sha1
  if identity_present; then
    sha1=$(cert_sha1 || true)
    log "signing identity present: \"${SIGNING_IDENTITY}\" (${sha1})"
    return 0
  fi

  log "creating signing identity \"${SIGNING_IDENTITY}\" in ${KEYCHAIN}"
  WORK_DIR="$(mktemp -d)"
  chmod 700 "${WORK_DIR}"
  local work="${WORK_DIR}"

  cat >"${work}/cs.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=${SIGNING_IDENTITY}
O=mac-server-setup
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF

  openssl req -x509 -newkey rsa:2048 -sha256 -days "${CERT_DAYS}" -nodes \
    -keyout "${work}/key.pem" -out "${work}/cert.pem" -config "${work}/cs.cnf" \
    >/dev/null 2>&1 || die "openssl failed to generate the certificate"

  # macOS `security import` cannot read OpenSSL 3's default PKCS#12
  # encryption; force the legacy algorithms (also what LibreSSL emits).
  local p12_pass
  p12_pass="$(openssl rand -hex 16)"
  openssl pkcs12 -export -inkey "${work}/key.pem" -in "${work}/cert.pem" \
    -out "${work}/id.p12" -passout "pass:${p12_pass}" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    >/dev/null 2>&1 || die "openssl failed to build the PKCS#12 bundle"

  # -T grants codesign use of the private key without a GUI prompt, which
  # is what makes unattended re-signing from a LaunchDaemon possible. No
  # trust setting is required: codesign signs with an untrusted self-signed
  # identity, and TCC matches on the certificate hash, not on trust.
  sudo -n security import "${work}/id.p12" -k "${KEYCHAIN}" -P "${p12_pass}" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null \
    || die "security import failed (sudo -n: needs a NOPASSWD rule, or run 'sudo -v' first)"

  identity_present || die "identity not visible after import"
  rm -rf "${WORK_DIR}"
  WORK_DIR=""
  sha1=$(cert_sha1 || true)
  log "signing identity created: \"${SIGNING_IDENTITY}\" (${sha1}), valid ${CERT_DAYS} days"
}

# ---------------------------------------------------------------------------
# Per-target state
# ---------------------------------------------------------------------------

requirement_for() {
  local bin="$1"
  printf 'identifier "%s.%s" and certificate root = H"%s"' \
    "${IDENTIFIER_PREFIX}" "${bin}" "${CERT_SHA1}"
}

# Homebrew's opt/<formula> is a symlink into the Cellar that Homebrew moves
# on every upgrade; its target is the version fingerprint we track.
source_version() {
  local formula="$1"
  readlink "${HOMEBREW_PREFIX}/opt/${formula}" 2>/dev/null || true
}

signed_ok() {
  local file="$1" bin="$2" req
  [[ -f "${file}" ]] || return 1
  req=$(requirement_for "${bin}")
  codesign -v -R="${req}" "${file}" >/dev/null 2>&1
}

# Returns 0 when the stable copy is current: same source version as last
# sync and every signed binary still satisfies its requirement.
target_current() {
  local formula="$1" bins="$2"
  local dest="${STABLE_ROOT}/${formula}"
  local stamp="${dest}/.source-version"
  [[ -f "${stamp}" ]] || return 1
  local synced current
  synced=$(cat "${stamp}" || true)
  current=$(source_version "${formula}")
  [[ "${synced}" == "${current}" ]] || return 1
  local bin
  for bin in ${bins//,/ }; do
    signed_ok "${dest}/bin/${bin}" "${bin}" || return 1
  done
  return 0
}

sync_target() {
  local formula="$1" bins="$2"
  local src="${HOMEBREW_PREFIX}/opt/${formula}"
  local dest="${STABLE_ROOT}/${formula}"

  [[ -d "${src}/bin" ]] || die "formula '${formula}' has no ${src}/bin"
  mkdir -p "${dest}/bin"

  # Drop the version stamp first: if this run is interrupted anywhere below,
  # the next run sees a stale mirror instead of trusting a half-updated one.
  rm -f "${dest}/.source-version"

  # rsync writes each file to a temp name and renames it, so a process that
  # is executing the old copy is never handed a half-written file.
  # --checksum: the default size+mtime quick-check would skip a source file
  # that changed content but not size or mtime - which is exactly the shape
  # of a re-signed or tampered stable copy, since signing on a copy preserves
  # the mtime. A full checksum over a formula's bin/ and libexec/ is cheap
  # for a once-daily job.
  rsync -a --checksum --delete "${src}/bin/" "${dest}/bin/"
  if [[ -d "${src}/libexec" ]]; then
    rsync -a --checksum --delete "${src}/libexec/" "${dest}/libexec/"
  else
    rm -rf "${dest}/libexec"
  fi

  local bin file tmp
  for bin in ${bins//,/ }; do
    file="${dest}/bin/${bin}"
    [[ -f "${file}" ]] || die "'${bin}' not found in ${src}/bin"
    tmp="${file}.stable-sign.tmp"
    cp -p "${file}" "${tmp}"
    # Sign by hash, not label, so the identity is unambiguous.
    codesign -f -s "${CERT_SHA1}" --identifier "${IDENTIFIER_PREFIX}.${bin}" \
      --keychain "${KEYCHAIN}" "${tmp}" 2>/dev/null \
      || {
        rm -f "${tmp}"
        die "codesign failed for ${file}"
      }
    mv -f "${tmp}" "${file}"
    signed_ok "${file}" "${bin}" || die "${file} does not satisfy its requirement after signing"
  done

  local version
  version=$(source_version "${formula}")
  printf '%s\n' "${version}" >"${dest}/.source-version"
  log "${formula}: synced ${version} -> ${dest}; signed: ${bins}"
}

report_target() {
  local formula="$1" bins="$2"
  local dest="${STABLE_ROOT}/${formula}"
  local status=0 bin current synced req
  current=$(source_version "${formula}")
  synced=$(cat "${dest}/.source-version" 2>/dev/null || echo '<never>')
  printf '%s\n' "${formula}:"
  if [[ -z "${current}" ]]; then
    # Same outcome as the sync path: an uninstalled formula is skipped.
    printf '  source:  not installed (skipped)\n'
    return 0
  fi
  printf '  source:  %s\n' "${current}"
  printf '  stable:  %s (synced from %s)\n' "${dest}" "${synced}"
  for bin in ${bins//,/ }; do
    if signed_ok "${dest}/bin/${bin}" "${bin}"; then
      req=$(requirement_for "${bin}")
      printf '  %-14s OK   %s\n' "${bin}" "${req}"
    else
      printf '  %-14s STALE\n' "${bin}"
      status=1
    fi
  done
  # Everything else in bin/: a symlink onto a signed binary is what callers
  # rely on (bare 'timeout' -> gtimeout, 'podman' -> podman-remote), so show
  # those. Anything else runs with Homebrew's own signature and gets no
  # stable grant; just count it. Informational, not a failure.
  local entry name target other=0
  for entry in "${dest}/bin"/*; do
    [[ -e "${entry}" || -L "${entry}" ]] || continue
    name=$(basename "${entry}")
    case ",${bins}," in
      *",${name},"*) continue ;;
      *) ;;
    esac
    target=""
    if [[ -L "${entry}" ]]; then
      target=$(readlink "${entry}" || true)
    fi
    case ",${bins}," in
      *",${target},"*) printf '  %-14s link -> %s (signed)\n' "${name}" "${target}" ;;
      *) other=$((other + 1)) ;;
    esac
  done
  if [[ "${other}" -gt 0 ]]; then
    printf '  (%d other entries in bin/ keep their Homebrew signature)\n' "${other}"
  fi
  target_current "${formula}" "${bins}" || status=1
  return "${status}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  for tool in codesign security rsync openssl; do
    command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
  done

  if [[ "${MODE}" == "identity" ]]; then
    ensure_identity
    return 0
  fi

  if [[ "${MODE}" == "check" ]]; then
    identity_present || die "signing identity \"${SIGNING_IDENTITY}\" not found in ${KEYCHAIN}"
    CERT_SHA1="$(cert_sha1)"
    local rc=0 entry
    for entry in "${STABLE_TARGETS[@]}"; do
      report_target "${entry%%:*}" "${entry#*:}" || rc=1
    done
    return "${rc}"
  fi

  ensure_identity
  CERT_SHA1="$(cert_sha1)"
  [[ -n "${CERT_SHA1}" ]] || die "could not read certificate hash for \"${SIGNING_IDENTITY}\""

  if [[ ! -d "${STABLE_ROOT}" ]]; then
    # Owned by the administrator so daily runs need no sudo; 755 so the
    # operator account can execute what lives here.
    local owner
    owner=$(id -un)
    sudo -n install -d -o "${owner}" -g admin -m 755 "${STABLE_ROOT}" \
      || die "could not create ${STABLE_ROOT}"
  fi

  local entry formula bins version
  for entry in "${STABLE_TARGETS[@]}"; do
    formula="${entry%%:*}"
    bins="${entry#*:}"
    if [[ ! -d "${HOMEBREW_PREFIX}/opt/${formula}" ]]; then
      log "${formula}: not installed, skipping"
      continue
    fi
    if [[ "${FORCE}" != "true" ]] && target_current "${formula}" "${bins}"; then
      version=$(source_version "${formula}")
      log "${formula}: current (${version}), nothing to do"
      continue
    fi
    sync_target "${formula}" "${bins}"
  done
}

main
