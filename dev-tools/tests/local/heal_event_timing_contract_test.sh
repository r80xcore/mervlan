#!/bin/sh
# Focused deterministic contracts for heal_event.sh wall-clock timing,
# structural restart detection, cache refresh, and EXIT cleanup ownership.
# No router, bridge, ebtables, or live service state is touched.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.heal-event-timing.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}
pass() {
  printf 'PASS: %s\n' "$1"
}

extract_function() {
  _eft_name="$1"
  _eft_source="$2"
  _eft_destination="$3"
  awk -v function_name="$_eft_name" '
    function brace_delta(line, opens, closes) {
      opens = line
      gsub(/[^\{]/, "", opens)
      closes = line
      gsub(/[^\}]/, "", closes)
      return length(opens) - length(closes)
    }
    { sub(/\r$/, "") }
    !active && $0 ~ ("^" function_name "\\()[[:space:]]*\\{") {
      active=1
    }
    active {
      print
      depth += brace_delta($0)
      if (depth == 0) exit
    }
  ' "$_eft_source" > "$_eft_destination" || return 1
  [ -s "$_eft_destination" ]
}

FUNCTIONS="$TEST_ROOT/heal_functions.sh"
: > "$FUNCTIONS" || exit 1
for _entry in \
  'heal_cleanup_on_exit heal_cleanup_on_exit' \
  'heal_wall_clock_now heal_wall_clock_now' \
  'heal_rc_busy heal_rc_busy' \
  'heal_guard_tick heal_guard_tick' \
  'heal_refresh_iface_vid_state heal_refresh_iface_vid_state' \
  'heal_qt_structure_teardown_observed heal_qt_structure_teardown_observed' \
  'heal_wireless_preentry_wait heal_wireless_preentry_wait' \
  'heal_protected_wait heal_protected_wait' \
  'wait_for_rc_quiet wait_for_rc_quiet'; do
  _name=${_entry%% *}
  _part="$TEST_ROOT/$_name.part"
  extract_function "$_name" "$BASE_DIR/functions/heal_event.sh" "$_part" || {
    printf 'FAIL: could not extract %s\n' "$_name" >&2
    exit 1
  }
  cat "$_part" >> "$FUNCTIONS" || exit 1
done
. "$FUNCTIONS" || exit 1

MERV_QT_CHAIN=MERV_QT
LOCK="$TEST_ROOT/vlan_event.lock"
HEAL_LOCK_NONCE=fixture-lock
HEAL_EXIT_REASON=fixture
export MERV_QT_CHAIN LOCK HEAL_LOCK_NONCE HEAL_EXIT_REASON

MOCK_NOW=100
MOCK_GUARD_DURATION=1
MOCK_GUARD_RC=0
MOCK_GUARD_COUNT=0
MOCK_SLEEP_COUNT=0
MOCK_SLEEP_BEFORE_FIRST_REFRESH=0
MOCK_RC_MODE=idle
MOCK_BUSY_UNTIL=0
MOCK_BUSY_AGAIN_START=0
MOCK_BUSY_AGAIN_END=0
MOCK_DUMP_MODE=valid
MOCK_DUMP_CALLS=0
MOCK_CACHE_INVALIDATIONS=0
MOCK_NVRAM_INVALIDATIONS=0
MOCK_CACHE_DISABLE_COUNT=0
MOCK_CACHE_DISABLE_RC=0
MOCK_PRE_ENSURE_COUNT=0
MOCK_PRE_ENSURE_DURATION=0
MOCK_PRE_ENSURE_RC=0
MOCK_TIME_FAIL=0
MOCK_TIME_VALUE=""
MOCK_LAST_INFO=""
MOCK_ALL_INFO=""
MOCK_LAST_WARN=""
MOCK_ALL_WARN=""
HEAL_IFACE_VID_CACHE_ENABLED=1
HEAL_DHCP_TOKEN=fixture-token
HEAL_LOCK_ACQUIRED=1

heal_wall_clock_now() {
  if [ "$MOCK_TIME_FAIL" -ne 0 ]; then
    return 1
  fi
  if [ -n "$MOCK_TIME_VALUE" ]; then
    printf '%s\n' "$MOCK_TIME_VALUE"
    return 0
  fi
  printf '%s\n' "$MOCK_NOW"
}

mock_rc_busy() {
  case "$MOCK_RC_MODE" in
    always)
      return 0
      ;;
    until)
      [ "$MOCK_NOW" -lt "$MOCK_BUSY_UNTIL" ]
      ;;
    cycle)
      if [ "$MOCK_NOW" -lt 102 ]; then
        return 0
      fi
      if [ "$MOCK_NOW" -ge "$MOCK_BUSY_AGAIN_START" ] &&
         [ "$MOCK_NOW" -lt "$MOCK_BUSY_AGAIN_END" ]; then
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}
rc_queue_has() { mock_rc_busy; }
rc_proc_busy() { mock_rc_busy; }

heal_guard_tick() {
  MOCK_GUARD_COUNT=$((MOCK_GUARD_COUNT + 1))
  if [ "$MOCK_GUARD_RC" -ne 0 ]; then
    return "$MOCK_GUARD_RC"
  fi
  MOCK_NOW=$((MOCK_NOW + MOCK_GUARD_DURATION))
  return 0
}

sleep() {
  if [ "$MOCK_CACHE_INVALIDATIONS" -eq 0 ]; then
    MOCK_SLEEP_BEFORE_FIRST_REFRESH=1
  fi
  MOCK_SLEEP_COUNT=$((MOCK_SLEEP_COUNT + 1))
  MOCK_NOW=$((MOCK_NOW + 1))
}

merv_qt_ensure_expected_rules() {
  MOCK_PRE_ENSURE_COUNT=$((MOCK_PRE_ENSURE_COUNT + 1))
  MOCK_NOW=$((MOCK_NOW + MOCK_PRE_ENSURE_DURATION))
  return "$MOCK_PRE_ENSURE_RC"
}

_merv_ebtables_get_dump() {
  MOCK_DUMP_CALLS=$((MOCK_DUMP_CALLS + 1))
  _dump_count=0
  [ -f "$TEST_ROOT/dump.calls" ] && _dump_count=$(cat "$TEST_ROOT/dump.calls")
  _dump_count=$((_dump_count + 1))
  printf '%s\n' "$_dump_count" > "$TEST_ROOT/dump.calls"
  case "$MOCK_DUMP_MODE" in
    transition)
      if [ "$_dump_count" -eq 1 ]; then
        printf '%s\n' valid
      else
        printf '%s\n' flushed
      fi
      ;;
    flushed)
      printf '%s\n' flushed
      ;;
    *)
      printf '%s\n' valid
      ;;
  esac
  return 0
}
merv_ebtables_verify_parent_jumps() {
  [ "${1:-}" = valid ]
}

merv_iface_vid_cache_invalidate() {
  MOCK_CACHE_INVALIDATIONS=$((MOCK_CACHE_INVALIDATIONS + 1))
  return 0
}
merv_nvram_inventory_invalidate() {
  MOCK_NVRAM_INVALIDATIONS=$((MOCK_NVRAM_INVALIDATIONS + 1))
  return 0
}
merv_iface_vid_cache_disable() {
  MOCK_CACHE_DISABLE_COUNT=$((MOCK_CACHE_DISABLE_COUNT + 1))
  return "$MOCK_CACHE_DISABLE_RC"
}
merv_dhcp_hold_abandon() { return 0; }
merv_owner_lock_release() { return 0; }

info() {
  shift
  shift
  MOCK_LAST_INFO="$*"
  MOCK_ALL_INFO="${MOCK_ALL_INFO}\n$*"
}
warn() {
  shift
  shift
  MOCK_LAST_WARN="$*"
  MOCK_ALL_WARN="${MOCK_ALL_WARN}\n$*"
}
error() { :; }

reset_fixture() {
  MOCK_NOW=100
  MOCK_GUARD_DURATION=1
  MOCK_GUARD_RC=0
  MOCK_GUARD_COUNT=0
  MOCK_SLEEP_COUNT=0
  MOCK_SLEEP_BEFORE_FIRST_REFRESH=0
  MOCK_RC_MODE=idle
  MOCK_BUSY_UNTIL=0
  MOCK_BUSY_AGAIN_START=0
  MOCK_BUSY_AGAIN_END=0
  MOCK_DUMP_MODE=valid
  MOCK_DUMP_CALLS=0
  : > "$TEST_ROOT/dump.calls"
  MOCK_CACHE_INVALIDATIONS=0
  MOCK_NVRAM_INVALIDATIONS=0
  MOCK_CACHE_DISABLE_COUNT=0
  MOCK_CACHE_DISABLE_RC=0
  MOCK_PRE_ENSURE_COUNT=0
  MOCK_PRE_ENSURE_DURATION=0
  MOCK_PRE_ENSURE_RC=0
  MOCK_TIME_FAIL=0
  MOCK_TIME_VALUE=""
  MOCK_LAST_INFO=""
  MOCK_ALL_INFO=""
  MOCK_LAST_WARN=""
  MOCK_ALL_WARN=""
  HEAL_IFACE_VID_CACHE_ENABLED=1
  HEAL_DHCP_TOKEN=fixture-token
  HEAL_LOCK_ACQUIRED=1
  HEAL_LOCK_NONCE=fixture-lock
}

run_fixture() {
  "$@" >"$TEST_ROOT/current.out" 2>&1
  RUN_RC=$?
}

assert_eq() {
  _label="$1"
  _expected="$2"
  _actual="$3"
  if [ "$_actual" != "$_expected" ]; then
    fail "$_label (expected=$_expected actual=$_actual)"
    return 1
  fi
  return 0
}

# 1. A slow guard cannot turn the five-second pre-entry budget into 50 slow
# iterations; one in-flight guard is the only allowed overrun.
reset_fixture
MOCK_GUARD_DURATION=2
run_fixture heal_wireless_preentry_wait 5
if [ "$RUN_RC" -eq 0 ] && [ "$MOCK_GUARD_COUNT" -eq 2 ] &&
   [ "$MOCK_NOW" -eq 105 ] && [ "$MOCK_SLEEP_COUNT" -eq 1 ]; then
  pass "pre-entry uses a five-second wall-clock deadline with slow guard work"
else
  fail "pre-entry deadline expanded with guard runtime (rc=$RUN_RC now=$MOCK_NOW guards=$MOCK_GUARD_COUNT sleeps=$MOCK_SLEEP_COUNT)"
fi

# 2. Quiet success is based on elapsed seconds, not a number of completed
# guard calls; the first idle observation refreshes the post-RC mapping.
reset_fixture
MOCK_GUARD_DURATION=3
run_fixture wait_for_rc_quiet 6 120
if [ "$RUN_RC" -eq 0 ] && [ "$MOCK_CACHE_INVALIDATIONS" -eq 1 ] &&
   [ "$MOCK_GUARD_COUNT" -eq 3 ] &&
   case "$MOCK_ALL_INFO" in *"rc quiet for "*"s; proceeding"*) true ;; *) false ;; esac; then
  pass "RC quiet success uses actual wall-clock quiet time"
else
  fail "RC quiet success did not follow wall-clock semantics (rc=$RUN_RC now=$MOCK_NOW guards=$MOCK_GUARD_COUNT invalidations=$MOCK_CACHE_INVALIDATIONS)"
fi

# 3. A slow guard crossing the max deadline cannot be hidden by a tick count;
# active RC still fails closed.
reset_fixture
MOCK_GUARD_DURATION=4
MOCK_RC_MODE=always
run_fixture wait_for_rc_quiet 6 5
if [ "$RUN_RC" -ne 0 ] && [ "$MOCK_GUARD_COUNT" -eq 1 ] &&
   [ "$MOCK_NOW" -eq 105 ] &&
   case "$MOCK_LAST_WARN" in *"while rc remains active; retaining DHCP protection"*) true ;; *) false ;; esac; then
  pass "RC max deadline remains wall-clock bounded across a slow guard"
else
  fail "RC timeout was not bounded by elapsed time (rc=$RUN_RC now=$MOCK_NOW guards=$MOCK_GUARD_COUNT warn=$MOCK_LAST_WARN)"
fi

# 4. Busy->idle invalidates/rebuilds once, then repeated idle polling reuses
# the fresh mapping while the quiet timer runs.
reset_fixture
MOCK_GUARD_DURATION=1
MOCK_RC_MODE=until
MOCK_BUSY_UNTIL=101
run_fixture wait_for_rc_quiet 2 20
if [ "$RUN_RC" -eq 0 ] && [ "$MOCK_CACHE_INVALIDATIONS" -eq 1 ] &&
   [ "$MOCK_SLEEP_BEFORE_FIRST_REFRESH" -eq 0 ] &&
   [ "$MOCK_NOW" -eq 104 ]; then
  pass "busy-to-idle refresh occurs immediately before quiet proof"
else
  fail "busy-to-idle refresh was delayed or repeated (rc=$RUN_RC now=$MOCK_NOW invalidations=$MOCK_CACHE_INVALIDATIONS sleeps-before-refresh=$MOCK_SLEEP_BEFORE_FIRST_REFRESH)"
fi

# 5. A second busy period resets quiet proof and requires a second fresh
# mapping refresh on the next idle transition.
reset_fixture
MOCK_GUARD_DURATION=1
MOCK_RC_MODE=cycle
MOCK_BUSY_AGAIN_START=104
MOCK_BUSY_AGAIN_END=106
run_fixture wait_for_rc_quiet 2 20
if [ "$RUN_RC" -eq 0 ] && [ "$MOCK_CACHE_INVALIDATIONS" -eq 2 ] &&
   [ "$MOCK_NOW" -eq 109 ]; then
  pass "busy-to-idle-to-busy-to-idle refreshes and resets correctly"
else
  fail "second busy transition reused stale mapping (rc=$RUN_RC now=$MOCK_NOW invalidations=$MOCK_CACHE_INVALIDATIONS)"
fi

# 6. The obsolete shield-state side effect is no longer a heal dependency.
if ! grep -Fq '_MERV_QT_SHIELD_STATE' "$BASE_DIR/functions/heal_event.sh" &&
   ! grep -Fq 'TICKS_PER_SEC' "$BASE_DIR/functions/heal_event.sh" &&
   ! grep -Fq 'TICK_CMD' "$BASE_DIR/functions/heal_event.sh"; then
  pass "heal no longer depends on _MERV_QT_SHIELD_STATE or tick counters"
else
  fail "obsolete shield-state or tick-counter dependency remains in heal"
fi

# 7. Structural teardown is a restart signal, while the strict guard still
# executes and performs the actual protection work.
reset_fixture
MOCK_GUARD_DURATION=1
MOCK_DUMP_MODE=transition
run_fixture heal_wireless_preentry_wait 5
if [ "$RUN_RC" -eq 0 ] && [ "$(cat "$TEST_ROOT/dump.calls")" -eq 2 ] &&
   [ "$MOCK_GUARD_COUNT" -eq 2 ] &&
   case "$MOCK_ALL_INFO" in *"structural MERV_QT teardown detected"*) true ;; *) false ;; esac; then
  pass "structural QT teardown triggers detection before strict repair completes"
else
  fail "structural teardown signal did not preserve strict guard work (rc=$RUN_RC dumps=$MOCK_DUMP_CALLS guards=$MOCK_GUARD_COUNT info=$MOCK_ALL_INFO)"
fi

# 8. The three-second protected settle is also wall-clock bounded and does
# not execute ten expensive guards per nominal second.
reset_fixture
MOCK_GUARD_DURATION=2
run_fixture heal_protected_wait 3
if [ "$RUN_RC" -eq 0 ] && [ "$MOCK_GUARD_COUNT" -eq 1 ] &&
   [ "$MOCK_NOW" -eq 103 ]; then
  pass "protected VLAN settle uses elapsed time with approximately 1 Hz guards"
else
  fail "protected settle expanded with guard runtime (rc=$RUN_RC now=$MOCK_NOW guards=$MOCK_GUARD_COUNT)"
fi

# 9. A strict guard failure remains visible to the protected wait caller.
reset_fixture
MOCK_GUARD_RC=7
run_fixture heal_protected_wait 3
if [ "$RUN_RC" -eq 7 ] && [ "$MOCK_GUARD_COUNT" -eq 1 ]; then
  pass "strict guard failure propagates from protected settle"
else
  fail "strict guard failure was swallowed (rc=$RUN_RC guards=$MOCK_GUARD_COUNT)"
fi

# 10. Cache cleanup runs on success and preserves an original failure code when
# the best-effort disable itself fails.
reset_fixture
:
heal_cleanup_on_exit >"$TEST_ROOT/cleanup-success.out" 2>&1
RUN_RC=$?
if [ "$RUN_RC" -eq 0 ] && [ "$MOCK_CACHE_DISABLE_COUNT" -eq 1 ] &&
   [ "$HEAL_IFACE_VID_CACHE_ENABLED" -eq 0 ]; then
  pass "cache cleanup runs on normal success"
else
  fail "normal cache cleanup failed (rc=$RUN_RC disables=$MOCK_CACHE_DISABLE_COUNT enabled=$HEAL_IFACE_VID_CACHE_ENABLED)"
fi

reset_fixture
MOCK_CACHE_DISABLE_RC=1
false
heal_cleanup_on_exit >"$TEST_ROOT/cleanup-error.out" 2>&1
RUN_RC=$?
if [ "$RUN_RC" -eq 1 ] && [ "$MOCK_CACHE_DISABLE_COUNT" -eq 1 ]; then
  pass "cache cleanup failure does not mask the original error status"
else
  fail "cache cleanup masked the original status (rc=$RUN_RC disables=$MOCK_CACHE_DISABLE_COUNT)"
fi

# 11. The current strict coordinator remains the only guard implementation
# used by the new timing helpers; exact child-rule strictness is covered by the
# maintained deep-audit fixture run separately.
if grep -Fq 'merv_guard_tick' "$BASE_DIR/functions/heal_event.sh" &&
   grep -Fq 'merv_qt_ensure_expected_rules || return $?' "$BASE_DIR/functions/heal_event.sh"; then
  pass "heal timing helpers retain strict QT/MAC/DHCP guard coordination"
else
  fail "strict guard coordination was not retained in heal"
fi

if [ "$failures" -eq 0 ]; then
  printf 'ALL 11 HEAL_EVENT_TIMING CONTRACT TESTS PASSED\n'
  exit 0
fi
printf '%s HEAL_EVENT_TIMING CONTRACT TEST(S) FAILED\n' "$failures" >&2
exit 1
