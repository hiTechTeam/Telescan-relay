#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

sshd_path="$(command -v sshd || true)"
if [[ -z "$sshd_path" ]]; then
  echo "sshd is unavailable." >&2
  exit 1
fi

effective_config=''
if effective_config="$("$sshd_path" -T 2>/dev/null)"; then
  :
elif command -v sudo >/dev/null 2>&1 && \
     effective_config="$(sudo -n "$sshd_path" -T 2>/dev/null)"; then
  :
else
  echo "Unable to read the effective SSH policy without an interactive privilege prompt." >&2
  exit 1
fi

check_setting() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(awk -v key="$key" '$1 == key { print $2; exit }' <<<"$effective_config")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'SSH policy mismatch: %s expected=%s actual=%s\n' \
      "$key" "$expected" "${actual:-missing}" >&2
    return 1
  fi
  printf 'SSH policy verified: %s=%s\n' "$key" "$actual"
}

check_setting permitrootlogin no
check_setting passwordauthentication no
check_setting kbdinteractiveauthentication no
check_setting pubkeyauthentication yes
check_setting x11forwarding no
