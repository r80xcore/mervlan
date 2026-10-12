#!/bin/sh
# Runtime M-06 contract: failed child-context export must launch no worker.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
SERVICE="$BASE_DIR/functions/service-event-handler.sh"
TEST_ROOT="/tmp/mervlan_tmp/selftest.dispatch-export.$(date +%s).$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15
. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || exit 1
merv_test_context_enable "$BASE_DIR" "$TEST_ROOT" || exit 1

# The extracted dispatcher test uses a narrow in-process continuation stub;
# production lease parsing and child activation are exercised separately by
# continuation_contract_test.sh.
MERV_BASE="$TEST_ROOT/fake-base"
mkdir -p "$MERV_BASE/settings" || exit 1
cat > "$MERV_BASE/settings/lib_mutation_admission.sh" <<'EOF'
merv_continuation_activate_wait() { return 0; }
merv_mutation_admit_action() { return 0; }
EOF
chmod 700 "$MERV_BASE" "$MERV_BASE/settings" "$MERV_BASE/settings/lib_mutation_admission.sh"
export MERV_BASE

# Extract only the dispatch function; the event router itself is intentionally
# not sourced because production paths are fixed to /jffs on ASUSWRT.
awk '
  /^dispatch_if_executable\(\) \{/ { in_dispatch=1 }
  in_dispatch { print }
  in_dispatch && $0 == "}" { exit }
' "$SERVICE" > "$TEST_ROOT/dispatch_fn.sh" || exit 1
. "$TEST_ROOT/dispatch_fn.sh" || exit 1

WORKER="$TEST_ROOT/execute_nodes.sh"
MARKER="$TEST_ROOT/worker-ran"
RELEASES="$TEST_ROOT/releases"
PROGRESS="$TEST_ROOT/progress"
ACK="$TEST_ROOT/ack"
printf '#!/bin/sh\nprintf ran > "%s"\n' "$MARKER" > "$WORKER"
chmod 700 "$WORKER"

LOCKDIR="$TEST_ROOT/locks"
MERV_ACTION_LOCK_PATH="$LOCKDIR/mervlan_action.lock"
RAW=apply_vlanmgr
TYPE=dispatch
EVENT=export_test
MERV_PROGRESS_TOKEN=''
export LOCKDIR MERV_ACTION_LOCK_PATH RAW TYPE EVENT MERV_PROGRESS_TOKEN

logger() { :; }
get_progress_request_token() { printf 'dispatch-test-token\n'; }
merv_action_progress_init() { printf 'init\n' >> "$PROGRESS"; }
merv_action_progress_fail() { printf 'fail:%s\n' "$1" >> "$PROGRESS"; }
action_ack_error() { printf 'ack:%s\n' "$1" >> "$ACK"; }
merv_action_lock_enter() {
  MERV_ACTION_LOCK_MODE=self
  MERV_ACTION_LOCK_NONCE=stub-nonce
  MERV_ACTION_LOCK_START=1
  return 0
}
merv_action_lock_leave() { printf '%s\n' "$1" >> "$RELEASES"; return 0; }
merv_action_lock_export_child_context() { return 1; }
merv_action_lock_clear_child_context() { return 0; }
merv_mutation_admit_action() { return 0; }
merv_continuation_publish_pending() {
  MERV_CONTINUATION_TOKEN=dispatch-test
  MERV_CONTINUATION_STATE=pending
  export MERV_CONTINUATION_TOKEN
  return 0
}
merv_continuation_path() { printf '%s/fake-lease\n' "$MERV_BASE"; }
merv_continuation_read() { return 0; }
merv_continuation_bind_child() { MERV_CONTINUATION_STATE=active; return 0; }
merv_continuation_retire() { return 0; }
merv_continuation_cancel_pending() { return 0; }

dispatch_if_executable "$WORKER"
_dispatch_rc=$?
[ "$_dispatch_rc" -ne 0 ] || exit 1
[ ! -e "$MARKER" ] || exit 1
[ -s "$PROGRESS" ] || exit 1
[ -s "$ACK" ] || exit 1
[ "$(wc -l < "$RELEASES" 2>/dev/null)" -eq 2 ] || exit 1

# A normal dispatched worker must use the identity API loaded by
# lib_action_lock, rather than the unavailable lib_mervqt compatibility
# wrappers.  This is the same path a router service-event invocation takes.
merv_action_lock_export_child_context() { return 0; }
merv_identity_proc_start() { printf '1\n'; }
merv_identity_matches() { return 0; }
dispatch_if_executable "$WORKER"
_dispatch_rc=$?
[ "$_dispatch_rc" -eq 0 ] || exit 1
[ -e "$MARKER" ] || exit 1
[ "$(wc -l < "$RELEASES" 2>/dev/null)" -eq 4 ] || exit 1

# Exercise the real dispatcher, owner locks, mutation-admission library, and
# continuation primitive together. The earlier cases keep their narrow stubs
# to isolate child-context export failure; this case reaches the real bind,
# child activation, second admission, worker exec, and parent retirement path.
mkdir -p "$LOCKDIR" "$TEST_ROOT/state" "$TEST_ROOT/functions" || exit 1
chmod 700 "$LOCKDIR" "$TEST_ROOT/state" "$TEST_ROOT/functions" || exit 1
MERV_BASE=$BASE_DIR
MERV_STATE_ROOT="$TEST_ROOT/state"
MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
MERVLAN_MAINTENANCE_LOCK_OVERRIDE="$LOCKDIR/mervlan_maintenance.lock"
MERV_FULL_FENCE_PATH="$TEST_ROOT/full.lock"
MERV_CONTINUATION_ROOT="$TEST_ROOT/continuations"
MERV_OWNER_LOCK_PROC_ROOT=/proc
MERV_ACTION_LOCK_PROC_ROOT=/proc
MERV_ACTION_LOCK_PATH="$LOCKDIR/mervlan_action.lock"
export MERV_BASE MERV_STATE_ROOT MERV_UPDATE_JOURNAL MERV_UPDATE_QUIESCE_FILE
export MERVLAN_MAINTENANCE_LOCK_OVERRIDE MERV_FULL_FENCE_PATH
export MERV_CONTINUATION_ROOT MERV_OWNER_LOCK_PROC_ROOT MERV_ACTION_LOCK_PROC_ROOT
export MERV_ACTION_LOCK_PATH

. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_action_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mutation_admission.sh" || exit 1
merv_action_lock_clear_child_context

REAL_WORKER="$TEST_ROOT/functions/mervlan_boot.sh"
REAL_MARKER="$TEST_ROOT/real-continuation-worker"
cat > "$REAL_WORKER" <<'EOF'
#!/bin/sh
set -eu
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 91
. "$MERV_BASE/settings/lib_continuation.sh" || exit 92
_real_start=$(merv_identity_current_start /proc) || exit 93
_real_lease=$(merv_continuation_path "${MERV_CONTINUATION_TOKEN:-}") || exit 94
merv_continuation_read "$_real_lease" || exit 95
[ "$MERV_CONTINUATION_STATE" = active ] &&
  [ "$MERV_CONTINUATION_CHILD_PID" = "$$" ] &&
  [ "$MERV_CONTINUATION_CHILD_START" = "$_real_start" ] || exit 96
printf 'pid=%s\nstart=%s\n' "$$" "$_real_start" > "$MERV_DISPATCH_REAL_MARKER" || exit 97
EOF
chmod 700 "$REAL_WORKER" || exit 1
export MERV_DISPATCH_REAL_MARKER="$REAL_MARKER"
RAW=checkservice_vlanmgr
TYPE=checkservice
EVENT=vlanmgr
MERV_PROGRESS_TOKEN=
export RAW TYPE EVENT MERV_PROGRESS_TOKEN
dispatch_if_executable "$REAL_WORKER" status
_real_dispatch_rc=$?
[ "$_real_dispatch_rc" -eq 0 ] || exit 1
[ -s "$REAL_MARKER" ] || exit 1

set -- "$MERV_CONTINUATION_ROOT"/*/lease
[ -f "$1" ] || exit 1
[ "$#" -eq 1 ] || exit 1
merv_continuation_read "$1" || exit 1
[ "$MERV_CONTINUATION_STATE" = terminal ] || exit 1
_real_worker_pid=$(sed -n 's/^pid=//p' "$REAL_MARKER")
_real_worker_start=$(sed -n 's/^start=//p' "$REAL_MARKER")
[ "$MERV_CONTINUATION_CHILD_PID" = "$_real_worker_pid" ] || exit 1
[ "$MERV_CONTINUATION_CHILD_START" = "$_real_worker_start" ] || exit 1
printf 'PASS: dispatcher used the real continuation lease through worker terminal state\n'
printf 'DISPATCHER_CONTEXT_EXPORT_CONTRACT_OK\n'
