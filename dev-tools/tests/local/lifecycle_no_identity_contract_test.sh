#!/bin/sh
# Static/structural contract for fail-closed worker identity handling.

set -u
BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
SERVICE="$BASE_DIR/functions/service-event-handler.sh"
EXECUTE="$BASE_DIR/functions/execute_nodes.sh"
_fail=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _fail=1; }
pass() { printf 'PASS: %s\n' "$1"; }

# Unknown worker identity must be reaped by wait rather than signalled by PID.
# Authenticated cancellation in other branches remains allowed only after the
# exact PID/start check; this assertion targets the unverified branch itself.
_noid_block=$(awk '
  /case "\$_se_worker_start" in/ { in_block=1 }
  in_block { print }
  in_block && /;;/ { exit }
' "$SERVICE")
if printf '%s\n' "$_noid_block" | grep -Fq 'kill "$_se_worker_pid"'; then
  fail 'dispatcher has unauthenticated worker PID kill'
else
  printf '%s\n' "$_noid_block" | grep -Fq 'wait "$_se_worker_pid"' ||
    fail 'dispatcher no-identity branch does not reap direct child'
  [ "$_fail" -eq 0 ] && pass dispatcher-no-identity-reaps-without-kill
fi
grep -Fq 'wait "$main_pid"' "$EXECUTE" || fail 'execute-nodes no-identity path does not reap direct child'
_reconcile_block=$(awk '
  /^execute_nodes_reconcile_signal_children\(\)/ { in_block=1 }
  in_block { print }
  in_block && /^}/ { exit }
' "$EXECUTE")
printf '%s\n' "$_reconcile_block" | grep -Fq 'if type merv_process_identity_matches' ||
  fail 'execute-nodes signal path does not authenticate helper availability'
printf '%s\n' "$_reconcile_block" | grep -Fq 'reap the direct child' ||
  fail 'execute-nodes signal path lacks fail-closed identity fallback'
printf '%s\n' "$_reconcile_block" | grep -Fq 'wait "$main_pid"' ||
  fail 'execute-nodes signal path does not wait when exact identity is unavailable'

# The authenticated context must be published before normal worker launch;
# export failure remains a nonzero terminal path.
grep -Fq 'worker was not launched' "$SERVICE" || fail 'dispatcher export failure launch gate missing'
grep -Fq '_se_script_rc=75' "$SERVICE" || fail 'dispatcher export/identity failure is not fail-closed'

if [ "$_fail" -eq 0 ]; then
  printf 'LIFECYCLE_NO_IDENTITY_CONTRACT_OK\n'
  exit 0
fi
printf 'LIFECYCLE_NO_IDENTITY_CONTRACT_FAILED\n' >&2
exit 1
