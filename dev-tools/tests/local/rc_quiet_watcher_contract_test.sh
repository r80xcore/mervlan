#!/bin/sh
# Contract tests for wait_for_rc_quiet() timing and semantics.
#
# Covers:
# 1. Pre-loop QT reconciliation does not consume RC observation timeout budget.
# 2. Initial long guard is not credited as continuous quiet; establishes baseline
#    and requires subsequent observation.
# 3. Slow guards (every tick takes 3s) reach normal quiet success without timeout fallback.
# 4. Genuine quiet interval: post-guard baseline followed by elapsed quiet >= need succeeds.
# 5. Busy observation resets established continuous quiet interval.
# 6. Timeout while RC remains active fails closed (returns 1, retains DHCP hold).
# 7. Timeout while RC is idle logs truthful warning and returns 0 (stable verification).
# 8. Guard tick failure propagates immediately (returns nonzero).
# 9. Pre-loop QT reconciliation failure propagates immediately.
# 10. Loop sleeps between ticks to avoid busy-spinning.
# 11. Time helper command failure fails closed immediately with warning.
# 12. Malformed non-numeric timestamp fails closed immediately.
# 13. Safe parameter defaults and sanitization for non-numeric/empty inputs.
# 14. Actual blocking NVRAM guard work is bounded and propagates L2 failure;
#     no elapsed time inside the guard is credited as quiet.
#
# Pure local contract test using extracted production functions and deterministic
# simulated time. Does not require router hardware, ebtables, or live state.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_TMP="${TMPDIR:-/tmp}/mervlan_test_rc_quiet.$$"
NVRAM_BIN="$TEST_TMP/bin"
RC_NVRAM_TRACE="$TEST_TMP/nvram.trace"
mkdir -p "$NVRAM_BIN" || exit 1
trap 'rm -rf "$TEST_TMP"' 0 1 2 3 15

MANAGER="$BASE_DIR/functions/mervlan_manager.sh"
[ -f "$MANAGER" ] || { printf 'FAIL: manager script not found: %s\n' "$MANAGER" >&2; exit 1; }
SNAPSHOT="$BASE_DIR/settings/mac_shield_snapshot.sh"
SSH_LIB="$BASE_DIR/settings/lib_ssh.sh"
[ -f "$SNAPSHOT" ] || { printf 'FAIL: snapshot source not found: %s\n' "$SNAPSHOT" >&2; exit 1; }
[ -f "$SSH_LIB" ] || { printf 'FAIL: SSH source not found: %s\n' "$SSH_LIB" >&2; exit 1; }

EXTRACTED="$TEST_TMP/extracted_rc_quiet.sh"
awk '
  /^merv_rc_quiet_now\(\) \{/,/^}$/ { print; next }
  /^merv_rc_quiet_sleep\(\) \{/,/^}$/ { print; next }
  /^wait_for_rc_quiet\(\) \{/,/^}$/ { print; next }
' "$MANAGER" > "$EXTRACTED" || exit 1

[ -s "$EXTRACTED" ] || { printf 'FAIL: failed to extract functions from %s\n' "$MANAGER" >&2; exit 1; }

# Extract the real NVRAM inventory/SSID builder and timeout seam used by the
# L2 guard's expected-interface calculation.  The guard fixture below calls
# this production builder directly; only the outer ebtables mutation remains
# stubbed so the test stays local and deterministic.
extract_fn() {
  _ef_src="$1" _ef_name="$2" _ef_dst="$3"
  awk -v wanted="$_ef_name" '
    $0 ~ ("^" wanted "\\(\\)[[:space:]]*\\{") { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$_ef_src" > "$_ef_dst" || return 1
  [ -s "$_ef_dst" ]
}

EXTRACTED_NVRAM="$TEST_TMP/extracted_nvram"
mkdir -p "$EXTRACTED_NVRAM" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_process_start "$EXTRACTED_NVRAM/inventory-process.sh" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_path "$EXTRACTED_NVRAM/inventory-path.sh" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_artifacts_safe "$EXTRACTED_NVRAM/inventory-artifacts-safe.sh" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_set_error "$EXTRACTED_NVRAM/inventory-set-error.sh" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_publish_state "$EXTRACTED_NVRAM/inventory-publish.sh" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_mark_error "$EXTRACTED_NVRAM/inventory-error.sh" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_invalidate "$EXTRACTED_NVRAM/inventory-invalidate.sh" || exit 1
extract_fn "$SNAPSHOT" merv_nvram_inventory_read "$EXTRACTED_NVRAM/inventory-read.sh" || exit 1
extract_fn "$SNAPSHOT" merv_mac_build_expected_iface_vid "$EXTRACTED_NVRAM/builder.sh" || exit 1
extract_fn "$SSH_LIB" _merv_timeout_run "$EXTRACTED_NVRAM/timeout.sh" || exit 1

# A real executable is required because production timeout runs `nvram show`
# as a child process (shell functions would not cross that boundary).
cat > "$NVRAM_BIN/nvram" <<'EOF'
#!/bin/sh
[ "${1:-}" = show ] || exit 2
printf '%s\n' nvram-show-start >> "$RC_NVRAM_TRACE"
if [ "${RC_NVRAM_MODE:-normal}" = stall ]; then
  exec sleep 10
fi
printf 'wl0.1_ssid=Guest\nwl0.1_ifname=wl0.1\n'
printf '%s\n' nvram-show-end >> "$RC_NVRAM_TRACE"
exit 0
EOF
chmod 700 "$NVRAM_BIN/nvram" || exit 1
PATH="$NVRAM_BIN:$PATH"
export PATH RC_NVRAM_TRACE

merv_has() { command -v "$1" >/dev/null 2>&1; }
_merv_log_err() { printf 'TIMEOUT-ERROR:%s\n' "$*" >> "$RC_NVRAM_TRACE"; }
. "$EXTRACTED_NVRAM/timeout.sh" || exit 1
for _inventory_piece in "$EXTRACTED_NVRAM"/inventory-*.sh; do
  . "$_inventory_piece" || exit 1
done
. "$EXTRACTED_NVRAM/builder.sh" || exit 1

# Source the extracted production functions
. "$EXTRACTED"

_failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _failures=$((_failures + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }

# Logging buffers
LAST_INFO=""
ALL_INFO=""
LAST_WARN=""
ALL_WARN=""
info() {
  shift; shift
  LAST_INFO="$*"
  ALL_INFO="${ALL_INFO}
$*"
}
warn() {
  shift; shift
  LAST_WARN="$*"
  ALL_WARN="${ALL_WARN}
$*"
}

# Strict test oracle helper for normal quiet success:
# Proves return code == 0, normal quiet log exists, and NO timeout warning occurred.
assert_quiet_success() {
  _test_id="$1" _status="$2"
  if [ "$_status" -ne 0 ]; then
    fail "$_test_id: returned status $_status, expected 0"
    return 1
  fi
  case "$ALL_INFO" in
    *"rc quiet for "*"s; proceeding"*) : ;;
    *)
      fail "$_test_id: normal quiet success log missing; ALL_INFO=$ALL_INFO"
      return 1
      ;;
  esac
  case "$ALL_WARN" in
    *"timeout"*)
      fail "$_test_id: unexpected timeout warning logged; ALL_WARN=$ALL_WARN"
      return 1
      ;;
  esac
  return 0
}

# State variables for simulation
MOCK_NOW=100
MOCK_SLEEP_COUNT=0
MOCK_SLEEP_SECONDS=0
MOCK_GUARD_TICK_COUNT=0
MOCK_GUARD_TICK_DURATION=1
MOCK_GUARD_TICK_RC=0
MOCK_PRELOOP_DURATION=0
MOCK_PRELOOP_RC=0
MOCK_RC_BUSY=0
MOCK_TIME_FAIL=0
MOCK_TIME_VALUE=""
MOCK_REAL_NVRAM_GUARD=0

# Override time and sleep functions with deterministic harness
merv_rc_quiet_now() {
  if [ "$MOCK_TIME_FAIL" -ne 0 ]; then
    return 1
  fi
  if [ -n "$MOCK_TIME_VALUE" ]; then
    case "$MOCK_TIME_VALUE" in
      ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$MOCK_TIME_VALUE"
    return 0
  fi
  printf '%s\n' "$MOCK_NOW"
}

merv_rc_quiet_sleep() {
  _dur="${1:-1}"
  MOCK_SLEEP_COUNT=$((MOCK_SLEEP_COUNT + 1))
  MOCK_SLEEP_SECONDS=$((MOCK_SLEEP_SECONDS + _dur))
  MOCK_NOW=$((MOCK_NOW + _dur))
}

ebt_quarantine_ensure_expected_rules() {
  if [ "$MOCK_PRELOOP_RC" -ne 0 ]; then
    return "$MOCK_PRELOOP_RC"
  fi
  MOCK_NOW=$((MOCK_NOW + MOCK_PRELOOP_DURATION))
  return 0
}

merv_guard_tick() {
  MOCK_GUARD_TICK_COUNT=$((MOCK_GUARD_TICK_COUNT + 1))
  if [ "$MOCK_REAL_NVRAM_GUARD" -ne 0 ]; then
    merv_mac_build_expected_iface_vid >/dev/null || return 1
    return 0
  fi
  if [ "$MOCK_GUARD_TICK_RC" -ne 0 ]; then
    return "$MOCK_GUARD_TICK_RC"
  fi
  MOCK_NOW=$((MOCK_NOW + MOCK_GUARD_TICK_DURATION))
  return 0
}

rc_queue_has() {
  [ "$MOCK_RC_BUSY" -ne 0 ]
}

rc_proc_busy() {
  [ "$MOCK_RC_BUSY" -ne 0 ]
}

reset_harness() {
  MOCK_NOW=100
  MOCK_SLEEP_COUNT=0
  MOCK_SLEEP_SECONDS=0
  MOCK_GUARD_TICK_COUNT=0
  MOCK_GUARD_TICK_DURATION=1
  MOCK_GUARD_TICK_RC=0
  MOCK_PRELOOP_DURATION=0
  MOCK_PRELOOP_RC=0
  MOCK_RC_BUSY=0
  MOCK_TIME_FAIL=0
  MOCK_TIME_VALUE=""
  MOCK_REAL_NVRAM_GUARD=0
  LAST_INFO=""
  ALL_INFO=""
  LAST_WARN=""
  ALL_WARN=""
}

# ==============================================================================
# TEST 1: Pre-loop work does not consume observation timeout
# ==============================================================================
reset_harness
MOCK_PRELOOP_DURATION=12
MOCK_GUARD_TICK_DURATION=1
MOCK_RC_BUSY=0

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if assert_quiet_success "TEST 1" "$_rc"; then
  pass "TEST 1: pre-loop QT work (12s) did not consume 10s observation timeout"
fi

# ==============================================================================
# TEST 2: Initial long guard is not credited as continuous quiet
# ==============================================================================
reset_harness
# Fixture: need=2. First pre-guard sample idle. Guard takes 3s. First post-guard idle.
# Must NOT succeed immediately after first guard.
# First post-guard establishes baseline; subsequent observation required for normal quiet success.
MOCK_GUARD_TICK_DURATION=3
MOCK_RC_BUSY=0

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if ! assert_quiet_success "TEST 2" "$_rc"; then
  :
elif [ "$MOCK_GUARD_TICK_COUNT" -lt 2 ]; then
  fail "TEST 2: falsely succeeded immediately after first guard (tick count: $MOCK_GUARD_TICK_COUNT)"
elif case "$ALL_INFO" in *"rc quiet for 3s"*) true ;; *) false ;; esac; then
  fail "TEST 2: falsely credited initial 3s guard as continuous quiet"
else
  pass "TEST 2: initial 3s guard not credited; established baseline post-guard and required subsequent observation"
fi

# ==============================================================================
# TEST 3: Slow guards (every tick takes 3s) reach normal quiet success
# ==============================================================================
reset_harness
# Every guard tick takes 3 seconds (exceeding need=2).
# RC idle at every actual sample.
# Must reach normal quiet success; must NOT hit idle timeout fallback.
MOCK_GUARD_TICK_DURATION=3
MOCK_RC_BUSY=0

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if ! assert_quiet_success "TEST 3" "$_rc"; then
  :
elif [ "$MOCK_GUARD_TICK_COUNT" -ne 2 ]; then
  fail "TEST 3: expected normal quiet success on tick 2, got tick count: $MOCK_GUARD_TICK_COUNT"
else
  pass "TEST 3: slow guards (3s each) reached normal quiet success without timeout fallback"
fi

# ==============================================================================
# TEST 4: Genuine quiet interval succeeds based on actual elapsed quiet time
# ==============================================================================
reset_harness
MOCK_GUARD_TICK_DURATION=1
MOCK_RC_BUSY=0

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if ! assert_quiet_success "TEST 4" "$_rc"; then
  :
elif case "$LAST_INFO" in *"rc quiet for 2s; proceeding"*) false ;; *) true ;; esac; then
  fail "TEST 4: expected log showing rc quiet for 2s, got: $LAST_INFO"
else
  pass "TEST 4: genuine quiet interval succeeded after proven baseline and elapsed quiet"
fi

# ==============================================================================
# TEST 5: RC busy resets established continuous quiet interval
# ==============================================================================
reset_harness
MOCK_GUARD_TICK_DURATION=1
# Custom rc callback: busy between t=102 and t=104
rc_proc_busy() {
  if [ "$MOCK_NOW" -ge 102 ] && [ "$MOCK_NOW" -lt 104 ]; then
    return 0
  fi
  return 1
}
rc_queue_has() { rc_proc_busy "$@"; }

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if ! assert_quiet_success "TEST 5" "$_rc"; then
  :
elif [ "$MOCK_NOW" -ne 107 ]; then
  fail "TEST 5: expected completion at t=107 after reset, finished at t=$MOCK_NOW"
else
  pass "TEST 5: busy state reset quiet interval; previous idle duration was not credited"
fi

# Restore standard rc callbacks
rc_queue_has() { [ "$MOCK_RC_BUSY" -ne 0 ]; }
rc_proc_busy() { [ "$MOCK_RC_BUSY" -ne 0 ]; }

# ==============================================================================
# TEST 6: Timeout while RC remains active fails closed
# ==============================================================================
reset_harness
MOCK_GUARD_TICK_DURATION=1
MOCK_RC_BUSY=1  # Always busy

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if [ "$_rc" -eq 0 ]; then
  fail "TEST 6: wait_for_rc_quiet unexpectedly returned 0 while RC remained active"
elif case "$LAST_WARN" in *"while rc remains active; retaining DHCP protection"*) false ;; *) true ;; esac; then
  fail "TEST 6: expected fail-closed DHCP retention warning, got: $LAST_WARN"
elif [ "$((MOCK_NOW - 100))" -lt 10 ]; then
  fail "TEST 6: timed out prematurely at elapsed $((MOCK_NOW - 100))s"
else
  pass "TEST 6: timeout with active RC failed closed and logged DHCP protection retention"
fi

# ==============================================================================
# TEST 7: Deadline reached with RC idle continues to stable verification
# ==============================================================================
reset_harness
MOCK_GUARD_TICK_DURATION=1
# Busy until t=109, then becomes idle at t=109. Max wait=10, need=5.
rc_proc_busy() {
  if [ "$MOCK_NOW" -lt 109 ]; then
    return 0
  fi
  return 1
}
rc_queue_has() { rc_proc_busy "$@"; }

_rc=0
wait_for_rc_quiet 5 10 || _rc=$?
if [ "$_rc" -ne 0 ]; then
  fail "TEST 7: wait_for_rc_quiet returned $_rc on idle timeout"
elif case "$LAST_WARN" in *"with rc idle; continuing to stable verification"*) false ;; *) true ;; esac; then
  fail "TEST 7: expected idle timeout warning, got: $LAST_WARN"
else
  pass "TEST 7: observation timeout with RC idle preserved fallback contract (returned 0)"
fi

# Restore standard rc callbacks
rc_queue_has() { [ "$MOCK_RC_BUSY" -ne 0 ]; }
rc_proc_busy() { [ "$MOCK_RC_BUSY" -ne 0 ]; }

# ==============================================================================
# TEST 8: Guard failure propagation
# ==============================================================================
reset_harness
MOCK_GUARD_TICK_RC=1

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if [ "$_rc" -eq 0 ]; then
  fail "TEST 8: guard tick failure was swallowed (returned 0)"
elif [ "$MOCK_GUARD_TICK_COUNT" -ne 1 ]; then
  fail "TEST 8: expected exactly 1 guard tick before returning error, ran $MOCK_GUARD_TICK_COUNT"
else
  pass "TEST 8: merv_guard_tick failure propagated immediately"
fi

# ==============================================================================
# TEST 9: Pre-loop QT ensure failure propagation
# ==============================================================================
reset_harness
MOCK_PRELOOP_RC=1

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if [ "$_rc" -eq 0 ]; then
  fail "TEST 9: pre-loop QT failure was swallowed (returned 0)"
elif [ "$MOCK_GUARD_TICK_COUNT" -ne 0 ]; then
  fail "TEST 9: watcher loop ran despite pre-loop QT failure (tick count: $MOCK_GUARD_TICK_COUNT)"
else
  pass "TEST 9: pre-loop QT reconciliation failure propagated immediately before watcher loop"
fi

# ==============================================================================
# TEST 10: No busy-spinning (sleep is invoked when quiet requirement is pending)
# ==============================================================================
reset_harness
MOCK_GUARD_TICK_DURATION=0  # Instantaneous guard tick
MOCK_RC_BUSY=0

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if [ "$_rc" -ne 0 ]; then
  fail "TEST 10: wait_for_rc_quiet failed with code $_rc"
elif [ "$MOCK_SLEEP_COUNT" -lt 2 ]; then
  fail "TEST 10: expected at least 2 sleeps for need=2 with instant guard, got $MOCK_SLEEP_COUNT"
elif [ "$MOCK_SLEEP_SECONDS" -lt 2 ]; then
  fail "TEST 10: expected at least 2 seconds slept, got $MOCK_SLEEP_SECONDS"
else
  pass "TEST 10: loop sleeps 1s between checks without busy-spinning"
fi

# ==============================================================================
# TEST 11: Time helper command failure fails closed
# ==============================================================================
reset_harness
MOCK_TIME_FAIL=1

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if [ "$_rc" -eq 0 ]; then
  fail "TEST 11: wait_for_rc_quiet returned 0 despite timestamp acquisition failure"
elif case "$ALL_WARN" in *"failed to acquire"*"timestamp; failing closed"*) false ;; *) true ;; esac; then
  fail "TEST 11: expected concise timestamp failure warning, got: $ALL_WARN"
elif [ "$MOCK_GUARD_TICK_COUNT" -ne 0 ]; then
  fail "TEST 11: watcher executed guard work despite timestamp failure ($MOCK_GUARD_TICK_COUNT ticks)"
else
  pass "TEST 11: timestamp helper command failure failed closed immediately with warning"
fi

# ==============================================================================
# TEST 12: Malformed timestamp fails closed
# ==============================================================================
reset_harness
MOCK_TIME_VALUE="abc"

_rc=0
wait_for_rc_quiet 2 10 || _rc=$?
if [ "$_rc" -eq 0 ]; then
  fail "TEST 12: wait_for_rc_quiet returned 0 on malformed timestamp"
elif case "$ALL_WARN" in *"failed to acquire"*"timestamp; failing closed"*) false ;; *) true ;; esac; then
  fail "TEST 12: expected concise timestamp failure warning, got: $ALL_WARN"
else
  pass "TEST 12: malformed non-numeric timestamp failed closed immediately"
fi

# ==============================================================================
# TEST 13: Safe parameter defaults and sanitization
# ==============================================================================
reset_harness
MOCK_GUARD_TICK_DURATION=1
MOCK_RC_BUSY=0

_rc=0
wait_for_rc_quiet "invalid" "bad_max" || _rc=$?
if ! assert_quiet_success "TEST 13" "$_rc"; then
  :
elif case "$ALL_INFO" in *"need=6s quiet, max=30s"*) false ;; *) true ;; esac; then
  fail "TEST 13: expected fallback to need=6 max=30, got: $ALL_INFO"
else
  pass "TEST 13: non-numeric/empty arguments safely default without arithmetic errors"
fi

# ==============================================================================
# TEST 14: Actual NVRAM guard operation exceeds watcher budget
# ==============================================================================
reset_harness
MOCK_REAL_NVRAM_GUARD=1
MOCK_RC_BUSY=1
MAX_SSIDS=1
SETTINGS_FILE="$TEST_TMP/rc-settings.json"
MERV_NVRAM_INVENTORY_ROOT="$TEST_TMP/rc-nvram-inventory"
MERV_NVRAM_INVENTORY_SCOPE=rc-guard
MERV_NVRAM_READ_TIMEOUT=2
RC_NVRAM_MODE=stall
export MAX_SSIDS SETTINGS_FILE MERV_NVRAM_INVENTORY_ROOT
export MERV_NVRAM_INVENTORY_SCOPE MERV_NVRAM_READ_TIMEOUT RC_NVRAM_MODE

# Minimal real builder dependencies.  The production builder still performs
# the inventory read and invokes the executable nvram show fixture above.
merv_cap_ssids() { printf '%s\n' 1; }
mervqt_valid_vid() { [ "$1" -ge 2 ] 2>/dev/null && [ "$1" -le 4094 ] 2>/dev/null; }
merv_is_wl_vap_iface() {
  case "$1" in wl[0-9]*.[0-9]*) return 0 ;; *) return 1 ;; esac
}
get_ssid_slot_value() { printf '%s\n' Guest; }
get_vlan_slot_value() { printf '%s\n' 10; }
_merv_mac_log() { printf 'MERV-MAC:%s\n' "$*" >> "$RC_NVRAM_TRACE"; }
merv_nvram_inventory_invalidate || exit 1
: > "$RC_NVRAM_TRACE"

START_EPOCH=$(date +%s)
_rc=0
wait_for_rc_quiet 1 1 || _rc=$?
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))

if [ "$_rc" -eq 0 ]; then
  fail "TEST 14: blocking NVRAM guard returned success while RC remained active"
elif [ "$_rc" -ne 1 ]; then
  fail "TEST 14: NVRAM/L2 guard failure was not propagated (rc=$_rc)"
elif [ "$MOCK_GUARD_TICK_COUNT" -ne 1 ]; then
  fail "TEST 14: expected one bounded NVRAM guard tick, got $MOCK_GUARD_TICK_COUNT"
elif ! grep -Fq 'nvram-show-start' "$RC_NVRAM_TRACE"; then
  fail "TEST 14: actual nvram show guard sub-operation was not invoked"
elif grep -Fq 'nvram-show-end' "$RC_NVRAM_TRACE"; then
  fail "TEST 14: stalled nvram show unexpectedly completed normally"
elif [ "${MERV_NVRAM_INVENTORY_REASON:-}" != timeout ]; then
  fail "TEST 14: inventory reason=${MERV_NVRAM_INVENTORY_REASON:-unset}, expected timeout"
elif [ "$ELAPSED" -lt 1 ] || [ "$ELAPSED" -gt 5 ]; then
  fail "TEST 14: guard wall runtime escaped bounded allowance (${ELAPSED}s; max wait=1s, NVRAM timeout=2s)"
elif case "$ALL_INFO" in *"rc quiet for "*"proceeding"*) true ;; *) false ;; esac; then
  fail "TEST 14: unobserved guard duration was credited as RC quiet"
else
  pass "TEST 14: actual blocking nvram show bounded to ${ELAPSED}s, active RC failed closed, and L2 failure propagated"
fi

# ==============================================================================
# Summary
# ==============================================================================
if [ "$_failures" -eq 0 ]; then
  printf 'ALL 14 RC_QUIET_WATCHER CONTRACT TESTS PASSED\n'
  exit 0
else
  printf '%d RC_QUIET_WATCHER CONTRACT TEST(S) FAILED\n' "$_failures" >&2
  exit 1
fi
