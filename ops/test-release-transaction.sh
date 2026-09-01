#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
raw_root="$(mktemp -d /tmp/telescan-relay-transaction-test.XXXXXX)"
test_root="$(cd "$raw_root" && pwd -P)"
mock_bin="$test_root/mock-bin"
active_root="$test_root/active"
release_root="$test_root/release"
test_log="$test_root/commands.log"
image_state="$test_root/image-state"
old_ref_state="$test_root/old-ref-state"
rollback_state="$test_root/rollback-ref-state"
cleanup() {
  local status=$?
  trap - EXIT
  chmod -R u+w "$test_root" 2>/dev/null || true
  rm -r -- "$test_root"
  exit "$status"
}
trap cleanup EXIT
install -d -m 0700 "$mock_bin" "$active_root/ops" "$release_root/ops"

write_executable() {
  local path="$1"
  shift
  install -m 0755 /dev/null "$path"
  printf '%s\n' "$@" >"$path"
}

write_executable "$mock_bin/realpath" \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '[[ $# -eq 1 && -e "$1" ]]' \
  'python3 -c '\''import os,sys; print(os.path.realpath(sys.argv[1]))'\'' "$1"'
write_executable "$mock_bin/flock" \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'mode=block' \
  'if [[ "$1" == --nonblock && "$2" == 9 ]]; then mode=nonblock' \
  'elif [[ "$1" == --exclusive && "$2" == --timeout && "$3" == 1800 && "$4" == 9 ]]; then mode=block' \
  'else exit 2; fi' \
  'python3 -c '\''import fcntl,sys; fcntl.flock(9, fcntl.LOCK_EX | (fcntl.LOCK_NB if sys.argv[1] == "nonblock" else 0))'\'' "$mode"'
write_executable "$mock_bin/timeout" \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '[[ "$1" == --signal=TERM && "$2" == 360 ]]' \
  'shift 2' \
  'exec "$@"'
write_executable "$mock_bin/docker" \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'old_id=sha256:3333333333333333333333333333333333333333333333333333333333333333' \
  'candidate_id=sha256:4444444444444444444444444444444444444444444444444444444444444444' \
  'release_ref=telescan-relay:release' \
  'old_ref=telescan-relay-relay:latest' \
  'if [[ "$1" == compose ]]; then' \
  '  shift' \
  '  [[ "$1" == --env-file && "$2" == "$TRANSACTION_ACTIVE_ROOT/.env" ]]' \
  '  shift 2' \
  '  [[ "$1" == --project-name && "$2" == telescan-relay ]]' \
  '  shift 2' \
  '  if [[ "${1:-}" == -f ]]; then' \
  '    [[ "$2" == */docker-compose.yml && "$3" == -f && "$4" == */compose-transaction-no-restart.yaml ]]' \
  '    shift 4' \
  '  fi' \
  '  case "${1:-}" in' \
  '    config)' \
  '      if [[ "${2:-}" == --format && "${3:-}" == json ]]; then' \
  '        printf "{\"services\":{\"relay\":{\"image\":\"%s\"}}}\n" "$release_ref"' \
  '      fi' \
  '      ;;' \
  '    ps)' \
  '      if [[ "${2:-}" == -q && "${3:-}" == relay ]]; then echo container-relay; fi' \
  '      ;;' \
  '    build)' \
  '      [[ "${2:-}" == relay ]]' \
  '      printf "%s\n" "$candidate_id" >"$TRANSACTION_IMAGE_STATE"' \
  '      echo candidate-build >>"$TRANSACTION_TEST_LOG"' \
  '      ;;' \
  '    up)' \
  '      echo compose-up >>"$TRANSACTION_TEST_LOG"' \
  '      ;;' \
  '    logs) exit 0 ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  'elif [[ "$1" == inspect && "$2" == --format ]]; then' \
  '  case "$3" in' \
  '    *State.Running*) echo true ;;' \
  '    *Config.Image*) echo "$old_ref" ;;' \
  '    *Image*) echo "$old_id" ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  'elif [[ "$1 $2" == "image inspect" && "$3" == --format ]]; then' \
  '  target="${5:-}"' \
  '  case "$target" in' \
  '    "$release_ref") cat "$TRANSACTION_IMAGE_STATE" ;;' \
  '    "$old_ref") cat "$TRANSACTION_OLD_REF_STATE" ;;' \
  '    telescan-relay:rollback-*) cat "$TRANSACTION_ROLLBACK_STATE" ;;' \
  '    sha256:*)' \
  '      if [[ "$target" == "$old_id" && "${TRANSACTION_OLD_IMAGE_MISSING:-0}" == 1 ]]; then exit 1; fi' \
  '      echo "$target"' \
  '      ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  'elif [[ "$1 $2" == "container commit" ]]; then' \
  '  [[ "$3" == --pause=true && "$4" == container-relay && "$5" == telescan-relay:rollback-* ]]' \
  '  materialized_id=sha256:5555555555555555555555555555555555555555555555555555555555555555' \
  '  printf "%s\n" "$materialized_id" >"$TRANSACTION_ROLLBACK_STATE"' \
  '  echo legacy-image-materialized >>"$TRANSACTION_TEST_LOG"' \
  '  echo "$materialized_id"' \
  'elif [[ "$1 $2" == "image tag" ]]; then' \
  '  source_id="$3"; target_ref="$4"' \
  '  if [[ "$source_id" == telescan-relay:rollback-* ]]; then source_id="$(cat "$TRANSACTION_ROLLBACK_STATE")"; fi' \
  '  case "$target_ref" in' \
  '    "$release_ref") printf "%s\n" "$source_id" >"$TRANSACTION_IMAGE_STATE" ;;' \
  '    "$old_ref") printf "%s\n" "$source_id" >"$TRANSACTION_OLD_REF_STATE" ;;' \
  '    telescan-relay:rollback-*) printf "%s\n" "$source_id" >"$TRANSACTION_ROLLBACK_STATE" ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  '  echo "image-tag-$source_id-$target_ref" >>"$TRANSACTION_TEST_LOG"' \
  'elif [[ "$1 $2" == "image rm" ]]; then' \
  '  : >"$TRANSACTION_ROLLBACK_STATE"' \
  'elif [[ "$1" == update && "$2" == --restart && "$3" == unless-stopped ]]; then' \
  '  echo restart-armed >>"$TRANSACTION_TEST_LOG"' \
  'else' \
  '  printf "Unexpected mocked Docker command: %q " "$@" >&2; echo >&2; exit 1' \
  'fi'

prepare_case() {
  local candidate_status="$1"
  rm -r -- "$active_root" "$release_root"
  install -d -m 0700 "$active_root/ops" "$release_root/ops"
  printf 'runtime-only\n' >"$active_root/.env"
  chmod 0600 "$active_root/.env"
  printf 'services: {}\n' >"$active_root/docker-compose.yml"
  printf 'old\n' >"$active_root/version.txt"
  write_executable "$active_root/ops/check-relay.sh" \
    '#!/usr/bin/env bash' \
    'echo old-health >>"$TRANSACTION_TEST_LOG"' \
    'exit 0'

  printf 'services: {}\n' >"$release_root/docker-compose.yml"
  printf 'FROM scratch\n' >"$release_root/Dockerfile"
  printf 'events {}\n' >"$release_root/nginx.conf"
  printf 'new\n' >"$release_root/version.txt"
  install -m 0755 ops/release-state.py "$release_root/ops/release-state.py"
  install -m 0644 ops/compose-transaction-no-restart.yaml \
    "$release_root/ops/compose-transaction-no-restart.yaml"
  write_executable "$release_root/ops/validate-relay-image.sh" \
    '#!/usr/bin/env bash' \
    '[[ "$1" == sha256:4444444444444444444444444444444444444444444444444444444444444444 ]]' \
    'echo candidate-validated >>"$TRANSACTION_TEST_LOG"'
  write_executable "$release_root/ops/check-relay.sh" \
    '#!/usr/bin/env bash' \
    'echo candidate-health >>"$TRANSACTION_TEST_LOG"' \
    "exit $candidate_status"
  : >"$test_log"
  printf '%s\n' sha256:3333333333333333333333333333333333333333333333333333333333333333 >"$image_state"
  cp "$image_state" "$old_ref_state"
  : >"$rollback_state"
}

invoke() (
  lock_mode="${2:-locked}"
  if [[ "$lock_mode" == locked ]]; then
    exec 9>"$test_root/production.lock"
    "$mock_bin/flock" --exclusive --timeout 1800 9
  fi
  PATH="$mock_bin:$PATH" \
  TRANSACTION_TEST_LOG="$test_log" \
  TRANSACTION_ACTIVE_ROOT="$active_root" \
  TRANSACTION_IMAGE_STATE="$image_state" \
  TRANSACTION_OLD_REF_STATE="$old_ref_state" \
  TRANSACTION_ROLLBACK_STATE="$rollback_state" \
  TRANSACTION_OLD_IMAGE_MISSING="${TRANSACTION_OLD_IMAGE_MISSING:-0}" \
  TELESCAN_RELAY_TRANSACTION_TEST_MODE=1 \
  TELESCAN_RELAY_TRANSACTION_TEST_ROOT="$test_root" \
  TELESCAN_RELAY_TRANSACTION_KILLPOINT="${1:-}" \
    bash ops/run-release-transaction.sh \
      --apply --confirm DEPLOY_RELAY_WITH_ROLLBACK \
      --active-root "$active_root" --release-root "$release_root"
)

recover() {
  PATH="$mock_bin:$PATH" \
  TRANSACTION_TEST_LOG="$test_log" \
  TRANSACTION_ACTIVE_ROOT="$active_root" \
  TRANSACTION_IMAGE_STATE="$image_state" \
  TRANSACTION_OLD_REF_STATE="$old_ref_state" \
  TRANSACTION_ROLLBACK_STATE="$rollback_state" \
  TELESCAN_RELAY_TRANSACTION_TEST_MODE=1 \
  TELESCAN_RELAY_TRANSACTION_TEST_ROOT="$test_root" \
    bash ops/deploy-with-rollback.sh \
      --apply --confirm RECOVER_RELAY_RELEASE \
      --active-root "$active_root" --recover-only
}

persistent_recover() {
  PATH="$mock_bin:$PATH" \
  TRANSACTION_TEST_LOG="$test_log" \
  TRANSACTION_ACTIVE_ROOT="$active_root" \
  TRANSACTION_IMAGE_STATE="$image_state" \
  TRANSACTION_OLD_REF_STATE="$old_ref_state" \
  TRANSACTION_ROLLBACK_STATE="$rollback_state" \
  TELESCAN_RELAY_TRANSACTION_TEST_MODE=1 \
  TELESCAN_RELAY_TRANSACTION_TEST_ROOT="$test_root" \
    bash "$active_root/.release-state/recovery-controller/ops/run-release-transaction.sh" \
      --apply --confirm RECOVER_RELAY_RELEASE \
      --active-root "$active_root" --recover-only
}

run_expect() {
  local expected="$1" killpoint="${2:-}" lock_mode="${3:-locked}" output="$test_root/transaction.out" actual
  set +e
  invoke "$killpoint" "$lock_mode" >"$output" 2>&1
  actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    cat "$output" >&2
    echo "Unexpected relay transaction status: expected=$expected actual=$actual" >&2
    exit 1
  fi
}

prepare_case 0
run_expect 1 "" unlocked
[[ ! -e "$active_root/current" ]]

prepare_case 0
printf 'must-not-enter-release\n' >"$release_root/.env"
run_expect 1
[[ "$(cat "$active_root/current/version.txt")" == old ]]
[[ "$(cat "$active_root/.env")" == runtime-only ]]
[[ -L "$active_root/current/.env" ]]

prepare_case 42
run_expect 1
[[ "$(cat "$active_root/current/version.txt")" == old ]]
[[ "$(cat "$active_root/.env")" == runtime-only ]]
[[ -L "$active_root/current/.env" ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]
grep -q '^candidate-health$' "$test_log"
grep -q '^old-health$' "$test_log"

prepare_case 0
run_expect 0
[[ "$(cat "$active_root/current/version.txt")" == new ]]
[[ "$(cat "$active_root/.env")" == runtime-only ]]
[[ -L "$active_root/current/.env" ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]

prepare_case 0
TRANSACTION_OLD_IMAGE_MISSING=1 run_expect 0
[[ "$(cat "$active_root/current/version.txt")" == new ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]
grep -q '^legacy-image-materialized$' "$test_log"

for killpoint in after-intent before-pointer after-pointer after-recreate; do
  prepare_case 0
  run_expect 1 "$killpoint"
  [[ "$(cat "$active_root/current/version.txt")" == old ]]
[[ "$(cat "$active_root/.env")" == runtime-only ]]
[[ -L "$active_root/current/.env" ]]
  [[ ! -e "$active_root/.release-state/intent.json" ]]
done

prepare_case 0
run_expect 1 after-commit
[[ "$(cat "$active_root/current/version.txt")" == new ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]

prepare_case 0
(
  for _ in {1..200}; do
    [[ -f "$active_root/.release-state/intent.json" ]] && break
    sleep 0.02
  done
  [[ -f "$active_root/.release-state/intent.json" ]]
  exec 9>"$test_root/production.lock"
  "$mock_bin/flock" --exclusive --timeout 1800 9
  persistent_recover >"$test_root/path-recovery.out" 2>&1
) &
watcher_pid=$!
run_expect 137 outer-after-intent
wait "$watcher_pid"
[[ "$(cat "$active_root/current/version.txt")" == old ]]
[[ ! -e "$active_root/.release-state/intent.json" ]]

echo "Relay immutable transaction passed rollback/success, child SIGKILL, and outer-session path-watcher recovery fixtures."
