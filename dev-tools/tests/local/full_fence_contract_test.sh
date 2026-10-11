#!/bin/sh
# Isolated contract coverage for canonical ownership controls and the
# absent-only Full admission fence.

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.full-fence.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
chmod 700 "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

export MERV_BASE="$BASE_DIR"
. "$BASE_DIR/settings/lib_selftest_context.sh" || fail context-library
merv_selftest_context_create "$TEST_ROOT" || fail context-create

# Ambient values do not redirect production, even when TEST_RUN and fake
# paths are also set. The explicit private context is absent in this child.
if sh -c '
  MERV_BASE="$1"
  MERVLAN_SELFTEST_CONTEXT=
  TEST_RUN=1
  MERV_OWNER_LOCK_PROC_ROOT="$2/fake-proc"
  MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=0
  MERV_OWNER_LOCK_FAULT=identity
  MERV_ACTION_LOCK_PATH="$2/fake-action.lock"
  MERV_ACTION_LOCK_PROC_ROOT="$2/fake-proc"
  MERV_UPDATE_MAINTENANCE_LOCK="$2/fake-maintenance.lock"
  export MERVLAN_SELFTEST_CONTEXT TEST_RUN MERV_OWNER_LOCK_PROC_ROOT \
    MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC MERV_OWNER_LOCK_FAULT \
    MERV_ACTION_LOCK_PATH MERV_ACTION_LOCK_PROC_ROOT MERV_UPDATE_MAINTENANCE_LOCK
  . "$MERV_BASE/settings/lib_owner_lock.sh" || exit 1
  [ "$MERV_OWNER_LOCK_PROC_ROOT" = /proc ] || exit 2
  [ "$MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC" = 10 ] || exit 3
  [ -z "${MERV_OWNER_LOCK_FAULT:-}" ] || exit 4
  . "$MERV_BASE/settings/lib_action_lock.sh" || exit 5
  [ "$MERV_ACTION_LOCK_PATH" = /tmp/mervlan_tmp/locks/mervlan_action.lock ] || exit 6
  [ "$MERV_ACTION_LOCK_PROC_ROOT" = /proc ] || exit 7
  . "$MERV_BASE/settings/lib_update_state.sh" || exit 8
  [ "$(merv_update_maintenance_lock_path)" = /tmp/mervlan_tmp/locks/mervlan_maintenance.lock ] || exit 9
' sh "$BASE_DIR" "$TEST_ROOT"; then
  pass 'production owner, action, proc, grace, and maintenance paths are canonical'
else
  fail 'production canonicalization'
fi

if sh -c '
  MERV_BASE="$1"
  MERVLAN_SELFTEST_CONTEXT=
  TEST_RUN=1
  MERV_DHCP_HOLD_TEST_MODE=1
  MERV_DHCP_HOLD_TEST_ROOT="$2"
  MERV_DHCP_HOLD_STATE_ROOT="$2/fake-dhcp"
  MERV_DHCP_HOLD_LEGACY_MARKER="$2/fake-legacy"
  MERV_DHCP_HOLD_PROC_ROOT="$2/fake-proc"
  MERV_DHCP_HOLD_EBTABLES="$2/fake-ebtables"
  MERV_DHCP_HOLD_FAULT_POINT=unit
  MERV_DHCP_HOLD_FAULT_ACTION=kill
  export MERVLAN_SELFTEST_CONTEXT TEST_RUN MERV_DHCP_HOLD_TEST_MODE \
    MERV_DHCP_HOLD_TEST_ROOT MERV_DHCP_HOLD_STATE_ROOT \
    MERV_DHCP_HOLD_LEGACY_MARKER MERV_DHCP_HOLD_PROC_ROOT \
    MERV_DHCP_HOLD_EBTABLES MERV_DHCP_HOLD_FAULT_POINT MERV_DHCP_HOLD_FAULT_ACTION
  . "$MERV_BASE/settings/lib_mervqt.sh" || exit 1
  [ -z "${MERV_DHCP_HOLD_TEST_MODE:-}" ] || exit 2
  [ "$MERV_DHCP_HOLD_STATE_ROOT" = /tmp/mervlan_tmp/locks/dhcp_hold ] || exit 3
  [ "$MERV_DHCP_HOLD_LEGACY_MARKER" = /tmp/mervlan_tmp/locks/merv_dhcp_hold.active ] || exit 4
  [ "$MERV_DHCP_HOLD_PROC_ROOT" = /proc ] || exit 5
  [ -z "${MERV_DHCP_HOLD_EBTABLES:-}" ] && [ -z "${MERV_DHCP_HOLD_FAULT_POINT:-}" ] || exit 6
  merv_dhcp_hold_fault_checkpoint unit; [ "$?" -eq 0 ] || exit 7
' sh "$BASE_DIR" "$TEST_ROOT"; then
  pass 'DHCP test roots and fault hooks ignore ambient TEST_RUN and fake paths'
else
  fail 'DHCP test seam production isolation'
fi

if sh -c '
  MERV_BASE="$1"
  MERVLAN_SELFTEST_CONTEXT="$2/.mervlan-selftest-context"
  MERV_DHCP_HOLD_TEST_MODE=1
  MERV_DHCP_HOLD_TEST_ROOT="$2"
  MERV_DHCP_HOLD_STATE_ROOT="$2/fake-dhcp"
  MERV_DHCP_HOLD_PROC_ROOT="$2/fake-proc"
  MERV_DHCP_HOLD_FAULT_POINT=unit
  MERV_DHCP_HOLD_FAULT_ACTION=return
  export MERVLAN_SELFTEST_CONTEXT MERV_DHCP_HOLD_TEST_MODE \
    MERV_DHCP_HOLD_TEST_ROOT MERV_DHCP_HOLD_STATE_ROOT \
    MERV_DHCP_HOLD_PROC_ROOT MERV_DHCP_HOLD_FAULT_POINT MERV_DHCP_HOLD_FAULT_ACTION
  . "$MERV_BASE/settings/lib_mervqt.sh" || exit 1
  merv_dhcp_hold_test_root_valid || exit 2
  [ "$(merv_dhcp_proc_root)" = "$2/fake-proc" ] || exit 3
  merv_dhcp_hold_fault_checkpoint unit >/dev/null 2>&1
  [ "$?" -eq 99 ] || exit 4
' sh "$BASE_DIR" "$TEST_ROOT"; then
  pass 'explicit private context retains bounded DHCP test roots and fault hooks'
else
  fail 'DHCP explicit test seam'
fi

FENCE="$TEST_ROOT/full.lock"
RUNTIME="$TEST_ROOT/mervlan_tmp"
mkdir -p "$RUNTIME/locks" || fail runtime-fixture
MERV_FULL_FENCE_PATH=$FENCE
MERV_OWNER_LOCK_PROC_ROOT=/proc
MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=1
unset MERV_OWNER_LOCK_FAULT
export MERV_FULL_FENCE_PATH MERV_OWNER_LOCK_PROC_ROOT MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC
. "$BASE_DIR/settings/lib_owner_lock.sh" || fail owner-library
. "$BASE_DIR/settings/lib_full_fence.sh" || fail fence-library
[ "$(merv_full_fence_path)" = "$FENCE" ] || fail test-fence-path
[ "$(merv_full_fence_path /tmp/.mervlan-full-uninstall.lock)" = /tmp/.mervlan-full-uninstall.lock ] || fail canonical-fence-path
[ "$(merv_full_fence_classify "$FENCE")" = absent ] || fail absent-classification
pass 'absent fence classifies idle and production path is exact'

merv_full_fence_claim "$FENCE" || fail absent-claim
[ "$(merv_full_fence_mode "$FENCE")" = drwx------ ] || fail fence-mode
[ "$(merv_full_fence_mode "$FENCE/owner")" = -rw------- ] || fail owner-mode
[ "$(merv_full_fence_classify "$FENCE")" = live ] || fail live-classification
if merv_full_fence_claim "$FENCE"; then fail 'existing live fence was reclaimed'; fi
pass 'claim is atomic, private, and live fences block'

# A foreign replacement is never released by the prior owner's tuple.
cp "$FENCE/owner" "$TEST_ROOT/owner.saved" || fail owner-save
_ff_start=$(merv_identity_current_start /proc) || fail owner-start
_ff_now=$(merv_owner_lock_now) || fail owner-now
merv_owner_v2_write_atomic "$FENCE" "$$" "$_ff_start" foreign."$_ff_now" \
  "$_ff_now" "$_ff_now" || fail foreign-owner-write
if merv_full_fence_release "$FENCE" "$MERV_FULL_FENCE_PID" \
  "$MERV_FULL_FENCE_START" "$MERV_FULL_FENCE_NONCE"; then
  fail 'foreign replacement fence was released'
fi
[ -d "$FENCE" ] || fail foreign-fence-removed
cp "$TEST_ROOT/owner.saved" "$FENCE/owner" || fail owner-restore
pass 'foreign owner replacement remains fenced'

rm -rf "$RUNTIME" || fail runtime-root-delete
[ "$(merv_full_fence_classify "$FENCE")" = live ] || fail fence-after-runtime-delete
[ -d "$FENCE" ] || fail fence-lost-after-runtime-delete
pass 'fence remains authoritative after runtime-root deletion'

merv_full_fence_release "$FENCE" "$MERV_FULL_FENCE_PID" \
  "$MERV_FULL_FENCE_START" "$MERV_FULL_FENCE_NONCE" || fail exact-release
[ "$(merv_full_fence_classify "$FENCE")" = absent ] || fail release-state
pass 'exact owner release removes only the private fence'

# Every pre-existing claim blocks, including owners that are safely classified
# dead or PID-reused by the ordinary lock classifier.
_ff_now=$(merv_owner_lock_now) || fail dead-now
mkdir "$FENCE" || fail dead-dir
chmod 700 "$FENCE" || fail dead-mode
merv_owner_v2_write_atomic "$FENCE" 999999999 1 dead.owner "$_ff_now" \
  "$_ff_now" || fail dead-record
[ "$(merv_full_fence_classify "$FENCE")" = dead ] || fail dead-state
if merv_full_fence_claim "$FENCE"; then fail 'dead fence was reclaimed'; fi
pass 'dead fence blocks and is never automatically reclaimed'
rm -rf "$FENCE"

_ff_current=$(merv_identity_current_start /proc) || fail reused-current
if [ "$_ff_current" = 1 ]; then _ff_reused_start=2; else _ff_reused_start=1; fi
mkdir "$FENCE" || fail reused-dir
chmod 700 "$FENCE" || fail reused-mode
merv_owner_v2_write_atomic "$FENCE" "$$" "$_ff_reused_start" reused.owner \
  "$_ff_now" "$_ff_now" || fail reused-record
[ "$(merv_full_fence_classify "$FENCE")" = reused ] || fail reused-state
if merv_full_fence_claim "$FENCE"; then fail 'reused fence was reclaimed'; fi
pass 'PID-reused fence blocks and is never automatically reclaimed'
rm -rf "$FENCE"

mkdir "$FENCE" || fail partial-dir
chmod 700 "$FENCE" || fail partial-mode
[ "$(merv_full_fence_classify "$FENCE")" = incomplete-grace ] || fail incomplete-grace
sleep 2
[ "$(merv_full_fence_classify "$FENCE")" = incomplete-expired ] || fail incomplete-expired
if merv_full_fence_claim "$FENCE"; then fail 'incomplete fence was reclaimed'; fi
pass 'incomplete fence blocks both within and beyond publication grace'
rm -rf "$FENCE"

mkdir "$FENCE" || fail malformed-dir
chmod 700 "$FENCE" || fail malformed-mode
printf '%s\n' 'pid=bad' > "$FENCE/owner"
chmod 600 "$FENCE/owner"
[ "$(merv_full_fence_classify "$FENCE")" = malformed ] || fail malformed-state
if merv_full_fence_claim "$FENCE"; then fail 'malformed fence was reclaimed'; fi
pass 'malformed fence blocks'
rm -rf "$FENCE"

ln -s "$TEST_ROOT/missing" "$FENCE" || fail symlink-create
[ "$(merv_full_fence_classify "$FENCE")" = obstructed ] || fail symlink-state
if merv_full_fence_claim "$FENCE"; then fail 'symlink obstruction was claimed'; fi
rm -f "$FENCE"
printf '%s\n' obstruction > "$FENCE"
[ "$(merv_full_fence_classify "$FENCE")" = obstructed ] || fail file-state
if merv_full_fence_claim "$FENCE"; then fail 'regular-file obstruction was claimed'; fi
rm -f "$FENCE"
pass 'symlink and regular-file obstructions block without following'

mkdir "$FENCE" || fail unreadable-dir
chmod 700 "$FENCE" || fail unreadable-mode
: > "$FENCE/owner"
chmod 600 "$FENCE/owner"
MERV_FULL_FENCE_FAULT=owner-unreadable
export MERV_FULL_FENCE_FAULT
[ "$(merv_full_fence_classify "$FENCE")" = unreadable ] || fail unreadable-state
MERV_FULL_FENCE_FAULT=path-unobservable
[ "$(merv_full_fence_classify "$FENCE")" = unobservable ] || fail unobservable-state
if merv_full_fence_claim "$FENCE"; then fail 'unobservable fence was claimed'; fi
unset MERV_FULL_FENCE_FAULT
pass 'unreadable and unobservable states block'

printf '%s\n' 'FULL_FENCE_CONTRACT_OK'
