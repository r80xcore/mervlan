#!/bin/sh
# Runtime contract for the WebUI repair terminal handoff. It executes the
# dispatcher body with a supervised repair-shaped worker and records the
# lifecycle rather than relying on source ordering alone.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
SERVICE="$BASE_DIR/functions/service-event-handler.sh"
TEST_ROOT="/tmp/mervlan_tmp/selftest.repair-terminal-order.$$"
umask 077
mkdir -p "$TEST_ROOT/functions" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

awk '
  /^dispatch_if_executable\(\) \{/ { in_dispatch=1 }
  in_dispatch { print }
  in_dispatch && $0 == "}" { exit }
' "$SERVICE" > "$TEST_ROOT/dispatch_fn.sh" || exit 1
. "$TEST_ROOT/dispatch_fn.sh" || exit 1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORKER="$TEST_ROOT/functions/update_mervlan_repair.sh"
TIMELINE="$TEST_ROOT/timeline"
cat > "$WORKER" <<'EOF'
#!/bin/sh
[ "${MERV_REPAIR_DEFER_WEBUI_TERMINAL:-}" = v1 ] || exit 91
printf '%s\n' repair-worker-return >> "$TIMELINE"
exit "${REPAIR_WORKER_RC:-0}"
EOF
chmod 700 "$WORKER"

MERV_BASE="$TEST_ROOT"
LOCKDIR="$TEST_ROOT/locks"
MERV_ACTION_LOCK_PATH="$LOCKDIR/mervlan_action.lock"
MERV_PROGRESS_ROOT="$TEST_ROOT/progress"
RAW='repairmain_vlanmgr_pgt_repair-order-token'
TYPE=repairmain
EVENT='vlanmgr_pgt_repair-order-token'
export MERV_BASE LOCKDIR MERV_ACTION_LOCK_PATH MERV_PROGRESS_ROOT RAW TYPE EVENT TIMELINE

logger() { :; }
get_progress_action_token() { printf 'repair-order-token\n'; }
merv_action_lock_enter() {
  MERV_ACTION_LOCK_MODE=self
  MERV_ACTION_LOCK_NONCE=dispatcher-nonce
  MERV_ACTION_LOCK_START=1
  return 0
}
merv_action_lock_export_child_context() {
  MERV_ACTION_LOCK_PARENT_HELD=1
  MERV_ACTION_LOCK_PARENT_PID=$$
  MERV_ACTION_LOCK_PARENT_START=1
  MERV_ACTION_LOCK_PARENT_NONCE=dispatcher-nonce
  return 0
}
merv_action_lock_clear_child_context() { return 0; }
merv_identity_proc_start() {
  [ "${IDENTITY_MODE:-ok}" = ok ] || return 1
  printf '1\n'
}
merv_identity_matches() { return 1; }
merv_action_lock_leave() {
  case "$1" in
    "$MERV_ACTION_LOCK_PATH") printf '%s\n' global-lock-release >> "$TIMELINE"; [ "${FAIL_RELEASE:-}" != global ] ;;
    *) printf '%s\n' event-lock-release >> "$TIMELINE"; [ "${FAIL_RELEASE:-}" != event ] ;;
  esac
}
merv_action_progress_init() {
  MERV_ACTION_PROGRESS_ENABLED=1
  MERV_ACTION_PROGRESS_LAST_RC=0
}
merv_action_progress_complete() {
  printf '%s\n' repair-terminal-complete >> "$TIMELINE"
  MERV_ACTION_PROGRESS_LAST_RC=0
}
merv_action_progress_fail() {
  printf '%s\n' repair-terminal-failed >> "$TIMELINE"
  MERV_ACTION_PROGRESS_LAST_RC=0
}

run_case() {
  : > "$TIMELINE"
  FAIL_RELEASE="${1:-}"
  IDENTITY_MODE="${2:-ok}"
  REPAIR_WORKER_RC="${3:-0}"
  export FAIL_RELEASE IDENTITY_MODE REPAIR_WORKER_RC
  dispatch_if_executable "$WORKER"
}

run_case || fail 'successful deferred repair dispatch failed'
worker_line=$(grep -n '^repair-worker-return$' "$TIMELINE" | cut -d: -f1)
event_line=$(grep -n '^event-lock-release$' "$TIMELINE" | cut -d: -f1)
global_line=$(grep -n '^global-lock-release$' "$TIMELINE" | cut -d: -f1)
complete_line=$(grep -n '^repair-terminal-complete$' "$TIMELINE" | cut -d: -f1)
[ -n "$worker_line" ] && [ -n "$event_line" ] && [ -n "$global_line" ] && [ -n "$complete_line" ] || \
  fail 'successful handoff timeline is incomplete'
[ "$worker_line" -lt "$event_line" ] && [ "$event_line" -lt "$complete_line" ] && \
  [ "$global_line" -lt "$complete_line" ] || fail 'terminal complete preceded a required lifecycle boundary'

for release in event global; do
  if run_case "$release"; then
    fail "$release release failure returned clean success"
  fi
  grep -Fq 'repair-terminal-complete' "$TIMELINE" && fail "$release release failure published complete"
  grep -Fq 'repair-terminal-failed' "$TIMELINE" || fail "$release release failure did not publish failed"
done

# No authenticated worker identity can yield a child-side 99% handoff, but
# never dispatcher-owned complete. The dispatcher releases only after wait and
# resolves the deferred status as failure.
if run_case '' missing; then
  fail 'unverified worker identity returned clean success'
fi
grep -Fq 'repair-terminal-complete' "$TIMELINE" && fail 'unverified worker identity published complete'
grep -Fq 'repair-terminal-failed' "$TIMELINE" || fail 'unverified worker identity left deferred status unresolved'

# If the pre-repair action-progress helper is unavailable, the dispatcher uses
# its fixed, atomic repair-only format-v2 fallback after lock release.
merv_action_progress_init() { MERV_ACTION_PROGRESS_ENABLED=0; MERV_ACTION_PROGRESS_LAST_RC=1; }
rm -f "$MERV_PROGRESS_ROOT/repair-order-token.json"
run_case || fail 'fallback terminal publication failed'
grep -Fq '"state":"complete"' "$MERV_PROGRESS_ROOT/repair-order-token.json" || \
  fail 'repair-only fallback did not publish complete'

printf 'REPAIR_DISPATCH_TERMINAL_ORDER_CONTRACT_OK\n'
