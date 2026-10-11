#!/bin/sh
# File: mervlan_node_runner.sh || version="0.72.0"
# Structured, detached node-manager runner.  Status files are untrusted input
# to callers and are always parsed, never sourced.

MNR_REQUEST_BASE=${MERV_BASE:-/jffs/addons/mervlan}
unset LIB_SELFTEST_CONTEXT_LOADED
if [ -n "${MERVLAN_SELFTEST_CONTEXT:-}" ] &&
   [ -r "$MNR_REQUEST_BASE/settings/lib_selftest_context.sh" ]; then
  . "$MNR_REQUEST_BASE/settings/lib_selftest_context.sh" 2>/dev/null || :
fi
if type merv_selftest_context_valid >/dev/null 2>&1 &&
   merv_selftest_context_valid; then
  MERV_BASE=$MNR_REQUEST_BASE
else
  MERV_BASE=/jffs/addons/mervlan
  unset MERV_ACTION_LOCK_PATH MERV_ACTION_LOCK_PROC_ROOT MERV_OWNER_LOCK_PROC_ROOT \
    MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID MERV_ACTION_LOCK_PARENT_START \
    MERV_ACTION_LOCK_PARENT_NONCE MERV_CONTINUATION_TOKEN MERV_NODE_RUNNER_MANAGER
  unset MERV_NODE_RUNNER_SELFTEST_CHECKPOINT MERV_NODE_RUNNER_SELFTEST_PAUSE_FILE \
    MERV_NODE_RUNNER_SELFTEST_RELEASE_FILE
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" || exit 2
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_owner_lock.sh" || exit 2
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_lock.sh" || exit 2
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" || exit 2
[ -n "${LIB_MUTATION_ADMISSION_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mutation_admission.sh" || exit 2
[ -n "${LIB_MAINTENANCE_QUIESCE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_maintenance_quiesce.sh" || exit 2

MNR_ACTION="${1:-}"
MNR_RUN_ID="${2:-}"
MNR_NODE_ID="${3:-}"
MNR_PUBLISH_SEQ=0
MNR_FINAL=0
MNR_CHILD_PID=""
MNR_CHILD_START=""
MNR_STARTED_EPOCH=""
MNR_MANAGER="$MERV_BASE/functions/mervlan_manager.sh"
MNR_ACTION_LOCK=/tmp/mervlan_tmp/locks/mervlan_action.lock
MNR_ROOT=$MERV_NODE_STATUS_ROOT
MNR_LOCK_OWNED=0
MNR_PARENT_PID=
MNR_PARENT_START=
MNR_PARENT_NONCE=
MNR_PENDING_FILE=
MNR_RUNNER_PID=
MNR_RUNNER_START=
MNR_MANAGER_PID=none
MNR_MANAGER_START=none
MNR_STATUS_FORMAT=2
MNR_Q_FAILED=0
MNR_DRAINING=0

if type merv_selftest_context_valid >/dev/null 2>&1 && merv_selftest_context_valid; then
  if merv_selftest_context_path_allowed "${MERV_ACTION_LOCK_PATH:-}"; then
    MNR_ACTION_LOCK=$MERV_ACTION_LOCK_PATH
  fi
  if merv_selftest_context_path_allowed "${MERV_NODE_RUNNER_MANAGER:-}"; then
    MNR_MANAGER=$MERV_NODE_RUNNER_MANAGER
  fi
else
  MNR_MANAGER=$MERV_BASE/functions/mervlan_manager.sh
  unset MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID \
    MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE \
    MERV_CONTINUATION_TOKEN MERV_NODE_RUNNER_MANAGER
fi

mnr_valid_run_id() {
  case "$1" in
    [0-9]*-[0-9]*) ;;
    *) return 1 ;;
  esac
  _mnr_left=${1%-*}
  _mnr_right=${1#*-}
  case "$_mnr_left:$_mnr_right" in *[!0-9:]*|*:|:*) return 1 ;; esac
  return 0
}

mnr_valid_reason() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# Deterministic process checkpoints for the authenticated local lifecycle
# harness. Arbitrary inherited TEST_RUN or paths cannot pause production work.
mnr_test_checkpoint() {
  _mntc_point=${1:-}
  [ "${MERV_NODE_RUNNER_SELFTEST_CHECKPOINT:-}" = "$_mntc_point" ] || return 0
  type merv_selftest_context_valid >/dev/null 2>&1 &&
    merv_selftest_context_valid || return 0
  _mntc_pause=${MERV_NODE_RUNNER_SELFTEST_PAUSE_FILE:-}
  _mntc_release=${MERV_NODE_RUNNER_SELFTEST_RELEASE_FILE:-}
  merv_selftest_context_path_allowed "$_mntc_pause" &&
    merv_selftest_context_path_allowed "$_mntc_release" || return 1
  [ ! -e "$_mntc_pause" ] && [ ! -L "$_mntc_pause" ] || return 1
  ( umask 077; : > "$_mntc_pause" ) || return 1
  while [ ! -e "$_mntc_release" ]; do
    [ ! -L "$_mntc_release" ] || return 1
    sleep 1
  done
  [ ! -L "$_mntc_release" ]
}

mnr_valid_status_root() {
  case "${MERV_NODE_STATUS_ROOT:-}" in
    "$RESULTDIR/node_runs"|/tmp/mervlan_tmp/selftest.*/*) ;;
    *) return 1 ;;
  esac
  case "$MERV_NODE_STATUS_ROOT" in
    *..*|*[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  return 0
}

mnr_init_paths() {
  mnr_valid_run_id "$MNR_RUN_ID" || return 1
  merv_is_valid_node_id "$MNR_NODE_ID" || return 1
  mnr_valid_status_root || return 1
  MNR_RUN_DIR="$MERV_NODE_STATUS_ROOT/$MNR_RUN_ID"
  MNR_STATUS_FILE="$MNR_RUN_DIR/node_$MNR_NODE_ID.status"
  MNR_PENDING_FILE="$MNR_RUN_DIR/node_$MNR_NODE_ID.pending"
  return 0
}

mnr_action_enter_admit() {
  unset MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID \
    MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE
  merv_action_lock_enter "$MNR_ACTION_LOCK" self || return 1
  [ "${MERV_ACTION_LOCK_MODE:-none}" = self ] || return 1
  MNR_LOCK_OWNED=1
  MNR_ACTION_NONCE=$MERV_ACTION_LOCK_NONCE
  MNR_ACTION_START=$MERV_ACTION_LOCK_START
  merv_mutation_admit_action "$MNR_ACTION_LOCK"
}

mnr_action_leave() {
  [ "$MNR_LOCK_OWNED" = 1 ] || return 0
  merv_action_lock_leave "$MNR_ACTION_LOCK" "$MNR_ACTION_NONCE" "$MNR_ACTION_START" self || return 1
  MNR_LOCK_OWNED=0
}

mnr_pending_write() {
  _mnp_pid=$1
  _mnp_start=$2
  case "$_mnp_pid:$_mnp_start" in
    none:none) ;;
    *[!0-9:]*|:*|*::*) return 1 ;;
  esac
  if [ -e "$MNR_PENDING_FILE" ] || [ -L "$MNR_PENDING_FILE" ]; then
    mnr_pending_validate "$MNR_PENDING_FILE" || return 1
    _mnp_old_parent=$(sed -n 's/^parent_pid=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    _mnp_old_start=$(sed -n 's/^parent_proc_start_time=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    _mnp_old_nonce=$(sed -n 's/^parent_nonce=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    _mnp_old_pid=$(sed -n 's/^runner_pid=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    _mnp_old_child_start=$(sed -n 's/^runner_proc_start_time=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    [ "$_mnp_old_parent" = "$MNR_PARENT_PID" ] &&
      [ "$_mnp_old_start" = "$MNR_PARENT_START" ] &&
      [ "$_mnp_old_nonce" = "$MNR_PARENT_NONCE" ] &&
      [ "$_mnp_old_pid:$_mnp_old_child_start" = none:none ] || return 1
  else
    [ "$_mnp_pid:$_mnp_start" = none:none ] || return 1
  fi
  _mnp_tmp="$MNR_RUN_DIR/.node_$MNR_NODE_ID.pending.$$.${MNR_PUBLISH_SEQ:-0}"
  MNR_PUBLISH_SEQ=$(( ${MNR_PUBLISH_SEQ:-0} + 1 ))
  [ ! -e "$_mnp_tmp" ] && [ ! -L "$_mnp_tmp" ] || return 1
  ( umask 077
    printf 'format_version=1\nrun_id=%s\nnode_id=%s\nstate=pending\nparent_pid=%s\nparent_proc_start_time=%s\nparent_nonce=%s\nrunner_pid=%s\nrunner_proc_start_time=%s\n' \
      "$MNR_RUN_ID" "$MNR_NODE_ID" "$MNR_PARENT_PID" "$MNR_PARENT_START" \
      "$MNR_PARENT_NONCE" "$_mnp_pid" "$_mnp_start" > "$_mnp_tmp"
  ) || { rm -f "$_mnp_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_mnp_tmp" 2>/dev/null || { rm -f "$_mnp_tmp"; return 1; }
  mv -f "$_mnp_tmp" "$MNR_PENDING_FILE" 2>/dev/null || { rm -f "$_mnp_tmp"; return 1; }
  mnr_pending_validate "$MNR_PENDING_FILE"
}

mnr_pending_validate() {
  _mnp_file=$1
  [ ! -L "$_mnp_file" ] && [ -f "$_mnp_file" ] && [ -r "$_mnp_file" ] || return 1
  [ "$(LC_ALL=C ls -ldn "$_mnp_file" 2>/dev/null | awk 'NR == 1 {print $1}')" = -rw------- ] || return 1
  awk -F= -v run="$MNR_RUN_ID" -v node="$MNR_NODE_ID" '
    BEGIN { split("format_version run_id node_id state parent_pid parent_proc_start_time parent_nonce runner_pid runner_proc_start_time", k, " "); for(i in k) a[k[i]]=1; want=9 }
    { if(NF != 2 || !($1 in a) || seen[$1]++) exit 2; v[$1]=$2; n++ }
    END {
      if(n != want) exit 2
      for(x in a) if(seen[x] != 1) exit 2
      if(v["format_version"] != "1" || v["run_id"] != run || v["node_id"] != node || v["state"] != "pending") exit 2
      if(v["parent_pid"] !~ /^[1-9][0-9]*$/ || v["parent_proc_start_time"] !~ /^[1-9][0-9]*$/ || v["parent_nonce"] !~ /^[A-Za-z0-9._:-]+$/) exit 2
      if((v["runner_pid"] == "none") != (v["runner_proc_start_time"] == "none")) exit 2
      if(v["runner_pid"] != "none" && (v["runner_pid"] !~ /^[1-9][0-9]*$/ || v["runner_proc_start_time"] !~ /^[1-9][0-9]*$/)) exit 2
    }' "$_mnp_file" >/dev/null 2>&1 || return 1
}

mnr_now() {
  _mnr_now=$(date +%s 2>/dev/null || printf '')
  case "$_mnr_now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$_mnr_now"
}

# mnr_status_validate_file <file> <run-id> <node-id>
mnr_status_validate_file() {
  _mnr_file="$1"
  _mnr_expected_run="$2"
  _mnr_expected_node="$3"
  [ ! -L "$_mnr_file" ] && [ -f "$_mnr_file" ] && [ -r "$_mnr_file" ] || return 1
  [ "$(LC_ALL=C ls -ldn "$_mnr_file" 2>/dev/null | awk 'NR == 1 {print $1}')" = -rw------- ] || return 1
  MNR_STATUS_FORMAT=""; MNR_STATUS_RUN=""; MNR_STATUS_NODE=""
  MNR_STATUS_STATE=""; MNR_STATUS_PID=""; MNR_STATUS_START=""
  MNR_STATUS_STARTED=""; MNR_STATUS_COMPLETED=""; MNR_STATUS_EXIT=""
  MNR_STATUS_REASON=""; MNR_STATUS_PARENT_PID=none; MNR_STATUS_PARENT_START=none
  MNR_STATUS_MANAGER_PID=none; MNR_STATUS_MANAGER_START=none
  _mnr_format=$(sed -n 's/^format_version=//p' "$_mnr_file" 2>/dev/null)
  if [ "$_mnr_format" = 2 ]; then
    awk -F= -v er="$_mnr_expected_run" -v en="$_mnr_expected_node" '
      BEGIN { split("format_version run_id node_id state pid proc_start_time parent_pid parent_proc_start_time manager_pid manager_proc_start_time started_epoch completed_epoch exit_code reason",k," "); for(i in k) a[k[i]]=1; want=14 }
      { if(NF != 2 || !($1 in a) || seen[$1]++) exit 2; v[$1]=$2; n++ }
      END {
        if(n != want) exit 2
        for(x in a) if(seen[x] != 1) exit 2
        if(v["format_version"] != "2" || v["run_id"] != er || v["node_id"] != en || v["node_id"] !~ /^(10|[1-9])$/) exit 2
        if(v["pid"] !~ /^[1-9][0-9]*$/ || v["proc_start_time"] !~ /^[1-9][0-9]*$/ ||
           v["parent_pid"] !~ /^[1-9][0-9]*$/ || v["parent_proc_start_time"] !~ /^[1-9][0-9]*$/ ||
           v["started_epoch"] !~ /^[1-9][0-9]*$/ || v["completed_epoch"] !~ /^(0|[1-9][0-9]*)$/) exit 2
        if((v["manager_pid"] == "none") != (v["manager_proc_start_time"] == "none")) exit 2
        if(v["manager_pid"] != "none" && (v["manager_pid"] !~ /^[1-9][0-9]*$/ || v["manager_proc_start_time"] !~ /^[1-9][0-9]*$/)) exit 2
        if(v["reason"] !~ /^[A-Za-z0-9._-]+$/ || length(v["reason"]) > 160) exit 2
        if(v["state"] == "pending") {
          if(v["pid"] != "none" || v["proc_start_time"] != "none" || v["manager_pid"] != "none" ||
             v["started_epoch"] != "0" || v["completed_epoch"] != "0" || v["exit_code"] != "" || v["reason"] != "pending") exit 2
        } else if(v["state"] == "started") {
          if(v["started_epoch"] !~ /^[1-9][0-9]*$/ || v["completed_epoch"] != "0" || v["exit_code"] != "") exit 2
        } else if(v["state"] == "complete") {
          if(v["exit_code"] != "0" || v["completed_epoch"] + 0 < v["started_epoch"] + 0) exit 2
        } else if(v["state"] == "failed") {
          if(v["exit_code"] !~ /^[1-9][0-9]*$/ || v["completed_epoch"] + 0 < v["started_epoch"] + 0) exit 2
        } else exit 2
      }' "$_mnr_file" >/dev/null 2>&1 || return 1
    MNR_STATUS_FORMAT=2
    MNR_STATUS_RUN=$(sed -n 's/^run_id=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_NODE=$(sed -n 's/^node_id=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_STATE=$(sed -n 's/^state=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_PID=$(sed -n 's/^pid=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_START=$(sed -n 's/^proc_start_time=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_PARENT_PID=$(sed -n 's/^parent_pid=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_PARENT_START=$(sed -n 's/^parent_proc_start_time=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_MANAGER_PID=$(sed -n 's/^manager_pid=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_MANAGER_START=$(sed -n 's/^manager_proc_start_time=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_STARTED=$(sed -n 's/^started_epoch=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_COMPLETED=$(sed -n 's/^completed_epoch=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_EXIT=$(sed -n 's/^exit_code=//p' "$_mnr_file" 2>/dev/null)
    MNR_STATUS_REASON=$(sed -n 's/^reason=//p' "$_mnr_file" 2>/dev/null)
    return 0
  fi
  [ "$_mnr_format" = 1 ] || return 1
  _mnr_seen_format=0; _mnr_seen_run=0; _mnr_seen_node=0; _mnr_seen_state=0
  _mnr_seen_pid=0; _mnr_seen_start=0; _mnr_seen_started=0; _mnr_seen_completed=0
  _mnr_seen_exit=0; _mnr_seen_reason=0
  while IFS= read -r _mnr_line || [ -n "$_mnr_line" ]; do
    case "$_mnr_line" in *=*) _mnr_key=${_mnr_line%%=*}; _mnr_value=${_mnr_line#*=} ;; *) return 1 ;; esac
    case "$_mnr_key" in
      format_version) [ "$_mnr_seen_format" -eq 0 ] || return 1; _mnr_seen_format=1; MNR_STATUS_FORMAT=$_mnr_value ;;
      run_id) [ "$_mnr_seen_run" -eq 0 ] || return 1; _mnr_seen_run=1; MNR_STATUS_RUN=$_mnr_value ;;
      node_id) [ "$_mnr_seen_node" -eq 0 ] || return 1; _mnr_seen_node=1; MNR_STATUS_NODE=$_mnr_value ;;
      state) [ "$_mnr_seen_state" -eq 0 ] || return 1; _mnr_seen_state=1; MNR_STATUS_STATE=$_mnr_value ;;
      pid) [ "$_mnr_seen_pid" -eq 0 ] || return 1; _mnr_seen_pid=1; MNR_STATUS_PID=$_mnr_value ;;
      proc_start_time) [ "$_mnr_seen_start" -eq 0 ] || return 1; _mnr_seen_start=1; MNR_STATUS_START=$_mnr_value ;;
      started_epoch) [ "$_mnr_seen_started" -eq 0 ] || return 1; _mnr_seen_started=1; MNR_STATUS_STARTED=$_mnr_value ;;
      completed_epoch) [ "$_mnr_seen_completed" -eq 0 ] || return 1; _mnr_seen_completed=1; MNR_STATUS_COMPLETED=$_mnr_value ;;
      exit_code) [ "$_mnr_seen_exit" -eq 0 ] || return 1; _mnr_seen_exit=1; MNR_STATUS_EXIT=$_mnr_value ;;
      reason) [ "$_mnr_seen_reason" -eq 0 ] || return 1; _mnr_seen_reason=1; MNR_STATUS_REASON=$_mnr_value ;;
      *) return 1 ;;
    esac
  done < "$_mnr_file"
  [ "$_mnr_seen_format$_mnr_seen_run$_mnr_seen_node$_mnr_seen_state$_mnr_seen_pid$_mnr_seen_start$_mnr_seen_started$_mnr_seen_completed$_mnr_seen_exit$_mnr_seen_reason" = 1111111111 ] || return 1
  [ "$MNR_STATUS_FORMAT" = 1 ] && mnr_valid_run_id "$MNR_STATUS_RUN" &&
    [ "$MNR_STATUS_RUN" = "$_mnr_expected_run" ] && merv_is_valid_node_id "$MNR_STATUS_NODE" &&
    [ "$MNR_STATUS_NODE" = "$_mnr_expected_node" ] || return 1
  case "$MNR_STATUS_PID:$MNR_STATUS_START:$MNR_STATUS_STARTED:$MNR_STATUS_COMPLETED" in
    *[!0-9:]*|:*|*::*) return 1 ;;
  esac
  mnr_valid_reason "$MNR_STATUS_REASON" || return 1
  case "$MNR_STATUS_STATE" in
    started) [ "$MNR_STATUS_COMPLETED" = 0 ] && [ -z "$MNR_STATUS_EXIT" ] ;;
    complete) [ "$MNR_STATUS_COMPLETED" -ge "$MNR_STATUS_STARTED" ] 2>/dev/null && [ "$MNR_STATUS_EXIT" = 0 ] ;;
    failed) case "$MNR_STATUS_EXIT" in ''|*[!0-9]*) false ;; *) [ "$MNR_STATUS_EXIT" -ne 0 ] 2>/dev/null && [ "$MNR_STATUS_COMPLETED" -ge "$MNR_STATUS_STARTED" ] 2>/dev/null ;; esac ;;
    *) false ;;
  esac
}

# Remove only complete, validated, old run directories.  BusyBox find differs
# across firmware builds, so enumerate direct children and validate every path
# before removing exact known runner artifacts.  Unknown files make rmdir fail
# and preserve the directory for inspection.
mnr_prune_old_runs() {
  mnr_valid_status_root || return 1
  case "${MERV_NODE_STATUS_RETENTION_SEC:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$MERV_NODE_STATUS_RETENTION_SEC" -gt 0 ] 2>/dev/null || return 0
  _mnr_prune_now=$(mnr_now) || return 1
  _mnr_prune_cutoff=$((_mnr_prune_now - MERV_NODE_STATUS_RETENTION_SEC))
  for _mnr_prune_dir in "$MERV_NODE_STATUS_ROOT"/*; do
    [ -d "$_mnr_prune_dir" ] || continue
    _mnr_prune_run=${_mnr_prune_dir##*/}
    mnr_valid_run_id "$_mnr_prune_run" || continue
    [ "$_mnr_prune_dir" = "$MERV_NODE_STATUS_ROOT/$_mnr_prune_run" ] || continue
    [ "$_mnr_prune_dir" = "$MNR_RUN_DIR" ] && continue
    _mnr_prune_status="$_mnr_prune_dir/node_$MNR_NODE_ID.status"
    mnr_status_validate_file "$_mnr_prune_status" "$_mnr_prune_run" "$MNR_NODE_ID" || continue
    case "$MNR_STATUS_STATE" in complete|failed) ;; *) continue ;; esac
    [ "$MNR_STATUS_COMPLETED" -le "$_mnr_prune_cutoff" ] 2>/dev/null || continue
    rm -f "$_mnr_prune_status" "$_mnr_prune_dir/cli.log" \
      "$_mnr_prune_dir/vlan.log" "$_mnr_prune_dir/stdout.log" \
      "$_mnr_prune_dir/runner.log" 2>/dev/null || continue
    rmdir "$_mnr_prune_dir/ssh" 2>/dev/null || :
    rmdir "$_mnr_prune_dir" 2>/dev/null || :
  done
  return 0
}

mnr_publish() {
  _mnr_state="$1"
  _mnr_exit="$2"
  _mnr_reason="$3"
  mnr_valid_reason "$_mnr_reason" || return 1
  [ -n "$MNR_STARTED_EPOCH" ] || return 1
  mkdir -p "$MNR_RUN_DIR" 2>/dev/null || return 1
  MNR_PUBLISH_SEQ=$((MNR_PUBLISH_SEQ + 1))
  _mnr_tmp="$MNR_RUN_DIR/.node_$MNR_NODE_ID.status.$$.${MNR_PUBLISH_SEQ}"
  umask 077
  if [ "$MNR_STATUS_FORMAT" = 1 ]; then
    [ -n "$MNR_CHILD_PID" ] && [ -n "$MNR_CHILD_START" ] || return 1
    {
      printf 'format_version=1\nrun_id=%s\nnode_id=%s\nstate=%s\npid=%s\nproc_start_time=%s\nstarted_epoch=%s\n' \
        "$MNR_RUN_ID" "$MNR_NODE_ID" "$_mnr_state" "$MNR_CHILD_PID" "$MNR_CHILD_START" "$MNR_STARTED_EPOCH"
      case "$_mnr_state" in
        started) printf 'completed_epoch=0\nexit_code=\nreason=%s\n' "$_mnr_reason" ;;
        complete|failed) _mnr_done=$(mnr_now) || exit 1; printf 'completed_epoch=%s\nexit_code=%s\nreason=%s\n' "$_mnr_done" "$_mnr_exit" "$_mnr_reason" ;;
        *) exit 1 ;;
      esac
    } > "$_mnr_tmp" 2>/dev/null || { rm -f "$_mnr_tmp" 2>/dev/null || :; return 1; }
  else
    [ -n "$MNR_RUNNER_PID" ] && [ -n "$MNR_RUNNER_START" ] &&
      [ -n "$MNR_PARENT_PID" ] && [ -n "$MNR_PARENT_START" ] || return 1
    {
      printf 'format_version=2\nrun_id=%s\nnode_id=%s\nstate=%s\npid=%s\nproc_start_time=%s\nparent_pid=%s\nparent_proc_start_time=%s\nmanager_pid=%s\nmanager_proc_start_time=%s\nstarted_epoch=%s\n' \
        "$MNR_RUN_ID" "$MNR_NODE_ID" "$_mnr_state" "$MNR_RUNNER_PID" "$MNR_RUNNER_START" \
        "$MNR_PARENT_PID" "$MNR_PARENT_START" "${MNR_MANAGER_PID:-none}" \
        "${MNR_MANAGER_START:-none}" "$MNR_STARTED_EPOCH"
      case "$_mnr_state" in
        started) printf 'completed_epoch=0\nexit_code=\nreason=%s\n' "$_mnr_reason" ;;
        complete|failed) _mnr_done=$(mnr_now) || exit 1; printf 'completed_epoch=%s\nexit_code=%s\nreason=%s\n' "$_mnr_done" "$_mnr_exit" "$_mnr_reason" ;;
        *) exit 1 ;;
      esac
    } > "$_mnr_tmp" 2>/dev/null || { rm -f "$_mnr_tmp" 2>/dev/null || :; return 1; }
  fi
  mnr_status_validate_file "$_mnr_tmp" "$MNR_RUN_ID" "$MNR_NODE_ID" || { rm -f "$_mnr_tmp" 2>/dev/null || :; return 1; }
  mv "$_mnr_tmp" "$MNR_STATUS_FILE" 2>/dev/null || { rm -f "$_mnr_tmp" 2>/dev/null || :; return 1; }
  case "$_mnr_state" in complete|failed) MNR_FINAL=1 ;; esac
  return 0
}

mnr_stop_child() {
  [ -n "${MNR_MANAGER_PID:-}" ] && [ "$MNR_MANAGER_PID" != none ] &&
    [ -n "${MNR_MANAGER_START:-}" ] || return 0
  if merv_process_identity_matches "$MNR_MANAGER_PID" "$MNR_MANAGER_START"; then
    kill -TERM "$MNR_MANAGER_PID" 2>/dev/null || :
    sleep 1
    merv_process_identity_matches "$MNR_MANAGER_PID" "$MNR_MANAGER_START" && kill -KILL "$MNR_MANAGER_PID" 2>/dev/null || :
  fi
  [ -n "${MNR_CHILD_PID:-}" ] && wait "$MNR_CHILD_PID" 2>/dev/null || :
}

# A signal can arrive after the runner atomically published `started` but
# before it removed the matching `pending` record. Retire only that exact
# transition after both records authenticate this runner's PID/start pair.
mnr_pending_retire_after_started() {
  _mpras_start=$(merv_identity_current_start /proc 2>/dev/null) || return 1
  mnr_status_validate_file "$MNR_STATUS_FILE" "$MNR_RUN_ID" "$MNR_NODE_ID" || return 1
  [ "$MNR_STATUS_STATE" = started ] && [ "$MNR_STATUS_PID" = "$$" ] &&
    [ "$MNR_STATUS_START" = "$_mpras_start" ] || return 1
  if [ -e "$MNR_PENDING_FILE" ] || [ -L "$MNR_PENDING_FILE" ]; then
    mnr_pending_validate "$MNR_PENDING_FILE" || return 1
    _mpras_pid=$(sed -n 's/^runner_pid=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    _mpras_bound_start=$(sed -n 's/^runner_proc_start_time=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    [ "$_mpras_pid" = "$$" ] && [ "$_mpras_bound_start" = "$_mpras_start" ] || return 1
    rm -f "$MNR_PENDING_FILE" 2>/dev/null || return 1
  fi
  return 0
}

mnr_run_exit() {
  _mnr_rc=$?
  [ "$MNR_FINAL" -eq 1 ] && return 0
  mnr_stop_child
  mnr_action_leave >/dev/null 2>&1 || :
  [ -n "$MNR_STARTED_EPOCH" ] || return 0
  [ "$MNR_Q_FAILED" = 1 ] && return 0
  if [ -n "${MNR_CHILD_PID:-}" ] && [ -n "${MNR_CHILD_START:-}" ] &&
     merv_process_identity_matches "$MNR_CHILD_PID" "$MNR_CHILD_START"; then
    return 0
  fi
  mnr_pending_retire_after_started || return 0
  # An unexpected runner exit may follow a manager that published detached
  # observation/reconciliation work. Keep the run nonterminal until Q proves
  # those continuation states are terminal; ambiguity leaves started.
  mnr_wait_mutation_descendants || { MNR_Q_FAILED=1; return 0; }
  mnr_publish failed "${_mnr_rc:-1}" runner-exit || :
}

mnr_run_term() {
  mnr_stop_child
  mnr_action_leave >/dev/null 2>&1 || :
  if [ "$MNR_DRAINING" = 1 ]; then
    MNR_Q_FAILED=1
    MNR_FINAL=1
    exit 143
  fi
  if [ -n "$MNR_STARTED_EPOCH" ]; then
    mnr_pending_retire_after_started || {
      MNR_Q_FAILED=1
      MNR_FINAL=1
      exit 143
    }
    mnr_wait_mutation_descendants || {
      MNR_Q_FAILED=1
      MNR_FINAL=1
      exit 143
    }
  fi
  mnr_publish failed 143 runner-terminated || :
  MNR_FINAL=1
  exit 143
}

# Wait for Q-visible workers started by the manager while this run remains in
# its started state. When Full has already acquired M then F, pass those exact
# same-process tuples as Q's expected owners so its fence does not deadlock the
# worker that Full is draining. Any unrelated maintenance owner remains busy.
mnr_wait_mutation_descendants() {
  MNR_DRAINING=1
  while :; do
    _mnw_mpid= _mnw_mstart= _mnw_mnonce= _mnw_fpid= _mnw_fstart= _mnw_fnonce=
    _mnw_mlock=$(merv_update_maintenance_lock_path 2>/dev/null || printf '')
    _mnw_fence=$(merv_full_fence_path 2>/dev/null || printf '')
    if [ "$(merv_update_maintenance_lock_state 2>/dev/null)" = live ] &&
       [ -n "$_mnw_mlock" ] &&
       merv_owner_v2_read "$_mnw_mlock/owner" 2>/dev/null; then
      _mnw_mpid=$MERV_OWNER_V2_PID
      _mnw_mstart=$MERV_OWNER_V2_PROC_START_TIME
      _mnw_mnonce=$MERV_OWNER_V2_NONCE
    fi
    if [ "$(merv_full_fence_classify "$_mnw_fence" 2>/dev/null)" = live ] &&
       merv_owner_v2_read "$_mnw_fence/owner" 2>/dev/null &&
       merv_full_fence_owner_is "$_mnw_fence" \
         "$MERV_OWNER_V2_PID" "$MERV_OWNER_V2_PROC_START_TIME" "$MERV_OWNER_V2_NONCE"; then
      _mnw_fpid=$MERV_OWNER_V2_PID
      _mnw_fstart=$MERV_OWNER_V2_PROC_START_TIME
      _mnw_fnonce=$MERV_OWNER_V2_NONCE
    fi
    merv_maintenance_quiesce_classify \
      "$_mnw_mpid" "$_mnw_mstart" "$_mnw_mnonce" \
      "$_mnw_fpid" "$_mnw_fstart" "$_mnw_fnonce" \
      "" "$MNR_RUN_ID:$MNR_NODE_ID" >/dev/null 2>&1 || :
    case "${MERV_QUIESCE_STATUS:-BLOCKING}" in
      IDLE) MNR_DRAINING=0; return 0 ;;
      BUSY) sleep 1 ;;
      *) MNR_Q_FAILED=1; return 75 ;;
    esac
  done
}

mnr_run() {
  mnr_init_paths || return 2
  _mnr_bind_tries=0
  while :; do
    mnr_pending_validate "$MNR_PENDING_FILE" || return 2
    _mnr_bound_pid=$(sed -n 's/^runner_pid=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    _mnr_bound_start=$(sed -n 's/^runner_proc_start_time=//p' "$MNR_PENDING_FILE" 2>/dev/null)
    [ "$_mnr_bound_pid" != none ] && [ "$_mnr_bound_start" != none ] && break
    [ "$_mnr_bind_tries" -lt 10 ] || return 2
    sleep 1
    _mnr_bind_tries=$((_mnr_bind_tries + 1))
  done
  MNR_PARENT_PID=$(sed -n 's/^parent_pid=//p' "$MNR_PENDING_FILE" 2>/dev/null)
  MNR_PARENT_START=$(sed -n 's/^parent_proc_start_time=//p' "$MNR_PENDING_FILE" 2>/dev/null)
  MNR_PARENT_NONCE=$(sed -n 's/^parent_nonce=//p' "$MNR_PENDING_FILE" 2>/dev/null)
  [ "$_mnr_bound_pid" = "$$" ] || return 2
  MNR_CHILD_PID=$$
  MNR_CHILD_START=$(merv_identity_current_start /proc 2>/dev/null) || return 2
  MNR_RUNNER_PID=$MNR_CHILD_PID
  MNR_RUNNER_START=$MNR_CHILD_START
  [ "$MNR_CHILD_START" = "$_mnr_bound_start" ] || return 2
  merv_owner_v2_matches "$MNR_ACTION_LOCK" "$MNR_PARENT_PID" \
    "$MNR_PARENT_START" "$MNR_PARENT_NONCE" /proc || return 2
  mnr_test_checkpoint bound-before-started || return 2
  # Parent death after identity binding leaves the pending record authoritative;
  # do not let this child proceed into mutation on a stale parent proof.
  merv_owner_v2_matches "$MNR_ACTION_LOCK" "$MNR_PARENT_PID" \
    "$MNR_PARENT_START" "$MNR_PARENT_NONCE" /proc || return 2
  [ ! -e "$MNR_STATUS_FILE" ] && [ ! -L "$MNR_STATUS_FILE" ] || return 2
  [ -f "$MNR_MANAGER" ] || return 2
  mkdir -p "$MNR_RUN_DIR" 2>/dev/null || return 2
  trap - EXIT INT TERM
  trap mnr_run_exit EXIT
  trap mnr_run_term INT TERM
  MNR_STARTED_EPOCH=$(mnr_now) || return 2
  MNR_STATUS_FORMAT=2
  MNR_MANAGER_PID=none
  MNR_MANAGER_START=none
  mnr_publish started '' runner-started || return 2
  mnr_status_validate_file "$MNR_STATUS_FILE" "$MNR_RUN_ID" "$MNR_NODE_ID" || return 2
  [ "$MNR_STATUS_PID" = "$$" ] && [ "$MNR_STATUS_START" = "$MNR_CHILD_START" ] || return 2
  rm -f "$MNR_PENDING_FILE" 2>/dev/null || return 2

  _mnr_lock_tries=0
  while ! mnr_action_enter_admit; do
    case "${MERV_MUTATION_ADMISSION_REASON:-}:${MERV_ACTION_LOCK_LAST_FAILURE:-}" in
      full-fence-*:*|maintenance-*:* )
        _mnr_done=$(mnr_now) || return 2
        mnr_action_leave || :
        mnr_publish failed 75 admission-refused || return 2
        MNR_FINAL=1
        return 75
        ;;
    esac
    [ "$_mnr_lock_tries" -lt 30 ] || return 2
    sleep 1
    _mnr_lock_tries=$((_mnr_lock_tries + 1))
  done
  merv_action_lock_export_child_context || { mnr_action_leave || :; return 2; }
  LOG_chan_cli="$MNR_RUN_DIR/cli.log"
  LOG_chan_vlan="$MNR_RUN_DIR/vlan.log"
  export LOG_chan_cli LOG_chan_vlan
  : > "$LOG_chan_cli" 2>/dev/null || return 2
  : > "$LOG_chan_vlan" 2>/dev/null || return 2
  : > "$MNR_RUN_DIR/stdout.log" 2>/dev/null || return 2
  MNR_STARTED_EPOCH=$(mnr_now) || return 2
  sh "$MNR_MANAGER" > "$MNR_RUN_DIR/stdout.log" 2>&1 &
  MNR_CHILD_PID=$!
  MNR_CHILD_START=$(merv_proc_start_time "$MNR_CHILD_PID" 2>/dev/null) || { mnr_stop_child; return 2; }
  MNR_MANAGER_PID=$MNR_CHILD_PID
  MNR_MANAGER_START=$MNR_CHILD_START
  mnr_publish started '' started || { mnr_stop_child; return 2; }
  wait "$MNR_CHILD_PID"
  _mnr_rc=$?
  MNR_CHILD_PID=
  mnr_action_leave || return 2
  mnr_wait_mutation_descendants || return 75
  if [ "$_mnr_rc" -eq 0 ]; then
    mnr_publish complete 0 manager-complete || return 2
    return 0
  fi
  mnr_publish failed "$_mnr_rc" manager-failed || return 2
  return "$_mnr_rc"
}

# Reconcile one detached manager by the authenticated PID/start identity in
# its canonical status record.  This command is intentionally narrow: it does
# not kill a process by PID alone and it never touches another run's marker.
mnr_cancel() {
  mnr_init_paths || return 2
  mnr_status_validate_file "$MNR_STATUS_FILE" "$MNR_RUN_ID" "$MNR_NODE_ID" || return 2
  case "$MNR_STATUS_STATE" in
    complete|failed) return 0 ;;
    started) ;;
    *) return 2 ;;
  esac
  _mnr_cancel_pid=$MNR_STATUS_PID
  _mnr_cancel_start=$MNR_STATUS_START
  if merv_process_identity_matches "$_mnr_cancel_pid" "$_mnr_cancel_start"; then
    kill -TERM "$_mnr_cancel_pid" 2>/dev/null || return 1
    _mnr_n=0
    while [ "$_mnr_n" -lt 10 ] && merv_process_identity_matches "$_mnr_cancel_pid" "$_mnr_cancel_start"; do
      sleep 1
      _mnr_n=$((_mnr_n + 1))
    done
    merv_process_identity_matches "$_mnr_cancel_pid" "$_mnr_cancel_start" && return 1
  fi
  # The runner alone may publish terminal after it has stopped its manager
  # and drained Q-visible descendants. A cancellation client must never
  # rewrite a still-started record merely because the runner PID disappeared:
  # its manager or a detached observation/reconciliation worker may survive.
  if mnr_status_validate_file "$MNR_STATUS_FILE" "$MNR_RUN_ID" "$MNR_NODE_ID" &&
     [ "$MNR_STATUS_STATE" = started ]; then
    return 1
  fi
  return 0
}

mnr_start() {
  mnr_init_paths || return 2
  mnr_action_enter_admit || { mnr_action_leave >/dev/null 2>&1 || :; return 75; }
  [ ! -e "$MNR_STATUS_FILE" ] && [ ! -L "$MNR_STATUS_FILE" ] &&
    [ ! -e "$MNR_PENDING_FILE" ] && [ ! -L "$MNR_PENDING_FILE" ] || {
      mnr_action_leave >/dev/null 2>&1 || :
      return 2
    }
  mkdir -p "$MNR_ROOT" 2>/dev/null || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  [ ! -L "$MNR_ROOT" ] && [ -d "$MNR_ROOT" ] || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  [ ! -e "$MNR_RUN_DIR" ] && [ ! -L "$MNR_RUN_DIR" ] || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  ( umask 077; mkdir "$MNR_RUN_DIR" ) 2>/dev/null || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  chmod 700 "$MNR_RUN_DIR" 2>/dev/null || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  [ "$(LC_ALL=C ls -ldn "$MNR_RUN_DIR" 2>/dev/null | awk 'NR == 1 {print $1}')" = drwx------ ] || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  MNR_PARENT_PID=$$
  MNR_PARENT_START=$MNR_ACTION_START
  MNR_PARENT_NONCE=$MNR_ACTION_NONCE
  mnr_test_checkpoint before-pending || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  mnr_pending_write none none || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  mnr_test_checkpoint pending-before-spawn || { mnr_action_leave >/dev/null 2>&1 || :; return 2; }
  nohup sh "$0" run "$MNR_RUN_ID" "$MNR_NODE_ID" </dev/null >> "$MNR_RUN_DIR/runner.log" 2>&1 &
  _mnr_runner_pid=$!
  mnr_test_checkpoint spawn-before-bind || { mnr_action_leave >/dev/null 2>&1 || :; return 1; }
  _mnr_runner_start=$(merv_identity_proc_start "$_mnr_runner_pid" /proc 2>/dev/null || printf '')
  case "$_mnr_runner_pid:$_mnr_runner_start" in *[!0-9:]*|:*|*::*) mnr_action_leave >/dev/null 2>&1 || :; return 1 ;; esac
  mnr_pending_write "$_mnr_runner_pid" "$_mnr_runner_start" || { mnr_action_leave >/dev/null 2>&1 || :; return 1; }
  _mnr_wait=0
  while [ "$_mnr_wait" -lt 5 ]; do
    if mnr_status_validate_file "$MNR_STATUS_FILE" "$MNR_RUN_ID" "$MNR_NODE_ID"; then
      case "$MNR_STATUS_STATE" in started|complete|failed) : ;; *) sleep 1; _mnr_wait=$((_mnr_wait + 1)); continue ;; esac
      if [ "$MNR_STATUS_PID" = "$_mnr_runner_pid" ] &&
         [ "$MNR_STATUS_START" = "$_mnr_runner_start" ]; then
        [ ! -e "$MNR_PENDING_FILE" ] || rm -f "$MNR_PENDING_FILE" 2>/dev/null || { mnr_action_leave >/dev/null 2>&1 || :; return 1; }
        mnr_action_leave || return 1
        printf '%s\n' "$MNR_STATUS_STATE"
        return 0
      fi
    fi
    sleep 1
    _mnr_wait=$((_mnr_wait + 1))
  done
  mnr_action_leave >/dev/null 2>&1 || :
  return 1
}

case "$MNR_ACTION" in
  start) mnr_start ;;
  status) mnr_init_paths && mnr_status_validate_file "$MNR_STATUS_FILE" "$MNR_RUN_ID" "$MNR_NODE_ID" && cat "$MNR_STATUS_FILE" ;;
  run) mnr_run ;;
  cancel) mnr_cancel ;;
  *) exit 2 ;;
esac
