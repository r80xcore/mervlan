#!/bin/sh
# Focused local regression coverage for lifecycle lock failure paths.
# This test never contacts a router or AP and uses only an isolated DHCP state
# root plus a preflight-checked observation lock under the test runtime root.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.lifecycle-lock.$$"
umask 077
mkdir -p /tmp/mervlan_tmp || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export TMPDIR="$TEST_ROOT/tmp"
export LOGDIR="$TEST_ROOT/logs"
export FUNCDIR="$BASE_DIR/functions"
export SETTINGSDIR="$BASE_DIR/settings"
export FLAGDIR="$TEST_ROOT/flags"
export LOCKDIR="$TEST_ROOT/locks"
export RESULTDIR="$TEST_ROOT/results"
export CHANGES="$TEST_ROOT/results/vlan_changes"
export COLLECTDIR="$TEST_ROOT/client_collection"
export MERV_MAC_CHAIN=MERV_MAC
export MERV_MAC_DB_ACTIVE="$TEST_ROOT/mac_shield.db"
export MERV_MAC_DB_JFFS="$TEST_ROOT/mac_shield.jffs.db"
export MERV_QT_CHAIN=MERV_QT
export MERV_DHCP_HOLD_CHAIN=MERV_DHCP_HOLD
export MERV_DHCP_HOLD_LEGACY_MARKER="$TEST_ROOT/merv_dhcp_hold.active"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_DHCP_HOLD_TEST_MODE=1
export MERV_DHCP_HOLD_TEST_ROOT="$TEST_ROOT"
export MERV_DHCP_HOLD_STATE_ROOT="$TEST_ROOT/dhcp_hold"
export MERV_DHCP_HOLD_PROC_ROOT=/proc

. "$BASE_DIR/settings/lib_identity.sh" || exit 1
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1

_FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _FAILURES=1; }
pass() { printf 'PASS: %s\n' "$1"; }

# The nonce generator is deliberately made unavailable after mkdir succeeds.
# Acquisition must remove its empty claim; otherwise every later state
# transaction is blocked by a lock that has no authoritative owner fields.
_merv_dhcp_nonce() { return 1; }
merv_dhcp_state_lock_acquire >/dev/null 2>&1
_dhcp_rc=$?
[ "$_dhcp_rc" -eq 2 ] || fail "DHCP nonce failure returns rc=2"
[ ! -e "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" ] ||
  fail "DHCP nonce failure leaves an empty state.lock claim"
[ "$_dhcp_rc" -eq 2 ] && [ ! -e "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" ] &&
  pass dhcp-nonce-failure-cleans-empty-claim

# A generic owner release obstruction removes compatibility sidecars while
# restoring the canonical owner record.  Observation idleness must therefore
# consult owner-v2 state, not only pid/proc_start_time sidecars.
_obs_lock="$LOCKDIR/observation/worker.lock"
if [ -e "$_obs_lock" ]; then
  fail "observation worker lock precondition is not idle"
else
  mkdir -p "${_obs_lock%/*}" || fail observation-lock-parent
  if merv_owner_lock_acquire "$_obs_lock" 0 0 lifecycle-observation; then
    _obs_nonce="$MERV_LOCK_NONCE"
    MERV_OWNER_LOCK_FAULT=release-rmdir
    export MERV_OWNER_LOCK_FAULT
    merv_owner_lock_release "$_obs_lock" "$_obs_nonce" >/dev/null 2>&1
    _obs_release_rc=$?
    unset MERV_OWNER_LOCK_FAULT
    export MERV_OWNER_LOCK_FAULT
    [ "$_obs_release_rc" -ne 0 ] || fail "observation obstruction fixture did not fail release"
    [ -f "$_obs_lock/owner" ] || fail "observation obstruction lost canonical owner"
    [ ! -f "$_obs_lock/pid" ] || fail "observation obstruction retained obsolete pid sidecar"
    merv_observation_wait_idle 0 >/dev/null 2>&1
    _obs_wait_rc=$?
    [ "$_obs_wait_rc" -ne 0 ] || fail "observation wait-idle treats canonical live owner as idle"
    rm -f "$_obs_lock/release-obstruction" 2>/dev/null || :
    merv_owner_lock_release "$_obs_lock" "$_obs_nonce" >/dev/null 2>&1 ||
      fail observation-owner-cleanup
    [ "$_obs_release_rc" -ne 0 ] && [ "$_obs_wait_rc" -ne 0 ] &&
      pass observation-wait-idle-uses-canonical-owner
  else
    fail observation-owner-acquire
  fi
fi

# Canonical dead/reused owners are safe reconciliation candidates: the wait
# may return idle so the acquiring subsystem can quarantine the exact claim.
_obs_now=$(date +%s 2>/dev/null || printf '')
_obs_dead="$LOCKDIR/observation/worker.lock"
mkdir -p "$_obs_dead" || fail observation-dead-lock-parent
merv_owner_v2_write_atomic "$_obs_dead" 999999999 1 dead-owner "$_obs_now" "$_obs_now" ||
  fail observation-dead-owner-write
merv_observation_wait_idle 0 >/dev/null 2>&1
_obs_dead_wait_rc=$?
[ "$_obs_dead_wait_rc" -eq 0 ] || fail "observation dead owner was not offered safe reconciliation"
rm -rf "$_obs_dead" 2>/dev/null || :
[ "$_obs_dead_wait_rc" -eq 0 ] && pass observation-dead-owner-reconciliation

_obs_reused="$LOCKDIR/observation/worker.lock"
mkdir -p "$_obs_reused" || fail observation-reused-lock-parent
_obs_actual_start=$(merv_proc_start_time "$$" /proc 2>/dev/null || printf '')
_obs_reused_start=$((_obs_actual_start + 1))
merv_owner_v2_write_atomic "$_obs_reused" "$$" "$_obs_reused_start" reused-owner "$_obs_now" "$_obs_now" ||
  fail observation-reused-owner-write
merv_observation_wait_idle 0 >/dev/null 2>&1
_obs_reused_wait_rc=$?
[ "$_obs_reused_wait_rc" -eq 0 ] || fail "observation reused owner was not offered safe reconciliation"
rm -rf "$_obs_reused" 2>/dev/null || :
[ "$_obs_reused_wait_rc" -eq 0 ] && pass observation-reused-owner-reconciliation

# A malformed owner and a replacement/live owner remain busy/unknown rather
# than being mistaken for idle.
_obs_bad="$LOCKDIR/observation/worker.lock"
mkdir -p "$_obs_bad" || fail observation-malformed-lock-parent
printf 'not-owner-v2\n' > "$_obs_bad/owner"
merv_observation_wait_idle 0 >/dev/null 2>&1
_obs_bad_wait_rc=$?
[ "$_obs_bad_wait_rc" -ne 0 ] || fail "observation malformed owner was treated as idle"
rm -rf "$_obs_bad" 2>/dev/null || :

_obs_replace="$LOCKDIR/observation/worker.lock"
mkdir -p "$_obs_replace" || fail observation-replacement-lock-parent
merv_owner_v2_write_atomic "$_obs_replace" "$$" "$_obs_actual_start" replacement-owner "$_obs_now" "$_obs_now" ||
  fail observation-replacement-owner-write
merv_observation_wait_idle 0 >/dev/null 2>&1
_obs_replace_wait_rc=$?
[ "$_obs_replace_wait_rc" -ne 0 ] || fail "observation replacement/live owner was treated as idle"
rm -rf "$_obs_replace" 2>/dev/null || :
[ "$_obs_bad_wait_rc" -ne 0 ] && [ "$_obs_replace_wait_rc" -ne 0 ] &&
  pass observation-malformed-and-replacement-owners-fail-closed

if [ "$_FAILURES" -eq 0 ]; then
  printf 'LIFECYCLE_LOCK_CONTRACT_OK\n'
  exit 0
fi
printf 'LIFECYCLE_LOCK_CONTRACT_FAILED\n' >&2
exit 1
