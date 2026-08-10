#!/bin/sh
# Regression reproduction: a failed MERV_MAC shield reload must not be
# reported as successful/reloaded.  This test uses only temporary DB state and
# a stubbed ebtables lifecycle function; it never touches router interfaces.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-snapshot-reload.$$"
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
export MERV_MAC_NODE_SYNC=0
export MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
export MERV_MAC_SNAPSHOT_RESET=0
export MERV_MAC_HEAL_TRIGGER=0

. "$BASE_DIR/settings/lib_identity.sh" || exit 1
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
. "$BASE_DIR/settings/mac_shield_snapshot.sh" || exit 1

info() { :; }
warn() { :; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Keep the structural MAC set unchanged so the production path labels this a
# forced reload rather than a content change.
_now=$(date +%s) || exit 1
printf '%s aa:bb:cc:dd:ee:ff wl0.2 10\n' "$((_now - 1))" > "$MERV_MAC_DB_ACTIVE" || exit 1

merv_mac_snapshot_preconditions_ok() { return 0; }
merv_mac_build_snapshot() {
  printf '%s aa:bb:cc:dd:ee:ff wl0.2 10\n' "$(date +%s)" > "$1" || return 1
  printf '1\n'
}

MERV_MAC_APPLY_CALLS=0
ebt_mac_shield_init_and_apply() {
  MERV_MAC_APPLY_CALLS=$((MERV_MAC_APPLY_CALLS + 1))
  return 1
}

merv_mac_snapshot
_snapshot_rc=$?

[ "$MERV_MAC_APPLY_CALLS" -gt 0 ] || fail 'failed reload stub was not invoked'
[ "$_snapshot_rc" -ne 0 ] || fail 'snapshot returned success after reload failure'
case "$MERV_MAC_LAST_STATUS" in
  reloaded|changed|unchanged)
    fail "snapshot reported successful status after reload failure: $MERV_MAC_LAST_STATUS" ;;
esac

printf 'MAC_SNAPSHOT_RELOAD_FAILURE_CONTRACT_OK\n'
