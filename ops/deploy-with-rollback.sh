#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Deploy: $0 --apply --confirm DEPLOY_RELAY_WITH_ROLLBACK --active-root /opt/telescan-relay --release-root /tmp/telescan-relay-release.SUFFIX" >&2
  echo "Recover: $0 --apply --confirm RECOVER_RELAY_RELEASE --active-root /opt/telescan-relay --recover-only" >&2
  exit 2
}

mode=deploy
if [[ $# -eq 7 && "$1" == --apply && "$2" == --confirm && \
      "$3" == DEPLOY_RELAY_WITH_ROLLBACK && \
      "$4" == --active-root && "$6" == --release-root ]]; then
  active_input="$5"
  release_input="$7"
elif [[ $# -eq 6 && "$1" == --apply && "$2" == --confirm && \
        "$3" == RECOVER_RELAY_RELEASE && \
        "$4" == --active-root && "$6" == --recover-only ]]; then
  mode=recover
  active_input="$5"
  release_input=""
else
  usage
fi
[[ -d "$active_input" ]] || usage
[[ "$mode" == recover || -d "$release_input" ]] || usage

active_root="$(realpath "$active_input")"
release_root=""
[[ "$mode" == recover ]] || release_root="$(realpath "$release_input")"
controller_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_tool="$controller_root/ops/release-state.py"
restart_override="$controller_root/ops/compose-transaction-no-restart.yaml"
transaction_test_mode="${TELESCAN_RELAY_TRANSACTION_TEST_MODE:-0}"
if [[ "$transaction_test_mode" == 1 ]]; then
  test_root="$(realpath "${TELESCAN_RELAY_TRANSACTION_TEST_ROOT:?}")"
  case "$test_root" in
    /tmp/telescan-relay-transaction-test.*|/private/tmp/telescan-relay-transaction-test.*) ;;
    *) usage ;;
  esac
  [[ "$active_root" == "$test_root/active" ]] || usage
  [[ "$mode" == recover || "$release_root" == "$test_root/release" ]] || usage
else
  [[ "$transaction_test_mode" == 0 ]] || usage
  [[ "$active_root" == /opt/telescan-relay ]] || usage
  [[ "$mode" == recover || "$release_root" == /tmp/telescan-relay-release.* ]] || usage
  [[ -z "${TELESCAN_RELAY_TRANSACTION_KILLPOINT:-}" ]] || usage
fi
[[ -f "$state_tool" && -f "$restart_override" ]] || usage

if ! { : >&9; } 2>/dev/null || ! flock --nonblock 9; then
  echo "The Relay release transaction requires inherited production lock FD 9." >&2
  exit 1
fi

state_root="$active_root/.release-state"
intent="$state_root/intent.json"
releases_root="$active_root/releases"
install -d -m 0700 "$state_root" "$releases_root"
python3 "$state_tool" sync-dir --path "$active_root"
if [[ ! -s "$active_root/.env" ]]; then
  echo "The preserved host-owned relay .env must exist." >&2
  exit 1
fi
if [[ "$transaction_test_mode" != 1 && "$(stat -c '%a' "$active_root/.env")" != 600 ]]; then
  echo "The preserved host-owned relay .env must have mode 0600." >&2
  exit 1
fi

compose_at() {
  local root="$1"
  shift
  (cd "$root" && docker compose --env-file "$active_root/.env" --project-name telescan-relay "$@")
}

compose_at_guarded() {
  local root="$1"
  shift
  (cd "$root" && docker compose --env-file "$active_root/.env" \
    --project-name telescan-relay -f "$root/docker-compose.yml" \
    -f "$restart_override" "$@")
}

resolve_image_reference() {
  local root="$1"
  compose_at "$root" config --format json | python3 -c '
import json, sys
payload = json.load(sys.stdin)
value = payload.get("services", {}).get("relay", {}).get("image", "")
if not isinstance(value, str) or not value:
    raise SystemExit("relay.image is missing from resolved Compose config")
print(value)
'
}

current_release_name() {
  [[ -L "$active_root/current" ]] || return 1
  local resolved
  resolved="$(realpath "$active_root/current")"
  [[ "$(dirname "$resolved")" == "$(realpath "$releases_root")" && -d "$resolved" ]] || return 1
  basename "$resolved"
}

sync_release() { python3 "$state_tool" sync-tree --path "$1"; }
switch_release() { python3 "$state_tool" switch --active-root "$active_root" --release "$1"; }

bootstrap_layout() {
  if [[ -L "$active_root/current" ]]; then
    current_release_name >/dev/null || {
      echo "The current release pointer is invalid." >&2
      return 1
    }
    return 0
  fi
  [[ ! -e "$active_root/current" ]] || {
    echo "The current release path exists but is not a symlink." >&2
    return 1
  }
  local bootstrap_name="bootstrap-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local bootstrap_release="$releases_root/$bootstrap_name"
  install -d -m 0755 "$bootstrap_release"
  rsync --archive --checksum \
    --exclude='.env' --exclude='.git/' --exclude='.DS_Store' --exclude='._*' \
    --exclude='data/' --exclude='releases/' --exclude='current' \
    --exclude='.release-state/' \
    "$active_root/" "$bootstrap_release/"
  for required in docker-compose.yml ops/check-relay.sh; do
    [[ -f "$bootstrap_release/$required" ]] || {
      echo "Legacy active tree cannot be bootstrapped: missing $required." >&2
      return 1
    }
  done
  chmod +x "$bootstrap_release"/ops/*.sh
  ln -s ../../.env "$bootstrap_release/.env"
  sync_release "$bootstrap_release"
  switch_release "$bootstrap_name"
  echo "Bootstrapped immutable Relay release: $bootstrap_name"
}

intent_field() { python3 "$state_tool" get --intent "$intent" --field "$1"; }

health_release() {
  local release="$1"
  local restart_mode="${2:-normal}"
  local recovery_mode="${3:-recovery}"
  compose_at "$release" config --quiet </dev/null
  if [[ "$restart_mode" == guarded ]]; then
    compose_at_guarded "$release" up -d --no-build --force-recreate --no-deps relay </dev/null
    if [[ "$recovery_mode" == transaction ]]; then
      killpoint after-recreate
    fi
  else
    compose_at "$release" up -d --no-build --force-recreate --no-deps relay </dev/null
  fi
  if ! COMPOSE_PROJECT_NAME=telescan-relay \
      timeout --signal=TERM 360 bash "$release/ops/check-relay.sh"; then
    compose_at "$release" ps relay || true
    compose_at "$release" logs --tail=100 relay || true
    return 1
  fi
}

recover_incomplete() {
  [[ -f "$intent" ]] || return 0
  local phase old_name new_name image_reference old_reference rollback_reference old_id new_id target_name target_id source_image
  phase="$(intent_field phase)"
  old_name="$(intent_field old_release)"
  new_name="$(intent_field new_release)"
  image_reference="$(intent_field image_reference)"
  old_reference="$(intent_field old_image_reference)"
  rollback_reference="$(intent_field rollback_image_reference)"
  old_id="$(intent_field old_image_id)"
  new_id="$(intent_field new_image_id)"
  if [[ "$phase" == committed ]]; then
    target_name="$new_name"
    target_id="$new_id"
    [[ "$target_id" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "Committed relay intent lacks the candidate image identity." >&2
      return 1
    }
    echo "Recovering committed Relay release $target_name."
  else
    target_name="$old_name"
    target_id="$old_id"
    echo "Rolling back incomplete Relay release phase=$phase to $target_name." >&2
  fi
  [[ -d "$releases_root/$target_name" ]] || return 1
  if [[ "$phase" == committed ]]; then
    source_image="$image_reference"
    [[ "$(docker image inspect --format '{{.Id}}' "$source_image")" == "$target_id" ]] || return 1
  else
    source_image="$rollback_reference"
    [[ "$(docker image inspect --format '{{.Id}}' "$source_image")" == "$target_id" ]] || return 1
  fi
  docker image tag "$source_image" "$image_reference"
  if [[ "$phase" != committed && -n "$old_reference" ]]; then
    docker image tag "$source_image" "$old_reference"
  fi
  switch_release "$target_name"
  [[ "$(current_release_name)" == "$target_name" ]]
  if [[ "$phase" == committed ]]; then
    health_release "$active_root/current" guarded recovery
    docker update --restart unless-stopped "$(compose_at "$active_root/current" ps -q relay)" >/dev/null
  else
    health_release "$active_root/current" normal recovery
  fi
  python3 "$state_tool" clear --intent "$intent"
  docker image rm "$rollback_reference" >/dev/null 2>&1 || true
  echo "Relay deterministic release recovery passed: release=$target_name image=$target_id"
}

bootstrap_layout
recover_incomplete
if [[ "$mode" == recover ]]; then
  echo "Relay release state is coherent; no incomplete intent remains."
  exit 0
fi

if find "$release_root" -name .env -print -quit | grep -q .; then
  echo "Incoming Relay release unexpectedly contains .env." >&2
  exit 1
fi
for required_file in docker-compose.yml Dockerfile nginx.conf \
    ops/check-relay.sh ops/validate-relay-image.sh ops/release-state.py \
    ops/compose-transaction-no-restart.yaml; do
  [[ -f "$release_root/$required_file" ]] || {
    echo "Incoming Relay release is missing $required_file." >&2
    exit 1
  }
done

old_name="$(current_release_name)"
old_release="$releases_root/$old_name"
compose_at "$old_release" config --quiet </dev/null
previous_container="$(compose_at "$old_release" ps -q relay)"
if [[ -z "$previous_container" || \
      "$(docker inspect --format '{{.State.Running}}' "$previous_container")" != true ]]; then
  echo "A running Relay container is required for automatic rollback." >&2
  exit 1
fi
previous_image_id="$(docker inspect --format '{{.Image}}' "$previous_container")"
previous_image_reference="$(docker inspect --format '{{.Config.Image}}' "$previous_container")"
if [[ ! "$previous_image_id" =~ ^sha256:[0-9a-f]{64}$ || \
      -z "$previous_image_reference" || "$previous_image_reference" == *$'\n'* ]]; then
  echo "Unable to capture the previous Relay image baseline." >&2
  exit 1
fi

candidate_image_reference="$(resolve_image_reference "$release_root")"
[[ "$candidate_image_reference" == telescan-relay:release ]] || {
  echo "Incoming Relay release changed the guarded image reference." >&2
  exit 1
}
new_name="release-$(date -u +%Y%m%dT%H%M%SZ)-$$"
new_release="$releases_root/$new_name"
rollback_image_reference="telescan-relay:rollback-$new_name"
install -d -m 0755 "$new_release"
rsync --archive --checksum --delete \
  --exclude='.env' --exclude='.git/' --exclude='.DS_Store' --exclude='._*' \
  --exclude='data/' "$release_root/" "$new_release/"
chmod +x "$new_release"/ops/*.sh
ln -s ../../.env "$new_release/.env"
sync_release "$new_release"

docker image tag "$previous_image_id" "$rollback_image_reference"
[[ "$(docker image inspect --format '{{.Id}}' "$rollback_image_reference")" == \
   "$previous_image_id" ]]
python3 "$state_tool" write-intent \
  --intent "$intent" --kind relay --phase prepared \
  --old-release "$old_name" --new-release "$new_name" \
  --image-reference "$candidate_image_reference" \
  --old-image-reference "$previous_image_reference" \
  --rollback-image-reference "$rollback_image_reference" \
  --old-image-id "$previous_image_id" --new-image-id pending
transaction_started=true
transaction_complete=false

transaction_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$transaction_started" == true && "$transaction_complete" != true && -f "$intent" ]]; then
    echo "Interrupted or failed Relay transaction; running durable recovery." >&2
    if ! recover_incomplete; then
      echo "CRITICAL: durable relay intent retained at $intent for deterministic retry." >&2
      status=1
    fi
  fi
  exit "$status"
}
trap transaction_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

killpoint() {
  if [[ "$transaction_test_mode" == 1 && "$1" == after-intent && \
        "${TELESCAN_RELAY_TRANSACTION_KILLPOINT:-}" == outer-after-intent ]]; then
    kill -KILL "$PPID"
    kill -KILL "$$"
  fi
  if [[ "$transaction_test_mode" == 1 && \
        "${TELESCAN_RELAY_TRANSACTION_KILLPOINT:-}" == "$1" ]]; then
    kill -KILL "$$"
  fi
}

killpoint after-intent
docker image tag "$rollback_image_reference" "$candidate_image_reference"
compose_at "$new_release" config --quiet </dev/null
compose_at "$new_release" build relay
candidate_image_id="$(docker image inspect --format '{{.Id}}' "$candidate_image_reference")"
[[ "$candidate_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]
bash "$new_release/ops/validate-relay-image.sh" "$candidate_image_id"
python3 "$state_tool" update-intent --intent "$intent" \
  --phase candidate_ready --new-image-id "$candidate_image_id"

killpoint before-pointer
switch_release "$new_name"
killpoint after-pointer
python3 "$state_tool" update-intent --intent "$intent" --phase promoted
[[ "$(current_release_name)" == "$new_name" ]]
[[ "$(docker image inspect --format '{{.Id}}' "$candidate_image_reference")" == \
   "$candidate_image_id" ]]
health_release "$active_root/current" guarded transaction

python3 "$state_tool" update-intent --intent "$intent" --phase committed
killpoint after-commit
docker update --restart unless-stopped "$(compose_at "$active_root/current" ps -q relay)" >/dev/null
python3 "$state_tool" clear --intent "$intent"
docker image rm "$rollback_image_reference" >/dev/null 2>&1 || true
transaction_complete=true
printf 'Relay immutable release transaction passed: previous=%s current=%s release=%s\n' \
  "$previous_image_id" "$candidate_image_id" "$new_name"
