#!/bin/sh
# Real wrapper/child process test for interrupted Update M ownership.

set -u
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.update-owner-life.$$"
ADDON="$TEST_ROOT/addon"
M_TEST_LOCK="$TEST_ROOT/locks/mervlan_maintenance.lock"
F_TEST_LOCK="$TEST_ROOT/full.lock"
ACTION_TEST_LOCK="$TEST_ROOT/locks/mervlan_action.lock"
umask 077
mkdir -p /tmp/mervlan_tmp "$ADDON/settings" "$ADDON/functions" \
  "$TEST_ROOT/state" "$TEST_ROOT/locks" "$TEST_ROOT/continuations" \
  "$TEST_ROOT/runtime/node_jobs" "$TEST_ROOT/node_runs" "$TEST_ROOT/bin" \
  /tmp/mervlan_tmp/logs || exit 1
chmod 700 "$TEST_ROOT" "$ADDON" "$ADDON/settings" "$ADDON/functions" \
  "$TEST_ROOT/state" "$TEST_ROOT/locks" "$TEST_ROOT/continuations" \
  "$TEST_ROOT/runtime" "$TEST_ROOT/runtime/node_jobs" "$TEST_ROOT/node_runs" \
  "$TEST_ROOT/bin" || exit 1
cp -R "$BASE_DIR/settings/." "$ADDON/settings/" || exit 1
cp "$BASE_DIR/functions/mervlan_boot_wrap.sh" "$ADDON/functions/mervlan_boot_wrap.sh" || exit 1
cp "$BASE_DIR/settings/lib_json.sh" "$ADDON/settings/lib_json.sh" || exit 1
printf '%s\n' '{"General":{"IS_NODE":"0"}}' > "$ADDON/settings/settings.json" || exit 1
chmod 600 "$ADDON/settings/settings.json" || exit 1

# Q's DHCP rule classifier gets a private empty fake, matching the existing
# authenticated router-test seam. It reports no chains or rules.
cat > "$TEST_ROOT/bin/ebtables" <<'EOF'
#!/bin/sh
case " $* " in *' -L MERV_DHCP_HOLD '*) exit 1 ;; esac
exit 0
EOF
chmod 700 "$TEST_ROOT/bin/ebtables" || exit 1

_wrapper_pid=
_child_release=
_f_nonce=
_f_start=
_m_nonce=
cleanup() {
  [ -z "$_child_release" ] || : > "$_child_release" 2>/dev/null || :
  [ -z "$_wrapper_pid" ] || kill -TERM "$_wrapper_pid" 2>/dev/null || :
  [ -z "$_wrapper_pid" ] || wait "$_wrapper_pid" 2>/dev/null || :
  rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || exit 1
merv_test_context_enable "$BASE_DIR" "$TEST_ROOT" || exit 1
MERV_BASE=$BASE_DIR
MERV_STATE_ROOT=$TEST_ROOT/state
MERV_UPDATE_JOURNAL=$MERV_STATE_ROOT/update.journal
MERV_UPDATE_QUIESCE_FILE=$MERV_STATE_ROOT/update.quiesce
MERVLAN_MAINTENANCE_LOCK_OVERRIDE=$M_TEST_LOCK
MERV_FULL_FENCE_PATH=$F_TEST_LOCK
MERV_ACTION_LOCK_PATH=$ACTION_TEST_LOCK
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
MERV_DHCP_HOLD_TEST_MODE=1
MERV_DHCP_HOLD_TEST_ROOT=$TEST_ROOT
MERV_DHCP_HOLD_EBTABLES=$TEST_ROOT/bin/ebtables
MERV_DHCP_HOLD_STATE_ROOT=$TEST_ROOT/locks/dhcp_hold
MERV_OWNER_LOCK_PROC_ROOT=/proc
MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=10
export MERV_BASE MERV_STATE_ROOT MERV_UPDATE_JOURNAL MERV_UPDATE_QUIESCE_FILE
export MERVLAN_MAINTENANCE_LOCK_OVERRIDE MERV_FULL_FENCE_PATH MERV_ACTION_LOCK_PATH
export MERV_CONTINUATION_ROOT MERV_QUIESCE_LOCK_ROOT MERV_QUIESCE_RUNTIME_ROOT
export MERV_QUIESCE_STATE_ROOT MERV_QUIESCE_SETTINGS_RECONCILE MERV_QUIESCE_NODE_RECONCILE
export MERV_QUIESCE_TRUST_LOCK MERV_QUIESCE_DHCP_ROOT MERV_QUIESCE_DHCP_LEGACY
export MERV_QUIESCE_OBSERVATION MERV_QUIESCE_NODE_JOBS MERV_QUIESCE_NODE_RUNS
export MERV_DHCP_HOLD_TEST_MODE MERV_DHCP_HOLD_TEST_ROOT MERV_DHCP_HOLD_EBTABLES
export MERV_DHCP_HOLD_STATE_ROOT MERV_OWNER_LOCK_PROC_ROOT MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_update_state.sh" || exit 1
. "$BASE_DIR/settings/lib_full_fence.sh" || exit 1
. "$BASE_DIR/settings/lib_continuation.sh" || exit 1
. "$BASE_DIR/settings/lib_maintenance_quiesce.sh" || exit 1

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -n "${MERV_TEST_CASE_DIR:-}" ] && [ -f "$MERV_TEST_CASE_DIR/wrapper.out" ]; then
    cat "$MERV_TEST_CASE_DIR/wrapper.out" >&2
  fi
  exit 1
}
pass() { printf 'PASS: %s\n' "$1"; }
write_interrupted_update() {
  _wiu_run=$1
  merv_update_journal_write "$_wiu_run" activated refs/heads/test 0 1 1 1 0 \
    interrupted none none none none none none old new || return 1
  merv_update_quiesce_begin "$_wiu_run"
}
wait_file() {
  _wf_path=$1
  _wf_tries=0
  while [ ! -f "$_wf_path" ] && [ "$_wf_tries" -lt 20 ]; do
    sleep 1
    _wf_tries=$((_wf_tries + 1))
  done
  [ -f "$_wf_path" ]
}

cat > "$ADDON/install.sh" <<'CHILD'
#!/bin/sh
set -u
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 41
. "$MERV_BASE/settings/lib_update_state.sh" || exit 42
. "$MERV_BASE/settings/lib_continuation.sh" || exit 43
. "$MERV_BASE/settings/lib_maintenance_quiesce.sh" || exit 44
merv_maintenance_delegation_valid || exit 45
merv_update_recovery_context_valid || exit 46
merv_maintenance_direct_admit normal || exit 47
[ "${MERV_MAINTENANCE_ENTRY_OWNED:-1}" = 0 ] &&
  [ "${MERV_MAINTENANCE_ENTRY_DELEGATED:-0}" = 1 ] || exit 48
merv_owner_v2_matches "$MERV_UPDATE_RECOVERY_M_PATH" \
  "$MERV_UPDATE_RECOVERY_M_PID" "$MERV_UPDATE_RECOVERY_M_START" \
  "$MERV_UPDATE_RECOVERY_M_NONCE" /proc || exit 49
merv_continuation_activate_wait "$MERV_CONTINUATION_TOKEN" || exit 50
: > "$MERV_TEST_CASE_DIR/child.started" || exit 51
while [ ! -f "$MERV_TEST_CASE_DIR/child.release" ]; do sleep 1; done
merv_update_journal_active && merv_update_quiesce_active || exit 52
merv_owner_v2_matches "$MERV_UPDATE_RECOVERY_M_PATH" \
  "$MERV_UPDATE_RECOVERY_M_PID" "$MERV_UPDATE_RECOVERY_M_START" \
  "$MERV_UPDATE_RECOVERY_M_NONCE" /proc || exit 53
merv_maintenance_quiesce_classify \
  "$MERV_UPDATE_RECOVERY_M_PID" "$MERV_UPDATE_RECOVERY_M_START" \
  "$MERV_UPDATE_RECOVERY_M_NONCE" "" "" "" \
  "$MERV_CONTINUATION_TOKEN" >/dev/null 2>&1 || exit 54
[ "${MERV_QUIESCE_STATUS:-BLOCKING}" = IDLE ] || exit 55
merv_continuation_retire "$MERV_CONTINUATION_TOKEN" || exit 56
: > "$MERV_TEST_CASE_DIR/child.returned"
CHILD
chmod 755 "$ADDON/install.sh" || exit 1

prepare_case() {
  _pc_name=$1
  MERV_BASE=$ADDON
  MERV_TEST_CASE_DIR=$TEST_ROOT/$_pc_name
  mkdir -m 700 "$MERV_TEST_CASE_DIR" || return 1
  MERV_BOOT_WRAP_SELFTEST_PAUSE_FILE=$MERV_TEST_CASE_DIR/parent.paused
  MERV_BOOT_WRAP_SELFTEST_RELEASE_FILE=$MERV_TEST_CASE_DIR/parent.release
  MERV_TEST_CASE_DIR=$MERV_TEST_CASE_DIR
  export MERV_BASE MERV_TEST_CASE_DIR MERV_BOOT_WRAP_SELFTEST_PAUSE_FILE MERV_BOOT_WRAP_SELFTEST_RELEASE_FILE
}

# End-to-end recovery: wrapper M is borrowed by reinstall, retained after the
# child returns, and held while another maintenance acquisition is attempted.
prepare_case success || fail case-setup
write_interrupted_update update-test-1 || fail journal-setup
sh "$ADDON/functions/mervlan_boot_wrap.sh" install \
  > "$MERV_TEST_CASE_DIR/wrapper.out" 2>&1 &
_wrapper_pid=$!
wait_file "$MERV_TEST_CASE_DIR/child.started" || fail 'delegated reinstall did not start'
_wrapper_start=$(merv_identity_proc_start "$_wrapper_pid" /proc 2>/dev/null || printf '')
case "$_wrapper_pid:$_wrapper_start" in *[!0-9:]*|:*|*::*) fail wrapper-identity ;; esac
merv_owner_v2_read "$M_TEST_LOCK/owner" || fail wrapper-M-record
[ "$MERV_OWNER_V2_PID" = "$_wrapper_pid" ] &&
  [ "$MERV_OWNER_V2_PROC_START_TIME" = "$_wrapper_start" ] || fail 'M is not owned by wrapper PID/start'
_wrapper_nonce=$MERV_OWNER_V2_NONCE
merv_owner_v2_matches "$M_TEST_LOCK" "$_wrapper_pid" "$_wrapper_start" \
  "$_wrapper_nonce" /proc || fail wrapper-M-authentication
[ -f "$MERV_UPDATE_JOURNAL" ] && [ -f "$MERV_UPDATE_QUIESCE_FILE" ] || fail 'markers missing during delegated reinstall'
: > "$MERV_TEST_CASE_DIR/child.release" || fail release-install-child
wait_file "$MERV_TEST_CASE_DIR/parent.paused" || fail 'wrapper did not pause after reinstall return'
[ -f "$MERV_TEST_CASE_DIR/child.returned" ] || fail 'install child did not return terminal'
[ -f "$MERV_UPDATE_JOURNAL" ] && [ -f "$MERV_UPDATE_QUIESCE_FILE" ] || fail 'wrapper retired markers before the checkpoint'
merv_owner_v2_matches "$M_TEST_LOCK" "$_wrapper_pid" "$_wrapper_start" \
  "$_wrapper_nonce" /proc || fail 'wrapper lost exact M before marker retirement'
if merv_owner_lock_acquire "$M_TEST_LOCK" 0 0 competing-maintenance; then
  merv_owner_lock_release "$M_TEST_LOCK" "$MERV_LOCK_NONCE" >/dev/null 2>&1 || :
  fail 'competing maintenance acquired M between child return and retirement'
fi
: > "$MERV_BOOT_WRAP_SELFTEST_RELEASE_FILE" || fail release-wrapper-checkpoint
wait "$_wrapper_pid" || { cat "$MERV_TEST_CASE_DIR/wrapper.out" >&2; fail wrapper-success; }
_wrapper_pid=
[ ! -e "$MERV_UPDATE_JOURNAL" ] && [ ! -e "$MERV_UPDATE_QUIESCE_FILE" ] || fail 'wrapper did not retire transaction markers'
[ "$(merv_update_maintenance_lock_state)" = absent ] || fail 'wrapper did not release M after marker retirement'
pass 'real wrapper retains exact M through delegated reinstall and marker retirement'

# An existing F prevents recovery before the delegated installer starts.
prepare_case fenced || fail fenced-case-setup
write_interrupted_update update-test-2 || fail fenced-journal-setup
merv_full_fence_claim "$F_TEST_LOCK" || fail fence-claim
_f_nonce=$MERV_FULL_FENCE_NONCE
_f_start=$MERV_FULL_FENCE_START
: > "$MERV_TEST_CASE_DIR/child.release"
if sh "$ADDON/functions/mervlan_boot_wrap.sh" install \
  > "$MERV_TEST_CASE_DIR/wrapper.out" 2>&1; then
  fail 'F-active interrupted recovery succeeded'
fi
[ ! -e "$MERV_TEST_CASE_DIR/child.started" ] || fail 'F-active recovery spawned reinstall'
[ "$(merv_update_maintenance_lock_state)" = absent ] || fail 'F-active recovery acquired M'
[ -f "$MERV_UPDATE_JOURNAL" ] && [ -f "$MERV_UPDATE_QUIESCE_FILE" ] || fail 'F-active recovery changed markers'
merv_full_fence_release "$F_TEST_LOCK" "$$" "$_f_start" "$_f_nonce" || fail fence-release
_f_nonce=
pass 'F-active interrupted recovery refuses before M or reinstall mutation'

# Killing the wrapper at the post-child/pre-retirement checkpoint leaves both
# the dead owner record and the interrupted transaction markers in place.
prepare_case crash || fail crash-case-setup
write_interrupted_update update-test-3 || fail crash-journal-setup
sh "$ADDON/functions/mervlan_boot_wrap.sh" install \
  > "$MERV_TEST_CASE_DIR/wrapper.out" 2>&1 &
_wrapper_pid=$!
wait_file "$MERV_TEST_CASE_DIR/child.started" || fail 'crash case installer did not start'
: > "$MERV_TEST_CASE_DIR/child.release" || fail crash-child-release
wait_file "$MERV_TEST_CASE_DIR/parent.paused" || fail 'crash case wrapper did not reach checkpoint'
[ -f "$MERV_TEST_CASE_DIR/child.returned" ] || fail 'crash case child did not return'
kill -KILL "$_wrapper_pid" 2>/dev/null || fail wrapper-kill
wait "$_wrapper_pid" 2>/dev/null || :
_wrapper_pid=
[ -f "$MERV_UPDATE_JOURNAL" ] && [ -f "$MERV_UPDATE_QUIESCE_FILE" ] || fail 'wrapper death removed recovery markers'
case "$(merv_update_maintenance_lock_state)" in dead|reused) ;; *) fail 'wrapper death did not leave a fail-closed stale M record' ;; esac
pass 'wrapper death before retirement preserves journal/quiesce and does not release M'

printf '%s\n' 'INTERRUPTED_UPDATE_OWNER_LIFETIME_OK'
