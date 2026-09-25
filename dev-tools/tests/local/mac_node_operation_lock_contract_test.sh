#!/bin/sh
# MAC Shield node operations and Sync share the canonical action owner.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-node-operation-lock.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export MERV_BASE="$BASE_DIR"
export VAR_SETTINGS_LOADED=1
export LIB_SSH_LOADED=1
export LIB_ACTION_LOCK_LOADED=1
export TMPDIR="$TEST_ROOT/tmp"
export LOCKDIR="$TEST_ROOT/locks"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_ACTION_LOCK_PATH="$LOCKDIR/mervlan_action.lock"
mkdir -p "$TMPDIR" "$LOCKDIR" "$MERV_STATE_ROOT"

. "$BASE_DIR/settings/lib_identity.sh" || exit 1
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
merv_is_valid_node_id() { return 0; }
. "$BASE_DIR/settings/mac_shield_snapshot.sh" || exit 1

ACTION_OWNER=none
ACTION_RELEASES=0
info() { :; }
warn() { :; }
error() { :; }
merv_mac_log() { :; }
merv_mac_logv() { :; }
merv_mac_is_main() { return 0; }
merv_mac_snapshot_body() { : > "$TEST_ROOT/body-entered"; return 0; }
merv_action_lock_enter() {
  if [ "$ACTION_OWNER" != none ]; then
    MERV_ACTION_LOCK_LAST_FAILURE=action-lock-busy
    return 3
  fi
  ACTION_OWNER=mac
  MERV_ACTION_LOCK_MODE=self
  MERV_ACTION_LOCK_NONCE=mac-nonce
  MERV_ACTION_LOCK_START=1
  return 0
}
merv_action_lock_leave() {
  [ "$ACTION_OWNER" = mac ] || return 1
  ACTION_OWNER=none
  ACTION_RELEASES=$((ACTION_RELEASES + 1))
  return 0
}

# Sync owns the action window first: the snapshot must defer before its body
# can perform collection, local enforcement, or remote push.
ACTION_OWNER=sync
MERV_MAC_NODE_SYNC=1
merv_mac_snapshot
_busy_rc=$?
[ "$_busy_rc" -eq 75 ] || fail "busy snapshot returned rc=$_busy_rc"
[ "${MERV_MAC_LAST_STATUS:-}" = busy ] || fail 'busy snapshot status missing'
[ ! -e "$TEST_ROOT/body-entered" ] || fail 'busy snapshot entered its mutation body'

# A snapshot owner first prevents a Sync action owner from entering. This is
# the opposite ordering and exercises the same canonical primitive.
ACTION_OWNER=none
merv_mac_node_operation_lock_enter || fail 'snapshot could not acquire action owner'
[ "$ACTION_OWNER" = mac ] || fail 'snapshot owner was not published'
merv_action_lock_enter "$MERV_ACTION_LOCK_PATH"
_sync_rc=$?
[ "$_sync_rc" -eq 3 ] || fail "Sync contention returned rc=$_sync_rc"
merv_mac_node_operation_lock_leave || fail 'snapshot owner did not release'
[ "$ACTION_OWNER" = none ] || fail 'snapshot owner remained after release'
[ "$ACTION_RELEASES" -eq 1 ] || fail 'snapshot action release count was not exact'

# A failed release keeps ownership state marked active so callers cannot
# falsely proceed. Once the canonical release succeeds, state clears.
ACTION_OWNER=none
merv_mac_node_operation_lock_enter || fail 'second snapshot owner acquisition failed'
merv_action_lock_leave() { return 1; }
if merv_mac_node_operation_lock_leave; then
  fail 'release failure was accepted'
fi
[ "${MERV_MAC_NODE_OPERATION_LOCK_ACTIVE:-0}" -eq 1 ] || fail 'failed release cleared ownership state'
merv_action_lock_leave() {
  ACTION_OWNER=none
  ACTION_RELEASES=$((ACTION_RELEASES + 1))
  return 0
}
merv_mac_node_operation_lock_leave || fail 'retry release failed'
[ "${MERV_MAC_NODE_OPERATION_LOCK_ACTIVE:-0}" -eq 0 ] || fail 'successful release left ownership state active'
printf 'MAC_NODE_OPERATION_LOCK_CONTRACT_OK\n'
