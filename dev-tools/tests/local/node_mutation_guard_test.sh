#!/bin/sh
# Target-side action-R/admission coverage for Sync Nodes and Execute Nodes.

set -u
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.node-mutation.$$"
M_TEST_LOCK="$TEST_ROOT/locks/mervlan_maintenance.lock"
F_TEST_LOCK="$TEST_ROOT/full.lock"
ACTION_TEST_LOCK="$TEST_ROOT/locks/mervlan_action.lock"
umask 077
mkdir -p /tmp/mervlan_tmp "$TEST_ROOT/locks" "$TEST_ROOT/state/ssh_trust" \
  "$TEST_ROOT/continuations" "$TEST_ROOT/runtime/node_jobs" \
  "$TEST_ROOT/node_runs" "$TEST_ROOT/nodefs/mervlan/settings" || exit 1
chmod 700 "$TEST_ROOT" "$TEST_ROOT/locks" "$TEST_ROOT/state" \
  "$TEST_ROOT/state/ssh_trust" "$TEST_ROOT/continuations" \
  "$TEST_ROOT/runtime" "$TEST_ROOT/runtime/node_jobs" \
  "$TEST_ROOT/node_runs" "$TEST_ROOT/nodefs" \
  "$TEST_ROOT/nodefs/mervlan" "$TEST_ROOT/nodefs/mervlan/settings" || exit 1
cp -R "$BASE_DIR/settings/." "$TEST_ROOT/nodefs/mervlan/settings/" || exit 1
printf '%s\n' '{"IS_NODE":0,"NODE_ID":"none"}' \
  > "$TEST_ROOT/nodefs/mervlan/settings/settings.json" || exit 1
chmod 600 "$TEST_ROOT/nodefs/mervlan/settings/settings.json" || exit 1

_release_file=
_worker_pid=
_m_nonce=
_f_nonce=
cleanup() {
  [ -z "$_release_file" ] || : > "$_release_file" 2>/dev/null || :
  [ -z "$_worker_pid" ] || kill "$_worker_pid" 2>/dev/null || :
  [ -z "$_worker_pid" ] || wait "$_worker_pid" 2>/dev/null || :
  [ -z "$_f_nonce" ] || merv_full_fence_release "$F_TEST_LOCK" "$$" \
    "$_f_start" "$_f_nonce" >/dev/null 2>&1 || :
  [ -z "$_m_nonce" ] || merv_owner_lock_release "$M_TEST_LOCK" \
    "$_m_nonce" >/dev/null 2>&1 || :
  rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || exit 1
. "$BASE_DIR/settings/lib_selftest_context.sh" || exit 1
merv_selftest_context_create "$TEST_ROOT" || exit 1
MERVLAN_SELFTEST_CONTEXT=$MERVLAN_SELFTEST_CONTEXT
export MERVLAN_SELFTEST_CONTEXT
MERV_BASE=$BASE_DIR
export MERV_BASE
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_action_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_update_state.sh" || exit 1
. "$BASE_DIR/settings/lib_full_fence.sh" || exit 1
. "$BASE_DIR/settings/lib_continuation.sh" || exit 1
. "$BASE_DIR/settings/var_settings.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
. "$BASE_DIR/settings/lib_maintenance_quiesce.sh" || exit 1

MERV_ACTION_LOCK_PATH=$ACTION_TEST_LOCK
MERV_ACTION_LOCK_PROC_ROOT=/proc
MERV_OWNER_LOCK_PROC_ROOT=/proc
MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=10
MERVLAN_MAINTENANCE_LOCK_OVERRIDE=$M_TEST_LOCK
MERV_FULL_FENCE_PATH=$F_TEST_LOCK
MERV_CONTINUATION_ROOT=$TEST_ROOT/continuations
MERV_QUIESCE_LOCK_ROOT=$TEST_ROOT/locks
MERV_QUIESCE_RUNTIME_ROOT=$TEST_ROOT/runtime
MERV_QUIESCE_STATE_ROOT=$TEST_ROOT/state
MERV_QUIESCE_SETTINGS_RECONCILE=$TEST_ROOT/state/settings_reconcile.state
MERV_QUIESCE_NODE_RECONCILE=$TEST_ROOT/state/node_reconcile.pending
MERV_QUIESCE_TRUST_LOCK=$TEST_ROOT/state/ssh_trust/state.lock
MERV_QUIESCE_DHCP_ROOT=$TEST_ROOT/locks/dhcp_hold
MERV_QUIESCE_DHCP_LEGACY=$TEST_ROOT/locks/merv_dhcp_hold.active
MERV_QUIESCE_OBSERVATION=$TEST_ROOT/locks/observation
MERV_QUIESCE_NODE_JOBS=$TEST_ROOT/runtime/node_jobs
MERV_QUIESCE_NODE_RUNS=$TEST_ROOT/node_runs
export MERV_ACTION_LOCK_PATH MERV_ACTION_LOCK_PROC_ROOT MERV_OWNER_LOCK_PROC_ROOT
export MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC MERVLAN_MAINTENANCE_LOCK_OVERRIDE
export MERV_FULL_FENCE_PATH MERV_CONTINUATION_ROOT MERV_QUIESCE_LOCK_ROOT
export MERV_QUIESCE_RUNTIME_ROOT MERV_QUIESCE_STATE_ROOT MERV_QUIESCE_SETTINGS_RECONCILE
export MERV_QUIESCE_NODE_RECONCILE MERV_QUIESCE_TRUST_LOCK MERV_QUIESCE_DHCP_ROOT
export MERV_QUIESCE_DHCP_LEGACY MERV_QUIESCE_OBSERVATION MERV_QUIESCE_NODE_JOBS
export MERV_QUIESCE_NODE_RUNS
merv_dhcp_hold_required() { return 1; }
merv_dhcp_hold_rules_absent() { return 0; }

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
run_mutator() {
  MERVLAN_SELFTEST_CONTEXT="$MERVLAN_SELFTEST_CONTEXT" \
    MERV_BASE="$BASE_DIR" sh "$BASE_DIR/functions/mervlan_node_mutate.sh" "$@"
}

_settings="$TEST_ROOT/nodefs/mervlan/settings/settings.json"
_before=$(cat "$_settings") || fail settings-read
merv_full_fence_claim "$F_TEST_LOCK" || fail fence-claim
_output=$(run_mutator execute-node-flags 1 2>&1) || fail 'dispatcher process failed while F active'
case "$_output" in *'NODE_MUTATION_BLOCKED|full-fence-live'*) ;; *) fail "F did not block node mutation: $_output" ;; esac
[ "$(cat "$_settings")" = "$_before" ] || fail 'F-blocked mutation changed node settings'
merv_full_fence_release "$F_TEST_LOCK" || fail fence-release
pass 'target-side F admission blocks before the first settings write'

merv_owner_lock_acquire "$M_TEST_LOCK" 0 0 node-mutation-test || fail maintenance-claim
_m_nonce=$MERV_LOCK_NONCE
_output=$(run_mutator execute-node-flags 1 2>&1) || fail 'dispatcher process failed while M active'
case "$_output" in *'NODE_MUTATION_BLOCKED|maintenance-live'*) ;; *) fail "M did not block node mutation: $_output" ;; esac
[ "$(cat "$_settings")" = "$_before" ] || fail 'M-blocked mutation changed node settings'
merv_owner_lock_release "$M_TEST_LOCK" "$_m_nonce" || fail maintenance-release
_m_nonce=
pass 'target-side M admission blocks before the first settings write'

# Hold a real node action owner mid-mutation, then acquire Full-style M/F.
# Q must see the action R until its synchronous operation exits.
_target="$TEST_ROOT/mutation-target"
_ready="$TEST_ROOT/mutation-ready"
_release_file="$TEST_ROOT/mutation-release"
run_mutator test-pause-write "$_target" "$_ready" "$_release_file" \
  > "$TEST_ROOT/mutator.out" 2>&1 &
_worker_pid=$!
_tries=0
while [ ! -f "$_ready" ] && [ "$_tries" -lt 15 ]; do
  sleep 1
  _tries=$((_tries + 1))
done
[ -f "$_ready" ] || fail 'node action-R worker did not publish mid-mutation state'
merv_owner_lock_acquire "$M_TEST_LOCK" 0 0 node-mutation-race || fail race-maintenance-claim
_m_nonce=$MERV_LOCK_NONCE
_m_start=$MERV_LOCK_START
merv_full_fence_claim "$F_TEST_LOCK" || fail race-fence-claim
_f_nonce=$MERV_FULL_FENCE_NONCE
_f_start=$MERV_FULL_FENCE_START
merv_maintenance_quiesce_classify "$$" "$_m_start" "$_m_nonce" \
  "$$" "$_f_start" "$_f_nonce" >/dev/null
_q=$MERV_QUIESCE_STATUS
[ "$_q" = BUSY ] || fail "Q did not see an active node-local action owner: $_q"
case "$MERV_QUIESCE_REASON" in owner-mervlan_action.lock-active) ;; *) fail "unexpected Q reason: $MERV_QUIESCE_REASON" ;; esac
: > "$_release_file" || fail mutation-release
wait "$_worker_pid" || fail 'node mutator failed after its owner-held operation'
_worker_pid=
grep -Fqx 'NODE_MUTATION_TEST_DONE' "$_target" || fail 'protected mutation did not finish'
merv_maintenance_quiesce_classify "$$" "$_m_start" "$_m_nonce" \
  "$$" "$_f_start" "$_f_nonce" >/dev/null
_q=$MERV_QUIESCE_STATUS
[ "$_q" = IDLE ] || fail "Q did not become idle after node-local R release: $_q/$MERV_QUIESCE_REASON"
merv_full_fence_release "$F_TEST_LOCK" "$$" "$_f_start" "$_f_nonce" || fail race-fence-release
_f_nonce=
merv_owner_lock_release "$M_TEST_LOCK" "$_m_nonce" || fail race-maintenance-release
_m_nonce=
_release_file=
pass 'real node R/F race remains Q-busy until synchronous mutation and R finish'

# The SSH adapter admits only fixed operations and safely quotes its embedded
# helper.  This source-side check does not claim to validate router transport.
. "$BASE_DIR/settings/lib_ssh.sh" || fail ssh-library-load
_remote=$(merv_ssh_node_mutate_command execute-node-flags 1) || fail remote-command-build
printf '%s\n' "$_remote" | sh -n || fail remote-command-syntax
case "$_remote" in *'mervlan_node_mutate_remote'*'execute-node-flags'*) ;; *) fail remote-command-shape ;; esac
if merv_ssh_node_mutate_command put-stage-file 1-2 1 'file;touch /tmp/untrusted' >/dev/null 2>&1; then
  fail 'remote mutation protocol accepted shell syntax in a path'
fi
pass 'SSH mutation protocol is closed and generated remote command parses'

printf '%s\n' 'NODE_MUTATION_GUARD_OK'
