#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 IMAGE_REFERENCE" >&2
  exit 2
fi

image_reference="$1"
temporary_root="$(mktemp -d)"
container_id=""
cleanup() {
  if [[ -n "$container_id" ]]; then
    docker rm -f -- "$container_id" >/dev/null 2>&1 || true
  fi
  rm -r -- "$temporary_root"
}
trap cleanup EXIT

certificate_dir="$temporary_root/api.tgtelescan.ru"
install -d -m 0700 "$certificate_dir"

openssl req -x509 -newkey rsa:2048 -nodes \
  -subj '/CN=api.tgtelescan.ru' \
  -days 1 \
  -keyout "$certificate_dir/privkey.pem" \
  -out "$certificate_dir/fullchain.pem" \
  >/dev/null 2>&1

docker run --rm \
  --entrypoint nginx \
  --volume "$certificate_dir:/etc/letsencrypt/live/api.tgtelescan.ru:ro" \
  "$image_reference" \
  -t

container_id="$(docker run --detach \
  --publish 127.0.0.1::80 \
  --publish 127.0.0.1::443 \
  --volume "$certificate_dir:/etc/letsencrypt/live/api.tgtelescan.ru:ro" \
  "$image_reference")"

http_port="$(docker port "$container_id" 80/tcp | awk -F: 'NR == 1 { print $NF }')"
https_port="$(docker port "$container_id" 443/tcp | awk -F: 'NR == 1 { print $NF }')"
if [[ ! "$http_port" =~ ^[0-9]+$ || ! "$https_port" =~ ^[0-9]+$ ]]; then
  echo "Could not resolve temporary relay ports." >&2
  exit 1
fi

for _ in {1..20}; do
  if [[ "$(curl --insecure --silent --noproxy '*' \
      --resolve "api.tgtelescan.ru:$https_port:127.0.0.1" \
      "https://api.tgtelescan.ru:$https_port/health/relay" 2>/dev/null || true)" == ok ]]; then
    break
  fi
  sleep 1
done

test "$(curl --insecure --silent --noproxy '*' \
  --resolve "api.tgtelescan.ru:$https_port:127.0.0.1" \
  "https://api.tgtelescan.ru:$https_port/health/relay")" = ok
test "$(curl --insecure --silent --output /dev/null --write-out '%{http_code}' --noproxy '*' \
  --resolve "api.tgtelescan.ru:$https_port:127.0.0.1" \
  "https://api.tgtelescan.ru:$https_port/docs")" = 404
test "$(curl --insecure --silent --output /dev/null --write-out '%{http_code}' --noproxy '*' \
  --resolve "api.tgtelescan.ru:$https_port:127.0.0.1" \
  "https://api.tgtelescan.ru:$https_port/internal/health")" = 404
test "$(curl --silent --output /dev/null --write-out '%{http_code}' --noproxy '*' \
  --resolve "api.tgtelescan.ru:$http_port:127.0.0.1" \
  "http://api.tgtelescan.ru:$http_port/public")" = 301

echo "Relay image semantic route checks passed."
