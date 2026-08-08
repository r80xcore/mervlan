# File: lib_node_jobs.sh || version="0.72.3"
# Bounded POSIX/BusyBox node-job helper.  Parents own locks and aggregation;
# workers own only their job directories and one atomic terminal result.
[ -n "${LIB_NODE_JOBS_LOADED:-}" ] && return 0 2>/dev/null
: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_identity.sh" || return 1
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" || return 1

mnj_safe_token() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
mnj_positive() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ] 2>/dev/null; }

mnj_parallelism() {
  case "${1:-}" in 1|2) printf '%s\n' "$1" ;; *)
    type warn >/dev/null 2>&1 && warn -c vlan "Node jobs: invalid parallelism '${1:-}'; using 1"
    printf '1\n' ;;
  esac
}

mnj_root_valid() {
  case "${1:-}" in "$TMPDIR/node_jobs"|"$TMPDIR/node_jobs"/*|/tmp/mervlan_tmp/selftest.*/*) ;; *) return 1;; esac
  case "$1" in *..*|*[!A-Za-z0-9_./-]*) return 1;; esac
  return 0
}

mnj_job_dir() {
  mnj_root_valid "$1" && merv_is_valid_node_id "$2" && mnj_safe_token "$3" || return 1
  printf '%s/node_%s\n' "$1" "$2"
}

mnj_nodes_validate() {
  _mnj_nv_file="$1"
  [ -f "$_mnj_nv_file" ] || return 1
  _mnj_nv_nodes=' '; _mnj_nv_ips=' '
  while IFS=' ' read -r _mnj_nv_node _mnj_nv_ip _mnj_nv_extra || [ -n "$_mnj_nv_node" ]; do
    [ -z "$_mnj_nv_extra" ] && merv_is_valid_node_id "$_mnj_nv_node" && [ -n "$_mnj_nv_ip" ] || return 1
    case "$_mnj_nv_nodes" in *" $_mnj_nv_node "*) return 1;; esac
    case "$_mnj_nv_ips" in *" $_mnj_nv_ip "*) return 1;; esac
    _mnj_nv_nodes="$_mnj_nv_nodes$_mnj_nv_node "
    _mnj_nv_ips="$_mnj_nv_ips$_mnj_nv_ip "
  done < "$_mnj_nv_file"
  return 0
}

mnj_result_validate() {
  _mnj_rf="$1" _mnj_node="$2" _mnj_phase="$3"
  [ -f "$_mnj_rf" ] || return 1
  MNJ_RESULT_FORMAT=""; MNJ_RESULT_STATE=""; MNJ_RESULT_NODE=""; MNJ_RESULT_PHASE=""; MNJ_RESULT_STARTED=""; MNJ_RESULT_COMPLETED=""; MNJ_RESULT_REASON=""
  MNJ_RESULT_OWNER_PID=""; MNJ_RESULT_OWNER_START=""; MNJ_RESULT_OWNER_NONCE=""
  _mnj_a=0; _mnj_b=0; _mnj_c=0; _mnj_d=0; _mnj_e=0; _mnj_f=0; _mnj_g=0; _mnj_h=0; _mnj_i=0; _mnj_j=0
  while IFS= read -r _mnj_line || [ -n "$_mnj_line" ]; do
    case "$_mnj_line" in *=*) _mnj_k=${_mnj_line%%=*}; _mnj_v=${_mnj_line#*=} ;; *) return 1;; esac
    case "$_mnj_k" in
      format_version) [ "$_mnj_a" = 0 ] || return 1; _mnj_a=1; MNJ_RESULT_FORMAT=$_mnj_v ;;
      state) [ "$_mnj_b" = 0 ] || return 1; _mnj_b=1; MNJ_RESULT_STATE=$_mnj_v ;;
      node_id) [ "$_mnj_c" = 0 ] || return 1; _mnj_c=1; MNJ_RESULT_NODE=$_mnj_v ;;
      phase) [ "$_mnj_d" = 0 ] || return 1; _mnj_d=1; MNJ_RESULT_PHASE=$_mnj_v ;;
      started_epoch) [ "$_mnj_e" = 0 ] || return 1; _mnj_e=1; MNJ_RESULT_STARTED=$_mnj_v ;;
      completed_epoch) [ "$_mnj_f" = 0 ] || return 1; _mnj_f=1; MNJ_RESULT_COMPLETED=$_mnj_v ;;
      reason) [ "$_mnj_g" = 0 ] || return 1; _mnj_g=1; MNJ_RESULT_REASON=$_mnj_v ;;
      owner_pid) [ "$_mnj_h" = 0 ] || return 1; _mnj_h=1; MNJ_RESULT_OWNER_PID=$_mnj_v ;;
      owner_start) [ "$_mnj_i" = 0 ] || return 1; _mnj_i=1; MNJ_RESULT_OWNER_START=$_mnj_v ;;
      owner_nonce) [ "$_mnj_j" = 0 ] || return 1; _mnj_j=1; MNJ_RESULT_OWNER_NONCE=$_mnj_v ;;
      *) return 1 ;;
    esac
  done < "$_mnj_rf"
  [ "$_mnj_a$_mnj_b$_mnj_c$_mnj_d$_mnj_e$_mnj_f$_mnj_g$_mnj_h$_mnj_i$_mnj_j" = 1111111111 ] || return 1
  [ "$MNJ_RESULT_FORMAT" = 2 ] || return 1
  case "$MNJ_RESULT_STATE" in ok|failed|timeout) ;; *) return 1;; esac
  merv_is_valid_node_id "$MNJ_RESULT_NODE" && [ "$MNJ_RESULT_NODE" = "$_mnj_node" ] &&
    mnj_safe_token "$MNJ_RESULT_PHASE" && [ "$MNJ_RESULT_PHASE" = "$_mnj_phase" ] &&
    mnj_positive "$MNJ_RESULT_STARTED" && mnj_positive "$MNJ_RESULT_COMPLETED" &&
    [ "$MNJ_RESULT_COMPLETED" -ge "$MNJ_RESULT_STARTED" ] 2>/dev/null &&
    mnj_safe_token "$MNJ_RESULT_REASON" &&
    mnj_positive "$MNJ_RESULT_OWNER_PID" && mnj_positive "$MNJ_RESULT_OWNER_START" &&
    mnj_safe_token "$MNJ_RESULT_OWNER_NONCE"
}

mnj_publish_result() {
  _mnj_dir="$1" _mnj_node="$2" _mnj_phase="$3" _mnj_state="$4" _mnj_started="$5" _mnj_reason="$6"
  mnj_root_valid "${_mnj_dir%/node_*}" && merv_is_valid_node_id "$_mnj_node" && mnj_safe_token "$_mnj_phase" &&
    mnj_safe_token "$_mnj_reason" && mnj_positive "$_mnj_started" || return 1
  case "$_mnj_state" in ok|failed|timeout) ;; *) return 1;; esac
  _mnj_now=$(date +%s 2>/dev/null || printf '')
  mnj_positive "$_mnj_now" || return 1
  _mnj_owner_pid="${MNJ_WORK_OWNER_PID:-$$}"
  if [ -n "${MNJ_WORK_OWNER_START:-}" ]; then
    _mnj_owner_start="$MNJ_WORK_OWNER_START"
  else
    _mnj_owner_start=$(merv_identity_current_start 2>/dev/null || printf '')
  fi
  if [ -n "${MNJ_WORK_OWNER_NONCE:-}" ]; then
    _mnj_owner_nonce="$MNJ_WORK_OWNER_NONCE"
  else
    _mnj_owner_nonce=""
    if merv_identity_nonce_next 2>/dev/null; then
      _mnj_owner_nonce="$MERV_IDENTITY_NONCE"
    fi
  fi
  mnj_positive "$_mnj_owner_pid" && mnj_positive "$_mnj_owner_start" && mnj_safe_token "$_mnj_owner_nonce" || return 1
  _mnj_tmp="$_mnj_dir/.result.$$.${MNJ_RESULT_SEQ:-0}"
  MNJ_RESULT_SEQ=$(( ${MNJ_RESULT_SEQ:-0} + 1 ))
  umask 077
  printf 'format_version=2\nstate=%s\nnode_id=%s\nphase=%s\nstarted_epoch=%s\ncompleted_epoch=%s\nreason=%s\nowner_pid=%s\nowner_start=%s\nowner_nonce=%s\n' \
    "$_mnj_state" "$_mnj_node" "$_mnj_phase" "$_mnj_started" "$_mnj_now" "$_mnj_reason" \
    "$_mnj_owner_pid" "$_mnj_owner_start" "$_mnj_owner_nonce" > "$_mnj_tmp" || return 1
  mnj_result_validate "$_mnj_tmp" "$_mnj_node" "$_mnj_phase" || { rm -f "$_mnj_tmp"; return 1; }
  mv "$_mnj_tmp" "$_mnj_dir/result" || { rm -f "$_mnj_tmp"; return 1; }
}

mnj_child_identity_live() {
  _mnj_dir="$1"
  _mnj_pid=$(cat "$_mnj_dir/child.pid" 2>/dev/null || printf '')
  _mnj_start=$(cat "$_mnj_dir/child.proc_start_time" 2>/dev/null || printf '')
  case "$_mnj_pid:$_mnj_start" in *[!0-9:]*|:*|*::*) return 1;; esac
  merv_process_identity_matches "$_mnj_pid" "$_mnj_start"
}

mnj_worker_stop_child() {
  _mnj_dir="$1"
  if mnj_child_identity_live "$_mnj_dir"; then
    _mnj_pid=$(cat "$_mnj_dir/child.pid")
    kill -TERM "$_mnj_pid" 2>/dev/null || :
    sleep 1
    mnj_child_identity_live "$_mnj_dir" && kill -KILL "$_mnj_pid" 2>/dev/null || :
  fi
  [ -n "${MNJ_CHILD_PID:-}" ] && wait "$MNJ_CHILD_PID" 2>/dev/null || :
}

mnj_worker_term() {
  mnj_worker_stop_child "$MNJ_WORK_DIR"
  mnj_publish_result "$MNJ_WORK_DIR" "$MNJ_WORK_NODE" "$MNJ_WORK_PHASE" timeout "$MNJ_WORK_STARTED" worker-term-timeout || :
  MNJ_WORK_FINAL=1
  exit 143
}

mnj_worker_exit() {
  _mnj_rc=$?
  [ "${MNJ_WORK_FINAL:-0}" = 1 ] || mnj_publish_result "$MNJ_WORK_DIR" "$MNJ_WORK_NODE" "$MNJ_WORK_PHASE" failed "$MNJ_WORK_STARTED" worker-exit || :
}

# mnj_worker <job-dir> <node-id> <phase> <handler> <handler args...>
mnj_worker() {
  MNJ_WORK_DIR="$1"; MNJ_WORK_NODE="$2"; MNJ_WORK_PHASE="$3"; shift 3
  mnj_root_valid "${MNJ_WORK_DIR%/node_*}" && merv_is_valid_node_id "$MNJ_WORK_NODE" && mnj_safe_token "$MNJ_WORK_PHASE" || return 2
  mkdir -p "$MNJ_WORK_DIR/ssh" || return 2
  trap - EXIT INT TERM
  MNJ_WORK_STARTED=$(date +%s 2>/dev/null || printf '')
  mnj_positive "$MNJ_WORK_STARTED" || return 2
  MNJ_WORK_OWNER_PID="$$"
  MNJ_WORK_OWNER_START=$(merv_identity_current_start 2>/dev/null || printf '')
  MNJ_WORK_OWNER_NONCE=""
  if merv_identity_nonce_next 2>/dev/null; then
    MNJ_WORK_OWNER_NONCE="$MERV_IDENTITY_NONCE"
  fi
  mnj_positive "$MNJ_WORK_OWNER_PID" && mnj_positive "$MNJ_WORK_OWNER_START" && mnj_safe_token "$MNJ_WORK_OWNER_NONCE" || return 2
  export MNJ_WORK_OWNER_PID MNJ_WORK_OWNER_START MNJ_WORK_OWNER_NONCE
  LOG_chan_cli="$MNJ_WORK_DIR/cli.log"; LOG_chan_vlan="$MNJ_WORK_DIR/vlan.log"
  MERV_NODE_JOB_DIR="$MNJ_WORK_DIR"; MERV_SSH_TMPDIR="$MNJ_WORK_DIR/ssh"
  export LOG_chan_cli LOG_chan_vlan MERV_NODE_JOB_DIR MERV_SSH_TMPDIR
  : > "$LOG_chan_cli"; : > "$LOG_chan_vlan"; : > "$MNJ_WORK_DIR/stdout.log" || return 2
  trap mnj_worker_exit EXIT
  trap mnj_worker_term INT TERM
  "$@" > "$MNJ_WORK_DIR/stdout.log" 2>&1 &
  MNJ_CHILD_PID=$!
  MNJ_CHILD_START=$(merv_proc_start_time "$MNJ_CHILD_PID" 2>/dev/null || printf '')
  case "$MNJ_CHILD_START" in ''|*[!0-9]*) mnj_worker_stop_child "$MNJ_WORK_DIR"; return 2;; esac
  printf '%s\n' "$MNJ_CHILD_PID" > "$MNJ_WORK_DIR/child.pid"
  printf '%s\n' "$MNJ_CHILD_START" > "$MNJ_WORK_DIR/child.proc_start_time"
  wait "$MNJ_CHILD_PID"; _mnj_rc=$?
  if [ "$_mnj_rc" -eq 0 ]; then mnj_publish_result "$MNJ_WORK_DIR" "$MNJ_WORK_NODE" "$MNJ_WORK_PHASE" ok "$MNJ_WORK_STARTED" worker-ok || return 2
  else mnj_publish_result "$MNJ_WORK_DIR" "$MNJ_WORK_NODE" "$MNJ_WORK_PHASE" failed "$MNJ_WORK_STARTED" worker-failed || return 2; fi
  MNJ_WORK_FINAL=1
  return "$_mnj_rc"
}

mnj_slot_set() {
  case "$1" in 1) MNJ_S1_PID="$2"; MNJ_S1_START="$3"; MNJ_S1_DIR="$4"; MNJ_S1_NODE="$5"; MNJ_S1_DEADLINE="$6";;
                     2) MNJ_S2_PID="$2"; MNJ_S2_START="$3"; MNJ_S2_DIR="$4"; MNJ_S2_NODE="$5"; MNJ_S2_DEADLINE="$6";; esac
}
mnj_slot_get() {
  case "$1" in 1) MNJ_GP="$MNJ_S1_PID"; MNJ_GS="$MNJ_S1_START"; MNJ_GD="$MNJ_S1_DIR"; MNJ_GN="$MNJ_S1_NODE"; MNJ_GL="$MNJ_S1_DEADLINE";;
                     2) MNJ_GP="$MNJ_S2_PID"; MNJ_GS="$MNJ_S2_START"; MNJ_GD="$MNJ_S2_DIR"; MNJ_GN="$MNJ_S2_NODE"; MNJ_GL="$MNJ_S2_DEADLINE";; esac
}

mnj_reconcile_slot() {
  _mnj_slot="$1" _mnj_state="$2" _mnj_reason="$3"
  mnj_slot_get "$_mnj_slot"
  merv_process_identity_matches "$MNJ_GP" "$MNJ_GS" && kill -TERM "$MNJ_GP" 2>/dev/null || :
  _mnj_n=0; while [ "$_mnj_n" -lt 2 ] && merv_process_identity_matches "$MNJ_GP" "$MNJ_GS"; do sleep 1; _mnj_n=$((_mnj_n+1)); done
  merv_process_identity_matches "$MNJ_GP" "$MNJ_GS" && kill -KILL "$MNJ_GP" 2>/dev/null || :
  mnj_child_identity_live "$MNJ_GD" && { _mnj_cp=$(cat "$MNJ_GD/child.pid"); kill -TERM "$_mnj_cp" 2>/dev/null || :; sleep 1; mnj_child_identity_live "$MNJ_GD" && kill -KILL "$_mnj_cp" 2>/dev/null || :; }
  merv_process_identity_matches "$MNJ_GP" "$MNJ_GS" && return 1
  mnj_child_identity_live "$MNJ_GD" && return 1
  mnj_result_validate "$MNJ_GD/result" "$MNJ_GN" "$MNJ_POOL_PHASE" || mnj_publish_result "$MNJ_GD" "$MNJ_GN" "$MNJ_POOL_PHASE" "$_mnj_state" "$(cat "$MNJ_GD/started_epoch" 2>/dev/null || date +%s)" "$_mnj_reason" || return 1
  wait "$MNJ_GP" 2>/dev/null || :
  mnj_slot_set "$_mnj_slot" '' '' '' '' ''
  return 0
}

mnj_poll_slot() {
  _mnj_slot="$1"; mnj_slot_get "$_mnj_slot"; [ -n "$MNJ_GP" ] || return 0
  if mnj_result_validate "$MNJ_GD/result" "$MNJ_GN" "$MNJ_POOL_PHASE"; then
    mnj_child_identity_live "$MNJ_GD" && return 0
    wait "$MNJ_GP" 2>/dev/null || :
    mnj_slot_set "$_mnj_slot" '' '' '' '' ''
    return 0
  fi
  _mnj_now=$(date +%s 2>/dev/null || printf 0)
  if ! merv_process_identity_matches "$MNJ_GP" "$MNJ_GS"; then mnj_reconcile_slot "$_mnj_slot" failed missing-result
  elif [ "$_mnj_now" -ge "$MNJ_GL" ] 2>/dev/null; then mnj_reconcile_slot "$_mnj_slot" timeout parent-deadline
  fi
}

# Parents may opt into a small progress callback while a pool is running.
# The callback is deliberately run only by the parent: workers must continue
# to write exclusively to their isolated job directories.  A safe function
# token avoids eval while preserving POSIX ash compatibility.
mnj_pool_progress() {
  [ -n "${MNJ_POOL_PROGRESS_HOOK:-}" ] || return 0
  mnj_safe_token "$MNJ_POOL_PROGRESS_HOOK" || return 0
  type "$MNJ_POOL_PROGRESS_HOOK" >/dev/null 2>&1 || return 0
  "$MNJ_POOL_PROGRESS_HOOK" "$MNJ_POOL_ROOT" "$MNJ_POOL_PHASE"
}

# mnj_pool_run <job-root> <phase> <parallelism> <timeout> <nodes-file> <handler>
mnj_pool_run() {
  MNJ_POOL_ROOT="$1"; MNJ_POOL_PHASE="$2"; MNJ_POOL_PAR=$(mnj_parallelism "$3"); MNJ_POOL_TIMEOUT="$4"; MNJ_POOL_NODES="$5"; MNJ_POOL_HANDLER="$6"
  mnj_root_valid "$MNJ_POOL_ROOT" && mnj_safe_token "$MNJ_POOL_PHASE" && mnj_positive "$MNJ_POOL_TIMEOUT" && [ -f "$MNJ_POOL_NODES" ] || return 2
  MNJ_POOL_FAILURES=0; MNJ_S1_PID=''; MNJ_S2_PID=''; mkdir -p "$MNJ_POOL_ROOT" || return 2
  MNJ_POOL_INPUT="$MNJ_POOL_ROOT/.nodes.$$"
  umask 077
  cat "$MNJ_POOL_NODES" > "$MNJ_POOL_INPUT" || return 2
  mnj_nodes_validate "$MNJ_POOL_INPUT" || return 2
  while IFS=' ' read -r MNJ_POOL_NODE MNJ_POOL_IP MNJ_POOL_EXTRA || [ -n "$MNJ_POOL_NODE" ]; do
    while :; do
      mnj_poll_slot 1; mnj_poll_slot 2
      mnj_pool_progress
      mnj_slot_get 1; _mnj_busy1="$MNJ_GP"; mnj_slot_get 2; _mnj_busy2="$MNJ_GP"
      if [ -z "$_mnj_busy1" ]; then _mnj_slot=1; break; fi
      if [ "$MNJ_POOL_PAR" = 2 ] && [ -z "$_mnj_busy2" ]; then _mnj_slot=2; break; fi
      sleep 1
    done
    MNJ_POOL_DIR=$(mnj_job_dir "$MNJ_POOL_ROOT" "$MNJ_POOL_NODE" "$MNJ_POOL_PHASE") || return 2
    [ ! -e "$MNJ_POOL_DIR" ] || return 2
    mkdir -p "$MNJ_POOL_DIR" || return 2
    ( mnj_worker "$MNJ_POOL_DIR" "$MNJ_POOL_NODE" "$MNJ_POOL_PHASE" "$MNJ_POOL_HANDLER" "$MNJ_POOL_NODE" "$MNJ_POOL_IP" ) </dev/null &
    _mnj_pid=$!; _mnj_start=$(merv_proc_start_time "$_mnj_pid" 2>/dev/null || printf '')
    case "$_mnj_start" in
      ''|*[!0-9]*)
        kill -TERM "$_mnj_pid" 2>/dev/null || :
        wait "$_mnj_pid" 2>/dev/null || :
        return 2
        ;;
    esac
    if ! printf '%s\n' "$_mnj_pid" > "$MNJ_POOL_DIR/wrapper.pid" ||
       ! printf '%s\n' "$_mnj_start" > "$MNJ_POOL_DIR/wrapper.proc_start_time"; then
      merv_process_identity_matches "$_mnj_pid" "$_mnj_start" && kill -TERM "$_mnj_pid" 2>/dev/null || :
      wait "$_mnj_pid" 2>/dev/null || :
      return 2
    fi
    _mnj_now=$(date +%s); mnj_slot_set "$_mnj_slot" "$_mnj_pid" "$_mnj_start" "$MNJ_POOL_DIR" "$MNJ_POOL_NODE" $((_mnj_now + MNJ_POOL_TIMEOUT))
  done < "$MNJ_POOL_INPUT"
  while [ -n "$MNJ_S1_PID$MNJ_S2_PID" ]; do mnj_poll_slot 1; mnj_poll_slot 2; mnj_pool_progress; [ -n "$MNJ_S1_PID$MNJ_S2_PID" ] && sleep 1; done
  mnj_pool_progress
  for _mnj_dir in "$MNJ_POOL_ROOT"/node_*; do [ -d "$_mnj_dir" ] || continue; mnj_result_validate "$_mnj_dir/result" "${_mnj_dir##*/node_}" "$MNJ_POOL_PHASE" && [ "$MNJ_RESULT_STATE" = ok ] || MNJ_POOL_FAILURES=$((MNJ_POOL_FAILURES+1)); done
  [ "$MNJ_POOL_FAILURES" -eq 0 ]
}

# mnj_prepare_node_settings <main_settings_file> <target_node_id> <output_file> [node_hw_source_file]
# Pure, testable settings-builder that transforms main settings.json into a complete,
# final node-specific settings.json ready for transmission and digest verification.
mnj_prepare_node_settings() {
  _mpns_main="$1"
  _mpns_node="$2"
  _mpns_out="$3"
  _mpns_hw_src="${4:-}"

  [ -f "$_mpns_main" ] || return 1
  merv_is_valid_node_id "$_mpns_node" || return 1
  [ -n "$_mpns_out" ] || return 1

  [ -n "${LIB_JSON_LOADED:-}" ] || . "${MERV_BASE:-/jffs/addons/mervlan}/settings/lib_json.sh" || return 1

  _mpns_out_dir=$(dirname "$_mpns_out" 2>/dev/null || printf '')
  if [ -n "$_mpns_out_dir" ] && [ "$_mpns_out_dir" != "." ]; then
    mkdir -p "$_mpns_out_dir" 2>/dev/null || return 1
  fi

  _mpns_tmp="${_mpns_out}.tmp.$$"
  cp "$_mpns_main" "$_mpns_tmp" 2>/dev/null || { rm -f "$_mpns_tmp" 2>/dev/null; return 1; }

  # 1. Apply node identity flags locally
  if ! json_set_flag "IS_NODE" "1" "$_mpns_tmp" || ! json_set_flag "NODE_ID" "$_mpns_node" "$_mpns_tmp"; then
    rm -f "$_mpns_tmp" 2>/dev/null
    return 1
  fi
  if grep -q '"General"[[:space:]]*:' "$_mpns_tmp" 2>/dev/null; then
    json_set_section_value "General" "IS_NODE" "1" "$_mpns_tmp" 2>/dev/null || :
    json_set_section_value "General" "NODE_ID" "$_mpns_node" "$_mpns_tmp" 2>/dev/null || :
  fi

  # 2. Preserve node-owned Hardware section if source file provided
  if [ -n "$_mpns_hw_src" ] && [ -f "$_mpns_hw_src" ]; then
    _mpns_node_hw=$(json_extract_hardware_section "$_mpns_hw_src" 2>/dev/null || printf '')
    if [ -n "$_mpns_node_hw" ] && echo "$_mpns_node_hw" | grep -q '"Hardware"'; then
      _mpns_hw_file="${_mpns_tmp}.hw.$$"
      printf '%s\n' "$_mpns_node_hw" > "$_mpns_hw_file" 2>/dev/null
      if json_replace_hardware_section "$_mpns_hw_file" "$_mpns_tmp"; then
        rm -f "$_mpns_hw_file" 2>/dev/null
      else
        rm -f "$_mpns_hw_file" 2>/dev/null
        rm -f "$_mpns_tmp" 2>/dev/null
        return 1
      fi
    fi
  fi

  # 3. Apply trunk rules (unify trunk configuration for node backhaul)
  _mpns_main_has_trunk="no"
  _mpns_ti=1
  while [ "$_mpns_ti" -le 8 ]; do
    if [ "$(json_get_flag "TRUNK${_mpns_ti}" "0" "$_mpns_main")" = "1" ]; then
      _mpns_main_has_trunk="yes"
      break
    fi
    _mpns_ti=$((_mpns_ti + 1))
  done

  if [ "$_mpns_main_has_trunk" = "yes" ] && json_reset_trunks_section "$_mpns_tmp"; then
    _mpns_vlan_scan_max=$(json_get_section_value "Hardware" "MAX_SSIDS" "$_mpns_tmp" 2>/dev/null)
    case "$_mpns_vlan_scan_max" in
      ''|0|*[!0-9]*)
        _mpns_vlan_scan_max=$(json_get_section_value "Limits" "MAX_SSID_CAP" "$_mpns_tmp" 2>/dev/null)
        case "$_mpns_vlan_scan_max" in ''|0|*[!0-9]*) _mpns_vlan_scan_max=16 ;; esac
        ;;
    esac
    _mpns_vlan_list=""
    _mpns_vi=1
    while [ "$_mpns_vi" -le "$_mpns_vlan_scan_max" ]; do
      _mpns_vid="$(json_get_flag "VLAN_$(printf '%02d' "$_mpns_vi")" "" "$_mpns_tmp")"
      case "$_mpns_vid" in
        ""|none|*[!0-9]*) ;;
        *) _mpns_vlan_list="${_mpns_vlan_list}${_mpns_vlan_list:+,}${_mpns_vid}" ;;
      esac
      _mpns_vi=$((_mpns_vi + 1))
    done
    if [ -n "$_mpns_vlan_list" ]; then
      json_set_flag "TRUNK1" "1" "$_mpns_tmp"
      json_set_flag "TAGGED_TRUNK1" "$_mpns_vlan_list" "$_mpns_tmp"
    fi
  else
    json_reset_trunks_section "$_mpns_tmp" 2>/dev/null || :
  fi

  mv "$_mpns_tmp" "$_mpns_out" 2>/dev/null || { rm -f "$_mpns_tmp" 2>/dev/null; return 1; }
  return 0
}

LIB_NODE_JOBS_LOADED=1
