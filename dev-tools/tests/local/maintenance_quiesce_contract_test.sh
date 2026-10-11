#!/bin/sh
# Read-only Q classification: authoritative idle, waitable work, and blockers.

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.quiesce.$$"
umask 077
mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/state" || exit 1
chmod 700 "$TEST_ROOT" "$TEST_ROOT/locks" "$TEST_ROOT/state" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

export MERV_BASE="$BASE_DIR"
. "$BASE_DIR/settings/lib_selftest_context.sh" || fail context-library
merv_selftest_context_create "$TEST_ROOT" || fail context-create
MERV_CONTINUATION_ROOT="$TEST_ROOT/continuations"
MERV_QUIESCE_LOCK_ROOT="$TEST_ROOT/locks"
MERV_QUIESCE_RUNTIME_ROOT="$TEST_ROOT"
MERV_QUIESCE_STATE_ROOT="$TEST_ROOT/state"
MERV_QUIESCE_SETTINGS_RECONCILE="$TEST_ROOT/state/settings_reconcile.state"
MERV_QUIESCE_NODE_RECONCILE="$TEST_ROOT/state/node_reconcile.pending"
MERV_QUIESCE_TRUST_LOCK="$TEST_ROOT/state/ssh_trust/state.lock"
MERV_QUIESCE_DHCP_ROOT="$TEST_ROOT/locks/dhcp_hold"
MERV_QUIESCE_DHCP_LEGACY="$TEST_ROOT/locks/merv_dhcp_hold.active"
MERV_QUIESCE_OBSERVATION="$TEST_ROOT/locks/observation"
MERV_QUIESCE_NODE_JOBS="$TEST_ROOT/node_jobs"
MERV_QUIESCE_NODE_RUNS="$TEST_ROOT/results/node_runs"
MERV_OWNER_LOCK_PROC_ROOT=/proc
export MERV_CONTINUATION_ROOT MERV_QUIESCE_LOCK_ROOT MERV_QUIESCE_RUNTIME_ROOT
export MERV_QUIESCE_STATE_ROOT MERV_QUIESCE_SETTINGS_RECONCILE MERV_QUIESCE_NODE_RECONCILE
export MERV_QUIESCE_TRUST_LOCK
export MERV_QUIESCE_DHCP_ROOT MERV_QUIESCE_DHCP_LEGACY MERV_QUIESCE_OBSERVATION
export MERV_QUIESCE_NODE_JOBS MERV_QUIESCE_NODE_RUNS MERV_OWNER_LOCK_PROC_ROOT
. "$BASE_DIR/settings/lib_maintenance_quiesce.sh" || fail quiesce-library

# Host tests have no ASUSWRT ebtables table. Stub only the read-only device
# observation result after loading the production classifier.
merv_dhcp_hold_required() { return 1; }
merv_dhcp_hold_rules_absent() { return 0; }
merv_full_fence_classify() { printf '%s' absent; }

[ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail empty-runtime-idle
pass 'empty authoritative inventory is idle'

LOCK="$TEST_ROOT/locks/mervlan_manager.lock"
merv_owner_lock_acquire "$LOCK" 0 0 q-test || fail owner-acquire
LOCK_NONCE=$MERV_LOCK_NONCE
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail live-owner-busy
merv_owner_lock_release "$LOCK" "$LOCK_NONCE" || fail owner-release
[ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail released-owner-idle
pass 'live owner is waitable and released owner is idle'

# Generic owner reclamation retains the exact dead lock in a sibling
# .dead.* directory. Q must authenticate known tombstones in each owned
# namespace rather than mistake them for unknown runtime state.
cat > "$TEST_ROOT/hold_owner.sh" <<'EOF'
#!/bin/sh
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 1
merv_owner_lock_acquire "$TOMB_LOCK" 0 0 q-tomb-owner || exit 2
: > "$TOMB_READY"
while :; do sleep 1; done
EOF
chmod 700 "$TEST_ROOT/hold_owner.sh" || fail tomb-holder-mode
assert_dead_tomb_idle() {
  TOMB_LOCK=$1
  TOMB_READY="$TEST_ROOT/tomb.$2.ready"
  export TOMB_LOCK TOMB_READY
  sh "$TEST_ROOT/hold_owner.sh" &
  TOMB_PID=$!
  _tomb_tries=0
  while [ ! -f "$TOMB_READY" ] && [ "$_tomb_tries" -lt 10 ]; do
    sleep 1
    _tomb_tries=$((_tomb_tries + 1))
  done
  [ -f "$TOMB_READY" ] || fail "$2-tomb-owner-start"
  kill -KILL "$TOMB_PID" 2>/dev/null || fail "$2-tomb-owner-kill"
  wait "$TOMB_PID" 2>/dev/null || :
  merv_owner_lock_acquire "$TOMB_LOCK" 0 0 q-tomb-reclaim || fail "$2-tomb-owner-reclaim"
  TOMB_REPLACEMENT_NONCE=$MERV_LOCK_NONCE
  merv_owner_lock_release "$TOMB_LOCK" "$TOMB_REPLACEMENT_NONCE" || fail "$2-tomb-owner-release"
  _tomb_seen=0
  for _tomb_path in "${TOMB_LOCK%/*}"/."${TOMB_LOCK##*/}".dead.*; do
    [ -d "$_tomb_path" ] && _tomb_seen=1
  done
  [ "$_tomb_seen" = 1 ] || fail "$2-dead-owner-tomb-missing"
  [ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail "$2-authenticated-dead-owner-tomb-not-idle"
  rm -f "$TOMB_READY"
}
assert_dead_tomb_idle "$TEST_ROOT/locks/mervlan_action.lock" action
pass 'Q recognizes authenticated dead owner quarantine while preserving unknown-name blocking'

mkdir -p "${MERV_QUIESCE_TRUST_LOCK%/*}" || fail trust-lock-parent
merv_owner_lock_acquire "$MERV_QUIESCE_TRUST_LOCK" 0 0 q-trust-test || fail trust-owner-acquire
TRUST_LOCK_NONCE=$MERV_LOCK_NONCE
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail trust-owner-busy
merv_owner_lock_release "$MERV_QUIESCE_TRUST_LOCK" "$TRUST_LOCK_NONCE" || fail trust-owner-release
[ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail trust-owner-idle
pass 'persistent SSH trust mutation owner is included in Q'

mkdir "$MERV_QUIESCE_TRUST_LOCK" || fail trust-malformed-lock-dir
printf '%s\n' bad > "$MERV_QUIESCE_TRUST_LOCK/owner"
chmod 600 "$MERV_QUIESCE_TRUST_LOCK/owner"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail trust-malformed-owner-blocks
rm -rf "$MERV_QUIESCE_TRUST_LOCK"

mkdir "$LOCK" || fail malformed-lock-dir
printf '%s\n' bad > "$LOCK/owner"
chmod 600 "$LOCK/owner"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail malformed-owner-blocks
rm -rf "$LOCK"

: > "$TEST_ROOT/locks/unclassified.state"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail unknown-runtime-blocks
rm -f "$TEST_ROOT/locks/unclassified.state"
pass 'malformed owners and unknown runtime names fail closed'

mkdir -p "$TEST_ROOT/locks/observation"
printf '%s\n' 'snapshot_requested_generation=2' 'snapshot_completed_generation=1' \
  'collection_requested_generation=0' 'collection_completed_generation=0' \
  > "$TEST_ROOT/locks/observation/request.state"
chmod 600 "$TEST_ROOT/locks/observation/request.state"
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail pending-generation-busy
printf '%s\n' 'snapshot_requested_generation=bad' 'snapshot_completed_generation=1' \
  'collection_requested_generation=0' 'collection_completed_generation=0' \
  > "$TEST_ROOT/locks/observation/request.state"
chmod 600 "$TEST_ROOT/locks/observation/request.state"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail malformed-generation-blocks
rm -rf "$TEST_ROOT/locks/observation"
pass 'pending observation generation is busy and malformed generation blocks'

mkdir -p "$MERV_QUIESCE_OBSERVATION" || fail observation-owner-root
merv_owner_lock_acquire "$MERV_QUIESCE_OBSERVATION/worker.lock" 0 0 q-observation-worker ||
  fail observation-worker-owner-acquire
OBS_WORKER_NONCE=$MERV_LOCK_NONCE
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail observation-worker-owner-busy
merv_owner_lock_release "$MERV_QUIESCE_OBSERVATION/worker.lock" "$OBS_WORKER_NONCE" ||
  fail observation-worker-owner-release
[ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail observation-worker-owner-idle
pass 'Q observes a live canonical observation worker owner'
assert_dead_tomb_idle "$MERV_QUIESCE_OBSERVATION/request.lock" observation
pass 'Q recognizes authenticated observation owner quarantine'

mkdir -p "$MERV_QUIESCE_DHCP_ROOT" || fail dhcp-state-root
pass 'DHCP dedicated state-lock schema is covered by quiesce_product_inventory_test'

: > "$TEST_ROOT/locks/merv_dhcp_hold.active"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail dhcp-legacy-blocks
rm -f "$TEST_ROOT/locks/merv_dhcp_hold.active"
mkdir -p "$TEST_ROOT/locks/dhcp_hold/failsafe/stale"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail dhcp-failsafe-blocks
rm -rf "$TEST_ROOT/locks/dhcp_hold"
pass 'DHCP Hold markers and failsafe state block'

mkdir -p "$TEST_ROOT/node_jobs/client.123/node_1"
: > "$TEST_ROOT/node_jobs/client.123/node_1/wrapper.pid"
: > "$TEST_ROOT/node_jobs/client.123/node_1/wrapper.proc_start_time"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail incomplete-node-job-blocks
rm -rf "$TEST_ROOT/node_jobs"
pass 'incomplete node-job publication blocks'

# A pending detached-run publication is visible before spawn and remains
# non-idle if its publisher disappears. Binding a direct child identity does
# not make pending safe; only a started/terminal transition may do so.
_run_dir="$MERV_QUIESCE_NODE_RUNS/77-1"
mkdir -p "$_run_dir" || fail node-run-root
_parent_start=$(merv_identity_current_start /proc 2>/dev/null) || fail node-run-parent-start
cat > "$_run_dir/node_1.pending" <<EOF
format_version=1
run_id=77-1
node_id=1
state=pending
parent_pid=$$
parent_proc_start_time=$_parent_start
parent_nonce=pending-test-nonce
runner_pid=none
runner_proc_start_time=none
EOF
chmod 600 "$_run_dir/node_1.pending" || fail node-run-pending-mode
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail node-run-pending-busy
sleep 30 &
_run_child=$!
_run_child_start=$(merv_identity_proc_start "$_run_child" /proc 2>/dev/null) || fail node-run-child-start
sed "s/runner_pid=none/runner_pid=$_run_child/;s/runner_proc_start_time=none/runner_proc_start_time=$_run_child_start/" \
  "$_run_dir/node_1.pending" > "$_run_dir/pending.tmp" || fail node-run-pending-bind
chmod 600 "$_run_dir/pending.tmp" || fail node-run-pending-bind-mode
mv "$_run_dir/pending.tmp" "$_run_dir/node_1.pending" || fail node-run-pending-bind-publish
kill -KILL "$_run_child" 2>/dev/null || :
wait "$_run_child" 2>/dev/null || :
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail node-run-pending-child-dead-still-busy
printf '%s\n' 'duplicate=field' >> "$_run_dir/node_1.pending"
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail node-run-pending-malformed-blocks
rm -f "$_run_dir/node_1.pending"
cat > "$_run_dir/node_1.status" <<EOF
format_version=1
run_id=77-1
node_id=1
state=started
pid=$_run_child
proc_start_time=$_run_child_start
started_epoch=1
completed_epoch=0
exit_code=
reason=started
EOF
chmod 600 "$_run_dir/node_1.status" || fail node-run-status-mode
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail node-run-dead-started-blocks
sed -i 's/state=started/state=complete/;s/completed_epoch=0/completed_epoch=2/;s/exit_code=/exit_code=0/;s/reason=started/reason=complete/' \
  "$_run_dir/node_1.status" || fail node-run-terminal-write
[ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail node-run-dead-terminal-idle
rm -rf "$MERV_QUIESCE_NODE_RUNS"
pass 'node-run pending survives parent/child ambiguity and terminal requires dead identity'

sh "$TEST_DIR/maintenance_quiesce_recursive_fixture.sh" || fail recursive-producer-contract

printf '%s\n' 'MAINTENANCE_QUIESCE_CONTRACT_OK'
