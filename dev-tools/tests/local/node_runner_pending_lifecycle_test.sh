#!/bin/sh
# Real local process race for the node runner's target-side action owner.

set -u
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.node-runner-life.$$"
umask 077
mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/state/ssh_trust" \
  "$TEST_ROOT/continuations" "$TEST_ROOT/node_runs" "$TEST_ROOT/runtime/node_jobs" || exit 1
chmod 700 "$TEST_ROOT" "$TEST_ROOT/locks" "$TEST_ROOT/state" \
  "$TEST_ROOT/state/ssh_trust" "$TEST_ROOT/continuations" \
  "$TEST_ROOT/node_runs" "$TEST_ROOT/runtime" "$TEST_ROOT/runtime/node_jobs" || exit 1
M_TEST_LOCK="$TEST_ROOT/locks/mervlan_maintenance.lock"
F_TEST_LOCK="$TEST_ROOT/full.lock"
trap 'test -n "${_release_marker:-}" && : > "$_release_marker" 2>/dev/null || :; test -n "${_pending_child:-}" && kill "$_pending_child" 2>/dev/null || :; test -n "${_pending_child:-}" && wait "$_pending_child" 2>/dev/null || :; test -n "${_live_manager:-}" && kill "$_live_manager" 2>/dev/null || :; test -n "${_live_manager:-}" && wait "$_live_manager" 2>/dev/null || :; test -n "${_lifecycle_runner:-}" && kill -TERM "$_lifecycle_runner" 2>/dev/null || :; test -n "${_lifecycle_runner:-}" && wait "$_lifecycle_runner" 2>/dev/null || :; test -n "${_fence_nonce:-}" && merv_full_fence_release "$F_TEST_LOCK" "$$" "$_fence_start" "$_fence_nonce" >/dev/null 2>&1 || :; test -n "${_maintenance_nonce:-}" && merv_owner_lock_release "$M_TEST_LOCK" "$_maintenance_nonce" >/dev/null 2>&1 || :; rm -rf "$TEST_ROOT"' 0 1 2 3 15

. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || exit 1
. "$BASE_DIR/settings/lib_selftest_context.sh" || exit 1
merv_selftest_context_create "$TEST_ROOT" || exit 1
mkdir -m 700 "$TEST_ROOT/bin" || exit 1
cat > "$TEST_ROOT/bin/ebtables" <<'EOF'
#!/bin/sh
# The runner subprocess uses the real rule classifier. Model a clear ruleset
# with a fake, read-only backend; never inspect or mutate host ebtables.
case "${3:-}:${4:-}" in
  -L:MERV_DHCP_HOLD) exit 1 ;;
  -L:FORWARD|-L:INPUT) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/ebtables" || exit 1
PATH="$TEST_ROOT/bin:$PATH"
MERV_DHCP_HOLD_CHAIN=MERV_DHCP_HOLD
export PATH MERV_DHCP_HOLD_CHAIN
MERV_BASE=$BASE_DIR
export MERV_BASE MERVLAN_SELFTEST_CONTEXT
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_action_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_update_state.sh" || exit 1
. "$BASE_DIR/settings/lib_full_fence.sh" || exit 1
. "$BASE_DIR/settings/lib_continuation.sh" || exit 1
. "$BASE_DIR/settings/var_settings.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1

MERV_ACTION_LOCK_PATH="$TEST_ROOT/locks/mervlan_action.lock"
MERV_ACTION_LOCK_PROC_ROOT=/proc
MERV_OWNER_LOCK_PROC_ROOT=/proc
MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=10
MERV_NODE_STATUS_ROOT="$TEST_ROOT/node_runs"
MERV_CONTINUATION_ROOT="$TEST_ROOT/continuations"
MERVLAN_MAINTENANCE_LOCK_OVERRIDE=$M_TEST_LOCK
MERV_FULL_FENCE_PATH=$F_TEST_LOCK
MERV_NODE_RUNNER_MANAGER="$TEST_ROOT/manager.sh"
MNR_TEST_MARKER="$TEST_ROOT/manager"
MERV_QUIESCE_LOCK_ROOT="$TEST_ROOT/locks"
MERV_QUIESCE_RUNTIME_ROOT="$TEST_ROOT/runtime"
MERV_QUIESCE_STATE_ROOT="$TEST_ROOT/state"
MERV_QUIESCE_SETTINGS_RECONCILE="$TEST_ROOT/state/settings_reconcile.state"
MERV_QUIESCE_NODE_RECONCILE="$TEST_ROOT/state/node_reconcile.pending"
MERV_QUIESCE_TRUST_LOCK="$TEST_ROOT/state/ssh_trust/state.lock"
MERV_QUIESCE_DHCP_ROOT="$TEST_ROOT/locks/dhcp_hold"
MERV_QUIESCE_DHCP_LEGACY="$TEST_ROOT/locks/merv_dhcp_hold.active"
MERV_QUIESCE_OBSERVATION="$TEST_ROOT/locks/observation"
MERV_QUIESCE_NODE_JOBS="$TEST_ROOT/runtime/node_jobs"
MERV_QUIESCE_NODE_RUNS="$MERV_NODE_STATUS_ROOT"
export MERV_ACTION_LOCK_PATH MERV_ACTION_LOCK_PROC_ROOT MERV_OWNER_LOCK_PROC_ROOT
export MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC MERV_NODE_STATUS_ROOT MERV_CONTINUATION_ROOT
export MERVLAN_MAINTENANCE_LOCK_OVERRIDE MERV_FULL_FENCE_PATH MERV_NODE_RUNNER_MANAGER MNR_TEST_MARKER
export MERV_QUIESCE_LOCK_ROOT MERV_QUIESCE_RUNTIME_ROOT MERV_QUIESCE_STATE_ROOT
export MERV_QUIESCE_SETTINGS_RECONCILE MERV_QUIESCE_NODE_RECONCILE MERV_QUIESCE_TRUST_LOCK
export MERV_QUIESCE_DHCP_ROOT MERV_QUIESCE_DHCP_LEGACY MERV_QUIESCE_OBSERVATION
export MERV_QUIESCE_NODE_JOBS MERV_QUIESCE_NODE_RUNS

. "$BASE_DIR/settings/lib_maintenance_quiesce.sh" || exit 1
merv_dhcp_hold_required() { return 1; }
merv_dhcp_hold_rules_absent() { return 0; }

fail() {
  if [ -f "$TEST_ROOT/start.out" ]; then cat "$TEST_ROOT/start.out" >&2; fi
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
pass() { printf 'PASS: %s\n' "$1"; }

mkdir -p /tmp/mervlan_tmp/locks || fail canonical-lock-root
[ "$(merv_update_maintenance_lock_state)" = absent ] || fail canonical-maintenance-lock-busy
[ "$(merv_full_fence_classify "$F_TEST_LOCK")" = absent ] || fail test-full-fence-busy

checkpoint_parent_death() {
  _cpd_run=$1
  _cpd_point=$2
  _cpd_pause="$TEST_ROOT/$_cpd_run.paused"
  _cpd_release="$TEST_ROOT/$_cpd_run.release"
  MERV_NODE_RUNNER_SELFTEST_CHECKPOINT=$_cpd_point
  MERV_NODE_RUNNER_SELFTEST_PAUSE_FILE=$_cpd_pause
  MERV_NODE_RUNNER_SELFTEST_RELEASE_FILE=$_cpd_release
  export MERV_NODE_RUNNER_SELFTEST_CHECKPOINT MERV_NODE_RUNNER_SELFTEST_PAUSE_FILE
  export MERV_NODE_RUNNER_SELFTEST_RELEASE_FILE
  sh "$BASE_DIR/functions/mervlan_node_runner.sh" start "$_cpd_run" 1 \
    > "$TEST_ROOT/$_cpd_run.out" 2>&1 &
  _cpd_parent=$!
  _cpd_tries=0
  while [ ! -f "$_cpd_pause" ] && [ "$_cpd_tries" -lt 12 ]; do
    sleep 1
    _cpd_tries=$((_cpd_tries + 1))
  done
  [ -f "$_cpd_pause" ] || { kill -KILL "$_cpd_parent" 2>/dev/null || :; wait "$_cpd_parent" 2>/dev/null || :; fail "checkpoint $_cpd_point was not reached"; }
  _cpd_run_dir="$MERV_NODE_STATUS_ROOT/$_cpd_run"
  case "$_cpd_point" in
    bound-before-started)
      _cpd_pending="$_cpd_run_dir/node_1.pending"
      _cpd_child=$(sed -n 's/^runner_pid=//p' "$_cpd_pending" 2>/dev/null)
      _cpd_child_start=$(sed -n 's/^runner_proc_start_time=//p' "$_cpd_pending" 2>/dev/null)
      case "$_cpd_child:$_cpd_child_start" in *[!0-9:]*|:*|*::*) fail bound-checkpoint-child-id ;; esac
      kill -KILL "$_cpd_parent" 2>/dev/null || fail bound-checkpoint-parent-kill
      wait "$_cpd_parent" 2>/dev/null || :
      : > "$_cpd_release" || fail bound-checkpoint-release
      _cpd_tries=0
      while [ "$(merv_continuation_process_state "$_cpd_child" "$_cpd_child_start")" = live ] && [ "$_cpd_tries" -lt 10 ]; do
        sleep 1
        _cpd_tries=$((_cpd_tries + 1))
      done
      case "$(merv_continuation_process_state "$_cpd_child" "$_cpd_child_start")" in dead|reused) ;; *) fail bound-checkpoint-child-live ;; esac
      [ "$(merv_maintenance_quiesce_classify)" != IDLE ] || fail 'parent death after runner bind made Q idle'
      [ ! -e "$_cpd_run_dir/node_1.status" ] || fail 'runner mutated before stale-parent revalidation'
      rm -f "$_cpd_pending" || fail bound-checkpoint-cleanup
      ;;
    *)
      kill -KILL "$_cpd_parent" 2>/dev/null || fail "parent kill at $_cpd_point"
      wait "$_cpd_parent" 2>/dev/null || :
      case "$_cpd_point" in
        before-pending)
          [ ! -e "$_cpd_run_dir/node_1.pending" ] && [ ! -e "$_cpd_run_dir/node_1.status" ] || fail 'pre-pending death left a child publication'
          [ "$(merv_maintenance_quiesce_classify)" = IDLE ] || fail 'pre-pending death left mutation-capable work'
          ;;
        pending-before-spawn|spawn-before-bind)
          [ -f "$_cpd_run_dir/node_1.pending" ] || fail "$_cpd_point did not preserve pending record"
          [ "$(merv_maintenance_quiesce_classify)" != IDLE ] || fail "$_cpd_point became false idle after parent death"
          if [ "$_cpd_point" = spawn-before-bind ]; then
            sleep 11
            [ "$(merv_maintenance_quiesce_classify)" != IDLE ] || fail 'unbound runner timeout converted pending to idle'
          fi
          rm -f "$_cpd_run_dir/node_1.pending" || fail "$_cpd_point pending cleanup"
          ;;
      esac
      ;;
  esac
  rm -f "$_cpd_run_dir/runner.log" || fail "checkpoint $_cpd_point runner-log cleanup"
  rmdir "$_cpd_run_dir" 2>/dev/null || fail "checkpoint $_cpd_point left unexpected run state"
  unset MERV_NODE_RUNNER_SELFTEST_CHECKPOINT MERV_NODE_RUNNER_SELFTEST_PAUSE_FILE
  unset MERV_NODE_RUNNER_SELFTEST_RELEASE_FILE
}

checkpoint_parent_death 910010-1 before-pending || fail death-before-pending
checkpoint_parent_death 910011-1 pending-before-spawn || fail death-after-pending
checkpoint_parent_death 910012-1 spawn-before-bind || fail death-after-spawn-before-bind
checkpoint_parent_death 910013-1 bound-before-started || fail death-after-bind-before-started
pass 'real process deaths before publish, before spawn, before bind, and before activation remain safe'

# Both canonical maintenance authorities reject the node runner after it owns
# target-local action R, before it publishes a run or invokes the manager.
merv_full_fence_claim "$F_TEST_LOCK" || fail test-fence-claim
if sh "$BASE_DIR/functions/mervlan_node_runner.sh" start 910001-1 1 >/dev/null 2>&1; then
  fail 'live F admitted node manager start'
fi
[ ! -e "$MERV_NODE_STATUS_ROOT/910001-1/node_1.pending" ] &&
  [ ! -e "$MNR_TEST_MARKER.mutated" ] || fail 'F refusal left pending work or mutated target'
merv_full_fence_release "$F_TEST_LOCK" || fail test-fence-release
_fence_nonce=
pass 'authenticated self-test F refuses node run before target mutation'

merv_owner_lock_acquire "$M_TEST_LOCK" 0 0 node-runner-test || fail test-maintenance-claim
_maintenance_nonce=$MERV_LOCK_NONCE
if sh "$BASE_DIR/functions/mervlan_node_runner.sh" start 910002-1 1 >/dev/null 2>&1; then
  fail 'live M admitted node manager start'
fi
[ ! -e "$MERV_NODE_STATUS_ROOT/910002-1/node_1.pending" ] &&
  [ ! -e "$MNR_TEST_MARKER.mutated" ] || fail 'M refusal left pending work or mutated target'
merv_owner_lock_release "$M_TEST_LOCK" "$_maintenance_nonce" || fail test-maintenance-release
_maintenance_nonce=
pass 'authenticated self-test M refuses node run before target mutation'

cat > "$MERV_NODE_RUNNER_MANAGER" <<'EOF'
#!/bin/sh
: > "$MNR_TEST_MARKER.started"
while [ ! -e "$MNR_TEST_MARKER.release" ]; do sleep 1; done
: > "$MNR_TEST_MARKER.mutated"
EOF
chmod 700 "$MERV_NODE_RUNNER_MANAGER" || fail fake-manager-mode
_release_marker="$MNR_TEST_MARKER.release"

sh "$BASE_DIR/functions/mervlan_node_runner.sh" start 910003-1 1 > "$TEST_ROOT/start.out" 2>&1 || fail node-run-start
_tries=0
while [ ! -e "$MNR_TEST_MARKER.started" ] && [ "$_tries" -lt 15 ]; do
  sleep 1
  _tries=$((_tries + 1))
done
[ -e "$MNR_TEST_MARKER.started" ] || fail node-manager-not-started

# A live target R remains Q-visible while Full-style M/F are held.
merv_owner_lock_acquire "$M_TEST_LOCK" 0 0 node-run-race || fail race-maintenance-claim
_maintenance_nonce=$MERV_LOCK_NONCE
_maintenance_start=$MERV_LOCK_START
merv_full_fence_claim "$F_TEST_LOCK" || fail race-fence-claim
_fence_nonce=$MERV_FULL_FENCE_NONCE
_fence_start=$MERV_FULL_FENCE_START
[ "$(merv_maintenance_quiesce_classify "$$" "$_maintenance_start" "$_maintenance_nonce" "$$" "$_fence_start" "$_fence_nonce")" = BUSY ] || fail 'Q did not see live node action/node run'
_q_mid=$(merv_maintenance_quiesce_classify "$$" "$_maintenance_start" "$_maintenance_nonce" "$$" "$_fence_start" "$_fence_nonce")
[ "$_q_mid" = BUSY ] || fail 'Q did not remain busy under target R'
mkdir -p "$MERV_QUIESCE_OBSERVATION" || fail observation-root
printf '%s\n' 'snapshot_requested_generation=2' 'snapshot_completed_generation=1' \
  'collection_requested_generation=0' 'collection_completed_generation=0' \
  > "$MERV_QUIESCE_OBSERVATION/request.state" || fail observation-pending
chmod 600 "$MERV_QUIESCE_OBSERVATION/request.state" || fail observation-mode
: > "$MNR_TEST_MARKER.release"
_tries=0
while [ ! -e "$MNR_TEST_MARKER.mutated" ] && [ "$_tries" -lt 15 ]; do
  sleep 1
  _tries=$((_tries + 1))
done
[ -e "$MNR_TEST_MARKER.mutated" ] || fail 'manager did not finish its protected mutation'
_status_file="$MERV_NODE_STATUS_ROOT/910003-1/node_1.status"
_manager_pid=$(sed -n 's/^manager_pid=//p' "$_status_file" 2>/dev/null)
_manager_start=$(sed -n 's/^manager_proc_start_time=//p' "$_status_file" 2>/dev/null)
_tries=0
while [ "$(merv_continuation_process_state "$_manager_pid" "$_manager_start")" = live ] && [ "$_tries" -lt 10 ]; do
  sleep 1
  _tries=$((_tries + 1))
done
case "$(merv_continuation_process_state "$_manager_pid" "$_manager_start")" in dead|reused) ;; *) fail 'manager process identity did not become terminal' ;; esac
grep -Fqx 'state=started' "$_status_file" || fail 'node run became terminal while observation was pending'
merv_maintenance_quiesce_classify "$$" "$_maintenance_start" "$_maintenance_nonce" "$$" "$_fence_start" "$_fence_nonce" >/dev/null
if [ "$MERV_QUIESCE_STATUS" != BUSY ] || [ "$MERV_QUIESCE_REASON" != observation-generation-pending ]; then
  printf 'Q detail after manager exit: status=%s reason=%s\n' \
    "$MERV_QUIESCE_STATUS" "$MERV_QUIESCE_REASON" >&2
  cat "$_status_file" >&2 2>/dev/null || :
  fail 'Q did not attribute busy state to the pending observation generation'
fi
rm -f "$MERV_QUIESCE_OBSERVATION/request.state" || fail observation-clear
_tries=0
while [ "$(merv_maintenance_quiesce_classify "$$" "$_maintenance_start" "$_maintenance_nonce" "$$" "$_fence_start" "$_fence_nonce")" != IDLE ] && [ "$_tries" -lt 15 ]; do
  sleep 1
  _tries=$((_tries + 1))
done
_q_final=$(merv_maintenance_quiesce_classify "$$" "$_maintenance_start" "$_maintenance_nonce" "$$" "$_fence_start" "$_fence_nonce")
if [ "$_q_final" != IDLE ]; then
  merv_maintenance_quiesce_classify >/dev/null
  printf 'Q detail: status=%s reason=%s\n' "$MERV_QUIESCE_STATUS" "$MERV_QUIESCE_REASON" >&2
  cat "$TEST_ROOT/node_runs/910003-1/node_1.pending" "$TEST_ROOT/node_runs/910003-1/node_1.status" 2>/dev/null >&2 || :
  fail 'Q did not become idle after manager/R terminal'
fi
merv_full_fence_release "$F_TEST_LOCK" "$$" "$_fence_start" "$_fence_nonce" || fail race-fence-release
_fence_nonce=
merv_owner_lock_release "$M_TEST_LOCK" "$_maintenance_nonce" || fail race-maintenance-release
_maintenance_nonce=
pass 'real node action-R race stays Q-busy until terminal while exact M/F remain held'

cat > "$TEST_ROOT/publish_pending.sh" <<'EOF'
#!/bin/sh
set -u
_dir=$1
_run=$2
_node=$3
_child_pid=$4
_child_start=$5
_parent_start=$(awk '{print $22}' "/proc/$$/stat" 2>/dev/null || printf '')
case "$$:$_parent_start" in *[!0-9:]*|:*|*::*) exit 1 ;; esac
case "$_child_pid:$_child_start" in none:none) ;; *[!0-9:]*|:*|*::*) exit 1 ;; esac
( umask 077
  printf 'format_version=1\nrun_id=%s\nnode_id=%s\nstate=pending\nparent_pid=%s\nparent_proc_start_time=%s\nparent_nonce=publisher.%s\nrunner_pid=%s\nrunner_proc_start_time=%s\n' \
    "$_run" "$_node" "$$" "$_parent_start" "$$" "$_child_pid" "$_child_start" > "$_dir/node_$_node.pending"
) || exit 1
chmod 600 "$_dir/node_$_node.pending" || exit 1
EOF
chmod 700 "$TEST_ROOT/publish_pending.sh" || fail pending-publisher-mode
mkdir -m 700 "$MERV_NODE_STATUS_ROOT/910004-1" || fail pending-dir
sh "$TEST_ROOT/publish_pending.sh" "$MERV_NODE_STATUS_ROOT/910004-1" 910004-1 1 none none || fail pending-unbound-publication
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail 'dead parent with unbound pending run became idle'
sleep 30 &
_pending_child=$!
_pending_child_start=$(merv_proc_start_time "$_pending_child" 2>/dev/null || printf '')
mkdir -m 700 "$MERV_NODE_STATUS_ROOT/910005-1" || fail bound-pending-dir
sh "$TEST_ROOT/publish_pending.sh" "$MERV_NODE_STATUS_ROOT/910005-1" 910005-1 1 \
  "$_pending_child" "$_pending_child_start" || fail pending-bound-publication
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail 'dead parent with bound pending run became idle'
kill "$_pending_child" 2>/dev/null || :
wait "$_pending_child" 2>/dev/null || :
_pending_child=
[ "$(merv_maintenance_quiesce_classify)" = BUSY ] || fail 'dead parent and child made pending run idle'
rm -f "$MERV_NODE_STATUS_ROOT/910004-1/node_1.pending" \
  "$MERV_NODE_STATUS_ROOT/910005-1/node_1.pending" || fail pending-fixture-cleanup
rmdir "$MERV_NODE_STATUS_ROOT/910004-1" "$MERV_NODE_STATUS_ROOT/910005-1" || fail pending-fixture-rmdir
pass 'real parent exit leaves pre-spawn and unbound runner records Q-busy'

mkdir -m 700 "$MERV_NODE_STATUS_ROOT/910006-1" || fail runner-death-dir
sleep 1 &
_dead_runner=$!
_dead_runner_start=$(merv_proc_start_time "$_dead_runner" 2>/dev/null || printf '')
wait "$_dead_runner" 2>/dev/null || :
sleep 30 &
_live_manager=$!
_live_manager_start=$(merv_proc_start_time "$_live_manager" 2>/dev/null || printf '')
_test_parent_start=$(merv_identity_current_start /proc 2>/dev/null || printf '')
_test_now=$(date +%s 2>/dev/null || printf '')
case "$_dead_runner:$_dead_runner_start:$_live_manager:$_live_manager_start:$_test_parent_start:$_test_now" in
  *[!0-9:]*|:*|*::*) fail runner-death-identities ;;
esac
cat > "$MERV_NODE_STATUS_ROOT/910006-1/node_1.status" <<EOF
format_version=2
run_id=910006-1
node_id=1
state=started
pid=$_dead_runner
proc_start_time=$_dead_runner_start
parent_pid=$$
parent_proc_start_time=$_test_parent_start
manager_pid=$_live_manager
manager_proc_start_time=$_live_manager_start
started_epoch=$_test_now
completed_epoch=0
exit_code=
reason=manager-started
EOF
chmod 600 "$MERV_NODE_STATUS_ROOT/910006-1/node_1.status" || fail runner-death-mode
merv_maintenance_quiesce_classify >/dev/null
[ "$MERV_QUIESCE_STATUS" = BUSY ] && [ "$MERV_QUIESCE_REASON" = node-run-manager-active ] ||
  fail 'Q did not see manager after runner death'
kill "$_live_manager" 2>/dev/null || :
wait "$_live_manager" 2>/dev/null || :
_pending_child=
merv_maintenance_quiesce_classify >/dev/null
[ "$MERV_QUIESCE_STATUS" = BLOCKING ] || fail 'dead runner with dead manager became terminal without status transition'
rm -f "$MERV_NODE_STATUS_ROOT/910006-1/node_1.status" || fail runner-death-status-cleanup
rmdir "$MERV_NODE_STATUS_ROOT/910006-1" || fail runner-death-dir-cleanup
pass 'runner death cannot hide a live manager or make nonterminal state idle'

# If a manager has already handed off observation work, terminating its runner
# must not publish a terminal run record while that generation is still pending.
MERV_NODE_RUNNER_MANAGER="$TEST_ROOT/manager-observation.sh"
cat > "$MERV_NODE_RUNNER_MANAGER" <<'EOF'
#!/bin/sh
mkdir -p "$MERV_QUIESCE_OBSERVATION" || exit 1
printf '%s\n' 'snapshot_requested_generation=2' 'snapshot_completed_generation=1' \
  'collection_requested_generation=0' 'collection_completed_generation=0' \
  > "$MERV_QUIESCE_OBSERVATION/request.state" || exit 1
EOF
chmod 700 "$MERV_NODE_RUNNER_MANAGER" || fail observation-manager-mode
export MERV_NODE_RUNNER_MANAGER
sh "$BASE_DIR/functions/mervlan_node_runner.sh" start 910007-1 1 \
  > "$TEST_ROOT/observation-start.out" 2>&1 || fail observation-run-start
_observation_status="$MERV_NODE_STATUS_ROOT/910007-1/node_1.status"
_observation_runner=$(sed -n 's/^pid=//p' "$_observation_status" 2>/dev/null)
_observation_start=$(sed -n 's/^proc_start_time=//p' "$_observation_status" 2>/dev/null)
_tries=0
while [ ! -f "$MERV_QUIESCE_OBSERVATION/request.state" ] && [ "$_tries" -lt 10 ]; do
  sleep 1
  _tries=$((_tries + 1))
done
[ -f "$MERV_QUIESCE_OBSERVATION/request.state" ] || fail observation-request-missing
[ "$(sed -n 's/^state=//p' "$_observation_status")" = started ] || fail 'runner became terminal while observation was pending'
case "$_observation_runner:$_observation_start" in *[!0-9:]*|:*|*::*) fail observation-runner-identity ;; esac
kill -TERM "$_observation_runner" 2>/dev/null || fail observation-runner-term
_tries=0
while [ "$(merv_continuation_process_state "$_observation_runner" "$_observation_start")" = live ] && [ "$_tries" -lt 2 ]; do
  sleep 1
  _tries=$((_tries + 1))
done
_observation_runner_state=$(merv_continuation_process_state "$_observation_runner" "$_observation_start")
case "$_observation_runner_state" in
  live)
    kill -KILL "$_observation_runner" 2>/dev/null || fail observation-runner-kill
    _tries=0
    while [ "$(merv_continuation_process_state "$_observation_runner" "$_observation_start")" = live ] && [ "$_tries" -lt 10 ]; do
      sleep 1
      _tries=$((_tries + 1))
    done
    case "$(merv_continuation_process_state "$_observation_runner" "$_observation_start")" in dead|reused) ;; *) fail observation-runner-not-terminal ;; esac
    ;;
  dead|reused) ;;
  *) fail observation-runner-unobservable ;;
esac
[ "$(sed -n 's/^state=//p' "$_observation_status")" = started ] || fail 'terminated runner published terminal while observation was pending'
[ "$(merv_maintenance_quiesce_classify)" != IDLE ] || fail 'Q ignored pending observation after runner termination'
rm -f "$MERV_QUIESCE_OBSERVATION/request.state" || fail observation-request-clear
[ "$(merv_maintenance_quiesce_classify)" = BLOCKING ] || fail 'dead started runner was treated as terminal after observation cleared'
rm -f "$_observation_status" || fail observation-status-cleanup
rm -f "$MERV_NODE_STATUS_ROOT/910007-1/runner.log" \
  "$MERV_NODE_STATUS_ROOT/910007-1/cli.log" \
  "$MERV_NODE_STATUS_ROOT/910007-1/vlan.log" \
  "$MERV_NODE_STATUS_ROOT/910007-1/stdout.log" || fail observation-run-logs-cleanup
rmdir "$MERV_NODE_STATUS_ROOT/910007-1" || fail observation-run-dir-cleanup
pass 'runner termination cannot publish terminal while observation remains pending'

printf '%s\n' 'NODE_RUNNER_PENDING_LIFECYCLE_OK'
