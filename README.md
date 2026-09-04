# Telescan EU Relay

Private edge relay for `api.tgtelescan.ru`. The relay terminates HTTPS in the
Netherlands and forwards API traffic to the Moscow origin through WireGuard.
The production relay, DNS route, certificate-renewal timer, and deployment
workflow are active.

## Network model

```text
iOS / VPN -> api.tgtelescan.ru:443 -> EU nginx
           -> WireGuard 10.77.0.2 -> 10.77.0.1:8081 Moscow nginx
           -> FastAPI 127.0.0.1:8000
```

The FastAPI port remains loopback-only. Swagger remains enabled in FastAPI and
is available only through an SSH tunnel whose final target is Moscow. The public
relay returns `404` for `/docs`, `/docs/`, `/redoc`, `/openapi.json`, and
`/internal/` before proxying. TLS terminates on the EU host; the EU-to-Moscow
origin hop is encrypted by WireGuard and is restricted to the two tunnel
addresses.

## Production host

- Region: Netherlands
- Public IP: `212.69.87.142`
- DNS: `api.tgtelescan.ru` resolves to the relay
- WireGuard address: `10.77.0.2/30`
- Moscow peer: `10.77.0.1/30`
- Installation path: `/opt/telescan-relay`

Secrets, WireGuard private keys, certificates, and `.env` are never committed.

The host also provides a dedicated Telegram HTTP CONNECT proxy for the
production bot. It listens only on the private WireGuard address
`10.77.0.2:8889`, accepts only the Moscow peer `10.77.0.1`, and permits only
`api.telegram.org:443`. Install or reconcile it on the relay host with:

```sh
sudo ./ops/install-telegram-egress.sh \
  --apply --confirm INSTALL_TELESCAN_BOT_EGRESS
```

## Provisioning or recovery

1. Install host packages with `sudo bash ops/install-host-dependencies.sh`.
2. From the provider console, apply and verify the interactive SSH baseline as
   documented in `RUNBOOK.md`, then prove a separate key login.
3. Configure WireGuard between EU and Moscow and verify
   `curl http://10.77.0.1:8081/health/origin` from the EU host.
4. Copy the repository to `/opt/telescan-relay` and create `.env` from
   `.env.example` with the certificate contact email.
5. Point the `A` record for `api.tgtelescan.ru` to `212.69.87.142`.
6. Run `sudo bash ops/bootstrap-certificate.sh` from `/opt/telescan-relay`.
7. Run the guarded release-runtime installer from `RUNBOOK.md`; it installs
   the renewal timer and durable online recovery watcher together.
8. Add GitHub production secrets and set repository variable
   `DEPLOY_ENABLED=true` only after the first healthy deployment.

These steps are for a replacement host or disaster recovery; the current host
has already completed them. Never regenerate a WireGuard key or replace the DNS
record during an ordinary application deployment.

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

UFW allows only SSH, HTTP, HTTPS, and WireGuard ingress. Fail2ban protects SSH.
Docker, Fail2ban, `wg-quick@wg0`, and the certificate-renewal timer are enabled
and active. The relay container uses a read-only root filesystem, bounded tmpfs
mounts, a minimal capability allow-list, `no-new-privileges`, and a Docker health
check. nginx `1.30.4-alpine3.24` and Certbot `v5.7.0` are pinned by immutable
multi-platform digests.

## Local validation

```sh
bash ops/preflight.sh
```

The preflight includes a live semantic route check against the built image.
Production writes a durable old/new release intent, protects the previous image
under a unique rollback tag, and switches one atomic `current` pointer. It rolls
back automatically if local relay, Moscow origin, or normal public-ready
verification fails. The online path watcher also recovers an interrupted outer
SSH session. Operational details and the interactive-only SSH hardening guard
are in `RUNBOOK.md`.

## Administrative Swagger tunnel

The EU host is only a jump host for Swagger; it does not listen on
`127.0.0.1:8000`. Forward the Moscow loopback port through EU:

```sh
ssh -N \
  -L 9000:127.0.0.1:8000 \
  -i ~/.ssh/telescan_cloud \
  -o 'ProxyCommand=ssh -i ~/.ssh/telescan_cloud -W %h:%p ubuntu@212.69.87.142' \
  ubuntu@89.169.153.38
```

Open [http://127.0.0.1:9000/docs](http://127.0.0.1:9000/docs) while the command
is running. A tunnel whose final target is `ubuntu@212.69.87.142` will return
`Connection refused` because FastAPI runs only on the Moscow host.

## Certificate renewal

The systemd timer runs Certbot twice daily. The ACME challenge uses port 80 and
reloads nginx only after a successful renewal. Deployment verifies the active
and enabled timer state.

## Repository workflow

Pull requests validate Compose, shell syntax, and live semantics of the pinned
relay image. A
successful push to `main` streams the release into immutable staging only after
the remote production lock is held, preserves the host-owned `.env`, verifies
the installed systemd definitions, creates and fsyncs an immutable release,
rebuilds the relay, and runs end-to-end health checks. Candidate containers use
`restart: no` until a durable commit. A failed or interrupted rollout restores
the previous `current` pointer and protected image. Production deployment is
gated by `DEPLOY_ENABLED=true` and serialized behind one production lock.

Cross-service production topology, recovery order, and security boundaries are
maintained in the private
[`Telescan-internal-docs`](https://github.com/hiTechTeam/Telescan-internal-docs)
repository.

## License

Proprietary and confidential. See [LICENSE](LICENSE).
