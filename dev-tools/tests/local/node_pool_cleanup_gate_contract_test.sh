#!/bin/sh
# Direct lifecycle contract for Execute/Sync cleanup ownership gates.
# This is a local-only harness: no router, SSH, or node action is contacted.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-node-pool-cleanup-gate.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
TMPDIR="$TEST_ROOT"
export TMPDIR
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got '$2', expected '$1')"; }

extract_fn() {
    _ec_name="$1" _ec_source="$2" _ec_dest="$3"
    awk -v name="$_ec_name" '
        $0 ~ ("^" name "\\()[[:space:]]*\\{") { active=1; depth=0 }
        active {
            print
            line=$0
            opens=gsub(/\{/, "{", line)
            closes=gsub(/\}/, "}", line)
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$_ec_source" > "$_ec_dest" || return 1
    [ -s "$_ec_dest" ]
}

extract_fn mnj_pool_state_unresolved "$BASE_DIR/settings/lib_node_jobs.sh" "$TEST_ROOT/mnj.sh" || fail 'extract pool state helper'
extract_fn execute_nodes_pool_state_unresolved "$BASE_DIR/functions/execute_nodes.sh" "$TEST_ROOT/execute-state.sh" || fail 'extract Execute state helper'
extract_fn execute_nodes_reconcile_signal_children "$BASE_DIR/functions/execute_nodes.sh" "$TEST_ROOT/execute-signal.sh" || fail 'extract Execute signal cleanup'
extract_fn execute_nodes_progress_cleanup "$BASE_DIR/functions/execute_nodes.sh" "$TEST_ROOT/execute-cleanup.sh" || fail 'extract Execute cleanup'
extract_fn sync_pool_state_unresolved "$BASE_DIR/functions/sync_nodes.sh" "$TEST_ROOT/sync-state.sh" || fail 'extract Sync state helper'
extract_fn _cleanup_sync_tmp "$BASE_DIR/functions/sync_nodes.sh" "$TEST_ROOT/sync-cleanup.sh" || fail 'extract Sync cleanup'
. "$TEST_ROOT/mnj.sh" || fail 'load pool state helper'
. "$TEST_ROOT/execute-state.sh" || fail 'load Execute state helper'
. "$TEST_ROOT/execute-signal.sh" || fail 'load Execute signal cleanup'
. "$TEST_ROOT/execute-cleanup.sh" || fail 'load Execute cleanup'
. "$TEST_ROOT/sync-state.sh" || fail 'load Sync state helper'
. "$TEST_ROOT/sync-cleanup.sh" || fail 'load Sync cleanup'

error() { :; }
merv_action_progress_complete() { :; }
merv_action_progress_fail() { :; }
execute_nodes_cancel_detached_nodes() { :; }
merv_action_runtime_finish() { EXEC_RUNTIME_RELEASES=$((EXEC_RUNTIME_RELEASES + 1)); return 0; }
merv_owner_lock_release() { OWNER_RELEASES=$((OWNER_RELEASES + 1)); return 0; }
merv_action_lock_leave() { ACTION_RELEASES=$((ACTION_RELEASES + 1)); return 0; }
sync_settings_reconcile_finish() { :; }
mnj_pool_abort_active() {
    ABORT_CALLS=$((ABORT_CALLS + 1))
    if [ "${ABORT_RESULT:-1}" -eq 0 ]; then
        MNJ_POOL_ACTIVE=0
        MNJ_POOL_PENDING_PID=''; MNJ_POOL_PENDING_START=''; MNJ_POOL_PENDING_DIR=''; MNJ_POOL_PENDING_NODE=''
        MNJ_S1_PID=''; MNJ_S1_START=''; MNJ_S1_DIR=''; MNJ_S1_NODE=''; MNJ_S1_DEADLINE=''
    fi
    return "${ABORT_RESULT:-1}"
}

reset_state() {
    MNJ_POOL_ACTIVE=0
    MNJ_POOL_PENDING_PID=''; MNJ_POOL_PENDING_START=''; MNJ_POOL_PENDING_DIR=''; MNJ_POOL_PENDING_NODE=''
    MNJ_S1_PID=''; MNJ_S1_START=''; MNJ_S1_DIR=''; MNJ_S1_NODE=''; MNJ_S1_DEADLINE=''
    MNJ_S2_PID=''; MNJ_S2_START=''; MNJ_S2_DIR=''; MNJ_S2_NODE=''; MNJ_S2_DEADLINE=''
    MNJ_S3_PID=''; MNJ_S3_START=''; MNJ_S3_DIR=''; MNJ_S3_NODE=''; MNJ_S3_DEADLINE=''
    MNJ_S4_PID=''; MNJ_S4_START=''; MNJ_S4_DIR=''; MNJ_S4_NODE=''; MNJ_S4_DEADLINE=''
    MNJ_S5_PID=''; MNJ_S5_START=''; MNJ_S5_DIR=''; MNJ_S5_NODE=''; MNJ_S5_DEADLINE=''
    ABORT_CALLS=0; ABORT_RESULT=1; EXEC_RUNTIME_RELEASES=0; OWNER_RELEASES=0; ACTION_RELEASES=0
}

run_execute() {
    EXEC_RUNTIME_OWNED=1; EXEC_NODES_LOCK_ACQUIRED=1; EXEC_ACTION_LOCK_ACQUIRED=1
    EXEC_NODES_LOCK="$TEST_ROOT/execute.lock"
    _exec_action_lock_path="$TEST_ROOT/action.lock"; _exec_action_lock_nonce=nonce; _exec_action_lock_start=1; _exec_action_lock_mode=self
    MODE=nodesonly; MERV_ACTION_PROGRESS_ENABLED=0
    execute_nodes_progress_cleanup
}

run_sync() {
    SYNC_LOCK_ACQUIRED=1; SYNC_ACTION_LOCK_ACQUIRED=1
    SYNC_LOCK="$TEST_ROOT/sync.lock"
    _sync_action_lock_path="$TEST_ROOT/action.lock"; _sync_action_lock_nonce=nonce; _sync_action_lock_start=1; _sync_action_lock_mode=self
    _sync_endpoint_map=''; SYNC_DEFERRED=0; MERV_ACTION_PROGRESS_ENABLED=0
    _cleanup_sync_tmp
}

run_execute_signal() {
    execute_nodes_reconcile_signal_children
}

reset_state; run_execute
assert_eq 0 "$ABORT_CALLS" 'Execute clean state does not abort'
assert_eq 1 "$EXEC_RUNTIME_RELEASES" 'Execute clean state releases runtime marker'
assert_eq 1 "$OWNER_RELEASES" 'Execute clean state releases owner lock'
assert_eq 1 "$ACTION_RELEASES" 'Execute clean state releases action lock'
pass 'Execute clean state releases ownership'

reset_state; MNJ_POOL_ACTIVE=1; ABORT_RESULT=0; run_execute
assert_eq 1 "$ABORT_CALLS" 'Execute normal active pool attempts reconciliation'
assert_eq 1 "$EXEC_RUNTIME_RELEASES" 'Execute normal active pool releases runtime marker after reconciliation'
assert_eq 1 "$OWNER_RELEASES" 'Execute normal active pool releases owner lock after reconciliation'
assert_eq 1 "$ACTION_RELEASES" 'Execute normal active pool releases action lock after reconciliation'
pass 'Execute normal active pool releases ownership after reconciliation'

reset_state; MNJ_POOL_PENDING_NODE=1; run_execute || :
assert_eq 1 "$ABORT_CALLS" 'Execute zero+pending attempts reconciliation'
assert_eq 0 "$OWNER_RELEASES" 'Execute zero+pending retains owner lock'
assert_eq 0 "$ACTION_RELEASES" 'Execute zero+pending retains action lock'
pass 'Execute zero+pending retains ownership'

reset_state; MNJ_S1_DEADLINE=123; run_execute || :
assert_eq 1 "$ABORT_CALLS" 'Execute zero+slot attempts reconciliation'
assert_eq 0 "$OWNER_RELEASES" 'Execute zero+slot retains owner lock'
assert_eq 0 "$ACTION_RELEASES" 'Execute zero+slot retains action lock'
pass 'Execute zero+slot retains ownership'

reset_state; MNJ_POOL_ACTIVE=malformed; run_execute || :
assert_eq 1 "$ABORT_CALLS" 'Execute malformed active attempts reconciliation'
assert_eq 0 "$EXEC_RUNTIME_RELEASES" 'Execute malformed active retains runtime marker'
assert_eq 0 "$OWNER_RELEASES" 'Execute malformed active retains owner lock'
assert_eq 0 "$ACTION_RELEASES" 'Execute malformed active retains action lock'
pass 'Execute malformed active retains ownership'

reset_state; MNJ_POOL_ACTIVE=1; MNJ_POOL_PENDING_DIR="$TEST_ROOT/pending"; run_sync || :
assert_eq 1 "$ABORT_CALLS" 'Sync active+pending attempts reconciliation'
assert_eq 0 "$OWNER_RELEASES" 'Sync active+pending retains owner lock'
assert_eq 0 "$ACTION_RELEASES" 'Sync active+pending retains action lock'
pass 'Sync active+pending retains ownership'

reset_state; MNJ_POOL_PENDING_NODE=1; MNJ_POOL_PENDING_DIR="$TEST_ROOT/sync-pending"; mkdir -p "$MNJ_POOL_PENDING_DIR"; run_sync || :
assert_eq 1 "$ABORT_CALLS" 'Sync zero+pending attempts reconciliation'
assert_eq 0 "$OWNER_RELEASES" 'Sync zero+pending retains owner lock'
assert_eq 0 "$ACTION_RELEASES" 'Sync zero+pending retains action lock'
[ -d "$MNJ_POOL_PENDING_DIR" ] || fail 'Sync zero+pending removed private worker-job state'
pass 'Sync zero+pending retains ownership and private worker-job state'

reset_state; MNJ_S1_DEADLINE=123; MNJ_S1_DIR="$TEST_ROOT/sync-slot"; mkdir -p "$MNJ_S1_DIR"; run_sync || :
assert_eq 1 "$ABORT_CALLS" 'Sync zero+slot attempts reconciliation'
assert_eq 0 "$OWNER_RELEASES" 'Sync zero+slot retains owner lock'
assert_eq 0 "$ACTION_RELEASES" 'Sync zero+slot retains action lock'
[ -d "$MNJ_S1_DIR" ] || fail 'Sync zero+slot removed private worker-job state'
pass 'Sync zero+slot retains ownership and private worker-job state'

reset_state; MNJ_POOL_ACTIVE=malformed; run_sync || :
assert_eq 1 "$ABORT_CALLS" 'Sync malformed active attempts reconciliation'
assert_eq 0 "$OWNER_RELEASES" 'Sync malformed active retains owner lock'
assert_eq 0 "$ACTION_RELEASES" 'Sync malformed active retains action lock'
pass 'Sync malformed active retains ownership'

reset_state; ABORT_RESULT=0; MNJ_POOL_PENDING_NODE=1; run_execute
assert_eq 1 "$ABORT_CALLS" 'resolved abort is attempted once'
assert_eq 1 "$OWNER_RELEASES" 'resolved abort releases owner lock'
assert_eq 1 "$ACTION_RELEASES" 'resolved abort releases action lock'
pass 'successful reconciliation releases ownership'

reset_state; run_execute_signal
assert_eq 0 "$ABORT_CALLS" 'Execute signal clean state does not abort'
reset_state; MNJ_POOL_ACTIVE=1; run_execute_signal || :
assert_eq 1 "$ABORT_CALLS" 'Execute signal normal active pool attempts reconciliation'
reset_state; MNJ_POOL_PENDING_NODE=1; run_execute_signal || :
assert_eq 1 "$ABORT_CALLS" 'Execute signal zero+pending attempts reconciliation'
reset_state; MNJ_S1_DEADLINE=123; run_execute_signal || :
assert_eq 1 "$ABORT_CALLS" 'Execute signal zero+slot attempts reconciliation'
reset_state; MNJ_POOL_ACTIVE=malformed; run_execute_signal || :
assert_eq 1 "$ABORT_CALLS" 'Execute signal malformed active attempts reconciliation'
pass 'Execute signal path uses the same unresolved-state contract'

printf 'NODE_POOL_CLEANUP_GATE_CONTRACT_OK\n'
