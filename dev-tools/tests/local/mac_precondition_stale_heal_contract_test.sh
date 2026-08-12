#!/bin/sh
# Regression reproduction: malformed canonical event ownership must block
# automatic MAC-precondition self-healing.  A malformed owner is unknown, not
# stale/absent; the temporary heal stub must therefore never be launched.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-precondition-heal.$$"
umask 077
mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/base/functions" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export LOCKDIR="$TEST_ROOT/locks"
export RESULTDIR="$TEST_ROOT/results"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_MAC_DB_ACTIVE="$TEST_ROOT/db/active.db"
export MERV_MAC_DB_JFFS="$TEST_ROOT/db/jffs.db"
export MERV_MAC_MAX_AGE_SEC=86400
export MERV_MAC_HEAL_TRIGGER=1
export MERV_MAC_HEAL_TRIGGER_DEBOUNCE=0
export HEAL_MARKER="$TEST_ROOT/heal.started"

. "$BASE_DIR/settings/lib_identity.sh" || exit 1
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
. "$BASE_DIR/settings/mac_shield_snapshot.sh" || exit 1

info() { :; }
warn() { :; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" > "$HEAL_MARKER"' > \
  "$TEST_ROOT/base/functions/heal_event.sh" || exit 1
chmod 700 "$TEST_ROOT/base/functions/heal_event.sh" || exit 1

# A malformed owner record is not a reclaimable stale owner.
_stale_lock="$LOCKDIR/vlan_event.lock"
mkdir -p "$_stale_lock" || exit 1
printf '%s\n' malformed-owner > "$_stale_lock/owner" || exit 1
_stale_state=$(merv_owner_lock_state "$_stale_lock" 2>/dev/null || printf unknown)
[ "$_stale_state" != live ] || fail 'stale fixture unexpectedly classified live'

# Point only the trigger's launch target at the temporary stub after loading
# the production function definitions.
MERV_BASE="$TEST_ROOT/base"
export MERV_BASE
if merv_mac_maybe_trigger_heal_on_precondition_fail; then
  fail 'malformed owner unexpectedly admitted automatic healing'
fi

_wait=0
while [ "$_wait" -lt 20 ] && [ ! -f "$HEAL_MARKER" ]; do
  sleep 0.1
  _wait=$((_wait + 1))
done
[ ! -f "$HEAL_MARKER" ] || fail "malformed vlan_event.lock launched heal (state=$_stale_state)"

printf 'MAC_PRECONDITION_MALFORMED_HEAL_CONTRACT_OK\n'
