#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run this script as root" >&2
  exit 1
fi
if [[ $# -ne 3 || $1 != --apply || $2 != --confirm || \
      $3 != INSTALL_TELESCAN_BOT_EGRESS ]]; then
  echo "Usage: $0 --apply --confirm INSTALL_TELESCAN_BOT_EGRESS" >&2
  exit 2
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
config_source="$repository_root/egress/tinyproxy-bot.conf"
filter_source="$repository_root/egress/telegram-filter"
unit_source="$repository_root/ops/systemd/telescan-bot-egress.service"
config_destination=/etc/tinyproxy/telescan-bot.conf
filter_destination=/etc/tinyproxy/telescan-bot-telegram-filter
unit_destination=/etc/systemd/system/telescan-bot-egress.service

for source_file in "$config_source" "$filter_source" "$unit_source"; do
  [[ -r "$source_file" ]] || {
    echo "Missing Telegram egress file: $source_file" >&2
    exit 1
  }
done
command -v tinyproxy >/dev/null
ip -4 address show dev wg0 | grep -qE 'inet 10\.77\.0\.2/'

backup_root="$(mktemp -d)"
unit_was_enabled=false
unit_was_active=false
firewall_rule_existed=false
complete=false

backup_file() {
  local destination="$1"
  local name="$2"
  if [[ -f "$destination" ]]; then
    install -m 0600 "$destination" "$backup_root/$name"
    : >"$backup_root/$name.present"
  fi
}

restore_file() {
  local destination="$1"
  local name="$2"
  if [[ -f "$backup_root/$name.present" ]]; then
    install -m 0644 "$backup_root/$name" "$destination"
  else
    rm -f -- "$destination"
  fi
}

backup_file "$config_destination" config
backup_file "$filter_destination" filter
backup_file "$unit_destination" unit
systemctl is-enabled --quiet telescan-bot-egress.service && unit_was_enabled=true || true
systemctl is-active --quiet telescan-bot-egress.service && unit_was_active=true || true
if ufw status | grep -Fq 'Telescan bot Telegram egress'; then
  firewall_rule_existed=true
fi

rollback() {
  local status=$?
  trap - EXIT
  if [[ "$complete" != true ]]; then
    restore_file "$config_destination" config
    restore_file "$filter_destination" filter
    restore_file "$unit_destination" unit
    systemctl daemon-reload || true
    if [[ "$unit_was_enabled" == true ]]; then
      systemctl enable telescan-bot-egress.service || true
    else
      systemctl disable telescan-bot-egress.service >/dev/null 2>&1 || true
    fi
    if [[ "$unit_was_active" == true ]]; then
      systemctl restart telescan-bot-egress.service || true
    else
      systemctl stop telescan-bot-egress.service >/dev/null 2>&1 || true
    fi
    if [[ "$firewall_rule_existed" != true ]]; then
      ufw --force delete allow in on wg0 \
        from 10.77.0.1 to 10.77.0.2 \
        port 8889 proto tcp >/dev/null 2>&1 || true
    fi
  fi
  rm -r -- "$backup_root"
  exit "$status"
}
trap rollback EXIT

install -m 0644 "$config_source" "$config_destination"
install -m 0644 "$filter_source" "$filter_destination"
install -m 0644 "$unit_source" "$unit_destination"

if [[ "$firewall_rule_existed" != true ]]; then
  ufw allow in on wg0 \
    from 10.77.0.1 to 10.77.0.2 \
    port 8889 proto tcp \
    comment 'Telescan bot Telegram egress'
fi

systemctl daemon-reload
systemctl enable --now telescan-bot-egress.service

deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  if systemctl is-active --quiet telescan-bot-egress.service && \
     ss -lnt | grep -qE '10\.77\.0\.2:8889[[:space:]]'; then
    complete=true
    rm -r -- "$backup_root"
    trap - EXIT
    echo "Private Telegram egress is listening on 10.77.0.2:8889."
    exit 0
  fi
  sleep 2
done

systemctl --no-pager --full status telescan-bot-egress.service || true
journalctl --no-pager --unit telescan-bot-egress.service --lines=100
exit 1
