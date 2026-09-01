#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker compose config --quiet
find ops -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash ops/test-safety-gates.sh
docker compose build relay

configured_image_reference="$(
  docker compose config --format json |
    python3 -c '
import json, sys
payload = json.load(sys.stdin)
value = payload.get("services", {}).get("relay", {}).get("image", "")
if not isinstance(value, str) or not value:
    raise SystemExit("relay.image is missing from resolved Compose config")
print(value)
'
)"
candidate_image_id="$(docker image inspect --format '{{.Id}}' "$configured_image_reference")"
if [[ ! "$candidate_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Unable to resolve the newly built relay image identity." >&2
  exit 1
fi

bash ops/validate-relay-image.sh "$candidate_image_id"
printf 'Relay preflight passed for reference=%s image_id=%s.\n' \
  "$configured_image_reference" "$candidate_image_id"
