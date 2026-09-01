#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
unit=ops/systemd/telescan-relay-release-recovery.service
temporary_root="$(mktemp -d)"
trap 'rm -r -- "$temporary_root"' EXIT
mock_bin="$temporary_root/bin"
log="$temporary_root/controller.log"
install -d -m 0700 "$mock_bin"

install -m 0755 /dev/null "$mock_bin/flock"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '[[ "$1" == --exclusive && "$2" == --timeout && "$3" == 1800 && "$4" == 9 ]]' \
  '[[ "${RECOVERY_TEST_FLOCK_FAIL:-0}" != 1 ]]' \
  >"$mock_bin/flock"
install -m 0755 /dev/null "$mock_bin/controller"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  ': >"$RECOVERY_TEST_LOG"' \
  >"$mock_bin/controller"

exec_line="$(sed -n 's|^ExecStart=/bin/bash -c '\''\(.*\)'\''$|\1|p' "$unit")"
[[ -n "$exec_line" ]]
test_command="$(UNIT_COMMAND="$exec_line" MOCK_CONTROLLER="$mock_bin/controller" \
  TEST_LOCK="$temporary_root/production.lock" python3 -c '
import os, re, shlex
value = os.environ["UNIT_COMMAND"].replace(
    "/tmp/telescan-production-deploy.lock", os.environ["TEST_LOCK"]
)
value, count = re.subn(
    r"exec /\S*recovery-controller/ops/run-release-transaction\.sh.*$",
    "exec " + shlex.quote(os.environ["MOCK_CONTROLLER"]),
    value,
)
if count != 1:
    raise SystemExit("could not isolate recovery controller command")
print(value)
')"

set +e
PATH="$mock_bin:$PATH" RECOVERY_TEST_FLOCK_FAIL=1 RECOVERY_TEST_LOG="$log" \
  /bin/bash -c "$test_command" >/dev/null 2>&1
failed_status=$?
set -e
[[ "$failed_status" -ne 0 ]]
[[ ! -e "$log" ]]

PATH="$mock_bin:$PATH" RECOVERY_TEST_FLOCK_FAIL=0 RECOVERY_TEST_LOG="$log" \
  /bin/bash -c "$test_command" >/dev/null
[[ -f "$log" ]]
echo "Recovery unit fail-closed lock fixture passed."
