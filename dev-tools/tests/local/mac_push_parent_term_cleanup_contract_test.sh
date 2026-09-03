#!/bin/sh
# Executable local behavior harness for caller-owned MAC push cleanup.
#
# Each case extracts the production cleanup/signal functions into an isolated
# driver, runs the real bounded node-job pool with a fake mutating worker, and
# sends TERM to the driver parent.  No router, SSH, ebtables, or production
# state is touched.  The lock-release fakes prove the worker is gone before a
# lock is released; the trace also proves no fake mutation follows cleanup.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
export MERV_BASE="$BASE_DIR"
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-push-parent-term.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

extract_function() {
  _ep_src="$1"
  _ep_name="$2"
  _ep_out="$3"
  awk -v name="$_ep_name" '
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
    !inside && $0 ~ "^[[:space:]]*" name "\\(\\)[[:space:]]*\\{" {
      inside=1
    }
    inside {
      print
      depth += brace_delta($0)
      if (depth == 0) exit
    }
  ' "$_ep_src" > "$_ep_out" || return 1
  [ -s "$_ep_out" ]
}

make_driver() {
  _md_case="$1"
  _md_case_root="$TEST_ROOT/$_md_case"
  mkdir -p "$_md_case_root" || return 1
  case "$_md_case" in
    observation)
      extract_function "$BASE_DIR/functions/post_apply_worker.sh" obs_abort_active_pool "$_md_case_root/obs_abort.sh" || return 1
      extract_function "$BASE_DIR/functions/post_apply_worker.sh" obs_pool_state_clean "$_md_case_root/obs_state.sh" || return 1
      extract_function "$BASE_DIR/functions/post_apply_worker.sh" obs_worker_cleanup "$_md_case_root/obs_cleanup.sh" || return 1
      extract_function "$BASE_DIR/functions/post_apply_worker.sh" obs_handle_signal "$_md_case_root/obs_signal.sh" || return 1
      ;;
    meta)
      extract_function "$BASE_DIR/functions/mac_client_meta.sh" meta_pool_state_unresolved "$_md_case_root/meta_state.sh" || return 1
      extract_function "$BASE_DIR/functions/mac_client_meta.sh" meta_abort_node_pool "$_md_case_root/meta_abort.sh" || return 1
      extract_function "$BASE_DIR/functions/mac_client_meta.sh" meta_handle_signal "$_md_case_root/meta_signal.sh" || return 1
      extract_function "$BASE_DIR/functions/mac_client_meta.sh" meta_release_action_lock "$_md_case_root/meta_action.sh" || return 1
      extract_function "$BASE_DIR/functions/mac_client_meta.sh" meta_release_lock "$_md_case_root/meta_lock.sh" || return 1
      ;;
    backup)
      extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_pool_state_unresolved "$_md_case_root/mb_state.sh" || return 1
      extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_abort_node_pool "$_md_case_root/mb_abort.sh" || return 1
      extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_handle_signal "$_md_case_root/mb_signal.sh" || return 1
      extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_cleanup "$_md_case_root/mb_cleanup.sh" || return 1
      ;;
    update)
      extract_function "$BASE_DIR/functions/update_mervlan.sh" update_pool_state_unresolved "$_md_case_root/update_state.sh" || return 1
      extract_function "$BASE_DIR/functions/update_mervlan.sh" update_abort_node_pool "$_md_case_root/update_abort.sh" || return 1
      extract_function "$BASE_DIR/functions/update_mervlan.sh" handle_update_signal "$_md_case_root/update_signal.sh" || return 1
      extract_function "$BASE_DIR/functions/update_mervlan.sh" cleanup_tmp "$_md_case_root/update_cleanup.sh" || return 1
      ;;
    *) return 1 ;;
  esac

  cat > "$_md_case_root/driver.sh" <<'DRIVER'
#!/bin/sh
set -u

export MERV_BASE CASE_ROOT CASE_NAME
export MERV_STATE_ROOT="$CASE_ROOT/state"
export MERV_NODE_PARALLELISM=3
. "$MERV_BASE/settings/var_settings.sh" || exit 2
. "$MERV_BASE/settings/lib_node_jobs.sh" || exit 2

FAKE_TRACE="$CASE_ROOT/trace"
FAKE_POOL_ROOT="$TMPDIR/node_jobs/c2-parent-term-$CASE_NAME-$$"
export FAKE_TRACE FAKE_POOL_ROOT
mkdir -p "$TMPDIR/node_jobs" "$FAKE_POOL_ROOT" || exit 2

info() { :; }
warn() { printf 'warn:%s\n' "$*" >> "$FAKE_TRACE"; }
error() { printf 'error:%s\n' "$*" >> "$FAKE_TRACE"; }

fake_worker() {
  trap 'printf "worker-term\n" >> "$FAKE_TRACE"; exit 143' INT TERM
  printf 'worker-start\n' >> "$FAKE_TRACE"
  while :; do
    printf 'worker-mutating\n' >> "$FAKE_TRACE"
    sleep 0.05
  done
}

fake_worker_still_live() {
  _fw_node=1
  while [ "$_fw_node" -le 3 ]; do
    _fw_dir="$FAKE_POOL_ROOT/node_$_fw_node"
    if [ -f "$_fw_dir/child.pid" ]; then
      _fw_pid=$(cat "$_fw_dir/child.pid" 2>/dev/null || printf '')
      case "$_fw_pid" in ''|*[!0-9]*) ;; *) kill -0 "$_fw_pid" 2>/dev/null && return 0 ;; esac
    fi
    _fw_node=$((_fw_node + 1))
  done
  return 1
}

fake_lock_release() {
  if fake_worker_still_live; then
    printf 'lock-release-before-worker-stop\n' >> "$FAKE_TRACE"
  fi
  printf 'lock-release\n' >> "$FAKE_TRACE"
  return 0
}

fake_action_release() {
  if fake_worker_still_live; then
    printf 'action-release-before-worker-stop\n' >> "$FAKE_TRACE"
  fi
  printf 'action-release\n' >> "$FAKE_TRACE"
  return 0
}

merv_lock_release() { fake_lock_release; }
merv_owner_lock_release() { fake_lock_release; }
merv_action_lock_leave() { fake_action_release; }

case "$CASE_NAME" in
  observation)
    . "$CASE_ROOT/obs_abort.sh" || exit 2
    . "$CASE_ROOT/obs_state.sh" || exit 2
    . "$CASE_ROOT/obs_cleanup.sh" || exit 2
    . "$CASE_ROOT/obs_signal.sh" || exit 2
    obs_log() { :; }
    obs_lock_release() { fake_lock_release; }
    OBS_WORKER_LOCK="$CASE_ROOT/observation.lock"
    OBS_LOCK_NONCE=observation-owner
    OBS_LOCK_ACQUIRED=1
    _ow_nonce="$OBS_LOCK_NONCE"
    OBS_SIGNAL_HANDLING=0
    trap 'obs_handle_signal 143' TERM
    _caller_cleanup=obs_worker_cleanup
    ;;
  meta)
    . "$CASE_ROOT/meta_state.sh" || exit 2
    . "$CASE_ROOT/meta_abort.sh" || exit 2
    . "$CASE_ROOT/meta_signal.sh" || exit 2
    . "$CASE_ROOT/meta_action.sh" || exit 2
    . "$CASE_ROOT/meta_lock.sh" || exit 2
    merv_action_progress_fail() { :; }
    merv_action_lock_leave() { fake_action_release; }
    META_ACTION_LOCK_PATH="$CASE_ROOT/action.lock"
    META_ACTION_LOCK_NONCE=meta-action
    META_ACTION_LOCK_START=1
    META_ACTION_LOCK_MODE=self
    META_ACTION_LOCK_RELEASED=0
    META_LOCK="$CASE_ROOT/meta.lock"
    META_LOCK_NONCE=meta-owner
    META_LOCK_ACQUIRED=1
    trap 'meta_handle_signal 143' TERM
    _caller_cleanup=meta_release_lock
    ;;
  backup)
    . "$CASE_ROOT/mb_state.sh" || exit 2
    . "$CASE_ROOT/mb_abort.sh" || exit 2
    . "$CASE_ROOT/mb_signal.sh" || exit 2
    . "$CASE_ROOT/mb_cleanup.sh" || exit 2
    mb_write_result() { printf 'result-write\n' >> "$FAKE_TRACE"; return 0; }
    MB_LOCK="$CASE_ROOT/maintenance.lock"
    MB_LOCK_OWNED=1
    MERV_LOCK_NONCE=backup-owner
    MB_PRESERVE_WORK=0
    MB_PRESERVE_JFFS=1
    MB_POOL_ABORT_FAILED=0
    MB_RECOVERY_REQUIRED=0
    MB_ACTIVATION_STARTED=0
    MB_ROLLBACK_DONE=0
    MB_OPERATION=backup_inventory
    MB_WORK_ROOT="$CASE_ROOT/mb-work"
    MB_JFFS_STAGE="$CASE_ROOT/unused-stage"
    MB_JFFS_OLD="$CASE_ROOT/unused-old"
    mkdir -p "$MB_WORK_ROOT"
    : > "$MB_WORK_ROOT/marker"
    trap 'mb_handle_signal 143' TERM
    _caller_cleanup=mb_cleanup
    ;;
  update)
    . "$CASE_ROOT/update_state.sh" || exit 2
    . "$CASE_ROOT/update_abort.sh" || exit 2
    . "$CASE_ROOT/update_signal.sh" || exit 2
    . "$CASE_ROOT/update_cleanup.sh" || exit 2
    UPDATE_MAINTENANCE_LOCK="$CASE_ROOT/maintenance.lock"
    UPDATE_MAINTENANCE_LOCK_OWNED=1
    UPDATE_MAINTENANCE_LOCK_NONCE=update-owner
    UPDATE_SIGNAL_HANDLING=0
    UPDATE_PRESERVE_TMP=0
    UPDATE_PRESERVE_JFFS=1
    UPDATE_POOL_ABORT_FAILED=0
    UPDATE_RECOVERY_REQUIRED=0
    UPDATE_ACTIVATION_STARTED=0
    UPDATE_JFFS_STAGE=""
    UPDATE_JFFS_OLD=""
    TMP_BASE="$CASE_ROOT/update-temp"
    mkdir -p "$TMP_BASE"
    : > "$TMP_BASE/marker"
    trap 'handle_update_signal 143' TERM
    _caller_cleanup=cleanup_tmp
    ;;
  *) exit 2 ;;
esac

driver_cleanup() {
  _driver_cleanup_rc=$?
  return_status() { return "$1"; }
  return_status "$_driver_cleanup_rc"
  "$_caller_cleanup"
  _caller_cleanup_rc=$?
  [ "$_caller_cleanup_rc" -eq 0 ] || _driver_cleanup_rc="$_caller_cleanup_rc"
  return "$_driver_cleanup_rc"
}
trap driver_cleanup EXIT

: > "$CASE_ROOT/driver-ready"
mnj_pool_run "$FAKE_POOL_ROOT" push 3 60 "$CASE_ROOT/nodes" fake_worker
_pool_rc=$?
printf 'driver-pool-rc=%s\n' "$_pool_rc" >> "$FAKE_TRACE"
exit "$_pool_rc"
DRIVER
  chmod 700 "$_md_case_root/driver.sh" || return 1
  printf '1 192.0.2.1\n2 192.0.2.2\n3 192.0.2.3\n' > "$_md_case_root/nodes" || return 1
  ( CASE_ROOT="$_md_case_root" CASE_NAME="$_md_case" sh "$_md_case_root/driver.sh" ) > "$_md_case_root/stdout" 2>&1 &
  _md_pid=$!
  _md_wait=0
  while [ ! -e "$_md_case_root/driver-ready" ] && [ "$_md_wait" -lt 50 ]; do
    sleep 0.1
    _md_wait=$((_md_wait + 1))
  done
  [ -e "$_md_case_root/driver-ready" ] || { cat "$_md_case_root/stdout" >&2; kill "$_md_pid" 2>/dev/null || :; wait "$_md_pid" 2>/dev/null || :; return 1; }
  _md_wait=0
  while [ "$(grep -c '^worker-start$' "$_md_case_root/trace" 2>/dev/null || printf 0)" -lt 3 ] && [ "$_md_wait" -lt 50 ]; do
    sleep 0.1
    _md_wait=$((_md_wait + 1))
  done
  [ "$(grep -c '^worker-start$' "$_md_case_root/trace" 2>/dev/null || printf 0)" -ge 3 ] || {
    cat "$_md_case_root/trace" >&2; kill -TERM "$_md_pid" 2>/dev/null || :; wait "$_md_pid" 2>/dev/null || :; return 1;
  }
  kill -TERM "$_md_pid" 2>/dev/null || :
  wait "$_md_pid" 2>/dev/null
  _md_rc=$?
  # Signal-driven drivers must terminate nonzero; cleanup itself may preserve
  # that original signal status even when all workers reconcile successfully.
  [ "$_md_rc" -ne 0 ] || { cat "$_md_case_root/stdout" >&2; return 1; }
  [ -f "$_md_case_root/trace" ] || { cat "$_md_case_root/stdout" >&2; return 1; }
  [ "$(grep -c '^worker-term$' "$_md_case_root/trace")" -ge 3 ] || { cat "$_md_case_root/trace" >&2; return 1; }
  grep -q '^lock-release$' "$_md_case_root/trace" || return 1
  ! grep -q 'before-worker-stop' "$_md_case_root/trace" || return 1
  awk '/lock-release$|action-release$/{released=1} released && /worker-mutating/{bad=1} END{exit bad+0}' "$_md_case_root/trace" || return 1
  if [ "$_md_case" = observation ]; then
    :
  elif [ "$_md_case" = meta ]; then
    grep -q '^action-release$' "$_md_case_root/trace" || return 1
  elif [ "$_md_case" = backup ]; then
    [ ! -e "$_md_case_root/mb-work/marker" ] || return 1
  else
    [ ! -e "$_md_case_root/update-temp/marker" ] || return 1
  fi
  printf 'PASS %s parent-term cleanup\n' "$_md_case"
  return 0
}

if [ -n "${C2_ONLY:-}" ]; then
  make_driver "$C2_ONLY" || fail "$C2_ONLY driver preparation failed"
  exit 0
fi
for _c2_case in observation meta backup update; do
  C2_ONLY="$_c2_case" sh "$BASE_DIR/dev-tools/tests/local/mac_push_parent_term_cleanup_contract_test.sh" || exit 1
done
printf 'MAC_PUSH_PARENT_TERM_CLEANUP_CONTRACT_OK\n'
