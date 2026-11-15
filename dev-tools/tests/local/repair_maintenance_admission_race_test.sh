#!/bin/sh
# Isolated runtime contract for the Heal/Manager maintenance admission race.
# It executes the exact production lock-admission and cleanup functions with
# synthetic locks; no router commands or production state are accessed.
set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
HEAL="$BASE_DIR/functions/heal_event.sh"
MANAGER="$BASE_DIR/functions/mervlan_manager.sh"
HANDLER="$BASE_DIR/functions/service-event-handler.sh"
TEST_ROOT="${TMPDIR:-/tmp}/mervlan_tmp/selftest.repair-maintenance-race.$$"
umask 077
mkdir -p "${TEST_ROOT%/*}" || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

extract_marked() {
  _em_source=$1 _em_start=$2 _em_end=$3 _em_out=$4
  awk -v start="$_em_start" -v end="$_em_end" '
    index($0, start) { copying=1; next }
    index($0, end) { copying=0; exit }
    copying { print }
  ' "$_em_source" >"$_em_out" || return 1
  [ -s "$_em_out" ]
}

assemble_with_sources() {
  _aws_template=$1 _aws_output=$2 _aws_marker_a=$3 _aws_source_a=$4
  _aws_marker_b=$5 _aws_source_b=$6
  while IFS= read -r _aws_line || [ -n "$_aws_line" ]; do
    case "$_aws_line" in
      "$_aws_marker_a") cat "$_aws_source_a" || return 1 ;;
      "$_aws_marker_b") cat "$_aws_source_b" || return 1 ;;
      *) printf '%s\n' "$_aws_line" ;;
    esac
  done <"$_aws_template" >"$_aws_output"
}

_heal_guard=$(grep -n -m 1 '^if ! type merv_update_mutation_blocked' "$HEAL" | cut -d: -f1)
_heal_dhcp=$(grep -n -m 1 'merv_dhcp_hold_reconcile heal-start' "$HEAL" | cut -d: -f1)
[ -n "$_heal_guard" ] && [ -n "$_heal_dhcp" ] && [ "$_heal_guard" -lt "$_heal_dhcp" ] || \
  fail 'Heal does not fail closed before DHCP/bridge reconciliation'
_manager_guard=$(grep -n -m 1 '^if ! type merv_update_mutation_blocked' "$MANAGER" | cut -d: -f1)
_manager_boot=$(grep -n -m 1 '^if \[ "$MERV_MANAGER_MODE" = "boot" \]' "$MANAGER" | cut -d: -f1)
[ -n "$_manager_guard" ] && [ -n "$_manager_boot" ] && [ "$_manager_guard" -lt "$_manager_boot" ] || \
  fail 'Manager does not fail closed before boot-mode file writes'
_shield=$(grep -n -m 1 '^    # Inline shield re-link' "$HANDLER" | cut -d: -f1)
_async=$(grep -n -m 1 '^    # Fire-and-forget heal' "$HANDLER" | cut -d: -f1)
[ -n "$_shield" ] && [ -n "$_async" ] && [ "$_shield" -lt "$_async" ] || \
  fail 'event handler no longer restores the shield before asynchronous Heal'
if grep -q 'merv_update_mutation_blocked' "$HANDLER"; then
  fail 'event handler unexpectedly gates its inline shield on maintenance'
fi

extract_marked "$HEAL" MERVLAN_HEAL_EXIT_CLEANUP_CONTRACT \
  END_MERVLAN_HEAL_EXIT_CLEANUP_CONTRACT "$TEST_ROOT/heal-cleanup.fn" || fail 'Heal cleanup extraction'
extract_marked "$HEAL" MERVLAN_HEAL_LOCK_ADMISSION_CONTRACT \
  END_MERVLAN_HEAL_LOCK_ADMISSION_CONTRACT "$TEST_ROOT/heal-admission.block" || fail 'Heal admission extraction'
extract_marked "$MANAGER" MERVLAN_MANAGER_LOCK_ADMISSION_CONTRACT \
  END_MERVLAN_MANAGER_LOCK_ADMISSION_CONTRACT "$TEST_ROOT/manager-lock.fn" || fail 'Manager lock extraction'
extract_marked "$MANAGER" MERVLAN_MANAGER_EXIT_CLEANUP_CONTRACT \
  END_MERVLAN_MANAGER_EXIT_CLEANUP_CONTRACT "$TEST_ROOT/manager-cleanup.fn" || fail 'Manager cleanup extraction'

cat >"$TEST_ROOT/heal-race.sh" <<'HEAL_TEST'
#!/bin/sh
set -u
LOCK=/tmp/vlan_event.lock
HEAL_LOCK_STALE_SEC=180
HEAL_LOCK_ACQUIRED=0
HEAL_LOCK_NONCE=
HEAL_DHCP_TOKEN=
HEAL_IFACE_VID_CACHE_ENABLED=0
HEAL_EXIT_REASON=process-exit
MERV_TEST_MAINTENANCE=0
info() { :; }
error() { :; }
merv_update_mutation_blocked() { [ "$MERV_TEST_MAINTENANCE" = 1 ]; }
merv_owner_lock_acquire() {
  HEAL_LOCK_ACQUIRED=1
  HEAL_LOCK_NONCE=heal-test-owner
  MERV_TEST_MAINTENANCE=1
  return 0
}
merv_owner_lock_release() {
  printf 'heal-lock-released\n' >>"$MERV_TEST_TRACE"
  return 0
}
merv_dhcp_hold_abandon() { return 0; }
HEAL_CLEANUP_SOURCE
HEAL_ADMISSION_SOURCE
printf 'heal-mutated\n' >>"$MERV_TEST_TRACE"
HEAL_TEST

cat >"$TEST_ROOT/manager-race.sh" <<'MANAGER_TEST'
#!/bin/sh
set -u
DRY_RUN=no
LOCK_PATH=/tmp/mervlan_manager.lock
LOCKDIR=/tmp/mervlan-test-locks
MERV_ACTION_LOCK_PATH=/tmp/mervlan-test-action.lock
MERV_MANAGER_LOCK_STALE_SEC=420
MERV_ACTION_RUNTIME_OWNER=0
LOCK_ACQUIRED=0
ACTION_LOCK_ACQUIRED=0
ACTION_LOCK_NONCE=
ACTION_LOCK_START=
ACTION_LOCK_MODE=none
MANAGER_LOCK_NONCE=
MANAGER_RUNTIME_OWNED=0
MANAGER_DHCP_TOKEN=
MANAGER_EXIT_REASON=process-exit
CHANGE_LOG=
MERV_ACTION_PROGRESS_ENABLED=0
MERV_TEST_MAINTENANCE=0
info() { :; }
error() { :; }
merv_update_mutation_blocked() { [ "$MERV_TEST_MAINTENANCE" = 1 ]; }
merv_action_lock_enter() {
  MERV_ACTION_LOCK_MODE=self
  MERV_ACTION_LOCK_NONCE=action-test-owner
  MERV_ACTION_LOCK_START=1
  return 0
}
merv_action_lock_export_child_context() { return 0; }
merv_action_lock_clear_child_context() { return 0; }
merv_action_lock_leave() {
  printf 'action-lock-released\n' >>"$MERV_TEST_TRACE"
  return 0
}
merv_owner_lock_state() { printf 'absent'; return 0; }
merv_owner_lock_acquire() {
  MERV_LOCK_NONCE=manager-test-owner
  MERV_TEST_MAINTENANCE=1
  return 0
}
merv_owner_lock_release() {
  printf 'manager-lock-released\n' >>"$MERV_TEST_TRACE"
  return 0
}
merv_action_runtime_start() {
  printf 'manager-runtime-started\n' >>"$MERV_TEST_TRACE"
  return 0
}
merv_dhcp_hold_abandon() { return 0; }
MANAGER_LOCK_SOURCE
MANAGER_CLEANUP_SOURCE
trap cleanup_on_exit EXIT
acquire_script_lock
printf 'manager-mutated\n' >>"$MERV_TEST_TRACE"
MANAGER_TEST

_heal_script="$TEST_ROOT/heal-race.sh.tmp"
assemble_with_sources "$TEST_ROOT/heal-race.sh" "$_heal_script" \
  HEAL_CLEANUP_SOURCE "$TEST_ROOT/heal-cleanup.fn" \
  HEAL_ADMISSION_SOURCE "$TEST_ROOT/heal-admission.block" || fail 'Heal harness assembly'
mv "$_heal_script" "$TEST_ROOT/heal-race.sh"

_manager_script="$TEST_ROOT/manager-race.sh.tmp"
assemble_with_sources "$TEST_ROOT/manager-race.sh" "$_manager_script" \
  MANAGER_LOCK_SOURCE "$TEST_ROOT/manager-lock.fn" \
  MANAGER_CLEANUP_SOURCE "$TEST_ROOT/manager-cleanup.fn" || fail 'Manager harness assembly'
mv "$_manager_script" "$TEST_ROOT/manager-race.sh"

run_shell_case() {
  _rsc_shell=$1 _rsc_script=$2 _rsc_trace=$3
  rm -f "$_rsc_trace"
  case "$_rsc_shell" in
    dash)
      if MERV_TEST_TRACE="$_rsc_trace" /bin/sh "$_rsc_script" >/dev/null 2>&1; then _rsc=0; else _rsc=$?; fi
      ;;
    busybox)
      if MERV_TEST_TRACE="$_rsc_trace" busybox ash "$_rsc_script" >/dev/null 2>&1; then _rsc=0; else _rsc=$?; fi
      ;;
    *) return 1 ;;
  esac
  [ "$_rsc" -eq 75 ] || fail "$_rsc_shell $2 did not refuse after maintenance won the race (rc=$_rsc)"
  ! grep -Eq 'mutated|runtime-started' "$_rsc_trace" 2>/dev/null || fail "$_rsc_shell $2 passed the post-lock safety gate"
  grep -q 'lock-released' "$_rsc_trace" || fail "$_rsc_shell $2 did not release acquired runtime ownership"
}

for _race_shell in dash busybox; do
  run_shell_case "$_race_shell" "$TEST_ROOT/heal-race.sh" "$TEST_ROOT/heal.$_race_shell.trace"
  run_shell_case "$_race_shell" "$TEST_ROOT/manager-race.sh" "$TEST_ROOT/manager.$_race_shell.trace"
done

pass 'Heal and Manager refuse a maintenance race after lock acquisition and release runtime ownership'
pass 'event shield restoration remains synchronous and outside the Heal maintenance gate'
