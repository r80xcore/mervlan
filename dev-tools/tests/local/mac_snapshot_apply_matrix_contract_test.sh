#!/bin/sh
# Strict local MAC Shield enforcement must gate changed, force-reload, and
# intentional empty-reset snapshot outcomes before any node push is attempted.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-snapshot-apply-matrix.$$"
umask 077
mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/db" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export LOCKDIR="$TEST_ROOT/locks"
export RESULTDIR="$TEST_ROOT/results"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_MAC_DB_ACTIVE="$TEST_ROOT/db/active.db"
export MERV_MAC_DB_JFFS="$TEST_ROOT/db/jffs.db"
export MERV_MAC_MAX_AGE_SEC=86400
export MERV_MAC_NODE_SYNC=1
export MERV_MAC_HEAL_TRIGGER=0
export SSH_KEY="$TEST_ROOT/db/ssh.key"
: > "$SSH_KEY"

. "$BASE_DIR/settings/lib_identity.sh" || exit 1
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
. "$BASE_DIR/settings/mac_shield_snapshot.sh" || exit 1

info() { :; }
warn() { :; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
merv_mac_snapshot_preconditions_ok() { return 0; }
merv_mac_is_main() { return 0; }
merv_mac_node_list() { printf '%s\n' '1 192.0.2.1'; }
merv_ssh_preflight_node_lines() { return 0; }
ssh_keys_effectively_installed() { return 0; }
merv_mac_collect_from_node() { return 0; }
MERV_MAC_PUSH_CALLS=0
merv_mac_push_db_to_nodes() { MERV_MAC_PUSH_CALLS=$((MERV_MAC_PUSH_CALLS + 1)); return 0; }
ebt_mac_shield_init_and_apply() { return 1; }

SNAP_RECORD=''
merv_mac_build_snapshot() {
  if [ -n "$SNAP_RECORD" ]; then
    printf '%s\n' "$SNAP_RECORD" > "$1" || return 1
    printf '1\n'
  else
    : > "$1" || return 1
    printf '0\n'
  fi
}

run_case() {
  _case=$1 _expected_reason=$2
  MERV_MAC_PUSH_CALLS=0
  if merv_mac_snapshot; then
    fail "$_case returned success after strict apply failure"
  fi
  [ "$MERV_MAC_LAST_STATUS" = apply_failed ] || fail "$_case status=$MERV_MAC_LAST_STATUS"
  [ "$MERV_MAC_LAST_REASON" = "$_expected_reason" ] || fail "$_case reason=$MERV_MAC_LAST_REASON"
  [ "$MERV_MAC_PUSH_CALLS" -eq 0 ] || fail "$_case began node push after local apply failure"
}

now=$(date +%s) || exit 1
printf '%s aa:bb:cc:dd:ee:01 wl0.2 10\n' "$now" > "$MERV_MAC_DB_ACTIVE"
SNAP_RECORD="$now aa:bb:cc:dd:ee:02 wl0.2 10"
export MERV_MAC_SNAPSHOT_RESET=0 MERV_MAC_SNAPSHOT_ALLOW_EMPTY=0 MERV_MAC_SNAPSHOT_FORCE_RELOAD=0
run_case changed local_enforcement_failed

printf '%s aa:bb:cc:dd:ee:03 wl0.2 10\n' "$now" > "$MERV_MAC_DB_ACTIVE"
SNAP_RECORD="$now aa:bb:cc:dd:ee:03 wl0.2 10"
export MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
run_case force-reload local_enforcement_failed

printf '%s aa:bb:cc:dd:ee:04 wl0.2 10\n' "$now" > "$MERV_MAC_DB_ACTIVE"
SNAP_RECORD=''
export MERV_MAC_SNAPSHOT_RESET=1 MERV_MAC_SNAPSHOT_ALLOW_EMPTY=1 MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
run_case empty-reset reset_local_enforcement_failed
[ ! -s "$MERV_MAC_DB_ACTIVE" ] || fail 'empty reset did not commit its explicit empty database'

printf 'MAC_SNAPSHOT_APPLY_MATRIX_CONTRACT_OK\n'
