# EU relay deployment and recovery

## Local evidence

`bash ops/preflight.sh` resolves the explicit `telescan-relay:release`
reference from Compose JSON, builds it, inspects the immutable candidate ID,
and validates that exact image with nginx syntax and live TLS, redirect, and
public deny-route semantics. It never derives a candidate from
`docker compose images -q`.

The transaction fixture covers success, candidate failure, SIGKILL before and
after pointer promotion, committed recovery, and loss of the outer SSH
supervisor. `ops/test-recovery-unit-lock.sh` proves a failed systemd `flock`
cannot fall through to the controller.

## Host preparation

From a provider-console-backed administrator session, with no durable release
intent, run:

```sh
sudo bash ops/install-release-recovery.sh \
  --apply --confirm APPLY_RELAY_RELEASE_RECOVERY_UNIT
```

This transactionally installs the recovery service/path and Certbot
service/timer. Certbot runs from `/opt/telescan-relay/current`; the boot service,
online path watcher, and timer are enabled, and previous unit files are restored
if installation fails. CI only compares and observes these units; it never
changes them.

For SSH changes, keep the provider console and current SSH session open:

```sh
sudo bash ops/install-host-hardening.sh \
  --apply --confirm APPLY_TELESCAN_SSH_HARDENING \
  --recovery-access-confirmed
```

Prove a second independent key-authenticated login and rerun
`ops/check-ssh-policy.sh` before ending the maintenance session.

## Immutable release transaction

After acquiring FD 9 on `/tmp/telescan-production-deploy.lock` with an
1800-second timeout, the workflow extracts the secret-free archive into `/tmp`
and invokes:

```sh
"$release_root/ops/run-release-transaction.sh" \
  --apply --confirm DEPLOY_RELAY_WITH_ROLLBACK \
  --active-root /opt/telescan-relay \
  --release-root "$release_root"
```

`/opt/telescan-relay/.env` remains host-owned. Every immutable release receives
a symlink to it; incoming `.env` files are rejected. Host state is:

- `releases/<release-id>`: immutable, fully-fsynced configuration;
- `current`: atomic symlink to exactly one release;
- `.release-state/intent.json`: durable phase and old/new image identities;
- `.release-state/recovery-controller`: atomic pointer to a versioned,
  fully-fsynced controller;
- `telescan-relay:rollback-<release-id>`: protected prior image until intent
  removal is durable.

The previous image is tagged before intent publication. After build and exact
semantic validation, `current` moves atomically and the candidate is recreated
with `restart: no`. The transaction requires local relay health, Moscow origin
health over WireGuard, and normal public readiness. Only after a durable commit
is restart armed to `unless-stopped`; intent is durably cleared before the
rollback tag is best-effort removed.

On any non-committed failure, recovery retags the protected prior image,
switches `current` back, recreates the old container, and repeats the bounded
end-to-end health gate. A committed-but-interrupted transaction finishes the
candidate instead. Never remove a retained intent, controller pointer, or
rollback tag by hand.

The external supervisor handles child failures. If the entire SSH/session
supervisor disappears, the enabled `.path` unit observes the intent, waits for
the same production lock through a fail-closed `flock` command, and invokes the
durable controller. The boot-enabled service provides the same recovery after
host restart.
