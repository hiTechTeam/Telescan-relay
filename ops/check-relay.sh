#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode=full
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--local-only]" >&2
  exit 2
fi
if [[ ${1:-} == --local-only ]]; then
  mode=local
elif [[ $# -eq 1 ]]; then
  echo "Unknown argument: $1" >&2
  exit 2
fi

check_url() {
  local name="$1"
  local expected_pattern="$2"
  shift 2

  local body=''
  for _ in {1..20}; do
    if body="$(curl --fail --silent --show-error --connect-timeout 3 --max-time 10 "$@" 2>/dev/null)" && \
       grep -Eiq "$expected_pattern" <<<"$body"; then
      printf '%s check passed.\n' "$name"
      return 0
    fi
    sleep 3
  done

  echo "$name check failed." >&2
  curl --fail --silent --show-error --connect-timeout 3 --max-time 10 "$@" >/dev/null
  return 1
}

container_id="$(docker compose ps -q relay)"
test -n "$container_id"

for _ in {1..20}; do
  health_status="$(docker inspect --format '{{.State.Health.Status}}' "$container_id")"
  if [[ "$health_status" == "healthy" ]]; then
    break
  fi
  sleep 3
done

docker compose ps relay
test "$(docker inspect --format '{{.State.Health.Status}}' "$container_id")" = "healthy"
docker compose exec -T relay nginx -t </dev/null

check_url Local-relay '^ok$' \
  --noproxy '*' \
  --resolve api.tgtelescan.ru:443:127.0.0.1 \
  https://api.tgtelescan.ru/health/relay

if [[ "$mode" == full ]]; then
  check_url Moscow-origin '^ok$' \
    http://10.77.0.1:8081/health/origin
  check_url Public-ready '"status"[[:space:]]*:[[:space:]]*"ok"' \
    https://api.tgtelescan.ru/health/ready
fi
