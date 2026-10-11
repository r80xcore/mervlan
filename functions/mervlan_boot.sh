#!/bin/sh
#
# ============================================================================ #
#                                                                              #
#   /$$      /$$                     /$$    /$$ /$$        /$$$$$$  /$$   /$$  #
#  | $$$    /$$$                    | $$   | $$| $$       /$$__  $$| $$$ | $$  #
#  | $$$$  /$$$$  /$$$$$$   /$$$$$$ | $$   | $$| $$      | $$  \ $$| $$$$| $$  #
#  | $$ $$/$$ $$ /$$__  $$ /$$__  $$|  $$ / $$/| $$      | $$$$$$$$| $$ $$ $$  #
#  | $$  $$$| $$| $$$$$$$$| $$  \__/ \  $$ $$/ | $$      | $$__  $$| $$  $$$$  #
#  | $$\  $ | $$| $$_____/| $$        \  $$$/  | $$      | $$  | $$| $$\  $$$  #
#  | $$ \/  | $$|  $$$$$$$| $$         \  $/   | $$$$$$$$| $$  | $$| $$ \  $$  #
#  |__/     |__/ \_______/|__/          \_/    |________/|__/  |__/|__/  \__/  #
#                                                                              #
# ============================================================================ #
#              - File: mervlan_boot.sh || version="0.72.2"                  #
# ============================================================================ #
# - Purpose:    Manage MerVLAN Manager auto-start, service-event helper, and   #
#               SSH propagation to nodes for fully automated VLAN management.  #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED LIB_MERVQT_LOADED LIB_OWNER_LOCK_LOADED LIB_ACTION_ACK_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -f "$TEMPLATE_LIB" ] || { error -c vlan,cli "Missing template library: $TEMPLATE_LIB"; exit 1; }
. "$TEMPLATE_LIB"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_BOOT_INTEGRITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_boot_integrity.sh" 2>/dev/null || {
  error -c vlan,cli "Unable to load the boot-integrity library; refusing boot action"
  exit 1
}
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || {
  error -c vlan,cli "Unable to load the owner-lock library; refusing boot action"
  exit 1
}
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || {
  error -c vlan,cli "Unable to load the DHCP/L2 safety library; refusing boot action"
  exit 1
}
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || true
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_lock.sh" 2>/dev/null || {
  error -c vlan,cli "Unable to load the action-lock library; refusing boot action"
  exit 75
}
[ -n "${LIB_MUTATION_ADMISSION_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mutation_admission.sh" 2>/dev/null || {
  error -c vlan,cli "Unable to load the mutation-admission library; refusing boot action"
  exit 75
}
[ -n "${LIB_NODE_RECONCILE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_node_reconcile.sh" 2>/dev/null || true
if [ -f "$MERV_BASE/settings/lib_action_ack.sh" ]; then
  [ -n "${LIB_ACTION_ACK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_ack.sh"
fi
# =========================================== End of MerVLAN environment setup #
SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)
# ========================================================================== #
# INITIALIZATION & CONSTANTS — Boot state flags, action dispatch, paths      #
# ========================================================================== #

# Action from command line ($1 parameter: enable/disable/setupenable/etc)
ACTION="$1"
ACTION_REQUEST_TOKEN="$2"

# Boot, setup, cron, and reconciliation entry points can alter durable hooks,
# settings, or delayed health work. Supported service-event callers reuse their
# authenticated parent action owner; direct and node-side invocations acquire
# the canonical local action owner themselves.
BOOT_ACTION_LOCKED=0
BOOT_ACTION_LOCK_MODE=none
BOOT_ACTION_LOCK_PATH="${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}"
case "$ACTION" in
  enable|disable|cronenable|crondisable|setupenable|setupdisable|nodeenable|nodedisable|reconcile-pending|status|report)
    if ! merv_action_lock_enter "$BOOT_ACTION_LOCK_PATH"; then
      error -c vlan,cli "Boot action refused because its action owner could not be acquired or verified"
      exit 75
    fi
    BOOT_ACTION_LOCK_MODE="${MERV_ACTION_LOCK_MODE:-none}"
    BOOT_ACTION_LOCK_NONCE="${MERV_ACTION_LOCK_NONCE:-}"
    BOOT_ACTION_LOCK_START="${MERV_ACTION_LOCK_START:-}"
    if ! merv_action_lock_export_child_context ||
       ! merv_mutation_admit_action "$BOOT_ACTION_LOCK_PATH"; then
      error -c vlan,cli "Boot action refused by mutation admission (${MERV_MUTATION_ADMISSION_REASON:-owner-context-invalid}); no boot mutation started"
      merv_action_lock_leave "$BOOT_ACTION_LOCK_PATH" "$BOOT_ACTION_LOCK_NONCE" \
        "$BOOT_ACTION_LOCK_START" "$BOOT_ACTION_LOCK_MODE" >/dev/null 2>&1 || :
      exit 75
    fi
    [ "$BOOT_ACTION_LOCK_MODE" = self ] && BOOT_ACTION_LOCKED=1
    boot_action_release_owner() {
      _bar_exit_rc=$?
      if [ "${BOOT_ACTION_LOCKED:-0}" = 1 ]; then
        if merv_action_lock_leave "$BOOT_ACTION_LOCK_PATH" "$BOOT_ACTION_LOCK_NONCE" \
             "$BOOT_ACTION_LOCK_START" "$BOOT_ACTION_LOCK_MODE" >/dev/null 2>&1; then
          BOOT_ACTION_LOCKED=0
        else
          error -c vlan,cli "Boot action could not release its action owner; recovery is required"
          [ "$_bar_exit_rc" -ne 0 ] || _bar_exit_rc=75
        fi
      fi
      return "$_bar_exit_rc"
    }
    trap 'boot_action_release_owner' EXIT
    ;;
esac

# Status/report is also a safe reconciliation entry point for owners left by a
# killed manager. Mutating boot work reaches the same reconciliation through
# the manager before it acquires its own lease.
case "$ACTION" in
  status|report)
    if type merv_dhcp_hold_reconcile >/dev/null 2>&1; then
      merv_dhcp_hold_reconcile status-start >/dev/null 2>&1 ||
        warn -c vlan,cli "DHCP hold reconciliation could not complete before status"
    fi
    ;;
esac

boot_action_name() {
  case "$ACTION" in
    enable) printf '%s' 'enableservice_vlanmgr' ;;
    disable) printf '%s' 'disableservice_vlanmgr' ;;
    *) printf '%s' "$ACTION" ;;
  esac
}

boot_action_ack_error() {
  type action_ack_error >/dev/null 2>&1 || return 0
  _ba_error_result="$3"
  [ -n "$_ba_error_result" ] || _ba_error_result='{}'
  action_ack_error "$ACTION_REQUEST_TOKEN" "$(boot_action_name)" "$_ba_error_result" "$1" '[]' "$2" || {
    warn -c vlan,cli "Unable to publish boot-action error acknowledgement"
    return 1
  }
}

boot_action_ack_complete() {
  _ba_status="$1"
  _ba_boot="$2"
  _ba_message="$3"
  _ba_warnings="${4:-[]}"
  _ba_result="{\"BOOT_ENABLED\":\"${_ba_boot}\"}"
  case "$_ba_status" in
    partial)
      if type action_ack_partial >/dev/null 2>&1; then
        action_ack_partial "$ACTION_REQUEST_TOKEN" "$(boot_action_name)" "$_ba_result" "$_ba_message" "$_ba_warnings" || {
          warn -c vlan,cli "Unable to publish boot-action partial acknowledgement"
          return 1
        }
      fi
      ;;
    *)
      if type action_ack_ok >/dev/null 2>&1; then
        action_ack_ok "$ACTION_REQUEST_TOKEN" "$(boot_action_name)" "$_ba_result" "$_ba_message" "$_ba_warnings" || {
          warn -c vlan,cli "Unable to publish boot-action completion acknowledgement"
          return 1
        }
      fi
      ;;
  esac
}

node_preflight_failure_is_transient() {
  case "${MERV_SSH_LAST_REASON:-${MERV_SSH_TRUST_LAST_REASON:-}}" in
    unreachable|timeout|refused|no-route) return 0 ;;
    *) return 1 ;;
  esac
}

schedule_node_reconcile() {
  _snr_action="$1"
  _snr_now=$(date +%s 2>/dev/null || printf '0')
  case "$_snr_now" in ''|*[!0-9]*) _snr_now=0 ;; esac
  _snr_delay="${MERV_NODE_RECONCILE_DELAY_SEC:-300}"
  case "$_snr_delay" in ''|*[!0-9]*) _snr_delay=300 ;; esac
  _snr_next=$((_snr_now + _snr_delay))
  _snr_detail=$(printf '%s' "${MERV_SSH_LAST_DETAIL:-node temporarily unavailable}" | tr ' ' '_' | tr -cd 'A-Za-z0-9._:/-')
  _snr_digest="unknown"
  if type merv_node_list_digest >/dev/null 2>&1; then
    _snr_digest=$(merv_node_list_digest 2>/dev/null || printf 'unknown')
  fi
  if type merv_node_reconcile_write >/dev/null 2>&1 &&
     merv_node_reconcile_write "$_snr_action" "${MERV_SSH_LAST_REASON:-unreachable}" \
       "${_snr_detail:-node-unavailable}" 0 "$_snr_next" "$_snr_digest"; then
    info -c vlan,cli "Node action '$_snr_action' deferred: a bounded retry is scheduled in ${_snr_delay}s"
    return 0
  fi
  warn -c vlan,cli "Node action '$_snr_action' could not publish its bounded retry marker"
  return 1
}

process_pending_node_reconcile() {
  type merv_node_reconcile_active >/dev/null 2>&1 && merv_node_reconcile_active || return 0
  _pnr_action=$(merv_node_reconcile_get action '')
  _pnr_next=$(merv_node_reconcile_get next_epoch 0)
  case "$_pnr_action" in
    enable|disable|setupenable|setupdisable|nodeenable|nodedisable) ;;
    *) merv_node_reconcile_clear || :; return 1 ;;
  esac
  case "$_pnr_next" in ''|*[!0-9]*) merv_node_reconcile_clear || :; return 1 ;; esac
  _pnr_now=$(date +%s 2>/dev/null || printf '0')
  case "$_pnr_now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_pnr_now" -ge "$_pnr_next" ] 2>/dev/null || return 0
  info -c vlan,cli "Retrying deferred node action '$_pnr_action' after the bounded recovery delay"
  MERV_NODE_RECONCILE_SUPPRESS_SCHEDULE=1 sh "$0" "$_pnr_action"
  _pnr_rc=$?
  if [ "$_pnr_rc" -eq 0 ]; then
    merv_node_reconcile_clear || warn -c vlan,cli "Deferred node action succeeded but its retry marker could not be cleared"
    return 0
  fi
  if node_preflight_failure_is_transient; then
    warn -c vlan,cli "Deferred node action '$_pnr_action' still cannot reach a node after the bounded retry; manual action is required"
  else
    warn -c vlan,cli "Deferred node action '$_pnr_action' ended with a non-retryable result: ${MERV_SSH_LAST_REASON:-action-failed}"
  fi
  merv_node_reconcile_clear || warn -c vlan,cli "Could not clear the completed deferred node retry marker"
  return "$_pnr_rc"
}

case "$ACTION" in
  enable|disable|setupenable|setupdisable|nodeenable|nodedisable)
    if type merv_update_mutation_blocked >/dev/null 2>&1 &&
       merv_update_mutation_blocked; then
      boot_action_ack_error "Boot action blocked: Update maintenance is active" '{}' "UPDATE_MAINTENANCE_ACTIVE"
      error -c vlan,cli "Boot action '$ACTION' refused while Update maintenance is active"
      exit 75
    fi
    ;;
esac

persist_boot_enabled_state() {
  _pbes_value="$1"
  json_set_flag "BOOT_ENABLED" "$_pbes_value" "$SETTINGS_FILE" >/dev/null 2>&1 || return 1

  # Current installs expose SETTINGS_FILE through a public symlink. Preserve
  # compatibility with older installs where the public path is a regular copy,
  # otherwise the Settings modal keeps reading a stale BOOT_ENABLED value.
  if [ -f "${PUBLIC_SETTINGS_FILE:-}" ] && [ ! -L "$PUBLIC_SETTINGS_FILE" ] && \
     ! cmp -s "$SETTINGS_FILE" "$PUBLIC_SETTINGS_FILE" 2>/dev/null; then
    if cp "$SETTINGS_FILE" "$PUBLIC_SETTINGS_FILE" 2>/dev/null; then
      chmod 644 "$PUBLIC_SETTINGS_FILE" 2>/dev/null || {
        warn -c vlan,cli "Failed to set permissions on the public settings copy"
        return 1
      }
    else
      warn -c vlan,cli "Failed to refresh the public settings copy after changing BOOT_ENABLED"
    fi
  fi
  return 0
}
# Marker format and lock helper
MARKER_PREFIX="### >>> MERVLAN START:"
MARKER_SUFFIX="### <<< MERVLAN END:"
# Use basename of the template as a stable template id in markers without relying on GNU basename
_template_id() {
  local path="$1"
  printf '%s\n' "${path##*/}"
}
_dest_id() {
  local path="$1"
  printf '%s\n' "${path##*/}"
}

: "${MERV_DISABLE_LOCKS:=0}"
if ! type merv_selftest_context_valid >/dev/null 2>&1 ||
   ! merv_selftest_context_valid; then
  MERV_DISABLE_LOCKS=0
  unset MERV_BOOT_TEST_FAULT
fi

# Compute content hash (md5 is in busybox; sha256 may not be)
_content_md5() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

CRON_NAME="mervlan_health"
CRU_BIN=""

if merv_has cru; then
  CRU_BIN=$(merv_cmd cru) || CRU_BIN=""
elif [ -x /usr/sbin/cru ]; then
  CRU_BIN="/usr/sbin/cru"
fi

INJ_BASE="${MERV_BASE%/}"

select_template_variant() {
  local name="$1" dest="$2" requested="$3" dest_id
  [ -n "$name" ] || return 1
  if [ -n "$requested" ]; then
    printf '%s' "$requested"
    return 0
  fi

  if [ -n "$dest" ] && [ -f "$dest" ]; then
    dest_id="$(_dest_id "$dest")"
    if LC_ALL=C grep -Fq "$MARKER_PREFIX $dest_id [tpl=${name}.v1.tpl" "$dest" 2>/dev/null; then
      printf '1'
      return 0
    fi
    if LC_ALL=C grep -Fq "$MARKER_PREFIX $dest_id [tpl=${name}.v2.tpl" "$dest" 2>/dev/null; then
      printf '2'
      return 0
    fi
    if head -n 1 "$dest" 2>/dev/null | grep -q '^#!'; then
      printf '2'
      return 0
    fi
  fi

  printf '1'
  return 0
}

inject_template() {
  local name="$1" dest="$2" variant="${3:-}" resolved tpl rc
  resolved=$(select_template_variant "$name" "$dest" "$variant") || return 1
  tpl=$(tpl_path "$name" "$resolved" "$dest") || return 1
  copy_inject "$tpl" "$dest"
  rc=$?
  if ! rm -f "$tpl" 2>/dev/null; then
    warn -c vlan,cli "Could not remove temporary rendered template $tpl"
    [ "$rc" -eq 0 ] && rc=1
  fi
  return $rc
}

remove_template_block() {
  local name="$1" dest="$2" variant="${3:-}" resolved tpl rc
  resolved=$(select_template_variant "$name" "$dest" "$variant") || return 1
  tpl=$(tpl_path "$name" "$resolved" "$dest") || return 1
  remove_inject "$tpl" "$dest"
  rc=$?
  if ! rm -f "$tpl" 2>/dev/null; then
    warn -c vlan,cli "Could not remove temporary rendered template $tpl"
    [ "$rc" -eq 0 ] && rc=1
  fi
  return $rc
}

reconcile_legacy_boot_file_locks() {
  _rbl_dest=""
  _rbl_lock=""
  for _rbl_dest in "$SERVICE_EVENT_WRAPPER" "$SERVICES_START"; do
    _rbl_lock="$LOCKDIR/${_rbl_dest##*/}.lock"
    [ -e "$_rbl_lock" ] || [ -L "$_rbl_lock" ] || continue
    [ -d "$_rbl_lock" ] && continue
    [ ! -L "$_rbl_lock" ] || {
      error -c vlan,cli "Refusing legacy boot-file lock symlink $_rbl_lock"
      return 1
    }
    merv_lock_quarantine_legacy_file "$_rbl_lock" "boot-file" || return 1
  done
  return 0
}

is_node() {
  # SSH-triggered context from main router overrides local flag
  [ "${MERV_NODE_CONTEXT:-0}" = "1" ] && return 0

  # Primary source of truth is IS_NODE flag in settings.json
  if [ -f "$SETTINGS_FILE" ]; then
    if [ "$(json_get_flag "IS_NODE" "0" "$SETTINGS_FILE" 2>/dev/null)" = "1" ]; then
      return 0
    fi
  fi

  # Legacy fallback while migrating away from .is_node sentinels
  if [ -f "$MERV_BASE/.is_node" ]; then
    return 0
  fi

  return 1
}

marker_present() {
  local name="$1" dest="$2" destid tplid start_base
  [ -f "$dest" ] || return 1
  destid="$(_dest_id "$dest")"
  tplid="${name}.v"
  start_base="$MARKER_PREFIX $destid [tpl=${tplid}"
  LC_ALL=C grep -qF "$start_base" "$dest" 2>/dev/null
}

boot_mutation_fault() {
  [ "${TEST_RUN:-0}" = 1 ] &&
    type merv_selftest_context_valid >/dev/null 2>&1 &&
    merv_selftest_context_valid && [ "${MERV_BOOT_TEST_FAULT:-}" = "$1" ]
}

boot_mutation_lock_begin() {
  _bml_dest="$1"
  _boot_mutation_lock="$LOCKDIR/${_bml_dest##*/}.lock"
  _boot_mutation_nonce=''
  _boot_mutation_locked=0
  if [ "${MERV_DISABLE_LOCKS:-0}" = 1 ] && [ "${TEST_RUN:-0}" = 1 ] &&
     type merv_selftest_context_valid >/dev/null 2>&1 &&
     merv_selftest_context_valid; then return 0; fi
  if [ "${MERV_DISABLE_LOCKS:-0}" = 1 ]; then
    warn -c vlan,cli "Ignoring MERV_DISABLE_LOCKS outside the installer test path"
  fi
  boot_mutation_fault lock_acquire && return 1
  merv_owner_lock_acquire "$_boot_mutation_lock" 0 0 boot-file || return 1
  _boot_mutation_nonce="$MERV_LOCK_NONCE"
  _boot_mutation_locked=1
}

boot_mutation_lock_end() {
  [ "${_boot_mutation_locked:-0}" = 1 ] || return 0
  if merv_owner_lock_release "$_boot_mutation_lock" "$_boot_mutation_nonce" >/dev/null 2>&1; then
    _boot_mutation_locked=0
    return 0
  fi
  # Retry only with the original owner nonce; never remove a foreign claim.
  merv_owner_lock_release "$_boot_mutation_lock" "$_boot_mutation_nonce" >/dev/null 2>&1 && _boot_mutation_locked=0
  return 1
}

boot_mutation_tempdir_create() {
  _bmtc_parent="$1"
  _bmtc_now=$(date +%s 2>/dev/null || printf '0')
  case "$_bmtc_now" in ''|*[!0-9]*) _bmtc_now=0 ;; esac
  case "${_boot_mutation_seq:-0}" in ''|*[!0-9]*) _boot_mutation_seq=0 ;; esac
  _bmtc_tries=0
  while [ "$_bmtc_tries" -lt 32 ]; do
    _boot_mutation_seq=$((_boot_mutation_seq + 1))
    _boot_mutation_stage_dir="$_bmtc_parent/.mervlan-hook.$$.${_bmtc_now}.${_boot_mutation_seq}"
    if mkdir "$_boot_mutation_stage_dir" 2>/dev/null; then
      if ! boot_mutation_fault stage_chmod && chmod 700 "$_boot_mutation_stage_dir" 2>/dev/null; then return 0; fi
      rmdir "$_boot_mutation_stage_dir" 2>/dev/null || :
      _boot_mutation_stage_dir=''
      return 1
    fi
    if [ ! -e "$_boot_mutation_stage_dir" ] && [ ! -L "$_boot_mutation_stage_dir" ]; then return 1; fi
    _bmtc_tries=$((_bmtc_tries + 1))
  done
  return 1
}

boot_mutation_cleanup_stage() {
  [ -n "${_boot_mutation_stage_dir:-}" ] || return 0
  [ ! -L "$_boot_mutation_stage_dir" ] && [ -d "$_boot_mutation_stage_dir" ] || return 1
  _bmcs_rc=0
  for _bmcs_file in block services-start service-event; do
    if [ -e "$_boot_mutation_stage_dir/$_bmcs_file" ] || [ -L "$_boot_mutation_stage_dir/$_bmcs_file" ]; then
      [ ! -L "$_boot_mutation_stage_dir/$_bmcs_file" ] && [ -f "$_boot_mutation_stage_dir/$_bmcs_file" ] || { _bmcs_rc=1; continue; }
      rm -f "$_boot_mutation_stage_dir/$_bmcs_file" 2>/dev/null || _bmcs_rc=1
    fi
  done
  [ "$_bmcs_rc" -eq 0 ] && rmdir "$_boot_mutation_stage_dir" 2>/dev/null || _bmcs_rc=1
  [ "$_bmcs_rc" -eq 0 ] && _boot_mutation_stage_dir=''
  return "$_bmcs_rc"
}

boot_mutation_signal() {
  _bms_signal="$1"
  boot_mutation_cleanup_stage || warn -c vlan,cli "Interrupted boot mutation retained staging evidence at ${_boot_mutation_stage_dir:-unknown}"
  boot_mutation_lock_end || warn -c vlan,cli "Interrupted boot mutation could not release the boot-file owner lock"
  exit "$_bms_signal"
}

boot_mutation_old_mode() {
  _bmom_file="$1"
  [ -f "$_bmom_file" ] || { printf '755\n'; return 0; }
  _bmom_mode=$(ls -ld "$_bmom_file" 2>/dev/null | awk '
    function digit(s, n) { n=0; if (substr(s,1,1)=="r") n+=4; if (substr(s,2,1)=="w") n+=2; if (substr(s,3,1)=="x") n+=1; return n }
    NR==1 { p=substr($1,1,10); if (substr(p,1,1)!="-" || p ~ /[sStT]/) exit 1; printf "%d%d%d\n", digit(substr(p,2,3)), digit(substr(p,5,3)), digit(substr(p,8,3)) }
  ' 2>/dev/null)
  case "$_bmom_mode" in [0-7][0-7][0-7]) ;; *) printf '755\n'; return 0 ;; esac
  _bmom_owner=${_bmom_mode%??}
  _bmom_group=$(printf '%s' "$_bmom_mode" | cut -c2)
  _bmom_other=${_bmom_mode#??}
  case "$_bmom_owner" in 5|7) ;; *) printf '755\n'; return 0 ;; esac
  case "$_bmom_group:$_bmom_other" in *2*|*3*|*6*|*7*) printf '755\n' ;; *) printf '%s\n' "$_bmom_mode" ;; esac
}

boot_mutation_mode_is_safe() {
  _bmmis_file="$1"
  _bmmis_mode=$(ls -ld "$_bmmis_file" 2>/dev/null | awk '
    function digit(s, n) { n=0; if (substr(s,1,1)=="r") n+=4; if (substr(s,2,1)=="w") n+=2; if (substr(s,3,1)=="x") n+=1; return n }
    NR==1 { p=substr($1,1,10); if (substr(p,1,1)!="-" || p ~ /[sStT]/) exit 1; printf "%d%d%d\n", digit(substr(p,2,3)), digit(substr(p,5,3)), digit(substr(p,8,3)) }
  ' 2>/dev/null)
  case "$_bmmis_mode" in [0-7][0-7][0-7]) ;; *) return 1 ;; esac
  _bmmis_owner=${_bmmis_mode%??}
  _bmmis_group=$(printf '%s' "$_bmmis_mode" | cut -c2)
  _bmmis_other=${_bmmis_mode#??}
  case "$_bmmis_owner" in 5|7) ;; *) return 1 ;; esac
  case "$_bmmis_group:$_bmmis_other" in *2*|*3*|*6*|*7*) return 1 ;; esac
  return 0
}

boot_mutation_state_usable() {
  case "$1:${MERV_BOOT_HOOK_REASON:-}" in
    present:*|absent:*|invalid:hook_shebang_invalid|invalid:hook_not_executable|invalid:legacy_replaceable) return 0 ;;
    *) return 1 ;;
  esac
}

boot_mutate_template() {
  _bmt_action="$1" _bmt_tmpl="$2" _bmt_dest="$3"
  [ -f "$_bmt_tmpl" ] && [ -r "$_bmt_tmpl" ] || { error -c vlan,cli "Template missing or unreadable: $_bmt_tmpl"; return 1; }
  _bmt_tplid=${_bmt_tmpl##*/}
  case "$_bmt_tplid" in
    services-start.v1.tpl|services-start.v2.tpl) _bmt_kind=services-start ;;
    services-start-addon.v1.tpl|services-start-addon.v2.tpl) _bmt_kind=services-start-addon ;;
    service-event.v1.tpl|service-event.v2.tpl) _bmt_kind=service-event ;;
    *) error -c vlan,cli "Unsupported boot template id: $_bmt_tplid"; return 1 ;;
  esac
  case "$_bmt_kind:${_bmt_dest##*/}" in
    services-start:services-start|services-start-addon:services-start|service-event:service-event) ;;
    *) error -c vlan,cli "Boot template and destination do not match"; return 1 ;;
  esac
  boot_mutation_lock_begin "$_bmt_dest" || { error -c vlan,cli "Could not acquire boot-file owner lock for $_bmt_dest"; return 1; }
  _boot_mutation_stage_dir=''
  MERV_BOOT_MUTATION_POSTCOMMIT_FAILURE=0
  trap 'boot_mutation_signal 129' HUP
  trap 'boot_mutation_signal 130' INT
  trap 'boot_mutation_signal 143' TERM
  _bmt_rc=0
  _bmt_check_name="$_bmt_kind"
  merv_boot_hook_state "$_bmt_dest" "$_bmt_check_name" "$MERV_BASE" >/dev/null
  _bmt_existing="$MERV_BOOT_HOOK_STATE"
  if ! boot_mutation_state_usable "$_bmt_existing"; then
    error -c vlan,cli "Refusing unsafe boot-hook destination $_bmt_dest (${MERV_BOOT_HOOK_REASON:-unknown})"
    _bmt_rc=1
  elif [ "$_bmt_action" = remove ] && [ "$_bmt_existing" = absent ]; then
    _bmt_rc=0
  else
    _bmt_start=${MERV_BOOT_HOOK_START_LINE:-0}
    _bmt_end=${MERV_BOOT_HOOK_END_LINE:-0}
    _bmt_keep_first=0
    _bmt_shebang='#!/bin/sh'
    if [ -f "$_bmt_dest" ]; then
      IFS= read -r _bmt_first < "$_bmt_dest" || _bmt_first=''
      _bmt_cr=$(printf '\r')
      case "$_bmt_first" in *"$_bmt_cr") _bmt_first=${_bmt_first%"$_bmt_cr"} ;; esac
      case "$_bmt_first" in
        '#!/bin/sh'|'#!/bin/ash') _bmt_shebang="$_bmt_first"; _bmt_keep_first=1 ;;
        '#!'*) error -c vlan,cli "Refusing unsupported startup shebang in $_bmt_dest"; _bmt_rc=1 ;;
      esac
    fi
    _bmt_parent=${_bmt_dest%/*}
    if [ "$_bmt_rc" -eq 0 ] && ! mkdir -p "$_bmt_parent" 2>/dev/null; then _bmt_rc=1; fi
    if [ "$_bmt_rc" -eq 0 ] && { [ -L "$_bmt_dest" ] || { [ -e "$_bmt_dest" ] && [ ! -f "$_bmt_dest" ]; }; }; then _bmt_rc=1; fi
    if [ "$_bmt_rc" -eq 0 ] && ! merv_boot_path_check "$_bmt_dest"; then _bmt_rc=1; fi
    if [ "$_bmt_rc" -eq 0 ] && boot_mutation_tempdir_create "$_bmt_parent"; then
      _bmt_block="$_boot_mutation_stage_dir/block"
      _bmt_content="$_boot_mutation_stage_dir/${_bmt_dest##*/}"
      _bmt_md5=$(_content_md5 "$_bmt_tmpl")
      case "$_bmt_md5" in ????????????????????????????????) ;; *) _bmt_rc=1 ;; esac
      if [ "$_bmt_rc" -eq 0 ]; then
        if boot_mutation_fault stage_write || boot_mutation_fault no_space; then
          printf '%s\n' "$MARKER_PREFIX ${_bmt_dest##*/} [tpl=$_bmt_tplid md5=$_bmt_md5]" > "$_bmt_block" 2>/dev/null || :
          _bmt_rc=1
        else
          {
            printf '%s\n' "$MARKER_PREFIX ${_bmt_dest##*/} [tpl=$_bmt_tplid md5=$_bmt_md5]"
            if IFS= read -r _bmt_template_first < "$_bmt_tmpl" 2>/dev/null && [ "${_bmt_template_first#\#!}" != "$_bmt_template_first" ]; then sed '1d' "$_bmt_tmpl"; else cat "$_bmt_tmpl"; fi
            printf '%s\n' "$MARKER_SUFFIX ${_bmt_dest##*/} [tpl=$_bmt_tplid md5=$_bmt_md5]"
          } > "$_bmt_block" 2>/dev/null || _bmt_rc=1
        fi
      fi
      if [ "$_bmt_rc" -eq 0 ]; then
        if boot_mutation_fault signal_before_commit; then
          kill -TERM "$$"
          sleep 1
          _bmt_rc=1
        fi
      fi
      if [ "$_bmt_rc" -eq 0 ]; then
        _bmt_input=/dev/null
        [ ! -f "$_bmt_dest" ] || _bmt_input="$_bmt_dest"
        LC_ALL=C awk -v start="$_bmt_start" -v end="$_bmt_end" -v block="$_bmt_block" -v action="$_bmt_action" -v add_shebang="$((1 - _bmt_keep_first))" '
          function emit_block(   line) { while ((getline line < block) > 0) print line; close(block) }
          BEGIN { if (add_shebang) print "#!/bin/sh" }
          NR == start && start > 0 { if (action == "insert") emit_block(); next }
          NR > start && NR <= end && start > 0 { next }
          { print }
          END { if (action == "insert" && start == 0) emit_block() }
        ' "$_bmt_input" > "$_bmt_content" 2>/dev/null || _bmt_rc=1
      fi
      if [ "$_bmt_rc" -eq 0 ] && [ "$_bmt_action" = remove ] && [ "$_bmt_start" = 0 ]; then _bmt_rc=1; fi
      if [ "$_bmt_rc" -eq 0 ] && [ "$_bmt_existing" = present ] && \
         boot_mutation_mode_is_safe "$_bmt_dest" && cmp -s "$_bmt_content" "$_bmt_dest" 2>/dev/null; then
        _bmt_noop=1
      else
        _bmt_noop=0
      fi
      if [ "$_bmt_rc" -eq 0 ] && [ "$_bmt_noop" = 0 ]; then
        if boot_mutation_fault chmod; then
          _bmt_rc=1
        else
          _bmt_mode=$(boot_mutation_old_mode "$_bmt_dest")
          case "$_bmt_mode" in [0-7][0-7][0-7]) ;; *) _bmt_mode=755 ;; esac
          chmod "$_bmt_mode" "$_bmt_content" 2>/dev/null || _bmt_rc=1
          [ -x "$_bmt_content" ] || chmod 755 "$_bmt_content" 2>/dev/null || _bmt_rc=1
        fi
        if [ "$_bmt_rc" -eq 0 ]; then
          if boot_mutation_fault syntax; then _bmt_rc=1; else "${MERV_BOOT_SH_BIN:-/bin/sh}" -n "$_bmt_content" >/dev/null 2>&1 || _bmt_rc=1; fi
        fi
        if [ "$_bmt_rc" -eq 0 ]; then
          _bmt_check=$(merv_boot_hook_state "$_bmt_content" "$_bmt_check_name" "$MERV_BASE")
          if [ "$_bmt_action" = insert ]; then [ "$_bmt_check" = present ] || _bmt_rc=1; else [ "$_bmt_check" = absent ] || _bmt_rc=1; fi
        fi
        if [ "$_bmt_rc" -eq 0 ] && boot_mutation_fault rename; then _bmt_rc=1; fi
        if [ "$_bmt_rc" -eq 0 ]; then mv -f "$_bmt_content" "$_bmt_dest" 2>/dev/null || _bmt_rc=1; fi
        if [ "$_bmt_rc" -eq 0 ]; then
          if boot_mutation_fault post_readback; then
            _bmt_rc=1
          else
            _bmt_post=$(merv_boot_hook_state "$_bmt_dest" "$_bmt_check_name" "$MERV_BASE")
            if [ "$_bmt_action" = insert ]; then [ "$_bmt_post" = present ] || _bmt_rc=1; else [ "$_bmt_post" = absent ] || _bmt_rc=1; fi
          fi
          if [ "$_bmt_rc" -ne 0 ]; then
            MERV_BOOT_MUTATION_POSTCOMMIT_FAILURE=1
            error -c vlan,cli "Boot-hook rename committed but post-commit verification failed for $_bmt_dest; recovery is required"
          fi
        fi
      fi
    else
      [ "$_bmt_rc" -ne 0 ] || { error -c vlan,cli "Could not allocate a same-directory boot-hook staging area"; _bmt_rc=1; }
    fi
  fi
  boot_mutation_cleanup_stage || { warn -c vlan,cli "Boot-hook staging cleanup failed at ${_boot_mutation_stage_dir:-unknown}"; _bmt_rc=1; }
  boot_mutation_lock_end || { warn -c vlan,cli "Could not release boot-file owner lock for $_bmt_dest"; _bmt_rc=1; }
  trap - HUP INT TERM
  [ "$_bmt_rc" -eq 0 ]
}

# copy_inject — Marker-bounded atomic insertion/replacement.
copy_inject() { boot_mutate_template insert "$1" "$2"; }

# The public remover shares the same locked staging path as insertion. Keep the
# original function name and template/destination caller contract.
remove_inject() {
  boot_mutate_template remove "$1" "$2"
}

# ============================================================================== #
# NODE ORCHESTRATION HELPERS — SSH connectivity, node discovery, status polling  #
# ============================================================================== #

# get_node_ips — Extract NODE1-NODE10 IPs from settings.json (same as sync_nodes.sh)
# Args: none (reads $SETTINGS_FILE global)
# Returns: stdout list of "node_id ip" pairs (one per line), or empty string if none
get_node_ips() {
    merv_node_list
}

# test_ssh_connection — Validate SSH connectivity to a specific node
# Args: $1 = node_ip, $2 = node_id (optional)
# Returns: 0 if "connected" echo received, 1 if SSH fails or no response
test_ssh_connection() {
    node_ip="$1"
    node_id="${2:-?}"
    merv_ssh_test "$node_id" "$node_ip"
}

# run_ssh_command — Execute a shell command on a remote node via SSH
# Args: $1 = node_ip, $2 = command (e.g., "enable", "disable"), $3 = node_id (optional)
# Returns: 0 on success, 1 if connection fails or command execution fails
# Context: Sets MERV_NODE_CONTEXT=1 so remote mervlan_boot.sh executes locally on node
run_ssh_command() {
    node_ip="$1"
    cmd="$2"
    node_id="${3:-?}"

  if is_node; then
    info -c cli,vlan "Node context detected; refusing to SSH to NODE${node_id} ($node_ip) for '$cmd'"
    return 0
  fi

    info -c cli,vlan "Running '$cmd' on NODE${node_id} ($node_ip) via SSH..."
    # Execute command on node with MERV_NODE_CONTEXT=1 (forces local node execution)
    remote="cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh '$cmd'"

  if merv_ssh_exec "$node_id" "$node_ip" "$remote" >/dev/null 2>&1; then
        info -c cli,vlan "✓ Command '$cmd' succeeded on NODE${node_id} ($node_ip)"
        return 0
    else
        merv_ssh_skip_log "$node_id" "$node_ip" "mervlan_boot '$cmd'"
        return 1
    fi
}

# handle_nodes_via_ssh — Batch propagate action to all configured nodes via SSH
# Args: $1 = action_name (e.g., "enable", "disable", "setupenable")
# Returns: 0 if all nodes succeeded, 1 if any failed (but continues all nodes)
# Context: Respects MERV_SKIP_NODE_SYNC=1 override flag for skipping propagation
handle_nodes_via_ssh() {
  cmd="$1"

  if is_node; then
    info -c cli,vlan "Node context detected; skipping node propagation for '$cmd'"
    return 0
  fi

  if [ "${MERV_SKIP_NODE_SYNC:-0}" = "1" ]; then
    info -c cli,vlan "Skipping node propagation for '$cmd' (MERV_SKIP_NODE_SYNC=1)"
    return 0
  fi

  NODE_IPS=$(get_node_ips)
  if [ -z "$NODE_IPS" ]; then
    return 0
  fi

  # Build display list of IPs for log
  _ip_list=""
  echo "$NODE_IPS" | while read -r _id _ip; do
    [ -n "$_ip" ] && _ip_list="$_ip_list $_ip"
  done
  info -c cli,vlan "Propagating '$cmd' to nodes:$_ip_list"

  overall_success=true
  while read -r node_id node_ip; do
    [ -n "$node_ip" ] || continue
    if ! run_ssh_command "$node_ip" "$cmd" "$node_id"; then
      overall_success=false
    fi
  done <<EOF
$NODE_IPS
EOF

  if [ "$overall_success" = "true" ]; then
    info -c cli,vlan "✓ All nodes processed successfully for '$cmd'"
    return 0
  else
    warn -c cli,vlan "⚠️  Some nodes failed for '$cmd'"
    return 1
  fi
}

# collect_node_status — Quietly poll all nodes via report action for status aggregation
# Args: none (reads NODE_IPS from get_node_ips)
# Sets: $NODE_STATUS_OUTPUT global (newline-separated "ip:status" pairs)
# Returns: none (always succeeds, unreachable nodes marked as such)
# Context: Used by status action to aggregate node state without verbose per-node logs
collect_node_status() {
  if is_node; then
    NODE_STATUS_OUTPUT=""
    return 0
  fi

    NODE_IPS=$(get_node_ips)
    [ -z "$NODE_IPS" ] && return 0

    NODE_STATUS_OUTPUT=""
    while read -r node_id node_ip; do
      [ -n "$node_ip" ] || continue
      # Single SSH invocation per node; grab the last line from remote's report
      ns=$(merv_ssh_exec "$node_id" "$node_ip" "cd '$MERV_BASE/functions' && sh ./mervlan_boot.sh report" 2>/dev/null | tail -1)
      if [ -n "$ns" ]; then
        # Normalize empty reply
        [ -n "$ns" ] || ns="REPORT error=empty"
        # store one entry per-line for robust parsing later
        NODE_STATUS_OUTPUT="${NODE_STATUS_OUTPUT}
      ${node_ip}:${ns#REPORT }"
      else
        NODE_STATUS_OUTPUT="${NODE_STATUS_OUTPUT}
      ${node_ip}:unreachable"
      fi
    done <<EOF
$NODE_IPS
EOF
}

# check_mac_shield_state — Sets $mac_shield_state to "on(N)" or "off".
# Used by status) and report) to surface MERV_MAC chain enforcement state.
check_mac_shield_state() {
  mac_shield_state="off"
  if type ebtables >/dev/null 2>&1; then
    _ms_rules=$(ebtables -t filter -L MERV_MAC 2>/dev/null | grep -c "^-s " 2>/dev/null || :)
    if [ "${_ms_rules:-0}" -gt 0 ]; then
      mac_shield_state="on(${_ms_rules})"
    fi
  fi
}

enable_cron_now() {
  if [ -z "$CRU_BIN" ]; then
    warn -c vlan,cli "Cron enable skipped: cru command not available"
    return 0
  fi

  info -c vlan,cli "Enabling cron: $CRON_NAME (*/5) -> $INJ_BASE/functions/heal_event.sh cron"
  "$CRU_BIN" d "$CRON_NAME" 2>/dev/null

  if "$CRU_BIN" a "$CRON_NAME" "*/5 * * * * $INJ_BASE/functions/heal_event.sh cron"; then
    info -c vlan,cli "Cron job $CRON_NAME added"
  else
    error -c vlan,cli "Failed to add cron job $CRON_NAME"
    return 1
  fi

  if merv_boot_cron_state "$CRU_BIN" "$INJ_BASE" >/dev/null && \
     [ "$MERV_BOOT_CRON_STATE" = present ]; then
    info -c vlan,cli "Cron confirmed for $CRON_NAME"
  else
    warn -c vlan,cli "Cron verification failed: $CRON_NAME not listed"
  fi
}

disable_cron_now() {
  if [ -z "$CRU_BIN" ]; then
    warn -c vlan,cli "Cron disable skipped: cru command not available"
    return 1
  fi

  "$CRU_BIN" d "$CRON_NAME" 2>/dev/null

  if ! merv_boot_cron_state "$CRU_BIN" "$INJ_BASE" >/dev/null; then
    warn -c vlan,cli "Cron disable verification failed; could not list cron entries"
    return 1
  fi

  case "$MERV_BOOT_CRON_STATE" in
    present)
      warn -c vlan,cli "Cron disable verification failed; entry still present"
      return 1
      ;;
    invalid)
      warn -c vlan,cli "Cron disable verification failed; malformed MerVLAN cron residue remains"
      return 1
      ;;
    absent) info -c vlan,cli "Cron disabled: $CRON_NAME" ;;
    *)
      warn -c vlan,cli "Cron disable verification failed; state is unknown"
      return 1
      ;;
  esac
  return 0
}

boot_verify_action_state() {
  _bvas_expected="$1"
  _bvas_role=main
  is_node && _bvas_role=node
  if merv_boot_verify_local "$_bvas_expected" "$_bvas_role" \
      "$SERVICES_START" "$SERVICE_EVENT_WRAPPER" "$SETTINGS_FILE" \
      "${CRU_BIN:-}" "$MERV_BASE"; then
    _boot_verify_reason=verified
    return 0
  fi
  _boot_verify_reason="${MERV_BOOT_VERIFY_REASON:-unknown}"
  return 1
}

boot_verify_action_hard_failure() {
  case "${_boot_verify_reason:-}" in
    cron_unknown|cron_mismatch) return 1 ;;
    *) return 0 ;;
  esac
}

# =============================================================================== #
# MAIN ACTION DISPATCH — Entry point for all actions (enable/disable/status/etc)  #
# =============================================================================== #

# Node-propagating boot actions must prove the complete configured node set
# before touching local hooks, cron, ebtables, or boot state.  Internal node
# invocations and explicitly quiesced update/recovery flows already own their
# separate preflight and therefore opt out here.
case "$ACTION" in
  enable|disable|setupenable|setupdisable|nodeenable|nodedisable)
    if [ "${MERV_NODE_CONTEXT:-0}" != "1" ] && [ "${MERV_SKIP_NODE_SYNC:-0}" != "1" ]; then
      if ! merv_ssh_preflight_configured_nodes; then
        if node_preflight_failure_is_transient; then
          if [ "${MERV_NODE_RECONCILE_SUPPRESS_SCHEDULE:-0}" != "1" ]; then
            schedule_node_reconcile "$ACTION" || :
          fi
          boot_action_ack_error "Boot action deferred: configured node is temporarily unreachable; retry is scheduled" \
            '{"reason":"node-unreachable"}' "NODE_UNREACHABLE"
          error -c vlan,cli "Boot action '$ACTION' deferred before local mutation: ${MERV_SSH_LAST_DETAIL:-node temporarily unreachable}"
        else
          boot_action_ack_error "Boot action blocked: complete SSH trust preflight failed" \
            '{"reason":"ssh-trust-required"}' "SSH_TRUST_REQUIRED"
          error -c vlan,cli "Boot action '$ACTION' refused before local mutation: ${MERV_SSH_LAST_DETAIL:-SSH trust preflight failed}"
        fi
        exit 1
      fi
    fi
    ;;
esac

case "$ACTION" in
  reconcile-pending)
    process_pending_node_reconcile
    exit $?
    ;;
  # =========================================================================== #
  # enable — Boot MerVLAN at router startup; enable mervlan.asp auto-load       #
  # =========================================================================== #
  enable)
    _boot_partial=0
    _boot_warnings='[]'
    # Inject services-start code to auto-load mervlan.asp at system boot
    inject_template "$TEMPLATE_SERVICES" "$SERVICES_START" || {
      error -c vlan,cli "Failed to install services-start"
      boot_action_ack_error "Failed to install services-start" "SERVICES_START_INSTALL_FAILED"
      exit 1
    }
    info -c vlan,cli "Installed services-start with MERV_BASE=$MERV_BASE (service-event managed at setup)"

    # Persist boot enabled state to settings.json
    if ! persist_boot_enabled_state "1"; then
      warn -c vlan,cli "Failed to persist BOOT_ENABLED=1"
      _boot_partial=1
      _boot_warnings='["BOOT_ENABLED could not be persisted"]'
    fi
    # Enable cron job for periodic VLAN health checks (main + nodes)
    if ! enable_cron_now; then
      _boot_partial=1
      _boot_warnings='["One or more secondary enable operations failed"]'
    fi
    if ! boot_verify_action_state 1; then
      if boot_verify_action_hard_failure; then
        error -c vlan,cli "Boot enable local integrity verification failed: $_boot_verify_reason"
        boot_action_ack_error "Boot enable local integrity verification failed" "{}" "BOOT_HOOK_VERIFY_FAILED"
        exit 1
      fi
      _boot_partial=1
      _boot_warnings='["Boot preference and manager hook match, but local cron could not be verified"]'
    fi

    # Required local enforcement precedes propagation; a failed reload is an
    # explicit partial recovery state, never a completed boot enable action.
    _boot_mac_enforced=1
    if type ebt_mac_shield_init_and_apply >/dev/null 2>&1; then
      if ebt_mac_shield_init_and_apply "$(merv_mac_best_db 2>/dev/null || true)"; then
        info -c vlan,cli "MERV_MAC: secondary shield armed"
      else
        _boot_mac_enforced=0
        _boot_partial=1
        _boot_warnings='["Boot enable is incomplete: local MAC Shield enforcement failed; recovery is required"]'
        error -c vlan,cli "MERV_MAC: local shield enforcement failed; node boot enable propagation suppressed"
      fi
    else
      _boot_mac_enforced=0
      _boot_partial=1
      _boot_warnings='["Boot enable is incomplete: MAC Shield enforcement is unavailable; recovery is required"]'
      error -c vlan,cli "MERV_MAC: shield enforcement is unavailable; node boot enable propagation suppressed"
    fi

    # Propagate enable action to all configured nodes via SSH
    if [ "$_boot_mac_enforced" = "1" ] && ! handle_nodes_via_ssh "enable"; then
      _boot_partial=1
      _boot_warnings='["Boot enable succeeded locally; one or more nodes could not be reached"]'
    fi
    if [ "$_boot_partial" = "1" ]; then
      boot_action_ack_complete partial 1 "Boot service enabled with warnings" "$_boot_warnings"
    else
      boot_action_ack_complete ok 1 "Boot service enabled"
    fi
    ;;

  # =============================================================================== #
  # disable — Disable boot; remove services-start injection but keep service-event  #
  # =============================================================================== #
  disable)
    _boot_partial=0
    _boot_warnings='[]'
    # Remove injected services-start code (idempotent; no-op if not found)
    if [ -f "$SERVICES_START" ]; then
      if ! remove_template_block "$TEMPLATE_SERVICES" "$SERVICES_START"; then
        error -c vlan,cli "Failed to remove injected services-start content"
        boot_action_ack_error "Failed to remove services-start content" "SERVICES_START_REMOVE_FAILED"
        exit 1
      fi
    fi
    # Persist boot disabled state to settings.json
    if ! persist_boot_enabled_state "0"; then
      warn -c vlan,cli "Failed to persist BOOT_ENABLED=0"
      _boot_partial=1
      _boot_warnings='["BOOT_ENABLED could not be persisted"]'
    fi

    info -c vlan,cli "Removed services-start injection (service-event unchanged)"

    # Disable cron job (main + nodes)
    if ! disable_cron_now; then
      _boot_partial=1
      _boot_warnings='["One or more secondary disable operations failed"]'
    fi
    if ! boot_verify_action_state 0; then
      if boot_verify_action_hard_failure; then
        error -c vlan,cli "Boot disable local integrity verification failed: $_boot_verify_reason"
        boot_action_ack_error "Boot disable local integrity verification failed" "{}" "BOOT_HOOK_VERIFY_FAILED"
        exit 1
      fi
      _boot_partial=1
      _boot_warnings='["Boot preference and manager hook match, but local cron could not be verified"]'
    fi

    # Tear down MERV_MAC secondary shield (db files retained for re-enable)
    if type ebt_mac_shield_teardown >/dev/null 2>&1; then
      if ebt_mac_shield_teardown; then
        info -c vlan,cli "MERV_MAC: secondary shield torn down (db files retained)"
      else
        warn -c vlan,cli "MERV_MAC: secondary shield teardown reported an error"
        _boot_partial=1
      fi
    fi

    # Propagate disable action to all configured nodes via SSH
    if ! handle_nodes_via_ssh "disable"; then
      _boot_partial=1
      _boot_warnings='["Boot disable succeeded locally; one or more nodes could not be reached"]'
    fi
    if [ "$_boot_partial" = "1" ]; then
      boot_action_ack_complete partial 0 "Boot service disabled with warnings" "$_boot_warnings"
    else
      boot_action_ack_complete ok 0 "Boot service disabled"
    fi
    ;;

  # ========================================================================== #
  # cron — enable and disable cron jobs for periodic VLAN health checks        #
  # ========================================================================== #

  cronenable)
    if enable_cron_now; then
      info -c vlan,cli "cronenable action completed"
      exit 0
    fi
    error -c vlan,cli "cronenable action failed"
    exit 1
    ;;

  crondisable)
    if disable_cron_now; then
      info -c vlan,cli "crondisable action completed"
      exit 0
    fi
    error -c vlan,cli "crondisable action failed"
    exit 1
    ;;

  # ========================================================================== #
  # setupenable — Setup-only: install service-event wrapper on main router     #
  # ========================================================================== #
  setupenable)
    if ! reconcile_legacy_boot_file_locks; then
      error -c vlan,cli "Refusing setupenable while legacy boot-file lock state is ambiguous"
      exit 1
    fi
    # Inject service-event wrapper into system rc_service handler
    inject_template "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER" || { error -c vlan,cli "Failed to install service-event"; exit 1; }
    marker_present "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER" || { error -c vlan,cli "Service-event injection verification failed"; exit 1; }
    # Inject addon boot entry into services-start (for addon install.sh auto-load)
    inject_template "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START" || { error -c vlan,cli "Failed to install addon boot entry"; exit 1; }
    marker_present "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START" || { error -c vlan,cli "services-start injection verification failed"; exit 1; }
    _setup_role=main
    is_node && _setup_role=node
    if ! merv_boot_verify_baseline "$_setup_role" "$SERVICES_START" "$SERVICE_EVENT_WRAPPER" "$SETTINGS_FILE" "$MERV_BASE"; then
      error -c vlan,cli "Setup hook integrity verification failed: ${MERV_BOOT_VERIFY_REASON:-unknown}"
      exit 1
    fi
    info -c vlan,cli "Installed service-event with MERV_BASE=$MERV_BASE (setup-only)"
    # Propagate setupenable to all configured nodes via SSH
    handle_nodes_via_ssh "setupenable"
    ;;

  # ========================================================================== #
  # setupdisable — Setup-only: remove service-event wrapper and addon entry    #
  # ========================================================================== #
  setupdisable)
    if ! reconcile_legacy_boot_file_locks; then
      error -c vlan,cli "Refusing setupdisable while legacy boot-file lock state is ambiguous"
      exit 1
    fi
    _setupdisable_failed=0
    # Remove injected service-event wrapper content (idempotent)
    if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
      if ! remove_template_block "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER"; then
        error -c vlan,cli "Failed to remove injected service-event content"
        _setupdisable_failed=1
      elif marker_present "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER"; then
        error -c vlan,cli "Service-event injection remains after setupdisable"
        _setupdisable_failed=1
      else
        info -c vlan,cli "Removed service-event injection (setup-only disable)"
      fi
    else
      info -c vlan,cli "service-event not present; nothing to disable"
    fi
    # Remove injected addon boot entry from services-start (idempotent)
    if [ -f "$SERVICES_START" ]; then
      if ! remove_template_block "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START"; then
        error -c vlan,cli "Failed to remove addon boot entry"
        _setupdisable_failed=1
      elif marker_present "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START"; then
        error -c vlan,cli "Addon boot entry remains after setupdisable"
        _setupdisable_failed=1
      fi
    fi
    merv_boot_hook_state "$SERVICE_EVENT_WRAPPER" service-event >/dev/null
    [ "$MERV_BOOT_HOOK_STATE" = absent ] || _setupdisable_failed=1
    merv_boot_hook_state "$SERVICES_START" services-start-addon >/dev/null
    [ "$MERV_BOOT_HOOK_STATE" = absent ] || _setupdisable_failed=1
    # Tear down MERV_QT quarantine chain: flush rules, remove FORWARD/INPUT
    # jumps, then delete chain. Strict ebtables order: -F before -D, -D before
    # -X. No restart_wireless needed — rules vanish silently in milliseconds.
    if type ebtables >/dev/null 2>&1; then
      if ! merv_qt_teardown; then
        error -c vlan,cli "MERV_QT: quarantine chain teardown failed"
        exit 1
      fi
      info -c vlan,cli "MERV_QT: quarantine chain torn down"
    fi
    # Tear down MERV_MAC secondary shield and remove persistent db files
    if ! ebt_mac_shield_teardown; then
      error -c vlan,cli "MERV_MAC: secondary shield teardown failed"
      exit 1
    fi
    info -c vlan,cli "MERV_MAC: secondary shield torn down"
    if ! rm -f "$MERV_MAC_DB_ACTIVE" "$MERV_MAC_DB_JFFS" 2>/dev/null; then
      error -c vlan,cli "MERV_MAC: could not remove persistent shield database files"
      exit 1
    fi
    # Propagate setupdisable to all configured nodes via SSH. Preserve any
    # local hook-removal failure even if node propagation itself succeeds.
    if ! handle_nodes_via_ssh "setupdisable"; then
      _setupdisable_failed=1
    fi
    [ "$_setupdisable_failed" -eq 0 ] || exit 1
    ;;
  
  # ========================================================================== #
  # nodeenable — Node-side setup: install mervlan_boot.sh and service-event    #
  # ========================================================================== #
  nodeenable)
    scope="${2:-}"
    force_local=0
    # Check for --local flag to force node-local execution
    case "$scope" in
      --local|-l|local) force_local=1 ;;
    esac
    # Check for MERV_FORCE_LOCAL override environment variable
    if [ "${MERV_FORCE_LOCAL:-0}" = "1" ]; then
      force_local=1
    fi
    if is_node; then
      force_local=1
    fi
    # Execute locally on this node if MERV_NODE_CONTEXT=1 (SSH propagation) or force_local=1
    if [ "${MERV_NODE_CONTEXT:-0}" = "1" ] || [ "$force_local" = "1" ]; then
      if ! is_node; then
        error -c vlan,cli "Refusing nodeenable on this device (not marked as node)"
        error -c vlan,cli "Ensure IS_NODE is 1 in settings.json or run via SSH with MERV_NODE_CONTEXT=1"
        exit 1
      fi
      if ! reconcile_legacy_boot_file_locks; then
        error -c vlan,cli "Refusing nodeenable while legacy boot-file lock state is ambiguous"
        exit 1
      fi
      # Shared handler now lives under functions/ and is synced from main
      if [ -n "${SERVICE_EVENT_HANDLER:-}" ] && [ -f "$SERVICE_EVENT_HANDLER" ]; then
        chmod 755 "$SERVICE_EVENT_HANDLER" 2>/dev/null || \
          warn -c vlan,cli "Could not chmod 755 $SERVICE_EVENT_HANDLER"
      else
        warn -c vlan,cli "service-event-handler missing at $SERVICE_EVENT_HANDLER"
      fi

      # Install the configured-node baseline from the currently active target
      # templates.  BOOT_ENABLED remains owned by the later enable/disable
      # action; nodeenable only establishes service-event and addon mounting.
      inject_template "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER" || { error -c vlan,cli "Failed to install node service-event"; exit 1; }
      inject_template "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START" || { error -c vlan,cli "Failed to install node addon boot entry"; exit 1; }
      if ! merv_boot_verify_baseline node "$SERVICES_START" "$SERVICE_EVENT_WRAPPER" "$SETTINGS_FILE" "$MERV_BASE"; then
        error -c vlan,cli "Node baseline hook integrity verification failed: ${MERV_BOOT_VERIFY_REASON:-unknown}"
        exit 1
      fi
      if [ -n "$BOOT_SCRIPT" ]; then
        chmod 755 "$BOOT_SCRIPT" 2>/dev/null || warn -c vlan,cli "Could not chmod 755 $BOOT_SCRIPT"
      fi

      info -c vlan,cli "Installed node service-event and addon boot templates (MERV_BASE=$MERV_BASE)"
      exit 0
    fi

    # Get list of configured nodes for propagation
    NODE_IPS=$(get_node_ips)
    if [ -z "$NODE_IPS" ]; then
      info -c vlan,cli "No nodes configured; skipping nodeenable"
      exit 0
    fi

    # Log propagation targets
    NODE_LIST=$(echo "$NODE_IPS" | tr '\n' ' ')
    info -c vlan,cli "Propagating nodeenable to nodes: $NODE_LIST"
    # Propagate to all nodes via SSH
    handle_nodes_via_ssh "nodeenable"
    exit 0
    ;;

  # ============================================================================ #
  # nodedisable — Node-side cleanup: remove mervlan_boot.sh and service-event    #
  # ============================================================================ #
  nodedisable)
    scope="${2:-}"
    force_local=0
    # Check for --local flag to force node-local execution
    case "$scope" in
      --local|-l|local) force_local=1 ;;
    esac
    # Check for MERV_FORCE_LOCAL override environment variable
    if [ "${MERV_FORCE_LOCAL:-0}" = "1" ]; then
      force_local=1
    fi
    if is_node; then
      force_local=1
    fi
    # Execute locally on this node if MERV_NODE_CONTEXT=1 (SSH propagation) or force_local=1
    if [ "${MERV_NODE_CONTEXT:-0}" = "1" ] || [ "$force_local" = "1" ]; then
      if ! is_node; then
        info -c vlan,cli "Not flagged as node; skipping nodedisable"
        exit 0
      fi
      if ! disable_cron_now; then
        error -c vlan,cli "Could not disable MerVLAN health cron on node"
        exit 1
      fi
      # Remove node service-event wrapper injection if present
      if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
        remove_template_block "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER" \
        || { error -c vlan,cli "Failed to remove node service-event"; exit 1; }
      else
        info -c vlan,cli "service-event not present on node; nothing to disable"
      fi
      # Remove both node-owned services-start blocks.  disable normally removes
      # the active manager block first, but nodedisable is deliberately complete
      # and idempotent when called on its own during recovery/uninstall.
      _nodedisable_failed=0
      if [ -f "$SERVICES_START" ]; then
        if ! remove_template_block "$TEMPLATE_SERVICES" "$SERVICES_START"; then
          error -c vlan,cli "Failed to remove services-start block"
          _nodedisable_failed=1
        elif marker_present "$TEMPLATE_SERVICES" "$SERVICES_START"; then
          error -c vlan,cli "Manager services-start block remains after nodedisable"
          _nodedisable_failed=1
        fi
        if ! remove_template_block "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START"; then
          error -c vlan,cli "Failed to remove addon boot block"
          _nodedisable_failed=1
        elif marker_present "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START"; then
          error -c vlan,cli "Addon boot block remains after nodedisable"
          _nodedisable_failed=1
        fi
      fi
      merv_boot_hook_state "$SERVICES_START" services-start >/dev/null
      [ "$MERV_BOOT_HOOK_STATE" = absent ] || _nodedisable_failed=1
      merv_boot_hook_state "$SERVICES_START" services-start-addon >/dev/null
      [ "$MERV_BOOT_HOOK_STATE" = absent ] || _nodedisable_failed=1
      merv_boot_hook_state "$SERVICE_EVENT_WRAPPER" service-event >/dev/null
      [ "$MERV_BOOT_HOOK_STATE" = absent ] || _nodedisable_failed=1
      # Tear down MERV_QT quarantine chain on this node
      if type ebtables >/dev/null 2>&1; then
        if ! merv_qt_teardown; then
          error -c vlan,cli "MERV_QT: quarantine chain teardown failed"
          exit 1
        fi
        info -c vlan,cli "MERV_QT: quarantine chain torn down"
      fi
      # Tear down MERV_MAC secondary shield and remove persistent db files
      if ! ebt_mac_shield_teardown; then
        error -c vlan,cli "MERV_MAC: secondary shield teardown failed"
        exit 1
      fi
      info -c vlan,cli "MERV_MAC: secondary shield torn down"
      if ! rm -f "$MERV_MAC_DB_ACTIVE" "$MERV_MAC_DB_JFFS" 2>/dev/null; then
        error -c vlan,cli "MERV_MAC: could not remove persistent shield database files"
        exit 1
      fi
      [ "$_nodedisable_failed" -eq 0 ] || exit 1
      exit 0
    fi

    # Get list of configured nodes for propagation
    NODE_IPS=$(get_node_ips)
    if [ -z "$NODE_IPS" ]; then
      info -c vlan,cli "No nodes configured; skipping nodedisable"
      exit 0
    fi

    # Log propagation targets
    NODE_LIST=$(echo "$NODE_IPS" | tr '\n' ' ')
    info -c vlan,cli "Propagating nodedisable to nodes: $NODE_LIST"
    # Propagate to all nodes via SSH
    handle_nodes_via_ssh "nodedisable"
    exit 0
    ;;

  # ========================================================================== #
  # status — Query current MerVLAN state (boot, addon, event, cron)            #
  # ========================================================================== #
  status)
    # Initialize all state indicators to default (absent/disabled)
    boot_state=unknown
    addon_state=missing
    event_state=missing
    cron_state=unknown
    manager_hook_state=unknown

    # Check persisted boot state in settings.json
    if merv_boot_read_preference "$SETTINGS_FILE" >/dev/null 2>&1; then
      case "$MERV_BOOT_PREFERENCE" in
        1) boot_state=enabled ;;
        0) boot_state=disabled ;;
      esac
    fi
    merv_boot_hook_state "$SERVICES_START" services-start >/dev/null
    manager_hook_state="$MERV_BOOT_HOOK_STATE"

    # Check if addon boot entry exists in services-start
    # Matches either legacy install.sh or current mervlan_boot_wrap.sh install
    if [ -f "$SERVICES_START" ] && grep -qE "mervlan/(install\.sh|functions/mervlan_boot_wrap\.sh install)" "$SERVICES_START" 2>/dev/null; then
      addon_state=active
    fi

    # Check if service-event wrapper is present and examine its state
    if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
      if grep -q "service-event disabled" "$SERVICE_EVENT_WRAPPER"; then
        event_state=disabled
      elif marker_present "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER"; then
        event_state=active
      else
        event_state=custom
      fi
    fi

    # Node-specific addon state: do not rely on install.sh on nodes
    if is_node; then
      if [ -f "$VLAN_MANAGER" ]; then
        case "$event_state" in
          active)
            addon_state="node-on"
            ;;
          custom)
            addon_state="node-custom"
            ;;
          disabled|missing|*)
            addon_state="node-off"
            ;;
        esac
      else
        addon_state="missing"
      fi
    fi

    if merv_boot_cron_state "$CRU_BIN" "$INJ_BASE" >/dev/null 2>&1; then
      cron_state="$MERV_BOOT_CRON_STATE"
    else
      cron_state=unknown
    fi

    # Local hardware label (main router) and node flag
    hw_label=""
    hw_label="$(json_get_flag "PRODUCTID" "Unknown" "$HW_SETTINGS_FILE" 2>/dev/null)"
    if is_node; then
      is_node_state=yes
    else
      is_node_state=no
    fi

    # MERV_MAC shield state
    check_mac_shield_state

    # Get list of configured nodes for status aggregation
    NODE_IPS=$(get_node_ips)
    if [ -n "$NODE_IPS" ]; then
      # Query nodes for their status via report action
      collect_node_status

      info -c vlan,cli "Status:"
      info -c vlan,cli "<--- Main Unit --->"
      info -c vlan,cli "${hw_label} boot=${boot_state} manager_hook=${manager_hook_state} addon=${addon_state} service-event=${event_state} cron=${cron_state} is_node=${is_node_state} mac_shield=${mac_shield_state}"
      info -c vlan,cli "<--- Configured Nodes --->"

      # NODE_STATUS_OUTPUT is newline-separated entries: ip:hw=LABEL boot=1 addon=.. event=.. cron=..
      printf '%s
    ' "$NODE_STATUS_OUTPUT" | sed 's/^[[:space:]]*//; /^$/d' | while IFS= read -r entry; do
        node_ip="${entry%%:*}"
        rest="${entry#*:}"

        # Default values
        node_hw="Unknown"
        node_boot_raw=""
        node_boot_preference=""
        node_addon=""
        node_event=""
        node_cron=""
        node_manager_hook="unknown"
        node_is_node=""
        node_mac_shield=""

        # Parse key=value pairs
        for kv in $rest; do
          case "$kv" in
            hw=*)           node_hw="${kv#hw=}" ;;
            boot=*)         node_boot_raw="${kv#boot=}" ;;
            boot_preference=*) node_boot_preference="${kv#boot_preference=}" ;;
            addon=*)        node_addon="${kv#addon=}" ;;
            event=*)        node_event="${kv#event=}" ;;
            cron=*)         node_cron="${kv#cron=}" ;;
            manager_hook=*) node_manager_hook="${kv#manager_hook=}" ;;
            is_node=*)      node_is_node="${kv#is_node=}" ;;
            mac_shield=*)   node_mac_shield="${kv#mac_shield=}" ;;
          esac
        done

        [ -z "$node_boot_preference" ] || node_boot_raw="$node_boot_preference"

        case "$node_boot_raw" in
          1) node_boot="enabled"  ;;
          0) node_boot="disabled" ;;
          *) node_boot="$node_boot_raw" ;;
        esac
        case "$node_manager_hook" in present|absent|invalid|unknown) ;; *) node_manager_hook=unknown ;; esac

        info -c vlan,cli "${node_hw} ${node_ip}:boot=${node_boot} manager_hook=${node_manager_hook} addon=${node_addon} event=${node_event} cron=${node_cron} is_node=${node_is_node} mac_shield=${node_mac_shield}"
      done
    else
      # No nodes configured; output local status only
      info -c vlan,cli "Status:"
      info -c vlan,cli "<--- Main Unit --->"
      info -c vlan,cli "${hw_label} boot=${boot_state} manager_hook=${manager_hook_state} addon=${addon_state} service-event=${event_state} cron=${cron_state} is_node=${is_node_state} mac_shield=${mac_shield_state}"
    fi

    if type merv_dhcp_hold_status >/dev/null 2>&1; then
      info -c vlan,cli "<--- DHCP Hold State --->"
      merv_dhcp_hold_status 2>&1 | while IFS= read -r _dhcp_status_line; do
        [ -n "$_dhcp_status_line" ] && info -c vlan,cli "$_dhcp_status_line"
      done
    fi
    if [ -x "$MERV_BASE/functions/post_apply_worker.sh" ]; then
      info -c vlan,cli "<--- Observation State --->"
      sh "$MERV_BASE/functions/post_apply_worker.sh" status 2>&1 |
        while IFS= read -r _observation_status_line; do
          [ -n "$_observation_status_line" ] && info -c vlan,cli "$_observation_status_line"
        done
    fi

    # ── Write service_status.json for the Settings modal ──────────────────
    # Lives in /tmp (tmpfs) so it never persists across reboots.
    # Populated only when the user presses the refresh button in the modal.
    _sj_dir="${PUBLIC_MERV_BASE:-/www/user/mervlan}/tmp/results"
    if ! mkdir -p "$_sj_dir" 2>/dev/null; then
      error -c vlan,cli "Could not prepare the service-status result directory"
      return 1
    fi
    _sj_ts="$(date '+%H:%M:%S' 2>/dev/null)"
    # Minimal inline JSON string escaping (backslash then quote)
    _json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

    # Build the nodes array inside a captured subshell so _sep stays local
    _sj_nodes="$(
      printf '%s\n' "$NODE_STATUS_OUTPUT" | sed 's/^[[:space:]]*//; /^$/d' | {
        _sep=""
        while IFS= read -r _e; do
          _nip="${_e%%:*}"; _nr="${_e#*:}"
          [ -n "$_nip" ] || continue
          _nh="Unknown"; _nb="?"; _bp=""; _na="?"; _nev="?"; _nc="?"; _nm="off"; _mh="unknown"
          for _kv in $_nr; do
            case "$_kv" in
              hw=*)         _nh="${_kv#hw=}" ;;
              boot=*)       _nb="${_kv#boot=}" ;;
              boot_preference=*) _bp="${_kv#boot_preference=}" ;;
              addon=*)      _na="${_kv#addon=}" ;;
              event=*)      _nev="${_kv#event=}" ;;
              cron=*)       _nc="${_kv#cron=}" ;;
              manager_hook=*) _mh="${_kv#manager_hook=}" ;;
              mac_shield=*) _nm="${_kv#mac_shield=}" ;;
            esac
          done
          [ -z "$_bp" ] || _nb="$_bp"
          case "$_nb" in 1) _nb="enabled";; 0) _nb="disabled";; esac
          case "$_mh" in present|absent|invalid|unknown) ;; *) _mh=unknown ;; esac
          printf '%s{"ip":"%s","hw":"%s","boot":"%s","manager_hook":"%s","addon":"%s","event":"%s","cron":"%s","mac":"%s"}' \
            "$_sep" "$_nip" "$(_json_str "$_nh")" "$_nb" "$_mh" "$_na" "$_nev" "$_nc" "$_nm"
          _sep=","
        done
      }
    )"

    if ! printf '{"ts":"%s","main":{"hw":"%s","boot":"%s","manager_hook":"%s","addon":"%s","event":"%s","cron":"%s","mac":"%s"},"nodes":[%s]}\n' \
      "$_sj_ts" "$(_json_str "$hw_label")" \
      "$boot_state" "$manager_hook_state" "$addon_state" "$event_state" "$cron_state" "$mac_shield_state" \
      "$_sj_nodes" \
      > "${_sj_dir}/service_status.json" 2>/dev/null; then
      error -c vlan,cli "Could not publish service-status JSON"
      return 1
    fi
    if ! chmod 644 "${_sj_dir}/service_status.json" 2>/dev/null; then
      error -c vlan,cli "Could not secure service-status JSON permissions"
      return 1
    fi
    ;;

  # ========================================================================== #
  # report — Terse machine-readable state output for remote aggregation        #
  # ========================================================================== #
  report)
    # Initialize state counters (boot uses 0/1 for machine readability)
    boot_state=0
    boot_preference=unknown
    addon_state=missing
    event_state=missing
    cron_state=unknown
    manager_hook_state=unknown
    is_node_state=no
    # Check persisted boot state and set boot_state to 1 if enabled
    if merv_boot_read_preference "$SETTINGS_FILE" >/dev/null 2>&1; then
      boot_preference="$MERV_BOOT_PREFERENCE"
      boot_state="$MERV_BOOT_PREFERENCE"
    fi
    merv_boot_hook_state "$SERVICES_START" services-start >/dev/null
    manager_hook_state="$MERV_BOOT_HOOK_STATE"
    # Check for addon boot entry in services-start (wrapper or legacy install.sh)
    if [ -f "$SERVICES_START" ] && grep -qE "mervlan/(install\.sh|functions/mervlan_boot_wrap\.sh install)" "$SERVICES_START" 2>/dev/null; then addon_state=active; fi
    # Check service-event wrapper and determine state: disabled/active/custom
    if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
      if grep -q "service-event disabled" "$SERVICE_EVENT_WRAPPER"; then
        event_state=disabled
      elif marker_present "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER"; then
        event_state=active
      else
        event_state=custom
      fi
    fi

    # Node-specific addon state for machine-readable report
    if is_node; then
      if [ -f "$VLAN_MANAGER" ]; then
        case "$event_state" in
          active)
            addon_state="node-on"
            ;;
          custom)
            addon_state="node-custom"
            ;;
          disabled|missing|*)
            addon_state="node-off"
            ;;
        esac
      else
        addon_state="missing"
      fi
    fi
    if merv_boot_cron_state "$CRU_BIN" "$INJ_BASE" >/dev/null 2>&1; then
      cron_state="$MERV_BOOT_CRON_STATE"
    else
      cron_state=unknown
    fi

        # Determine node state using the same helper as the rest of the script
    if is_node; then
      is_node_state=yes
    fi
    # Output terse report line: REPORT hw=<PRODUCTID> boot=0/1 addon=<state> event=<state> cron=<state> is_node=0/1
    # Used by collect_node_status() for remote aggregation via SSH
    # Hardware label from settings.json (PRODUCTID may be stored top-level or in
    # the Hardware block; json_get_flag handles legacy top-level keys while
    # var_settings.sh exposes HW_SETTINGS_FILE alias.)
    hw_label="$(json_get_flag "PRODUCTID" "Unknown" "$HW_SETTINGS_FILE" 2>/dev/null)"

    check_mac_shield_state

    echo "REPORT hw=$hw_label boot=$boot_state boot_preference=$boot_preference addon=$addon_state event=$event_state cron=$cron_state is_node=$is_node_state mac_shield=$mac_shield_state manager_hook=$manager_hook_state"
    exit 0
    ;;

  # ========================================================================== #
  # * — Default: unrecognized action or missing argument                       #
  # ========================================================================== #
  *)
    # Display usage information and exit with error code
    echo "Usage: $0 {enable|disable|cronenable|crondisable|status|setupenable|setupdisable|nodeenable|nodedisable|report}" >&2
    exit 2
    ;;
esac
