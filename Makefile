.PHONY: config build up down logs renew

config:
	docker compose config --quiet

build:
	docker compose build relay

up:
	docker compose up -d --build --no-deps relay

down:
	docker compose down

logs:
	docker compose logs --tail=100 relay

renew:
	docker compose --profile certificate run --rm certbot renew \
		--webroot --webroot-path /var/www/certbot
