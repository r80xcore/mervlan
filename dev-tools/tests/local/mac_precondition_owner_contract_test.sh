#!/bin/sh
# Canonical owner-state decision matrix for MAC precondition healing.  This
# isolates admission only: no production heal or router operation is run.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-precondition-owner.$$"
umask 077
mkdir -p "$TEST_ROOT/locks" "$TEST_ROOT/base/functions" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export LOCKDIR="$TEST_ROOT/locks"
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
MERV_BASE="$TEST_ROOT/base"
export MERV_BASE
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$HEAL_MARKER"' > \
  "$TEST_ROOT/base/functions/heal_event.sh" || exit 1
chmod 700 "$TEST_ROOT/base/functions/heal_event.sh" || exit 1

STATE_SEQUENCE=''
STATE_FILE="$TEST_ROOT/state-sequence"
QUARANTINE_CALLS=0
merv_owner_lock_state() {
  case "$1" in */mervlan_manager.lock) printf '%s\n' absent; return 0 ;; esac
  _sequence=$(cat "$STATE_FILE" 2>/dev/null || printf '%s' "$STATE_SEQUENCE")
  _state=${_sequence%%,*}
  case "$_sequence" in *,*) _sequence=${_sequence#*,} ;; *) _sequence=$_state ;; esac
  printf '%s\n' "$_sequence" > "$STATE_FILE"
  printf '%s\n' "${_state:-absent}"
}
merv_owner_lock_quarantine() {
  QUARANTINE_CALLS=$((QUARANTINE_CALLS + 1))
  return 0
}

reset_case() {
  rm -f "$HEAL_MARKER" "$LOCKDIR/mac_precondition_heal.last"
  QUARANTINE_CALLS=0
  printf '%s\n' "$STATE_SEQUENCE" > "$STATE_FILE"
}
expect_heal() {
  _wait=0
  while [ "$_wait" -lt 20 ] && [ ! -f "$HEAL_MARKER" ]; do
    sleep 0.1
    _wait=$((_wait + 1))
  done
  [ -f "$HEAL_MARKER" ] || fail "$1 did not admit heal"
}
expect_no_heal() {
  sleep 0.2
  [ ! -f "$HEAL_MARKER" ] || fail "$1 unexpectedly admitted heal"
}

STATE_SEQUENCE='absent'; reset_case
merv_mac_maybe_trigger_heal_on_precondition_fail || fail 'absent returned failure'
expect_heal absent

STATE_SEQUENCE='live'; reset_case
merv_mac_maybe_trigger_heal_on_precondition_fail || fail 'live returned failure'
expect_no_heal live

STATE_SEQUENCE='incomplete-grace'; reset_case
merv_mac_maybe_trigger_heal_on_precondition_fail || fail 'grace returned failure'
expect_no_heal incomplete-grace

STATE_SEQUENCE='dead,dead,absent'; reset_case
merv_mac_maybe_trigger_heal_on_precondition_fail || fail 'dead reconciliation returned failure'
[ "$QUARANTINE_CALLS" -eq 1 ] || fail 'dead owner was not quarantined exactly once'
expect_heal dead

STATE_SEQUENCE='reused,reused,absent'; reset_case
merv_mac_maybe_trigger_heal_on_precondition_fail || fail 'reused reconciliation returned failure'
[ "$QUARANTINE_CALLS" -eq 1 ] || fail 'reused owner was not quarantined exactly once'
expect_heal reused

STATE_SEQUENCE='malformed'; reset_case
if merv_mac_maybe_trigger_heal_on_precondition_fail; then fail 'malformed returned success'; fi
expect_no_heal malformed

STATE_SEQUENCE='incomplete-expired'; reset_case
if merv_mac_maybe_trigger_heal_on_precondition_fail; then fail 'expired incomplete returned success'; fi
expect_no_heal incomplete-expired

# A live successor detected during the stale-owner recheck must never be moved.
STATE_SEQUENCE='dead,live'; reset_case
merv_mac_maybe_trigger_heal_on_precondition_fail || fail 'replacement live returned failure'
[ "$QUARANTINE_CALLS" -eq 0 ] || fail 'replacement owner was quarantined'
expect_no_heal replacement-owner

printf 'MAC_PRECONDITION_OWNER_CONTRACT_OK\n'
