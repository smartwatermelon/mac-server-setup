#!/usr/bin/env bash
# Find sensitive-looking values in public docs (#205).
# Usage: check-sensitive.sh [--allowlist FILE] FILE... (1 finding, 2 unreadable)

set -euo pipefail

allowlist=""
if [[ "${1:-}" == "--allowlist" ]]; then
  allowlist="${2:?--allowlist needs a file}"
  shift 2
fi
if (($# == 0)); then
  echo "usage: check-sensitive.sh [--allowlist FILE] FILE..." >&2
  exit 64
fi

# Generic examples and public resolvers, compared as exact strings.
readonly IPV4_ALLOWED=(
  0.0.0.0
  10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
  192.168.0.1 192.168.1.0/24 192.168.1.1
  1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112
)

ipv4_allowed() {
  local ip="$1" a
  case "${ip}" in
    127.* | 192.0.2.* | 198.51.100.* | 203.0.113.* | 255.*) return 0 ;;
    # The docs' example LAN (/22 holding the /24) and OpenVPN's default.
    192.168.2[0-3].* | 10.8.0.*) return 0 ;;
    *) ;;
  esac
  for a in "${IPV4_ALLOWED[@]}"; do
    [[ "${ip}" == "${a}" ]] && return 0
  done
  return 1
}

# Placeholder hosts for the part after @.
email_host_allowed() {
  local host
  host="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  [[ "${host}" =~ (^|\.)example\.(com|org|net)$ ]] && return 0
  [[ "${host}" =~ ^your[-_a-z]*\.(local|com|org|net)$ ]] && return 0
  [[ "${host}" =~ ^(macmini|your_server|server)\.local$ ]] && return 0
  return 1
}

allowed_by_file() {
  local path="$1" match="$2"
  [[ -n "${allowlist}" ]] || return 1
  grep -qxF "${path}"$'\t'"${match}" "${allowlist}"
}

found=0
report() {
  local path="$1" line="$2" rule="$3" match="$4"
  allowed_by_file "${path}" "${match}" && return 0
  printf '%s:%s: %s: %s\n' "${path}" "${line}" "${rule}" "${match}"
  found=1
}

# "line<TAB>match" for ERE $2 in file $1; sed -E script $3 trims context.
matches() {
  grep -noE "$2" "$1" | sed -E 's/^([0-9]+):/\1\t/' | sed -E "${3:-}" || true
}

# Refuse before scanning: grep errors are masked in the pipelines below, so
# an unreadable file must not be allowed to look clean.
for f in "$@"; do
  if [[ ! -f "${f}" || ! -r "${f}" ]]; then
    echo "check-sensitive: cannot read ${f}" >&2
    exit 2
  fi
done
if [[ -n "${allowlist}" && ! -r "${allowlist}" ]]; then
  echo "check-sensitive: cannot read allowlist ${allowlist}" >&2
  exit 2
fi

for f in "$@"; do
  while IFS=$'\t' read -r n m; do
    ip="${m%%/*}"
    valid=1
    IFS=. read -r o1 o2 o3 o4 <<<"${ip}"
    for o in "${o1}" "${o2}" "${o3}" "${o4}"; do
      ((10#${o} <= 255)) || valid=0
    done
    ((valid)) || continue
    ipv4_allowed "${m}" || ipv4_allowed "${ip}" || report "${f}" "${n}" ipv4 "${m}"
  done < <(matches "${f}" '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' \
    's/\t[^0-9]*/\t/' || true)

  # Ids: take each whole alphanumeric run, so two ids joined by one
  # character are both seen, then keep the runs with an id's exact shape.
  while IFS=$'\t' read -r n m; do
    uuid='[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    while [[ "${m}" =~ ${uuid} ]]; do
      report "${f}" "${n}" id "${BASH_REMATCH[0]}"
      m="${m/"${BASH_REMATCH[0]}"/-}"
    done
    IFS=- read -r -a parts <<<"${m}"
    for w in "${parts[@]}"; do
      if [[ "${w}" =~ ^([0-9a-fA-F]{32}|[0-9a-fA-F]{64})$ ]]; then
        report "${f}" "${n}" id "${w}"
      elif [[ "${w}" =~ ^[a-z0-9]{26}$ && "${w}" =~ [0-9] && "${w}" =~ [a-z] ]]; then
        # 1Password ids are 26 lowercase letters and digits, mixed.
        report "${f}" "${n}" opid "${w}"
      fi
    done
  done < <(matches "${f}" '[0-9A-Za-z-]{26,}' || true)

  while IFS=$'\t' read -r n m; do
    case "${m%%.*}" in
      your-team | example | team) ;;
      *) report "${f}" "${n}" team "${m}" ;;
    esac
  done < <(matches "${f}" '[A-Za-z0-9-]+\.cloudflareaccess\.com' || true)

  while IFS=$'\t' read -r n m; do
    report "${f}" "${n}" op "${m}"
  done < <(matches "${f}" 'op://[A-Za-z0-9][^[:space:]`"<>)]*' || true)

  while IFS=$'\t' read -r n m; do
    email_host_allowed "${m#*@}" || report "${f}" "${n}" email "${m}"
  done < <(matches "${f}" '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' || true)
done

exit "${found}"
