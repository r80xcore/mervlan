#!/bin/sh
# Strict continuation leases for work that may outlive its R/M owner.
# Records are data, never shell code. A malformed or ambiguous lease blocks.

if [ -n "${LIB_CONTINUATION_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || return 1 2>/dev/null || exit 1

MERV_CONTINUATION_CANONICAL_ROOT=/tmp/mervlan_tmp/continuations
if ! type merv_selftest_context_valid >/dev/null 2>&1 ||
   ! merv_selftest_context_valid; then
  MERV_CONTINUATION_ROOT=$MERV_CONTINUATION_CANONICAL_ROOT
fi
LIB_CONTINUATION_LOADED=1
MERV_CONTINUATION_TMP_SEQ=${MERV_CONTINUATION_TMP_SEQ:-0}

merv_continuation_root() {
  _mcr_requested=${1:-${MERV_CONTINUATION_ROOT:-$MERV_CONTINUATION_CANONICAL_ROOT}}
  if [ "$_mcr_requested" = "$MERV_CONTINUATION_CANONICAL_ROOT" ]; then
    printf '%s\n' "$MERV_CONTINUATION_CANONICAL_ROOT"
    return 0
  fi
  type merv_selftest_context_path_allowed >/dev/null 2>&1 || return 1
  merv_selftest_context_path_allowed "$_mcr_requested" || return 1
  merv_owner_lock_path_chain_safe "$_mcr_requested" || return 1
  printf '%s\n' "$_mcr_requested"
}

merv_continuation_token_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 160 ]
}

merv_continuation_operation_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

merv_continuation_parent_valid() {
  _mcpv_type=${1:-}
  _mcpv_path=${2:-}
  case "$_mcpv_type" in action|maintenance|runtime) ;; *) return 1 ;; esac
  case "$_mcpv_path" in
    /tmp/mervlan_tmp/locks/*) ;;
    /tmp/mervlan_tmp/locks/mervlan_maintenance.lock) ;;
    *)
      type merv_selftest_context_path_allowed >/dev/null 2>&1 || return 1
      merv_selftest_context_path_allowed "$_mcpv_path" || return 1
      ;;
  esac
  case "$_mcpv_type:$_mcpv_path" in
    maintenance:/tmp/mervlan_tmp/locks/mervlan_maintenance.lock) ;;
    maintenance:*)
      type merv_selftest_context_path_allowed >/dev/null 2>&1 &&
        merv_selftest_context_path_allowed "$_mcpv_path" || return 1
      ;;
    action:/tmp/mervlan_tmp/locks/mervlan_action.lock) ;;
    action:*)
      type merv_selftest_context_path_allowed >/dev/null 2>&1 &&
        merv_selftest_context_path_allowed "$_mcpv_path" || return 1
      ;;
    *) ;;
  esac
  merv_owner_lock_path_chain_safe "$_mcpv_path" || return 1
  return 0
}

merv_continuation_path() {
  _mcp_token=${1:-}
  merv_continuation_token_valid "$_mcp_token" || return 1
  _mcp_root=$(merv_continuation_root) || return 1
  printf '%s/%s/lease\n' "$_mcp_root" "$_mcp_token"
}

merv_continuation_root_safe() {
  _mcrs_root=${1:-$(merv_continuation_root)}
  [ -n "$_mcrs_root" ] || return 1
  merv_owner_lock_path_chain_safe "$_mcrs_root" || return 1
  [ -d "$_mcrs_root" ] && [ ! -L "$_mcrs_root" ] &&
    [ -r "$_mcrs_root" ] && [ -x "$_mcrs_root" ] || return 1
  _mcrs_mode=$(LC_ALL=C ls -ldn "$_mcrs_root" 2>/dev/null | awk 'NR == 1 { print $1 }')
  [ "$_mcrs_mode" = drwx------ ]
}

# Parse a lease strictly into MERV_CONTINUATION_* values.
merv_continuation_read() {
  _mcr_file=${1:-}
  MERV_CONTINUATION_FORMAT=
  MERV_CONTINUATION_TOKEN=
  MERV_CONTINUATION_OPERATION=
  MERV_CONTINUATION_RUN_TOKEN=
  MERV_CONTINUATION_PARENT_TYPE=
  MERV_CONTINUATION_PARENT_PATH=
  MERV_CONTINUATION_PARENT_PID=
  MERV_CONTINUATION_PARENT_START=
  MERV_CONTINUATION_PARENT_NONCE=
  MERV_CONTINUATION_CHILD_PID=
  MERV_CONTINUATION_CHILD_START=
  MERV_CONTINUATION_STATE=
  [ -n "$_mcr_file" ] && [ ! -L "$_mcr_file" ] && [ -f "$_mcr_file" ] &&
    [ -r "$_mcr_file" ] || return 1
  _mcr_mode=$(LC_ALL=C ls -ldn "$_mcr_file" 2>/dev/null | awk 'NR == 1 { print $1 }')
  [ "$_mcr_mode" = -rw------- ] || return 1
  _mcr_size=$(wc -c < "$_mcr_file" 2>/dev/null | awk '{print $1}') || return 1
  case "$_mcr_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_mcr_size" -gt 0 ] 2>/dev/null && [ "$_mcr_size" -le 2048 ] 2>/dev/null || return 1
  LC_ALL=C grep -q '[^ -~]' "$_mcr_file" 2>/dev/null && return 1
  awk -F= '
    BEGIN {
      split("format lease_token operation run_token parent_type parent_path parent_pid parent_start_time parent_nonce child_pid child_start_time state", keys, " ")
      for (i in keys) required[keys[i]] = 1
      wanted = 12
    }
    {
      if (NF != 2 || !($1 in required)) exit 2
      seen[$1]++
      if (seen[$1] != 1) exit 2
      value = $2
      if ($1 == "format" && value != "1") exit 2
      if (($1 == "lease_token" || $1 == "run_token" || $1 == "parent_nonce") && value !~ /^[A-Za-z0-9._:-]+$/) exit 2
      if ($1 == "operation" && value !~ /^[A-Za-z0-9_.-]+$/) exit 2
      if ($1 == "parent_type" && value !~ /^(action|maintenance|runtime)$/) exit 2
      if ($1 == "parent_path" && value !~ /^\/[A-Za-z0-9_.\/-]+$/) exit 2
      if (($1 == "parent_pid" || $1 == "parent_start_time") && value !~ /^[1-9][0-9]*$/) exit 2
      if (($1 == "child_pid" || $1 == "child_start_time") && value != "none" && value !~ /^[1-9][0-9]*$/) exit 2
      if ($1 == "state" && value !~ /^(pending|active|terminal)$/) exit 2
      count++
    }
    END {
      if (count != wanted) exit 2
      for (key in required) if (seen[key] != 1) exit 2
    }
  ' "$_mcr_file" >/dev/null 2>&1 || return 1
  _mcr_lines=0
  while IFS= read -r _mcr_line || [ -n "$_mcr_line" ]; do
    _mcr_lines=$((_mcr_lines + 1))
    _mcr_key=${_mcr_line%%=*}
    _mcr_value=${_mcr_line#*=}
    case "$_mcr_key" in
      format) MERV_CONTINUATION_FORMAT=$_mcr_value ;;
      lease_token) MERV_CONTINUATION_TOKEN=$_mcr_value ;;
      operation) MERV_CONTINUATION_OPERATION=$_mcr_value ;;
      run_token) MERV_CONTINUATION_RUN_TOKEN=$_mcr_value ;;
      parent_type) MERV_CONTINUATION_PARENT_TYPE=$_mcr_value ;;
      parent_path) MERV_CONTINUATION_PARENT_PATH=$_mcr_value ;;
      parent_pid) MERV_CONTINUATION_PARENT_PID=$_mcr_value ;;
      parent_start_time) MERV_CONTINUATION_PARENT_START=$_mcr_value ;;
      parent_nonce) MERV_CONTINUATION_PARENT_NONCE=$_mcr_value ;;
      child_pid) MERV_CONTINUATION_CHILD_PID=$_mcr_value ;;
      child_start_time) MERV_CONTINUATION_CHILD_START=$_mcr_value ;;
      state) MERV_CONTINUATION_STATE=$_mcr_value ;;
    esac
  done < "$_mcr_file"
  [ "$_mcr_lines" -eq 12 ] || return 1
  merv_continuation_token_valid "$MERV_CONTINUATION_TOKEN" || return 1
  merv_continuation_token_valid "$MERV_CONTINUATION_RUN_TOKEN" || return 1
  merv_continuation_operation_valid "$MERV_CONTINUATION_OPERATION" || return 1
  merv_continuation_parent_valid "$MERV_CONTINUATION_PARENT_TYPE" \
    "$MERV_CONTINUATION_PARENT_PATH" || return 1
  merv_owner_v2_positive_uint "$MERV_CONTINUATION_PARENT_PID" || return 1
  merv_owner_v2_positive_uint "$MERV_CONTINUATION_PARENT_START" || return 1
  merv_owner_v2_nonce_valid "$MERV_CONTINUATION_PARENT_NONCE" || return 1
  case "$MERV_CONTINUATION_STATE:$MERV_CONTINUATION_CHILD_PID:$MERV_CONTINUATION_CHILD_START" in
    pending:none:none) ;;
    pending:[1-9]*:[1-9]*)
      merv_owner_v2_positive_uint "$MERV_CONTINUATION_CHILD_PID" || return 1
      merv_owner_v2_positive_uint "$MERV_CONTINUATION_CHILD_START" || return 1
      ;;
    active:[1-9]*:[1-9]*|terminal:[1-9]*:[1-9]*)
      merv_owner_v2_positive_uint "$MERV_CONTINUATION_CHILD_PID" || return 1
      merv_owner_v2_positive_uint "$MERV_CONTINUATION_CHILD_START" || return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

merv_continuation_write() {
  _mcw_file=${1:-}
  _mcw_state=${2:-}
  _mcw_child_pid=${3:-none}
  _mcw_child_start=${4:-none}
  [ -n "$_mcw_file" ] && [ -n "${MERV_CONTINUATION_TOKEN:-}" ] || return 1
  case "$_mcw_state:$_mcw_child_pid:$_mcw_child_start" in
    pending:none:none) ;;
    pending:[1-9]*:[1-9]*)
      merv_owner_v2_positive_uint "$_mcw_child_pid" || return 1
      merv_owner_v2_positive_uint "$_mcw_child_start" || return 1
      ;;
    active:[1-9]*:[1-9]*|terminal:[1-9]*:[1-9]*)
      merv_owner_v2_positive_uint "$_mcw_child_pid" || return 1
      merv_owner_v2_positive_uint "$_mcw_child_start" || return 1
      ;;
    *) return 1 ;;
  esac
  MERV_CONTINUATION_TMP_SEQ=$((MERV_CONTINUATION_TMP_SEQ + 1))
  _mcw_tmp="${_mcw_file}.tmp.$$.$MERV_CONTINUATION_TMP_SEQ"
  [ ! -e "$_mcw_tmp" ] && [ ! -L "$_mcw_tmp" ] || return 1
  ( umask 077
    {
      printf 'format=1\n'
      printf 'lease_token=%s\n' "$MERV_CONTINUATION_TOKEN"
      printf 'operation=%s\n' "$MERV_CONTINUATION_OPERATION"
      printf 'run_token=%s\n' "$MERV_CONTINUATION_RUN_TOKEN"
      printf 'parent_type=%s\n' "$MERV_CONTINUATION_PARENT_TYPE"
      printf 'parent_path=%s\n' "$MERV_CONTINUATION_PARENT_PATH"
      printf 'parent_pid=%s\n' "$MERV_CONTINUATION_PARENT_PID"
      printf 'parent_start_time=%s\n' "$MERV_CONTINUATION_PARENT_START"
      printf 'parent_nonce=%s\n' "$MERV_CONTINUATION_PARENT_NONCE"
      printf 'child_pid=%s\n' "$_mcw_child_pid"
      printf 'child_start_time=%s\n' "$_mcw_child_start"
      printf 'state=%s\n' "$_mcw_state"
    } > "$_mcw_tmp"
  ) 2>/dev/null || { rm -f "$_mcw_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_mcw_tmp" 2>/dev/null || { rm -f "$_mcw_tmp" 2>/dev/null || :; return 1; }
  merv_continuation_read "$_mcw_tmp" || { rm -f "$_mcw_tmp" 2>/dev/null || :; return 1; }
  mv -f "$_mcw_tmp" "$_mcw_file" 2>/dev/null || {
    rm -f "$_mcw_tmp" 2>/dev/null || :
    return 1
  }
  return 0
}

# Bind the direct child identity while the authenticated parent R/M owner is
# still held. The child waits for this publication before activation.
merv_continuation_bind_child() {
  _mcbc_token=${1:-}
  _mcbc_pid=${2:-}
  _mcbc_start=${3:-}
  _mcbc_file=$(merv_continuation_path "$_mcbc_token") || return 1
  merv_continuation_read "$_mcbc_file" || return 1
  [ "$MERV_CONTINUATION_STATE" = pending ] &&
    [ "$MERV_CONTINUATION_CHILD_PID" = none ] &&
    [ "$MERV_CONTINUATION_CHILD_START" = none ] || return 1
  [ "$MERV_CONTINUATION_PARENT_PID" = "$$" ] || return 1
  merv_owner_v2_matches "$MERV_CONTINUATION_PARENT_PATH" \
    "$MERV_CONTINUATION_PARENT_PID" "$MERV_CONTINUATION_PARENT_START" \
    "$MERV_CONTINUATION_PARENT_NONCE" /proc || return 1
  [ "$(merv_continuation_process_state "$_mcbc_pid" "$_mcbc_start")" = live ] || return 1
  merv_continuation_write "$_mcbc_file" pending "$_mcbc_pid" "$_mcbc_start" || return 1
  merv_continuation_read "$_mcbc_file" || return 1
  [ "$MERV_CONTINUATION_STATE" = pending ] &&
    [ "$MERV_CONTINUATION_CHILD_PID" = "$_mcbc_pid" ] &&
    [ "$MERV_CONTINUATION_CHILD_START" = "$_mcbc_start" ]
}

# Publish pending while the exact parent owner is still live. The caller must
# verify success before spawning any child that can mutate.
merv_continuation_publish_pending() {
  _mcpp_operation=${1:-}
  _mcpp_run=${2:-}
  _mcpp_type=${3:-}
  _mcpp_parent=${4:-}
  _mcpp_pid=${5:-}
  _mcpp_start=${6:-}
  _mcpp_nonce=${7:-}
  merv_continuation_operation_valid "$_mcpp_operation" || return 1
  merv_continuation_token_valid "$_mcpp_run" || return 1
  merv_continuation_parent_valid "$_mcpp_type" "$_mcpp_parent" || return 1
  merv_owner_v2_positive_uint "$_mcpp_pid" || return 1
  merv_owner_v2_positive_uint "$_mcpp_start" || return 1
  merv_owner_v2_nonce_valid "$_mcpp_nonce" || return 1
  merv_owner_v2_matches "$_mcpp_parent" "$_mcpp_pid" "$_mcpp_start" \
    "$_mcpp_nonce" /proc || return 1
  _mcpp_root=$(merv_continuation_root) || return 1
  if ! ls -ld "$_mcpp_root" >/dev/null 2>&1; then
    merv_owner_lock_path_chain_safe "$_mcpp_root" || return 1
    _mcpp_parent_root=${_mcpp_root%/*}
    [ -d "$_mcpp_parent_root" ] && [ ! -L "$_mcpp_parent_root" ] || return 1
    mkdir "$_mcpp_root" 2>/dev/null || return 1
    chmod 700 "$_mcpp_root" 2>/dev/null || return 1
  fi
  merv_continuation_root_safe "$_mcpp_root" || return 1
  merv_identity_nonce_next || return 1
  _mcpp_token=$MERV_IDENTITY_NONCE
  merv_continuation_token_valid "$_mcpp_token" || return 1
  _mcpp_dir="$_mcpp_root/$_mcpp_token"
  mkdir "$_mcpp_dir" 2>/dev/null || return 1
  chmod 700 "$_mcpp_dir" 2>/dev/null || return 1
  MERV_CONTINUATION_TOKEN=$_mcpp_token
  MERV_CONTINUATION_OPERATION=$_mcpp_operation
  MERV_CONTINUATION_RUN_TOKEN=$_mcpp_run
  MERV_CONTINUATION_PARENT_TYPE=$_mcpp_type
  MERV_CONTINUATION_PARENT_PATH=$_mcpp_parent
  MERV_CONTINUATION_PARENT_PID=$_mcpp_pid
  MERV_CONTINUATION_PARENT_START=$_mcpp_start
  MERV_CONTINUATION_PARENT_NONCE=$_mcpp_nonce
  MERV_CONTINUATION_CHILD_PID=none
  MERV_CONTINUATION_CHILD_START=none
  MERV_CONTINUATION_STATE=pending
  _mcpp_file="$_mcpp_dir/lease"
  merv_continuation_write "$_mcpp_file" pending none none || return 1
  merv_continuation_read "$_mcpp_file" || return 1
  [ "$MERV_CONTINUATION_TOKEN" = "$_mcpp_token" ] &&
    [ "$MERV_CONTINUATION_STATE" = pending ] || return 1
  MERV_CONTINUATION_PATH=$_mcpp_file
  MERV_CONTINUATION_TOKEN=$_mcpp_token
  return 0
}

merv_continuation_authenticate_parent() {
  _mcap_file=${1:-}
  _mcap_token=${2:-}
  merv_continuation_read "$_mcap_file" || return 1
  [ "$MERV_CONTINUATION_TOKEN" = "$_mcap_token" ] || return 1
  merv_owner_v2_matches "$MERV_CONTINUATION_PARENT_PATH" \
    "$MERV_CONTINUATION_PARENT_PID" "$MERV_CONTINUATION_PARENT_START" \
    "$MERV_CONTINUATION_PARENT_NONCE" /proc
}

# Child-side activation requires the child to authenticate the exact pending
# lease and parent before its first mutation.
merv_continuation_activate() {
  _mca_token=${1:-${MERV_CONTINUATION_TOKEN:-}}
  _mca_child_pid=$$
  _mca_child_start=$(merv_identity_current_start /proc 2>/dev/null) || return 1
  _mca_file=$(merv_continuation_path "$_mca_token") || return 1
  merv_continuation_authenticate_parent "$_mca_file" "$_mca_token" || return 1
  [ "$MERV_CONTINUATION_STATE" = pending ] &&
    [ "$MERV_CONTINUATION_CHILD_PID" = "$_mca_child_pid" ] &&
    [ "$MERV_CONTINUATION_CHILD_START" = "$_mca_child_start" ] || return 1
  merv_continuation_write "$_mca_file" active "$_mca_child_pid" "$_mca_child_start" || return 1
  merv_continuation_read "$_mca_file" || return 1
  [ "$MERV_CONTINUATION_STATE" = active ] &&
    [ "$MERV_CONTINUATION_CHILD_PID" = "$_mca_child_pid" ] &&
    [ "$MERV_CONTINUATION_CHILD_START" = "$_mca_child_start" ]
}

# The supervisor can publish the child's PID/start only after spawn. Retry the
# narrow pending-without-child window for at most ten seconds; malformed,
# foreign, or already-active records fail immediately.
merv_continuation_activate_wait() {
  _mcaw_token=${1:-${MERV_CONTINUATION_TOKEN:-}}
  _mcaw_tries=0
  _mcaw_file=$(merv_continuation_path "$_mcaw_token") || return 1
  while [ "$_mcaw_tries" -lt 10 ]; do
    if merv_continuation_read "$_mcaw_file"; then
      case "$MERV_CONTINUATION_STATE:$MERV_CONTINUATION_CHILD_PID:$MERV_CONTINUATION_CHILD_START" in
        pending:none:none)
          sleep 1
          _mcaw_tries=$((_mcaw_tries + 1))
          continue
          ;;
        pending:*)
          merv_continuation_activate "$_mcaw_token" && return 0
          return 1
          ;;
        active:*)
          _mcaw_start=$(merv_identity_current_start /proc 2>/dev/null || printf '')
          [ "$MERV_CONTINUATION_CHILD_PID" = "$$" ] &&
            [ "$MERV_CONTINUATION_CHILD_START" = "$_mcaw_start" ] && return 0
          return 1
          ;;
        *) return 1 ;;
      esac
    fi
    return 1
  done
  return 1
}

merv_continuation_process_state() {
  _mcps_pid=${1:-}
  _mcps_start=${2:-}
  merv_owner_v2_positive_uint "$_mcps_pid" || { printf '%s' malformed; return 0; }
  merv_owner_v2_positive_uint "$_mcps_start" || { printf '%s' malformed; return 0; }
  _mcps_proc=$(merv_owner_lock_proc_root "${MERV_OWNER_LOCK_PROC_ROOT:-/proc}" 2>/dev/null || printf '')
  [ -n "$_mcps_proc" ] && [ -d "$_mcps_proc" ] && [ -r "$_mcps_proc" ] || {
    printf '%s' unobservable
    return 0
  }
  _mcps_actual=$(merv_identity_proc_start "$_mcps_pid" "$_mcps_proc" 2>/dev/null || printf '')
  if merv_owner_v2_positive_uint "$_mcps_actual"; then
    if [ "$_mcps_actual" != "$_mcps_start" ]; then
      printf '%s' reused
    elif [ "$_mcps_proc" != /proc ] || kill -0 "$_mcps_pid" 2>/dev/null; then
      printf '%s' live
    else
      printf '%s' unobservable
    fi
  elif [ -e "$_mcps_proc/$_mcps_pid/stat" ]; then
    printf '%s' unobservable
  else
    printf '%s' dead
  fi
}

# Called only after the child and all mutation-capable descendants are known
# terminal. A child may publish terminal for itself; a live authenticated
# parent may publish it after reaping and proving the child stopped.
merv_continuation_retire() {
  _mcrt_token=${1:-${MERV_CONTINUATION_TOKEN:-}}
  _mcrt_file=$(merv_continuation_path "$_mcrt_token") || return 1
  merv_continuation_read "$_mcrt_file" || return 1
  [ "$MERV_CONTINUATION_TOKEN" = "$_mcrt_token" ] || return 1
  [ "$MERV_CONTINUATION_STATE" = active ] || return 1
  _mcrt_self_start=$(merv_identity_current_start /proc 2>/dev/null || printf '')
  if [ "$MERV_CONTINUATION_CHILD_PID" = "$$" ] &&
     [ "$MERV_CONTINUATION_CHILD_START" = "$_mcrt_self_start" ]; then
    : # Child-side terminal publication; caller certifies descendant drain.
  elif [ "$MERV_CONTINUATION_PARENT_PID" = "$$" ] &&
       merv_owner_v2_matches "$MERV_CONTINUATION_PARENT_PATH" \
         "$MERV_CONTINUATION_PARENT_PID" "$MERV_CONTINUATION_PARENT_START" \
         "$MERV_CONTINUATION_PARENT_NONCE" /proc; then
    _mcrt_child_state=$(merv_continuation_process_state \
      "$MERV_CONTINUATION_CHILD_PID" "$MERV_CONTINUATION_CHILD_START")
    case "$_mcrt_child_state" in dead|reused) ;; *) return 1 ;; esac
  else
    return 1
  fi
  merv_continuation_write "$_mcrt_file" terminal \
    "$MERV_CONTINUATION_CHILD_PID" "$MERV_CONTINUATION_CHILD_START" || return 1
  merv_continuation_read "$_mcrt_file" || return 1
  [ "$MERV_CONTINUATION_STATE" = terminal ]
}

# Cancel a pending handoff only after the supervisor has reaped the direct
# child (or proved that spawn never produced one). A bound child must also be
# authoritatively dead or PID-reused. Ambiguous state remains visible.
merv_continuation_cancel_pending() {
  _mccp_token=${1:-${MERV_CONTINUATION_TOKEN:-}}
  _mccp_reaped=${2:-}
  [ "$_mccp_reaped" = direct-child-reaped ] || return 1
  _mccp_file=$(merv_continuation_path "$_mccp_token") || return 1
  merv_continuation_read "$_mccp_file" || return 1
  [ "$MERV_CONTINUATION_TOKEN" = "$_mccp_token" ] &&
    [ "$MERV_CONTINUATION_STATE" = pending ] &&
    [ "$MERV_CONTINUATION_PARENT_PID" = "$$" ] || return 1
  merv_owner_v2_matches "$MERV_CONTINUATION_PARENT_PATH" \
    "$MERV_CONTINUATION_PARENT_PID" "$MERV_CONTINUATION_PARENT_START" \
    "$MERV_CONTINUATION_PARENT_NONCE" /proc || return 1
  case "$MERV_CONTINUATION_CHILD_PID:$MERV_CONTINUATION_CHILD_START" in
    none:none) : ;;
    *)
      _mccp_child=$(merv_continuation_process_state \
        "$MERV_CONTINUATION_CHILD_PID" "$MERV_CONTINUATION_CHILD_START")
      case "$_mccp_child" in dead|reused) : ;; *) return 1 ;; esac
      merv_continuation_write "$_mccp_file" terminal \
        "$MERV_CONTINUATION_CHILD_PID" "$MERV_CONTINUATION_CHILD_START" || return 1
      ;;
  esac
  _mccp_dir=${_mccp_file%/*}
  merv_continuation_read "$_mccp_file" || return 1
  [ "$(LC_ALL=C ls -A "$_mccp_dir" 2>/dev/null)" = lease ] || return 1
  rm -f "$_mccp_file" 2>/dev/null || return 1
  rmdir "$_mccp_dir" 2>/dev/null || return 1
  return 0
}

merv_continuation_classify_file() {
  _mccf_file=${1:-}
  if ! merv_continuation_read "$_mccf_file"; then
    printf '%s' malformed
    return 0
  fi
  _mccf_token=${MERV_CONTINUATION_TOKEN}
  _mccf_dir=${_mccf_file%/*}
  [ "${_mccf_dir##*/}" = "$_mccf_token" ] &&
    [ "${_mccf_file##*/}" = lease ] || { printf '%s' malformed; return 0; }
  case "$MERV_CONTINUATION_STATE" in
    pending) printf '%s' pending ;;
    active) printf '%s' active ;;
    terminal)
      _mccf_child=$(merv_continuation_process_state \
        "$MERV_CONTINUATION_CHILD_PID" "$MERV_CONTINUATION_CHILD_START")
      case "$_mccf_child" in
        dead|reused) printf '%s' terminal ;;
        live) printf '%s' terminal-child-live ;;
        *) printf '%s' unobservable ;;
      esac
      ;;
    *) printf '%s' malformed ;;
  esac
}

# Read-only strict inventory. Empty/missing root is idle only when its full
# path chain and nearest existing parent can be observed. Unknown entries block.
merv_continuation_quiescence() {
  _mcq_except=${1:-}
  if [ -n "$_mcq_except" ]; then
    merv_continuation_token_valid "$_mcq_except" || { printf '%s' blocking; return 0; }
    _mcq_except_file=$(merv_continuation_path "$_mcq_except") || { printf '%s' blocking; return 0; }
    merv_continuation_read "$_mcq_except_file" || { printf '%s' blocking; return 0; }
    _mcq_self_start=$(merv_identity_current_start /proc 2>/dev/null || printf '')
    [ "$MERV_CONTINUATION_TOKEN" = "$_mcq_except" ] &&
      [ "$MERV_CONTINUATION_STATE" = active ] &&
      [ "$MERV_CONTINUATION_CHILD_PID" = "$$" ] &&
      [ "$MERV_CONTINUATION_CHILD_START" = "$_mcq_self_start" ] || {
        printf '%s' blocking
        return 0
      }
  fi
  _mcq_root=$(merv_continuation_root) || { printf '%s' blocking; return 0; }
  if ! ls -ld "$_mcq_root" >/dev/null 2>&1; then
    merv_owner_lock_path_chain_safe "$_mcq_root" || { printf '%s' blocking; return 0; }
    _mcq_parent=${_mcq_root%/*}
    while [ ! -d "$_mcq_parent" ]; do
      [ "$_mcq_parent" != / ] || { printf '%s' blocking; return 0; }
      _mcq_parent=${_mcq_parent%/*}
      [ -n "$_mcq_parent" ] || _mcq_parent=/
    done
    [ ! -L "$_mcq_parent" ] && [ -r "$_mcq_parent" ] && [ -x "$_mcq_parent" ] || {
      printf '%s' blocking
      return 0
    }
    printf '%s' idle
    return 0
  fi
  merv_continuation_root_safe "$_mcq_root" || { printf '%s' blocking; return 0; }
  _mcq_busy=0
  for _mcq_entry in "$_mcq_root"/* "$_mcq_root"/.[!.]*; do
    [ -e "$_mcq_entry" ] || [ -L "$_mcq_entry" ] || continue
    [ ! -L "$_mcq_entry" ] && [ -d "$_mcq_entry" ] || { printf '%s' blocking; return 0; }
    _mcq_name=${_mcq_entry##*/}
    merv_continuation_token_valid "$_mcq_name" || { printf '%s' blocking; return 0; }
    [ -z "$_mcq_except" ] || [ "$_mcq_name" != "$_mcq_except" ] || continue
    _mcq_file="$_mcq_entry/lease"
    [ ! -L "$_mcq_file" ] && [ -f "$_mcq_file" ] || { printf '%s' blocking; return 0; }
    _mcq_state=$(merv_continuation_classify_file "$_mcq_file")
    [ "$_mcq_state" != malformed ] || { printf '%s' blocking; return 0; }
    case "$_mcq_state" in
      terminal) ;;
      pending|active|terminal-child-live) _mcq_busy=1 ;;
      *) printf '%s' blocking; return 0 ;;
    esac
    # One lease directory contains exactly one owner record.
    _mcq_entries=$(LC_ALL=C ls -A "$_mcq_entry" 2>/dev/null) || { printf '%s' blocking; return 0; }
    [ "$_mcq_entries" = lease ] || { printf '%s' blocking; return 0; }
  done
  if [ "$_mcq_busy" -eq 1 ]; then printf '%s' busy; else printf '%s' idle; fi
}

LIB_CONTINUATION_LOADED=1
