#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
files=$(mktemp)
trap 'rm -f "$files"' EXIT HUP INT TERM

# Include tracked and untracked commit candidates, but never ignored local data.
git ls-files --cached --others --exclude-standard -z > "$files"

fail=0
check_pattern() {
  label=$1
  pattern=$2
  if xargs -0 rg --no-messages -I -l -e "$pattern" < "$files" 2>/dev/null \
    | grep -v '^scripts/public-release-audit\.sh$' >/dev/null; then
    printf 'FAIL: %s detected (values redacted)\n' "$label"
    fail=1
  fi
}

check_pattern 'private-key header' 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
check_pattern 'bearer token' 'Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}'
check_pattern 'probable provider key' '(sk_live_|ghp_|github_pat_|xox[bp]-)[A-Za-z0-9_-]+'

# Assemble disclosure patterns so this audited script does not match itself.
private_ipv4=$(printf '%s%s' '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.' '168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)')
tailscale_ipv4=$(printf '%s%s' '(^|[^0-9])100\.' '(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.')
absolute_path=$(printf '%s%s' '(/Us' 'ers/[^/[:space:]]+|/opt/docker/|/etc/hausklar-)')
check_pattern 'private IPv4 address' "$private_ipv4"
check_pattern 'Tailscale CGNAT address' "$tailscale_ipv4"
check_pattern 'absolute user/server deployment path' "$absolute_path"

email_pattern='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
if xargs -0 rg --no-messages -I -o -e "$email_pattern" < "$files" \
  | awk '{print $NF}' \
  | grep -Eiv '@([A-Za-z0-9.-]+\.)?example\.(invalid|com)$|@users\.noreply\.github\.com$' >/dev/null; then
  printf 'FAIL: non-public-safe email address detected (value redacted)\n'
  fail=1
fi

telephone_pattern='(^|[^[:alnum:]])\+[1-9][0-9 ()-]{8,}[0-9]'
check_pattern 'probable telephone number' "$telephone_pattern"

if tr '\0' '\n' < "$files" | grep -Ei '\.(db|sqlite|sqlite3|pem|key|p12|mobileprovision|fit|zip|tar|tgz|gz|age|pdf)$' >/dev/null; then
  printf 'FAIL: prohibited data/archive/signing extension detected\n'
  fail=1
fi
if tr '\0' '\n' < "$files" \
  | grep -Ei '\.(png|jpe?g|webp|gif|heic)$' \
  | grep -Ei '(^|/)(screenshots?|captures?|photos?)(/|$)|(^|/).*(screen[-_ ]?shot|camera[-_ ]?frame).*$' >/dev/null; then
  printf 'FAIL: unapproved screenshot/photo/capture filename detected\n'
  fail=1
fi

scan_denylist() {
  label=$1
  denylist=$2
  [ -n "$denylist" ] || return 0
  if [ ! -r "$denylist" ]; then
    printf 'FAIL: %s denylist is not readable\n' "$label"
    fail=1
  elif xargs -0 rg --no-messages -I -F -l -f "$denylist" < "$files" >/dev/null 2>&1; then
    printf 'FAIL: %s denylist match detected (values redacted)\n' "$label"
    fail=1
  fi
}
scan_denylist 'private' "${PRIVATE_DENYLIST_FILE:-}"
scan_denylist 'infrastructure' "${INFRA_DENYLIST_FILE:-}"

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks dir --redact=100 --no-banner .
else
  printf 'WARN: gitleaks unavailable; CI must run it\n'
fi
[ "$fail" -eq 0 ] || exit 1
printf 'Public-release audit passed.\n'
