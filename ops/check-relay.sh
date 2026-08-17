#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

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
curl --fail --silent --show-error --max-time 10 \
  https://api.tgtelescan.ru/health/relay \
  --resolve api.tgtelescan.ru:443:127.0.0.1 \
  >/dev/null
