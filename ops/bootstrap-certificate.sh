#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -s .env ]]; then
  echo "Missing .env. Copy .env.example and set CERTBOT_EMAIL." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${CERTBOT_EMAIL:-}" ]]; then
  echo "CERTBOT_EMAIL must be set in .env." >&2
  exit 1
fi

if [[ "$(dig +short A api.tgtelescan.ru | tail -n1)" != "212.69.87.142" ]]; then
  echo "api.tgtelescan.ru must resolve to 212.69.87.142 before issuing the certificate." >&2
  exit 1
fi

docker compose --profile bootstrap up -d bootstrap
trap 'docker compose --profile bootstrap stop bootstrap >/dev/null 2>&1 || true; docker compose --profile bootstrap rm -f bootstrap >/dev/null 2>&1 || true' EXIT

docker compose --profile certificate run --rm certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --domain api.tgtelescan.ru \
  --email "$CERTBOT_EMAIL" \
  --agree-tos \
  --no-eff-email \
  --non-interactive

docker compose --profile bootstrap stop bootstrap
docker compose --profile bootstrap rm -f bootstrap
trap - EXIT
docker compose up -d --build --no-deps relay
bash ops/check-relay.sh
