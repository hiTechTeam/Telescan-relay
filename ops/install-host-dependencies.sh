#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  sudo_cmd=()
else
  sudo_cmd=(sudo)
fi

"${sudo_cmd[@]}" apt-get update
"${sudo_cmd[@]}" apt-get install -y \
  ca-certificates \
  curl \
  docker.io \
  docker-compose-v2 \
  fail2ban \
  rsync \
  ufw \
  wireguard

"${sudo_cmd[@]}" systemctl enable --now docker fail2ban

"${sudo_cmd[@]}" ufw default deny incoming
"${sudo_cmd[@]}" ufw default allow outgoing
"${sudo_cmd[@]}" ufw allow OpenSSH
"${sudo_cmd[@]}" ufw allow 80/tcp
"${sudo_cmd[@]}" ufw allow 443/tcp
"${sudo_cmd[@]}" ufw allow 51820/udp
"${sudo_cmd[@]}" ufw --force enable

"${sudo_cmd[@]}" systemctl is-active --quiet docker
"${sudo_cmd[@]}" systemctl is-active --quiet fail2ban
"${sudo_cmd[@]}" fail2ban-client status sshd
