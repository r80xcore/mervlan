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

# Exercise the real DHCP state-lock acquisition primitive at the two
# post-timestamp seams.  Each case uses a private state root and only replaces
# the timestamp/quarantine dependency that represents the injected race.
# The owner fields are deliberately not copied from production helpers: these
# assertions observe the lock primitive's externally visible retry, warning,
# and obstruction semantics.
_dhcp_write_complete_claim() {
  _dwcc_lock="$1"
  _dwcc_pid="${2:-999999999}"
  _dwcc_start="${3:-1}"
  _dwcc_created="${4:-1}"
  _dwcc_nonce="${5:-stale-owner}"
  mkdir "$_dwcc_lock" || return 1
  printf '%s\n' "$_dwcc_pid" > "$_dwcc_lock/pid" || return 1
  printf '%s\n' "$_dwcc_start" > "$_dwcc_lock/proc_start_time" || return 1
  printf '%s\n' "$_dwcc_created" > "$_dwcc_lock/created_epoch" || return 1
  printf '%s\n' "$_dwcc_nonce" > "$_dwcc_lock/owner_nonce" || return 1
}

# Case A — timestamp lookup loses a release race.  The authoritative
# non-following absence check must permit one retry and must not emit the
# scary "age is unverifiable" warning for a lock that really disappeared.
(
  _CASE="$TEST_ROOT/dhcp-post-a"
  mkdir -p "$_CASE" || exit 1
  MERV_DHCP_HOLD_STATE_ROOT="$_CASE/state"
  export MERV_DHCP_HOLD_STATE_ROOT
  TRACE="$_CASE/trace.log"
  OUTPUT="$_CASE/output.log"
  : > "$TRACE"
  info() { printf 'INFO:%s\n' "$*" >> "$TRACE"; }
  warn() { printf 'WARN:%s\n' "$*" >> "$TRACE"; }
  error() { printf 'ERROR:%s\n' "$*" >> "$TRACE"; }
  usleep() { :; }
  _DHCP_NONCE_SEQ=0
  _merv_dhcp_nonce() {
    _DHCP_NONCE_SEQ=$((_DHCP_NONCE_SEQ + 1))
    MERV_DHCP_NONCE="post-a-$_DHCP_NONCE_SEQ"
  }
  merv_dhcp_state_lock_timestamp() {
    rmdir "$1" 2>/dev/null || :
    return 1
  }
  mkdir -p "$MERV_DHCP_HOLD_STATE_ROOT" || exit 2
  mkdir "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" || exit 3
  merv_dhcp_state_lock_acquire > "$OUTPUT" 2>&1
  _rc=$?
  [ "$_rc" -eq 0 ] || exit 10
  [ -f "$MERV_DHCP_HOLD_STATE_ROOT/state.lock/owner_nonce" ] || exit 11
  [ ! -s "$TRACE" ] || exit 12
  if [ -s "$OUTPUT" ] && grep -Eq 'age is unverifiable|refusing reclaim' "$OUTPUT"; then
    exit 13
  fi
  _nonce=$(cat "$MERV_DHCP_HOLD_STATE_ROOT/state.lock/owner_nonce" 2>/dev/null || printf '')
  merv_dhcp_state_lock_release "$_nonce" || exit 14
  [ ! -e "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" ] || exit 15
)
_dhcp_case_a_rc=$?
if [ "$_dhcp_case_a_rc" -eq 0 ]; then
  pass dhcp-post-timestamp-disappearance-retries
  pass dhcp-post-timestamp-disappearance-no-warning
else
  fail "dhcp-post-timestamp-disappearance (rc=$_dhcp_case_a_rc)"
fi

# Case B — a stale predecessor is replaced by a retained incomplete claim
# during quarantine.  Acquisition must return rc=2, preserve the incomplete
# lock, and emit one bounded warning rather than silently treating it as idle.
(
  _CASE="$TEST_ROOT/dhcp-post-b"
  mkdir -p "$_CASE" || exit 1
  MERV_DHCP_HOLD_STATE_ROOT="$_CASE/state"
  export MERV_DHCP_HOLD_STATE_ROOT
  TRACE="$_CASE/trace.log"
  OUTPUT="$_CASE/output.log"
  : > "$TRACE"
  info() { printf 'INFO:%s\n' "$*" >> "$TRACE"; }
  warn() { printf 'WARN:%s\n' "$*" >> "$TRACE"; }
  error() { printf 'ERROR:%s\n' "$*" >> "$TRACE"; }
  usleep() { :; }
  _DHCP_NONCE_SEQ=0
  _merv_dhcp_nonce() {
    _DHCP_NONCE_SEQ=$((_DHCP_NONCE_SEQ + 1))
    MERV_DHCP_NONCE="post-b-$_DHCP_NONCE_SEQ"
  }
  merv_dhcp_state_lock_quarantine_hook() {
    rm -f "$1/owner_nonce" 2>/dev/null || return 1
    return 0
  }
  mkdir -p "$MERV_DHCP_HOLD_STATE_ROOT" || exit 2
  _dhcp_write_complete_claim "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" || exit 3
  MERV_DHCP_STATE_LOCK_FAULT=quarantine-window
  export MERV_DHCP_STATE_LOCK_FAULT
  merv_dhcp_state_lock_acquire > "$OUTPUT" 2>&1
  _rc=$?
  [ "$_rc" -eq 2 ] || exit 10
  [ -d "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" ] || exit 11
  [ ! -e "$MERV_DHCP_HOLD_STATE_ROOT/state.lock/owner_nonce" ] || exit 12
  grep -q '^WARN:' "$TRACE" || exit 13
)
_dhcp_case_b_rc=$?
if [ "$_dhcp_case_b_rc" -eq 0 ]; then
  pass dhcp-post-state-retained-incomplete-rc2
  pass dhcp-post-state-retained-incomplete-warns
else
  fail "dhcp-post-state-retained-incomplete (rc=$_dhcp_case_b_rc)"
fi

# Case C — the exact quarantine window installs a regular-file replacement.
# The replacement must not be moved away as if it were the old directory, and
# the waiter must remain blocked with the object intact.
(
  _CASE="$TEST_ROOT/dhcp-post-c"
  mkdir -p "$_CASE" || exit 1
  MERV_DHCP_HOLD_STATE_ROOT="$_CASE/state"
  export MERV_DHCP_HOLD_STATE_ROOT
  TRACE="$_CASE/trace.log"
  : > "$TRACE"
  info() { printf 'INFO:%s\n' "$*" >> "$TRACE"; }
  warn() { printf 'WARN:%s\n' "$*" >> "$TRACE"; }
  error() { printf 'ERROR:%s\n' "$*" >> "$TRACE"; }
  usleep() { :; }
  _DHCP_NONCE_SEQ=0
  _merv_dhcp_nonce() {
    _DHCP_NONCE_SEQ=$((_DHCP_NONCE_SEQ + 1))
    MERV_DHCP_NONCE="post-c-$_DHCP_NONCE_SEQ"
  }
  merv_dhcp_state_lock_quarantine_hook() {
    _lock="$1"
    rm -f "$_lock/pid" "$_lock/proc_start_time" \
      "$_lock/created_epoch" "$_lock/owner_nonce" 2>/dev/null || return 1
    rmdir "$_lock" 2>/dev/null || return 1
    printf 'replacement-regular-object\n' > "$_lock" || return 1
    return 0
  }
  mkdir -p "$MERV_DHCP_HOLD_STATE_ROOT" || exit 2
  _dhcp_write_complete_claim "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" || exit 3
  MERV_DHCP_STATE_LOCK_FAULT=quarantine-window
  export MERV_DHCP_STATE_LOCK_FAULT
  merv_dhcp_state_lock_acquire > "$_CASE/output.log" 2>&1
  _rc=$?
  [ "$_rc" -eq 2 ] || exit 10
  [ -f "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" ] || exit 11
  [ ! -L "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" ] || exit 12
  grep -qx 'replacement-regular-object' "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" || exit 13
)
_dhcp_case_c_rc=$?
if [ "$_dhcp_case_c_rc" -eq 0 ]; then
  pass dhcp-post-state-regular-replacement-blocked
else
  fail "dhcp-post-state-regular-replacement (rc=$_dhcp_case_c_rc)"
fi

# Case D — the exact quarantine window installs a new canonical owner.  The
# replacement owner remains authoritative at state.lock and the stale
# predecessor is retained separately for bounded inspection.
(
  _CASE="$TEST_ROOT/dhcp-post-d"
  mkdir -p "$_CASE" || exit 1
  MERV_DHCP_HOLD_STATE_ROOT="$_CASE/state"
  export MERV_DHCP_HOLD_STATE_ROOT
  TRACE="$_CASE/trace.log"
  : > "$TRACE"
  info() { printf 'INFO:%s\n' "$*" >> "$TRACE"; }
  warn() { printf 'WARN:%s\n' "$*" >> "$TRACE"; }
  error() { printf 'ERROR:%s\n' "$*" >> "$TRACE"; }
  usleep() { :; }
  _DHCP_NONCE_SEQ=0
  _merv_dhcp_nonce() {
    _DHCP_NONCE_SEQ=$((_DHCP_NONCE_SEQ + 1))
    MERV_DHCP_NONCE="post-d-$_DHCP_NONCE_SEQ"
  }
  merv_dhcp_state_lock_quarantine_hook() {
    _lock="$1"
    _backup="${_lock}.race-original"
    rm -rf "$_backup" 2>/dev/null || return 1
    mv "$_lock" "$_backup" || return 1
    mkdir "$_lock" || return 1
    _start=$(merv_proc_start_time "$$" "$MERV_DHCP_HOLD_PROC_ROOT" 2>/dev/null) || return 1
    _now=$(merv_dhcp_state_lock_now 2>/dev/null) || return 1
    printf '%s\n' "$$" > "$_lock/pid" || return 1
    printf '%s\n' "$_start" > "$_lock/proc_start_time" || return 1
    printf '%s\n' "$_now" > "$_lock/created_epoch" || return 1
    printf 'replacement-owner\n' > "$_lock/owner_nonce" || return 1
    return 0
  }
  mkdir -p "$MERV_DHCP_HOLD_STATE_ROOT" || exit 2
  _dhcp_write_complete_claim "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" || exit 3
  MERV_DHCP_STATE_LOCK_FAULT=quarantine-window
  export MERV_DHCP_STATE_LOCK_FAULT
  merv_dhcp_state_lock_acquire > "$_CASE/output.log" 2>&1
  _rc=$?
  [ "$_rc" -eq 2 ] || exit 10
  [ -d "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" ] || exit 11
  [ "$(cat "$MERV_DHCP_HOLD_STATE_ROOT/state.lock/pid" 2>/dev/null)" = "$$" ] || exit 12
  [ "$(cat "$MERV_DHCP_HOLD_STATE_ROOT/state.lock/owner_nonce" 2>/dev/null)" = replacement-owner ] || exit 13
  [ -d "$MERV_DHCP_HOLD_STATE_ROOT/state.lock.race-original" ] || exit 14
)
_dhcp_case_d_rc=$?
if [ "$_dhcp_case_d_rc" -eq 0 ]; then
  pass dhcp-post-state-replacement-owner-blocked
  pass dhcp-post-state-stale-predecessor-retained
else
  fail "dhcp-post-state-replacement-owner (rc=$_dhcp_case_d_rc)"
fi

# Case E — regular file, symlink to an existing directory, and dangling
# symlink are all obstructions. None may be interpreted as authoritative
# absence or replaced by a new owner claim.
(
  _CASE="$TEST_ROOT/dhcp-obstructions"
  mkdir -p "$_CASE" || exit 1
  info() { :; }
  warn() { :; }
  error() { :; }
  usleep() { :; }
  _merv_dhcp_nonce() { MERV_DHCP_NONCE=post-e; }
  for _kind in regular symlink dangling; do
    MERV_DHCP_HOLD_STATE_ROOT="$_CASE/$_kind/state"
    export MERV_DHCP_HOLD_STATE_ROOT
    mkdir -p "$MERV_DHCP_HOLD_STATE_ROOT" || exit 2
    _lock="$MERV_DHCP_HOLD_STATE_ROOT/state.lock"
    case "$_kind" in
      regular)
        printf 'regular-obstruction\n' > "$_lock" || exit 3
        ;;
      symlink)
        _target="$_CASE/symlink-target"
        printf 'symlink-target\n' > "$_target" || exit 4
        MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$_target" "$_lock" 2>/dev/null || exit 200
        [ -L "$_lock" ] || exit 201
        ;;
      dangling)
        _target="$_CASE/dangling-target"
        MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$_target" "$_lock" 2>/dev/null || exit 200
        [ -L "$_lock" ] || exit 201
        ;;
    esac
    MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC=0
    export MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
    merv_dhcp_state_lock_acquire > "$_CASE/$_kind.output" 2>&1
    _rc=$?
    [ "$_rc" -eq 2 ] || exit 10
    case "$_kind" in
      regular) [ -f "$_lock" ] && [ ! -L "$_lock" ] || exit 11 ;;
      symlink|dangling) [ -L "$_lock" ] || exit 12 ;;
    esac
  done
)
_dhcp_case_e_rc=$?
if [ "$_dhcp_case_e_rc" -eq 0 ]; then
  pass dhcp-obstruction-regular-fails-closed
  pass dhcp-obstruction-symlink-fails-closed
  pass dhcp-obstruction-dangling-symlink-fails-closed
elif [ "$_dhcp_case_e_rc" -eq 200 ]; then
  fail "dhcp-obstruction-symlink-support-unavailable"
elif [ "$_dhcp_case_e_rc" -eq 201 ]; then
  fail "dhcp-obstruction-symlink-not-an-object"
else
  fail "dhcp-obstruction-matrix (rc=$_dhcp_case_e_rc)"
fi

# Case F — an injected timestamp-helper failure while the directory remains
# present is ambiguous. The primitive must return rc=2, retain the directory,
# and warn; it must never synthesize a fresh age and reclaim it.
(
  _CASE="$TEST_ROOT/dhcp-timestamp-retained"
  mkdir -p "$_CASE" || exit 1
  MERV_DHCP_HOLD_STATE_ROOT="$_CASE/state"
  export MERV_DHCP_HOLD_STATE_ROOT
  TRACE="$_CASE/trace.log"
  : > "$TRACE"
  info() { printf 'INFO:%s\n' "$*" >> "$TRACE"; }
  warn() { printf 'WARN:%s\n' "$*" >> "$TRACE"; }
  error() { printf 'ERROR:%s\n' "$*" >> "$TRACE"; }
  usleep() { :; }
  _merv_dhcp_nonce() { MERV_DHCP_NONCE=post-f; }
  merv_dhcp_state_lock_timestamp() { return 1; }
  mkdir -p "$MERV_DHCP_HOLD_STATE_ROOT" || exit 2
  mkdir "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" || exit 3
  merv_dhcp_state_lock_acquire > "$_CASE/output.log" 2>&1
  _rc=$?
  [ "$_rc" -eq 2 ] || exit 10
  [ -d "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" ] || exit 11
  grep -q '^WARN:' "$TRACE" || exit 12
  grep -q 'age is unverifiable' "$TRACE" || exit 13
)
_dhcp_case_f_rc=$?
if [ "$_dhcp_case_f_rc" -eq 0 ]; then
  pass dhcp-timestamp-failure-retains-incomplete
  pass dhcp-timestamp-failure-warns
else
  fail "dhcp-timestamp-failure-retained (rc=$_dhcp_case_f_rc)"
fi

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
