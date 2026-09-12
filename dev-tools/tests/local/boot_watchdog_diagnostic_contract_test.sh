#!/bin/sh
# Early boot watchdog diagnostic contract test
# Exercises early watchdog startup stages to verify:
# 1. Failure remains nonzero
# 2. Each stage has a distinct stable diagnostic identifier/message:
#    - transient-lock-enter
#    - marker-claim
#    - transient-lock-leave
#    - mark-handoff-wait
#    - ready-lock-enter
#    - ready-publication marker/PID/start/process/context/ready predicates
#    - ready-lock-leave
# 3. PID/start evidence is emitted safely
# 4. Lock-state reporting does not mutate the lock
# 5. Readiness timeout cleans dead child PID/start safely without cleaning live or replacement
set -u

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
TEST_ROOT="/tmp/mervlan_tmp/selftest.boot-watchdog-diag.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
_RUNNER_PID=""
_OLD_CHILD_PID=""
_REPLACEMENT_CHILD_PID=""
_MANAGER_PID=""
_MANAGER_HANDOFF_PID=""
_cleanup_test() {
  [ -n "$_OLD_CHILD_PID" ] && kill "$_OLD_CHILD_PID" 2>/dev/null || :
  [ -n "$_REPLACEMENT_CHILD_PID" ] && kill "$_REPLACEMENT_CHILD_PID" 2>/dev/null || :
  [ -n "$_RUNNER_PID" ] && kill "$_RUNNER_PID" 2>/dev/null || :
  [ -n "$_MANAGER_PID" ] && kill "$_MANAGER_PID" 2>/dev/null || :
  [ -n "$_MANAGER_HANDOFF_PID" ] && kill "$_MANAGER_HANDOFF_PID" 2>/dev/null || :
  [ "${MERV_TEST_KEEP:-0}" -eq 1 ] || rm -rf "$TEST_ROOT"
}
trap _cleanup_test 0 1 2 3 15

_FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _FAILURES=$((_FAILURES + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }

# Build the fixture runner around production watchdog functions
FIXTURE="$TEST_ROOT/watchdog_fixture.sh"
{
  printf '%s\n' '#!/bin/sh' 'set -u'
  printf 'MERV_TEST_PRODUCTION_BASE=%s\n' "$BASE_DIR"
  cat <<'EOF'
PHASE_DIR=${MERV_TEST_PHASE_DIR:?}
LOGDIR="$PHASE_DIR/logs"
TMPDIR="$PHASE_DIR/tmp"
LOCKDIR="$PHASE_DIR/locks"
SETTINGS_FILE="$PHASE_DIR/settings.json"
MERV_BASE="$PHASE_DIR/no-production"
VLAN_MANAGER="$PHASE_DIR/manager"
mkdir -p "$LOGDIR" "$TMPDIR" "$LOCKDIR"
LOG_chan_boot="$LOGDIR/boot_wrap.log"
: > "$LOG_chan_boot"

info() { echo "INFO: $*" >> "$LOG_chan_boot"; }
warn() { echo "WARN: $*" >> "$LOG_chan_boot"; }
error() { echo "ERROR: $*" >> "$LOG_chan_boot"; }

merv_proc_start_time() {
  if [ "${FAULT_START_LOOKUP:-}" = once ] && [ "${1:-}" != "$$" ] &&
     [ ! -e "$PHASE_DIR/start-lookup-failed-once" ]; then
    : > "$PHASE_DIR/start-lookup-failed-once"
    return 1
  fi
  awk '{print $22}' "/proc/$1/stat" 2>/dev/null || printf '1'
}
merv_identity_current_start() { merv_proc_start_time "$$"; }
kill() {
  if [ "${1:-}" = '-0' ] && [ -f "$PHASE_DIR/term-pid-reuse-observed" ] &&
     [ "${2:-}" = "$(cat "$PHASE_DIR/watchdog-child-pid" 2>/dev/null || printf '')" ]; then
    return 0
  fi
  if [ "${1:-}" = '-0' ] && [ -f "$PHASE_DIR/dead-pid" ] &&
     [ -f "$PHASE_DIR/allow-dead-exit" ] &&
     [ "${2:-}" = "$(cat "$PHASE_DIR/dead-pid" 2>/dev/null || printf '')" ]; then
    return 1
  fi
  # Model TERM racing a child disappearance: the parent has already proven
  # PID/start under its transient lock, but the signal reports failure after
  # the exact child has exited.  The real rollback path must reclassify the
  # unchanged partial publication instead of treating TERM's status as proof.
  if [ "${1:-}" = '-TERM' ] && [ -f "$PHASE_DIR/fault_parent_term_disappear" ] &&
     [ "${2:-}" = "$(cat "$PHASE_DIR/watchdog-child-pid" 2>/dev/null || printf '')" ]; then
    command kill -KILL "$2" 2>/dev/null || :
    return 1
  fi
  if [ "${1:-}" = '-TERM' ] && [ -f "$PHASE_DIR/fault_parent_term_pid_reuse" ] &&
     [ "${2:-}" = "$(cat "$PHASE_DIR/watchdog-child-pid" 2>/dev/null || printf '')" ]; then
    command kill -TERM "$2" 2>/dev/null || :
    : > "$PHASE_DIR/term-pid-reuse-observed"
    return 0
  fi
  if [ "${1:-}" = '-TERM' ] && [ -f "$PHASE_DIR/fault_parent_term_replace" ] &&
     [ "${2:-}" = "$(cat "$PHASE_DIR/watchdog-child-pid" 2>/dev/null || printf '')" ]; then
    command kill -TERM "$2" 2>/dev/null || :
    (sleep 30) &
    _term_successor=$!
    _term_successor_start=$(merv_proc_start_time "$_term_successor" 2>/dev/null || printf '')
    printf 'run_id=term-replacement-run\n' > "$LOCKDIR/merv_boot_shield.active"
    printf '%s\n' "$_term_successor" > "$LOCKDIR/merv_boot_shield.pid"
    printf '%s\n' "$_term_successor_start" > "$LOCKDIR/merv_boot_shield.pid.start"
    printf 'parent_run_id=term-replacement-run\nhandoff_id=term-replacement-handoff\nwatchdog_state=handoff-published\n' > "$LOCKDIR/merv_boot_shield.handoff"
    printf '%s\n' "$_term_successor" > "$LOCKDIR/merv_boot_shield.ready"
    printf '%s\n' "$_term_successor" > "$PHASE_DIR/term-successor-pid"
    return 0
  fi
  if [ "${1:-}" = '-TERM' ] && [ -f "$PHASE_DIR/fault_parent_term_live" ] &&
     [ "${2:-}" = "$(cat "$PHASE_DIR/watchdog-child-pid" 2>/dev/null || printf '')" ]; then
    : > "$PHASE_DIR/term-live-observed"
    return 0
  fi
  if [ "${1:-}" = '-TERM' ] && [ -f "$PHASE_DIR/record_parent_leave_term" ]; then
    : > "$PHASE_DIR/parent-leave-term-attempted"
  fi
  command kill "$@"
}
merv_process_identity_matches() {
  _mpim_p="$1"; _mpim_s="$2"
  [ -n "$_mpim_p" ] && [ -n "$_mpim_s" ] || return 1
  [ -d "$LOCKDIR/merv_boot_shield.transient.lock" ] && : > "$PHASE_DIR/identity-checked-under-lock"
  if [ "${MERV_TEST_GENERIC_TRANSIENT_LOCK:-0}" = 1 ] &&
     [ -f "$PHASE_DIR/handoff-wait-passed" ]; then
    merv_owner_lock_owner_matches "$LOCKDIR/merv_boot_shield.transient.lock" \
      "${MERV_LOCK_NONCE:-}" || return 1
    : > "$PHASE_DIR/generic-ready-owner-authenticated"
  fi
  if [ -f "$PHASE_DIR/fault_ready_process" ]; then
    return 19
  fi
  if [ -f "$PHASE_DIR/fault_parent_leave_pid_reuse" ] &&
     [ -f "$PHASE_DIR/fault_transient_leave" ] &&
     [ "$_mpim_p" = "$(cat "$PHASE_DIR/watchdog-child-pid" 2>/dev/null || printf '')" ]; then
    return 1
  fi
  if [ -f "$PHASE_DIR/term-pid-reuse-observed" ] &&
     [ "$_mpim_p" = "$(cat "$PHASE_DIR/watchdog-child-pid" 2>/dev/null || printf '')" ]; then
    return 1
  fi
  if [ -f "$PHASE_DIR/term-live-observed" ] &&
     [ "$_mpim_p" = "$(cat "$PHASE_DIR/watchdog-child-pid" 2>/dev/null || printf '')" ]; then
    printf 'poll\n' >> "$PHASE_DIR/term-live-identity-polls"
  fi
  # Boundary injection for a classification-to-cleanup race: publish a live
  # successor after the stale owner has already been observed dead. The
  # production reclassification must reject cleanup of that replacement.
  # This must precede the fixture's normal live-identity probe because the
  # injected old PID is intentionally absent.
  if [ -f "$PHASE_DIR/publish-successor-on-dead-classification" ] &&
     [ ! -f "$PHASE_DIR/successor-published-at-dead" ] &&
     ! kill -0 "$_mpim_p" 2>/dev/null; then
    _successor_pid=$(cat "$PHASE_DIR/successor.pid" 2>/dev/null || printf '')
    _successor_start=$(cat "$PHASE_DIR/successor.start" 2>/dev/null || printf '')
    printf 'run_id=successor-dead-run\n' > "$LOCKDIR/merv_boot_shield.active"
    printf 'parent_run_id=successor-dead-run\nhandoff_id=successor-dead-handoff\nwatchdog_state=handoff-published\n' > "$LOCKDIR/merv_boot_shield.handoff"
    printf '%s\n' "$_successor_pid" > "$LOCKDIR/merv_boot_shield.ready"
    printf '%s\n' "$_successor_pid" > "$LOCKDIR/merv_boot_shield.pid"
    printf '%s\n' "$_successor_start" > "$LOCKDIR/merv_boot_shield.pid.start"
    : > "$PHASE_DIR/successor-published-at-dead"
  fi
  kill -0 "$_mpim_p" 2>/dev/null || return 1
  # Boundary injection for the replacement-owner regression: publish the
  # successor only after the real production path has read the old PID/start
  # pair and proven that the PID is still live but its start identity differs.
  # The production function must re-check ownership before removing state.
  if [ -f "$PHASE_DIR/publish-successor-on-identity-mismatch" ] &&
     [ ! -f "$PHASE_DIR/successor-published-at-identity" ] &&
     [ "$(merv_proc_start_time "$_mpim_p")" != "$_mpim_s" ]; then
    _successor_pid=$(cat "$PHASE_DIR/successor.pid" 2>/dev/null || printf '')
    _successor_start=$(cat "$PHASE_DIR/successor.start" 2>/dev/null || printf '')
    printf 'run_id=successor-identity-run\n' > "$LOCKDIR/merv_boot_shield.active"
    printf 'parent_run_id=successor-identity-run\nhandoff_id=successor-identity-handoff\nwatchdog_state=handoff-published\n' > "$LOCKDIR/merv_boot_shield.handoff"
    printf 'successor-identity-ready\n' > "$LOCKDIR/merv_boot_shield.ready"
    printf '%s\n' "$_successor_pid" > "$LOCKDIR/merv_boot_shield.pid"
    printf '%s\n' "$_successor_start" > "$LOCKDIR/merv_boot_shield.pid.start"
    : > "$PHASE_DIR/successor-published-at-identity"
  fi
  [ "$(merv_proc_start_time "$_mpim_p")" = "$_mpim_s" ]
}
merv_owner_lock_state() { printf 'held'; }
# The generic-ready cases install a complete actual contender after the first
# transient release. This hook mutates that contender only when the second
# acquire has observed its owner and crossed the named classifier boundary.
merv_owner_lock_state_hook() {
  _molsh_point="${1:-}"; _molsh_lock="${2:-}"
  [ -n "${MERV_TEST_GENERIC_READY_RACE:-}" ] || return 1
  [ "$_molsh_point" = before-readable ] || return 1
  [ ! -e "$PHASE_DIR/generic-ready-race-fired" ] || return 0
  case "$MERV_TEST_GENERIC_READY_RACE" in
    disappearance)
      rm -rf "$_molsh_lock" 2>/dev/null || return 1
      ;;
    obstruction)
      rm -rf "$_molsh_lock" 2>/dev/null || return 1
      : > "$_molsh_lock"
      ;;
    replacement)
      rm -rf "$_molsh_lock" 2>/dev/null || return 1
      mkdir "$_molsh_lock" || return 1
      _molsh_start=$(merv_identity_current_start /proc 2>/dev/null) || return 1
      merv_owner_v2_write_atomic "$_molsh_lock" "$$" "$_molsh_start" \
        ready-race-replacement 1 1 || return 1
      ;;
    *) return 1 ;;
  esac
  : > "$PHASE_DIR/generic-ready-race-fired"
  return 0
}
ebtables() { return 0; }
merv_boot_shield_lan_configured() { return 0; }
_is_update_or_safe_boot_active() { return 1; }
_flag_exists() { return 0; }
_is_node_runtime() { return 1; }
_write_flag() { return 0; }
EOF

  # Extract production watchdog functions from mervlan_boot_wrap.sh
  awk '/^_merv_boot_watchdog_publish_state\(\) \{/{p=1} /^_is_update_recovery_or_safe_boot_active\(\) \{/{p=0} p' \
    "$BASE_DIR/functions/mervlan_boot_wrap.sh"

  # Extract the real manager path as a separate production-path fixture. The
  # manager is exercised below with an isolated blocking VLAN_MANAGER command.
  awk '/^_mode_manager\(\) \{/{p=1} p; p && /^}$/ {exit}' \
    "$BASE_DIR/functions/mervlan_boot_wrap.sh"

  # Override the transient lock only; marker claim and publication remain the
  # exact production helpers so rollback cases exercise their real paths.
  cat <<'EOF'
_merv_boot_watchdog_transient_lock_enter() {
  if [ "${MERV_TEST_GENERIC_TRANSIENT_LOCK:-0}" = 1 ]; then
    _lock="${LOCKDIR}/merv_boot_shield.transient.lock"
    merv_owner_lock_acquire "$_lock" 30 "${MERV_TEST_GENERIC_TRANSIENT_MAX:-30}" \
      boot-shield-transient || return $?
    _lock_count=$(cat "$PHASE_DIR/lock-count" 2>/dev/null || printf '0')
    case "$_lock_count" in ''|*[!0-9]*) _lock_count=0 ;; esac
    _lock_count=$((_lock_count + 1))
    printf '%s\n' "$_lock_count" > "$PHASE_DIR/lock-count"
    [ "$_lock_count" -eq 2 ] && : > "$PHASE_DIR/generic-ready-lock-acquired"
    return 0
  fi
  if [ -f "$PHASE_DIR/fault_transient_enter" ]; then
    return 7
  fi
  if [ -f "$PHASE_DIR/fault_ready_lock_enter" ] &&
     [ -f "$PHASE_DIR/publication-initialized" ]; then
    return 23
  fi
  if [ -f "$PHASE_DIR/fail-reconcile-lock" ] &&
     [ -f "$PHASE_DIR/publication-initialized" ]; then
    return 17
  fi
  _lock="${LOCKDIR}/merv_boot_shield.transient.lock"
  [ ! -e "$_lock" ] || return 1
  mkdir -p "$_lock" 2>/dev/null || return 1
  _lock_count=$(cat "$PHASE_DIR/lock-count" 2>/dev/null || printf '0')
  case "$_lock_count" in ''|*[!0-9]*) _lock_count=0 ;; esac
  _lock_count=$((_lock_count + 1))
  printf '%s\n' "$_lock_count" > "$PHASE_DIR/lock-count"
  [ "$_lock_count" -eq 1 ] && : > "$PHASE_DIR/publication-initialized"
  if [ "${WATCHDOG_MODE:-}" = replacement ] && [ "$_lock_count" -eq 2 ] &&
     [ ! -f "$PHASE_DIR/replacement-published" ]; then
    _replacement_pid=$(cat "$PHASE_DIR/replacement.pid" 2>/dev/null || printf '')
    _replacement_start=$(cat "$PHASE_DIR/replacement.start" 2>/dev/null || printf '')
    printf 'run_id=replacement-run\n' > "$LOCKDIR/merv_boot_shield.active"
    printf 'parent_run_id=replacement-run\nhandoff_id=replacement-handoff\nwatchdog_state=handoff-published\n' > "$LOCKDIR/merv_boot_shield.handoff"
    printf 'replacement-ready\n' > "$LOCKDIR/merv_boot_shield.ready"
    printf '%s\n' "$_replacement_pid" > "$LOCKDIR/merv_boot_shield.pid"
    printf '%s\n' "$_replacement_start" > "$LOCKDIR/merv_boot_shield.pid.start"
    : > "$PHASE_DIR/replacement-published"
  fi
  MERV_LOCK_NONCE="fixture-nonce-$$"
  return 0
}

_merv_boot_watchdog_transient_lock_leave() {
  if [ "${MERV_TEST_GENERIC_TRANSIENT_LOCK:-0}" = 1 ]; then
    _lock="${LOCKDIR}/merv_boot_shield.transient.lock"
    merv_owner_lock_release "$_lock" "${MERV_LOCK_NONCE:-}" || return $?
    _lock_count=$(cat "$PHASE_DIR/lock-count" 2>/dev/null || printf '0')
    if [ "$_lock_count" -eq 1 ] 2>/dev/null; then
      : > "$PHASE_DIR/generic-initial-lock-released"
      if [ -n "${MERV_TEST_GENERIC_READY_RACE:-}" ]; then
        merv_owner_lock_acquire "$_lock" 30 0 ready-race-contender || return $?
        : > "$PHASE_DIR/generic-contender-published"
        MERV_OWNER_LOCK_FAULT=state-owner-before-readable
        export MERV_OWNER_LOCK_FAULT
      fi
    fi
    return 0
  fi
  if [ -f "$PHASE_DIR/fault_parent_leave_identity_replacement" ] &&
     [ ! -e "$PHASE_DIR/parent-leave-successor-pid" ]; then
    (sleep 30) &
    _plr_successor=$!
    _plr_start=$(merv_proc_start_time "$_plr_successor" 2>/dev/null || printf '')
    printf 'run_id=leave-replacement-run\n' > "$LOCKDIR/merv_boot_shield.active"
    printf '%s\n' "$_plr_successor" > "$LOCKDIR/merv_boot_shield.pid"
    printf '%s\n' "$_plr_start" > "$LOCKDIR/merv_boot_shield.pid.start"
    printf 'parent_run_id=leave-replacement-run\nhandoff_id=leave-replacement-handoff\nwatchdog_state=handoff-published\n' > "$LOCKDIR/merv_boot_shield.handoff"
    printf '%s\n' "$_plr_successor" > "$LOCKDIR/merv_boot_shield.ready"
    printf '%s\n' "$_plr_successor" > "$PHASE_DIR/parent-leave-successor-pid"
  fi
  if [ -f "$PHASE_DIR/fault_transient_leave" ]; then
    return 9
  fi
  if [ -f "$PHASE_DIR/fault_ready_lock_leave" ] &&
     [ -f "$PHASE_DIR/handoff-wait-passed" ]; then
    return 31
  fi
  _lock="${LOCKDIR}/merv_boot_shield.transient.lock"
  rmdir "$_lock" 2>/dev/null || rm -rf "$_lock" 2>/dev/null || :
  return 0
}

merv_owner_lock_owner_matches() {
  [ -d "${1:-}" ] && [ "${2:-}" = "${MERV_LOCK_NONCE:-}" ] || return 1
  : > "$PHASE_DIR/parent-rollback-lock-owned"
  return 0
}

# Fail only the selected atomic publication rename.  The production helper
# has already created and verified its private same-directory temporary file,
# so this exercises the parent rollback paths without changing their parser or
# cleanup behavior.
mv() {
  case "$1:$2" in
    "$LOCKDIR/merv_boot_shield.active.marker."*:"$LOCKDIR/merv_boot_shield.active")
      : > "$PHASE_DIR/actual-claim-marker"
      ;;
    "$LOCKDIR/merv_boot_shield.pid.pid."*:"$LOCKDIR/merv_boot_shield.pid")
      : > "$PHASE_DIR/actual-publish-pid"
      ;;
    "$LOCKDIR/merv_boot_shield.pid.start.pid-start."*:"$LOCKDIR/merv_boot_shield.pid.start")
      : > "$PHASE_DIR/actual-publish-pid-start"
      ;;
    "$LOCKDIR/merv_boot_shield.handoff.context."*:"$LOCKDIR/merv_boot_shield.handoff")
      : > "$PHASE_DIR/actual-publish-context"
      ;;
  esac
  if [ -f "$PHASE_DIR/fault_claim_marker" ]; then
    case "$1" in *.marker.*) return 1 ;; esac
  fi
  case "${FAULT_PUBLISH_STAGE:-}:$1" in
    pid:"$LOCKDIR/merv_boot_shield.pid.pid."*) return 1 ;;
    pid-start:"$LOCKDIR/merv_boot_shield.pid.start.pid-start."*) return 1 ;;
    context:"$LOCKDIR/merv_boot_shield.handoff.context."*) return 1 ;;
  esac
  if [ "$2" = "$PHASE_DIR/context" ] &&
     [ -f "$PHASE_DIR/fault_ready_context" ] &&
     [ -f "$PHASE_DIR/handoff-wait-passed" ]; then
    return 29
  fi
  if [ "$2" = "$PHASE_DIR/ready" ] &&
     [ -f "$PHASE_DIR/fault_ready_publication" ]; then
    return 37
  fi
  command mv "$@"
}

merv_dhcp_hold_acquire() { MERV_DHCP_HOLD_TOKEN=token-fixture; return 0; }
merv_dhcp_hold_release() { : > "$PHASE_DIR/dhcp-release-called"; return 0; }
merv_dhcp_handoff_request() { MERV_DHCP_HANDOFF_ID=h-test; return 0; }
merv_dhcp_hold_mark_handoff_wait() {
  if [ -f "$PHASE_DIR/fault_ready_marker_read" ]; then
    printf '%s\n' malformed-marker > "$_shield_marker"
  elif [ -f "$PHASE_DIR/fault_ready_marker_match" ]; then
    printf '%s\n' run_id=replacement-run > "$_shield_marker"
  elif [ -f "$PHASE_DIR/fault_ready_pid" ]; then
    printf '%s\n' 999999 > "$_pid_file"
  elif [ -f "$PHASE_DIR/fault_ready_pid_start" ]; then
    printf '%s9\n' "$_self_start" > "$_pid_start_file"
  fi
  : > "$PHASE_DIR/handoff-wait-passed"
  if [ -f "$PHASE_DIR/fault_mark_handoff_wait" ]; then
    return 17
  fi
  return 0
}
merv_dhcp_hold_enforce() { sleep 1; return 0; }
merv_dhcp_hold_abandon() { return 0; }
merv_dhcp_handoff_parent_abort() { MERV_DHCP_HANDOFF_ABORT_STATE=successor-verified; return 0; }

# The regular fixture uses controlled transient-lock stand-ins. Generic-lock
# cases opt in to the installed production sources and the wrapper above then
# delegates its lock entry/leave calls to the real generic owner lifecycle.
if [ "${MERV_TEST_GENERIC_TRANSIENT_LOCK:-0}" = 1 ]; then
  MERV_BASE="$MERV_TEST_PRODUCTION_BASE"
  . "$MERV_BASE/settings/lib_identity.sh" || exit 90
  . "$MERV_BASE/settings/lib_owner_lock.sh" || exit 91
fi

case "${1:-}" in
  run-watchdog)
    _shield_marker="$2"
    _ready_file="$3"
    _context_file="$4"
    _max="$5"
    _pid_file="$6"
    printf '%s\n' "$$" > "$_pid_file"
    printf '%s\n' "$(merv_proc_start_time "$$")" > "${_pid_file}.start"
    _mode_shield_watchdog "$@"
    exit $?
    ;;
  run-shield)
    _mode_shield
    exit $?
    ;;
  run-readiness)
    _run_id="$2"
    _shield_marker="$3"
    _ready_file="$4"
    _context_file="$5"
    _pid_file="$6"
    _pid_start_file="$7"
    _watchdog_transient_lock="$LOCKDIR/merv_boot_shield.transient.lock"
    _ready_case="${8:-exact}"
    _self_start=$(merv_proc_start_time "$$")
    printf 'run_id=%s\n' "$_run_id" > "$_shield_marker"
    printf '%s\n' "$$" > "$_pid_file"
    printf '%s\n' "$_self_start" > "$_pid_start_file"
    printf 'parent_run_id=%s\nhandoff_id=readiness-handoff\nwatchdog_state=handoff-published\n' \
      "$_run_id" > "$_context_file"
    printf '%s\n' "$$" > "$_ready_file"
    case "$_ready_case" in
      replacement)
        printf 'run_id=successor-ready-run\n' > "$_shield_marker"
        printf 'parent_run_id=successor-ready-run\nhandoff_id=successor-ready-handoff\nwatchdog_state=handoff-published\n' > "$_context_file"
        printf '%s\n' "$$" > "$_ready_file"
        ;;
      pid-reuse)
        printf '%s9\n' "$_self_start" > "$_pid_start_file"
        ;;
    esac
    _merv_boot_watchdog_readiness_valid "$_run_id" "$$" "$_self_start" \
      "$_shield_marker" "$_ready_file" "$_context_file" \
      "$_pid_file" "$_pid_start_file"
    exit $?
    ;;
  temp-symlink)
    _run_id=temp-symlink-run
    _handoff_id=pending
    _context_file="$LOCKDIR/merv_boot_shield.handoff"
    _shield_marker="$LOCKDIR/merv_boot_shield.active"
    _tmp_target="$PHASE_DIR/temp-target"
    ln -s "$_tmp_target" "${_context_file}.context.$$" 2>/dev/null || exit 200
    _merv_boot_watchdog_publish_state starting
    _temp_rc=$?
    [ "$_temp_rc" -ne 0 ] && [ ! -e "$_tmp_target" ] || exit 1
    exit 0
    ;;
  run-manager)
    _mode_manager
    exit $?
    ;;
  publish-replacement)
    _merv_boot_watchdog_transient_lock_enter || exit 1
    [ -d "$LOCKDIR/merv_boot_shield.transient.lock" ] || exit 1
    printf 'run_id=replacement-run\n' > "$LOCKDIR/merv_boot_shield.active"
    printf 'parent_run_id=replacement-run\nhandoff_id=replacement-handoff\nwatchdog_state=handoff-published\n' > "$LOCKDIR/merv_boot_shield.handoff"
    : > "$PHASE_DIR/replacement-published-under-lock"
    _merv_boot_watchdog_transient_lock_leave || exit 1
    exit 0
    ;;
  shield-watchdog)
    case "${WATCHDOG_MODE:-live}" in
      dead)
        printf '%s\n' "$$" > "$PHASE_DIR/dead-pid"
        while [ ! -f "$PHASE_DIR/allow-dead-exit" ]; do sleep 1; done
        exit 0
        ;;
      dead-fast)
        printf '%s\n' "$$" > "$PHASE_DIR/dead-pid"
        exit 0
        ;;
      *)
        printf '%s\n' "$$" > "$PHASE_DIR/watchdog-child-pid"
        exec sleep 30
        ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
} > "$FIXTURE"
chmod 755 "$FIXTURE"

# --- Test Case 1: Transient lock enter failure ---
DIR1="$TEST_ROOT/case1"
mkdir -p "$DIR1"
: > "$DIR1/fault_transient_enter"
MERV_TEST_PHASE_DIR="$DIR1" "$FIXTURE" run-watchdog "$DIR1/marker" "$DIR1/ready" "$DIR1/context" 10 "$DIR1/pid" >/dev/null 2>&1
RC1=$?
[ "$RC1" -ne 0 ] || fail "case1-transient-enter: expected nonzero exit"
if grep -Fq "stage=transient-lock-enter rc=7" "$DIR1/logs/boot_wrap.log" 2>/dev/null; then
  pass "case1-transient-enter-diagnostic-captured (exact rc=7)"
else
  fail "case1-transient-enter-missing-diagnostic (expected stage=transient-lock-enter rc=7)"
fi

# --- Test Case 2: Marker claim failure ---
DIR2="$TEST_ROOT/case2"
mkdir -p "$DIR2"
: > "$DIR2/fault_claim_marker"
MERV_TEST_PHASE_DIR="$DIR2" "$FIXTURE" run-watchdog "$DIR2/marker" "$DIR2/ready" "$DIR2/context" 10 "$DIR2/pid" >/dev/null 2>&1
RC2=$?
[ "$RC2" -ne 0 ] || fail "case2-claim-marker: expected nonzero exit"
if grep -Fq "stage=marker-claim rc=1" "$DIR2/logs/boot_wrap.log" 2>/dev/null; then
  pass "case2-claim-marker-diagnostic-captured (exact rc=1)"
else
  fail "case2-claim-marker-missing-diagnostic (expected stage=marker-claim rc=1)"
fi

# --- Test Case 3: Transient lock leave failure ---
DIR3="$TEST_ROOT/case3"
mkdir -p "$DIR3"
: > "$DIR3/fault_transient_leave"
MERV_TEST_PHASE_DIR="$DIR3" "$FIXTURE" run-watchdog "$DIR3/marker" "$DIR3/ready" "$DIR3/context" 10 "$DIR3/pid" >/dev/null 2>&1
RC3=$?
[ "$RC3" -ne 0 ] || fail "case3-transient-leave: expected nonzero exit"
if grep -Fq "stage=transient-lock-leave rc=9" "$DIR3/logs/boot_wrap.log" 2>/dev/null; then
  pass "case3-transient-leave-diagnostic-captured (exact rc=9)"
else
  fail "case3-transient-leave-missing-diagnostic (expected stage=transient-lock-leave rc=9)"
fi

# --- Test Cases 3A-J: Post-handoff watchdog exit diagnostics ---------------
# Each case drives the real _mode_shield_watchdog path through handoff
# publication and faults exactly one post-handoff stage.  The fixture writes
# only safe stand-ins for the DHCP token/handoff values; the production
# diagnostic must never include either value in its log line.
_post_handoff_diagnostic_case() {
  _phdc_name="$1"; _phdc_fault="$2"; _phdc_stage="$3"; _phdc_rc="$4"
  _phdc_dir="$TEST_ROOT/$_phdc_name"
  mkdir -p "$_phdc_dir"
  : > "$_phdc_dir/$_phdc_fault"
  MERV_TEST_PHASE_DIR="$_phdc_dir" "$FIXTURE" run-watchdog \
    "$_phdc_dir/marker" "$_phdc_dir/ready" "$_phdc_dir/context" 10 \
    "$_phdc_dir/pid" > "$_phdc_dir/watchdog.out" 2>&1
  _phdc_exit=$?
  [ "$_phdc_exit" -ne 0 ] &&
    pass "$_phdc_name:nonzero-exit" ||
    fail "$_phdc_name:unexpected-success (rc=$_phdc_exit)"
  if grep -Fq "stage=$_phdc_stage rc=$_phdc_rc" \
    "$_phdc_dir/logs/boot_wrap.log" 2>/dev/null; then
    pass "$_phdc_name:diagnostic-captured (exact rc=$_phdc_rc)"
  else
    fail "$_phdc_name:diagnostic-missing (expected stage=$_phdc_stage rc=$_phdc_rc)"
  fi
  if grep -Fq 'token-fixture' "$_phdc_dir/logs/boot_wrap.log" 2>/dev/null ||
     grep -Fq 'h-test' "$_phdc_dir/logs/boot_wrap.log" 2>/dev/null; then
    fail "$_phdc_name:secret-like-fixture-value-logged"
  else
    pass "$_phdc_name:no-token-or-handoff-value-logged"
  fi
}

_post_handoff_diagnostic_case case3a-mark-handoff-wait \
  fault_mark_handoff_wait mark-handoff-wait 17
_post_handoff_diagnostic_case case3b-ready-lock-enter \
  fault_ready_lock_enter ready-lock-enter 23
_post_handoff_diagnostic_case case3c-ready-marker-read \
  fault_ready_marker_read ready-publication-marker-read 1
_post_handoff_diagnostic_case case3d-ready-marker-match \
  fault_ready_marker_match ready-publication-marker-match 1
_post_handoff_diagnostic_case case3e-ready-pid \
  fault_ready_pid ready-publication-pid 1
_post_handoff_diagnostic_case case3f-ready-pid-start \
  fault_ready_pid_start ready-publication-pid-start 1
_post_handoff_diagnostic_case case3g-ready-process \
  fault_ready_process ready-publication-process 19
_post_handoff_diagnostic_case case3h-ready-context \
  fault_ready_context ready-publication-context 1
_post_handoff_diagnostic_case case3i-ready-publication \
  fault_ready_publication ready-publication-ready 1
_post_handoff_diagnostic_case case3j-ready-lock-leave \
  fault_ready_lock_leave ready-lock-leave 31

# --- Test Case 4: Production-path readiness cleanup ---
# Run the real _mode_shield function with isolated lock/state paths.  The
# watchdog child is a controlled sleep process; all state mutations under the
# publication lock are performed by the production function itself.
_wait_for_file() {
  _wff_path="$1"; _wff_limit="$2"; _wff_i=0
  while [ ! -e "$_wff_path" ] && [ "$_wff_i" -lt "$_wff_limit" ]; do
    sleep 1
    _wff_i=$((_wff_i + 1))
  done
  [ -e "$_wff_path" ]
}

# --- Test Case 3K-M: Generic ready-entry lifecycle --------------------------
# These cases use the actual generic owner-lock library beneath the real
# watchdog publication path. The test fixture changes only the retry bound so
# a hostile live replacement is observed once and fails promptly.
CASE3K="$TEST_ROOT/case3k-generic-ready-release"
mkdir -p "$CASE3K"
MERV_TEST_PHASE_DIR="$CASE3K" MERV_TEST_GENERIC_TRANSIENT_LOCK=1 \
  MERV_TEST_GENERIC_TRANSIENT_MAX=0 MERV_TEST_GENERIC_READY_RACE=disappearance \
  "$FIXTURE" run-watchdog \
  "$CASE3K/marker" "$CASE3K/ready" "$CASE3K/context" 10 "$CASE3K/pid" \
  > "$CASE3K/watchdog.out" 2>&1 &
_RUNNER_PID=$!
# The actual owner library performs several atomic compatibility publications
# before its authoritative record. Leave a bounded allowance for slow local
# filesystems before deciding that ready entry failed.
_wait_for_file "$CASE3K/generic-ready-owner-authenticated" 15 ||
  fail 'case3k-generic-ready-release:ready-owner-not-authenticated'
_wait_for_file "$CASE3K/generic-ready-lock-acquired" 2 ||
  fail 'case3k-generic-ready-release:ready-lock-not-reacquired'
[ -e "$CASE3K/generic-initial-lock-released" ] &&
  [ -e "$CASE3K/generic-contender-published" ] &&
  [ -e "$CASE3K/generic-ready-race-fired" ] &&
  pass 'case3k-generic-ready-release:initial-generic-lock-released' ||
  fail 'case3k-generic-ready-release:initial-release-or-contender-race-missing'
_wait_for_file "$CASE3K/ready" 5 ||
  fail 'case3k-generic-ready-release:ready-publication-not-observed'
[ "$(cat "$CASE3K/ready" 2>/dev/null || printf '')" = "$(cat "$CASE3K/pid" 2>/dev/null || printf '')" ] &&
  grep -Fq 'handoff_id=h-test' "$CASE3K/context" 2>/dev/null &&
  pass 'case3k-generic-ready-release:authenticated-ready-publication-reached' ||
  fail 'case3k-generic-ready-release:ready-publication-missing-or-unauthenticated'
rm -f "$CASE3K/marker"
wait "$_RUNNER_PID" 2>/dev/null
CASE3K_RC=$?
_RUNNER_PID=""
[ "$CASE3K_RC" -eq 0 ] && [ ! -e "$CASE3K/locks/merv_boot_shield.transient.lock" ] &&
  pass 'case3k-generic-ready-release:generic-ready-lock-released-after-publication' ||
  fail "case3k-generic-ready-release:generic-ready-lock-or-runner-not-released (rc=$CASE3K_RC)"

_generic_ready_hostile_case() {
  _grhc_mode="$1"
  _grhc_dir="$TEST_ROOT/case3${_grhc_mode}-generic-ready-hostile"
  mkdir -p "$_grhc_dir"
  MERV_TEST_PHASE_DIR="$_grhc_dir" MERV_TEST_GENERIC_TRANSIENT_LOCK=1 \
    MERV_TEST_GENERIC_TRANSIENT_MAX=0 MERV_TEST_GENERIC_READY_RACE="$_grhc_mode" \
    "$FIXTURE" run-watchdog "$_grhc_dir/marker" "$_grhc_dir/ready" \
    "$_grhc_dir/context" 10 "$_grhc_dir/pid" > "$_grhc_dir/watchdog.out" 2>&1
  _grhc_rc=$?
  [ "$_grhc_rc" -ne 0 ] && [ -e "$_grhc_dir/generic-initial-lock-released" ] &&
    [ ! -e "$_grhc_dir/ready" ] &&
    pass "case3${_grhc_mode}-generic-ready-hostile:ready-entry-blocked" ||
    fail "case3${_grhc_mode}-generic-ready-hostile:unexpected-ready-publication (rc=$_grhc_rc)"
  case "$_grhc_mode" in
    obstruction)
      [ -f "$_grhc_dir/locks/merv_boot_shield.transient.lock" ] &&
        pass 'case3obstruction-generic-ready-hostile:obstruction-preserved' ||
        fail 'case3obstruction-generic-ready-hostile:obstruction-mutated'
      ;;
    replacement)
      [ -e "$_grhc_dir/generic-contender-published" ] &&
        [ -e "$_grhc_dir/generic-ready-race-fired" ] &&
        [ -d "$_grhc_dir/locks/merv_boot_shield.transient.lock" ] &&
        [ -f "$_grhc_dir/locks/merv_boot_shield.transient.lock/owner" ] &&
        pass 'case3replacement-generic-ready-hostile:replacement-owner-preserved' ||
        fail 'case3replacement-generic-ready-hostile:replacement-owner-lost'
      ;;
  esac
}

_generic_ready_hostile_case obstruction
_generic_ready_hostile_case replacement

_wait_for_boot_publication_replacement() {
  _wbpr_pidf="$1"; _wbpr_startf="$2"; _wbpr_marker="$3"; _wbpr_context="$4"
  _wbpr_old_pid="$5"; _wbpr_old_run="$6"; _wbpr_limit="$7"; _wbpr_i=0
  MERV_TEST_WATCHDOG_PID=""
  MERV_TEST_WATCHDOG_START=""
  MERV_TEST_WATCHDOG_RUN=""
  while [ "$_wbpr_i" -lt "$_wbpr_limit" ]; do
    _wbpr_pid=$(cat "$_wbpr_pidf" 2>/dev/null || printf '')
    _wbpr_start=$(cat "$_wbpr_startf" 2>/dev/null || printf '')
    _wbpr_marker_body=$(cat "$_wbpr_marker" 2>/dev/null || printf '')
    _wbpr_run=${_wbpr_marker_body#run_id=}
    _wbpr_context_body=$(cat "$_wbpr_context" 2>/dev/null || printf '')
    case "$_wbpr_pid" in ''|*[!0-9]*) _wbpr_valid=0 ;; *) _wbpr_valid=1 ;; esac
    case "$_wbpr_start" in ''|*[!0-9]*) _wbpr_valid=0 ;; esac
    case "$_wbpr_run" in ''|.|..|*[!A-Za-z0-9._-]*) _wbpr_valid=0 ;; esac
    _wbpr_expected_context=$(printf 'parent_run_id=%s\nhandoff_id=pending\nwatchdog_state=starting' "$_wbpr_run")
    if [ "$_wbpr_valid" -eq 1 ] && [ "$_wbpr_pid" != "$_wbpr_old_pid" ] &&
       [ "$_wbpr_run" != "$_wbpr_old_run" ] &&
       [ "$_wbpr_marker_body" = "run_id=$_wbpr_run" ] &&
       [ "$_wbpr_context_body" = "$_wbpr_expected_context" ]; then
      MERV_TEST_WATCHDOG_PID="$_wbpr_pid"
      MERV_TEST_WATCHDOG_START="$_wbpr_start"
      MERV_TEST_WATCHDOG_RUN="$_wbpr_run"
      return 0
    fi
    sleep 1
    _wbpr_i=$((_wbpr_i + 1))
  done
  return 1
}

_run_shield() {
  _rsh_dir="$1"; _rsh_mode="$2"; _rsh_ready="$3"; _rsh_fault="${4:-}"
  _rsh_start_fault="${5:-}"
  mkdir -p "$_rsh_dir"
  printf 'dhcp-sentinel\n' > "$_rsh_dir/dhcp-state"
  MERV_TEST_PHASE_DIR="$_rsh_dir" WATCHDOG_MODE="$_rsh_mode" \
    FAULT_PUBLISH_STAGE="$_rsh_fault" FAULT_START_LOOKUP="$_rsh_start_fault" \
    LOCKDIR="$_rsh_dir/locks" MERV_BOOT_SHIELD_READY_SEC="$_rsh_ready" \
    "$FIXTURE" run-shield >/dev/null 2>&1 &
  _RUNNER_PID=$!
}

_stop_child() {
  _sc_pid="$1"
  [ -n "$_sc_pid" ] && kill "$_sc_pid" 2>/dev/null || :
  _sc_i=0
  while [ -n "$_sc_pid" ] && kill -0 "$_sc_pid" 2>/dev/null && [ "$_sc_i" -lt 5 ]; do
    sleep 1
    _sc_i=$((_sc_i + 1))
  done
}

_publish_complete_manager_handoff() {
  _pcmh_dir="$1"; _pcmh_run="$2"; _pcmh_handoff="$3"
  (sleep 30) &
  _MANAGER_HANDOFF_PID=$!
  _pcmh_start=$(awk '{print $22}' "/proc/$_MANAGER_HANDOFF_PID/stat" 2>/dev/null || printf '')
  printf 'run_id=%s\n' "$_pcmh_run" > "$_pcmh_dir/locks/merv_boot_shield.active"
  printf '%s\n' "$_MANAGER_HANDOFF_PID" > "$_pcmh_dir/locks/merv_boot_shield.pid"
  printf '%s\n' "$_pcmh_start" > "$_pcmh_dir/locks/merv_boot_shield.pid.start"
  printf '%s\n' "$_MANAGER_HANDOFF_PID" > "$_pcmh_dir/locks/merv_boot_shield.ready"
  printf 'parent_run_id=%s\nhandoff_id=%s\nwatchdog_state=handoff-published\n' \
    "$_pcmh_run" "$_pcmh_handoff" > "$_pcmh_dir/locks/merv_boot_shield.handoff"
}

_finish_shield() {
  wait "$_RUNNER_PID" 2>/dev/null
  _finish_rc=$?
  _RUNNER_PID=""
  [ "$_finish_rc" -ne 0 ] || fail "$1: expected readiness failure (rc=$_finish_rc)"
}

# Subcase 4A: dead exact spawn removes its complete validated publication.
# DHCP state remains intact, and the identity check occurs locked.
CASE4A="$TEST_ROOT/case4a"
_run_shield "$CASE4A" dead 5
CASE4A_LOCKS="$CASE4A/locks"
CASE4A_PIDF="$CASE4A_LOCKS/merv_boot_shield.pid"
_wait_for_file "$CASE4A_PIDF" 5 || fail 'subcase4a-production:pid-not-published'
_OLD_CHILD_PID=$(cat "$CASE4A_PIDF" 2>/dev/null || printf '')
CASE4A_RUN=$(sed -n 's/^run_id=//p' "$CASE4A_LOCKS/merv_boot_shield.active" 2>/dev/null | head -n 1)
[ -n "$CASE4A_RUN" ] || fail 'subcase4a-production:run-not-published'
printf 'parent_run_id=%s\nhandoff_id=pending\nwatchdog_state=starting\n' \
  "$CASE4A_RUN" > "$CASE4A_LOCKS/merv_boot_shield.handoff"
: > "$CASE4A/allow-dead-exit"
_finish_shield subcase4a-production
[ ! -e "$CASE4A_PIDF" ] && [ ! -e "${CASE4A_PIDF}.start" ] &&
  pass 'subcase4a-production:dead-exact-pid-start-cleaned' ||
  fail 'subcase4a-production:dead-exact-pid-start-not-cleaned'
[ ! -e "$CASE4A_LOCKS/merv_boot_shield.active" ] &&
  pass 'subcase4a-production:dead-exact-marker-cleaned' ||
  fail 'subcase4a-production:marker-not-cleaned'
[ ! -e "$CASE4A_LOCKS/merv_boot_shield.handoff" ] &&
  pass 'subcase4a-production:dead-exact-context-cleaned' ||
  fail 'subcase4a-production:context-not-cleaned'
[ ! -e "$CASE4A/dhcp-release-called" ] &&
  [ "$(cat "$CASE4A/dhcp-state" 2>/dev/null)" = dhcp-sentinel ] &&
  pass 'subcase4a-production:dhcp-untouched' ||
  fail 'subcase4a-production:dhcp-mutated'
[ -e "$CASE4A/identity-checked-under-lock" ] &&
  pass 'subcase4a-production:identity-checked-under-transient-lock' ||
  fail 'subcase4a-production:identity-check-not-locked'
_stop_child "$_OLD_CHILD_PID"
_OLD_CHILD_PID=""

# Subcase 4B: live exact spawn remains fully published after readiness failure.
CASE4B="$TEST_ROOT/case4b"
_run_shield "$CASE4B" live 1
CASE4B_LOCKS="$CASE4B/locks"
CASE4B_PIDF="$CASE4B_LOCKS/merv_boot_shield.pid"
_wait_for_file "$CASE4B_PIDF" 5 || fail 'subcase4b-production:pid-not-published'
_OLD_CHILD_PID=$(cat "$CASE4B_PIDF" 2>/dev/null || printf '')
CASE4B_RUN=$(sed -n 's/^run_id=//p' "$CASE4B_LOCKS/merv_boot_shield.active" 2>/dev/null | head -n 1)
_finish_shield subcase4b-production
[ -e "$CASE4B_PIDF" ] && [ -e "${CASE4B_PIDF}.start" ] &&
  pass 'subcase4b-production:live-pid-start-retained' ||
  fail 'subcase4b-production:live-pid-start-improperly-cleaned'
[ -e "$CASE4B_LOCKS/merv_boot_shield.active" ] &&
  grep -Fq "parent_run_id=$CASE4B_RUN" "$CASE4B_LOCKS/merv_boot_shield.handoff" 2>/dev/null &&
  pass 'subcase4b-production:live-marker-context-retained' ||
  fail 'subcase4b-production:live-state-improperly-cleaned'
kill -0 "$_OLD_CHILD_PID" 2>/dev/null &&
  pass 'subcase4b-production:live-child-not-signalled' ||
  fail 'subcase4b-production:live-child-not-running'
[ ! -e "$CASE4B/dhcp-release-called" ] &&
  [ "$(cat "$CASE4B/dhcp-state" 2>/dev/null)" = dhcp-sentinel ] &&
  pass 'subcase4b-production:live-dhcp-untouched' ||
  fail 'subcase4b-production:live-dhcp-mutated'
_stop_child "$_OLD_CHILD_PID"
_OLD_CHILD_PID=""

# Subcase 4C: same PID with a different start identity is treated as reuse.
CASE4C="$TEST_ROOT/case4c"
_run_shield "$CASE4C" live 1
CASE4C_LOCKS="$CASE4C/locks"
CASE4C_PIDF="$CASE4C_LOCKS/merv_boot_shield.pid"
_wait_for_file "$CASE4C_PIDF" 5 || fail 'subcase4c-production:pid-not-published'
_OLD_CHILD_PID=$(cat "$CASE4C_PIDF" 2>/dev/null || printf '')
CASE4C_START=$(cat "${CASE4C_PIDF}.start" 2>/dev/null || printf '')
CASE4C_RUN=$(sed -n 's/^run_id=//p' "$CASE4C_LOCKS/merv_boot_shield.active" 2>/dev/null | head -n 1)
printf '%s9\n' "$CASE4C_START" > "${CASE4C_PIDF}.start"
_finish_shield subcase4c-production
[ -e "$CASE4C_PIDF" ] && [ "$(cat "${CASE4C_PIDF}.start" 2>/dev/null)" = "${CASE4C_START}9" ] &&
  pass 'subcase4c-production:pid-reuse-state-retained' ||
  fail 'subcase4c-production:pid-reuse-state-improperly-cleaned'
[ -e "$CASE4C_LOCKS/merv_boot_shield.active" ] &&
  grep -Fq "parent_run_id=$CASE4C_RUN" "$CASE4C_LOCKS/merv_boot_shield.handoff" 2>/dev/null &&
  pass 'subcase4c-production:pid-reuse-marker-context-retained' ||
  fail 'subcase4c-production:pid-reuse-state-improperly-cleaned'
kill -0 "$_OLD_CHILD_PID" 2>/dev/null &&
  pass 'subcase4c-production:pid-reuse-child-not-signalled' ||
  fail 'subcase4c-production:pid-reuse-child-not-running'
_stop_child "$_OLD_CHILD_PID"
_OLD_CHILD_PID=""

# Subcase 4D: a replacement publishes all transient state before cleanup reads
# it; the old readiness failure must not remove any successor artifact.
CASE4D="$TEST_ROOT/case4d"
mkdir -p "$CASE4D"
(sleep 30) &
_REPLACEMENT_CHILD_PID=$!
REPLACEMENT_START=$(awk '{print $22}' "/proc/$_REPLACEMENT_CHILD_PID/stat" 2>/dev/null || printf '')
printf '%s\n' "$_REPLACEMENT_CHILD_PID" > "$CASE4D/replacement.pid"
printf '%s\n' "$REPLACEMENT_START" > "$CASE4D/replacement.start"
_run_shield "$CASE4D" replacement 0
CASE4D_LOCKS="$CASE4D/locks"
CASE4D_PIDF="$CASE4D_LOCKS/merv_boot_shield.pid"
_wait_for_file "$CASE4D_PIDF" 5 || fail 'subcase4d-production:pid-not-published'
_OLD_CHILD_PID=$(cat "$CASE4D_PIDF" 2>/dev/null || printf '')
_finish_shield subcase4d-production
[ "$(cat "$CASE4D_LOCKS/merv_boot_shield.pid" 2>/dev/null)" = "$_REPLACEMENT_CHILD_PID" ] &&
  [ "$(cat "$CASE4D_LOCKS/merv_boot_shield.pid.start" 2>/dev/null)" = "$REPLACEMENT_START" ] &&
  pass 'subcase4d-production:replacement-pid-start-retained' ||
  fail 'subcase4d-production:replacement-pid-start-improperly-cleaned'
grep -Fq 'run_id=replacement-run' "$CASE4D_LOCKS/merv_boot_shield.active" 2>/dev/null &&
  grep -Fq 'parent_run_id=replacement-run' "$CASE4D_LOCKS/merv_boot_shield.handoff" 2>/dev/null &&
  grep -Fq 'handoff_id=replacement-handoff' "$CASE4D_LOCKS/merv_boot_shield.handoff" 2>/dev/null &&
  [ "$(cat "$CASE4D_LOCKS/merv_boot_shield.ready" 2>/dev/null)" = replacement-ready ] &&
  pass 'subcase4d-production:replacement-marker-ready-context-retained' ||
  fail 'subcase4d-production:replacement-state-improperly-cleaned'
[ ! -e "$CASE4D/dhcp-release-called" ] &&
  [ "$(cat "$CASE4D/dhcp-state" 2>/dev/null)" = dhcp-sentinel ] &&
  pass 'subcase4d-production:replacement-dhcp-untouched' ||
  fail 'subcase4d-production:replacement-dhcp-mutated'
_stop_child "$_OLD_CHILD_PID"
_OLD_CHILD_PID=""
_stop_child "$_REPLACEMENT_CHILD_PID"
_REPLACEMENT_CHILD_PID=""

# --- Test Case 5: Manager replacement-marker ownership -------------------
# The manager process is blocked in the real extracted _mode_manager call.
# A successor then publishes a marker and handoff under the transient
# publication-lock seam. Releasing the old manager must not let its teardown
# remove the successor's marker or context.
CASE5="$TEST_ROOT/case5-manager-replacement"
CASE5_LOCKS="$CASE5/locks"
CASE5_MANAGER="$CASE5/manager"
mkdir -p "$CASE5" "$CASE5_LOCKS"
{
  printf '%s\n' '#!/bin/sh'
  cat <<'EOF'
_manager_phase=${MERV_TEST_PHASE_DIR:?}
[ ! -e "$_manager_phase/locks/merv_boot_shield.transient.lock" ] &&
  : > "$_manager_phase/manager-entered-after-admission-release"
: > "$_manager_phase/manager-entered"
while [ ! -f "$_manager_phase/release-manager" ]; do
  sleep 1
done
exit 0
EOF
} > "$CASE5_MANAGER"
chmod 755 "$CASE5_MANAGER"
_publish_complete_manager_handoff "$CASE5" old-run old-handoff
MERV_TEST_PHASE_DIR="$CASE5" "$FIXTURE" run-manager > "$CASE5/manager.out" 2>&1 &
_MANAGER_PID=$!
_wait_for_file "$CASE5/manager-entered" 5 || fail 'subcase5-manager-replacement:old-manager-not-blocked'
[ -e "$CASE5/identity-checked-under-lock" ] &&
  pass 'subcase5-manager-replacement:admission-classified-under-transient-lock' ||
  fail 'subcase5-manager-replacement:admission-classification-not-locked'
[ -e "$CASE5/manager-entered-after-admission-release" ] &&
  pass 'subcase5-manager-replacement:admission-lock-released-before-manager' ||
  fail 'subcase5-manager-replacement:manager-started-before-admission-release'
MERV_TEST_PHASE_DIR="$CASE5" "$FIXTURE" publish-replacement > "$CASE5/replacement.out" 2>&1
CASE5_PUBLISH_RC=$?
[ "$CASE5_PUBLISH_RC" -eq 0 ] &&
  [ -e "$CASE5/replacement-published-under-lock" ] &&
  pass 'subcase5-manager-replacement:successor-published-under-transient-lock' ||
  fail "subcase5-manager-replacement:successor-publication-failed (rc=$CASE5_PUBLISH_RC)"
: > "$CASE5/release-manager"
wait "$_MANAGER_PID" 2>/dev/null
CASE5_MANAGER_RC=$?
_MANAGER_PID=""
[ "$CASE5_MANAGER_RC" -eq 0 ] &&
  pass 'subcase5-manager-replacement:old-manager-released' ||
  fail "subcase5-manager-replacement:old-manager-returned-nonzero (rc=$CASE5_MANAGER_RC)"
if [ "$(cat "$CASE5_LOCKS/merv_boot_shield.active" 2>/dev/null || printf '')" = 'run_id=replacement-run' ]; then
  pass 'subcase5-manager-replacement:successor-marker-survives-old-teardown'
else
  fail 'subcase5-manager-replacement:successor-marker-removed-or-overwritten'
fi
grep -Fq 'parent_run_id=replacement-run' "$CASE5_LOCKS/merv_boot_shield.handoff" 2>/dev/null &&
  grep -Fq 'handoff_id=replacement-handoff' "$CASE5_LOCKS/merv_boot_shield.handoff" 2>/dev/null &&
  pass 'subcase5-manager-replacement:successor-handoff-survives-old-teardown' ||
  fail 'subcase5-manager-replacement:successor-handoff-removed-or-overwritten'
[ ! -e "$CASE5_LOCKS/merv_boot_shield.transient.lock" ] &&
  pass 'subcase5-manager-replacement:transient-lock-released' ||
  fail 'subcase5-manager-replacement:transient-lock-left-behind'
_stop_child "$_MANAGER_HANDOFF_PID"
_MANAGER_HANDOFF_PID=""

# --- Test Case 6: Shield PID/start reuse preserves a published successor ---
# The real _mode_shield reads a live PID with a stale start identity while the
# identity-check seam publishes a complete successor under the transient lock.
# Every successor sidecar must survive that same invocation; no new watchdog
# may overwrite a state owner that appeared after the old identity was read.
CASE6="$TEST_ROOT/case6-shield-identity-replacement"
CASE6_LOCKS="$CASE6/locks"
mkdir -p "$CASE6" "$CASE6_LOCKS"
(sleep 30) &
_OLD_CHILD_PID=$!
CASE6_OLD_START=$(awk '{print $22}' "/proc/$_OLD_CHILD_PID/stat" 2>/dev/null || printf '')
(sleep 30) &
_REPLACEMENT_CHILD_PID=$!
CASE6_SUCCESSOR_START=$(awk '{print $22}' "/proc/$_REPLACEMENT_CHILD_PID/stat" 2>/dev/null || printf '')
printf '%s\n' "$_OLD_CHILD_PID" > "$CASE6_LOCKS/merv_boot_shield.pid"
printf '%s9\n' "$CASE6_OLD_START" > "$CASE6_LOCKS/merv_boot_shield.pid.start"
printf 'run_id=old-run\n' > "$CASE6_LOCKS/merv_boot_shield.active"
printf 'parent_run_id=old-run\nhandoff_id=old-handoff\nwatchdog_state=handoff-published\n' \
  > "$CASE6_LOCKS/merv_boot_shield.handoff"
printf '%s\n' "$_REPLACEMENT_CHILD_PID" > "$CASE6/successor.pid"
printf '%s\n' "$CASE6_SUCCESSOR_START" > "$CASE6/successor.start"
: > "$CASE6/publish-successor-on-identity-mismatch"
MERV_TEST_PHASE_DIR="$CASE6" WATCHDOG_MODE=live \
  LOCKDIR="$CASE6_LOCKS" MERV_BOOT_SHIELD_READY_SEC=0 \
  "$FIXTURE" run-shield > "$CASE6/shield.out" 2>&1
CASE6_SHIELD_RC=$?
[ -e "$CASE6/successor-published-at-identity" ] &&
  pass 'subcase6-shield-identity-replacement:successor-published-at-live-mismatch' ||
  fail 'subcase6-shield-identity-replacement:identity-boundary-not-injected'
pass "subcase6-shield-identity-replacement:mode-shield-invoked (rc=$CASE6_SHIELD_RC)"
[ "$(cat "$CASE6_LOCKS/merv_boot_shield.active" 2>/dev/null || printf '')" = 'run_id=successor-identity-run' ] &&
  pass 'subcase6-shield-identity-replacement:successor-marker-retained' ||
  fail 'subcase6-shield-identity-replacement:successor-marker-overwritten-or-removed'
grep -Fq 'parent_run_id=successor-identity-run' "$CASE6_LOCKS/merv_boot_shield.handoff" 2>/dev/null &&
  grep -Fq 'handoff_id=successor-identity-handoff' "$CASE6_LOCKS/merv_boot_shield.handoff" 2>/dev/null &&
  pass 'subcase6-shield-identity-replacement:successor-context-retained' ||
  fail 'subcase6-shield-identity-replacement:successor-context-overwritten-or-removed'
[ "$(cat "$CASE6_LOCKS/merv_boot_shield.ready" 2>/dev/null || printf '')" = 'successor-identity-ready' ] &&
  pass 'subcase6-shield-identity-replacement:successor-ready-retained' ||
  fail 'subcase6-shield-identity-replacement:successor-ready-removed'
[ "$(cat "$CASE6_LOCKS/merv_boot_shield.pid" 2>/dev/null || printf '')" = "$_REPLACEMENT_CHILD_PID" ] &&
  [ "$(cat "$CASE6_LOCKS/merv_boot_shield.pid.start" 2>/dev/null || printf '')" = "$CASE6_SUCCESSOR_START" ] &&
  pass 'subcase6-shield-identity-replacement:successor-pid-start-retained' ||
  fail 'subcase6-shield-identity-replacement:successor-pid-start-removed-or-replaced'
[ -e "$CASE6/identity-checked-under-lock" ] &&
  pass 'subcase6-shield-identity-replacement:identity-mismatch-checked-under-lock' ||
  fail 'subcase6-shield-identity-replacement:identity-mismatch-not-locked'
_stop_child "$_OLD_CHILD_PID"
_OLD_CHILD_PID=""
_stop_child "$_REPLACEMENT_CHILD_PID"
_REPLACEMENT_CHILD_PID=""

# --- Test Case 7: Manager teardown lock acquisition is fail-closed ----------
# A successful manager run is not a successful boot handoff when the exact
# marker cannot be retired under the transient publication lock.
_prepare_success_manager_case() {
  _psmc_dir="$1"
  _psmc_parent="$2"
  mkdir -p "$_psmc_dir" "$_psmc_dir/locks"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' ': > "$MERV_TEST_PHASE_DIR/manager-entered"' 'exit 0'
  } > "$_psmc_dir/manager"
  chmod 755 "$_psmc_dir/manager"
  _publish_complete_manager_handoff "$_psmc_dir" "$_psmc_parent" "$_psmc_parent-handoff"
}

CASE7="$TEST_ROOT/case7-manager-lock-enter"
_prepare_success_manager_case "$CASE7" case7-parent
: > "$CASE7/fault_transient_enter"
MERV_TEST_PHASE_DIR="$CASE7" "$FIXTURE" run-manager > "$CASE7/manager.out" 2>&1
CASE7_MANAGER_RC=$?
[ "$CASE7_MANAGER_RC" -ne 0 ] &&
  pass 'subcase7-manager-lock-enter:teardown-failure-propagated' ||
  fail 'subcase7-manager-lock-enter:teardown-failure-returned-success'
[ "$(cat "$CASE7/locks/merv_boot_shield.active" 2>/dev/null || printf '')" = 'run_id=case7-parent' ] &&
  pass 'subcase7-manager-lock-enter:exact-marker-retained' ||
  fail 'subcase7-manager-lock-enter:marker-lost-on-lock-failure'
[ ! -e "$CASE7/manager-entered" ] &&
  pass 'subcase7-manager-lock-enter:admission-failure-suppressed-manager' ||
  fail 'subcase7-manager-lock-enter:manager-invoked-after-admission-failure'
_stop_child "$_MANAGER_HANDOFF_PID"
_MANAGER_HANDOFF_PID=""

# --- Test Case 8: Manager teardown lock release is fail-closed --------------
CASE8="$TEST_ROOT/case8-manager-lock-leave"
_prepare_success_manager_case "$CASE8" case8-parent
: > "$CASE8/fault_transient_leave"
MERV_TEST_PHASE_DIR="$CASE8" "$FIXTURE" run-manager > "$CASE8/manager.out" 2>&1
CASE8_MANAGER_RC=$?
[ "$CASE8_MANAGER_RC" -ne 0 ] &&
  pass 'subcase8-manager-lock-leave:teardown-failure-propagated' ||
  fail 'subcase8-manager-lock-leave:teardown-failure-returned-success'
[ "$(cat "$CASE8/locks/merv_boot_shield.active" 2>/dev/null || printf '')" = 'run_id=case8-parent' ] &&
  pass 'subcase8-manager-lock-leave:exact-marker-retained' ||
  fail 'subcase8-manager-lock-leave:marker-retired-before-release-confirmed'
[ ! -e "$CASE8/manager-entered" ] &&
  pass 'subcase8-manager-lock-leave:admission-failure-suppressed-manager' ||
  fail 'subcase8-manager-lock-leave:manager-invoked-after-admission-failure'
_stop_child "$_MANAGER_HANDOFF_PID"
_MANAGER_HANDOFF_PID=""

# --- Test Case 9: Manager exact-marker classification is fail-closed --------
# An otherwise valid run_id with extra marker content is not an exact marker;
# the manager must retain it and report a non-success teardown result.
CASE9="$TEST_ROOT/case9-manager-marker-classification"
_prepare_success_manager_case "$CASE9" case9-parent
printf 'run_id=case9-parent\nextra=unexpected\n' > "$CASE9/locks/merv_boot_shield.active"
MERV_TEST_PHASE_DIR="$CASE9" "$FIXTURE" run-manager > "$CASE9/manager.out" 2>&1
CASE9_MANAGER_RC=$?
[ "$CASE9_MANAGER_RC" -ne 0 ] &&
  pass 'subcase9-manager-marker-classification:teardown-failure-propagated' ||
  fail 'subcase9-manager-marker-classification:ambiguous-marker-returned-success'
[ "$(cat "$CASE9/locks/merv_boot_shield.active" 2>/dev/null || printf '')" = "$(printf 'run_id=case9-parent\nextra=unexpected')" ] &&
  pass 'subcase9-manager-marker-classification:ambiguous-marker-retained' ||
  fail 'subcase9-manager-marker-classification:ambiguous-marker-lost'
[ ! -e "$CASE9/manager-entered" ] &&
  pass 'subcase9-manager-marker-classification:manager-not-invoked' ||
  fail 'subcase9-manager-marker-classification:manager-invoked'
_stop_child "$_MANAGER_HANDOFF_PID"
_MANAGER_HANDOFF_PID=""

# --- Test Case 10: Manager rejects a dangling boot marker ------------------
# The marker must not be treated as absent, and no install/manager work may
# run while the handoff publication is an unresolved symlink.
CASE10="$TEST_ROOT/case10-manager-dangling-marker"
mkdir -p "$CASE10/locks"
CASE10_TARGET="$CASE10/marker-target-does-not-exist"
CASE10_MARKER="$CASE10/locks/merv_boot_shield.active"
MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$CASE10_TARGET" "$CASE10_MARKER" 2>/dev/null
if [ ! -L "$CASE10_MARKER" ]; then
  pass 'subcase10-manager-dangling-marker:unsupported-on-host'
else
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'echo manager_invoked >> "$MERV_TEST_PHASE_DIR/manager-invoked"' 'exit 0'
  } > "$CASE10/manager"
  chmod 755 "$CASE10/manager"
  [ ! -e "$CASE10_TARGET" ] || fail 'subcase10-manager-dangling-marker:target-precondition'
  MERV_TEST_PHASE_DIR="$CASE10" "$FIXTURE" run-manager > "$CASE10/manager.out" 2>&1
  CASE10_MANAGER_RC=$?
  [ "$CASE10_MANAGER_RC" -ne 0 ] &&
    pass 'subcase10-manager-dangling-marker:startup-rejected' ||
    fail 'subcase10-manager-dangling-marker:startup-returned-success'
  [ -L "$CASE10_MARKER" ] && [ ! -e "$CASE10_TARGET" ] &&
    pass 'subcase10-manager-dangling-marker:state-preserved' ||
    fail 'subcase10-manager-dangling-marker:state-mutated'
  [ ! -e "$CASE10/manager-invoked" ] &&
    pass 'subcase10-manager-dangling-marker:manager-not-invoked' ||
    fail 'subcase10-manager-dangling-marker:manager-invoked'
fi

# --- Test Case 11: Shield rejects a dangling boot marker -------------------
# A redirect at the exact marker path must not receive the new timestamp or
# be used as the basis for a new watchdog publication.
CASE11="$TEST_ROOT/case11-shield-dangling-marker"
mkdir -p "$CASE11/locks"
CASE11_TARGET="$CASE11/marker-target-does-not-exist"
CASE11_MARKER="$CASE11/locks/merv_boot_shield.active"
MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$CASE11_TARGET" "$CASE11_MARKER" 2>/dev/null
if [ ! -L "$CASE11_MARKER" ]; then
  pass 'subcase11-shield-dangling-marker:unsupported-on-host'
else
  [ ! -e "$CASE11_TARGET" ] || fail 'subcase11-shield-dangling-marker:target-precondition'
  MERV_TEST_PHASE_DIR="$CASE11" "$FIXTURE" run-shield > "$CASE11/shield.out" 2>&1
  CASE11_SHIELD_RC=$?
  [ "$CASE11_SHIELD_RC" -ne 0 ] &&
    pass 'subcase11-shield-dangling-marker:startup-rejected' ||
    fail 'subcase11-shield-dangling-marker:startup-returned-success'
  [ -L "$CASE11_MARKER" ] && [ ! -e "$CASE11_TARGET" ] &&
    pass 'subcase11-shield-dangling-marker:state-preserved' ||
    fail 'subcase11-shield-dangling-marker:state-mutated'
  [ ! -e "$CASE11/locks/merv_boot_shield.pid" ] &&
    pass 'subcase11-shield-dangling-marker:watchdog-not-published' ||
    fail 'subcase11-shield-dangling-marker:watchdog-published'
fi

# --- Test Case 12: Two independent Shield invocations reclaim an orphan -----
# The first parent publishes a complete starting publication, then fails to
# reacquire the transient lock before readiness cleanup. Its watchdog exits,
# leaving an exact dead orphan. The second independent Shield must reclaim that
# exact publication under the lock and publish its own identity.
CASE12="$TEST_ROOT/case12-two-invocations"
mkdir -p "$CASE12"
: > "$CASE12/fail-reconcile-lock"
# Exit the first watchdog immediately so the orphan's exact PID is truly
# absent before the independent second invocation classifies it.
_run_shield "$CASE12" dead-fast 0
CASE12_LOCKS="$CASE12/locks"
CASE12_PIDF="$CASE12_LOCKS/merv_boot_shield.pid"
_wait_for_file "$CASE12_PIDF" 5 || fail 'case12-first:pid-not-published'
_OLD_CHILD_PID=$(cat "$CASE12_PIDF" 2>/dev/null || printf '')
CASE12_OLD_RUN=$(sed -n 's/^run_id=//p' "$CASE12_LOCKS/merv_boot_shield.active" 2>/dev/null | head -n 1)
: > "$CASE12/allow-dead-exit"
_finish_shield case12-first
_stop_child "$_OLD_CHILD_PID"
CASE12_OLD_PID="$_OLD_CHILD_PID"
_OLD_CHILD_PID=""
[ -e "$CASE12_LOCKS/merv_boot_shield.active" ] &&
  [ -e "$CASE12_LOCKS/merv_boot_shield.handoff" ] &&
  [ -e "$CASE12_PIDF" ] &&
  pass 'case12-first:dead-orphan-preserved-after-cleanup-lock-failure' ||
  fail 'case12-first:orphan-not-preserved'
rm -f "$CASE12/fail-reconcile-lock"
_run_shield "$CASE12" live 0
# The first orphan already owns the PID path. Wait for one coherent strict
# starting publication: the parent writes marker, PID, start, then context
# atomically, so sampling after PID alone races the final context publication.
# Do not inspect the fixture log: the spawned fixture child initializes its
# private log channel and can truncate the parent's earlier diagnostic.
_wait_for_boot_publication_replacement "$CASE12_PIDF" "${CASE12_PIDF}.start" \
  "$CASE12_LOCKS/merv_boot_shield.active" "$CASE12_LOCKS/merv_boot_shield.handoff" \
  "$CASE12_OLD_PID" "$CASE12_OLD_RUN" 5 ||
  fail 'case12-second:replacement-publication-not-published'
CASE12_NEW_PID="$MERV_TEST_WATCHDOG_PID"
CASE12_NEW_START="$MERV_TEST_WATCHDOG_START"
CASE12_NEW_RUN="$MERV_TEST_WATCHDOG_RUN"
_finish_shield case12-second
[ -n "$CASE12_NEW_RUN" ] && [ "$CASE12_NEW_RUN" != "$CASE12_OLD_RUN" ] &&
  [ -n "$CASE12_NEW_START" ] && [ -n "$CASE12_NEW_PID" ] &&
  pass 'case12-second:exact-dead-publication-reclaimed' ||
  fail 'case12-second:dead-publication-not-reclaimed'
[ -n "$CASE12_NEW_PID" ] && [ "$CASE12_NEW_PID" != "$CASE12_OLD_PID" ] &&
  pass 'case12-second:new-pid-published-after-reclaim' ||
  fail 'case12-second:new-pid-not-replaced'
_OLD_CHILD_PID="$CASE12_NEW_PID"
_stop_child "$_OLD_CHILD_PID"
_OLD_CHILD_PID=""

# --- Test Case 13: Classification-to-cleanup replacement race ---------------
# A dead old PID triggers the identity classifier, which publishes a live
# successor before cleanup reclassifies the publication. The successor must
# survive intact; no new Shield may overwrite it.
CASE13="$TEST_ROOT/case13-classification-cleanup-race"
mkdir -p "$CASE13" "$CASE13/locks"
(sleep 30) &
_OLD_CHILD_PID=$!
CASE13_OLD_START=$(awk '{print $22}' "/proc/$_OLD_CHILD_PID/stat" 2>/dev/null || printf '')
kill "$_OLD_CHILD_PID" 2>/dev/null || :
wait "$_OLD_CHILD_PID" 2>/dev/null || :
(sleep 30) &
_REPLACEMENT_CHILD_PID=$!
CASE13_NEW_START=$(awk '{print $22}' "/proc/$_REPLACEMENT_CHILD_PID/stat" 2>/dev/null || printf '')
printf '%s\n' "$_REPLACEMENT_CHILD_PID" > "$CASE13/successor.pid"
printf '%s\n' "$CASE13_NEW_START" > "$CASE13/successor.start"
printf 'run_id=old-dead-run\n' > "$CASE13/locks/merv_boot_shield.active"
printf '%s\n' "$_OLD_CHILD_PID" > "$CASE13/locks/merv_boot_shield.pid"
printf '%s\n' "$CASE13_OLD_START" > "$CASE13/locks/merv_boot_shield.pid.start"
printf 'parent_run_id=old-dead-run\nhandoff_id=old-dead-handoff\nwatchdog_state=handoff-published\n' > "$CASE13/locks/merv_boot_shield.handoff"
printf '%s\n' "$_OLD_CHILD_PID" > "$CASE13/locks/merv_boot_shield.ready"
: > "$CASE13/publish-successor-on-dead-classification"
MERV_TEST_PHASE_DIR="$CASE13" WATCHDOG_MODE=live MERV_BOOT_SHIELD_READY_SEC=0 \
  LOCKDIR="$CASE13/locks" "$FIXTURE" run-shield > "$CASE13/shield.out" 2>&1
CASE13_RC=$?
[ "$CASE13_RC" -ne 0 ] && [ -e "$CASE13/successor-published-at-dead" ] &&
  pass 'case13-classification-cleanup-race:reclassification-failed-closed' ||
  fail 'case13-classification-cleanup-race:race-not-exercised'
[ "$(cat "$CASE13/locks/merv_boot_shield.pid" 2>/dev/null || printf '')" = "$_REPLACEMENT_CHILD_PID" ] &&
  [ "$(cat "$CASE13/locks/merv_boot_shield.pid.start" 2>/dev/null || printf '')" = "$CASE13_NEW_START" ] &&
  pass 'case13-classification-cleanup-race:successor-pid-start-retained' ||
  fail 'case13-classification-cleanup-race:successor-pid-start-lost'
grep -Fq 'run_id=successor-dead-run' "$CASE13/locks/merv_boot_shield.active" 2>/dev/null &&
  grep -Fq 'parent_run_id=successor-dead-run' "$CASE13/locks/merv_boot_shield.handoff" 2>/dev/null &&
  pass 'case13-classification-cleanup-race:successor-marker-context-retained' ||
  fail 'case13-classification-cleanup-race:successor-marker-context-lost'
_stop_child "$_REPLACEMENT_CHILD_PID"
_REPLACEMENT_CHILD_PID=""
_OLD_CHILD_PID=""

# --- Test Case 14: Readiness rejects replacement and PID reuse ---------------
CASE14="$TEST_ROOT/case14-readiness-authentication"
mkdir -p "$CASE14"
CASE14_MARKER="$CASE14/marker"
CASE14_READY="$CASE14/ready"
CASE14_CONTEXT="$CASE14/context"
CASE14_PID="$CASE14/pid"
CASE14_START="$CASE14/pid.start"
MERV_TEST_PHASE_DIR="$CASE14" "$FIXTURE" run-readiness readiness-run \
  "$CASE14_MARKER" "$CASE14_READY" "$CASE14_CONTEXT" "$CASE14_PID" "$CASE14_START" exact \
  > "$CASE14/exact.out" 2>&1
[ $? -eq 0 ] && pass 'case14-readiness:exact-publication-accepted' || fail 'case14-readiness:exact-publication-rejected'
MERV_TEST_PHASE_DIR="$CASE14" "$FIXTURE" run-readiness readiness-run \
  "$CASE14_MARKER" "$CASE14_READY" "$CASE14_CONTEXT" "$CASE14_PID" "$CASE14_START" pid-reuse \
  > "$CASE14/pid-reuse.out" 2>&1
[ $? -ne 0 ] && pass 'case14-readiness:pid-reuse-rejected' || fail 'case14-readiness:pid-reuse-accepted'
MERV_TEST_PHASE_DIR="$CASE14" "$FIXTURE" run-readiness readiness-run \
  "$CASE14_MARKER" "$CASE14_READY" "$CASE14_CONTEXT" "$CASE14_PID" "$CASE14_START" replacement \
  > "$CASE14/replacement.out" 2>&1
[ $? -ne 0 ] && pass 'case14-readiness:successor-rejected' || fail 'case14-readiness:successor-accepted'
grep -Fq 'run_id=successor-ready-run' "$CASE14_MARKER" 2>/dev/null &&
  grep -Fq 'parent_run_id=successor-ready-run' "$CASE14_CONTEXT" 2>/dev/null &&
  pass 'case14-readiness:successor-files-retained' ||
  fail 'case14-readiness:successor-files-mutated'

# --- Test Case 15: Predictable temporary symlink is rejected -----------------
CASE15="$TEST_ROOT/case15-temp-symlink"
mkdir -p "$CASE15/locks"
MERV_TEST_PHASE_DIR="$CASE15" "$FIXTURE" temp-symlink > "$CASE15/temp.out" 2>&1
CASE15_RC=$?
if [ "$CASE15_RC" -eq 200 ]; then
  pass 'case15-temp-symlink:unsupported-on-host'
elif [ "$CASE15_RC" -eq 0 ]; then
  pass 'case15-temp-symlink:predictable-temp-obstruction-rejected'
else
  fail "case15-temp-symlink:publication-not-rejected (rc=$CASE15_RC)"
fi

# --- Test Case 16: Manager rejects incomplete active handoff ----------------
# Marker/context alone used to reach the manager. An active handoff now needs
# the exact live PID/start/ready publication as well.
CASE16="$TEST_ROOT/case16-manager-incomplete-active-handoff"
mkdir -p "$CASE16/locks"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' ': > "$MERV_TEST_PHASE_DIR/manager-entered"' 'exit 0'
} > "$CASE16/manager"
chmod 755 "$CASE16/manager"
printf 'run_id=incomplete-parent\n' > "$CASE16/locks/merv_boot_shield.active"
printf 'parent_run_id=incomplete-parent\nhandoff_id=incomplete-handoff\nwatchdog_state=handoff-published\n' \
  > "$CASE16/locks/merv_boot_shield.handoff"
MERV_TEST_PHASE_DIR="$CASE16" "$FIXTURE" run-manager > "$CASE16/manager.out" 2>&1
CASE16_MANAGER_RC=$?
[ "$CASE16_MANAGER_RC" -ne 0 ] &&
  pass 'case16-manager-incomplete-active-handoff:startup-rejected' ||
  fail 'case16-manager-incomplete-active-handoff:startup-returned-success'
[ -e "$CASE16/locks/merv_boot_shield.active" ] && [ -e "$CASE16/locks/merv_boot_shield.handoff" ] &&
  [ ! -e "$CASE16/manager-entered" ] &&
  pass 'case16-manager-incomplete-active-handoff:state-retained-manager-not-invoked' ||
  fail 'case16-manager-incomplete-active-handoff:state-mutated-or-manager-invoked'

# --- Test Case 16A: Manager requires an exact ready record -----------------
# Classification deliberately permits a missing ready file so Shield can
# reclaim a complete dead pre-ready publication.  Manager admission is stricter:
# a live handoff must prove its ready PID is exactly the classified watchdog.
_manager_ready_reject_case() {
  _mrrc_name="$1"; _mrrc_kind="$2"; _mrrc_dir="$TEST_ROOT/$_mrrc_name"
  _mrrc_locks="$_mrrc_dir/locks"
  mkdir -p "$_mrrc_dir" "$_mrrc_locks"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' ': > "$MERV_TEST_PHASE_DIR/manager-entered"' 'exit 0'
  } > "$_mrrc_dir/manager"
  chmod 755 "$_mrrc_dir/manager"
  _publish_complete_manager_handoff "$_mrrc_dir" "$_mrrc_name-run" "$_mrrc_name-handoff"
  case "$_mrrc_kind" in
    missing) rm -f "$_mrrc_locks/merv_boot_shield.ready" ;;
    malformed) printf 'not-a-pid\nextra=unexpected\n' > "$_mrrc_locks/merv_boot_shield.ready" ;;
    *) fail "$_mrrc_name:invalid-fixture-kind" ;;
  esac
  MERV_TEST_PHASE_DIR="$_mrrc_dir" "$FIXTURE" run-manager > "$_mrrc_dir/manager.out" 2>&1
  _mrrc_rc=$?
  [ "$_mrrc_rc" -ne 0 ] &&
    pass "$_mrrc_name:startup-rejected" ||
    fail "$_mrrc_name:startup-returned-success"
  [ "$(cat "$_mrrc_locks/merv_boot_shield.active" 2>/dev/null || printf '')" = "run_id=$_mrrc_name-run" ] &&
    [ "$(cat "$_mrrc_locks/merv_boot_shield.pid" 2>/dev/null || printf '')" = "$_MANAGER_HANDOFF_PID" ] &&
    [ -e "$_mrrc_locks/merv_boot_shield.pid.start" ] &&
    [ "$(cat "$_mrrc_locks/merv_boot_shield.handoff" 2>/dev/null || printf '')" = "$(printf 'parent_run_id=%s\nhandoff_id=%s\nwatchdog_state=handoff-published' "$_mrrc_name-run" "$_mrrc_name-handoff")" ] &&
    [ ! -e "$_mrrc_dir/manager-entered" ] &&
    case "$_mrrc_kind" in
      missing) [ ! -e "$_mrrc_locks/merv_boot_shield.ready" ] ;;
      malformed) [ "$(cat "$_mrrc_locks/merv_boot_shield.ready" 2>/dev/null || printf '')" = "$(printf 'not-a-pid\nextra=unexpected')" ] ;;
    esac &&
    pass "$_mrrc_name:state-retained-manager-not-invoked" ||
    fail "$_mrrc_name:state-mutated-or-manager-invoked"
  _stop_child "$_MANAGER_HANDOFF_PID"
  _MANAGER_HANDOFF_PID=""
}

_manager_ready_reject_case case16a-manager-missing-ready missing
_manager_ready_reject_case case16b-manager-malformed-ready malformed

# --- Test Case 17: Parent rolls back exact partial publications -------------
# A parent owns the transient lock until it has published marker, PID, start,
# and context.  Each failed publication must terminate only its exact child
# and quarantine only its own partial state; DHCP remains untouched.
_parent_rollback_case() {
  _prc_name="$1"; _prc_fault="$2"; _prc_term_race="${3:-no}"; _prc_dir="$TEST_ROOT/$_prc_name"
  _prc_locks="$_prc_dir/locks"
  mkdir -p "$_prc_dir"
  [ "$_prc_term_race" != disappear ] || : > "$_prc_dir/fault_parent_term_disappear"
  _run_shield "$_prc_dir" live 0 "$_prc_fault"
  _wait_for_file "$_prc_dir/watchdog-child-pid" 5 || fail "$_prc_name:child-not-spawned"
  _prc_child=$(cat "$_prc_dir/watchdog-child-pid" 2>/dev/null || printf '')
  _finish_shield "$_prc_name"
  [ -e "$_prc_dir/parent-rollback-lock-owned" ] &&
    pass "$_prc_name:lock-ownership-proven" ||
    fail "$_prc_name:lock-ownership-not-proven"
  [ -e "$_prc_dir/actual-claim-marker" ] && [ -e "$_prc_dir/actual-publish-$_prc_fault" ] &&
    pass "$_prc_name:actual-claim-and-publish-atomic-used" ||
    fail "$_prc_name:claim-or-publish-atomic-not-used"
  [ ! -e "$_prc_locks/merv_boot_shield.active" ] &&
    [ ! -e "$_prc_locks/merv_boot_shield.pid" ] &&
    [ ! -e "$_prc_locks/merv_boot_shield.pid.start" ] &&
    [ ! -e "$_prc_locks/merv_boot_shield.handoff" ] &&
    [ ! -e "$_prc_locks/merv_boot_shield.ready" ] &&
    pass "$_prc_name:exact-partial-publication-removed" ||
    fail "$_prc_name:partial-publication-retained"
  ! kill -0 "$_prc_child" 2>/dev/null &&
    pass "$_prc_name:exact-child-terminated" ||
    fail "$_prc_name:child-not-terminated"
  [ ! -e "$_prc_dir/dhcp-release-called" ] &&
    [ "$(cat "$_prc_dir/dhcp-state" 2>/dev/null)" = dhcp-sentinel ] &&
    pass "$_prc_name:dhcp-untouched" ||
    fail "$_prc_name:dhcp-mutated"
  _stop_child "$_prc_child"
}

_parent_rollback_case case16a-parent-rollback-marker pid
_parent_rollback_case case16b-parent-rollback-marker-pid pid-start
_parent_rollback_case case16c-parent-rollback-marker-pid-start context
_parent_rollback_case case16d-parent-term-success-absence pid
_parent_rollback_case case16e-parent-term-failed-disappear pid disappear

# --- Test Cases 16F-H: Post-TERM ambiguity remains fail-closed --------------
# These all start through the real claim_marker/publish_atomic path, fault the
# PID publication, then exercise the parent reinspection boundary after TERM.
_parent_rollback_term_preserve_case() {
  _prtpc_name="$1"; _prtpc_mode="$2"; _prtpc_dir="$TEST_ROOT/$_prtpc_name"
  _prtpc_locks="$_prtpc_dir/locks"
  mkdir -p "$_prtpc_dir"
  case "$_prtpc_mode" in
    reuse) : > "$_prtpc_dir/fault_parent_term_pid_reuse" ;;
    replace) : > "$_prtpc_dir/fault_parent_term_replace" ;;
    live) : > "$_prtpc_dir/fault_parent_term_live" ;;
    *) fail "$_prtpc_name:invalid-fixture-mode" ;;
  esac
  _run_shield "$_prtpc_dir" live 0 pid
  _wait_for_file "$_prtpc_dir/watchdog-child-pid" 5 || fail "$_prtpc_name:child-not-spawned"
  _prtpc_child=$(cat "$_prtpc_dir/watchdog-child-pid" 2>/dev/null || printf '')
  _finish_shield "$_prtpc_name"
  [ -e "$_prtpc_dir/actual-claim-marker" ] && [ -e "$_prtpc_dir/actual-publish-pid" ] &&
    pass "$_prtpc_name:actual-claim-and-publish-atomic-used" ||
    fail "$_prtpc_name:claim-or-publish-atomic-not-used"
  case "$_prtpc_mode" in
    reuse)
      [ -e "$_prtpc_dir/term-pid-reuse-observed" ] &&
        [ -e "$_prtpc_locks/merv_boot_shield.active" ] &&
        [ ! -e "$_prtpc_locks/merv_boot_shield.pid" ] &&
        pass "$_prtpc_name:pid-reuse-after-term-publication-retained" ||
        fail "$_prtpc_name:pid-reuse-after-term-publication-mutated"
      ;;
    replace)
      _prtpc_successor=$(cat "$_prtpc_dir/term-successor-pid" 2>/dev/null || printf '')
      [ "$(cat "$_prtpc_locks/merv_boot_shield.active" 2>/dev/null || printf '')" = 'run_id=term-replacement-run' ] &&
        [ "$(cat "$_prtpc_locks/merv_boot_shield.pid" 2>/dev/null || printf '')" = "$_prtpc_successor" ] &&
        [ -e "$_prtpc_locks/merv_boot_shield.pid.start" ] &&
        [ "$(cat "$_prtpc_locks/merv_boot_shield.handoff" 2>/dev/null || printf '')" = "$(printf 'parent_run_id=term-replacement-run\nhandoff_id=term-replacement-handoff\nwatchdog_state=handoff-published')" ] &&
        [ "$(cat "$_prtpc_locks/merv_boot_shield.ready" 2>/dev/null || printf '')" = "$_prtpc_successor" ] &&
        pass "$_prtpc_name:replacement-during-term-publication-retained" ||
        fail "$_prtpc_name:replacement-during-term-publication-mutated"
      _stop_child "$_prtpc_successor"
      ;;
    live)
      _prtpc_polls=$(wc -l < "$_prtpc_dir/term-live-identity-polls" 2>/dev/null || printf '0')
      [ -e "$_prtpc_dir/term-live-observed" ] && [ "$_prtpc_polls" -ge 3 ] 2>/dev/null &&
        [ -e "$_prtpc_locks/merv_boot_shield.active" ] && [ ! -e "$_prtpc_locks/merv_boot_shield.pid" ] &&
        kill -0 "$_prtpc_child" 2>/dev/null &&
        pass "$_prtpc_name:child-live-past-bounded-check-retained" ||
        fail "$_prtpc_name:child-live-past-bounded-check-not-retained"
      ;;
  esac
  _stop_child "$_prtpc_child"
}

_parent_rollback_term_preserve_case case16f-parent-term-pid-reuse reuse
_parent_rollback_term_preserve_case case16g-parent-term-replacement replace
_parent_rollback_term_preserve_case case16h-parent-term-live-bound live

# --- Test Case 16E: Lost parent lock never causes PID-only TERM -------------
# The parent has published a real marker/PID/start/context, then transient lock
# release fails while the child PID is simulated as reused.  It must retain all
# publication and avoid signaling a PID that can no longer be reauthenticated.
CASE16E="$TEST_ROOT/case16e-parent-lock-leave-pid-reuse"
CASE16E_LOCKS="$CASE16E/locks"
mkdir -p "$CASE16E"
: > "$CASE16E/fault_transient_leave"
: > "$CASE16E/fault_parent_leave_pid_reuse"
: > "$CASE16E/record_parent_leave_term"
_run_shield "$CASE16E" live 0
_wait_for_file "$CASE16E/watchdog-child-pid" 5 || fail 'case16e-parent-lock-leave-pid-reuse:child-not-spawned'
CASE16E_CHILD=$(cat "$CASE16E/watchdog-child-pid" 2>/dev/null || printf '')
_finish_shield case16e-parent-lock-leave-pid-reuse
[ ! -e "$CASE16E/parent-leave-term-attempted" ] &&
  pass 'case16e-parent-lock-leave-pid-reuse:no-pid-only-term' ||
  fail 'case16e-parent-lock-leave-pid-reuse:pid-only-term-attempted'
[ -e "$CASE16E_LOCKS/merv_boot_shield.active" ] && [ -e "$CASE16E_LOCKS/merv_boot_shield.pid" ] &&
  [ -e "$CASE16E_LOCKS/merv_boot_shield.pid.start" ] && [ -e "$CASE16E_LOCKS/merv_boot_shield.handoff" ] &&
  kill -0 "$CASE16E_CHILD" 2>/dev/null &&
  pass 'case16e-parent-lock-leave-pid-reuse:publication-and-child-retained' ||
  fail 'case16e-parent-lock-leave-pid-reuse:publication-or-child-lost'
_stop_child "$CASE16E_CHILD"

# --- Test Case 16I: Lost lock retains identity-positive replacement ---------
# The original watchdog remains a live exact PID/start, but a successor
# publication appears before the parent learns release failed.  This branch
# must not TERM either child or mutate successor state after lock ownership is
# uncertain.
CASE16I="$TEST_ROOT/case16i-parent-lock-leave-live-replacement"
CASE16I_LOCKS="$CASE16I/locks"
mkdir -p "$CASE16I"
: > "$CASE16I/fault_transient_leave"
: > "$CASE16I/fault_parent_leave_identity_replacement"
: > "$CASE16I/record_parent_leave_term"
_run_shield "$CASE16I" live 0
_wait_for_file "$CASE16I/watchdog-child-pid" 5 || fail 'case16i-parent-lock-leave-live-replacement:child-not-spawned'
CASE16I_CHILD=$(cat "$CASE16I/watchdog-child-pid" 2>/dev/null || printf '')
CASE16I_CHILD_START=$(awk '{print $22}' "/proc/$CASE16I_CHILD/stat" 2>/dev/null || printf '')
_finish_shield case16i-parent-lock-leave-live-replacement
CASE16I_SUCCESSOR=$(cat "$CASE16I/parent-leave-successor-pid" 2>/dev/null || printf '')
[ ! -e "$CASE16I/parent-leave-term-attempted" ] &&
  kill -0 "$CASE16I_CHILD" 2>/dev/null &&
  [ "$(awk '{print $22}' "/proc/$CASE16I_CHILD/stat" 2>/dev/null || printf '')" = "$CASE16I_CHILD_START" ] &&
  pass 'case16i-parent-lock-leave-live-replacement:identity-positive-child-not-signalled' ||
  fail 'case16i-parent-lock-leave-live-replacement:identity-positive-child-signalled'
[ "$(cat "$CASE16I_LOCKS/merv_boot_shield.active" 2>/dev/null || printf '')" = 'run_id=leave-replacement-run' ] &&
  [ "$(cat "$CASE16I_LOCKS/merv_boot_shield.pid" 2>/dev/null || printf '')" = "$CASE16I_SUCCESSOR" ] &&
  [ -e "$CASE16I_LOCKS/merv_boot_shield.pid.start" ] &&
  [ "$(cat "$CASE16I_LOCKS/merv_boot_shield.handoff" 2>/dev/null || printf '')" = "$(printf 'parent_run_id=leave-replacement-run\nhandoff_id=leave-replacement-handoff\nwatchdog_state=handoff-published')" ] &&
  [ "$(cat "$CASE16I_LOCKS/merv_boot_shield.ready" 2>/dev/null || printf '')" = "$CASE16I_SUCCESSOR" ] &&
  kill -0 "$CASE16I_SUCCESSOR" 2>/dev/null &&
  pass 'case16i-parent-lock-leave-live-replacement:successor-publication-retained' ||
  fail 'case16i-parent-lock-leave-live-replacement:successor-publication-mutated'
_stop_child "$CASE16I_CHILD"
_stop_child "$CASE16I_SUCCESSOR"

# --- Test Case 18: Transient parent start lookup resolves before retry ------
# The first post-fork /proc observation fails, but the parent retries while it
# still owns the transient lock. A verified retry may retire only its exact
# marker and child; an independent Shield invocation must then publish a new
# complete starting handoff.
CASE18="$TEST_ROOT/case18-start-lookup-retry"
CASE18_LOCKS="$CASE18/locks"
CASE18_PIDF="$CASE18_LOCKS/merv_boot_shield.pid"
_run_shield "$CASE18" live 0 '' once
_wait_for_file "$CASE18/watchdog-child-pid" 5 || fail 'case18-first:child-not-spawned'
CASE18_OLD_PID=$(cat "$CASE18/watchdog-child-pid" 2>/dev/null || printf '')
_finish_shield case18-first
[ -e "$CASE18/start-lookup-failed-once" ] && [ -e "$CASE18/parent-rollback-lock-owned" ] &&
  pass 'case18-first:lookup-failure-and-lock-ownership-proven' ||
  fail 'case18-first:lookup-failure-or-lock-ownership-not-proven'
[ ! -e "$CASE18_LOCKS/merv_boot_shield.active" ] && [ ! -e "$CASE18_PIDF" ] &&
  [ ! -e "${CASE18_PIDF}.start" ] && [ ! -e "$CASE18_LOCKS/merv_boot_shield.handoff" ] &&
  ! kill -0 "$CASE18_OLD_PID" 2>/dev/null &&
  pass 'case18-first:exact-marker-and-child-retired' ||
  fail 'case18-first:orphan-retained-or-child-live'
rm -f "$CASE18/watchdog-child-pid"
_run_shield "$CASE18" live 0
_wait_for_file "$CASE18/watchdog-child-pid" 5 || fail 'case18-second:child-not-spawned'
CASE18_NEW_PID=$(cat "$CASE18/watchdog-child-pid" 2>/dev/null || printf '')
_finish_shield case18-second
CASE18_NEW_RUN=$(sed -n 's/^run_id=//p' "$CASE18_LOCKS/merv_boot_shield.active" 2>/dev/null | head -n 1)
CASE18_NEW_START=$(cat "${CASE18_PIDF}.start" 2>/dev/null || printf '')
[ -n "$CASE18_NEW_PID" ] && [ "$CASE18_NEW_PID" != "$CASE18_OLD_PID" ] &&
  [ "$(cat "$CASE18_PIDF" 2>/dev/null || printf '')" = "$CASE18_NEW_PID" ] &&
  [ -n "$CASE18_NEW_START" ] && [ -n "$CASE18_NEW_RUN" ] &&
  [ "$(cat "$CASE18_LOCKS/merv_boot_shield.handoff" 2>/dev/null || printf '')" = \
    "$(printf 'parent_run_id=%s\nhandoff_id=pending\nwatchdog_state=starting' "$CASE18_NEW_RUN")" ] &&
  pass 'case18-second:new-complete-watchdog-publication-started' ||
  fail 'case18-second:new-watchdog-publication-missing-or-incomplete'
_stop_child "$CASE18_NEW_PID"

if [ "$_FAILURES" -eq 0 ]; then
  printf 'BOOT_WATCHDOG_DIAGNOSTIC_CONTRACT_OK\n'
  exit 0
else
  printf 'BOOT_WATCHDOG_DIAGNOSTIC_CONTRACT_FAILED (%s failure(s))\n' "$_FAILURES" >&2
  exit 1
fi
