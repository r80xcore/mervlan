#!/bin/sh
# Local-only lifecycle coverage for the live-test guard scheduler handoff.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
GUARD="$ROOT/dev-tools/safety/mervlan_live_test_guard.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-live-guard.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

ADDON="$WORK/addon"
STATE="$WORK/state"
BIN="$WORK/bin"
CRU_STATE="$WORK/cru.jobs"
GUARD_ROOT="$STATE/guard"
GUARD_EXECUTABLE="$STATE/scheduler/mervlan_live_test_guard.sh"
mkdir -p "$ADDON/settings" "$ADDON/functions" "$BIN" "$STATE"

printf '%s\n' \
  'LOCKDIR="$MERV_STATE_ROOT/locks"' \
  'MERV_DHCP_HOLD_STATE_ROOT="$MERV_STATE_ROOT/dhcp"' >"$ADDON/settings/var_settings.sh"
printf '%s\n' \
  'info() { :; }' \
  'warn() { :; }' \
  'error() { :; }' >"$ADDON/settings/log_settings.sh"
printf '%s\n' \
  'MERV_DHCP_HOLD_LEGACY_MARKER="$MERV_STATE_ROOT/legacy-hold"' \
  'merv_dhcp_hold_reconcile() { [ "${FAKE_MANAGER_RC:-0}" -eq 0 ]; }' \
  'merv_dhcp_hold_rules_absent() { [ ! -e "$MERV_STATE_ROOT/hold-rules" ]; }' \
  'merv_dhcp_hold_arm() { : > "$MERV_STATE_ROOT/hold-rules"; return 0; }' \
  'merv_dhcp_hold_rules_remove() { rm -f "$MERV_STATE_ROOT/hold-rules"; return 0; }' >"$ADDON/settings/lib_mervqt.sh"
printf '%s\n' \
  '#!/bin/sh' \
  '[ "${FAKE_MANAGER_RC:-0}" -eq 0 ]' >"$ADDON/functions/mervlan_manager.sh"
chmod 755 "$ADDON/functions/mervlan_manager.sh"

# Minimal cru model. Delete removes the job without creating any local state;
# add can be failed to prove an arm never leaves an armed marker behind.
printf '%s\n' \
  '#!/bin/sh' \
  'case "${1:-}" in' \
  '  d) rm -f "$CRU_STATE" ;;' \
  '  a) [ "${CRU_ADD_FAIL:-0}" = 1 ] && exit 1; printf "%s\\n" "${3:-}" > "$CRU_STATE" ;;' \
  '  l) [ -f "$CRU_STATE" ] && cat "$CRU_STATE" ;;' \
  '  *) exit 1 ;;' \
  'esac' >"$BIN/cru"
chmod 755 "$BIN/cru"

export PATH="$BIN:$PATH"
export MERV_BASE="$ADDON"
export MERV_STATE_ROOT="$STATE"
export MERV_DHCP_HOLD_STATE_ROOT="$STATE/dhcp"
export DEV_TOOLS_ROOT="$ROOT/dev-tools"
export LIVE_TEST_GUARD_SCRIPT="$GUARD"
export MERV_LIVE_TEST_GUARD_ROOT="$GUARD_ROOT"
export MERV_LIVE_TEST_GUARD_EXECUTABLE="$GUARD_EXECUTABLE"
export MERV_LIVE_TEST_GUARD_CRON_NAME=MerVLANLiveTestGuardTest
export CRU_STATE

run_guard() { sh "$GUARD" "$@"; }

# Status, disarm, and expiry before an arm must be observational and leave no
# guard state behind.
[ ! -e "$GUARD_ROOT" ] || fail unarmed-initial-state
run_guard status | grep -Fqx 'armed=no' || fail unarmed-status
[ ! -e "$GUARD_ROOT" ] || fail status-created-state
run_guard disarm | grep -Fqx 'armed=no' || fail unarmed-disarm
run_guard expire || fail unarmed-expire
[ ! -e "$GUARD_ROOT" ] || fail unarmed-actions-created-state
pass unarmed-actions-create-no-state

run_guard arm 30 >"$WORK/arm.out" || fail arm
[ -f "$GUARD_ROOT/armed" ] || fail armed-marker
[ -x "$GUARD_EXECUTABLE" ] || fail staged-executable
grep -Fq "sh $GUARD_EXECUTABLE expire" "$CRU_STATE" || fail stable-scheduler-target
! grep -Fq "$ADDON" "$CRU_STATE" || fail scheduler-target-inside-addon
pass arm-stages-stable-executable

# Remove the replaceable addon developer tree before expiry. The staged target
# must still perform recovery and clean its scheduler after the transition.
rm -rf "$ADDON/dev-tools"
sed -i 's/^deadline_epoch=.*/deadline_epoch=0/' "$GUARD_ROOT/armed"
FAKE_MANAGER_RC=0; export FAKE_MANAGER_RC
sh "$GUARD_EXECUTABLE" expire || fail successful-expiry
[ ! -f "$GUARD_ROOT/armed" ] || fail success-left-armed
[ ! -e "$CRU_STATE" ] || fail success-left-scheduler
[ ! -e "$GUARD_EXECUTABLE" ] || fail success-left-executable
grep -R -Fq 'event=recovery-succeeded' "$GUARD_ROOT/history" || fail success-history
pass expiry-survives-addon-replacement-and-cleans-up

run_guard arm 30 >"$WORK/arm-failure.out" || fail rearm
sed -i 's/^deadline_epoch=.*/deadline_epoch=0/' "$GUARD_ROOT/armed"
FAKE_MANAGER_RC=1; export FAKE_MANAGER_RC
sh "$GUARD_EXECUTABLE" expire && fail failed-expiry-accepted
[ ! -f "$GUARD_ROOT/armed" ] || fail failure-left-armed
[ ! -e "$CRU_STATE" ] || fail failure-left-scheduler
[ ! -e "$GUARD_EXECUTABLE" ] || fail failure-left-executable
[ -f "$MERV_DHCP_HOLD_STATE_ROOT/recovery.pending" ] || fail recovery-not-queued
grep -R -Fq 'event=recovery-failed' "$GUARD_ROOT/history" || fail failure-history
pass expiry-failure-queues-fail-closed-recovery

FAKE_MANAGER_RC=0; export FAKE_MANAGER_RC
run_guard arm 30 >"$WORK/arm-disarm.out" || fail rearm-disarm
run_guard disarm | grep -Fqx 'armed=no' || fail disarm
[ ! -f "$GUARD_ROOT/armed" ] && [ ! -e "$CRU_STATE" ] &&
  [ ! -e "$GUARD_EXECUTABLE" ] || fail disarm-cleanup
grep -R -Fq 'event=disarmed' "$GUARD_ROOT/history" || fail disarm-history
pass disarm-cleans-stable-target-and-scheduler

rm -rf "$GUARD_ROOT" "$STATE/scheduler" "$CRU_STATE"
CRU_ADD_FAIL=1; export CRU_ADD_FAIL
if run_guard arm 30 >"$WORK/arm-scheduler-failure.out" 2>&1; then
  fail scheduler-failure-accepted
fi
[ ! -e "$GUARD_ROOT" ] || fail scheduler-failure-left-state
[ ! -e "$GUARD_EXECUTABLE" ] || fail scheduler-failure-left-executable
pass scheduler-failure-leaves-unarmed-no-state

printf 'LIVE_TEST_GUARD_LIFECYCLE_CONTRACT_OK\n'
