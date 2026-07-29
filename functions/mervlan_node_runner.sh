#!/bin/sh
# File: mervlan_node_runner.sh || version="0.72.0"
# Structured, detached node-manager runner.  Status files are untrusted input
# to callers and are always parsed, never sourced.

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" || exit 2

MNR_ACTION="${1:-}"
MNR_RUN_ID="${2:-}"
MNR_NODE_ID="${3:-}"
MNR_PUBLISH_SEQ=0
MNR_FINAL=0
MNR_CHILD_PID=""
MNR_CHILD_START=""
MNR_STARTED_EPOCH=""
MNR_MANAGER="${MERV_NODE_RUNNER_MANAGER:-$VLAN_MANAGER}"

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
  return 0
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
  [ -f "$_mnr_file" ] || return 1
  MNR_STATUS_FORMAT=""; MNR_STATUS_RUN=""; MNR_STATUS_NODE=""
  MNR_STATUS_STATE=""; MNR_STATUS_PID=""; MNR_STATUS_START=""
  MNR_STATUS_STARTED=""; MNR_STATUS_COMPLETED=""; MNR_STATUS_EXIT=""
  MNR_STATUS_REASON=""
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
  [ -n "$MNR_CHILD_PID" ] && [ -n "$MNR_CHILD_START" ] && [ -n "$MNR_STARTED_EPOCH" ] || return 1
  mkdir -p "$MNR_RUN_DIR" 2>/dev/null || return 1
  MNR_PUBLISH_SEQ=$((MNR_PUBLISH_SEQ + 1))
  _mnr_tmp="$MNR_RUN_DIR/.node_$MNR_NODE_ID.status.$$.${MNR_PUBLISH_SEQ}"
  umask 077
  {
    printf 'format_version=1\nrun_id=%s\nnode_id=%s\nstate=%s\npid=%s\nproc_start_time=%s\nstarted_epoch=%s\n' \
      "$MNR_RUN_ID" "$MNR_NODE_ID" "$_mnr_state" "$MNR_CHILD_PID" "$MNR_CHILD_START" "$MNR_STARTED_EPOCH"
    case "$_mnr_state" in
      started) printf 'completed_epoch=0\nexit_code=\nreason=%s\n' "$_mnr_reason" ;;
      complete|failed) _mnr_done=$(mnr_now) || exit 1; printf 'completed_epoch=%s\nexit_code=%s\nreason=%s\n' "$_mnr_done" "$_mnr_exit" "$_mnr_reason" ;;
      *) exit 1 ;;
    esac
  } > "$_mnr_tmp" 2>/dev/null || { rm -f "$_mnr_tmp" 2>/dev/null || :; return 1; }
  mnr_status_validate_file "$_mnr_tmp" "$MNR_RUN_ID" "$MNR_NODE_ID" || { rm -f "$_mnr_tmp" 2>/dev/null || :; return 1; }
  mv "$_mnr_tmp" "$MNR_STATUS_FILE" 2>/dev/null || { rm -f "$_mnr_tmp" 2>/dev/null || :; return 1; }
  case "$_mnr_state" in complete|failed) MNR_FINAL=1 ;; esac
  return 0
}

mnr_stop_child() {
  [ -n "$MNR_CHILD_PID" ] && [ -n "$MNR_CHILD_START" ] || return 0
  if merv_process_identity_matches "$MNR_CHILD_PID" "$MNR_CHILD_START"; then
    kill -TERM "$MNR_CHILD_PID" 2>/dev/null || :
    sleep 1
    merv_process_identity_matches "$MNR_CHILD_PID" "$MNR_CHILD_START" && kill -KILL "$MNR_CHILD_PID" 2>/dev/null || :
  fi
  wait "$MNR_CHILD_PID" 2>/dev/null || :
}

mnr_run_exit() {
  _mnr_rc=$?
  [ "$MNR_FINAL" -eq 1 ] || mnr_publish failed "${_mnr_rc:-1}" runner-exit || :
}

mnr_run_term() {
  mnr_stop_child
  mnr_publish failed 143 runner-terminated || :
  MNR_FINAL=1
  exit 143
}

mnr_run() {
  mnr_init_paths || return 2
  [ ! -e "$MNR_STATUS_FILE" ] || return 2
  [ -f "$MNR_MANAGER" ] || return 2
  mkdir -p "$MNR_RUN_DIR" 2>/dev/null || return 2
  trap - EXIT INT TERM
  trap mnr_run_exit EXIT
  trap mnr_run_term INT TERM
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
  mnr_publish started '' started || { mnr_stop_child; return 2; }
  wait "$MNR_CHILD_PID"
  _mnr_rc=$?
  if [ "$_mnr_rc" -eq 0 ]; then
    mnr_publish complete 0 manager-complete || return 2
    return 0
  fi
  mnr_publish failed "$_mnr_rc" manager-failed || return 2
  return "$_mnr_rc"
}

mnr_start() {
  mnr_init_paths || return 2
  mnr_prune_old_runs || return 2
  [ ! -e "$MNR_STATUS_FILE" ] || return 2
  mkdir -p "$MNR_RUN_DIR" 2>/dev/null || return 2
  nohup sh "$0" run "$MNR_RUN_ID" "$MNR_NODE_ID" </dev/null >> "$MNR_RUN_DIR/runner.log" 2>&1 &
  _mnr_runner_pid=$!
  _mnr_runner_start=$(merv_proc_start_time "$_mnr_runner_pid" 2>/dev/null || printf '')
  _mnr_wait=0
  while [ "$_mnr_wait" -lt 5 ]; do
    if mnr_status_validate_file "$MNR_STATUS_FILE" "$MNR_RUN_ID" "$MNR_NODE_ID"; then
      printf '%s\n' "$MNR_STATUS_STATE"
      return 0
    fi
    merv_process_identity_matches "$_mnr_runner_pid" "$_mnr_runner_start" 2>/dev/null && {
      printf 'started\n'
      return 0
    }
    sleep 1
    _mnr_wait=$((_mnr_wait + 1))
  done
  return 1
}

case "$MNR_ACTION" in
  start) mnr_start ;;
  status) mnr_init_paths && mnr_status_validate_file "$MNR_STATUS_FILE" "$MNR_RUN_ID" "$MNR_NODE_ID" && cat "$MNR_STATUS_FILE" ;;
  run) mnr_run ;;
  *) exit 2 ;;
esac
