#!/bin/sh
# Focused synthetic test for the RC3 Update Manager publication barrier.
set -u

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
MANAGER="$BASE_DIR/functions/mervlan_manager.sh"
UPDATE="$BASE_DIR/functions/update_mervlan.sh"
TEST_ROOT_BASE="/tmp/mervlan_tmp/selftest.rc3-manager-barrier.$$"
TEST_ROOT="$TEST_ROOT_BASE"
umask 077
mkdir -p "${TEST_ROOT_BASE%/*}" || exit 1
_root_suffix=0
while ! mkdir "$TEST_ROOT" 2>/dev/null; do
  _root_suffix=$((_root_suffix + 1))
  TEST_ROOT="$TEST_ROOT_BASE.$_root_suffix"
done
_cleanup() {
  [ "${MERV_TEST_KEEP:-0}" = 1 ] || rm -rf "$TEST_ROOT"
}
trap _cleanup 0 1 2 3 15

_FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _FAILURES=$((_FAILURES + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }

awk '
  /BEGIN MERVLAN_UPDATE_RC3_MANAGER_PUBLICATION_BARRIER/ { copying=1; next }
  /END MERVLAN_UPDATE_RC3_MANAGER_PUBLICATION_BARRIER/ { copying=0; exit }
  copying { print }
' "$UPDATE" > "$TEST_ROOT/barrier-functions.sh"
[ -s "$TEST_ROOT/barrier-functions.sh" ] || exit 1

_manager_action_line=$(grep -n 'merv_action_lock_enter "$ACTION_LOCK_PATH"' "$MANAGER" | head -n 1 | cut -d: -f1)
_manager_runtime_line=$(grep -n 'merv_owner_lock_acquire "$LOCK_PATH"' "$MANAGER" | head -n 1 | cut -d: -f1)
case "$_manager_action_line:$_manager_runtime_line" in
  *[!0-9:]*|:*|*:) fail 'Could not locate Manager action/runtime lock order' ;;
  *) [ "$_manager_action_line" -lt "$_manager_runtime_line" ] ||
       fail 'Manager no longer acquires the action lock before its runtime lock' ;;
esac

_update_run=$(awk '
  /^update_run_rc3_repair_candidate\(\) \{/ { copying=1 }
  copying && /^write_update_undo_marker\(\)/ { exit }
  copying { print }
' "$UPDATE")
_manager_release_line=$(printf '%s\n' "$_update_run" | grep -n 'update_rc3_publication_barrier_release_manager;' | tail -n 1 | cut -d: -f1)
_quiesce_clear_line=$(printf '%s\n' "$_update_run" | grep -n 'merv_update_quiesce_clear;' | tail -n 1 | cut -d: -f1)
_maintenance_release_line=$(printf '%s\n' "$_update_run" | grep -n 'merv_owner_lock_release "$UPDATE_MAINTENANCE_LOCK"' | tail -n 1 | cut -d: -f1)
_action_release_line=$(printf '%s\n' "$_update_run" | grep -n 'update_rc3_publication_barrier_action_release;' | tail -n 1 | cut -d: -f1)
case "$_manager_release_line:$_quiesce_clear_line:$_maintenance_release_line:$_action_release_line" in
  *[!0-9:]*|:*|*::*|*:) fail 'Could not locate success-path publication barrier release order' ;;
  *)
    [ "$_quiesce_clear_line" -lt "$_maintenance_release_line" ] &&
      [ "$_maintenance_release_line" -lt "$_manager_release_line" ] &&
      [ "$_manager_release_line" -lt "$_action_release_line" ] ||
      fail 'Publication barriers must remain held through quiesce and maintenance release'
    ;;
esac

cat > "$TEST_ROOT/fixture.sh" <<'FIXTURE'
#!/bin/sh
set -u
BASE_DIR=$MERV_TEST_BASE_DIR
PHASE_DIR=$MERV_TEST_PHASE_DIR
LOCKDIR="$PHASE_DIR/locks"
MERV_BASE="$BASE_DIR"
MERV_ACTION_LOCK_PATH="$LOCKDIR/mervlan_action.lock"
UPDATE_RC3_REPAIR_MODE=1
UPDATE_RC3_MANAGER_BARRIER_PATH=
UPDATE_RC3_MANAGER_BARRIER_NONCE=
UPDATE_RC3_MANAGER_BARRIER_OWNED=0
UPDATE_RC3_ACTION_BARRIER_PATH=
UPDATE_RC3_ACTION_BARRIER_NONCE=
UPDATE_RC3_ACTION_BARRIER_START=
UPDATE_RC3_ACTION_BARRIER_MODE=none
UPDATE_RC3_ACTION_BARRIER_RELEASE=0
MERV_ACTION_LOCK_PARENT_HELD=0
mkdir -p "$LOCKDIR" || exit 80
. "$BASE_DIR/settings/lib_identity.sh" || exit 81
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 82
. "$BASE_DIR/settings/lib_action_lock.sh" || exit 83
info() { :; }
error() { :; }
update_mark_recovery_required() { UPDATE_RECOVERY_REQUIRED=1; }
. "$MERV_TEST_FUNCTIONS" || exit 84
case "$1" in
  barrier)
    update_rc3_publication_barrier_acquire || exit 10
    [ "$UPDATE_RC3_MANAGER_BARRIER_OWNED" = 1 ] || exit 11
    [ "$UPDATE_RC3_ACTION_BARRIER_RELEASE" = 1 ] || exit 12
    case "$MERV_TEST_SHELL" in
      busybox)
        MERV_ACTION_LOCK_PARENT_HELD=0 busybox ash "$0" contender "$PHASE_DIR" || exit 13
        ;;
      *)
        MERV_ACTION_LOCK_PARENT_HELD=0 dash "$0" contender "$PHASE_DIR" || exit 13
        ;;
    esac
    update_rc3_publication_barrier_release_manager || exit 14
    [ ! -e "$LOCKDIR/mervlan_manager.lock" ] || exit 15
    [ -e "$LOCKDIR/mervlan_action.lock" ] || exit 16
    update_rc3_publication_barrier_action_release || exit 17
    [ ! -e "$LOCKDIR/mervlan_action.lock" ] || exit 18
    ;;
  hold-barrier)
    : > "$PHASE_DIR/maintenance-active" || exit 60
    update_rc3_publication_barrier_acquire || exit 61
    : > "$PHASE_DIR/holder-ready" || exit 62
    while [ ! -e "$PHASE_DIR/holder-release" ]; do sleep 1; done
    [ ! -e "$PHASE_DIR/maintenance-active" ] || exit 63
    update_rc3_publication_barrier_release_manager || exit 64
    update_rc3_publication_barrier_action_release || exit 65
    ;;
  runtime-contender)
    # Model a legacy Manager that already passed its update admission check and
    # does not participate in the global action lock. Its runtime owner lock
    # must keep it out until Update has left maintenance.
    : > "$PHASE_DIR/contender-started" || exit 66
    merv_owner_lock_acquire "$LOCKDIR/mervlan_manager.lock" 420 10 legacy-manager || exit 67
    _legacy_nonce="$MERV_LOCK_NONCE"
    [ ! -e "$PHASE_DIR/maintenance-active" ] || exit 68
    : > "$PHASE_DIR/manager-mutated" || exit 69
    merv_owner_lock_release "$LOCKDIR/mervlan_manager.lock" "$_legacy_nonce" || exit 70
    ;;
  contender)
    _admitted=1
    [ "$_admitted" = 1 ] || exit 20
    merv_action_lock_enter "$MERV_ACTION_LOCK_PATH"
    _contender_rc=$?
    [ "$_contender_rc" -eq 3 ] || exit 21
    [ ! -e "$2/manager-mutated" ] || exit 22
    ;;
  hold-action)
    merv_action_lock_enter "$MERV_ACTION_LOCK_PATH" || exit 30
    : > "$PHASE_DIR/holder-ready"
    while [ ! -e "$PHASE_DIR/holder-release" ]; do sleep 1; done
    merv_action_lock_leave "$MERV_ACTION_LOCK_PATH" "$MERV_ACTION_LOCK_NONCE" \
      "$MERV_ACTION_LOCK_START" self || exit 31
    ;;
  hold-manager)
    merv_owner_lock_acquire "$LOCKDIR/mervlan_manager.lock" 420 0 fixture-manager || exit 40
    _holder_nonce="$MERV_LOCK_NONCE"
    : > "$PHASE_DIR/holder-ready"
    while [ ! -e "$PHASE_DIR/holder-release" ]; do sleep 1; done
    merv_owner_lock_release "$LOCKDIR/mervlan_manager.lock" "$_holder_nonce" || exit 41
    ;;
  inherited-action)
    merv_action_lock_enter "$MERV_ACTION_LOCK_PATH" || exit 50
    merv_action_lock_export_child_context || exit 51
    update_rc3_publication_barrier_acquire || exit 52
    update_rc3_publication_barrier_release_manager || exit 53
    update_rc3_publication_barrier_action_release || exit 54
    [ -e "$LOCKDIR/mervlan_action.lock" ] || exit 55
    merv_action_lock_leave "$MERV_ACTION_LOCK_PATH" "$MERV_ACTION_LOCK_NONCE" \
      "$MERV_ACTION_LOCK_START" self || exit 56
    [ ! -e "$LOCKDIR/mervlan_action.lock" ] || exit 57
    ;;
  *) exit 2 ;;
esac
exit 0
FIXTURE

_run_fixture() {
  _rf_shell="$1"; _rf_mode="$2"; _rf_dir="$3"
  case "$_rf_shell" in
    dash)
      MERV_TEST_BASE_DIR="$BASE_DIR" MERV_TEST_PHASE_DIR="$_rf_dir" MERV_TEST_SHELL="$_rf_shell" \
        MERV_TEST_FUNCTIONS="$TEST_ROOT/barrier-functions.sh" \
        dash "$TEST_ROOT/fixture.sh" "$_rf_mode" "$_rf_dir"
      ;;
    busybox)
      MERV_TEST_BASE_DIR="$BASE_DIR" MERV_TEST_PHASE_DIR="$_rf_dir" MERV_TEST_SHELL="$_rf_shell" \
        MERV_TEST_FUNCTIONS="$TEST_ROOT/barrier-functions.sh" \
        busybox ash "$TEST_ROOT/fixture.sh" "$_rf_mode" "$_rf_dir"
      ;;
    *) return 2 ;;
  esac
}

_start_holder() {
  _sh="$1"; _mode="$2"; _dir="$3"
  case "$_sh" in
    dash)
      MERV_TEST_BASE_DIR="$BASE_DIR" MERV_TEST_PHASE_DIR="$_dir" MERV_TEST_SHELL="$_sh" \
        MERV_TEST_FUNCTIONS="$TEST_ROOT/barrier-functions.sh" \
        dash "$TEST_ROOT/fixture.sh" "$_mode" "$_dir" >/dev/null 2>&1 &
      ;;
    busybox)
      MERV_TEST_BASE_DIR="$BASE_DIR" MERV_TEST_PHASE_DIR="$_dir" MERV_TEST_SHELL="$_sh" \
        MERV_TEST_FUNCTIONS="$TEST_ROOT/barrier-functions.sh" \
        busybox ash "$TEST_ROOT/fixture.sh" "$_mode" "$_dir" >/dev/null 2>&1 &
      ;;
  esac
  _HOLDER=$!
}

_wait_for() {
  _wf_file="$1"; _wf_limit=10; _wf_i=0
  while [ ! -e "$_wf_file" ] && [ "$_wf_i" -lt "$_wf_limit" ]; do
    sleep 1
    _wf_i=$((_wf_i + 1))
  done
  [ -e "$_wf_file" ]
}

for _shell in dash busybox; do
  if [ "$_shell" = busybox ] && ! busybox ash -c ':' >/dev/null 2>&1; then
    fail 'BusyBox ash is required for the fixture'
    continue
  fi
  _dir="$TEST_ROOT/$_shell"
  mkdir -p "$_dir/locks"
  if _run_fixture "$_shell" barrier "$_dir" >"$_dir/barrier.out" 2>&1; then
    [ ! -e "$_dir/locks/mervlan_action.lock" ] &&
      [ ! -e "$_dir/locks/mervlan_manager.lock" ] &&
      pass "$_shell: admitted legacy Manager blocked; barriers released by their owner" ||
      fail "$_shell: successful barrier left a runtime lock behind"
  else
    _rc=$?
    fail "$_shell: Manager publication barrier lifecycle failed (rc=$_rc)"
  fi

  _dir="$TEST_ROOT/$_shell-inherited"
  mkdir -p "$_dir/locks"
  if _run_fixture "$_shell" inherited-action "$_dir" >/dev/null 2>&1; then
    pass "$_shell: inherited action owner remained held until its parent released it"
  else
    fail "$_shell: barrier released or lost its inherited action owner"
  fi

  _dir="$TEST_ROOT/$_shell-action-busy"
  mkdir -p "$_dir/locks"
  _start_holder "$_shell" hold-action "$_dir"
  _wait_for "$_dir/holder-ready" || fail "$_shell: action-lock holder did not start"
  if _run_fixture "$_shell" barrier "$_dir" >/dev/null 2>&1; then
    fail "$_shell: publication proceeded while another action owner was live"
  else
    [ ! -e "$_dir/locks/mervlan_manager.lock" ] &&
      pass "$_shell: live action owner refused before Manager barrier acquisition" ||
      fail "$_shell: refused action-lock race left a Manager barrier"
  fi
  : > "$_dir/holder-release"
  wait "$_HOLDER" 2>/dev/null || fail "$_shell: action-lock fixture owner did not release"

  _dir="$TEST_ROOT/$_shell-manager-busy"
  mkdir -p "$_dir/locks"
  _start_holder "$_shell" hold-manager "$_dir"
  _wait_for "$_dir/holder-ready" || fail "$_shell: Manager runtime owner did not start"
  if _run_fixture "$_shell" barrier "$_dir" >/dev/null 2>&1; then
    fail "$_shell: publication proceeded while Manager runtime lock was live"
  else
    [ ! -e "$_dir/locks/mervlan_action.lock" ] &&
      pass "$_shell: live Manager runtime owner refused; temporary action claim released" ||
      fail "$_shell: runtime refusal left an action barrier"
  fi
  : > "$_dir/holder-release"
  wait "$_HOLDER" 2>/dev/null || fail "$_shell: Manager runtime fixture owner did not release"

  _dir="$TEST_ROOT/$_shell-runtime-waiter"
  mkdir -p "$_dir/locks"
  _start_holder "$_shell" hold-barrier "$_dir"
  _BARRIER_HOLDER="$_HOLDER"
  _wait_for "$_dir/holder-ready" || fail "$_shell: publication barriers did not become active"
  _start_holder "$_shell" runtime-contender "$_dir"
  _LEGACY_HOLDER="$_HOLDER"
  _wait_for "$_dir/contender-started" || fail "$_shell: runtime-only legacy contender did not start"
  sleep 1
  [ ! -e "$_dir/manager-mutated" ] && [ -e "$_dir/maintenance-active" ] ||
    fail "$_shell: runtime-only legacy writer proceeded during maintenance"
  rm -f "$_dir/maintenance-active"
  : > "$_dir/holder-release"
  wait "$_BARRIER_HOLDER" 2>/dev/null || fail "$_shell: publication barrier holder did not release cleanly"
  wait "$_LEGACY_HOLDER" 2>/dev/null || fail "$_shell: runtime-only legacy writer did not resume after maintenance"
  [ -e "$_dir/manager-mutated" ] &&
    pass "$_shell: runtime-only legacy writer stayed blocked through maintenance and resumed after release" ||
    fail "$_shell: runtime-only legacy writer did not resume after barrier release"
done

if [ "$_FAILURES" -eq 0 ]; then
  printf 'RC3_MANAGER_PUBLICATION_BARRIER_CONTRACT_OK\n'
  exit 0
fi
if [ "${MERV_TEST_KEEP:-0}" = 1 ]; then
  printf 'RC3_MANAGER_BARRIER_FIXTURE_ROOT=%s\n' "$TEST_ROOT" >&2
fi
printf 'RC3_MANAGER_PUBLICATION_BARRIER_CONTRACT_FAILED (%s failure(s))\n' "$_FAILURES" >&2
exit 1
