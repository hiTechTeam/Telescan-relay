# EU relay recovery

Run `bash ops/preflight.sh` before deployment.

From a provider-console-backed administrator session:

```sh
sudo bash ops/install-release-recovery.sh \
  --apply --confirm APPLY_RELAY_RELEASE_RECOVERY_UNIT
```

Apply SSH hardening separately, keep the provider console open and verify a
second independent key login before ending the session.

Production deployment holds `/tmp/telescan-production-deploy.lock`, keeps the
host `.env`, protects the previous image and writes a durable intent before
atomically switching `/opt/telescan-relay/current`. The candidate must pass
local relay, Moscow origin and public readiness checks.

Failure before commit restores the previous release/image. A committed but
interrupted release is completed by the supervisor or systemd recovery unit.
Never remove a retained intent, controller pointer or rollback tag manually.
