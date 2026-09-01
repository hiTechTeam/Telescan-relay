#!/usr/bin/env bash
set -Eeuo pipefail

mode=deploy
if [[ $# -eq 7 && "$1" == --apply && "$2" == --confirm && \
      "$3" == DEPLOY_RELAY_WITH_ROLLBACK && "$4" == --active-root && \
      "$6" == --release-root ]]; then
  active_input="$5"
  release_input="$7"
elif [[ $# -eq 6 && "$1" == --apply && "$2" == --confirm && \
        "$3" == RECOVER_RELAY_RELEASE && "$4" == --active-root && \
        "$6" == --recover-only ]]; then
  mode=recover
  active_input="$5"
  release_input=""
else
  echo "Usage: $0 --apply --confirm DEPLOY_RELAY_WITH_ROLLBACK --active-root /opt/telescan-relay --release-root /tmp/telescan-relay-release.SUFFIX" >&2
  echo "Usage: $0 --apply --confirm RECOVER_RELAY_RELEASE --active-root /opt/telescan-relay --recover-only" >&2
  exit 2
fi
active_root="$(realpath "$active_input")"
controller="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy-with-rollback.sh"

if ! { : >&9; } 2>/dev/null || ! flock --nonblock 9; then
  echo "The relay release supervisor requires inherited production lock FD 9." >&2
  exit 1
fi

if [[ "$mode" == recover ]]; then
  exec bash "$controller" "$@"
fi

# Recover any older intent with the complete incoming controller before
# publishing a replacement recovery controller.
intent="$active_root/.release-state/intent.json"
if [[ -f "$intent" ]]; then
  bash "$controller" --apply --confirm RECOVER_RELAY_RELEASE \
    --active-root "$active_root" --recover-only
fi

# Persist a known recovery controller before the child can write its intent.
# The boot recovery unit uses this host-owned copy even when `current` points
# to a pre-transaction release.
controller_name="controller-$(date -u +%Y%m%dT%H%M%SZ)-$$"
controller_root="$active_root/.release-state/controllers/$controller_name"
controller_store="$controller_root/ops"
install -d -m 0700 "$controller_store"
for file in deploy-with-rollback.sh run-release-transaction.sh release-state.py \
    compose-transaction-no-restart.yaml; do
  install -m 0755 "$(dirname "$controller")/$file" "$controller_store/$file"
done
chmod 0644 "$controller_store/compose-transaction-no-restart.yaml"
python3 "$controller_store/release-state.py" sync-tree \
  --path "$controller_root"
python3 "$controller_store/release-state.py" sync-dir --path "$active_root"
python3 "$controller_store/release-state.py" switch-path \
  --root "$active_root/.release-state" --link recovery-controller \
  --target "controllers/$controller_name"

set +e
bash "$controller" "$@"
child_status=$?
set -e

if [[ -f "$intent" ]]; then
  echo "Relay child exited with durable intent; supervisor is recovering before returning." >&2
  if ! bash "$controller" \
      --apply --confirm RECOVER_RELAY_RELEASE \
      --active-root "$active_root" --recover-only; then
    echo "CRITICAL: relay supervisor recovery failed; intent remains at $intent." >&2
    exit 1
  fi
fi

if [[ "$child_status" -ne 0 ]]; then
  # Normalize signal exits after recovery so callers receive a regular failed
  # deployment rather than mistaking a killed child for an orphaned rollout.
  if [[ "$child_status" -ge 128 ]]; then
    exit 1
  fi
  exit "$child_status"
fi
echo "Relay release supervisor verified that no durable transaction intent remains."
