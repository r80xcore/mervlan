#!/bin/sh
# Local-only lifecycle coverage for the live-test guard scheduler handoff.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
GUARD="$ROOT/dev-tools/safety/mervlan_live_test_guard.sh"
TEST_TMP_ROOT=/tmp/mervlan_tmp
mkdir -p "$TEST_TMP_ROOT" || exit 1
WORK=$(mktemp -d "$TEST_TMP_ROOT/mervlan-live-guard.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

ADDON="$WORK/addon"
STATE="$WORK/state"
BIN="$WORK/bin"
CRU_STATE="$WORK/cru.jobs"
GUARD_ROOT="$STATE/guard"
GUARD_EXECUTABLE="$GUARD_ROOT/mervlan_live_test_guard.sh"
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
  'if [ "${FAKE_MANAGER_RC:-0}" -ne 0 ]; then exit 1; fi' \
  ': > "$MERV_STATE_ROOT/manager-called"' >"$ADDON/functions/mervlan_manager.sh"
chmod 755 "$ADDON/functions/mervlan_manager.sh"

# Minimal cru model. Delete removes the job without creating any local state;
# add can be failed to prove an arm never leaves an armed marker behind.
printf '%s\n' \
  '#!/bin/sh' \
  'case "${1:-}" in' \
  '  d) [ "${CRU_DELETE_FAIL:-0}" = 1 ] && exit 1; rm -f "$CRU_STATE" ;;' \
  '  a) [ "${CRU_ADD_FAIL:-0}" = 1 ] && exit 1; printf "%s\\n" "${3:-}" > "$CRU_STATE" ;;' \
  '  l) [ -f "$CRU_STATE" ] && cat "$CRU_STATE" ;;' \
  '  *) exit 1 ;;' \
  'esac' >"$BIN/cru"
chmod 755 "$BIN/cru"

REAL_MV=$(command -v mv) || fail could-not-find-real-mv
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${FAKE_MV_FAIL_ARMED:-0}" = 1 ] && [ "${1:-}" = "$MERV_LIVE_TEST_GUARD_ROOT/armed" ]; then exit 1; fi' \
  "exec \"$REAL_MV\" \"\$@\"" >"$BIN/mv"
chmod 755 "$BIN/mv"

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

# A staged executable must stay under the guard root and use only safe cron
# pathname characters. Rejections must not touch an unrelated sentinel or
# create any durable guard/scheduler state.
SENTINEL="$STATE/unrelated/sentinel"
mkdir -p "${SENTINEL%/*}"
printf 'keep-me\n' >"$SENTINEL"
GUARD_EXECUTABLE="$SENTINEL"; export GUARD_EXECUTABLE MERV_LIVE_TEST_GUARD_EXECUTABLE="$GUARD_EXECUTABLE"
if run_guard arm 30 >"$WORK/unsafe-outside-root.out" 2>&1; then
  fail unsafe-outside-root-accepted
fi
grep -Fqx 'keep-me' "$SENTINEL" || fail unsafe-path-overwrote-sentinel
[ ! -e "$GUARD_ROOT/armed" ] || fail unsafe-outside-root-left-armed
[ ! -e "$CRU_STATE" ] || fail unsafe-outside-root-left-scheduler
pass unsafe-outside-root-rejected-without-cleanup

GUARD_EXECUTABLE="$GUARD_ROOT/bad path;touch $STATE/injected"; export GUARD_EXECUTABLE MERV_LIVE_TEST_GUARD_EXECUTABLE="$GUARD_EXECUTABLE"
if run_guard arm 30 >"$WORK/unsafe-characters.out" 2>&1; then
  fail unsafe-shell-characters-accepted
fi
[ ! -e "$STATE/injected" ] || fail unsafe-path-executed-command
[ ! -e "$GUARD_ROOT/armed" ] || fail unsafe-shell-characters-left-armed
[ ! -e "$CRU_STATE" ] || fail unsafe-shell-characters-left-scheduler
pass unsafe-shell-characters-rejected

GUARD_EXECUTABLE="$GUARD_ROOT/mervlan_live_test_guard.sh"; export GUARD_EXECUTABLE MERV_LIVE_TEST_GUARD_EXECUTABLE="$GUARD_EXECUTABLE"
run_guard arm 30 >"$WORK/arm.out" || fail arm
[ -f "$GUARD_ROOT/armed" ] || fail armed-marker
[ -x "$GUARD_EXECUTABLE" ] || fail staged-executable
grep -Fq "sh $GUARD_EXECUTABLE expire" "$CRU_STATE" || fail stable-scheduler-target
! grep -Fq "$ADDON" "$CRU_STATE" || fail scheduler-target-inside-addon
pass arm-stages-stable-executable

# A durable disarm claim must succeed before a scheduler deletion is attempted.
FAKE_MV_FAIL_ARMED=1; export FAKE_MV_FAIL_ARMED
if run_guard disarm >"$WORK/disarm-claim-failure.out" 2>&1; then
  fail disarm-claim-failure-accepted
fi
[ -f "$GUARD_ROOT/armed" ] || fail disarm-claim-failure-lost-armed
[ -e "$CRU_STATE" ] || fail disarm-claim-failure-lost-scheduler
[ -e "$GUARD_EXECUTABLE" ] || fail disarm-claim-failure-lost-executable
pass disarm-claim-failure-keeps-recovery-installed
FAKE_MV_FAIL_ARMED=0; export FAKE_MV_FAIL_ARMED

# If scheduler cleanup fails after the durable transition, retain the staged
# executable so a later stale cron invocation can retry cleanup.
CRU_DELETE_FAIL=1; export CRU_DELETE_FAIL
if run_guard disarm >"$WORK/disarm-scheduler-failure.out" 2>&1; then
  fail disarm-scheduler-failure-accepted
fi
[ ! -f "$GUARD_ROOT/armed" ] || fail disarm-scheduler-failure-left-armed
[ -e "$CRU_STATE" ] || fail disarm-scheduler-failure-lost-scheduler
[ -e "$GUARD_EXECUTABLE" ] || fail disarm-scheduler-failure-lost-executable
run_guard status | grep -Fqx 'armed=no' || fail disarm-scheduler-failure-reported-armed
pass disarm-scheduler-failure-retains-retry-target
CRU_DELETE_FAIL=0; export CRU_DELETE_FAIL
run_guard disarm | grep -Fqx 'armed=no' || fail disarm-retry-cleanup
[ ! -e "$CRU_STATE" ] || fail disarm-retry-left-scheduler
[ ! -e "$GUARD_EXECUTABLE" ] || fail disarm-retry-left-executable
pass disarm-stale-scheduler-retries-cleanup

# Remove the replaceable addon developer tree before expiry. The staged target
# must still perform recovery and clean its scheduler after the transition.
run_guard arm 30 >"$WORK/arm-successful-expiry.out" || fail rearm-successful-expiry
rm -rf "$ADDON/dev-tools"
sed -i 's/^deadline_epoch=.*/deadline_epoch=0/' "$GUARD_ROOT/armed"
FAKE_MANAGER_RC=0; export FAKE_MANAGER_RC
rm -f "$STATE/manager-called"
sh "$GUARD_EXECUTABLE" expire || fail successful-expiry
[ ! -f "$GUARD_ROOT/armed" ] || fail success-left-armed
[ ! -e "$CRU_STATE" ] || fail success-left-scheduler
[ ! -e "$GUARD_EXECUTABLE" ] || fail success-left-executable
[ -f "$STATE/manager-called" ] || fail success-manager-not-called
grep -R -Fq 'event=recovery-succeeded' "$GUARD_ROOT/history" || fail success-history
pass expiry-survives-addon-replacement-and-cleans-up

# Expiry also keeps its staged executable when scheduler deletion fails. A
# subsequent stale invocation must retain it while deletion still fails, then
# remove it once scheduler cleanup succeeds.
run_guard arm 30 >"$WORK/arm-expiry-scheduler-failure.out" || fail rearm-expiry-scheduler-failure
sed -i 's/^deadline_epoch=.*/deadline_epoch=0/' "$GUARD_ROOT/armed"
rm -f "$STATE/manager-called"
CRU_DELETE_FAIL=1; export CRU_DELETE_FAIL
sh "$GUARD_EXECUTABLE" expire || fail expiry-scheduler-failure-recovery
[ ! -f "$GUARD_ROOT/armed" ] || fail expiry-scheduler-failure-left-armed
[ -e "$CRU_STATE" ] || fail expiry-scheduler-failure-lost-scheduler
[ -e "$GUARD_EXECUTABLE" ] || fail expiry-scheduler-failure-lost-executable
[ -f "$STATE/manager-called" ] || fail expiry-scheduler-failure-skipped-recovery
if sh "$GUARD_EXECUTABLE" expire >"$WORK/unarmed-expiry-scheduler-failure.out" 2>&1; then
  fail unarmed-expiry-scheduler-failure-accepted
fi
[ -e "$GUARD_EXECUTABLE" ] || fail unarmed-expiry-scheduler-failure-lost-executable
CRU_DELETE_FAIL=0; export CRU_DELETE_FAIL
sh "$GUARD_EXECUTABLE" expire || fail expiry-scheduler-retry
[ ! -e "$CRU_STATE" ] || fail expiry-scheduler-retry-left-scheduler
[ ! -e "$GUARD_EXECUTABLE" ] || fail expiry-scheduler-retry-left-executable
pass expiry-scheduler-failure-retains-and-retries-cleanup

# An expiry claim failure must not report recovery as completed or remove the
# only runnable scheduler/executable pair.
run_guard arm 30 >"$WORK/arm-expiry-claim-failure.out" || fail rearm-expiry-claim-failure
sed -i 's/^deadline_epoch=.*/deadline_epoch=0/' "$GUARD_ROOT/armed"
rm -f "$STATE/manager-called"
FAKE_MV_FAIL_ARMED=1; export FAKE_MV_FAIL_ARMED
if sh "$GUARD_EXECUTABLE" expire >"$WORK/expiry-claim-failure.out" 2>&1; then
  fail expiry-claim-failure-accepted
fi
FAKE_MV_FAIL_ARMED=0; export FAKE_MV_FAIL_ARMED
[ -f "$GUARD_ROOT/armed" ] || fail expiry-claim-failure-lost-armed
[ -e "$CRU_STATE" ] || fail expiry-claim-failure-lost-scheduler
[ -e "$GUARD_EXECUTABLE" ] || fail expiry-claim-failure-lost-executable
[ ! -e "$STATE/manager-called" ] || fail expiry-claim-failure-ran-recovery
pass expiry-claim-failure-keeps-recovery-installed

# Retry the stale scheduler path after the claim failure; recovery and cleanup
# should proceed normally once the durable transition can be claimed.
FAKE_MANAGER_RC=0; export FAKE_MANAGER_RC
sh "$GUARD_EXECUTABLE" expire || fail expiry-claim-retry
[ ! -f "$GUARD_ROOT/armed" ] || fail expiry-claim-retry-left-armed
[ ! -e "$CRU_STATE" ] || fail expiry-claim-retry-left-scheduler
[ ! -e "$GUARD_EXECUTABLE" ] || fail expiry-claim-retry-left-executable
pass expiry-claim-retry-cleans-up

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
