#!/bin/sh
# Local contract coverage for Backup and Update signal/EXIT cleanup.
#
# The handlers are extracted from the production scripts (without sourcing
# their top-level work) and run with deterministic pool, release, and rollback
# stubs. The critical cases cover both independent preservation gates: an
# unresolved worker pool and a failed rollback after a clean worker abort.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.backup-update-signal.$$"
umask 077
mkdir -p "$TEST_ROOT/extracted" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_function() {
  _eus_src="$1"
  _eus_name="$2"
  _eus_out="$3"
  awk -v name="$_eus_name" '
    function brace_delta(line,   i,c,n) {
      gsub(/\$\{[^}]*\}/, "", line)
      n=0
      for (i=1; i<=length(line); i++) {
        c=substr(line, i, 1)
        if (c == "{") n++
        else if (c == "}") n--
      }
      return n
    }
    !inside && $0 ~ "^[[:space:]]*" name "[[:space:]]*\\(\\)[[:space:]]*\\{" {
      inside=1
    }
    inside {
      print
      depth += brace_delta($0)
      if (depth == 0) exit
    }
  ' "$_eus_src" > "$_eus_out" || return 1
  [ -s "$_eus_out" ]
}

extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_pool_state_unresolved \
  "$TEST_ROOT/extracted/mb_state.sh" || fail 'backup state extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_abort_node_pool \
  "$TEST_ROOT/extracted/mb_abort.sh" || fail 'backup abort extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_mark_recovery_required \
  "$TEST_ROOT/extracted/mb_recovery.sh" || fail 'backup recovery-state extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_cleanup \
  "$TEST_ROOT/extracted/mb_cleanup.sh" || fail 'backup cleanup extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_handle_signal \
  "$TEST_ROOT/extracted/mb_signal.sh" || fail 'backup signal extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_rollback_after_activation \
  "$TEST_ROOT/extracted/mb_rollback_after_activation.sh" || fail 'backup post-activation rollback extraction'
extract_function "$BASE_DIR/functions/update_mervlan.sh" update_pool_state_unresolved \
  "$TEST_ROOT/extracted/update_state.sh" || fail 'update state extraction'
extract_function "$BASE_DIR/functions/update_mervlan.sh" update_abort_node_pool \
  "$TEST_ROOT/extracted/update_abort.sh" || fail 'update abort extraction'
extract_function "$BASE_DIR/functions/update_mervlan.sh" update_activation_started \
  "$TEST_ROOT/extracted/update_activation.sh" || fail 'update activation-state extraction'
extract_function "$BASE_DIR/functions/update_mervlan.sh" update_mark_recovery_required \
  "$TEST_ROOT/extracted/update_recovery.sh" || fail 'update recovery extraction'
extract_function "$BASE_DIR/functions/update_mervlan.sh" cleanup_tmp \
  "$TEST_ROOT/extracted/update_cleanup.sh" || fail 'update cleanup extraction'
extract_function "$BASE_DIR/functions/update_mervlan.sh" handle_update_signal \
  "$TEST_ROOT/extracted/update_signal.sh" || fail 'update signal extraction'
extract_function "$BASE_DIR/functions/update_mervlan.sh" fail_update \
  "$TEST_ROOT/extracted/update_fail.sh" || fail 'update failure-handler extraction'

cat > "$TEST_ROOT/driver.sh" <<'DRIVER'
#!/bin/sh
set -u

CASE_ROOT=${CASE_ROOT:?}
CASE_KIND=${CASE_KIND:?}
CASE_MODE=${CASE_MODE:?}
TRACE="$CASE_ROOT/trace"
READY="$CASE_ROOT/ready"
mkdir -p "$CASE_ROOT" || exit 2

printf '%s\n' "driver-start kind=$CASE_KIND mode=$CASE_MODE" >> "$TRACE"
info() { :; }
warn() { printf 'warn:%s\n' "$*" >> "$TRACE"; }
error() { printf 'error:%s\n' "$*" >> "$TRACE"; }

# The first abort in the critical signal case fails; a later invocation is
# deliberately successful to model an EXIT retry that must not clear the
# signal-path safety decision.
POOL_UNRESOLVED=0
ABORT_CALLS=0
mnj_pool_state_unresolved() {
  [ "$POOL_UNRESOLVED" = 1 ]
}
mnj_pool_abort_active() {
  ABORT_CALLS=$((ABORT_CALLS + 1))
  case "$CASE_MODE" in
    normal-failure|signal-critical-failure)
      if [ "$ABORT_CALLS" = 1 ]; then
        : > "$CASE_ROOT/second-abort-would-succeed"
        printf 'abort-call=%s result=fail\n' "$ABORT_CALLS" >> "$TRACE"
        return 1
      fi
      POOL_UNRESOLVED=0
      MNJ_POOL_ACTIVE=0
      printf 'abort-call=%s result=success\n' "$ABORT_CALLS" >> "$TRACE"
      return 0
      ;;
    *)
      POOL_UNRESOLVED=0
      MNJ_POOL_ACTIVE=0
      printf 'abort-call=%s result=success\n' "$ABORT_CALLS" >> "$TRACE"
      return 0
      ;;
  esac
}

merv_owner_lock_release() {
  printf 'release args=%s|%s\n' "${1:-}" "${2:-}" >> "$TRACE"
  return 0
}

mb_remove_jffs_stage() {
  printf 'stage-remove=%s\n' "${1:-}" >> "$TRACE"
  rm -rf "$1"
}
update_remove_jffs_stage() {
  printf 'stage-remove=%s\n' "${1:-}" >> "$TRACE"
  rm -rf "$1"
}

mb_rollback_restore() {
  printf 'rollback-call=backup\n' >> "$TRACE"
  [ "${ROLLBACK_RESULT:-success}" = success ]
}
mb_clear_durable_recovery() { return 0; }
restore_update_original_tree() {
  printf 'rollback-call=update\n' >> "$TRACE"
  if [ "$CASE_MODE" = signal-rename-window ]; then
    mv "$UPDATE_JFFS_OLD" "$MERV_BASE" || return 1
    rm -rf "$UPDATE_JFFS_STAGE" || return 1
  fi
  [ "${ROLLBACK_RESULT:-success}" = success ]
}
mb_write_result() { printf 'result-write=%s\n' "${1:-}" >> "$TRACE"; return 0; }
mb_fail() { printf 'mb-fail=%s|%s\n' "${1:-}" "${2:-}" >> "$TRACE"; return 0; }
update_record_phase() { printf 'update-phase=%s\n' "${1:-}" >> "$TRACE"; return 0; }
run_update_step() { printf 'update-step=%s\n' "${1:-}" >> "$TRACE"; return 0; }
merv_update_quiesce_clear() {
  printf 'quiesce-clear runtime=%s recovery=%s\n' "$UPDATE_RUNTIME_RESTORED" "$UPDATE_RECOVERY_REQUIRED" >> "$TRACE"
  rm -f "$MERV_UPDATE_QUIESCE_FILE"
  return 0
}
merv_update_journal_clear() {
  printf 'journal-clear runtime=%s recovery=%s\n' "$UPDATE_RUNTIME_RESTORED" "$UPDATE_RECOVERY_REQUIRED" >> "$TRACE"
  rm -f "$MERV_UPDATE_JOURNAL"
  return 0
}
log_maintain_all() { :; }

case "$CASE_KIND" in
  backup)
    . "$EXTRACT_ROOT/mb_state.sh" || exit 2
    . "$EXTRACT_ROOT/mb_abort.sh" || exit 2
    . "$EXTRACT_ROOT/mb_recovery.sh" || exit 2
    . "$EXTRACT_ROOT/mb_cleanup.sh" || exit 2
    . "$EXTRACT_ROOT/mb_signal.sh" || exit 2
    . "$EXTRACT_ROOT/mb_rollback_after_activation.sh" || exit 2
    MB_POOL_ABORT_FAILED=0
    MB_RECOVERY_REQUIRED=0
    MB_DURABLE_RECOVERY_OWNED=0
    MB_SIGNAL_HANDLING=0
    MB_LOCK_OWNED=1
    MB_LOCK="$CASE_ROOT/maintenance.lock"
    MERV_LOCK_NONCE=backup-owner
    MB_PRESERVE_WORK=0
    MB_PRESERVE_JFFS=0
    MB_ACTIVATION_STARTED=0
    MB_ROLLBACK_DONE=0
    MB_RESTORE_ORIGINAL="$CASE_ROOT/original"
    MB_RESTORE_ORIGINAL_BOOT=0
    MB_OPERATION=backup_inventory
    MB_WORK_ROOT="$CASE_ROOT/work"
    MB_JFFS_STAGE="$CASE_ROOT/stage"
    MB_JFFS_OLD="$CASE_ROOT/old"
    mkdir -p "$MB_WORK_ROOT" "$MB_RESTORE_ORIGINAL" "$MB_JFFS_STAGE" "$MB_JFFS_OLD" || exit 2
    : > "$MB_WORK_ROOT/marker"
    _cleanup=mb_cleanup
    _signal=mb_handle_signal
    ;;
  update)
    . "$EXTRACT_ROOT/update_state.sh" || exit 2
    . "$EXTRACT_ROOT/update_abort.sh" || exit 2
    . "$EXTRACT_ROOT/update_activation.sh" || exit 2
    . "$EXTRACT_ROOT/update_recovery.sh" || exit 2
    . "$EXTRACT_ROOT/update_cleanup.sh" || exit 2
    . "$EXTRACT_ROOT/update_signal.sh" || exit 2
    . "$EXTRACT_ROOT/update_fail.sh" || exit 2
    UPDATE_POOL_ABORT_FAILED=0
    UPDATE_RECOVERY_REQUIRED=0
    UPDATE_SIGNAL_HANDLING=0
    UPDATE_MAINTENANCE_LOCK_OWNED=1
    UPDATE_MAINTENANCE_LOCK="$CASE_ROOT/maintenance.lock"
    UPDATE_MAINTENANCE_LOCK_NONCE=update-owner
    UPDATE_PRESERVE_TMP=0
    UPDATE_PRESERVE_JFFS=0
    UPDATE_ACTIVATION_STARTED=0
    MERVLAN_BACKUP_DIR="$CASE_ROOT"
    UPDATE_JFFS_STAGE="$CASE_ROOT/.mervlan.new.1"
    UPDATE_JFFS_OLD="$CASE_ROOT/.mervlan.old.1"
    MERV_BASE="$CASE_ROOT/active"
    UPDATE_ORIGINAL_DIR="$CASE_ROOT/original"
    UPDATE_QUIESCE_ACTIVE=1
    MERV_UPDATE_JOURNAL="$CASE_ROOT/update.journal"
    MERV_UPDATE_QUIESCE_FILE="$CASE_ROOT/update.quiesce"
    TMP_BASE="$CASE_ROOT/work"
    mkdir -p "$TMP_BASE" "$UPDATE_JFFS_STAGE" "$UPDATE_JFFS_OLD" "$UPDATE_ORIGINAL_DIR" || exit 2
    : > "$TMP_BASE/marker"
    : > "$MERV_UPDATE_JOURNAL"
    : > "$MERV_UPDATE_QUIESCE_FILE"
    _cleanup=cleanup_tmp
    _signal=handle_update_signal
    ;;
  *) exit 2 ;;
esac

case "$CASE_MODE" in
  normal-success|normal-failure|signal-before-activation|signal-success|signal-critical-failure|signal-rollback-failure|signal-rename-window)
    POOL_UNRESOLVED=1
    MNJ_POOL_ACTIVE=1
    ;;
esac

if [ "$CASE_KIND" = backup ]; then
  if [ "$CASE_MODE" = signal-critical-failure ]; then
    MB_ACTIVATION_STARTED=1
    MB_PRESERVE_WORK=0
    MB_PRESERVE_JFFS=0
  elif [ "$CASE_MODE" = signal-success ] || [ "$CASE_MODE" = signal-rollback-failure ]; then
    MB_ACTIVATION_STARTED=1
    [ "$CASE_MODE" != signal-rollback-failure ] || ROLLBACK_RESULT=fail
  fi
else
  if [ "$CASE_MODE" = signal-critical-failure ]; then
    UPDATE_ACTIVATION_STARTED=1
    UPDATE_PRESERVE_TMP=0
    UPDATE_PRESERVE_JFFS=0
  elif [ "$CASE_MODE" = signal-success ] || [ "$CASE_MODE" = signal-rollback-failure ]; then
    UPDATE_ACTIVATION_STARTED=1
    [ "$CASE_MODE" != signal-rollback-failure ] || ROLLBACK_RESULT=fail
  fi
fi

if [ "$CASE_KIND" = update ] && [ "$CASE_MODE" = signal-before-activation ]; then
  rm -rf "$UPDATE_JFFS_OLD"
fi

cleanup_on_exit() {
  _exit_rc=$?
  "$_cleanup"
  _cleanup_rc=$?
  [ "$_cleanup_rc" -eq 0 ] || _exit_rc="$_cleanup_rc"
  return "$_exit_rc"
}
trap cleanup_on_exit EXIT

case "$CASE_MODE" in
  normal-clean)
    exit 0
    ;;
  normal-success)
    exit 0
    ;;
  normal-failure)
    exit 1
    ;;
  normal-rollback-success)
    mb_rollback_after_activation reconciliation \
      'restore failed; original installation was restored' \
      'restore failed; automatic rollback failed; recovery preserved' \
      "$MB_RESTORE_ORIGINAL" "$MB_RESTORE_ORIGINAL_BOOT"
    exit 1
    ;;
  normal-rollback-failure)
    ROLLBACK_RESULT=fail
    mb_rollback_after_activation reconciliation \
      'restore failed; original installation was restored' \
      'restore failed; automatic rollback failed; recovery preserved' \
      "$MB_RESTORE_ORIGINAL" "$MB_RESTORE_ORIGINAL_BOOT"
    exit 1
    ;;
  normal-update-rollback-success|normal-update-rollback-failure|normal-update-rollback-fallback-success)
    DESTRUCTIVE_TOUCHED=1
    BACKUP_READY=1
    TEARDOWN_DONE=1
    UPDATE_RUNTIME_RESTORED=0
    MAC_DB_BACKUP_PRESENT=0
    UPDATE_NODES_TOUCHED=0
    BACKUP_DIR="$CASE_ROOT/no-backup"
    BOOT_SCRIPT=""
    PRE_BOOT_ENABLED=0
    if [ "$CASE_MODE" = normal-update-rollback-fallback-success ]; then
      BOOT_SCRIPT="$CASE_ROOT/fallback-boot.sh"
      : > "$BOOT_SCRIPT"
      chmod 700 "$BOOT_SCRIPT"
      PRE_BOOT_ENABLED=1
      ROLLBACK_RESULT=fail
    elif [ "$CASE_MODE" = normal-update-rollback-failure ]; then
      ROLLBACK_RESULT=fail
    fi
    fail_update post_activation 'forced post-activation failure'
    exit 2
    ;;
  signal-before-activation|signal-success|signal-critical-failure|signal-rollback-failure|signal-rename-window)
    trap '"$_signal" 143' TERM
    : > "$READY"
    while :; do sleep 1; done
    ;;
  *) exit 2 ;;
esac
DRIVER
chmod 700 "$TEST_ROOT/driver.sh" || exit 1

run_case() {
  _rc_kind="$1"
  _rc_mode="$2"
  _rc_root="$TEST_ROOT/$_rc_kind-$_rc_mode"
  mkdir -p "$_rc_root" || fail "$_rc_kind $_rc_mode fixture setup"
  case "$_rc_mode" in
  normal-clean|normal-success|normal-failure|normal-rollback-success|normal-rollback-failure|normal-update-rollback-success|normal-update-rollback-failure|normal-update-rollback-fallback-success)
    ( CASE_ROOT="$_rc_root" CASE_KIND="$_rc_kind" CASE_MODE="$_rc_mode" \
      EXTRACT_ROOT="$TEST_ROOT/extracted" sh "$TEST_ROOT/driver.sh" ) \
      > "$_rc_root/stdout" 2>&1
    _rc=$?
    ;;
  signal-*)
    ( CASE_ROOT="$_rc_root" CASE_KIND="$_rc_kind" CASE_MODE="$_rc_mode" \
      EXTRACT_ROOT="$TEST_ROOT/extracted" sh "$TEST_ROOT/driver.sh" ) \
      > "$_rc_root/stdout" 2>&1 &
    _rc_pid=$!
    _rc_wait=0
    while [ ! -e "$_rc_root/ready" ] && [ "$_rc_wait" -lt 50 ]; do
      sleep 0.1
      _rc_wait=$((_rc_wait + 1))
    done
    [ -e "$_rc_root/ready" ] || {
      cat "$_rc_root/stdout" >&2
      kill -TERM "$_rc_pid" 2>/dev/null || :
      wait "$_rc_pid" 2>/dev/null || :
      fail "$_rc_kind $_rc_mode driver did not become ready"
    }
    kill -TERM "$_rc_pid" 2>/dev/null || fail "$_rc_kind $_rc_mode signal"
    wait "$_rc_pid" 2>/dev/null
    _rc=$?
    ;;
  *) fail "$_rc_kind unknown mode $_rc_mode" ;;
  esac

  [ "$_rc" -ne 2 ] || { cat "$_rc_root/stdout" >&2; fail "$_rc_kind $_rc_mode driver setup"; }
  [ -f "$_rc_root/trace" ] || fail "$_rc_kind $_rc_mode missing trace"
  _release_count=$(grep -c '^release args=' "$_rc_root/trace" 2>/dev/null || :)
  _release_count=${_release_count:-0}
  _abort_count=$(grep -c '^abort-call=' "$_rc_root/trace" 2>/dev/null || :)
  _abort_count=${_abort_count:-0}
  _rollback_count=$(grep -c '^rollback-call=' "$_rc_root/trace" 2>/dev/null || :)
  _rollback_count=${_rollback_count:-0}
  _work_marker="$_rc_root/work/marker"
  if [ "$_rc_kind" = update ]; then
    _stage_path="$_rc_root/.mervlan.new.1"
    _old_path="$_rc_root/.mervlan.old.1"
  else
    _stage_path="$_rc_root/stage"
    _old_path="$_rc_root/old"
  fi

  case "$_rc_mode" in
    normal-clean)
      [ "$_rc" -eq 0 ] || fail "$_rc_kind normal-clean rc=$_rc"
      [ "$_release_count" -eq 1 ] || fail "$_rc_kind normal-clean release=$_release_count"
      [ "$_abort_count" -eq 0 ] || fail "$_rc_kind normal-clean abort=$_abort_count"
      [ ! -e "$_work_marker" ] || fail "$_rc_kind normal-clean retained work"
      [ "$_rollback_count" -eq 0 ] || fail "$_rc_kind normal-clean rollback=$_rollback_count"
      ;;
    normal-success)
      [ "$_rc" -eq 0 ] || fail "$_rc_kind normal-success rc=$_rc"
      [ "$_release_count" -eq 1 ] || fail "$_rc_kind normal-success release=$_release_count"
      [ "$_abort_count" -eq 1 ] || fail "$_rc_kind normal-success abort=$_abort_count"
      [ ! -e "$_work_marker" ] || fail "$_rc_kind normal-success retained work"
      [ "$_rollback_count" -eq 0 ] || fail "$_rc_kind normal-success rollback=$_rollback_count"
      ;;
    normal-failure)
      [ "$_rc" -eq 1 ] || fail "$_rc_kind normal-failure rc=$_rc"
      grep -q '^abort-call=1 result=fail$' "$_rc_root/trace" || fail "$_rc_kind missing abort failure"
      [ "$_release_count" -eq 0 ] || fail "$_rc_kind normal-failure released lock"
      [ -e "$_work_marker" ] || fail "$_rc_kind normal-failure discarded recovery work"
      [ "$_rollback_count" -eq 0 ] || fail "$_rc_kind normal-failure rollback=$_rollback_count"
      ;;
    normal-rollback-success)
      [ "$_rc_kind" = backup ] || fail "$_rc_kind unsupported normal rollback success"
      [ "$_rc" -eq 1 ] || fail "backup normal-rollback-success rc=$_rc"
      [ "$_release_count" -eq 1 ] || fail "backup normal-rollback-success release=$_release_count"
      [ "$_abort_count" -eq 0 ] || fail "backup normal-rollback-success abort=$_abort_count"
      [ "$_rollback_count" -eq 1 ] || fail "backup normal-rollback-success rollback=$_rollback_count"
      grep -q '^mb-fail=reconciliation|restore failed; original installation was restored$' "$_rc_root/trace" || fail 'backup normal rollback success message'
      [ ! -e "$_work_marker" ] || fail 'backup normal rollback success retained work'
      ;;
    normal-rollback-failure)
      [ "$_rc_kind" = backup ] || fail "$_rc_kind unsupported normal rollback failure"
      [ "$_rc" -eq 1 ] || fail "backup normal-rollback-failure rc=$_rc"
      [ "$_release_count" -eq 0 ] || fail 'backup normal rollback failure released owner lock'
      [ "$_abort_count" -eq 0 ] || fail "backup normal-rollback-failure abort=$_abort_count"
      [ "$_rollback_count" -eq 1 ] || fail "backup normal-rollback-failure rollback=$_rollback_count"
      grep -q '^mb-fail=reconciliation|restore failed; automatic rollback failed; recovery preserved$' "$_rc_root/trace" || fail 'backup normal rollback failure message'
      if grep -q 'original installation was restored' "$_rc_root/trace"; then
        cat "$_rc_root/trace" >&2
        fail 'backup normal rollback failure falsely reported restoration'
      fi
      [ -e "$_work_marker" ] || fail 'backup normal rollback failure discarded work'
      [ -d "$_stage_path" ] || fail 'backup normal rollback failure discarded staged recovery tree'
      [ -d "$_old_path" ] || fail 'backup normal rollback failure discarded rollback source'
      ;;
    normal-update-rollback-success)
      [ "$_rc_kind" = update ] || fail "$_rc_kind unsupported update rollback success"
      [ "$_rc" -eq 1 ] || fail "update normal-rollback-success rc=$_rc"
      [ "$_release_count" -eq 1 ] || fail "update normal-rollback-success release=$_release_count"
      [ "$_abort_count" -eq 0 ] || fail "update normal-rollback-success abort=$_abort_count"
      [ "$_rollback_count" -eq 1 ] || fail "update normal-rollback-success rollback=$_rollback_count"
      grep -q 'backup restored' "$_rc_root/trace" || fail 'update normal rollback success result'
      [ ! -e "$_work_marker" ] || fail 'update normal rollback success retained work'
      [ ! -e "$_rc_root/update.journal" ] || fail 'update normal rollback success retained journal'
      [ ! -e "$_rc_root/update.quiesce" ] || fail 'update normal rollback success retained quiesce marker'
      ;;
    normal-update-rollback-failure)
      [ "$_rc_kind" = update ] || fail "$_rc_kind unsupported update rollback failure"
      [ "$_rc" -eq 1 ] || fail "update normal-rollback-failure rc=$_rc"
      [ "$_release_count" -eq 0 ] || fail 'update normal rollback failure released maintenance lock'
      [ "$_abort_count" -eq 0 ] || fail "update normal-rollback-failure abort=$_abort_count"
      [ "$_rollback_count" -eq 1 ] || fail "update normal-rollback-failure rollback=$_rollback_count"
      grep -q 'backup restore failed' "$_rc_root/trace" || fail 'update normal rollback failure result'
      [ -e "$_work_marker" ] || fail 'update normal rollback failure discarded temporary work'
      [ -d "$_stage_path" ] || fail 'update normal rollback failure discarded staged recovery tree'
      [ -d "$_old_path" ] || fail 'update normal rollback failure discarded rollback source'
      [ -e "$_rc_root/update.journal" ] || fail 'update normal rollback failure cleared journal'
      [ -e "$_rc_root/update.quiesce" ] || fail 'update normal rollback failure cleared quiesce marker'
      ;;
    normal-update-rollback-fallback-success)
      [ "$_rc_kind" = update ] || fail "$_rc_kind unsupported update rollback fallback"
      [ "$_rc" -eq 1 ] || fail "update normal-rollback-fallback rc=$_rc"
      [ "$_release_count" -eq 0 ] || fail 'update rollback fallback released maintenance lock'
      [ "$_rollback_count" -eq 1 ] || fail "update normal-rollback-fallback rollback=$_rollback_count"
      grep -q '^update-step=rollback main setupenable$' "$_rc_root/trace" || fail 'update rollback fallback skipped setupenable'
      grep -q '^update-step=rollback main enable$' "$_rc_root/trace" || fail 'update rollback fallback skipped enable'
      if grep -q '^[^#]*\(quiesce-clear\|journal-clear\)' "$_rc_root/trace"; then
        cat "$_rc_root/trace" >&2
        fail 'update rollback fallback cleared recovery markers'
      fi
      [ -e "$_rc_root/update.journal" ] || fail 'update rollback fallback cleared journal'
      [ -e "$_rc_root/update.quiesce" ] || fail 'update rollback fallback cleared quiesce marker'
      [ -d "$_old_path" ] || fail 'update rollback fallback discarded rollback source'
      ;;
    signal-before-activation)
      [ "$_rc" -eq 143 ] || fail "$_rc_kind signal-before-activation rc=$_rc"
      [ "$_release_count" -eq 1 ] || fail "$_rc_kind signal-before-activation release=$_release_count"
      [ "$_abort_count" -eq 1 ] || fail "$_rc_kind signal-before-activation abort=$_abort_count"
      [ "$_rollback_count" -eq 0 ] || fail "$_rc_kind signal-before-activation rollback=$_rollback_count"
      [ ! -e "$_work_marker" ] || fail "$_rc_kind signal-before-activation retained work"
      if [ "$_rc_kind" = backup ]; then
        grep -q '^result-write=interrupted$' "$_rc_root/trace" || fail "$_rc_kind signal-before-activation result"
      fi
      ;;
    signal-success)
      [ "$_rc" -eq 143 ] || fail "$_rc_kind signal-success rc=$_rc"
      [ "$_release_count" -eq 1 ] || fail "$_rc_kind signal-success release=$_release_count"
      [ "$_abort_count" -eq 1 ] || fail "$_rc_kind signal-success abort=$_abort_count"
      [ "$_rollback_count" -eq 1 ] || fail "$_rc_kind signal-success rollback=$_rollback_count"
      [ ! -e "$_work_marker" ] || fail "$_rc_kind signal-success retained work"
      if [ "$_rc_kind" = backup ]; then
        grep -q '^result-write=interrupted$' "$_rc_root/trace" || fail "$_rc_kind signal-success result"
      fi
      ;;
    signal-critical-failure)
      [ "$_rc" -eq 143 ] || fail "$_rc_kind signal-critical-failure rc=$_rc"
      grep -q '^abort-call=1 result=fail$' "$_rc_root/trace" || fail "$_rc_kind missing first abort failure"
      # The next controlled abort would succeed, but EXIT must not retry and
      # erase the signal path's critical preservation decision.
      [ -e "$_rc_root/second-abort-would-succeed" ] || fail "$_rc_kind second abort was not configured to succeed"
      [ "$_abort_count" -eq 1 ] || fail "$_rc_kind retried a latched abort failure"
      if [ "$_release_count" -ne 0 ]; then
        cat "$_rc_root/trace" >&2
        fail "$_rc_kind released lock after abort failure"
      fi
      [ -e "$_work_marker" ] || fail "$_rc_kind discarded recovery work"
      [ "$_rollback_count" -eq 0 ] || fail "$_rc_kind rolled back after unresolved workers"
      [ -d "$_stage_path" ] || fail "$_rc_kind discarded staged recovery tree"
      [ -d "$_old_path" ] || fail "$_rc_kind discarded rollback source"
      if [ "$_rc_kind" = backup ]; then
        grep -q '^result-write=interrupted$' "$_rc_root/trace" || fail "$_rc_kind result"
      else
        [ -e "$_rc_root/update.journal" ] || fail 'update cleared recovery journal'
        [ -e "$_rc_root/update.quiesce" ] || fail 'update cleared quiesce marker'
      fi
      ;;
    signal-rollback-failure)
      [ "$_rc" -eq 143 ] || fail "$_rc_kind signal-rollback-failure rc=$_rc"
      grep -q '^abort-call=1 result=success$' "$_rc_root/trace" || fail "$_rc_kind signal rollback did not reconcile workers"
      [ "$_abort_count" -eq 1 ] || fail "$_rc_kind signal rollback abort=$_abort_count"
      [ "$_rollback_count" -eq 1 ] || fail "$_rc_kind signal rollback=$_rollback_count"
      if [ "$_release_count" -ne 0 ]; then
        cat "$_rc_root/trace" >&2
        fail "$_rc_kind released lock after failed rollback"
      fi
      [ -e "$_work_marker" ] || fail "$_rc_kind discarded temporary recovery work after failed rollback"
      [ -d "$_stage_path" ] || fail "$_rc_kind discarded staged recovery tree after failed rollback"
      [ -d "$_old_path" ] || fail "$_rc_kind discarded rollback source after failed rollback"
      if [ "$_rc_kind" = backup ]; then
        grep -q '^result-write=interrupted$' "$_rc_root/trace" || fail "$_rc_kind failed rollback result"
      else
        [ -e "$_rc_root/update.journal" ] || fail 'update cleared recovery journal after failed rollback'
        [ -e "$_rc_root/update.quiesce" ] || fail 'update cleared quiesce marker after failed rollback'
      fi
      ;;
    signal-rename-window)
      [ "$_rc_kind" = update ] || fail "$_rc_kind unsupported rename window"
      [ "$_rc" -eq 143 ] || fail "update signal rename-window rc=$_rc"
      [ "$_release_count" -eq 1 ] || fail "update signal rename-window release=$_release_count"
      [ "$_rollback_count" -eq 1 ] || fail "update signal rename-window rollback=$_rollback_count"
      [ -d "$_rc_root/active" ] || fail 'update signal rename-window did not restore active tree'
      [ ! -e "$_stage_path" ] || fail 'update signal rename-window retained activation stage'
      [ ! -e "$_old_path" ] || fail 'update signal rename-window retained rollback tree'
      ;;
  esac
  pass "$_rc_kind $_rc_mode"
}

for _kind in ${C2_ONLY:-backup update}; do
  run_case "$_kind" normal-clean
  run_case "$_kind" normal-success
  run_case "$_kind" normal-failure
  if [ "$_kind" = backup ]; then
    run_case "$_kind" normal-rollback-success
    run_case "$_kind" normal-rollback-failure
  else
    run_case "$_kind" normal-update-rollback-success
    run_case "$_kind" normal-update-rollback-failure
    run_case "$_kind" normal-update-rollback-fallback-success
  fi
  run_case "$_kind" signal-before-activation
  run_case "$_kind" signal-success
  run_case "$_kind" signal-rollback-failure
  run_case "$_kind" signal-critical-failure
  [ "$_kind" != update ] || run_case "$_kind" signal-rename-window
done

printf 'BACKUP_UPDATE_SIGNAL_CLEANUP_CONTRACT_OK\n'
