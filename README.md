# Telescan EU Relay

Private edge relay for `api.tgtelescan.ru`. The relay terminates HTTPS in the
Netherlands and forwards API traffic to the Moscow origin through WireGuard.

## Network model

```text
iOS / VPN -> api.tgtelescan.ru:443 -> EU nginx
           -> WireGuard 10.77.0.2 -> 10.77.0.1:8081 Moscow nginx
           -> FastAPI 127.0.0.1:8000
```

The FastAPI port remains loopback-only. Swagger remains enabled in FastAPI and
is available only through the existing SSH tunnel to Moscow. The public relay
returns `404` for `/docs`, `/docs/`, `/redoc`, `/openapi.json`, and `/internal/`.

## Production host

- Region: Netherlands
- Public IP: `212.69.87.142`
- WireGuard address: `10.77.0.2/30`
- Moscow peer: `10.77.0.1/30`
- Installation path: `/opt/telescan-relay`

Secrets, WireGuard private keys, certificates, and `.env` are never committed.

## First deployment

1. Install host packages with `sudo bash ops/install-host-dependencies.sh`.
2. Configure WireGuard between EU and Moscow and verify
   `curl http://10.77.0.1:8081/health/origin` from the EU host.
3. Copy the repository to `/opt/telescan-relay` and create `.env` from
   `.env.example` with the certificate contact email.
4. Point the `A` record for `api.tgtelescan.ru` to `212.69.87.142`.
5. Run `sudo bash ops/bootstrap-certificate.sh` from `/opt/telescan-relay`.
6. Install and enable the renewal timer from `ops/systemd/`.
7. Add GitHub production secrets and set repository variable
   `DEPLOY_ENABLED=true` only after the first healthy deployment.

## GitHub deployment secrets

- `RELAY_SERVER_HOST`
- `RELAY_SERVER_USER`
- `RELAY_SERVER_SSH_KEY`
- `RELAY_SERVER_KNOWN_HOSTS`

Deployment uploads the private repository contents over SSH. The server does
not need a GitHub token or deploy key.

Production access is split between two locked-password accounts. `ubuntu`
accepts only the administrator key and has passwordless sudo for host
maintenance. `deploy` accepts only the GitHub Actions key, belongs to the
`docker` group, and has no sudo access. Docker membership is root-equivalent
and must remain limited to the reviewed CI key. Direct root login, SSH password
authentication, keyboard-interactive authentication, and X11 forwarding are
disabled. Systemd units are installed once by an administrator; CI verifies
their contents before each deployment and fails closed if the checked-in
definitions differ.

## Local validation

```bash
docker compose config --quiet
docker compose build relay
bash -n ops/*.sh
```

## Certificate renewal

The systemd timer runs Certbot twice daily. The ACME challenge uses port 80 and
reloads nginx only after a successful renewal.
