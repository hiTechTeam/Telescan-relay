#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run this script as root from a provider-console-backed maintenance session." >&2
  exit 1
fi

if [[ ! -t 0 ]]; then
  echo "SSH policy changes require an interactive provider-console-backed session." >&2
  exit 1
fi

if [[ $# -ne 4 || $1 != --apply || $2 != --confirm || \
      $3 != APPLY_TELESCAN_SSH_HARDENING || $4 != --recovery-access-confirmed ]]; then
  echo "Usage: $0 --apply --confirm APPLY_TELESCAN_SSH_HARDENING --recovery-access-confirmed" >&2
  exit 2
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

destination=/etc/ssh/sshd_config.d/00-telescan-hardening.conf
backup_file="$(mktemp)"
had_previous=false
if [[ -f "$destination" ]]; then
  cp "$destination" "$backup_file"
  had_previous=true
fi

rollback_ssh_config() {
  if [[ "$had_previous" == true ]]; then
    install -m 0644 "$backup_file" "$destination"
  else
    rm -f -- "$destination"
  fi
  sshd -t
  systemctl reload ssh
}

rollback_enabled=true
trap 'if [[ "$rollback_enabled" == true ]]; then rollback_ssh_config; fi; rm -f -- "$backup_file"' EXIT

install -m 0644 \
  "$repository_root/ops/ssh/00-telescan-hardening.conf" \
  "$destination"

sshd -t
bash "$repository_root/ops/check-ssh-policy.sh"
systemctl reload ssh
bash "$repository_root/ops/check-ssh-policy.sh"

rollback_enabled=false
rm -f -- "$backup_file"
trap - EXIT

echo "SSH policy reloaded. Keep the recovery session open until a separate key login succeeds."
