# Telescan EU Relay

Public TLS edge for `api.tgtelescan.ru`. It forwards requests from the
Netherlands to Moscow through WireGuard:

```text
iOS -> EU nginx -> 10.77.0.2 -> 10.77.0.1:8081 -> Moscow API
```

Public `/internal/`, Swagger and OpenAPI routes return `404`. Secrets,
certificates, WireGuard keys and `.env` remain on the host. The relay also runs
a private Telegram proxy on `10.77.0.2:8889`, limited to the Moscow peer and
`api.telegram.org:443`.

## Check and deploy

```sh
bash ops/preflight.sh
sudo ./ops/install-telegram-egress.sh \
  --apply --confirm INSTALL_TELESCAN_BOT_EGRESS
```

Pushes to protected `main` deploy only when `DEPLOY_ENABLED=true`. Releases are
immutable, serialized by the production lock and automatically restored if
relay, origin or public readiness fails. TLS renewal and interrupted-deployment
recovery use systemd units installed by an administrator.

Host provisioning and SSH hardening are recovery-only operations; never rotate
WireGuard keys or DNS during an ordinary deploy. See [RUNBOOK.md](RUNBOOK.md).

## License

Proprietary and confidential. See [LICENSE](LICENSE).
