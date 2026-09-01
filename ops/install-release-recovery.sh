#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 || "$1" != --apply || "$2" != --confirm || \
      "$3" != APPLY_RELAY_RELEASE_RECOVERY_UNIT ]]; then
  echo "Usage: $0 --apply --confirm APPLY_RELAY_RELEASE_RECOVERY_UNIT" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_unit="$root/ops/systemd/telescan-relay-release-recovery.service"
destination=/etc/systemd/system/telescan-relay-release-recovery.service
source_path_unit="$root/ops/systemd/telescan-relay-release-recovery.path"
path_destination=/etc/systemd/system/telescan-relay-release-recovery.path
source_certbot_service="$root/ops/systemd/telescan-relay-certbot-renew.service"
certbot_service_destination=/etc/systemd/system/telescan-relay-certbot-renew.service
source_certbot_timer="$root/ops/systemd/telescan-relay-certbot-renew.timer"
certbot_timer_destination=/etc/systemd/system/telescan-relay-certbot-renew.timer
backup_root="$(mktemp -d)"

backup_unit() {
  local destination_path="$1"
  local backup_name="$2"
  if test -f "$destination_path"; then
    cp "$destination_path" "$backup_root/$backup_name"
    : >"$backup_root/$backup_name.present"
  fi
}

restore_unit() {
  local destination_path="$1"
  local backup_name="$2"
  if [[ -f "$backup_root/$backup_name.present" ]]; then
    install -m 0644 "$backup_root/$backup_name" "$destination_path"
  else
    rm -f -- "$destination_path"
  fi
}

backup_unit "$destination" recovery.service
backup_unit "$path_destination" recovery.path
backup_unit "$certbot_service_destination" certbot.service
backup_unit "$certbot_timer_destination" certbot.timer
test ! -e /opt/telescan-relay/.release-state/intent.json
complete=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$complete" != true ]]; then
    restore_unit "$destination" recovery.service
    restore_unit "$path_destination" recovery.path
    restore_unit "$certbot_service_destination" certbot.service
    restore_unit "$certbot_timer_destination" certbot.timer
    systemctl daemon-reload || true
  fi
  rm -r -- "$backup_root"
  exit "$status"
}
trap cleanup EXIT

install -m 0644 "$source_unit" "$destination"
install -m 0644 "$source_path_unit" "$path_destination"
install -m 0644 "$source_certbot_service" "$certbot_service_destination"
install -m 0644 "$source_certbot_timer" "$certbot_timer_destination"
systemctl daemon-reload
systemctl enable telescan-relay-release-recovery.service
systemctl enable --now telescan-relay-release-recovery.path
systemctl enable --now telescan-relay-certbot-renew.timer
systemctl is-enabled --quiet telescan-relay-release-recovery.service
systemctl is-enabled --quiet telescan-relay-release-recovery.path
systemctl is-active --quiet telescan-relay-release-recovery.path
systemctl is-enabled --quiet telescan-relay-certbot-renew.timer
systemctl is-active --quiet telescan-relay-certbot-renew.timer
complete=true
echo "Relay release recovery and current-pointer Certbot runtime installed; no recovery was executed."
