#!/bin/sh
# Read-only fail-closed inventory for Update and Full maintenance.
# Policy, wait duration, and user messages belong to caller-specific wrappers.

if [ -n "${LIB_MAINTENANCE_QUIESCE_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_action_lock.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_FULL_FENCE_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_full_fence.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_CONTINUATION_LOADED:-}" ] ||
  . "$MERV_BASE/settings/lib_continuation.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh" 2>/dev/null || return 1 2>/dev/null || exit 1
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || return 1 2>/dev/null || exit 1

if ! type merv_selftest_context_valid >/dev/null 2>&1 ||
   ! merv_selftest_context_valid; then
  MERV_QUIESCE_LOCK_ROOT=/tmp/mervlan_tmp/locks
  MERV_QUIESCE_RUNTIME_ROOT=/tmp/mervlan_tmp
  MERV_QUIESCE_STATE_ROOT=/jffs/addons/mervlan_state
  MERV_QUIESCE_SETTINGS_RECONCILE=/jffs/addons/mervlan_state/settings_reconcile.state
  MERV_QUIESCE_NODE_RECONCILE=/jffs/addons/mervlan_state/node_reconcile.pending
  MERV_QUIESCE_TRUST_LOCK=/jffs/addons/mervlan_state/ssh_trust/state.lock
  MERV_QUIESCE_DHCP_ROOT=/tmp/mervlan_tmp/locks/dhcp_hold
  MERV_QUIESCE_DHCP_LEGACY=/tmp/mervlan_tmp/locks/merv_dhcp_hold.active
  MERV_QUIESCE_OBSERVATION=/tmp/mervlan_tmp/locks/observation
  MERV_QUIESCE_NODE_JOBS=/tmp/mervlan_tmp/node_jobs
  MERV_QUIESCE_NODE_RUNS=/tmp/mervlan_tmp/results/node_runs
else
  if [ -n "${MERV_QUIESCE_LOCK_ROOT:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_LOCK_ROOT"; then unset MERV_QUIESCE_LOCK_ROOT; fi
  if [ -n "${MERV_QUIESCE_RUNTIME_ROOT:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_RUNTIME_ROOT"; then unset MERV_QUIESCE_RUNTIME_ROOT; fi
  if [ -n "${MERV_QUIESCE_STATE_ROOT:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_STATE_ROOT"; then unset MERV_QUIESCE_STATE_ROOT; fi
  if [ -n "${MERV_QUIESCE_SETTINGS_RECONCILE:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_SETTINGS_RECONCILE"; then unset MERV_QUIESCE_SETTINGS_RECONCILE; fi
  if [ -n "${MERV_QUIESCE_NODE_RECONCILE:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_NODE_RECONCILE"; then unset MERV_QUIESCE_NODE_RECONCILE; fi
  if [ -n "${MERV_QUIESCE_TRUST_LOCK:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_TRUST_LOCK"; then unset MERV_QUIESCE_TRUST_LOCK; fi
  if [ -n "${MERV_QUIESCE_DHCP_ROOT:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_DHCP_ROOT"; then unset MERV_QUIESCE_DHCP_ROOT; fi
  if [ -n "${MERV_QUIESCE_DHCP_LEGACY:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_DHCP_LEGACY"; then unset MERV_QUIESCE_DHCP_LEGACY; fi
  if [ -n "${MERV_QUIESCE_OBSERVATION:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_OBSERVATION"; then unset MERV_QUIESCE_OBSERVATION; fi
  if [ -n "${MERV_QUIESCE_NODE_JOBS:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_NODE_JOBS"; then unset MERV_QUIESCE_NODE_JOBS; fi
  if [ -n "${MERV_QUIESCE_NODE_RUNS:-}" ] && ! merv_selftest_context_path_allowed "$MERV_QUIESCE_NODE_RUNS"; then unset MERV_QUIESCE_NODE_RUNS; fi
  : "${MERV_QUIESCE_LOCK_ROOT:=/tmp/mervlan_tmp/locks}"
  : "${MERV_QUIESCE_RUNTIME_ROOT:=/tmp/mervlan_tmp}"
  : "${MERV_QUIESCE_STATE_ROOT:=/jffs/addons/mervlan_state}"
  : "${MERV_QUIESCE_SETTINGS_RECONCILE:=$MERV_QUIESCE_STATE_ROOT/settings_reconcile.state}"
  : "${MERV_QUIESCE_NODE_RECONCILE:=$MERV_QUIESCE_STATE_ROOT/node_reconcile.pending}"
  : "${MERV_QUIESCE_TRUST_LOCK:=/jffs/addons/mervlan_state/ssh_trust/state.lock}"
  : "${MERV_QUIESCE_DHCP_ROOT:=$MERV_QUIESCE_LOCK_ROOT/dhcp_hold}"
  : "${MERV_QUIESCE_DHCP_LEGACY:=$MERV_QUIESCE_LOCK_ROOT/merv_dhcp_hold.active}"
  : "${MERV_QUIESCE_OBSERVATION:=$MERV_QUIESCE_LOCK_ROOT/observation}"
  : "${MERV_QUIESCE_NODE_JOBS:=$MERV_QUIESCE_RUNTIME_ROOT/node_jobs}"
  : "${MERV_QUIESCE_NODE_RUNS:=$MERV_QUIESCE_RUNTIME_ROOT/results/node_runs}"
fi
LIB_MAINTENANCE_QUIESCE_LOADED=1

merv_quiesce_idle() {
  MERV_QUIESCE_STATUS=IDLE
  MERV_QUIESCE_REASON=idle
}

merv_quiesce_busy() {
  [ "${MERV_QUIESCE_STATUS:-IDLE}" = BLOCKING ] && return 0
  MERV_QUIESCE_STATUS=BUSY
  MERV_QUIESCE_REASON=${1:-runtime-owner-active}
}

merv_quiesce_block() {
  MERV_QUIESCE_STATUS=BLOCKING
  MERV_QUIESCE_REASON=${1:-state-unverifiable}
}

# Report absent only after validating every existing path component and the
# nearest existing parent. Dangling links, non-directory components, and
# unreadable ancestors are obstructions.
merv_quiesce_path_state() {
  _mqps_path=${1:-}
  MERV_QUIESCE_PATH_STATE=unobservable
  [ -n "$_mqps_path" ] || return 1
  merv_owner_lock_path_chain_safe "$_mqps_path" || {
    MERV_QUIESCE_PATH_STATE=obstructed
    return 0
  }
  if ls -ld "$_mqps_path" >/dev/null 2>&1; then
    if [ -L "$_mqps_path" ]; then
      MERV_QUIESCE_PATH_STATE=obstructed
    else
      MERV_QUIESCE_PATH_STATE=present
    fi
    return 0
  fi
  _mqps_parent=${_mqps_path%/*}
  [ -n "$_mqps_parent" ] || _mqps_parent=/
  while [ ! -d "$_mqps_parent" ]; do
    [ "$_mqps_parent" != / ] || return 0
    _mqps_parent=${_mqps_parent%/*}
    [ -n "$_mqps_parent" ] || _mqps_parent=/
  done
  [ ! -L "$_mqps_parent" ] && [ -r "$_mqps_parent" ] && [ -x "$_mqps_parent" ] || return 0
  MERV_QUIESCE_PATH_STATE=absent
}

merv_quiesce_owner_state() {
  _mqos_path=${1:-}
  _mqos_label=${2:-runtime-owner}
  merv_quiesce_path_state "$_mqos_path"
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) return 0 ;;
    present) [ -d "$_mqos_path" ] || { merv_quiesce_block "$_mqos_label-obstructed"; return 1; } ;;
    obstructed) merv_quiesce_block "$_mqos_label-obstructed"; return 1 ;;
    *) merv_quiesce_block "$_mqos_label-unobservable"; return 1 ;;
  esac
  _mqos_state=$(merv_owner_lock_state "$_mqos_path" /proc 2>/dev/null || printf unknown)
  case "$_mqos_state" in
    absent|dead|reused) return 0 ;;
    live|incomplete-grace) merv_quiesce_busy "$_mqos_label-active"; return 1 ;;
    *) merv_quiesce_block "$_mqos_label-$_mqos_state"; return 1 ;;
  esac
}

merv_quiesce_marker_absent() {
  _mqma_path=${1:-}
  _mqma_label=${2:-safety-marker}
  merv_quiesce_path_state "$_mqma_path"
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) return 0 ;;
    present) merv_quiesce_block "$_mqma_label-present"; return 1 ;;
    obstructed) merv_quiesce_block "$_mqma_label-obstructed"; return 1 ;;
    *) merv_quiesce_block "$_mqma_label-unobservable"; return 1 ;;
  esac
}

merv_quiesce_expected_owner() {
  _mqeo_path=${1:-}
  _mqeo_pid=${2:-}
  _mqeo_start=${3:-}
  _mqeo_nonce=${4:-}
  [ -n "$_mqeo_pid$_mqeo_start$_mqeo_nonce" ] || return 2
  merv_owner_v2_positive_uint "$_mqeo_pid" &&
    merv_owner_v2_positive_uint "$_mqeo_start" &&
    merv_owner_v2_nonce_valid "$_mqeo_nonce" || return 1
  merv_owner_v2_matches "$_mqeo_path" "$_mqeo_pid" "$_mqeo_start" \
    "$_mqeo_nonce" /proc
}

merv_quiesce_uint_value() {
  _mquv_value=${1:-}
  _mquv_zero=${2:-no}
  case "$_mquv_zero:$_mquv_value" in
    yes:0) return 0 ;;
    *) : ;;
  esac
  case "$_mquv_value" in ''|0|0[0-9]*|*[!0-9]*) return 1 ;; esac
  [ "${#_mquv_value}" -le 10 ] || return 1
  awk -v n="$_mquv_value" 'BEGIN { exit !(n + 0 <= 2147483647) }' 2>/dev/null
}

merv_quiesce_token_value() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 160 ]
}

merv_quiesce_readable_record() {
  _mqrr_path=${1:-}
  _mqrr_max=${2:-2048}
  [ ! -L "$_mqrr_path" ] && [ -f "$_mqrr_path" ] && [ -r "$_mqrr_path" ] || return 1
  _mqrr_size=$(wc -c < "$_mqrr_path" 2>/dev/null | awk '{print $1}') || return 1
  case "$_mqrr_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_mqrr_size" -le "$_mqrr_max" ] 2>/dev/null
}

merv_quiesce_private_record() {
  _mqpr_path=${1:-}
  _mqpr_max=${2:-2048}
  merv_quiesce_readable_record "$_mqpr_path" "$_mqpr_max" || return 1
  _mqpr_mode=$(LC_ALL=C ls -ldn "$_mqpr_path" 2>/dev/null | awk 'NR == 1 { print $1 }') || return 1
  [ "$_mqpr_mode" = -rw------- ]
}

merv_quiesce_uint_file() {
  _mquf_file=${1:-}
  _mquf_zero=${2:-no}
  merv_quiesce_readable_record "$_mquf_file" 64 || return 1
  _mquf_value=$(awk '
    NR == 1 && $0 ~ /^(0|[1-9][0-9]*)$/ && length($0) <= 10 && $0 + 0 <= 2147483647 { value = $0; next }
    { bad = 1 }
    END { if (NR != 1 || bad) exit 1; print value }
  ' "$_mquf_file" 2>/dev/null) || return 1
  merv_quiesce_uint_value "$_mquf_value" "$_mquf_zero" || return 1
  MERV_QUIESCE_UINT_FILE_VALUE=$_mquf_value
}

merv_quiesce_node_list_file() {
  _mqnf_file=${1:-}
  [ ! -L "$_mqnf_file" ] && [ -f "$_mqnf_file" ] && [ -r "$_mqnf_file" ] || return 1
  awk '
    function ipv4(s, a, n, i, part) {
      n = split(s, a, ".")
      if (n != 4) return 0
      for (i = 1; i <= 4; i++) {
        part = a[i]
        if (part !~ /^[0-9]+$/ || length(part) > 3) return 0
        if (length(part) > 1 && substr(part, 1, 1) == "0") return 0
        if (part + 0 > 255) return 0
      }
      return 1
    }
    NF == 0 { next }
    NF != 2 || $1 !~ /^(10|[1-9])$/ || !ipv4($2) { exit 2 }
    seen_node[$1]++ || seen_ip[$2]++ { exit 2 }
    { count++; if (count > 10) exit 2 }
    END { if (failed) exit 2 }
  ' "$_mqnf_file" >/dev/null 2>&1
}

merv_quiesce_check_primary_owners() {
  _mqc_mpid=${1:-}
  _mqc_mstart=${2:-}
  _mqc_mnonce=${3:-}
  _mqc_fpid=${4:-}
  _mqc_fstart=${5:-}
  _mqc_fnonce=${6:-}
  _mqc_mlock=$(merv_update_maintenance_lock_path 2>/dev/null) || {
    merv_quiesce_block maintenance-owner-path-unverifiable
    return 1
  }
  _mqc_fence=$(merv_full_fence_path 2>/dev/null) || {
    merv_quiesce_block full-fence-path-unverifiable
    return 1
  }
  MERV_QUIESCE_EXPECTED_M_PID=$_mqc_mpid
  MERV_QUIESCE_EXPECTED_M_START=$_mqc_mstart
  MERV_QUIESCE_EXPECTED_M_NONCE=$_mqc_mnonce

  if [ -n "$_mqc_mpid$_mqc_mstart$_mqc_mnonce" ]; then
    if merv_quiesce_expected_owner "$_mqc_mlock" "$_mqc_mpid" "$_mqc_mstart" "$_mqc_mnonce"; then
      :
    else
      _mqc_state=$(merv_update_maintenance_lock_state 2>/dev/null || printf unknown)
      case "$_mqc_state" in live) merv_quiesce_busy maintenance-owner-changed ;; *) merv_quiesce_block maintenance-owner-unverified ;; esac
      return 1
    fi
  else
    merv_quiesce_owner_state "$_mqc_mlock" maintenance-owner || return 1
  fi

  if [ -n "$_mqc_fpid$_mqc_fstart$_mqc_fnonce" ]; then
    if ! merv_full_fence_owner_is "$_mqc_fence" "$_mqc_fpid" "$_mqc_fstart" "$_mqc_fnonce"; then
      merv_quiesce_block full-fence-owner-unverified
      return 1
    fi
  else
    _mqc_fstate=$(merv_full_fence_classify "$_mqc_fence" 2>/dev/null || printf unknown)
    case "$_mqc_fstate" in
      absent) ;;
      live) merv_quiesce_busy full-fence-active; return 1 ;;
      *) merv_quiesce_block "full-fence-$_mqc_fstate"; return 1 ;;
    esac
  fi
  return 0
}

# Explicit product-generated debounce/health state. These epochs convey no
# mutation authority: heal owns vlan_event.lock and performs post-owner F/M
# admission; manager owns R/L throughout service restart; MAC queueing also
# reaches the guarded heal entry. A partial publication blocks this scan.
merv_quiesce_informational_epoch() {
  _mqie_file=$1
  merv_quiesce_readable_record "$_mqie_file" 21 || return 1
  # Require exactly one canonical decimal epoch with its producer newline.
  # Byte comparison also rejects NUL, CR, extra lines and missing newline.
  _mqie_epoch=$(cat "$_mqie_file" 2>/dev/null) || return 1
  case "$_mqie_epoch" in 0|[1-9]*) ;; *) return 1 ;; esac
  case "$_mqie_epoch" in *[!0-9]*|'') return 1 ;; esac
  [ "${#_mqie_epoch}" -le 20 ] || return 1
  [ "$(wc -c < "$_mqie_file")" = "$(printf '%s\n' "$_mqie_epoch" | wc -c)" ] || return 1
  [ "$_mqie_epoch" = 0 ] || [ "${_mqie_epoch#0}" = "$_mqie_epoch" ]
}

# Historical observation diagnostics are inert only in a recognized producer
# format. The operation/generation are bound to the explicit filename family.
merv_quiesce_observation_fault() {
  _mqof_file=$1; _mqof_name=${1##*/}
  merv_quiesce_readable_record "$_mqof_file" 128 || return 1
  awk -F= -v name="$_mqof_name" '
    BEGIN {n=split(name,a,"-"); if(n!=4 || a[1]!~/^(snapshot|collection)$/)bad=1
      for(i=2;i<=4;i++)if(a[i]!~/^(0|[1-9][0-9]*)$/ || length(a[i])>10 || a[i]+0>2147483647)bad=1
      if(a[4]=="0")bad=1}
    NF!=2 || seen[$1]++ {bad=1}
    $1=="operation" {if($2!=a[1])bad=1;next}
    $1=="generation" {if($2!=a[2])bad=1;next}
    $1=="epoch" {if($2!~/^(0|[1-9][0-9]*)$/ || length($2)>10 || $2+0>2147483647)bad=1;next}
    {bad=1}
    END {exit (bad || NR!=3 || !seen["operation"] || !seen["generation"] || !seen["epoch"])}
  ' "$_mqof_file"
}

merv_quiesce_scan_locks() {
  _mqsl_root=$MERV_QUIESCE_LOCK_ROOT
  merv_quiesce_path_state "$_mqsl_root"
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) return 0 ;;
    present) [ -d "$_mqsl_root" ] || { merv_quiesce_block lock-root-obstructed; return 1; } ;;
    obstructed) merv_quiesce_block lock-root-obstructed; return 1 ;;
    *) merv_quiesce_block lock-root-unobservable; return 1 ;;
  esac
  for _mqsl_entry in "$_mqsl_root"/* "$_mqsl_root"/.[!.]* "$_mqsl_root"/..?*; do
    [ -e "$_mqsl_entry" ] || [ -L "$_mqsl_entry" ] || continue
    _mqsl_name=${_mqsl_entry##*/}
    case "$_mqsl_name" in
      .mervlan_maintenance.lock.dead.*|.mervlan_maintenance.lock.reused.*|\
      .mervlan_action.lock.dead.*|.mervlan_action.lock.reused.*|\
      .mervlan_manager.lock.dead.*|.mervlan_manager.lock.reused.*|\
      .vlan_event.lock.dead.*|.vlan_event.lock.reused.*|\
      .execute_nodes.lock.dead.*|.execute_nodes.lock.reused.*|\
      .client_collect.lock.dead.*|.client_collect.lock.reused.*|\
      .sync_nodes.lock.dead.*|.sync_nodes.lock.reused.*|\
      .mac_client_meta.lock.dead.*|.mac_client_meta.lock.reused.*|\
      .mac_snapshot.lock.dead.*|.mac_snapshot.lock.reused.*|\
      .merv_boot_shield.transient.lock.dead.*|.merv_boot_shield.transient.lock.reused.*|\
      .[A-Za-z0-9._-]*.lock.dead.*|.[A-Za-z0-9._-]*.lock.reused.*|\
      .state.lock.dead.*|.state.lock.reused.*)
        # Owner-lock reclamation preserves an authenticated dead/reused
        # directory under a sibling tombstone for inspection. Q accepts only
        # the known lock families and still classifies the retained owner;
        # live, malformed, or obstructed tombstones block.
        merv_quiesce_owner_state "$_mqsl_entry" quarantined-owner || return 1
        ;;
      mervlan_maintenance.lock|mervlan_action.lock|mervlan_manager.lock|vlan_event.lock|execute_nodes.lock|client_collect.lock|sync_nodes.lock|mac_client_meta.lock|mac_snapshot.lock|merv_boot_shield.transient.lock|observation/request.lock|observation/worker.lock|dhcp_hold/state.lock|*.lock)
        if [ "$_mqsl_name" = mervlan_maintenance.lock ] &&
           [ -n "${MERV_QUIESCE_EXPECTED_M_PID:-}${MERV_QUIESCE_EXPECTED_M_START:-}${MERV_QUIESCE_EXPECTED_M_NONCE:-}" ] &&
           merv_quiesce_expected_owner "$_mqsl_entry" \
             "$MERV_QUIESCE_EXPECTED_M_PID" "$MERV_QUIESCE_EXPECTED_M_START" \
             "$MERV_QUIESCE_EXPECTED_M_NONCE"; then
          continue
        fi
        if [ "$_mqsl_entry" = /tmp/mervlan_tmp/locks/mervlan_action.lock ] &&
           merv_action_lock_parent_owned "$_mqsl_entry"; then
          continue
        fi
        merv_quiesce_owner_state "$_mqsl_entry" "owner-$(_mqsl_safe_name=$(printf '%s' "$_mqsl_name" | tr -cd 'A-Za-z0-9._-'); printf '%s' "$_mqsl_safe_name")" || return 1
        ;;
      native_auth.snapshot.*)
        # Manager service-restart transaction data, never evidence of idle.
        merv_quiesce_block native-auth-transaction-present
        return 1
        ;;
      dhcp_hold|observation) [ -d "$_mqsl_entry" ] && [ ! -L "$_mqsl_entry" ] || { merv_quiesce_block "runtime-dir-$_mqsl_name-obstructed"; return 1; } ;;
      heal_event.last|vlan_event.last|vlan_heal.last|vlan_health_ok.last|vlan_last_mismatch.last|mac_precondition_heal.last|self_restart.marker)
        merv_quiesce_informational_epoch "$_mqsl_entry" || { merv_quiesce_block "informational-state-$_mqsl_name-invalid"; return 1; }
        ;;
      merv_boot_shield.active|merv_boot_shield.ready|merv_boot_shield.handoff|merv_boot_shield.pid|merv_boot_shield.pid.start|merv_dhcp_hold.active)
        merv_quiesce_block "safety-marker-$_mqsl_name"
        return 1
        ;;
      *) merv_quiesce_block "unknown-lock-entry-$_mqsl_name"; return 1 ;;
    esac
  done
  return 0
}

merv_quiesce_observation_state() {
  _mqos_root=$MERV_QUIESCE_OBSERVATION
  merv_quiesce_path_state "$_mqos_root"
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) return 0 ;;
    present) [ -d "$_mqos_root" ] && [ ! -L "$_mqos_root" ] || { merv_quiesce_block observation-root-obstructed; return 1; } ;;
    obstructed) merv_quiesce_block observation-root-obstructed; return 1 ;;
    *) merv_quiesce_block observation-root-unobservable; return 1 ;;
  esac
  for _mqos_entry in "$_mqos_root"/* "$_mqos_root"/.[!.]* "$_mqos_root"/..?*; do
    [ -e "$_mqos_entry" ] || [ -L "$_mqos_entry" ] || continue
    _mqos_name=${_mqos_entry##*/}
    case "$_mqos_name" in
      .request.lock.dead.*|.request.lock.reused.*|\
      .worker.lock.dead.*|.worker.lock.reused.*)
        merv_quiesce_owner_state "$_mqos_entry" observation-quarantined-owner || return 1
        ;;
      request.lock|worker.lock)
        merv_quiesce_owner_state "$_mqos_entry" "observation-$_mqos_name" || return 1
        ;;
      request.state)
        merv_quiesce_readable_record "$_mqos_entry" 256 || { merv_quiesce_block observation-state-unreadable; return 1; }
        _mqos_check=$(awk -F= '
          BEGIN { a["snapshot_requested_generation"]=1; a["snapshot_completed_generation"]=1; a["collection_requested_generation"]=1; a["collection_completed_generation"]=1; want=4 }
          { if (NF!=2 || !($1 in a) || seen[$1]++) exit 2; if ($2 !~ /^(0|[1-9][0-9]*)$/ || length($2)>10 || $2+0>2147483647) exit 2; count++ }
          END { if (count!=want) exit 2; for (k in a) if (seen[k]!=1) exit 2 }
        ' "$_mqos_entry" 2>/dev/null) || { merv_quiesce_block observation-generation-malformed; return 1; }
        _mqos_sr=$(sed -n 's/^snapshot_requested_generation=//p' "$_mqos_entry" 2>/dev/null)
        _mqos_sc=$(sed -n 's/^snapshot_completed_generation=//p' "$_mqos_entry" 2>/dev/null)
        _mqos_cr=$(sed -n 's/^collection_requested_generation=//p' "$_mqos_entry" 2>/dev/null)
        _mqos_cc=$(sed -n 's/^collection_completed_generation=//p' "$_mqos_entry" 2>/dev/null)
        [ "$_mqos_sr" -le "$_mqos_sc" ] 2>/dev/null &&
          [ "$_mqos_cr" -le "$_mqos_cc" ] 2>/dev/null || { merv_quiesce_busy observation-generation-pending; return 1; }
        ;;
      faults)
        [ -d "$_mqos_entry" ] && [ ! -L "$_mqos_entry" ] || { merv_quiesce_block observation-faults-obstructed; return 1; }
        for _mqos_fault in "$_mqos_entry"/* "$_mqos_entry"/.[!.]* "$_mqos_entry"/..?*; do
          [ -e "$_mqos_fault" ] || [ -L "$_mqos_fault" ] || continue
          merv_quiesce_observation_fault "$_mqos_fault" || { merv_quiesce_block observation-fault-invalid; return 1; }
        done
        ;;
      snapshot.reset.generation)
        merv_quiesce_readable_record "$_mqos_entry" 64 || { merv_quiesce_block observation-reset-obstructed; return 1; }
        _mqos_reset=$(cat "$_mqos_entry" 2>/dev/null || printf '')
        case "$_mqos_reset" in ''|*[!0-9]*|0[0-9]*) merv_quiesce_block observation-reset-malformed; return 1 ;; esac
        [ "${#_mqos_reset}" -le 10 ] && [ "$_mqos_reset" -le 2147483647 ] 2>/dev/null || { merv_quiesce_block observation-reset-malformed; return 1; }
        [ "$_mqos_reset" = 0 ] || { merv_quiesce_busy observation-reset-pending; return 1; }
        ;;
      .request.state.tmp.*) merv_quiesce_block observation-partial-publication; return 1 ;;
      *) merv_quiesce_block "unknown-observation-entry-$_mqos_name"; return 1 ;;
    esac
  done
  return 0
}

_merv_quiesce_dhcp_id_valid() {
  case "${1:-}" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 255 ]
}

_merv_quiesce_dhcp_epoch_valid() {
  merv_quiesce_uint_value "${1:-}" "${2:-no}"
}

_merv_quiesce_dhcp_line_file() {
  local _mqdl_path="${1:-}" _mqdl_max="${2:-256}" _mqdl_value _mqdl_size
  merv_quiesce_readable_record "$_mqdl_path" "$_mqdl_max" || return 1
  _mqdl_value=$(cat "$_mqdl_path" 2>/dev/null) || return 1
  case "$_mqdl_value" in *'
'*) return 1 ;; esac
  _mqdl_size=$(wc -c < "$_mqdl_path" 2>/dev/null | awk '{print $1}') || return 1
  case "$_mqdl_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_mqdl_size" -eq "$((${#_mqdl_value} + 1))" ] 2>/dev/null || return 1
  MERV_QUIESCE_DHCP_LINE=$_mqdl_value
  return 0
}

_merv_quiesce_dhcp_handoff_completed() {
  local _mqhc_dir="${1:-}" _mqhc_name _mqhc_child _mqhc_count=0
  local _mqhc_id _mqhc_parent_type _mqhc_parent_run _mqhc_parent_ref
  local _mqhc_child_type _mqhc_requested _mqhc_ack_run _mqhc_ack_ref
  local _mqhc_ack_epoch _mqhc_completed _mqhc_retired _mqhc_verify
  local _mqhc_owner_path _mqhc_owner_state
  [ ! -L "$_mqhc_dir" ] && [ -d "$_mqhc_dir" ] || return 1
  _mqhc_name=${_mqhc_dir##*/}
  _merv_quiesce_dhcp_id_valid "$_mqhc_name" || return 1

  # A terminal record has the exact fields published by request, ack,
  # verification, and parent retirement. Hidden temp fields and extensions
  # remain unclassified and therefore fail closed.
  for _mqhc_child in "$_mqhc_dir"/* "$_mqhc_dir"/.[!.]* "$_mqhc_dir"/..?*; do
    [ -e "$_mqhc_child" ] || [ -L "$_mqhc_child" ] || continue
    _mqhc_count=$((_mqhc_count + 1))
    _mqhc_child=${_mqhc_child##*/}
    case "$_mqhc_child" in
      handoff_id|parent_owner_type|parent_run_id|parent_token_reference|\
      child_owner_type|requested_epoch|handoff_state|ready|\
      ack_child_run_id|ack_child_token_reference|ack_epoch|\
      verification_id|completed_epoch|parent_retired_epoch) ;;
      *) return 1 ;;
    esac
    _merv_quiesce_dhcp_line_file "$_mqhc_dir/$_mqhc_child" 256 || return 1
  done
  [ "$_mqhc_count" -eq 14 ] || return 1

  for _mqhc_child in handoff_id parent_owner_type parent_run_id parent_token_reference \
    child_owner_type requested_epoch handoff_state ready ack_child_run_id \
    ack_child_token_reference ack_epoch verification_id completed_epoch parent_retired_epoch; do
    [ -f "$_mqhc_dir/$_mqhc_child" ] && [ ! -L "$_mqhc_dir/$_mqhc_child" ] || return 1
  done
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/handoff_id" 256 || return 1
  _mqhc_id=$MERV_QUIESCE_DHCP_LINE
  [ "$_mqhc_id" = "$_mqhc_name" ] || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/parent_owner_type" 256 || return 1
  _mqhc_parent_type=$MERV_QUIESCE_DHCP_LINE
  case "$_mqhc_parent_type" in boot-watchdog|manager|heal|recovery) ;; *) return 1 ;; esac
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/parent_run_id" 256 || return 1
  _mqhc_parent_run=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_id_valid "$_mqhc_parent_run" || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/parent_token_reference" 256 || return 1
  _mqhc_parent_ref=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_id_valid "$_mqhc_parent_ref" || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/child_owner_type" 256 || return 1
  _mqhc_child_type=$MERV_QUIESCE_DHCP_LINE
  case "$_mqhc_child_type" in boot-watchdog|manager|heal|recovery) ;; *) return 1 ;; esac
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/requested_epoch" 256 || return 1
  _mqhc_requested=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_epoch_valid "$_mqhc_requested" no || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/handoff_state" 256 || return 1
  [ "$MERV_QUIESCE_DHCP_LINE" = completed ] || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/ready" 256 || return 1
  [ "$MERV_QUIESCE_DHCP_LINE" = 1 ] || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/ack_child_run_id" 256 || return 1
  _mqhc_ack_run=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_id_valid "$_mqhc_ack_run" || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/ack_child_token_reference" 256 || return 1
  _mqhc_ack_ref=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_id_valid "$_mqhc_ack_ref" || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/ack_epoch" 256 || return 1
  _mqhc_ack_epoch=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_epoch_valid "$_mqhc_ack_epoch" no || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/verification_id" 256 || return 1
  _mqhc_verify=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_id_valid "$_mqhc_verify" || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/completed_epoch" 256 || return 1
  _mqhc_completed=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_epoch_valid "$_mqhc_completed" no || return 1
  _merv_quiesce_dhcp_line_file "$_mqhc_dir/parent_retired_epoch" 256 || return 1
  _mqhc_retired=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_epoch_valid "$_mqhc_retired" no || return 1

  # Completed is terminal only after the producer recorded parent retirement
  # and both referenced owners are authoritatively absent.
  for _mqhc_owner_path in \
    "$MERV_QUIESCE_DHCP_ROOT/owners/$_mqhc_parent_ref" \
    "$MERV_QUIESCE_DHCP_ROOT/owners/$_mqhc_ack_ref"; do
    merv_quiesce_path_state "$_mqhc_owner_path"
    _mqhc_owner_state=$MERV_QUIESCE_PATH_STATE
    [ "$_mqhc_owner_state" = absent ] || return 1
  done
  MERV_QUIESCE_DHCP_HANDOFF_ID=$_mqhc_id
  MERV_QUIESCE_DHCP_HANDOFF_PARENT_TYPE=$_mqhc_parent_type
  MERV_QUIESCE_DHCP_HANDOFF_CHILD_TYPE=$_mqhc_child_type
  return 0
}

_merv_quiesce_dhcp_heal_pending() {
  local _mqhp_file="${1:-}" _mqhp_lines _mqhp_newlines
  local _mqhp_reason _mqhp_epoch _mqhp_attached _mqhp_hand
  merv_quiesce_readable_record "$_mqhp_file" 1024 || return 1
  _mqhp_lines=$(awk 'END { print NR }' "$_mqhp_file" 2>/dev/null) || return 1
  _mqhp_newlines=$(wc -l < "$_mqhp_file" 2>/dev/null | awk '{print $1}') || return 1
  [ "$_mqhp_lines" = "$_mqhp_newlines" ] || return 1
  case "$_mqhp_lines" in 2|3) ;; *) return 1 ;; esac
  _mqhp_reason=$(awk 'NR == 1 { if ($0 ~ /^reason=[A-Za-z0-9._-]+$/) { sub(/^reason=/, ""); value=$0 } else bad=1 } END { if (NR < 1 || bad) exit 1; print value }' "$_mqhp_file" 2>/dev/null) || return 1
  _merv_quiesce_dhcp_id_valid "$_mqhp_reason" || return 1
  _mqhp_epoch=$(awk 'NR == 2 { if ($0 ~ /^requested_epoch=(0|[1-9][0-9]*)$/) { sub(/^requested_epoch=/, ""); value=$0 } else bad=1 } END { if (NR < 2 || bad) exit 1; print value }' "$_mqhp_file" 2>/dev/null) || return 1
  _merv_quiesce_dhcp_epoch_valid "$_mqhp_epoch" yes || return 1
  [ "$_mqhp_lines" -eq 3 ] || return 1
  _mqhp_attached=$(awk 'NR == 3 { if ($0 ~ /^attached_handoff=[A-Za-z0-9._-]+$/) { sub(/^attached_handoff=/, ""); value=$0 } else bad=1 } END { if (NR < 3 || bad) exit 1; print value }' "$_mqhp_file" 2>/dev/null) || return 1
  _merv_quiesce_dhcp_id_valid "$_mqhp_attached" || return 1
  _mqhp_hand="$MERV_QUIESCE_DHCP_ROOT/handoffs/$_mqhp_attached"
  _merv_quiesce_dhcp_handoff_completed "$_mqhp_hand" || return 1
  [ "$MERV_QUIESCE_DHCP_HANDOFF_ID" = "$_mqhp_attached" ] &&
    [ "$MERV_QUIESCE_DHCP_HANDOFF_PARENT_TYPE" = heal ] &&
    [ "$MERV_QUIESCE_DHCP_HANDOFF_CHILD_TYPE" = manager ]
}

_merv_quiesce_dhcp_state_lock() {
  local _mqsl_dir="${1:-}" _mqsl_child _mqsl_count=0
  local _mqsl_pid _mqsl_start _mqsl_created _mqsl_nonce _mqsl_state
  [ ! -L "$_mqsl_dir" ] && [ -d "$_mqsl_dir" ] || {
    merv_quiesce_block dhcp-state-lock-obstructed; return 1;
  }
  for _mqsl_child in "$_mqsl_dir"/* "$_mqsl_dir"/.[!.]* "$_mqsl_dir"/..?*; do
    [ -e "$_mqsl_child" ] || [ -L "$_mqsl_child" ] || continue
    _mqsl_count=$((_mqsl_count + 1))
    _mqsl_child=${_mqsl_child##*/}
    case "$_mqsl_child" in pid|proc_start_time|created_epoch|owner_nonce) ;;
      *) merv_quiesce_block dhcp-state-lock-unknown-field; return 1 ;;
    esac
    _merv_quiesce_dhcp_line_file "$_mqsl_dir/$_mqsl_child" 256 || {
      merv_quiesce_block dhcp-state-lock-field-malformed; return 1;
    }
  done
  [ "$_mqsl_count" -eq 4 ] || { merv_quiesce_block dhcp-state-lock-incomplete; return 1; }
  for _mqsl_child in pid proc_start_time created_epoch owner_nonce; do
    [ -f "$_mqsl_dir/$_mqsl_child" ] && [ ! -L "$_mqsl_dir/$_mqsl_child" ] || {
      merv_quiesce_block dhcp-state-lock-incomplete; return 1;
    }
  done
  _merv_quiesce_dhcp_line_file "$_mqsl_dir/pid" 256 || { merv_quiesce_block dhcp-state-lock-malformed; return 1; }
  _mqsl_pid=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_epoch_valid "$_mqsl_pid" no || { merv_quiesce_block dhcp-state-lock-malformed; return 1; }
  _merv_quiesce_dhcp_line_file "$_mqsl_dir/proc_start_time" 256 || { merv_quiesce_block dhcp-state-lock-malformed; return 1; }
  _mqsl_start=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_epoch_valid "$_mqsl_start" no || { merv_quiesce_block dhcp-state-lock-malformed; return 1; }
  _merv_quiesce_dhcp_line_file "$_mqsl_dir/created_epoch" 256 || { merv_quiesce_block dhcp-state-lock-malformed; return 1; }
  _mqsl_created=$MERV_QUIESCE_DHCP_LINE
  _merv_quiesce_dhcp_epoch_valid "$_mqsl_created" no || { merv_quiesce_block dhcp-state-lock-malformed; return 1; }
  _merv_quiesce_dhcp_line_file "$_mqsl_dir/owner_nonce" 256 || { merv_quiesce_block dhcp-state-lock-malformed; return 1; }
  _mqsl_nonce=$MERV_QUIESCE_DHCP_LINE
  case "$_mqsl_nonce" in ''|*[!A-Za-z0-9._:-]*) merv_quiesce_block dhcp-state-lock-malformed; return 1 ;; esac
  [ "${#_mqsl_nonce}" -le 160 ] || { merv_quiesce_block dhcp-state-lock-malformed; return 1; }
  _mqsl_state=$(merv_continuation_process_state "$_mqsl_pid" "$_mqsl_start")
  case "$_mqsl_state" in
    live) merv_quiesce_busy dhcp-state-lock-active; return 1 ;;
    dead|reused) merv_quiesce_block dhcp-state-lock-stale; return 1 ;;
    *) merv_quiesce_block dhcp-state-lock-identity-unknown; return 1 ;;
  esac
}

_merv_quiesce_dhcp_state_lock_tombstone() {
  local _mqst_dir="${1:-}" _mqst_kind="${2:-}" _mqst_name _mqst_suffix
  local _mqst_epoch _mqst_nonce _mqst_child _mqst_count=0 _mqst_state
  local _mqst_pid='' _mqst_start='' _mqst_created='' _mqst_owner_nonce=''
  [ ! -L "$_mqst_dir" ] && [ -d "$_mqst_dir" ] || return 1
  _mqst_name=${_mqst_dir##*/}
  case "$_mqst_kind" in stale|incomplete-stale) ;; *) return 1 ;; esac
  _mqst_suffix=${_mqst_name#"state.lock.$_mqst_kind."}
  [ "$_mqst_suffix" != "$_mqst_name" ] || return 1
  _mqst_epoch=${_mqst_suffix%%.*}
  [ "$_mqst_suffix" != "$_mqst_epoch" ] || return 1
  _mqst_nonce=${_mqst_suffix#"$_mqst_epoch".}
  _merv_quiesce_dhcp_epoch_valid "$_mqst_epoch" no || return 1
  case "$_mqst_nonce" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#_mqst_nonce}" -le 160 ] || return 1
  for _mqst_child in "$_mqst_dir"/* "$_mqst_dir"/.[!.]* "$_mqst_dir"/..?*; do
    [ -e "$_mqst_child" ] || [ -L "$_mqst_child" ] || continue
    _mqst_count=$((_mqst_count + 1))
    _mqst_child=${_mqst_child##*/}
    case "$_mqst_child" in pid|proc_start_time|created_epoch|owner_nonce) ;;
      *) return 1 ;;
    esac
    _merv_quiesce_dhcp_line_file "$_mqst_dir/$_mqst_child" 256 || return 1
    case "$_mqst_child" in
      pid) _mqst_pid=$MERV_QUIESCE_DHCP_LINE ;;
      proc_start_time) _mqst_start=$MERV_QUIESCE_DHCP_LINE ;;
      created_epoch) _mqst_created=$MERV_QUIESCE_DHCP_LINE ;;
      owner_nonce) _mqst_owner_nonce=$MERV_QUIESCE_DHCP_LINE ;;
    esac
  done
  if [ "$_mqst_kind" = stale ]; then
    [ "$_mqst_count" -eq 4 ] || return 1
    _merv_quiesce_dhcp_epoch_valid "$_mqst_pid" no &&
      _merv_quiesce_dhcp_epoch_valid "$_mqst_start" no &&
      _merv_quiesce_dhcp_epoch_valid "$_mqst_created" no || return 1
    case "$_mqst_owner_nonce" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
    _mqst_state=$(merv_continuation_process_state "$_mqst_pid" "$_mqst_start")
    case "$_mqst_state" in dead|reused) return 0 ;; *) return 1 ;; esac
  fi
  # incomplete-stale is published only after an incomplete lock publication
  # exceeded the producer's stale threshold. It may contain any subset of the
  # four direct metadata files; a complete valid owner cannot use this tag.
  if [ "$_mqst_count" -eq 4 ] &&
     _merv_quiesce_dhcp_epoch_valid "$_mqst_pid" no &&
     _merv_quiesce_dhcp_epoch_valid "$_mqst_start" no &&
     _merv_quiesce_dhcp_epoch_valid "$_mqst_created" no &&
     case "$_mqst_owner_nonce" in ''|*[!A-Za-z0-9._:-]*) false ;; *) true ;; esac; then
    return 1
  fi
  return 0
}

merv_quiesce_dhcp_state() {
  merv_quiesce_marker_absent "$MERV_QUIESCE_DHCP_LEGACY" dhcp-legacy-hold || return 1
  _mqds_root=$MERV_QUIESCE_DHCP_ROOT
  merv_quiesce_path_state "$_mqds_root"
  _mqds_root_state=$MERV_QUIESCE_PATH_STATE
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) : ;;
    present) [ -d "$_mqds_root" ] && [ ! -L "$_mqds_root" ] || { merv_quiesce_block dhcp-state-root-obstructed; return 1; } ;;
    obstructed) merv_quiesce_block dhcp-state-root-obstructed; return 1 ;;
    *) merv_quiesce_block dhcp-state-root-unobservable; return 1 ;;
  esac
  if [ "$_mqds_root_state" = present ]; then
    for _mqds_entry in "$_mqds_root"/* "$_mqds_root"/.[!.]* "$_mqds_root"/..?*; do
      [ -e "$_mqds_entry" ] || [ -L "$_mqds_entry" ] || continue
      _mqds_name=${_mqds_entry##*/}
      case "$_mqds_name" in
        state.lock.stale.*)
          _merv_quiesce_dhcp_state_lock_tombstone "$_mqds_entry" stale || {
            merv_quiesce_block dhcp-state-lock-tombstone-invalid; return 1;
          }
          ;;
        state.lock.incomplete-stale.*)
          _merv_quiesce_dhcp_state_lock_tombstone "$_mqds_entry" incomplete-stale || {
            merv_quiesce_block dhcp-state-lock-tombstone-invalid; return 1;
          }
          ;;
        state.lock.incomplete.*)
          merv_quiesce_block dhcp-state-lock-incomplete-retained; return 1
          ;;
        state.lock)
          _merv_quiesce_dhcp_state_lock "$_mqds_entry" || return 1
          ;;
        handoffs)
          [ -d "$_mqds_entry" ] && [ ! -L "$_mqds_entry" ] || { merv_quiesce_block "dhcp-$_mqds_name-obstructed"; return 1; }
          for _mqds_child in "$_mqds_entry"/* "$_mqds_entry"/.[!.]* "$_mqds_entry"/..?*; do
            [ -e "$_mqds_child" ] || [ -L "$_mqds_child" ] || continue
            _merv_quiesce_dhcp_handoff_completed "$_mqds_child" || {
              merv_quiesce_block dhcp-handoff-active-or-invalid; return 1;
            }
          done
          ;;
        heal.pending)
          _merv_quiesce_dhcp_heal_pending "$_mqds_entry" || {
            merv_quiesce_block dhcp-heal-pending-unresolved; return 1;
          }
          ;;
        faults|intents|owners|failsafe)
          [ -d "$_mqds_entry" ] && [ ! -L "$_mqds_entry" ] || { merv_quiesce_block "dhcp-$_mqds_name-obstructed"; return 1; }
          for _mqds_child in "$_mqds_entry"/* "$_mqds_entry"/.[!.]* "$_mqds_entry"/..?*; do
            [ -e "$_mqds_child" ] || [ -L "$_mqds_child" ] || continue
            merv_quiesce_block "dhcp-$_mqds_name-state-present"
            return 1
          done
          ;;
        recovery.pending) merv_quiesce_block dhcp-recovery-pending; return 1 ;;
        *) merv_quiesce_block "unknown-dhcp-state-$_mqds_name"; return 1 ;;
      esac
    done
  fi
  if type merv_dhcp_hold_required >/dev/null 2>&1 && merv_dhcp_hold_required; then
    merv_quiesce_block dhcp-hold-required
    return 1
  fi
  type merv_dhcp_hold_rules_absent >/dev/null 2>&1 || { merv_quiesce_block dhcp-rule-classifier-missing; return 1; }
  merv_dhcp_hold_rules_absent >/dev/null 2>&1 || { merv_quiesce_block dhcp-rules-unresolved; return 1; }
  return 0
}

merv_quiesce_reconciliation_state() {
  _mqrs_file=$MERV_QUIESCE_SETTINGS_RECONCILE
  merv_quiesce_path_state "$_mqrs_file"
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) ;;
    present)
      [ ! -L "$_mqrs_file" ] && [ -f "$_mqrs_file" ] && [ -r "$_mqrs_file" ] || { merv_quiesce_block settings-reconcile-obstructed; return 1; }
      [ -n "${LIB_SETTINGS_RECONCILE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_settings_reconcile.sh" 2>/dev/null || { merv_quiesce_block settings-reconcile-library-missing; return 1; }
      MERV_STATE_ROOT=$MERV_QUIESCE_STATE_ROOT
      MERV_SETTINGS_RECONCILE_FILE=$_mqrs_file
      merv_settings_reconcile_read || { merv_quiesce_block settings-reconcile-malformed; return 1; }
      case "$MERV_SETTINGS_RECONCILE_STATUS" in
        verified|blocked|paused) ;;
        pending|queued|running|retry) merv_quiesce_busy settings-reconcile-queued; return 1 ;;
        *) merv_quiesce_block settings-reconcile-status-unknown; return 1 ;;
      esac
      ;;
    obstructed) merv_quiesce_block settings-reconcile-obstructed; return 1 ;;
    *) merv_quiesce_block settings-reconcile-unobservable; return 1 ;;
  esac
  _mqrs_node=$MERV_QUIESCE_NODE_RECONCILE
  merv_quiesce_path_state "$_mqrs_node"
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) return 0 ;;
    present)
      [ ! -L "$_mqrs_node" ] && [ -f "$_mqrs_node" ] && [ -r "$_mqrs_node" ] || { merv_quiesce_block node-reconcile-obstructed; return 1; }
      # A pending node action can launch later from a boot/health route. Until
      # that route's post-owner fence admission is audited, it remains busy.
      merv_quiesce_block node-reconcile-pending
      return 1
      ;;
    obstructed) merv_quiesce_block node-reconcile-obstructed; return 1 ;;
    *) merv_quiesce_block node-reconcile-unobservable; return 1 ;;
  esac
}

# The following two state scanners are intentionally conservative. Existing
# job roots are recursively inspected; every nonterminal or malformed record
# blocks, and a terminal record is idle only when its recorded processes are
# authoritatively dead/reused.
merv_quiesce_job_uint_file() {
  _mqjuf_path=${1:-}
  [ ! -L "$_mqjuf_path" ] && [ -f "$_mqjuf_path" ] && [ -r "$_mqjuf_path" ] || return 1
  _mqjuf_value=$(cat "$_mqjuf_path" 2>/dev/null || printf '')
  merv_owner_v2_positive_uint "$_mqjuf_value" || return 1
  MERV_QUIESCE_JOB_VALUE=$_mqjuf_value
}

merv_quiesce_job_process() {
  _mqjp_pid=${1:-}
  _mqjp_start=${2:-}
  _mqjp_label=${3:-job-process}
  case "$_mqjp_pid:$_mqjp_start" in none:none) return 0 ;; esac
  merv_owner_v2_positive_uint "$_mqjp_pid" && merv_owner_v2_positive_uint "$_mqjp_start" || { merv_quiesce_block "$_mqjp_label-identity-missing"; return 1; }
  _mqjp_state=$(merv_continuation_process_state "$_mqjp_pid" "$_mqjp_start")
  case "$_mqjp_state" in
    dead|reused) return 0 ;;
    live) merv_quiesce_busy "$_mqjp_label-live"; return 1 ;;
    *) merv_quiesce_block "$_mqjp_label-unobservable"; return 1 ;;
  esac
}

merv_quiesce_node_job_ssh_forensics() {
  _mqjf_dir=${1:-}
  [ -d "$_mqjf_dir" ] && [ ! -L "$_mqjf_dir" ] && [ -r "$_mqjf_dir" ] && [ -x "$_mqjf_dir" ] || {
    merv_quiesce_block node-job-ssh-forensics-obstructed
    return 1
  }
  _mqjf_mode=$(LC_ALL=C ls -ldn "$_mqjf_dir" 2>/dev/null | awk 'NR == 1 { print $1 }')
  [ "$_mqjf_mode" = drwx------ ] || { merv_quiesce_block node-job-ssh-forensics-obstructed; return 1; }

  # lib_ssh.sh publishes 30 newline-terminated fields. Its 28 dynamic values
  # each pass through the ASCII/byte-bounded 512-byte sanitizer; fixed values
  # and all key/equal/newline bytes total 475 bytes. Thus the exact producer
  # maximum is 28*512+475 = 14811 bytes. The producer chmods final records 600.
  for _mqjf_entry in "$_mqjf_dir"/* "$_mqjf_dir"/.[!.]* "$_mqjf_dir"/..?*; do
    [ -e "$_mqjf_entry" ] || [ -L "$_mqjf_entry" ] || continue
    _mqjf_name=${_mqjf_entry##*/}
    case "$_mqjf_name" in
      .*) merv_quiesce_block node-job-partial-publication; return 1 ;;
      attempt.*)
        _mqjf_pair=$(printf '%s\n' "$_mqjf_name" | LC_ALL=C awk -F. '
          NF == 4 && $1 == "attempt" && $2 ~ /^[1-9][0-9]*$/ &&
            $3 ~ /^[1-9][0-9]*$/ && $4 == "log" { print $2 ":" $3; good = 1 }
          END { if (NR != 1 || !good) exit 1 }
        ' 2>/dev/null) || { merv_quiesce_block node-job-ssh-forensics-name-malformed; return 1; }
        _mqjf_pid=${_mqjf_pair%%:*}
        _mqjf_seq=${_mqjf_pair#*:}
        merv_quiesce_uint_value "$_mqjf_pid" no && merv_quiesce_uint_value "$_mqjf_seq" no || {
          merv_quiesce_block node-job-ssh-forensics-name-malformed
          return 1
        }
        merv_quiesce_private_record "$_mqjf_entry" 14811 || {
          merv_quiesce_block node-job-ssh-forensics-record-obstructed
          return 1
        }
        ;;
      *) merv_quiesce_block unknown-node-job-entry; return 1 ;;
    esac
  done
  return 0
}

merv_quiesce_node_job_result() {
  _mqnjr_dir=${1:-}
  _mqnjr_file="$_mqnjr_dir/result"
  merv_quiesce_private_record "$_mqnjr_file" 2048 || { merv_quiesce_block node-job-result-missing-or-unreadable; return 1; }
  _mqnjr_expected_node=${_mqnjr_dir##*/node_}
  awk -F= -v expected_node="$_mqnjr_expected_node" '
    BEGIN { split("format_version state node_id phase started_epoch completed_epoch reason owner_pid owner_start owner_nonce",k," "); for(i in k) a[k[i]]=1; want=10 }
    {
      if (NF != 2 || !($1 in a) || seen[$1]++) exit 2
      v[$1]=$2
      if ($1 == "format_version" && $2 != "2") exit 2
      if (($1 == "started_epoch" || $1 == "completed_epoch" || $1 == "owner_pid" || $1 == "owner_start") &&
          ($2 !~ /^[1-9][0-9]*$/ || length($2) > 10 || $2 + 0 > 2147483647)) exit 2
      if (($1 == "phase" || $1 == "reason" || $1 == "owner_nonce") && $2 !~ /^[A-Za-z0-9._-]+$/) exit 2
      count++
    }
    END {
      if (count != want) exit 2
      for (x in a) if (seen[x] != 1) exit 2
      if (v["state"] !~ /^(ok|failed|timeout)$/ || v["node_id"] !~ /^(10|[1-9])$/ || v["node_id"] != expected_node) exit 2
      if (length(v["phase"]) > 64 || length(v["reason"]) > 160 || length(v["owner_nonce"]) > 160) exit 2
      if (v["completed_epoch"] + 0 < v["started_epoch"] + 0) exit 2
    }
  ' "$_mqnjr_file" >/dev/null 2>&1 || { merv_quiesce_block node-job-result-malformed; return 1; }
  _mqnjr_state=$(sed -n 's/^state=//p' "$_mqnjr_file" 2>/dev/null)
  case "$_mqnjr_state" in ok|failed|timeout) ;; *) merv_quiesce_busy node-job-nonterminal; return 1 ;; esac
  _mqnjr_owner=$(sed -n 's/^owner_pid=//p' "$_mqnjr_file" 2>/dev/null)
  _mqnjr_owner_start=$(sed -n 's/^owner_start=//p' "$_mqnjr_file" 2>/dev/null)
  merv_quiesce_job_process "$_mqnjr_owner" "$_mqnjr_owner_start" node-job-result-owner || return 1
  merv_quiesce_uint_file "$_mqnjr_dir/wrapper.pid" no || { merv_quiesce_block node-job-wrapper-identity-missing; return 1; }
  _mqnjr_wrapper=$MERV_QUIESCE_UINT_FILE_VALUE
  merv_quiesce_uint_file "$_mqnjr_dir/wrapper.proc_start_time" no || { merv_quiesce_block node-job-wrapper-identity-missing; return 1; }
  _mqnjr_wrapper_start=$MERV_QUIESCE_UINT_FILE_VALUE
  merv_quiesce_job_process "$_mqnjr_wrapper" "$_mqnjr_wrapper_start" node-job-wrapper || return 1
  _mqnjr_has_pid=0; _mqnjr_has_start=0
  [ -e "$_mqnjr_dir/child.pid" ] || [ -L "$_mqnjr_dir/child.pid" ] && _mqnjr_has_pid=1
  [ -e "$_mqnjr_dir/child.proc_start_time" ] || [ -L "$_mqnjr_dir/child.proc_start_time" ] && _mqnjr_has_start=1
  [ "$_mqnjr_has_pid" = "$_mqnjr_has_start" ] || { merv_quiesce_block node-job-child-identity-incomplete; return 1; }
  if [ "$_mqnjr_has_pid" = 1 ]; then
    merv_quiesce_uint_file "$_mqnjr_dir/child.pid" no || { merv_quiesce_block node-job-child-identity-malformed; return 1; }
    _mqnjr_child=$MERV_QUIESCE_UINT_FILE_VALUE
    merv_quiesce_uint_file "$_mqnjr_dir/child.proc_start_time" no || { merv_quiesce_block node-job-child-identity-malformed; return 1; }
    _mqnjr_child_start=$MERV_QUIESCE_UINT_FILE_VALUE
    merv_quiesce_job_process "$_mqnjr_child" "$_mqnjr_child_start" node-job-child || return 1
  fi
  for _mqnjr_entry in "$_mqnjr_dir"/* "$_mqnjr_dir"/.[!.]* "$_mqnjr_dir"/..?*; do
    [ -e "$_mqnjr_entry" ] || [ -L "$_mqnjr_entry" ] || continue
    _mqnjr_name=${_mqnjr_entry##*/}
    case "$_mqnjr_name" in
      result|wrapper.pid|wrapper.proc_start_time|child.pid|child.proc_start_time|stdout.log|cli.log|vlan.log|client.json|snapshot.json|settings.expected) [ ! -L "$_mqnjr_entry" ] && [ -f "$_mqnjr_entry" ] && [ -r "$_mqnjr_entry" ] || { merv_quiesce_block node-job-entry-obstructed; return 1; } ;;
      ssh) [ -d "$_mqnjr_entry" ] && [ ! -L "$_mqnjr_entry" ] || { merv_quiesce_block node-job-ssh-obstructed; return 1; } ;;
      ssh_forensics)
        merv_quiesce_node_job_ssh_forensics "$_mqnjr_entry" || return 1
        ;;
      .*) merv_quiesce_block node-job-partial-publication; return 1 ;;
      *) merv_quiesce_block unknown-node-job-entry; return 1 ;;
    esac
  done
  return 0
}

merv_quiesce_node_jobs_walk() {
  # BusyBox ash (ASUSWRT) and host dash support function-local variables.
  # Recursive children must not replace their parent's traversal/manifest
  # frame. Only the aggregate READY/LAUNCHED counters remain shared.
  local _mqnjw_dir _mqnjw_depth _mqnjw_entry _mqnjw_name _mqnjw_pid
  local _mqnjw_ready _mqnjw_node _mqnjw_ip _mqnjw_extra _mqnjw_status _mqnjw_next
  _mqnjw_dir=${1:-}
  _mqnjw_depth=${2:-0}
  [ "$_mqnjw_depth" -le 4 ] 2>/dev/null || { merv_quiesce_block node-job-depth; return 1; }
  for _mqnjw_entry in "$_mqnjw_dir"/* "$_mqnjw_dir"/.[!.]* "$_mqnjw_dir"/..?*; do
    [ -e "$_mqnjw_entry" ] || [ -L "$_mqnjw_entry" ] || continue
    _mqnjw_name=${_mqnjw_entry##*/}
    case "$_mqnjw_name" in
      node_[1-9]|node_[1-9][0-9])
        [ -d "$_mqnjw_entry" ] && [ ! -L "$_mqnjw_entry" ] || { merv_quiesce_block node-job-dir-obstructed; return 1; }
        merv_quiesce_node_job_result "$_mqnjw_entry" || return 1
        ;;
      .nodes.[0-9]*|ready|launched)
        [ ! -L "$_mqnjw_entry" ] && [ -f "$_mqnjw_entry" ] && [ -r "$_mqnjw_entry" ] || { merv_quiesce_block node-job-manifest-obstructed; return 1; }
        case "$_mqnjw_name" in
          .nodes.*)
            _mqnjw_pid=${_mqnjw_name#.nodes.}
            merv_quiesce_uint_value "$_mqnjw_pid" no || { merv_quiesce_block node-job-input-name-malformed; return 1; }
            merv_quiesce_node_list_file "$_mqnjw_entry" || { merv_quiesce_block node-job-input-malformed; return 1; }
            ;;
          ready)
            merv_quiesce_node_list_file "$_mqnjw_entry" || { merv_quiesce_block node-job-ready-malformed; return 1; }
            MERV_QUIESCE_READY_MANIFEST_COUNT=$((MERV_QUIESCE_READY_MANIFEST_COUNT + 1))
            ;;
          launched)
            _mqnjw_ready="$_mqnjw_dir/ready"
            merv_quiesce_node_list_file "$_mqnjw_entry" &&
              merv_quiesce_node_list_file "$_mqnjw_ready" || { merv_quiesce_block node-job-launched-or-ready-malformed; return 1; }
            [ -s "$_mqnjw_entry" ] || { merv_quiesce_block node-job-launched-empty; return 1; }
            while IFS=' ' read -r _mqnjw_node _mqnjw_ip _mqnjw_extra || [ -n "$_mqnjw_node" ]; do
              [ -n "$_mqnjw_node" ] || continue
              [ -z "$_mqnjw_extra" ] || { merv_quiesce_block node-job-launched-row-malformed; return 1; }
              awk -v n="$_mqnjw_node" -v ip="$_mqnjw_ip" '$1 == n && $2 == ip { found = 1 } END { exit !found }' \
                "$_mqnjw_ready" >/dev/null 2>&1 || { merv_quiesce_block node-job-launched-not-ready; return 1; }
              _mqnjw_status="$_mqnjw_dir/status/node_$_mqnjw_node"
              merv_quiesce_node_job_result "$_mqnjw_status" || return 1
            done < "$_mqnjw_entry"
            MERV_QUIESCE_LAUNCHED_MANIFEST_COUNT=$((MERV_QUIESCE_LAUNCHED_MANIFEST_COUNT + 1))
            ;;
        esac
        ;;
      .*) merv_quiesce_block node-job-partial-publication; return 1 ;;
      *)
        if [ -d "$_mqnjw_entry" ] && [ ! -L "$_mqnjw_entry" ]; then
          case "$_mqnjw_name" in *[!A-Za-z0-9._-]*) merv_quiesce_block unknown-node-job-dir; return 1 ;; esac
          _mqnjw_next=$((_mqnjw_depth + 1))
          merv_quiesce_node_jobs_walk "$_mqnjw_entry" "$_mqnjw_next" || return 1
        else
          merv_quiesce_block unknown-node-job-entry
          return 1
        fi
        ;;
    esac
  done
  return 0
}

merv_quiesce_node_jobs_state() {
  MERV_QUIESCE_READY_MANIFEST_COUNT=0
  MERV_QUIESCE_LAUNCHED_MANIFEST_COUNT=0
  merv_quiesce_path_state "$MERV_QUIESCE_NODE_JOBS"
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) return 0 ;;
    present) [ -d "$MERV_QUIESCE_NODE_JOBS" ] && [ ! -L "$MERV_QUIESCE_NODE_JOBS" ] || { merv_quiesce_block node-job-root-obstructed; return 1; } ;;
    obstructed) merv_quiesce_block node-job-root-obstructed; return 1 ;;
    *) merv_quiesce_block node-job-root-unobservable; return 1 ;;
  esac
  merv_quiesce_node_jobs_walk "$MERV_QUIESCE_NODE_JOBS" 0 || return 1
  if [ "$MERV_QUIESCE_READY_MANIFEST_COUNT" -gt "$MERV_QUIESCE_LAUNCHED_MANIFEST_COUNT" ] 2>/dev/null; then
    merv_quiesce_block node-job-ready-without-terminal-launch-inventory
    return 1
  fi
  return 0
}

merv_quiesce_node_run_status() {
  _mqnr_file=${1:-}
  _mqnr_expected_run=${2:-}
  _mqnr_expected_node=${3:-}
  _mqnr_ignore=${4:-}
  merv_quiesce_private_record "$_mqnr_file" 2048 || { merv_quiesce_block node-run-status-obstructed; return 1; }
  _mqnr_format=$(sed -n 's/^format_version=//p' "$_mqnr_file" 2>/dev/null)
  case "$_mqnr_format" in
    1)
      # Compatibility with the current installed runner record. Its state is
      # not rich enough to authenticate a pre-spawn pending interval, so a
      # nonterminal dead runner remains BLOCKING. Terminal records are idle
      # only after the recorded runner identity is authoritatively terminal.
      awk -F= -v expected_run="$_mqnr_expected_run" -v expected_node="$_mqnr_expected_node" '
        BEGIN { split("format_version run_id node_id state pid proc_start_time started_epoch completed_epoch exit_code reason",k," "); for(i in k) a[k[i]]=1; want=10 }
        { if (NF != 2 || !($1 in a) || seen[$1]++) exit 2; v[$1]=$2; n++ }
        END {
          if (n != want) exit 2
          for (x in a) if (seen[x] != 1) exit 2
          if (v["format_version"] != "1" || v["run_id"] != expected_run || v["node_id"] != expected_node || v["node_id"] !~ /^(10|[1-9])$/) exit 2
          if (v["pid"] !~ /^[1-9][0-9]*$/ || v["proc_start_time"] !~ /^[1-9][0-9]*$/ || v["started_epoch"] !~ /^[1-9][0-9]*$/ || v["completed_epoch"] !~ /^(0|[1-9][0-9]*)$/) exit 2
          if (v["reason"] !~ /^[A-Za-z0-9._-]+$/) exit 2
          if (v["state"] == "started") { if (v["completed_epoch"] != "0" || v["exit_code"] != "") exit 2 }
          else if (v["state"] == "complete") { if (v["exit_code"] != "0" || v["completed_epoch"] + 0 < v["started_epoch"] + 0) exit 2 }
          else if (v["state"] == "failed") { if (v["exit_code"] !~ /^[1-9][0-9]*$/ || v["completed_epoch"] + 0 < v["started_epoch"] + 0) exit 2 }
          else exit 2
        }' "$_mqnr_file" >/dev/null 2>&1 || { merv_quiesce_block node-run-status-malformed; return 1; }
      _mqnr_state=$(sed -n 's/^state=//p' "$_mqnr_file" 2>/dev/null)
      _mqnr_pid=$(sed -n 's/^pid=//p' "$_mqnr_file" 2>/dev/null)
      _mqnr_start=$(sed -n 's/^proc_start_time=//p' "$_mqnr_file" 2>/dev/null)
      _mqnr_proc=$(merv_continuation_process_state "$_mqnr_pid" "$_mqnr_start")
      case "$_mqnr_state:$_mqnr_proc" in
        started:live) merv_quiesce_busy node-run-active; return 1 ;;
        started:*) merv_quiesce_block legacy-node-run-nonterminal; return 1 ;;
        complete:dead|complete:reused|failed:dead|failed:reused) return 0 ;;
        complete:live|failed:live) merv_quiesce_busy legacy-node-run-child-active; return 1 ;;
        *) merv_quiesce_block legacy-node-run-child-unobservable; return 1 ;;
      esac
      ;;
    2) ;;
    *) merv_quiesce_block node-run-format-unknown; return 1 ;;
  esac
  awk -v expected_run="$_mqnr_expected_run" -v expected_node="$_mqnr_expected_node" '
    BEGIN { split("format_version run_id node_id state pid proc_start_time parent_pid parent_proc_start_time manager_pid manager_proc_start_time started_epoch completed_epoch exit_code reason",k," "); for(i in k) a[k[i]]=1; want=14 }
    {
      p = index($0, "=")
      if (!p) exit 2
      key = substr($0, 1, p - 1); value = substr($0, p + 1)
      if (!(key in a) || seen[key]++) exit 2
      v[key] = value
      if (key == "format_version" && value != "2") exit 2
      if ((key == "pid" || key == "proc_start_time" || key == "parent_pid" ||
           key == "parent_proc_start_time" || key == "started_epoch") && value != "none" &&
          (value !~ /^[1-9][0-9]*$/ || length(value) > 10 || value + 0 > 2147483647)) exit 2
      if ((key == "manager_pid" || key == "manager_proc_start_time") && value != "none" &&
          (value !~ /^[1-9][0-9]*$/ || length(value) > 10 || value + 0 > 2147483647)) exit 2
      if (key == "completed_epoch" && value !~ /^(0|[1-9][0-9]*)$/) exit 2
      if (key == "completed_epoch" && (length(value) > 10 || value + 0 > 2147483647)) exit 2
      if (key == "exit_code" && value != "" && value !~ /^(0|[1-9][0-9]*)$/) exit 2
      if (key == "exit_code" && value != "" && (length(value) > 3 || value + 0 > 255)) exit 2
      if (key == "reason" && value !~ /^[A-Za-z0-9._-]+$/) exit 2
      count++
    }
    END {
      if (count != want) exit 2
      for (x in a) if (seen[x] != 1) exit 2
      if (v["run_id"] != expected_run || v["node_id"] != expected_node ||
          v["node_id"] !~ /^(10|[1-9])$/ || length(v["reason"]) > 160) exit 2
      if (v["parent_pid"] !~ /^[1-9][0-9]*$/ || v["parent_proc_start_time"] !~ /^[1-9][0-9]*$/) exit 2
      if ((v["manager_pid"] == "none") != (v["manager_proc_start_time"] == "none")) exit 2
      if (v["state"] == "pending") {
        if (v["pid"] != "none" || v["proc_start_time"] != "none" || v["manager_pid"] != "none" ||
            v["started_epoch"] != "0" || v["completed_epoch"] != "0" ||
            v["exit_code"] != "" || v["reason"] != "pending") exit 2
      } else if (v["state"] == "started") {
        if (v["pid"] !~ /^[1-9][0-9]*$/ || v["proc_start_time"] !~ /^[1-9][0-9]*$/ ||
            v["started_epoch"] !~ /^[1-9][0-9]*$/ || v["completed_epoch"] != "0" || v["exit_code"] != "") exit 2
      } else if (v["state"] == "complete") {
        if (v["pid"] !~ /^[1-9][0-9]*$/ || v["proc_start_time"] !~ /^[1-9][0-9]*$/ ||
            v["started_epoch"] !~ /^[1-9][0-9]*$/ || v["exit_code"] != "0" ||
            v["completed_epoch"] + 0 < v["started_epoch"] + 0) exit 2
      } else if (v["state"] == "failed") {
        if (v["pid"] !~ /^[1-9][0-9]*$/ || v["proc_start_time"] !~ /^[1-9][0-9]*$/ ||
            v["started_epoch"] !~ /^[1-9][0-9]*$/ || v["exit_code"] == "" || v["exit_code"] == "0" ||
            v["completed_epoch"] + 0 < v["started_epoch"] + 0) exit 2
      } else exit 2
    }
  ' "$_mqnr_file" >/dev/null 2>&1 || { merv_quiesce_block node-run-status-malformed; return 1; }
  _mqnr_state=$(sed -n 's/^state=//p' "$_mqnr_file" 2>/dev/null)
  _mqnr_pid=$(sed -n 's/^pid=//p' "$_mqnr_file" 2>/dev/null)
  _mqnr_start=$(sed -n 's/^proc_start_time=//p' "$_mqnr_file" 2>/dev/null)
  _mqnr_manager=$(sed -n 's/^manager_pid=//p' "$_mqnr_file" 2>/dev/null)
  _mqnr_manager_start=$(sed -n 's/^manager_proc_start_time=//p' "$_mqnr_file" 2>/dev/null)
  case "$_mqnr_state" in
    pending)
      merv_quiesce_busy node-run-pending
      return 1
      ;;
    started)
      if [ "$_mqnr_ignore" = "$_mqnr_expected_run:$_mqnr_expected_node" ] &&
         [ "$_mqnr_pid" = "$$" ] &&
         [ "$_mqnr_start" = "$(merv_identity_current_start /proc 2>/dev/null || printf '')" ]; then
        if [ "$_mqnr_manager" != none ]; then
          _mqnr_manager_state=$(merv_continuation_process_state "$_mqnr_manager" "$_mqnr_manager_start")
          case "$_mqnr_manager_state" in
            dead|reused) return 0 ;;
            live) merv_quiesce_busy node-run-manager-active; return 1 ;;
            *) merv_quiesce_block node-run-manager-unobservable; return 1 ;;
          esac
        fi
        return 0
      fi
      _mqnr_proc=$(merv_continuation_process_state "$_mqnr_pid" "$_mqnr_start")
      case "$_mqnr_proc" in
        live) merv_quiesce_busy node-run-active ;;
        dead|reused)
          if [ "$_mqnr_manager" != none ]; then
            _mqnr_manager_state=$(merv_continuation_process_state "$_mqnr_manager" "$_mqnr_manager_start")
            case "$_mqnr_manager_state" in live) merv_quiesce_busy node-run-manager-active ;; *) merv_quiesce_block node-run-nonterminal-runner-dead ;; esac
          else
            merv_quiesce_block node-run-nonterminal-runner-dead
          fi
          ;;
        *) merv_quiesce_block node-run-child-unobservable ;;
      esac
      return 1
      ;;
    complete|failed)
      merv_quiesce_job_process "$_mqnr_pid" "$_mqnr_start" node-run-child || return 1
      merv_quiesce_job_process "$_mqnr_manager" "$_mqnr_manager_start" node-run-manager || return 1
      ;;
    *) merv_quiesce_block node-run-state-unknown; return 1 ;;
  esac
  return 0
}

merv_quiesce_node_run_pending() {
  _mqnp_file=${1:-}
  _mqnp_expected_run=${2:-}
  _mqnp_expected_node=${3:-}
  merv_quiesce_private_record "$_mqnp_file" 1024 || { merv_quiesce_block node-run-pending-obstructed; return 1; }
  awk -F= -v er="$_mqnp_expected_run" -v en="$_mqnp_expected_node" '
    BEGIN { split("format_version run_id node_id state parent_pid parent_proc_start_time parent_nonce runner_pid runner_proc_start_time",k," "); for(i in k) a[k[i]]=1; want=9 }
    { if(NF != 2 || !($1 in a) || seen[$1]++) exit 2; v[$1]=$2; n++ }
    END {
      if(n != want) exit 2
      for(x in a) if(seen[x] != 1) exit 2
      if(v["format_version"] != "1" || v["run_id"] != er || v["node_id"] != en || v["state"] != "pending") exit 2
      if(v["node_id"] !~ /^(10|[1-9])$/ || v["parent_pid"] !~ /^[1-9][0-9]*$/ || v["parent_proc_start_time"] !~ /^[1-9][0-9]*$/ || v["parent_nonce"] !~ /^[A-Za-z0-9._:-]+$/) exit 2
      if((v["runner_pid"] == "none") != (v["runner_proc_start_time"] == "none")) exit 2
      if(v["runner_pid"] != "none" && (v["runner_pid"] !~ /^[1-9][0-9]*$/ || v["runner_proc_start_time"] !~ /^[1-9][0-9]*$/)) exit 2
    }' "$_mqnp_file" >/dev/null 2>&1 || { merv_quiesce_block node-run-pending-malformed; return 1; }
  merv_quiesce_busy node-run-pending
  return 1
}

merv_quiesce_node_runs_state() {
  _mqnr_ignore=${1:-}
  merv_quiesce_path_state "$MERV_QUIESCE_NODE_RUNS"
  case "$MERV_QUIESCE_PATH_STATE" in
    absent) return 0 ;;
    present) [ -d "$MERV_QUIESCE_NODE_RUNS" ] && [ ! -L "$MERV_QUIESCE_NODE_RUNS" ] || { merv_quiesce_block node-run-root-obstructed; return 1; } ;;
    obstructed) merv_quiesce_block node-run-root-obstructed; return 1 ;;
    *) merv_quiesce_block node-run-root-unobservable; return 1 ;;
  esac
  for _mqnr_run in "$MERV_QUIESCE_NODE_RUNS"/*; do
    [ -e "$_mqnr_run" ] || [ -L "$_mqnr_run" ] || continue
    [ ! -L "$_mqnr_run" ] && [ -d "$_mqnr_run" ] || { merv_quiesce_block node-run-dir-obstructed; return 1; }
    _mqnr_run_id=${_mqnr_run##*/}
    _mqnr_run_left=${_mqnr_run_id%%-*}
    _mqnr_run_right=${_mqnr_run_id#*-}
    case "$_mqnr_run_id" in *-*) ;; *) merv_quiesce_block node-run-id-malformed; return 1 ;; esac
    case "$_mqnr_run_left:$_mqnr_run_right" in ''|*[!0-9:]*|:*|*::|*:|*:) merv_quiesce_block node-run-id-malformed; return 1 ;; esac
    for _mqnr_entry in "$_mqnr_run"/* "$_mqnr_run"/.[!.]* "$_mqnr_run"/..?*; do
      [ -e "$_mqnr_entry" ] || [ -L "$_mqnr_entry" ] || continue
      _mqnr_name=${_mqnr_entry##*/}
      case "$_mqnr_name" in
        node_[1-9].pending|node_[1-9][0-9].pending)
          _mqnr_node=${_mqnr_name#node_}; _mqnr_node=${_mqnr_node%.pending}
          case "$_mqnr_node" in 1|2|3|4|5|6|7|8|9|10) ;; *) merv_quiesce_block node-run-node-id-invalid; return 1 ;; esac
          merv_quiesce_node_run_pending "$_mqnr_entry" "$_mqnr_run_id" "$_mqnr_node" || return 1
          ;;
        node_[1-9].status|node_[1-9][0-9].status)
          _mqnr_node=${_mqnr_name#node_}; _mqnr_node=${_mqnr_node%.status}
          case "$_mqnr_node" in 1|2|3|4|5|6|7|8|9|10) ;; *) merv_quiesce_block node-run-node-id-invalid; return 1 ;; esac
          merv_quiesce_node_run_status "$_mqnr_entry" "$_mqnr_run_id" "$_mqnr_node" "$_mqnr_ignore" || return 1
          ;;
        *.log) [ ! -L "$_mqnr_entry" ] && [ -f "$_mqnr_entry" ] || { merv_quiesce_block node-run-log-obstructed; return 1; } ;;
        .*) merv_quiesce_block node-run-partial-publication; return 1 ;;
        *) merv_quiesce_block unknown-node-run-entry; return 1 ;;
      esac
    done
  done
  return 0
}

merv_maintenance_quiesce_classify() {
  MERV_QUIESCE_STATUS=IDLE
  MERV_QUIESCE_REASON=idle
  merv_quiesce_check_primary_owners "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" || { printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0; }
  merv_quiesce_scan_locks || { printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0; }
  merv_quiesce_owner_state "$MERV_QUIESCE_TRUST_LOCK" ssh-trust-state-lock || { printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0; }
  merv_quiesce_observation_state || { printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0; }
  # A continuation owner may request Q to exclude only its own authenticated
  # active lease while it proves that all other mutation state has retired.
  # The continuation library validates that the token belongs to this exact
  # child identity before excluding it.
  _mqc_cont=$(merv_continuation_quiescence "${7:-}" 2>/dev/null || printf blocking)
  case "$_mqc_cont" in
    idle) ;;
    busy) merv_quiesce_busy continuation-pending-or-active; printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0 ;;
    *) merv_quiesce_block continuation-unverifiable; printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0 ;;
  esac
  merv_quiesce_node_jobs_state || { printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0; }
  merv_quiesce_node_runs_state "${8:-}" || { printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0; }
  merv_quiesce_dhcp_state || { printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0; }
  merv_quiesce_reconciliation_state || { printf '%s\n' "$MERV_QUIESCE_STATUS"; return 0; }
  printf '%s\n' "$MERV_QUIESCE_STATUS"
}
