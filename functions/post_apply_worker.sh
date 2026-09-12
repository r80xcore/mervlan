#!/bin/sh
# ============================================================================
# - File: post_apply_worker.sh || version="0.5"
# - Purpose: Serialize and coalesce post-apply MAC snapshots/client collection.
# ============================================================================
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_MERVQT_LOADED
  unset LIB_SSID_FILTER_LOADED LIB_MAC_SHIELD_SNAPSHOT_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_ACTION_ACK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_ack.sh" 2>/dev/null || :
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_identity.sh" 2>/dev/null || exit 75
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || exit 75
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh"
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || exit 75
[ -n "${LIB_SSID_FILTER_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssid_filter.sh"
[ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ] || . "$MERV_BASE/settings/mac_shield_snapshot.sh" 2>/dev/null || true
[ -n "${LIB_PROGRESS_LOADED:-}" ] || [ ! -f "$MERV_BASE/settings/lib_progress.sh" ] || . "$MERV_BASE/settings/lib_progress.sh" 2>/dev/null || :

# A detached observation worker starts without the manager's exported hardware
# profile. Bootstrap the same bounded slot count and node assignment here so a
# fresh process cannot misread MAX_SSIDS=0 and publish an empty snapshot.
if [ -z "${MAX_SSIDS:-}" ]; then
  MAX_SSIDS=$(json_get_int MAX_SSIDS 0 "$HW_SETTINGS_FILE")
  [ "$MAX_SSIDS" -gt 0 ] 2>/dev/null ||
    MAX_SSIDS=$(json_get_section_value Hardware MAX_SSIDS "$HW_SETTINGS_FILE")
fi
MAX_SSIDS=$(merv_cap_ssids "${MAX_SSIDS:-0}" "$HW_SETTINGS_FILE")
if [ -z "${MERV_NODE_ID:-}" ]; then
  MERV_NODE_ID=$(json_get_flag NODE_ID "" "$SETTINGS_FILE")
  [ -n "$MERV_NODE_ID" ] ||
    MERV_NODE_ID=$(json_get_section_value General NODE_ID "$SETTINGS_FILE")
fi
ssid_filter_init "${MERV_NODE_ID:-none}"
export MAX_SSIDS MERV_NODE_ID

OBS_ACTION="${1:-status}"
case "$OBS_ACTION" in
  status) : ;;
  *)
    if merv_update_mutation_blocked; then
      printf '%s\n' 'Observation request refused: Update maintenance is active' >&2
      exit 75
    fi
    ;;
esac
OBS_ROOT="${MERV_OBSERVATION_ROOT:-$LOCKDIR/observation}"
OBS_STATE="$OBS_ROOT/request.state"
OBS_WORKER_LOCK="$OBS_ROOT/worker.lock"
OBS_REQUEST_LOCK="$OBS_ROOT/request.lock"
OBS_FAULTS="$OBS_ROOT/faults"
OBS_CONFIG_LOCKDIR="${MERV_OBSERVATION_CONFIG_LOCKDIR:-$LOCKDIR}"

obs_log() {
  _ol_level="$1"; shift
  if type "$_ol_level" >/dev/null 2>&1; then
    "$_ol_level" -c cli,vlan "Observation: $*"
  else
    printf 'Observation %s: %s\n' "$_ol_level" "$*" >&2
  fi
}

# A trust-resume collection keeps its browser action open while this shared
# coordinator drains earlier work. This optional channel updates only that
# parent action; ordinary client refreshes remain frontend-owned.
obs_resume_progress_phase() {
  _orpp_phase="$1" _orpp_message="$2"
  _orpp_token="${MERV_OBS_RESUME_PROGRESS_TOKEN:-}"
  case "$_orpp_token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "${#_orpp_token}" -le 96 ] || return 0
  type merv_progress_phase >/dev/null 2>&1 || return 0
  merv_progress_phase "$_orpp_token" sshtrustresume_vlanmgr \
    "Resuming MerVLAN action" "$_orpp_phase" "$_orpp_message" >/dev/null 2>&1 || :
}

obs_mac_refresh_progress() {
  _omrp_phase="$1"
  _omrp_percent="$2"
  _omrp_message="$3"

  [ "${MERV_MAC_REFRESH_PROGRESS:-0}" = "1" ] || return 0

  case "${MERV_PROGRESS_TOKEN:-}" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac

  type merv_progress_update >/dev/null 2>&1 || return 0

  merv_progress_update \
    "$MERV_PROGRESS_TOKEN" \
    macrefresh_vlanmgr \
    "Rebuild MAC Shield" \
    running \
    determinate \
    "$_omrp_phase" \
    0 \
    0 \
    "$_omrp_percent" \
    "$_omrp_message" \
    "" >/dev/null 2>&1 || :
}

# The collection loader is frontend-owned.  Give its nested SSH trust probe a
# distinct, terminal progress record so a verified check cannot overwrite the
# client-refresh stages or leave the browser token falsely running.
obs_trust_probe_progress_token() {
  _otpp_existing="$MERV_SSH_TRUST_PROGRESS_TOKEN"
  case "$_otpp_existing" in
    [A-Za-z0-9._-]* )
      case "$_otpp_existing" in *[!A-Za-z0-9._-]* ) ;; *) printf '%s\n' "$_otpp_existing"; return 0 ;; esac
      ;;
  esac
  _otpp_now=$(date +%s 2>/dev/null || printf 0)
  case "$_otpp_now" in ''|*[!0-9]*) return 1 ;; esac
  _otpp_start=$(merv_identity_current_start 2>/dev/null || printf 0)
  case "$_otpp_start" in ''|*[!0-9]*) _otpp_start=0 ;; esac
  printf 'probe.%s.%s.%s\n' "$_otpp_now" "$$" "$_otpp_start"
}

# A successful router-owned host-key probe can be reused only by the same
# immediately queued observation generation.  The short-lived grant is tied
# to the canonical configured-node list; a later request or settings change
# falls back to the normal complete preflight.
obs_trust_gate_grant() {
  type merv_node_list_digest >/dev/null 2>&1 || return 1
  _otg_now=$(date +%s 2>/dev/null || printf 0)
  case "$_otg_now" in ''|*[!0-9]*) return 1 ;; esac
  _otg_digest=$(merv_node_list_digest 2>/dev/null)
  case "$_otg_digest" in
    cksum:[0-9]*.[0-9]*|md5:[0-9A-Fa-f][0-9A-Fa-f]*) ;;
    *) return 1 ;;
  esac
  MERV_OBS_TRUST_GATE_EPOCH="$_otg_now"
  MERV_OBS_TRUST_GATE_DIGEST="$_otg_digest"
  export MERV_OBS_TRUST_GATE_EPOCH MERV_OBS_TRUST_GATE_DIGEST
  return 0
}

obs_root_valid() {
  if [ "${MERV_DHCP_HOLD_TEST_MODE:-0}" = 1 ]; then
    merv_dhcp_hold_test_root_valid || return 1
    case "$OBS_ROOT" in "$MERV_DHCP_HOLD_TEST_ROOT"/*) return 0 ;; *) return 1 ;; esac
  fi
  [ "$OBS_ROOT" = "${LOCKDIR:-/tmp/mervlan_tmp/locks}/observation" ]
}

obs_init() {
  obs_root_valid || return 1
  mkdir -p "$OBS_ROOT" "$OBS_FAULTS" 2>/dev/null || return 2
  # A missing state file reads as four zeroes. The first request publishes it
  # while holding request.lock, avoiding an initialization-vs-request race.
  return 0
}

obs_read_number() {
  _orn_key="$1"
  _orn_value=$(sed -n "s/^${_orn_key}=//p" "$OBS_STATE" 2>/dev/null | tail -n 1)
  case "$_orn_value" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$_orn_value" ;; esac
}

obs_state_load() {
  OBS_SR=$(obs_read_number snapshot_requested_generation)
  OBS_SC=$(obs_read_number snapshot_completed_generation)
  OBS_CR=$(obs_read_number collection_requested_generation)
  OBS_CC=$(obs_read_number collection_completed_generation)
}

obs_state_write() {
  _osw_sr="$1"; _osw_sc="$2"; _osw_cr="$3"; _osw_cc="$4"
  # State publication is not an ownership record, but its temporary name
  # still uses the canonical current-shell nonce so concurrent detached
  # workers cannot collide on a PID-only path.
  merv_identity_nonce_next || return 2
  _osw_tmp="$OBS_ROOT/.request.state.tmp.$$.$MERV_IDENTITY_NONCE"
  {
    printf 'snapshot_requested_generation=%s\n' "$_osw_sr"
    printf 'snapshot_completed_generation=%s\n' "$_osw_sc"
    printf 'collection_requested_generation=%s\n' "$_osw_cr"
    printf 'collection_completed_generation=%s\n' "$_osw_cc"
  } > "$_osw_tmp" 2>/dev/null &&
    mv "$_osw_tmp" "$OBS_STATE" 2>/dev/null || {
      rm -f "$_osw_tmp" 2>/dev/null || :
      return 2
    }
}

obs_lock_acquire() {
  _ola_lock="$1" _ola_wait="${2:-0}"
  case "$_ola_wait" in ''|*[!0-9]*) return 2 ;; esac
  # Observation chooses its proc root for deterministic tests; the generic
  # owner library retains /proc as the production default.
  _ola_prev_proc_root="${MERV_OWNER_LOCK_PROC_ROOT+x}"
  _ola_prev_proc_value="${MERV_OWNER_LOCK_PROC_ROOT:-}"
  MERV_OWNER_LOCK_PROC_ROOT="${MERV_OBSERVATION_PROC_ROOT:-/proc}"
  merv_owner_lock_acquire "$_ola_lock" 0 "$_ola_wait" observation
  _ola_rc=$?
  if [ -n "$_ola_prev_proc_root" ]; then
    MERV_OWNER_LOCK_PROC_ROOT="$_ola_prev_proc_value"
  else
    unset MERV_OWNER_LOCK_PROC_ROOT
  fi
  [ "$_ola_rc" -eq 0 ] || return "$_ola_rc"
  OBS_LOCK_NONCE="$MERV_LOCK_NONCE"
  OBS_LOCK_START="$MERV_LOCK_START"
  return 0
}

obs_lock_release() {
  _olr_lock="$1" _olr_nonce="$2"
  _olr_prev_proc_root="${MERV_OWNER_LOCK_PROC_ROOT+x}"
  _olr_prev_proc_value="${MERV_OWNER_LOCK_PROC_ROOT:-}"
  MERV_OWNER_LOCK_PROC_ROOT="${MERV_OBSERVATION_PROC_ROOT:-/proc}"
  merv_owner_lock_release "$_olr_lock" "$_olr_nonce"
  _olr_rc=$?
  if [ -n "$_olr_prev_proc_root" ]; then
    MERV_OWNER_LOCK_PROC_ROOT="$_olr_prev_proc_value"
  else
    unset MERV_OWNER_LOCK_PROC_ROOT
  fi
  return "$_olr_rc"
}

obs_config_observable() {
  OBS_BLOCKER_REASON=""
  for _oco_lock in "$OBS_CONFIG_LOCKDIR/mervlan_manager.lock" "$OBS_CONFIG_LOCKDIR/vlan_event.lock"; do
    if type merv_lock_state >/dev/null 2>&1; then
      case "$(merv_lock_state "$_oco_lock")" in
        active|unknown)
          case "$_oco_lock" in
            "$OBS_CONFIG_LOCKDIR/mervlan_manager.lock") OBS_BLOCKER_REASON="VLAN manager" ;;
            "$OBS_CONFIG_LOCKDIR/vlan_event.lock") OBS_BLOCKER_REASON="VLAN event" ;;
            *) OBS_BLOCKER_REASON="configuration mutation" ;;
          esac
          return 1
          ;;
      esac
    elif [ -d "$_oco_lock" ]; then
      case "$_oco_lock" in
        "$OBS_CONFIG_LOCKDIR/mervlan_manager.lock") OBS_BLOCKER_REASON="VLAN manager" ;;
        "$OBS_CONFIG_LOCKDIR/vlan_event.lock") OBS_BLOCKER_REASON="VLAN event" ;;
        *) OBS_BLOCKER_REASON="configuration mutation" ;;
      esac
      return 1
    fi
  done
  for _oco_owner in "$MERV_DHCP_HOLD_STATE_ROOT/owners/"*; do
    [ -d "$_oco_owner" ] && [ -f "$_oco_owner/ready" ] || continue
    _oco_phase=$(cat "$_oco_owner/phase" 2>/dev/null)
    case "$_oco_phase" in
      mutating|handoff_wait)
        _oco_owner_type=$(cat "$_oco_owner/owner_type" 2>/dev/null)
        [ -n "$_oco_owner_type" ] || _oco_owner_type=unknown
        OBS_BLOCKER_REASON="DHCP owner: $_oco_owner_type ($_oco_phase)"
        return 1
        ;;
    esac
  done
  return 0
}

obs_record_fault() {
  _orf_kind="$1" _orf_generation="$2"
  _orf_file="$OBS_FAULTS/${_orf_kind}-${_orf_generation}-$(date +%s 2>/dev/null || printf 0)-$$"
  {
    printf 'operation=%s\n' "$_orf_kind"
    printf 'generation=%s\n' "$_orf_generation"
    printf 'epoch=%s\n' "$(date +%s 2>/dev/null || printf 0)"
  } > "$_orf_file" 2>/dev/null || :
}

# Collection has an all-or-nothing public-generation contract.  A failed
# request deliberately leaves the last known-good client file in place, so a
# progress-backed browser action also needs an explicit terminal failure rather
# than inferring success from the still-readable old file.
obs_collection_failure_notice() {
  _ocfn_generation="$1"
  case "${MERV_PROGRESS_TOKEN:-}" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  if type merv_progress_fail >/dev/null 2>&1; then
    merv_progress_fail "$MERV_PROGRESS_TOKEN" collectclients_vlanmgr \
      "Collect VLAN clients" phase \
      "Client refresh failed; showing the last known client data." \
      client-collection-failed >/dev/null 2>&1 || :
  fi
  if type action_ack_error >/dev/null 2>&1; then
    action_ack_error "$MERV_PROGRESS_TOKEN" collectclients_vlanmgr \
      "{\"reason\":\"client-collection-failed\",\"generation\":$_ocfn_generation}" \
      "Client refresh failed; showing the last known client data." '[]' \
      client-collection-failed >/dev/null 2>&1 || :
  fi
}

obs_snapshot_run() {
  if [ -n "${MERV_OBS_SNAPSHOT_CMD:-}" ]; then
    "$MERV_OBS_SNAPSHOT_CMD"
    return $?
  fi
  type merv_mac_snapshot >/dev/null 2>&1 || return 1
  if [ "${OBS_SNAPSHOT_RESET_CURRENT:-0}" = 1 ]; then
    MERV_MAC_SNAPSHOT_RESET=1
    MERV_MAC_SNAPSHOT_ALLOW_EMPTY=1
    MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
    export MERV_MAC_SNAPSHOT_RESET MERV_MAC_SNAPSHOT_ALLOW_EMPTY MERV_MAC_SNAPSHOT_FORCE_RELOAD
  fi
  merv_mac_snapshot || return $?
  case "${MERV_MAC_LAST_STATUS:-}" in changed|reloaded|unchanged|empty) return 0 ;; *) return 1 ;; esac
}

obs_collection_run() {
  if [ -n "${MERV_OBS_COLLECTION_CMD:-}" ]; then
    "$MERV_OBS_COLLECTION_CMD"
    return $?
  fi
  # Nodes publish their local observation artifact; only the main router owns
  # the cluster-wide merge and public client JSON.
  if type merv_mac_is_main >/dev/null 2>&1 && ! merv_mac_is_main; then
    [ -f "$MERV_BASE/functions/collect_local_clients.sh" ] || return 1
    # The main router provides the configured node IP when it asks a node for
    # an inventory generation. Preserve that stable identity in the artifact
    # rather than falling back to the node's mutable shell hostname/OOMID.
    if [ -n "${MERV_OBS_CLIENT_ROUTER:-}" ]; then
      sh "$MERV_BASE/functions/collect_local_clients.sh" "" \
        "$MERV_OBS_CLIENT_ROUTER" "$MERV_OBS_CLIENT_ROUTER"
      return $?
    fi
    sh "$MERV_BASE/functions/collect_local_clients.sh"
    return $?
  fi
  [ -f "$MERV_BASE/functions/collect_clients.sh" ] || return 1
  sh "$MERV_BASE/functions/collect_clients.sh"
}

obs_complete_generation() {
  _ocg_kind="$1" _ocg_generation="$2"
  obs_lock_acquire "$OBS_REQUEST_LOCK" 5 || return 2
  _ocg_nonce="$OBS_LOCK_NONCE"
  obs_state_load
  case "$_ocg_kind" in
    snapshot)
      [ "$OBS_SC" -ge "$_ocg_generation" ] || OBS_SC="$_ocg_generation"
      _ocg_reset=$(cat "$OBS_ROOT/snapshot.reset.generation" 2>/dev/null || printf '0')
      case "$_ocg_reset" in ''|*[!0-9]*) _ocg_reset=0 ;; esac
      [ "$_ocg_reset" -gt "$OBS_SC" ] || rm -f "$OBS_ROOT/snapshot.reset.generation" 2>/dev/null || :
      ;;
    collection)
      [ "$OBS_CC" -ge "$_ocg_generation" ] || OBS_CC="$_ocg_generation"
      ;;
  esac
  obs_state_write "$OBS_SR" "$OBS_SC" "$OBS_CR" "$OBS_CC"
  _ocg_rc=$?
  obs_lock_release "$OBS_REQUEST_LOCK" "$_ocg_nonce" || return 2
  return "$_ocg_rc"
}

# Observation owns the MAC Shield snapshot, which may in turn own the shared
# node pool.  Reconcile that pool before releasing the observation owner lock;
# otherwise a TERM/INT during Shield collection could leave node workers alive
# while a later observation starts.
obs_abort_active_pool() {
  _oap_unresolved=0
  if type mnj_pool_state_unresolved >/dev/null 2>&1; then
    mnj_pool_state_unresolved
    _oap_state_rc=$?
    case "$_oap_state_rc" in
      0) _oap_unresolved=1 ;;
      1) ;;
      *) return 1 ;;
    esac
  else
    case "${MNJ_POOL_ACTIVE:-0}" in ''|0) ;; *) _oap_unresolved=1 ;; esac
    [ -n "${MNJ_POOL_PENDING_PID:-}${MNJ_POOL_PENDING_START:-}${MNJ_POOL_PENDING_DIR:-}${MNJ_POOL_PENDING_NODE:-}" ] && _oap_unresolved=1
    [ -n "${MNJ_S1_PID:-}${MNJ_S1_START:-}${MNJ_S1_DIR:-}${MNJ_S1_NODE:-}${MNJ_S1_DEADLINE:-}" ] && _oap_unresolved=1
    [ -n "${MNJ_S2_PID:-}${MNJ_S2_START:-}${MNJ_S2_DIR:-}${MNJ_S2_NODE:-}${MNJ_S2_DEADLINE:-}" ] && _oap_unresolved=1
    [ -n "${MNJ_S3_PID:-}${MNJ_S3_START:-}${MNJ_S3_DIR:-}${MNJ_S3_NODE:-}${MNJ_S3_DEADLINE:-}" ] && _oap_unresolved=1
    [ -n "${MNJ_S4_PID:-}${MNJ_S4_START:-}${MNJ_S4_DIR:-}${MNJ_S4_NODE:-}${MNJ_S4_DEADLINE:-}" ] && _oap_unresolved=1
    [ -n "${MNJ_S5_PID:-}${MNJ_S5_START:-}${MNJ_S5_DIR:-}${MNJ_S5_NODE:-}${MNJ_S5_DEADLINE:-}" ] && _oap_unresolved=1
  fi
  [ "$_oap_unresolved" -eq 1 ] || return 0
  type mnj_pool_abort_active >/dev/null 2>&1 || return 1
  mnj_pool_abort_active failed observation-signal || return 1
  if type mnj_pool_state_unresolved >/dev/null 2>&1; then
    mnj_pool_state_unresolved
    _oap_state_rc=$?
    [ "$_oap_state_rc" -eq 1 ] && return 0
    return 1
  else
    case "${MNJ_POOL_ACTIVE:-0}" in ''|0) return 0 ;; *) return 1 ;; esac
  fi
}

obs_pool_state_clean() {
  if type mnj_pool_state_unresolved >/dev/null 2>&1; then
    mnj_pool_state_unresolved
    _opsc_rc=$?
    [ "$_opsc_rc" -eq 1 ] && return 0
    return 1
  fi
  case "${MNJ_POOL_ACTIVE:-0}" in ''|0) ;; *) return 1 ;; esac
  [ -z "${MNJ_POOL_PENDING_PID:-}${MNJ_POOL_PENDING_START:-}${MNJ_POOL_PENDING_DIR:-}${MNJ_POOL_PENDING_NODE:-}" ] || return 1
  [ -z "${MNJ_S1_PID:-}${MNJ_S1_START:-}${MNJ_S1_DIR:-}${MNJ_S1_NODE:-}${MNJ_S1_DEADLINE:-}" ] || return 1
  [ -z "${MNJ_S2_PID:-}${MNJ_S2_START:-}${MNJ_S2_DIR:-}${MNJ_S2_NODE:-}${MNJ_S2_DEADLINE:-}" ] || return 1
  [ -z "${MNJ_S3_PID:-}${MNJ_S3_START:-}${MNJ_S3_DIR:-}${MNJ_S3_NODE:-}${MNJ_S3_DEADLINE:-}" ] || return 1
  [ -z "${MNJ_S4_PID:-}${MNJ_S4_START:-}${MNJ_S4_DIR:-}${MNJ_S4_NODE:-}${MNJ_S4_DEADLINE:-}" ] || return 1
  [ -z "${MNJ_S5_PID:-}${MNJ_S5_START:-}${MNJ_S5_DIR:-}${MNJ_S5_NODE:-}${MNJ_S5_DEADLINE:-}" ] || return 1
  return 0
}

obs_worker_cleanup() {
  _ow_cleanup_rc=$?
  _ow_pool_abort_failed=0
  if ! obs_abort_active_pool; then
    _ow_pool_abort_failed=1
    _ow_cleanup_rc=1
    obs_log error "observation worker cleanup retained ownership because node workers could not be reconciled"
  fi
  if [ "$_ow_pool_abort_failed" -eq 0 ] && obs_pool_state_clean &&
     [ -n "${MNJ_POOL_ROOT:-}" ] && type mnj_root_valid >/dev/null 2>&1 &&
     mnj_root_valid "$MNJ_POOL_ROOT"; then
    if ! rm -rf "$MNJ_POOL_ROOT" 2>/dev/null; then
      _ow_cleanup_rc=1
      obs_log error "observation worker cleanup could not remove its private node-job workspace"
    fi
  fi
  if [ "$_ow_pool_abort_failed" -eq 0 ]; then
    if ! obs_lock_release "$OBS_WORKER_LOCK" "$_ow_nonce" 2>/dev/null; then
      _ow_cleanup_rc=1
      obs_log error "observation worker lock cleanup failed"
    fi
  fi
  return "$_ow_cleanup_rc"
}

OBS_SIGNAL_HANDLING=0
obs_handle_signal() {
  _obs_signal_status="$1"
  [ "${OBS_SIGNAL_HANDLING:-0}" -eq 0 ] || exit "$_obs_signal_status"
  OBS_SIGNAL_HANDLING=1
  trap - INT TERM
  obs_log error "observation interrupted (rc=$_obs_signal_status); reconciling Shield/node workers"
  obs_abort_active_pool ||
    obs_log error "observation interruption could not reconcile every node worker"
  exit "$_obs_signal_status"
}

obs_collection_trust_gate() {
  # A progress-backed collection is an SSH action. Check host-key trust before
  # publishing a coordinator generation so the browser receives a correlated
  # decision while its loading task is still active.
  case "$MERV_PROGRESS_TOKEN" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  if type merv_mac_is_main >/dev/null 2>&1 && ! merv_mac_is_main; then
    return 0
  fi
  if [ ! -f "$MERV_BASE/functions/ssh_trust_action.sh" ]; then
    if type action_ack_error >/dev/null 2>&1; then
      action_ack_error "$MERV_PROGRESS_TOKEN" collectclients_vlanmgr '{"reason":"ssh-trust-worker-missing"}' "SSH trust verification is unavailable; client collection was not started." '[]' ssh-trust-error >/dev/null 2>&1 || :
    fi
    return 75
  fi
  _octg_progress_token=$(obs_trust_probe_progress_token) || return 75
  (
    MERV_SSH_TRUST_ORIGINAL_ACTION=collectclients_vlanmgr
    MERV_SSH_TRUST_ACK_ACTION=collectclients_vlanmgr
    MERV_SSH_TRUST_SILENT_IF_VERIFIED=1
    MERV_SSH_TRUST_DECISION_EXIT=1
    MERV_SSH_TRUST_PROGRESS_TOKEN="$_octg_progress_token"
    export MERV_SSH_TRUST_ORIGINAL_ACTION MERV_SSH_TRUST_ACK_ACTION
    export MERV_SSH_TRUST_SILENT_IF_VERIFIED MERV_SSH_TRUST_DECISION_EXIT
    export MERV_SSH_TRUST_PROGRESS_TOKEN
    sh "$MERV_BASE/functions/ssh_trust_action.sh" probe "$MERV_PROGRESS_TOKEN"
  )
  _octg_rc=$?
  case "$_octg_rc" in
    0)
      obs_trust_gate_grant || return 75
      return 0
      ;;
    10) return 10 ;;
    *)
      if type action_ack_error >/dev/null 2>&1; then
        action_ack_error "$MERV_PROGRESS_TOKEN" collectclients_vlanmgr '{"reason":"ssh-trust-preflight-failed"}' "SSH trust preflight could not complete; client collection was not started." '[]' ssh-trust-error >/dev/null 2>&1 || :
      fi
      return "$_octg_rc"
      ;;
  esac
}

obs_request() {
  shift
  [ "$#" -gt 0 ] || return 1
  _or_needs_collection=0
  for _or_kind in "$@"; do
    case "$_or_kind" in
      snapshot|snapshot-reset) ;;
      collect|collection) _or_needs_collection=1 ;;
      *) return 1 ;;
    esac
  done
  if [ "$_or_needs_collection" -eq 1 ]; then
    obs_collection_trust_gate
    _or_gate_rc=$?
    [ "$_or_gate_rc" -eq 0 ] || return "$_or_gate_rc"
  fi
  obs_lock_acquire "$OBS_REQUEST_LOCK" 5 || return 2
  _or_nonce="$OBS_LOCK_NONCE"
  obs_state_load
  for _or_kind in "$@"; do
    case "$_or_kind" in
      snapshot) OBS_SR=$((OBS_SR + 1)) ;;
      snapshot-reset)
        OBS_SR=$((OBS_SR + 1))
        printf '%s\n' "$OBS_SR" > "$OBS_ROOT/.snapshot.reset.tmp.$$" &&
          mv "$OBS_ROOT/.snapshot.reset.tmp.$$" "$OBS_ROOT/snapshot.reset.generation" || {
            if ! obs_lock_release "$OBS_REQUEST_LOCK" "$_or_nonce"; then
              obs_log error "observation request lock cleanup failed after reset publication failure"
            fi
            return 2
          }
        ;;
      collect|collection) OBS_CR=$((OBS_CR + 1)) ;;
      *)
        if ! obs_lock_release "$OBS_REQUEST_LOCK" "$_or_nonce"; then
          obs_log error "observation request lock cleanup failed after invalid request"
        fi
        return 1
        ;;
    esac
  done
  obs_state_write "$OBS_SR" "$OBS_SC" "$OBS_CR" "$OBS_CC"
  _or_rc=$?
  obs_lock_release "$OBS_REQUEST_LOCK" "$_or_nonce" || return 2
  [ "$_or_rc" -eq 0 ] || return "$_or_rc"
  printf 'snapshot_requested=%s collection_requested=%s\n' "$OBS_SR" "$OBS_CR"
  if [ "${MERV_OBS_NO_AUTOSTART:-0}" != 1 ]; then
    # Requests often arrive before the manager releases its mutation lock.
    # A one-shot worker correctly deferred in that state, but nothing retried
    # it afterward and the generation remained pending until another event.
    # The bounded wait path preserves coalescing and retries after the lock is
    # released without keeping the requesting manager blocked.
    "$0" run-wait "${MERV_OBS_AUTOSTART_WAIT_SEC:-120}" </dev/null >/dev/null 2>&1 &
  fi
}

obs_run() {
  obs_lock_acquire "$OBS_WORKER_LOCK" 0 || {
    obs_resume_progress_phase queued "Waiting for queued router observation work..."
    return 0
  }
  _ow_nonce="$OBS_LOCK_NONCE"
  trap 'obs_worker_cleanup' EXIT
  trap 'obs_handle_signal 130' INT
  trap 'obs_handle_signal 143' TERM
  while :; do
    obs_state_load
    [ "$OBS_SC" -lt "$OBS_SR" ] || [ "$OBS_CC" -lt "$OBS_CR" ] || break
    if [ "$OBS_SC" -lt "$OBS_SR" ]; then
      if [ "$OBS_CC" -lt "$OBS_CR" ]; then
        _ow_pending_work="MAC snapshot + client collection pending"
      else
        _ow_pending_work="MAC snapshot pending"
      fi
    elif [ "$OBS_CC" -lt "$OBS_CR" ]; then
      _ow_pending_work="client collection pending"
    else
      _ow_pending_work="observation work pending"
    fi
    if ! obs_config_observable; then
      [ -n "$OBS_BLOCKER_REASON" ] || OBS_BLOCKER_REASON="configuration mutation"
      obs_resume_progress_phase deferred "Waiting for active configuration work before refreshing clients..."
      obs_log info "queued: $_ow_pending_work; blocked by $OBS_BLOCKER_REASON"
      return 75
    fi
    if [ "${MERV_OBS_WAIT_RETRY:-0}" = 1 ]; then
      obs_log info "blocker cleared; resuming queued work"
      unset MERV_OBS_WAIT_RETRY
    fi
    if [ "$OBS_SC" -lt "$OBS_SR" ]; then
      obs_resume_progress_phase snapshot "Refreshing queued MAC Shield snapshot..."
      _ow_generation="$OBS_SR"
      _ow_reset=$(cat "$OBS_ROOT/snapshot.reset.generation" 2>/dev/null || printf '0')
      case "$_ow_reset" in ''|*[!0-9]*) _ow_reset=0 ;; esac
      # Any reset request newer than the last completed snapshot upgrades the
      # coalesced target generation to reset mode.
      if [ "$_ow_reset" -gt "$OBS_SC" ]; then
        OBS_SNAPSHOT_RESET_CURRENT=1
      else
        OBS_SNAPSHOT_RESET_CURRENT=0
      fi
      export OBS_SNAPSHOT_RESET_CURRENT
      if obs_snapshot_run; then
        obs_complete_generation snapshot "$_ow_generation" || return 2
      else
        obs_record_fault snapshot "$_ow_generation"
        return 1
      fi
      continue
    fi
    if [ "$OBS_CC" -lt "$OBS_CR" ]; then
    obs_resume_progress_phase collect "Refreshing client inventory..."
    obs_mac_refresh_progress refresh 92 \
      "Refreshing client inventory..."
    _ow_generation="$OBS_CR"
      if obs_collection_run; then
    obs_complete_generation collection "$_ow_generation" || return 2
    obs_mac_refresh_progress finish 97 \
      "Client inventory refreshed; finishing..."
      else
        obs_record_fault collection "$_ow_generation"
        obs_collection_failure_notice "$_ow_generation"
        return 1
      fi
    fi
  done
  return 0
}

obs_run_wait() {
  _orw_max="${1:-120}"
  case "$_orw_max" in ''|*[!0-9]*) return 2 ;; esac
  _orw_was_deferred=0
  _orw_started=$(date +%s 2>/dev/null || printf '0')
  case "$_orw_started" in ''|*[!0-9]*) return 2 ;; esac
  _orw_deadline=$((_orw_started + _orw_max))
  obs_state_load
  _orw_snapshot_target="$OBS_SR"
  _orw_collection_target="$OBS_CR"
  while :; do
    if [ "$_orw_was_deferred" -eq 1 ]; then
      MERV_OBS_WAIT_RETRY=1 "$0" run
    else
      "$0" run
    fi
    _orw_rc=$?
    case "$_orw_rc" in
      0) ;;
      75) _orw_was_deferred=1 ;;
      *) return "$_orw_rc" ;;
    esac
    obs_state_load
    if [ "$OBS_SC" -ge "$_orw_snapshot_target" ] &&
       [ "$OBS_CC" -ge "$_orw_collection_target" ]; then
      return 0
    fi
    # Do not interrupt a snapshot or collection that has already started,
    # but account retries against real elapsed time so slow calls cannot reset
    # the caller's wait budget on every loop.
    _orw_now=$(date +%s 2>/dev/null || printf '0')
    case "$_orw_now" in ''|*[!0-9]*) return 2 ;; esac
    if [ "$_orw_now" -ge "$_orw_deadline" ] 2>/dev/null; then
      obs_resume_progress_phase waiting "Client refresh remains queued; router work is still protected."
      break
    fi
    sleep 1
  done
  return 75
}

obs_status() {
  obs_state_load
  printf 'snapshot requested=%s completed=%s pending=%s\n' \
    "$OBS_SR" "$OBS_SC" "$((OBS_SR - OBS_SC))"
  printf 'collection requested=%s completed=%s pending=%s\n' \
    "$OBS_CR" "$OBS_CC" "$((OBS_CR - OBS_CC))"
  if [ -d "$OBS_WORKER_LOCK" ]; then printf 'worker=active\n'; else printf 'worker=idle\n'; fi
}

obs_init || exit $?
case "$OBS_ACTION" in
  request) obs_request "$@" ;;
  run) obs_run ;;
  run-wait) obs_run_wait "${2:-120}" ;;
  status) obs_status ;;
  *) printf 'Usage: %s request snapshot|collect [...] | run | run-wait [seconds] | status\n' "$0" >&2; exit 2 ;;
esac
