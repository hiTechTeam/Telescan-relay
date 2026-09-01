#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

expect_rejected() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "Safety gate accepted an incomplete invocation: $name" >&2
    exit 1
  fi
}

expect_rejected deploy bash ops/deploy-with-rollback.sh
expect_rejected release-supervisor bash ops/run-release-transaction.sh
expect_rejected release-recovery-install bash ops/install-release-recovery.sh
grep -q 'systemctl reset-failed' ops/install-release-recovery.sh
expect_rejected ssh-apply bash ops/install-host-hardening.sh
expect_rejected relay-check-argument bash ops/check-relay.sh --unexpected
grep -q '^  group: telescan-relay-production$' .github/workflows/deploy.yml
grep -q "github.ref == 'refs/heads/main'" .github/workflows/deploy.yml
grep -q "github.event_name == 'push'" .github/workflows/deploy.yml
grep -q "github.event_name == 'workflow_dispatch'" .github/workflows/deploy.yml
grep -q 'flock --exclusive --timeout 1800 9' .github/workflows/deploy.yml
grep -q "stat -c '%U:%G:%a'" .github/workflows/deploy.yml
grep -q 'root:root:644' .github/workflows/deploy.yml
grep -q 'test-release-transaction.sh' .github/workflows/deploy.yml
grep -q 'tar --extract --gzip --file=- --directory "$release_root"' \
  .github/workflows/deploy.yml
grep -q -- '--active-root /opt/telescan-relay' .github/workflows/deploy.yml
if grep -Eq 'Upload release|rsync' .github/workflows/deploy.yml; then
  echo "Relay workflow still mutates the active release outside its transaction." >&2
  exit 1
fi
lock_line="$(grep -n 'flock --exclusive --timeout 1800 9' \
  .github/workflows/deploy.yml | cut -d: -f1)"
extract_line="$(grep -n 'tar --extract --gzip --file=- --directory' \
  .github/workflows/deploy.yml | cut -d: -f1)"
transaction_line="$(grep -n '"\$release_root/ops/run-release-transaction.sh"' \
  .github/workflows/deploy.yml | cut -d: -f1)"
if [[ ! "$lock_line" =~ ^[0-9]+$ || ! "$extract_line" =~ ^[0-9]+$ || \
      ! "$transaction_line" =~ ^[0-9]+$ || \
      "$lock_line" -ge "$extract_line" || "$extract_line" -ge "$transaction_line" ]]; then
  echo "Relay lock must precede staging extraction and release transaction." >&2
  exit 1
fi
if grep -Erq 'docker compose images[[:space:]]+-q' ops .github docker-compose.yml; then
  echo "Unsafe running-container image discovery remains in relay deployment files." >&2
  exit 1
fi
grep -q 'image: telescan-relay:release' docker-compose.yml
grep -q 'docker compose config --format json' ops/preflight.sh
grep -q 'docker image inspect' ops/preflight.sh
grep -q 'config --format json' ops/deploy-with-rollback.sh
grep -q 'docker image inspect' ops/deploy-with-rollback.sh
grep -q 'transaction_started=true' ops/deploy-with-rollback.sh
grep -q 'trap transaction_exit EXIT' ops/deploy-with-rollback.sh
grep -q 'rsync --archive --checksum --delete' ops/deploy-with-rollback.sh
grep -q 'rollback_image_reference="telescan-relay:rollback-' ops/deploy-with-rollback.sh
grep -q 'write-intent' ops/deploy-with-rollback.sh
grep -q 'switch_release "$new_name"' ops/deploy-with-rollback.sh
grep -q 'fsync_directory(root.parent)' ops/release-state.py
grep -q 'recovery-controller' ops/run-release-transaction.sh
grep -q 'PathExists=/opt/telescan-relay/.release-state/intent.json' \
  ops/systemd/telescan-relay-release-recovery.path
grep -q 'telescan-relay-certbot-renew.service' ops/install-release-recovery.sh
grep -q 'telescan-relay-certbot-renew.timer' ops/install-release-recovery.sh
grep -q 'enable --now telescan-relay-certbot-renew.timer' \
  ops/install-release-recovery.sh
grep -q 'is-enabled --quiet telescan-relay-certbot-renew.timer' \
  .github/workflows/deploy.yml
grep -q 'requires inherited production lock FD 9' ops/deploy-with-rollback.sh
grep -q 'find "$release_root" -name .env' ops/deploy-with-rollback.sh
bash ops/test-release-transaction.sh >/dev/null
bash ops/test-recovery-unit-lock.sh >/dev/null
resolved_release_reference="$(
  docker compose config --format json |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["relay"]["image"])'
)"
test "$resolved_release_reference" = telescan-relay:release

echo "Relay staged config/image transaction, SSH, branch, and production-lock safety gates passed."
