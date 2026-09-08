#!/bin/sh
# Offline H-04 regression coverage for the token-owned boot watchdog.
#
# The harness extracts only the production watchdog functions and supplies
# deterministic DHCP-owner stubs.  It never invokes ebtables, SSH, or a router.
# The real DHCP state engine's M-03 nonce-after-mkdir regression is covered by
# lifecycle_lock_contract_test.sh; this test exercises the watchdog handoff
# phases and its catchable/un-catchable interruption contract.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.boot-watchdog.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1

_p_before=""; _p_during=""; _p_after=""; _p_normal=""; _p_kill=""
_replace_writer_pid=""
_cleanup() {
  for _p in "$_p_before" "$_p_during" "$_p_after" "$_p_normal" "$_p_kill"; do
    [ -n "$_p" ] && kill "$_p" 2>/dev/null || :
  done
  # The replacement publisher can be waiting on the same transient lock when
  # an assertion fails.  Reap it before removing its workspace so no writer
  # survives this isolated fixture.
  [ -n "$_replace_writer_pid" ] && kill "$_replace_writer_pid" 2>/dev/null || :
  [ -n "$_replace_writer_pid" ] && wait "$_replace_writer_pid" 2>/dev/null || :
  rm -rf "$TEST_ROOT" 2>/dev/null || :
}
trap _cleanup 0 1 2 3 15

_failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _failures=1; }
pass() { printf 'PASS: %s\n' "$1"; }

# Build a small runner around the exact production functions.  The fixture
# records owner/handoff publication so the simulated SIGKILL case can prove
# that durable state is left for reconciliation.
_fixture="$TEST_ROOT/watchdog_fixture.sh"
{
  printf '%s\n' '#!/bin/sh' 'set -u'
  cat <<'EOF'
PHASE_DIR=${MERV_TEST_PHASE_DIR:?}
info() { :; }
warn() { :; }
merv_owner_lock_acquire() {
  _lock="$1"
  mkdir -p "${_lock%/*}" 2>/dev/null || return 1
  while ! mkdir "$_lock" 2>/dev/null; do sleep 1; done
  _start=$(merv_proc_start_time "$$") || { rmdir "$_lock" 2>/dev/null || :; return 1; }
  case "$_start" in ''|*[!0-9]*|0) rmdir "$_lock" 2>/dev/null || :; return 1 ;; esac
  MERV_LOCK_NONCE="fixture-lock-$$"
  MERV_LOCK_START="$_start"
  # Model the authoritative v2 owner record exactly: parent rollback must
  # prove this process, start time, and nonce while it still owns the lock.
  printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=1\nheartbeat=1\n' \
    "$$" "$MERV_LOCK_START" "$MERV_LOCK_NONCE" > "$_lock/owner" || {
      rmdir "$_lock" 2>/dev/null || :
      return 1
    }
  return 0
}
merv_dhcp_hold_valid_id() { case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
merv_proc_start_time() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
merv_process_identity_matches() {
  _pid="$1"; _start="$2"
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$_start" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$_pid" 2>/dev/null || return 1
  [ "$(merv_proc_start_time "$_pid" 2>/dev/null || printf '')" = "$_start" ]
}
merv_owner_lock_owner_matches() {
  _lock="$1"; _nonce="$2"
  [ -d "$_lock" ] && [ -f "$_lock/owner" ] || return 1
  _start=$(merv_proc_start_time "$$" 2>/dev/null || printf '')
  case "$_start" in ''|*[!0-9]*|0) return 1 ;; esac
  _expected=$(printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=1\nheartbeat=1' \
    "$$" "$_start" "$_nonce")
  [ "$(cat "$_lock/owner" 2>/dev/null || printf '')" = "$_expected" ] || return 1
  merv_process_identity_matches "$$" "$_start"
}
merv_owner_lock_release() {
  _lock="$1"; _nonce="${2:-${MERV_LOCK_NONCE:-}}"
  [ -d "$_lock" ] || return 0
  merv_owner_lock_owner_matches "$_lock" "$_nonce" || return 1
  rm -f "$_lock/owner" || return 1
  rmdir "$_lock" 2>/dev/null || return 1
  MERV_LOCK_NONCE=''; MERV_LOCK_START=''
}
merv_dhcp_hold_acquire() {
  printf '%s\n' acquired > "$PHASE_DIR/acquire"
  if [ "${WATCHDOG_PHASE:-}" = before ]; then sleep 20; fi
  : > "$PHASE_DIR/owner.active"
  MERV_DHCP_HOLD_TOKEN=watch-token
  return 0
}
merv_dhcp_handoff_request() {
  : > "$PHASE_DIR/handoff.active"
  MERV_DHCP_HANDOFF_ID=handoff-test
  return 0
}
merv_dhcp_hold_mark_handoff_wait() { : > "$PHASE_DIR/handoff-wait"; return 0; }
merv_dhcp_hold_enforce() { sleep 1; return 0; }
merv_dhcp_hold_abandon() { : > "$PHASE_DIR/abandon"; return 0; }
merv_dhcp_handoff_parent_abort() {
  _mode=$(cat "$PHASE_DIR/abort_mode" 2>/dev/null || printf uncertain)
  case "$_mode" in
    complete) MERV_DHCP_HANDOFF_ABORT_STATE=successor-verified; : > "$PHASE_DIR/successor-preserved"; return 0 ;;
    incomplete) MERV_DHCP_HANDOFF_ABORT_STATE=abandoned; : > "$PHASE_DIR/abandoned"; return 0 ;;
    replace) : > "$PHASE_DIR/abort-started"; sleep 2; MERV_DHCP_HANDOFF_ABORT_STATE=successor-verified; return 0 ;;
    *) return 1 ;;
  esac
}
EOF
  # Keep this extraction resilient to line movement within the source file.
  awk '/^_merv_boot_watchdog_publish_state\(\) \{/{p=1} /^_mode_shield\(\) \{/{p=0} p' \
    "$BASE_DIR/functions/mervlan_boot_wrap.sh"
  cat <<'EOF'
case "${1:-}" in
  run)
    _pid_file="$6"
    printf '%s\n' "$$" > "$_pid_file"
    printf '%s\n' "$(merv_proc_start_time "$$")" > "${_pid_file}.start"
    _mode_shield_watchdog "$@"
    ;;
  *) exit 2 ;;
esac
EOF
} > "$_fixture" 2>/dev/null
chmod 700 "$_fixture" || exit 1

_wait_for() {
  _wf_path="$1"; _wf_n=0
  while [ ! -e "$_wf_path" ] && [ "$_wf_n" -lt 20 ]; do
    sleep 1
    _wf_n=$((_wf_n + 1))
  done
  [ -e "$_wf_path" ]
}

_run_watchdog() {
  _rw_name="$1"; _rw_phase="$2"; _rw_mode="$3"
  _rw_dir="$TEST_ROOT/$_rw_name"
  _rw_run="$_rw_name-run"
  mkdir -p "$_rw_dir" || return 1
  printf 'run_id=%s\n' "$_rw_run" > "$_rw_dir/marker" || return 1
  printf '%s\n' "$_rw_mode" > "$_rw_dir/abort_mode"
  MERV_TEST_PHASE_DIR="$_rw_dir" WATCHDOG_PHASE="$_rw_phase" LOCKDIR="$_rw_dir/locks" \
    "$_fixture" run "$_rw_dir/marker" "$_rw_dir/ready" \
      "$_rw_dir/context" 60 "$_rw_dir/pid" "$_rw_run" &
  _rw_pid=$!
  case "$_rw_name" in
    before) _p_before="$_rw_pid" ;;
    during) _p_during="$_rw_pid" ;;
    after) _p_after="$_rw_pid" ;;
    normal) _p_normal="$_rw_pid" ;;
    kill) _p_kill="$_rw_pid" ;;
  esac
}

# TERM before DHCP ownership is published: only this watchdog's transient
# marker is removed; no unverified lease cleanup is attempted.
_before_dir="$TEST_ROOT/before"
_run_watchdog before before incomplete || fail watchdog-before-start
_before_pid="$_rw_pid"
_wait_for "$_before_dir/acquire" || fail watchdog-before-acquire
kill -TERM "$_before_pid" 2>/dev/null || :
wait "$_before_pid" 2>/dev/null; _before_rc=$?
[ "$_before_rc" -eq 143 ] || fail "TERM-before-handoff exit rc=$_before_rc"
[ ! -e "$_before_dir/marker" ] || fail watchdog-before-marker-retained
[ ! -e "$_before_dir/abandon" ] || fail watchdog-before-unowned-abandon
[ ! -e "$_before_dir/owner.active" ] || fail watchdog-before-owner-published
[ ! -e "$_before_dir/marker" ] && pass term-before-handoff

# TERM during the published handoff converts only the watchdog parent to an
# abandoned/failsafe state; no successor ownership exists in this phase.
_during_dir="$TEST_ROOT/during"
_run_watchdog during during incomplete || fail watchdog-during-start
_during_pid="$_rw_pid"
_wait_for "$_during_dir/context" || fail watchdog-during-context
kill -TERM "$_during_pid" 2>/dev/null || :
wait "$_during_pid" 2>/dev/null; _during_rc=$?
[ "$_during_rc" -eq 143 ] || fail "TERM-during-handoff exit rc=$_during_rc"
[ -e "$_during_dir/abandoned" ] || fail watchdog-during-not-abandoned
[ ! -e "$_during_dir/successor-preserved" ] || fail watchdog-during-successor-marker
[ ! -e "$_during_dir/marker" ] || fail watchdog-during-marker-retained
[ -e "$_during_dir/abandoned" ] && [ ! -e "$_during_dir/successor-preserved" ] && pass term-during-handoff

# If the successor completes before TERM, cleanup retires only the parent and
# never calls the generic abandon path that could remove successor ownership.
_after_dir="$TEST_ROOT/after"
_run_watchdog after after uncertain || fail watchdog-after-start
_after_pid="$_rw_pid"
_wait_for "$_after_dir/context" || fail watchdog-after-context
printf '%s\n' complete > "$_after_dir/abort_mode"
kill -TERM "$_after_pid" 2>/dev/null || :
wait "$_after_pid" 2>/dev/null; _after_rc=$?
[ "$_after_rc" -eq 143 ] || fail "TERM-after-successor exit rc=$_after_rc"
[ -e "$_after_dir/successor-preserved" ] || fail watchdog-after-successor-not-preserved
[ ! -e "$_after_dir/abandon" ] || fail watchdog-after-called-generic-abandon
[ ! -e "$_after_dir/marker" ] || fail watchdog-after-marker-retained
[ -e "$_after_dir/successor-preserved" ] && [ ! -e "$_after_dir/abandon" ] && pass term-after-verified-successor

# Normal completion uses the same terminal path and leaves no transient state.
_normal_dir="$TEST_ROOT/normal"
_run_watchdog normal normal complete || fail watchdog-normal-start
_normal_pid="$_rw_pid"
_wait_for "$_normal_dir/context" || fail watchdog-normal-context
rm -f "$_normal_dir/marker"
wait "$_normal_pid" 2>/dev/null; _normal_rc=$?
[ "$_normal_rc" -eq 0 ] || fail "normal watchdog exit rc=$_normal_rc"
[ ! -e "$_normal_dir/marker" ] && [ ! -e "$_normal_dir/context" ] &&
  pass normal-completion-cleans-transient-state

# A replacement watchdog may publish while an old watchdog is retiring.  Both
# publication and cleanup use the exact transient lock; the old run must leave
# replacement marker/context/pid files untouched and report reconciliation.
_replace_dir="$TEST_ROOT/replace"
_run_watchdog replace replace replace || fail watchdog-replace-start
_replace_pid="$_rw_pid"
_wait_for "$_replace_dir/context" || fail watchdog-replace-context
rm -f "$_replace_dir/marker"
_wait_for "$_replace_dir/abort-started" || fail watchdog-replace-abort-window
_replace_writer="$_replace_dir/write-replacement.sh"
cat > "$_replace_writer" <<'EOF'
#!/bin/sh
set -u
_lock="$1"; _root="$2"
while ! mkdir "$_lock" 2>/dev/null; do sleep 1; done
printf 'run_id=replacement-run\n' > "$_root/marker"
printf 'parent_run_id=replacement-run\nhandoff_id=replacement-handoff\nwatchdog_state=handoff-published\n' > "$_root/context"
printf 'replacement\n' > "$_root/ready"
printf '999999\n' > "$_root/pid"
printf '1\n' > "$_root/pid.start"
sleep 2
rmdir "$_lock" 2>/dev/null || :
EOF
chmod 700 "$_replace_writer"
"$_replace_writer" "$_replace_dir/locks/merv_boot_shield.transient.lock" "$_replace_dir" &
_replace_writer_pid=$!
wait "$_replace_pid" 2>/dev/null; _replace_rc=$?
wait "$_replace_writer_pid" 2>/dev/null || :
_replace_writer_pid=""
[ "$_replace_rc" -ne 0 ] || fail 'replacement race unexpectedly reported clean completion'
[ -e "$_replace_dir/marker" ] && [ -e "$_replace_dir/context" ] &&
  [ -e "$_replace_dir/pid" ] && [ -e "$_replace_dir/pid.start" ] ||
  fail 'replacement watchdog transients were deleted by old cleanup'
[ -e "$_replace_dir/marker" ] && [ -e "$_replace_dir/context" ] &&
  pass replacement-transients-preserved

# SIGKILL cannot run a shell trap.  Durable owner/handoff state and the marker
# therefore remain, allowing the next reconciliation pass to keep DHCP held.
_kill_dir="$TEST_ROOT/kill"
_run_watchdog kill kill uncertain || fail watchdog-kill-start
_kill_pid="$_rw_pid"
_wait_for "$_kill_dir/context" || fail watchdog-kill-context
kill -KILL "$_kill_pid" 2>/dev/null || :
wait "$_kill_pid" 2>/dev/null; _kill_rc=$?
[ "$_kill_rc" -eq 137 ] || fail "simulated SIGKILL exit rc=$_kill_rc"
[ -e "$_kill_dir/marker" ] || fail sigkill-marker-not-retained
[ -e "$_kill_dir/owner.active" ] && [ -e "$_kill_dir/handoff.active" ] || fail sigkill-durable-owner-state
[ -e "$_kill_dir/marker" ] && [ -e "$_kill_dir/owner.active" ] &&
  pass sigkill-leaves-durable-fail-closed-state

[ "$_failures" -eq 0 ] || { printf 'BOOT_WATCHDOG_DHCP_CONTRACT_FAILED\n' >&2; exit 1; }
printf 'BOOT_WATCHDOG_DHCP_CONTRACT_OK\n'
exit 0
