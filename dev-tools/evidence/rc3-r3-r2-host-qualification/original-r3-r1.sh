#!/bin/sh
# Standalone MerVLAN Emergency Repair.
# This source-free engine can be run from a separately verified copy; it never
# sources files from the installed addon.
set -u
LC_ALL=C; export LC_ALL
: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${MERV_REPAIR_TMP_ROOT:=/tmp}"
: "${MERV_REPAIR_PROC_ROOT:=/proc}"
: "${MERV_REPAIR_OWNER_PROC_ROOT:=/proc}"
: "${MERV_REPAIR_LOCK:=/tmp/mervlan_tmp/locks/mervlan_maintenance.lock}"
: "${MERV_REPAIR_LEGACY_LOCK_ROOT:=/tmp/mervlan_tmp/locks}"
: "${MERV_REPAIR_ACTION_LOCK:=/tmp/mervlan_tmp/locks/mervlan_action.lock}"
: "${MERV_REPAIR_MANAGER_LOCK:=/tmp/mervlan_tmp/locks/mervlan_manager.lock}"
: "${MERV_REPAIR_BACKUP_ROOT:=/jffs/addons/mervlan_backups}"
: "${MERV_REPAIR_SNAPSHOT_BASE:=https://codeload.github.com/r80xcore/mervlan/tar.gz}"
: "${MERV_REPAIR_MEMINFO:=/proc/meminfo}"
: "${MERV_REPAIR_CURL:=curl}"
# Minimum resources that must remain available at BOTH preflight checkpoints.
# KiB: 32768 = 32 MiB, 65536 = 64 MiB, 8192 = 8 MiB.
REPAIR_MIN_AVAILABLE_KIB=32768
REPAIR_MIN_TMP_FREE_KIB=65536
REPAIR_MIN_DEST_FREE_KIB=8192
WORK= ACTION_LOCKED=0 MAINTENANCE_LOCKED=0 MANAGER_LOCKED=0
TX=0 COMMITTED=0 ROLLBACK_OK=0 PUBLISHED=0 VERIFIED=0
SELECTED= REPLACEMENTS=58 SELECTED_BYTES=0
ACTION_PARENT=0 ACTION_PARENT_PID= ACTION_PARENT_START= ACTION_PARENT_NONCE=
LOCK_START= LOCK_CREATED= ACTION_NONCE= MAINTENANCE_NONCE= MANAGER_NONCE=
LOCK_SEQ=0 JOURNAL_SEQ=0 BACKUP_ESTIMATE=0 TXN_ID= HANDOFF_START=
LOCK_ACQUIRE_REASON= OWNER_CHECK_FAILURE=
RUN_START=$(date +%s 2>/dev/null || printf '0')
START_ID= REF= ROOT= COHORT= MANIFEST= STAGE= BACKUP= LEDGER= ARCHIVE=
BACKUP_ROOT= TXN_DIR= READY_FILE= INDEX_FILE= RECOVERY_HELPER= SOURCE_ROOT=
BACKUP_HASH_STYLE=
status() {
  now=$(date +%s 2>/dev/null || printf '%s' "$RUN_START")
  printf '[mervlan-lean] %s elapsed=%ss %s\n' "$1" "$((now-RUN_START))" "${2:-}" >&2
}
stop() { status ERROR "$*"; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
path_present() { exists "$1"; }
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
path_regular() { regular "$1"; }
# No symlinked ancestor or malformed filesystem path is trusted.
safe_chain() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  rest=${1#/}; part=/
  while [ -n "$rest" ]; do
    case "$rest" in */*) component=${rest%%/*}; rest=${rest#*/} ;; *) component=$rest; rest= ;; esac
    [ -n "$component" ] || return 1
    part="$part$component"
    if exists "$part"; then
      [ ! -L "$part" ] && [ -d "$part" ] && [ -x "$part" ] || return 1
    fi
    part="$part/"
  done
}
# Parents for the allowlisted cohort can be created, but never via symlinks.
ensure_dir() {
  safe_chain "$1" || return 1
  rest=${1#/}; part=/
  while [ -n "$rest" ]; do
    case "$rest" in */*) component=${rest%%/*}; rest=${rest#*/} ;; *) component=$rest; rest= ;; esac
    part="$part$component"
    if ! exists "$part"; then mkdir "$part" || return 1; fi
    [ -d "$part" ] && [ ! -L "$part" ] || return 1
    part="$part/"
  done
}
valid_rel() {
  case "$1" in ''|/*|*..*|*//*|*' '*|*'\t'*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  case "$1" in .|./*|*/.|*/./*|*/..) return 1 ;; esac
}
valid_ref() {
  REF="${1:-}"
  [ "${#REF}" -eq 40 ] || return 1
  case "$REF" in *[!0123456789abcdef]*) return 1 ;; esac
  return 0
}
# The allowlist is compiled into the trusted standalone engine, not loaded
# from potentially broken installed files or an untrusted source manifest.
write_contract() {
  cat >"$WORK/expected.manifest" <<'CONTRACT'
format=2
cohort=control-plane
0644 changelog.txt
0644 mervlan.asp
0644 www/index.html
0755 functions/collect_clients.sh
0755 functions/collect_local_clients.sh
0755 functions/device_support_mapper.sh
0755 functions/dropbear_sshkey_gen.sh
0755 functions/execute_nodes.sh
0755 functions/heal_event.sh
0755 functions/hw_probe.sh
0755 functions/mac_client_meta.sh
0755 functions/mac_refresh.sh
0755 functions/mervlan_backup.sh
0755 functions/mervlan_boot.sh
0755 functions/mervlan_boot_wrap.sh
0755 functions/mervlan_manager.sh
0755 functions/mervlan_node_runner.sh
0755 functions/mervlan_recover.sh
0755 functions/mervlan_trunk.sh
0755 functions/mervlan_wan.sh
0755 functions/post_apply_worker.sh
0755 functions/save_settings.sh
0755 functions/settings_reconcile.sh
0755 functions/service-event-handler.sh
0755 functions/ssh_hostkey_probe.sh
0755 functions/ssh_trust_action.sh
0755 functions/sync_nodes.sh
0755 functions/update_mervlan.sh
0644 functions/update_mervlan_repair.manifest
0755 functions/update_mervlan_repair.sh
0755 install.sh
0644 settings/lib_action_ack.sh
0644 settings/lib_action_lock.sh
0644 settings/lib_action_progress.sh
0644 settings/lib_action_runtime.sh
0644 settings/lib_br0_guard.sh
0644 settings/lib_debug.sh
0644 settings/lib_identity.sh
0644 settings/lib_json.sh
0644 settings/lib_maintenance_recovery.sh
0644 settings/lib_backup_state.sh
0644 settings/lib_mervqt.sh
0644 settings/lib_node_jobs.sh
0644 settings/lib_node_reconcile.sh
0644 settings/lib_settings_reconcile.sh
0644 settings/lib_owner_lock.sh
0644 settings/lib_progress.sh
0644 settings/lib_radio.sh
0644 settings/lib_ssh.sh
0644 settings/lib_ssh_trust.sh
0644 settings/lib_ssid_filter.sh
0644 settings/lib_stp.sh
0644 settings/lib_update_state.sh
0644 settings/log_settings.sh
0644 settings/mac_shield_snapshot.sh
0644 settings/var_settings.sh
0644 templates/mervlan_templates.sh
0755 uninstall.sh
CONTRACT
  sed '1,2d' "$WORK/expected.manifest" >"$COHORT"
}
proc_start() (
  pid=$1; proc_root=${2:-/proc}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$proc_root/$pid/stat" ] || return 1
  line=; IFS= read -r line <"$proc_root/$pid/stat" || [ -n "$line" ] || return 1
  case "$line" in *')'*) after=${line##*)} ;; *) return 1 ;; esac
  IFS=$(printf ' \t')
  set -- $after
  tick=${20:-}
  case "$tick" in ''|*[!0-9]*) return 1 ;; esac
  case "$tick" in *[1-9]*) : ;; *) return 1 ;; esac
  printf '%s\n' "$tick"
)
owner_fields_read() {
  _ofr_file="$1"; OWNER_PID= OWNER_START= OWNER_NONCE= OWNER_CREATED= OWNER_HEARTBEAT=
  [ ! -L "$_ofr_file" ] && [ -f "$_ofr_file" ] && [ -r "$_ofr_file" ] || return 1
  _ofr_size=$(wc -c <"$_ofr_file" 2>/dev/null) || return 1
  _ofr_size=${_ofr_size#"${_ofr_size%%[! ]*}"}
  case "$_ofr_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_ofr_size" -gt 0 ] && [ "$_ofr_size" -le 512 ] || return 1
  LC_ALL=C grep -q '[^ -~]' "$_ofr_file" 2>/dev/null && return 1
  _ofr_n=0
  while IFS= read -r _ofr_line || [ -n "$_ofr_line" ]; do
    _ofr_n=$((_ofr_n + 1)); [ "$_ofr_n" -le 5 ] || return 1
    case "$_ofr_line" in
      pid=*) [ -z "$OWNER_PID" ] || return 1; OWNER_PID=${_ofr_line#pid=} ;;
      proc_start_time=*) [ -z "$OWNER_START" ] || return 1; OWNER_START=${_ofr_line#proc_start_time=} ;;
      owner_nonce=*) [ -z "$OWNER_NONCE" ] || return 1; OWNER_NONCE=${_ofr_line#owner_nonce=} ;;
      created=*) [ -z "$OWNER_CREATED" ] || return 1; OWNER_CREATED=${_ofr_line#created=} ;;
      heartbeat=*) [ -z "$OWNER_HEARTBEAT" ] || return 1; OWNER_HEARTBEAT=${_ofr_line#heartbeat=} ;;
      *) return 1 ;;
    esac
  done <"$_ofr_file"
  [ "$_ofr_n" -eq 5 ] || return 1
  case "$OWNER_PID:$OWNER_START:$OWNER_CREATED:$OWNER_HEARTBEAT" in *[!0-9:]*) return 1 ;; esac
  case "$OWNER_PID:$OWNER_START:$OWNER_CREATED:$OWNER_HEARTBEAT" in *::*|:*|*:) return 1 ;; esac
  for _ofr_num in "$OWNER_PID" "$OWNER_START" "$OWNER_CREATED" "$OWNER_HEARTBEAT"; do
    case "$_ofr_num" in *[1-9]*) : ;; *) return 1 ;; esac
  done
  case "$OWNER_NONCE" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#OWNER_NONCE}" -le 160 ] || return 1
  return 0
}
owner_record_matches() {
  _otm_lock="$1" _otm_pid="$2" _otm_start="$3" _otm_nonce="$4"
  [ ! -L "$_otm_lock" ] && [ -d "$_otm_lock" ] || return 1
  owner_fields_read "$_otm_lock/owner" || return 1
  [ "$OWNER_PID" = "$_otm_pid" ] && [ "$OWNER_START" = "$_otm_start" ] &&
    [ "$OWNER_NONCE" = "$_otm_nonce" ]
}
owner_tuple_matches() {
  owner_record_matches "$@" || return 1
  [ "$(proc_start "$OWNER_PID" "$MERV_REPAIR_OWNER_PROC_ROOT" 2>/dev/null)" = "$OWNER_START" ] &&
    kill -0 "$OWNER_PID" 2>/dev/null
}
lock_owner_state() {
  _los_lock="$1"
  [ ! -L "$_los_lock" ] && [ -d "$_los_lock" ] || return 1
  # The canonical v2 owner file is authoritative. Compatibility sidecars may
  # be absent or stale; they must not override a valid owner identity.
  owner_fields_read "$_los_lock/owner" || return 1
  _los_pid=$OWNER_PID _los_start=$OWNER_START
  _los_actual=$(proc_start "$_los_pid" "$MERV_REPAIR_OWNER_PROC_ROOT" 2>/dev/null)
  if [ -n "$_los_actual" ]; then
    [ "$_los_actual" = "$_los_start" ] || { LOCK_OWNER_STATE=reused; return 0; }
    kill -0 "$_los_pid" 2>/dev/null && LOCK_OWNER_STATE=live || LOCK_OWNER_STATE=unknown
    return 0
  fi
  if exists "$MERV_REPAIR_OWNER_PROC_ROOT/$_los_pid/stat" || kill -0 "$_los_pid" 2>/dev/null; then
    LOCK_OWNER_STATE=unknown
  else
    LOCK_OWNER_STATE=dead
  fi
  return 0
}
lock_quarantine_dead() {
  _lqd_lock="$1"
  lock_owner_state "$_lqd_lock" || return 1
  case "$LOCK_OWNER_STATE" in dead|reused) ;; *) return 1 ;; esac
  _lqd_state=$LOCK_OWNER_STATE _lqd_pid=$OWNER_PID _lqd_start=$OWNER_START
  _lqd_nonce=$OWNER_NONCE _lqd_created=$OWNER_CREATED _lqd_heartbeat=$OWNER_HEARTBEAT
  _lqd_parent=${_lqd_lock%/*} _lqd_base=${_lqd_lock##*/}
  LOCK_SEQ=$((LOCK_SEQ + 1))
  _lqd_quarantine="$_lqd_parent/.$_lqd_base.repair-stale.$$.$LOCK_SEQ"
  safe_chain "$_lqd_quarantine" && ! exists "$_lqd_quarantine" || return 1
  # The sibling rename preserves stale evidence. Recheck the exact owner and
  # process generation before and after moving it; ambiguity remains a refusal.
  lock_owner_state "$_lqd_lock" || return 1
  [ "$LOCK_OWNER_STATE" = "$_lqd_state" ] && [ "$OWNER_PID" = "$_lqd_pid" ] &&
    [ "$OWNER_START" = "$_lqd_start" ] && [ "$OWNER_NONCE" = "$_lqd_nonce" ] &&
    [ "$OWNER_CREATED" = "$_lqd_created" ] && [ "$OWNER_HEARTBEAT" = "$_lqd_heartbeat" ] || return 1
  mv "$_lqd_lock" "$_lqd_quarantine" 2>/dev/null || return 1
  if lock_owner_state "$_lqd_quarantine" &&
     { [ "$LOCK_OWNER_STATE" = dead ] || [ "$LOCK_OWNER_STATE" = reused ]; } &&
     [ "$OWNER_PID" = "$_lqd_pid" ] && [ "$OWNER_START" = "$_lqd_start" ] &&
     [ "$OWNER_NONCE" = "$_lqd_nonce" ] && [ "$OWNER_CREATED" = "$_lqd_created" ] &&
     [ "$OWNER_HEARTBEAT" = "$_lqd_heartbeat" ]; then
    return 0
  fi
  if ! exists "$_lqd_lock"; then mv "$_lqd_quarantine" "$_lqd_lock" 2>/dev/null || :; fi
  return 1
}
action_parent_check() {
  ACTION_PARENT=0
  if [ "${MERV_ACTION_LOCK_PARENT_HELD:-0}" != 1 ]; then
    case "${MERV_ACTION_LOCK_PARENT_PID:-}:${MERV_ACTION_LOCK_PARENT_START:-}:${MERV_ACTION_LOCK_PARENT_NONCE:-}" in
      ::) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "${MERV_ACTION_LOCK_PARENT_PID:-}:${MERV_ACTION_LOCK_PARENT_START:-}" in
    *[!0-9:]*|:*|*:) return 1 ;; esac
  case "${MERV_ACTION_LOCK_PARENT_NONCE:-}" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  ACTION_PARENT_PID=$MERV_ACTION_LOCK_PARENT_PID
  ACTION_PARENT_START=$MERV_ACTION_LOCK_PARENT_START
  ACTION_PARENT_NONCE=$MERV_ACTION_LOCK_PARENT_NONCE
  _ap_lock="${MERV_ACTION_LOCK_PATH:-$MERV_REPAIR_ACTION_LOCK}"
  [ "$_ap_lock" = "$MERV_REPAIR_ACTION_LOCK" ] || return 1
  owner_tuple_matches "$_ap_lock" "$ACTION_PARENT_PID" "$ACTION_PARENT_START" "$ACTION_PARENT_NONCE" || return 1
  ACTION_PARENT=1
  return 0
}
write_lock_value() {
  _wlv_dir="$1" _wlv_name="$2" _wlv_value="$3"
  LOCK_SEQ=$((LOCK_SEQ + 1))
  _wlv_tmp="$_wlv_dir/.$_wlv_name.tmp.$$.$LOCK_SEQ"
  (umask 077; printf '%s\n' "$_wlv_value" >"$_wlv_tmp") 2>/dev/null || return 1
  chmod 600 "$_wlv_tmp" 2>/dev/null && mv -f "$_wlv_tmp" "$_wlv_dir/$_wlv_name" 2>/dev/null || {
    rm -f "$_wlv_tmp" 2>/dev/null || :
    return 1
  }
  return 0
}
lock_acquire_one() {
  _lao_lock="$1" _lao_nonce="$2"
  LOCK_ACQUIRE_REASON=
  safe_chain "${_lao_lock%/*}" || { LOCK_ACQUIRE_REASON=unsafe_lock_path; return 1; }
  ensure_dir "${_lao_lock%/*}" || { LOCK_ACQUIRE_REASON=lock_parent_unavailable; return 1; }
  _lao_attempt=0
  while ! mkdir "$_lao_lock" 2>/dev/null; do
    if ! exists "$_lao_lock"; then
      LOCK_ACQUIRE_REASON=lock_create_failed
      return 1
    fi
    [ ! -L "$_lao_lock" ] && [ -d "$_lao_lock" ] || {
      LOCK_ACQUIRE_REASON=lock_object_unsafe
      return 1
    }
    if ! lock_owner_state "$_lao_lock"; then
      if [ -L "$_lao_lock/owner" ] || { exists "$_lao_lock/owner" && [ ! -f "$_lao_lock/owner" ]; }; then
        LOCK_ACQUIRE_REASON=owner_object_unsafe
      elif exists "$_lao_lock/owner" && [ ! -r "$_lao_lock/owner" ]; then
        LOCK_ACQUIRE_REASON=owner_record_unreadable
      elif exists "$_lao_lock/owner"; then
        LOCK_ACQUIRE_REASON=owner_record_invalid
      else
        LOCK_ACQUIRE_REASON=owner_record_incomplete
      fi
      return 1
    fi
    case "$LOCK_OWNER_STATE" in
      dead|reused)
        lock_quarantine_dead "$_lao_lock" || { LOCK_ACQUIRE_REASON=stale_lock_quarantine_failed; return 1; }
        ;;
      live) LOCK_ACQUIRE_REASON=live_owner; return 1 ;;
      *) LOCK_ACQUIRE_REASON=owner_liveness_unknown; return 1 ;;
    esac
    _lao_attempt=$((_lao_attempt + 1))
    [ "$_lao_attempt" -lt 8 ] || { LOCK_ACQUIRE_REASON=stale_lock_retry_limit; return 1; }
  done
  chmod 700 "$_lao_lock" 2>/dev/null || {
    LOCK_ACQUIRE_REASON=lock_directory_mode_failed
    rmdir "$_lao_lock" 2>/dev/null || :
    return 1
  }
  for _lao_field in pid proc_start_time owner_nonce created heartbeat; do
    case "$_lao_field" in
      pid) _lao_value=$$ ;;
      proc_start_time) _lao_value=$LOCK_START ;;
      owner_nonce) _lao_value=$_lao_nonce ;;
      created|heartbeat) _lao_value=$LOCK_CREATED ;;
    esac
    write_lock_value "$_lao_lock" "$_lao_field" "$_lao_value" || {
      rm -f "$_lao_lock/pid" "$_lao_lock/proc_start_time" "$_lao_lock/owner_nonce" \
        "$_lao_lock/created" "$_lao_lock/heartbeat" 2>/dev/null || :
      rmdir "$_lao_lock" 2>/dev/null || :
      LOCK_ACQUIRE_REASON=compatibility_record_write_failed
      return 1
    }
  done
  _lao_tmp="$_lao_lock/.owner.tmp.$$.$LOCK_SEQ"
  (umask 077
    printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=%s\nheartbeat=%s\n' \
      "$$" "$LOCK_START" "$_lao_nonce" "$LOCK_CREATED" "$LOCK_CREATED" >"$_lao_tmp"
  ) 2>/dev/null || {
    rm -f "$_lao_tmp" 2>/dev/null || :
    LOCK_ACQUIRE_REASON=owner_record_write_failed
    return 1
  }
  chmod 600 "$_lao_tmp" 2>/dev/null && mv -f "$_lao_tmp" "$_lao_lock/owner" 2>/dev/null || {
    rm -f "$_lao_tmp" "$_lao_lock/pid" "$_lao_lock/proc_start_time" \
      "$_lao_lock/owner_nonce" "$_lao_lock/created" "$_lao_lock/heartbeat" 2>/dev/null || :
    rmdir "$_lao_lock" 2>/dev/null || :
    LOCK_ACQUIRE_REASON=owner_record_publish_failed
    return 1
  }
  if ! owner_tuple_matches "$_lao_lock" "$$" "$LOCK_START" "$_lao_nonce"; then
    LOCK_ACQUIRE_REASON=self_owner_verification_failed
    return 1
  fi
  return 0
}
lock_release_one() {
  _lro_lock="$1" _lro_nonce="$2"
  owner_tuple_matches "$_lro_lock" "$$" "$LOCK_START" "$_lro_nonce" || return 1
  _lro_restore="$_lro_lock.owner.restore.$$.$LOCK_SEQ"
  exists "$_lro_restore" && return 1
  cp "$_lro_lock/owner" "$_lro_restore" && chmod 600 "$_lro_restore" || return 1
  rm -f "$_lro_lock/owner" "$_lro_lock/pid" "$_lro_lock/proc_start_time" \
    "$_lro_lock/owner_nonce" "$_lro_lock/created" "$_lro_lock/heartbeat" || {
      mv -f "$_lro_restore" "$_lro_lock/owner" 2>/dev/null || :
      return 1
    }
  if ! rmdir "$_lro_lock"; then
    if [ -d "$_lro_lock" ] && [ ! -L "$_lro_lock" ] && ! exists "$_lro_lock/owner"; then
      mv -f "$_lro_restore" "$_lro_lock/owner" 2>/dev/null || return 1
    else
      rm -f "$_lro_restore" 2>/dev/null || :
    fi
    return 1
  fi
  rm -f "$_lro_restore" 2>/dev/null || :
}
owner_ok() {
  OWNER_CHECK_FAILURE=
  # The running shell cannot change generation during this check. Each
  # self-owned record must still match that identity and its own nonce.
  [ "$(proc_start "$$" "$MERV_REPAIR_OWNER_PROC_ROOT" 2>/dev/null)" = "$LOCK_START" ] || {
    OWNER_CHECK_FAILURE=proc_identity_invalid
    return 1
  }
  if [ "$ACTION_PARENT" -eq 1 ]; then
    owner_tuple_matches "$MERV_REPAIR_ACTION_LOCK" "$ACTION_PARENT_PID" "$ACTION_PARENT_START" "$ACTION_PARENT_NONCE" || {
      OWNER_CHECK_FAILURE=parent_action_owner_invalid
      return 1
    }
  elif [ "$ACTION_LOCKED" -eq 1 ]; then
    owner_record_matches "$MERV_REPAIR_ACTION_LOCK" "$$" "$LOCK_START" "$ACTION_NONCE" || {
      OWNER_CHECK_FAILURE=action_owner_invalid
      return 1
    }
  else
    OWNER_CHECK_FAILURE=action_lock_not_owned
    return 1
  fi
  [ "$MAINTENANCE_LOCKED" -eq 1 ] || { OWNER_CHECK_FAILURE=maintenance_lock_not_owned; return 1; }
  owner_record_matches "$MERV_REPAIR_LOCK" "$$" "$LOCK_START" "$MAINTENANCE_NONCE" || {
    OWNER_CHECK_FAILURE=maintenance_owner_invalid
    return 1
  }
  [ "$MANAGER_LOCKED" -eq 1 ] || { OWNER_CHECK_FAILURE=manager_lock_not_owned; return 1; }
  owner_record_matches "$MERV_REPAIR_MANAGER_LOCK" "$$" "$LOCK_START" "$MANAGER_NONCE" || {
    OWNER_CHECK_FAILURE=manager_owner_invalid
    return 1
  }
  return 0
}
admission_lock_failure() {
  _alf_stage="$1"
  case "$LOCK_ACQUIRE_REASON" in
    live_owner) status ADMISSION "admission=${_alf_stage}_lock_busy reason=live_owner" ;;
    owner_liveness_unknown) status ADMISSION "admission=${_alf_stage}_lock_busy reason=owner_liveness_unknown" ;;
    owner_record_incomplete) status ADMISSION "admission=${_alf_stage}_lock_failed reason=owner_record_incomplete" ;;
    owner_record_invalid) status ADMISSION "admission=${_alf_stage}_lock_failed reason=owner_record_invalid" ;;
    *) status ADMISSION "admission=${_alf_stage}_lock_failed reason=$LOCK_ACQUIRE_REASON" ;;
  esac
  return 1
}
acquire() {
  action_parent_check || { status ADMISSION 'admission=action_parent_invalid'; return 1; }
  LOCK_START=$(proc_start "$$" "$MERV_REPAIR_OWNER_PROC_ROOT") || {
    status ADMISSION 'admission=proc_identity_invalid'
    return 1
  }
  LOCK_CREATED=$(date +%s 2>/dev/null || printf '')
  case "$LOCK_CREATED" in
    ''|*[!0-9]*) status ADMISSION 'admission=clock_invalid'; return 1 ;;
  esac
  ACTION_NONCE="repair.$$.$LOCK_START.action"
  MAINTENANCE_NONCE="repair.$$.$LOCK_START.maintenance"
  MANAGER_NONCE="repair.$$.$LOCK_START.manager"
  if [ "$ACTION_PARENT" -eq 0 ]; then
    lock_acquire_one "$MERV_REPAIR_ACTION_LOCK" "$ACTION_NONCE" || {
      admission_lock_failure action
      return 1
    }
    ACTION_LOCKED=1
  fi
  lock_acquire_one "$MERV_REPAIR_LOCK" "$MAINTENANCE_NONCE" || {
    admission_lock_failure maintenance
    return 1
  }
  MAINTENANCE_LOCKED=1
  lock_acquire_one "$MERV_REPAIR_MANAGER_LOCK" "$MANAGER_NONCE" || {
    admission_lock_failure manager
    return 1
  }
  MANAGER_LOCKED=1
  owner_ok || {
    status ADMISSION "admission=self_owner_validation_failed reason=$OWNER_CHECK_FAILURE"
    return 1
  }
  status ADMISSION 'action, maintenance and Manager ownership acquired'
}
release() {
  _rel_rc=0
  if [ "$MANAGER_LOCKED" -eq 1 ]; then
    lock_release_one "$MERV_REPAIR_MANAGER_LOCK" "$MANAGER_NONCE" && MANAGER_LOCKED=0 || _rel_rc=1
  fi
  if [ "$MAINTENANCE_LOCKED" -eq 1 ]; then
    lock_release_one "$MERV_REPAIR_LOCK" "$MAINTENANCE_NONCE" && MAINTENANCE_LOCKED=0 || _rel_rc=1
  fi
  if [ "$ACTION_LOCKED" -eq 1 ]; then
    lock_release_one "$MERV_REPAIR_ACTION_LOCK" "$ACTION_NONCE" && ACTION_LOCKED=0 || _rel_rc=1
  fi
  return "$_rel_rc"
}
# Historical writer inventory (identical recognized basenames to accepted R1).
mutator() {
  case "$1" in
    "$MERV_BASE"/install.sh|"$MERV_BASE"/uninstall.sh|\
    "$MERV_BASE"/functions/update_mervlan.sh|"$MERV_BASE"/functions/mervlan_manager.sh|\
    "$MERV_BASE"/functions/sync_nodes.sh|"$MERV_BASE"/functions/execute_nodes.sh|\
    "$MERV_BASE"/functions/service-event-handler.sh|"$MERV_BASE"/functions/mervlan_backup.sh|\
    "$MERV_BASE"/functions/mervlan_recover.sh|"$MERV_BASE"/functions/mervlan_boot.sh|\
    "$MERV_BASE"/functions/mervlan_boot_wrap.sh|"$MERV_BASE"/functions/heal_event.sh|\
    "$MERV_BASE"/functions/save_settings.sh|"$MERV_BASE"/functions/hw_probe.sh|\
    "$MERV_BASE"/functions/dropbear_sshkey_gen.sh) return 0 ;; esac
  return 1
}
writer_basename() {
  case "${1##*/}" in
    install.sh|uninstall.sh|update_mervlan.sh|mervlan_manager.sh|\
    sync_nodes.sh|execute_nodes.sh|service-event-handler.sh|mervlan_backup.sh|mervlan_recover.sh|\
    mervlan_boot.sh|mervlan_boot_wrap.sh|heal_event.sh|\
    save_settings.sh|hw_probe.sh|dropbear_sshkey_gen.sh) return 0 ;;
  esac
  return 1
}
relative_candidate() {
  case "$1" in ''|/*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  writer_basename "$1"
}
# Strip harmless ./ components, including nested ones. Reject '..' and
# malformed candidates instead of assuming their resulting path is harmless.
normalize_relative() (
  rest=$1; output=
  case "$rest" in ''|/*|*..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  while [ -n "$rest" ]; do
    case "$rest" in */*) component=${rest%%/*}; rest=${rest#*/} ;;
      *) component=$rest; rest= ;; esac
    case "$component" in ''|.) : ;;
      *) if [ -n "$output" ]; then output="$output/$component";
         else output=$component; fi ;; esac
  done
  [ -n "$output" ] || return 1
  printf '%s\n' "$output"
)
readonly_dispatcher_action() {
  _rda_found=0
  while IFS= read -r _rda_arg || [ -n "$_rda_arg" ]; do
    case "$_rda_arg" in
      checkservice_vlanmgr|checkservice-vlanmgr|collectclients_vlanmgr|collectclients-vlanmgr|\
      collectclients_vlanmgr_pgt_*|collectclients-vlanmgr-pgt_*|clearclilog_vlanmgr|clearclilog-vlanmgr)
        _rda_found=1 ;;
    esac
  done <<EOF
$1
EOF
  [ "$_rda_found" -eq 1 ]
}
scan_processes() {
  safe_chain "$MERV_REPAIR_PROC_ROOT" && [ -d "$MERV_REPAIR_PROC_ROOT" ] &&
    [ -r "$MERV_REPAIR_PROC_ROOT" ] && [ -x "$MERV_REPAIR_PROC_ROOT" ] || return 1
  for entry in "$MERV_REPAIR_PROC_ROOT"/[0-9]*; do
    exists "$entry" || continue
    [ -d "$entry" ] && [ ! -L "$entry" ] || return 1
    pid=${entry##*/}
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    case "$pid" in *[1-9]*) : ;; *) return 1 ;; esac
    regular "$entry/cmdline" && [ -r "$entry/cmdline" ] || return 1
    # Important: read each PID only when its turn arrives. Never pre-shortlist.
    argv=$(tr '\000' '\n' <"$entry/cmdline") || return 1
    # Every writer name contains .sh. Skip argument parsing only after the
    # complete cmdline read has succeeded, at this PID's turn in this scan.
    case "$argv" in *.sh*) : ;; *) continue ;; esac
    matched=0; matched_count=0; matched_arg=; noncanonical=0
    # Absolute paths take priority; all other arguments are inspected
    # as relative candidates, including BARE filenames (the R1 regression).
    while IFS= read -r arg || [ -n "$arg" ]; do
      if ! mutator "$arg"; then
        case "$arg" in
          "$MERV_BASE"/*|/./*|/../*|/*/./*|/*/../*|//*|/*//*) writer_basename "$arg" || continue ;;
          *) continue ;;
        esac
        normalized=$(normalize_relative "${arg#/}") || {
          status REFUSED 'ambiguous absolute writer candidate'; return 1;
        }
        mutator "/$normalized" || continue
        # Lexical equivalence can block a writer but cannot authenticate an
        # exception for a dispatcher reached through an alternate spelling.
        noncanonical=1
      fi
      matched=1; matched_count=$((matched_count+1)); matched_arg="$arg"
    done <<ARGS
$argv
ARGS
    if [ "$matched" -eq 0 ]; then
      while IFS= read -r arg || [ -n "$arg" ]; do
        relative_candidate "$arg" || continue
        [ -L "$entry/cwd" ] || return 1
        cwd=$(readlink "$entry/cwd" 2>/dev/null) || return 1
        safe_chain "$cwd" && [ -d "$cwd" ] && [ ! -L "$cwd" ] || return 1
        normalized=$(normalize_relative "$arg") || return 1
        if mutator "${cwd%/}/$normalized"; then
          matched=1; matched_count=$((matched_count+1)); matched_arg="${cwd%/}/$normalized"
        else
          # A known script basename under the addon with unexpected spelling
          # must not silently pass when it does not resolve to a known writer.
          case "$cwd" in "$MERV_BASE"|"$MERV_BASE"/*)
            status REFUSED 'ambiguous addon-relative writer candidate'; return 1 ;;
          esac
        fi
      done <<ARGS
$argv
ARGS
    fi
    if [ "$matched" -eq 1 ]; then
      # A WebUI transport may own the global action lock. Admit only that
      # authenticated dispatcher process; every other recognized mutator blocks.
      if [ "$noncanonical" -eq 0 ] && [ "$ACTION_PARENT" -eq 1 ] && [ "$pid" = "$ACTION_PARENT_PID" ] &&
         [ "$matched_count" -eq 1 ] &&
         [ "$matched_arg" = "$MERV_BASE/functions/service-event-handler.sh" ] &&
         [ "$(proc_start "$pid" "$MERV_REPAIR_PROC_ROOT" 2>/dev/null)" = "$ACTION_PARENT_START" ]; then
        continue
      fi
      if [ "$noncanonical" -eq 0 ] && [ "$matched_count" -eq 1 ] &&
         [ "$matched_arg" = "$MERV_BASE/functions/service-event-handler.sh" ] &&
         readonly_dispatcher_action "$argv"; then
        continue
      fi
      # R1 checks the process generation and liveness for any candidate.
      # Our lean policy is stricter: unreadable/disappeared/reused identities
      # also BLOCK, rather than treating a stale observation as safe.
      start=$(proc_start "$pid" "$MERV_REPAIR_PROC_ROOT" 2>/dev/null) || {
        status REFUSED 'writer process identity unavailable'; return 1;
      }
      kill -0 "$pid" 2>/dev/null || {
        status REFUSED 'writer process liveness uncertain'; return 1;
      }
      [ "$(proc_start "$pid" "$MERV_REPAIR_PROC_ROOT" 2>/dev/null)" = "$start" ] || {
        status REFUSED 'writer process generation changed'; return 1;
      }
      status REFUSED "recognized writer pid=$pid"; return 1
    fi
  done
  return 0
}
capacity_kib() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}
preflight() {
  available=$(awk '$1=="MemAvailable:" {print $2}' "$MERV_REPAIR_MEMINFO") || return 1
  case "$available" in ''|*[!0-9]*) return 1 ;; esac
  tmpfree=$(capacity_kib "$MERV_REPAIR_TMP_ROOT")
  flashfree=$(capacity_kib "$MERV_BASE")
  case "$tmpfree:$flashfree" in *[!0-9:]*|:*|*:) return 1 ;; esac
  status PREFLIGHT "MemAvailable=${available}KiB tmpFree=${tmpfree}KiB destFree=${flashfree}KiB"
  [ "$available" -ge "$REPAIR_MIN_AVAILABLE_KIB" ] &&
    [ "$tmpfree" -ge "$REPAIR_MIN_TMP_FREE_KIB" ] &&
    [ "$flashfree" -ge "$REPAIR_MIN_DEST_FREE_KIB" ]
}
# Refuse unresolved workspaces from BOTH this engine and the accepted R1.
# A known pre-transaction workspace is harmless but is never deleted here.
prior_workspaces_clear() {
  for prior_root in "$MERV_REPAIR_TMP_ROOT" "${MERV_REPAIR_BOOTSTRAP_DIR:-$MERV_REPAIR_TMP_ROOT}"; do
    safe_chain "$prior_root" && [ -d "$prior_root" ] && [ ! -L "$prior_root" ] || return 1
    for pattern in mervlan_lean mervlan_repair; do
      for prior in "$prior_root"/"$pattern".*; do
        exists "$prior" || continue
        [ -d "$prior" ] && [ ! -L "$prior" ] && regular "$prior/.owner" || return 1
        case "$pattern" in
          mervlan_lean) grep -Fqx 'lean-repair-v1' "$prior/.owner" || return 1 ;;
          mervlan_repair) grep -Fqx 'mervlan-repair-workspace-v2' "$prior/.owner" || return 1 ;;
        esac
        if exists "$prior/ledger"; then
          regular "$prior/ledger" || return 1
          [ ! -s "$prior/ledger" ] || return 1
        fi
      done
    done
  done
}
create_work() {
  safe_chain "$MERV_REPAIR_TMP_ROOT" && [ -d "$MERV_REPAIR_TMP_ROOT" ] || return 1
  prior_workspaces_clear || return 1
  i=0
  while [ "$i" -lt 8 ]; do
    WORK="$MERV_REPAIR_TMP_ROOT/mervlan_lean.$RUN_START.$$.$i"
    if (umask 077; mkdir "$WORK") 2>/dev/null; then break; fi
    i=$((i+1))
  done
  [ -d "$WORK" ] || return 1
  (umask 077; printf 'lean-repair-v1\n' >"$WORK/.owner") || return 1
  ARCHIVE="$WORK/snapshot.tar.gz"; STAGE="$WORK/stage"; BACKUP=""
  LEDGER=""; MANIFEST="$WORK/expected.manifest"; COHORT="$WORK/cohort"
  mkdir "$STAGE" "$WORK/extract" "$WORK/protected" || return 1
  write_contract
}
fetch_archive() {
  status DOWNLOAD "HTTPS source=$REF; connect<=5s attempt<=18s total~38s"
  # No retry of the archive after validation: this is the one source snapshot.
  "$MERV_REPAIR_CURL" -fsSL --proto '=https' --proto-redir '=https' \
    --connect-timeout 5 --max-time 18 --retry 1 --retry-delay 1 \
    --retry-max-time 38 --max-filesize 8388608 \
    -o "$ARCHIVE.part" "$MERV_REPAIR_SNAPSHOT_BASE/$REF" || return 1
  regular "$ARCHIVE.part" && [ -s "$ARCHIVE.part" ] || return 1
  bytes=$(wc -c <"$ARCHIVE.part") || return 1
  [ "$bytes" -le 8388608 ] || return 1
  mv "$ARCHIVE.part" "$ARCHIVE" || return 1
  status DOWNLOAD "complete compressedBytes=$bytes"
}
validate_archive() {
  # Stream cap protects /tmp against a gzip bomb; tar still verifies CRC.
  expanded=$(gzip -dc "$ARCHIVE" 2>/dev/null | head -c 16777217 | wc -c) || return 1
  [ "$expanded" -le 16777216 ] || return 1
  tar -tzf "$ARCHIVE" >"$WORK/names" 2>/dev/null || return 1
  tar -tvzf "$ARCHIVE" >"$WORK/details" 2>/dev/null || return 1
  : >"$WORK/seen"; ROOT=; n=0
  while IFS= read -r member || [ -n "$member" ]; do
    case "$member" in */) member=${member%/} ;; esac
    valid_rel "$member" || return 1
    candidate=${member%%/*}
    case "$candidate" in mervlan-*) : ;; *) return 1 ;; esac
    [ -z "$ROOT" ] && ROOT=$candidate
    [ "$candidate" = "$ROOT" ] || return 1
    printf '%s\n' "$member" >>"$WORK/seen" || return 1
    n=$((n+1)); [ "$n" -le 4096 ] || return 1
  done <"$WORK/names"
  [ "$n" -ge 58 ] || return 1
  awk 'seen[$0]++ {exit 1}' "$WORK/seen" || return 1
  while IFS= read -r detail || [ -n "$detail" ]; do
    case "$detail" in -*|d*) : ;; *) return 1 ;; esac
    case "$detail" in *' -> '*|*' link to '*) return 1 ;; esac
  done <"$WORK/details"
  # Extract ONLY the embedded allowlist, never execute downloaded scripts.
  set --
  while IFS=' ' read -r mode relative; do
    case "$mode:$relative" in 0644:*|0755:*) : ;; *) return 1 ;; esac
    valid_rel "$relative" || return 1
    set -- "$@" "$ROOT/$relative"
  done <"$COHORT"
  tar -xzf "$ARCHIVE" -C "$WORK/extract" "$@" 2>/dev/null || return 1
  SOURCE_ROOT="$WORK/extract/$ROOT"
  actual_manifest="$SOURCE_ROOT/functions/update_mervlan_repair.manifest"
  regular "$actual_manifest" && cmp -s "$MANIFEST" "$actual_manifest" || return 1
  status ARCHIVE "validated members=$n uncompressedBytes=$expanded manifest=exact"
}
stage_files() {
  size=0; count=0
  while IFS=' ' read -r mode relative; do
    from="$SOURCE_ROOT/$relative"; to="$STAGE/$relative"
    safe_chain "${from%/*}" && regular "$from" && [ -s "$from" ] || return 1
    ensure_dir "${to%/*}" || return 1
    cp "$from" "$to" && chmod "$mode" "$to" || return 1
    regular "$to" && cmp -s "$from" "$to" || return 1
    case "$relative" in *.sh) sh -n "$to" >/dev/null 2>&1 || return 1 ;; esac
    this=$(wc -c <"$to") || return 1
    size=$((size+this)); [ "$size" -le 8388608 ] || return 1
    count=$((count+1))
  done <"$COHORT"
  [ "$count" -eq 58 ] || return 1
  STAGED_BYTES=$size
  status STAGING "complete files=$count bytes=$size"
}
mode_ok() {
  listing=$(LC_ALL=C ls -ld "$2" 2>/dev/null) || return 1
  perms=${listing%% *}
  case "$1:$perms" in 0755:-rwxr-xr-x|0644:-rw-r--r--) return 0 ;; esac
  return 1
}
mode_value() {
  _mv_path="$1"
  _mv_line=$(LC_ALL=C ls -ld "$_mv_path" 2>/dev/null) || return 1
  _mv_mode=${_mv_line%% *}
  [ "${#_mv_mode}" -eq 10 ] || return 1
  case "$_mv_mode" in [d-]?????????) printf '%s\n' "$_mv_mode" ;; *) return 1 ;; esac
}
mode_record_valid() {
  case "$1" in -[r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]) return 0 ;; *) return 1 ;; esac
}
sha_valid() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0123456789abcdef]*) return 1 ;; esac
}
sha256_file() {
  _sf_path="$1" _sf_hash=""
  regular "$_sf_path" || return 1
  if type sha256sum >/dev/null 2>&1; then
    _sf_line=$(sha256sum "$_sf_path" 2>/dev/null) || return 1
    _sf_hash=${_sf_line%% *}
  elif type openssl >/dev/null 2>&1; then
    _sf_line=$(openssl dgst -sha256 "$_sf_path" 2>/dev/null) || return 1
    _sf_hash=${_sf_line##* }
  else
    return 1
  fi
  sha_valid "$_sf_hash" || return 1
  printf '%s\n' "$_sf_hash"
}
repair_test_fault() {
  [ "${MERV_REPAIR_TEST_ONLY:-0}" = 1 ] || return 1
  [ "${1:-}" = "${2:-}" ]
}
protected_files() {
  protected_relatives='settings/settings.json .ssh/vlan_manager .ssh/vlan_manager.pub \
    tmp/mac_shield.db tmp/mac_shield_override.db tmp/client_name_override.db \
    flags/.install_ok www/settings/hardware_profiles.json'
  for rel in $protected_relatives; do
    src="$MERV_BASE/$rel"; saved="$WORK/protected/$rel"
    if exists "$src"; then
      regular "$src" || return 1
      ensure_dir "${saved%/*}" || return 1
      cp -p "$src" "$saved" || return 1
      cmp -s "$src" "$saved" || return 1
      printf 'present %s\n' "$rel" >>"$WORK/protected.index" || return 1
    else
      printf 'absent %s\n' "$rel" >>"$WORK/protected.index" || return 1
    fi
  done
  chmod 600 "$WORK/protected.index" 2>/dev/null || return 1
}
protected_unchanged() {
  while IFS=' ' read -r _pu_state _pu_rel; do
    case "$_pu_state" in
      present) regular "$MERV_BASE/$_pu_rel" && cmp -s "$WORK/protected/$_pu_rel" "$MERV_BASE/$_pu_rel" || return 1 ;;
      absent) exists "$MERV_BASE/$_pu_rel" && return 1 ;;
      *) return 1 ;;
    esac
  done <"$WORK/protected.index"
  return 0
}
new_transaction() {
  BACKUP_ROOT=${MERV_REPAIR_BACKUP_ROOT%/}
  case "$BACKUP_ROOT" in ''|/|*..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  case "$BACKUP_ROOT" in "$MERV_BASE"|"$MERV_BASE"/*) return 1 ;; esac
  safe_chain "$BACKUP_ROOT" || return 1
  ensure_dir "$BACKUP_ROOT" || return 1
  prior_transactions_clear || return 1
  _nt_now=$(date +%s 2>/dev/null || printf '')
  case "$_nt_now" in ''|*[!0-9]*) return 1 ;; esac
  _nt_try=0
  while [ "$_nt_try" -lt 16 ]; do
    TXN_ID="mervlan.repair.$_nt_now.$$.$_nt_try"
    TXN_DIR="$BACKUP_ROOT/$TXN_ID"
    if (umask 077; mkdir "$TXN_DIR") 2>/dev/null; then break; fi
    _nt_try=$((_nt_try + 1))
  done
  [ -d "$TXN_DIR" ] && [ ! -L "$TXN_DIR" ] || return 1
  chmod 700 "$TXN_DIR" || return 1
  BACKUP="$TXN_DIR/original"
  INDEX_FILE="$TXN_DIR/index"
  READY_FILE="$TXN_DIR/READY"
  LEDGER="$TXN_DIR/journal"
  RECOVERY_HELPER="$TXN_DIR/recover.sh"
  mkdir "$BACKUP" || return 1
  chmod 700 "$BACKUP" || return 1
  cp -p "$0" "$RECOVERY_HELPER" 2>/dev/null || return 1
  chmod 700 "$RECOVERY_HELPER" || return 1
  cmp -s "$0" "$RECOVERY_HELPER" || return 1
  sh -n "$RECOVERY_HELPER" >/dev/null 2>&1 || return 1
  return 0
}
backup_capacity_check() {
  _bc_total=0
  while IFS=' ' read -r _bc_mode _bc_rel; do
    _bc_target="$MERV_BASE/$_bc_rel"
    safe_chain "${_bc_target%/*}" || return 1
    if exists "$_bc_target"; then
      regular "$_bc_target" || return 1
      _bc_size=$(wc -c <"$_bc_target" 2>/dev/null) || return 1
      _bc_size=${_bc_size#"${_bc_size%%[! ]*}"}
      case "$_bc_size" in ''|*[!0-9]*) return 1 ;; esac
      _bc_total=$((_bc_total + _bc_size))
      [ "$_bc_total" -le 8388608 ] || return 1
    fi
  done <"$COHORT"
  _bc_helper=$(wc -c <"$RECOVERY_HELPER" 2>/dev/null) || return 1
  _bc_helper=${_bc_helper#"${_bc_helper%%[! ]*}"}
  case "$_bc_helper" in ''|*[!0-9]*) return 1 ;; esac
  _bc_free=$(capacity_kib "$BACKUP_ROOT")
  case "$_bc_free" in ''|*[!0-9]*) return 1 ;; esac
  _bc_need=$(((_bc_total + _bc_helper + 65535) / 1024 + REPAIR_MIN_DEST_FREE_KIB))
  [ "$_bc_free" -ge "$_bc_need" ] || return 1
  BACKUP_ESTIMATE=$_bc_total
  return 0
}
choose_hash_style() {
  if [ -z "${BACKUP_HASH_STYLE:-}" ]; then
    if type sha256sum >/dev/null 2>&1; then
      BACKUP_HASH_STYLE=sum
    elif [ "$(openssl dgst -sha256 -r </dev/null 2>/dev/null)" = \
           'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 *stdin' ]; then
      BACKUP_HASH_STYLE=openssl
    else
      BACKUP_HASH_STYLE=individual
    fi
  fi
}
hash_batch() {
  case "$BACKUP_HASH_STYLE" in
    sum) sha256sum "$@" 2>/dev/null ;;
    openssl) openssl dgst -sha256 -r "$@" 2>/dev/null ;;
  esac
}
backup_payload_verify() {
  _bpv_count=0 _bpv_total=0
  _bpv_stage=${1:-} _bpv_expected=
  # The full output must match the ordered digests and exact allowlisted paths.
  choose_hash_style
  set --
  exec 3<"$INDEX_FILE" || return 1
  while IFS=' ' read -r _bpv_newmode _bpv_rel; do
    IFS='|' read -r _bpv_kind _bpv_oldmode _bpv_size _bpv_oldhash _bpv_newhash _bpv_path <&3 || { exec 3<&-; return 1; }
    [ "$_bpv_rel" = "$_bpv_path" ] && sha_valid "$_bpv_newhash" || { exec 3<&-; return 1; }
    if [ "$_bpv_stage" = verify-stage ]; then
      path_regular "$STAGE/$_bpv_rel" || { exec 3<&-; return 1; }
      _bpv_stage_hash=$(sha256_file "$STAGE/$_bpv_rel") || { exec 3<&-; return 1; }
      [ "$_bpv_stage_hash" = "$_bpv_newhash" ] || { exec 3<&-; return 1; }
    fi
    case "$_bpv_kind" in
      old)
        mode_record_valid "$_bpv_oldmode" || { exec 3<&-; return 1; }
        case "$_bpv_size" in ''|*[!0-9]*) exec 3<&-; return 1 ;; esac
        sha_valid "$_bpv_oldhash" || { exec 3<&-; return 1; }
        _bpv_saved="$BACKUP/$_bpv_rel"
        path_regular "$_bpv_saved" || { exec 3<&-; return 1; }
        case "$BACKUP_HASH_STYLE" in
          sum) _bpv_separator='  ' ;;
          openssl) _bpv_separator=' *' ;;
          individual)
            _bpv_saved_hash=$(sha256_file "$_bpv_saved") || { exec 3<&-; return 1; }
            [ "$_bpv_saved_hash" = "$_bpv_oldhash" ] || { exec 3<&-; return 1; } ;;
        esac
        if [ "$BACKUP_HASH_STYLE" != individual ]; then
          set -- "$@" "$_bpv_saved"
          _bpv_expected="$_bpv_expected$_bpv_oldhash$_bpv_separator$_bpv_saved
"
        fi
        _bpv_saved_size=$(wc -c <"$_bpv_saved" 2>/dev/null) || { exec 3<&-; return 1; }
        _bpv_saved_size=${_bpv_saved_size#"${_bpv_saved_size%%[! ]*}"}
        _bpv_saved_mode=$(mode_value "$_bpv_saved") || { exec 3<&-; return 1; }
        [ "$_bpv_saved_size" = "$_bpv_size" ] &&
          [ "$_bpv_saved_mode" = "$_bpv_oldmode" ] || { exec 3<&-; return 1; }
        _bpv_total=$((_bpv_total + _bpv_size))
        [ "$_bpv_total" -le 8388608 ] || { exec 3<&-; return 1; }
        ;;
      new)
        [ "$_bpv_oldmode" = - ] && [ "$_bpv_size" = 0 ] && [ "$_bpv_oldhash" = - ] || { exec 3<&-; return 1; }
        exists "$BACKUP/$_bpv_rel" && { exec 3<&-; return 1; }
        ;;
      *) exec 3<&-; return 1 ;;
    esac
    _bpv_count=$((_bpv_count + 1))
  done <"$COHORT"
  if IFS='|' read -r _bpv_extra <&3; then exec 3<&-; return 1; fi
  exec 3<&-
  [ "$_bpv_count" -eq 58 ] && [ "$_bpv_total" -le 8388608 ] || return 1
  if [ "$#" -gt 0 ]; then
    _bpv_actual=$(hash_batch "$@") || return 1
    [ "$_bpv_actual" = "${_bpv_expected%?}" ] || return 1
  fi
  return 0
}
journal_validate() {
  JOURNAL_STATE=
  [ -n "$LEDGER" ] && path_regular "$LEDGER" || return 1
  _jv_size=$(wc -c <"$LEDGER" 2>/dev/null | tr -d ' ') || return 1
  case "$_jv_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_jv_size" -le 16384 ] || return 1
  # BusyBox awk can treat a NUL as a record separator.
  tr -d '\000' <"$LEDGER" | cmp -s "$LEDGER" - || return 1
  # Index the embedded cohort once per validation. Exact record keys also
  # reject extra separators, whitespace and paths outside the contract.
  JOURNAL_STATE=$(awk '
    function reject() { invalid = 1; exit 1 }
    FILENAME == ARGV[1] {
      allowed["pending|" $2] = allowed["done|" $2] = 1
      next
    }
    FNR > 120 { reject() }
    FNR == 1 {
      if ($0 != "format=1") reject()
      next
    }
    /^state=(prepared|publishing|committed|rolled-back)$/ {
      state = substr($0, 7)
      next
    }
    {
      if (!($0 in allowed) || seen[$0]++) reject()
      if (substr($0, 1, 5) == "done|") completed++
    }
    END {
      if (invalid || state == "" ||
          (state == "committed" && completed != 58) ||
          (state == "prepared" && FNR != 2)) exit 1
      print state
    }
  ' "$COHORT" "$LEDGER" 2>/dev/null) || return 1
}
journal_append() {
  _ja_line="$1"
  journal_validate || return 1
  JOURNAL_SEQ=$((JOURNAL_SEQ + 1))
  _ja_tmp="$LEDGER.tmp.$$.$JOURNAL_SEQ"
  (umask 077
    cat "$LEDGER" || exit 1
    # Intent covers the complete verified index. Completion is emitted only
    # after all destinations have passed final verification and the data flush.
    _ja_record=
    case "$_ja_line" in
      state=publishing) printf '%s\n' "$_ja_line" || exit 1; _ja_record=pending ;;
      state=committed) _ja_record=done ;;
    esac
    if [ -n "$_ja_record" ]; then
      _ja_n=0
      while IFS=' ' read -r _ja_mode _ja_path; do
        printf '%s|%s\n' "$_ja_record" "$_ja_path" || exit 1
        _ja_n=$((_ja_n + 1))
      done <"$COHORT" || exit 1
      [ "$_ja_n" -eq 58 ] || exit 1
    fi
    if [ "$_ja_line" != state=publishing ]; then printf '%s\n' "$_ja_line"; fi
  ) >"$_ja_tmp" 2>/dev/null || { rm -f "$_ja_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_ja_tmp" && mv -f "$_ja_tmp" "$LEDGER" 2>/dev/null || {
    rm -f "$_ja_tmp" 2>/dev/null || :
    return 1
  }
  return 0
}
backup_files() {
  new_transaction || return 1
  printf 'format=1\nstate=prepared\n' >"$LEDGER" || return 1
  chmod 600 "$LEDGER" || return 1
  backup_capacity_check || return 1
  _bf_tmp="$INDEX_FILE.tmp.$$"
  (umask 077; : >"$_bf_tmp") || return 1
  _bf_total=0
  while IFS=' ' read -r _bf_newmode _bf_rel; do
    _bf_target="$MERV_BASE/$_bf_rel"; _bf_saved="$BACKUP/$_bf_rel"; _bf_new="$STAGE/$_bf_rel"
    _bf_newhash=$(sha256_file "$_bf_new") || return 1
    if [ "${FULL-1}" = 0 ]; then
      safe_chain "${_bf_target%/*}" || return 1
      IFS='|' read -r _bf_kind _bf_mode _bf_bytes _bf_digest _bf_source _bf_path _bf_selected <&5 || return 1
      [ "$_bf_path" = "$_bf_rel" ] && [ "$_bf_source" = "$_bf_newhash" ] || return 1
      if publication_selected "$_bf_rel"; then
        [ "$_bf_selected" = 1 ] || return 1
      else
        [ "$_bf_selected" = 0 ] || return 1
      fi
    fi
    if exists "$_bf_target"; then
      regular "$_bf_target" || return 1
      _bf_oldmode=$(mode_value "$_bf_target") || return 1
      _bf_size=$(wc -c <"$_bf_target" 2>/dev/null) || return 1
      _bf_size=${_bf_size#"${_bf_size%%[! ]*}"}
      case "$_bf_size" in ''|*[!0-9]*) return 1 ;; esac
      _bf_total=$((_bf_total + _bf_size)); [ "$_bf_total" -le 8388608 ] || return 1
      if [ "${FULL-1}" = 0 ] && [ "$_bf_digest" = "$_bf_newhash" ]; then
        cmp -s "$_bf_new" "$_bf_target" || return 1
        _bf_oldhash=$_bf_newhash
      else
        _bf_oldhash=$(sha256_file "$_bf_target") || return 1
      fi
      if [ "${FULL-1}" = 0 ]; then
        [ "$_bf_kind|$_bf_mode|$_bf_bytes|$_bf_digest" = "old|$_bf_oldmode|$_bf_size|$_bf_oldhash" ] || return 1
      fi
      ensure_dir "${_bf_saved%/*}" || return 1
      cp -p "$_bf_target" "$_bf_saved" || return 1
      cmp -s "$_bf_target" "$_bf_saved" || return 1
      [ "$(mode_value "$_bf_saved")" = "$_bf_oldmode" ] || return 1
      printf 'old|%s|%s|%s|%s|%s\n' "$_bf_oldmode" "$_bf_size" "$_bf_oldhash" "$_bf_newhash" "$_bf_rel" >>"$_bf_tmp" || return 1
    else
      if [ "${FULL-1}" = 0 ]; then
        [ "$_bf_kind|$_bf_mode|$_bf_bytes|$_bf_digest|$_bf_selected" = 'new|-|0|-|1' ] || return 1
      fi
      printf 'new|-|0|-|%s|%s\n' "$_bf_newhash" "$_bf_rel" >>"$_bf_tmp" || return 1
    fi
  done <"$COHORT"
  if [ "${FULL-1}" = 0 ]; then
    _bf_extra=
    if IFS= read -r _bf_extra <&5 || [ -n "$_bf_extra" ]; then return 1; fi
  fi
  chmod 600 "$_bf_tmp" && mv -f "$_bf_tmp" "$INDEX_FILE" || return 1
  backup_payload_verify || return 1
  if [ "${FULL-1}" = 0 ]; then
    # Catch changes to earlier entries during the copy loop, using the
    # independently verified backup as the byte-for-byte reference.
    selective_originals_match || return 1
  fi
  _bf_contract_hash=$(sha256_file "$MANIFEST") || return 1
  _bf_index_hash=$(sha256_file "$INDEX_FILE") || return 1
  _bf_helper_hash=$(sha256_file "$RECOVERY_HELPER") || return 1
  sync || return 1
  _bf_ready_tmp="$READY_FILE.tmp.$$"
  (umask 077
    printf 'format=1\ntxn_id=%s\ncontract_sha256=%s\nindex_sha256=%s\nrecovery_sha256=%s\nfile_count=58\n' \
      "$TXN_ID" "$_bf_contract_hash" "$_bf_index_hash" "$_bf_helper_hash" >"$_bf_ready_tmp"
  ) || return 1
  chmod 600 "$_bf_ready_tmp" && mv -f "$_bf_ready_tmp" "$READY_FILE" || return 1
  sync || return 1
  [ "$(cat "$READY_FILE" 2>/dev/null)" = "$(printf 'format=1\ntxn_id=%s\ncontract_sha256=%s\nindex_sha256=%s\nrecovery_sha256=%s\nfile_count=58' \
    "$TXN_ID" "$_bf_contract_hash" "$_bf_index_hash" "$_bf_helper_hash")" ] || return 1
  status BACKUP "persistent manifest backup ready originalBytes=$_bf_total id=$TXN_ID"
}
backup_verify() {
  [ -d "$TXN_DIR" ] && [ ! -L "$TXN_DIR" ] && [ "$(mode_value "$TXN_DIR")" = drwx------ ] || return 1
  [ -d "$BACKUP" ] && [ ! -L "$BACKUP" ] && [ "$(mode_value "$BACKUP")" = drwx------ ] || return 1
  path_regular "$INDEX_FILE" && [ "$(mode_value "$INDEX_FILE")" = -rw------- ] || return 1
  path_regular "$RECOVERY_HELPER" && [ "$(mode_value "$RECOVERY_HELPER")" = -rwx------ ] || return 1
  path_regular "$READY_FILE" && [ "$(mode_value "$READY_FILE")" = -rw------- ] || return 1
  backup_payload_verify "$@" || return 1
  _bv_contract=$(sha256_file "$MANIFEST") || return 1
  _bv_index=$(sha256_file "$INDEX_FILE") || return 1
  _bv_helper=$(sha256_file "$RECOVERY_HELPER") || return 1
  _bv_expected=$(printf 'format=1\ntxn_id=%s\ncontract_sha256=%s\nindex_sha256=%s\nrecovery_sha256=%s\nfile_count=58\n' \
    "$TXN_ID" "$_bv_contract" "$_bv_index" "$_bv_helper")
  [ "$(cat "$READY_FILE" 2>/dev/null)" = "$_bv_expected" ] || return 1
  journal_validate || return 1
  return 0
}
prior_transactions_clear() {
  _ptc_root=${MERV_REPAIR_BACKUP_ROOT%/}
  case "$_ptc_root" in ''|/|"$MERV_BASE"|"$MERV_BASE"/*) return 1 ;; esac
  safe_chain "$_ptc_root" || return 1
  if ! exists "$_ptc_root"; then return 0; fi
  [ -d "$_ptc_root" ] && [ ! -L "$_ptc_root" ] || return 1
  [ -r "$_ptc_root" ] && [ -x "$_ptc_root" ] || return 1
  for _ptc_dir in "$_ptc_root"/mervlan.repair.*; do
    exists "$_ptc_dir" || continue
    [ ! -L "$_ptc_dir" ] && [ -d "$_ptc_dir" ] || return 1
    if ! path_present "$_ptc_dir/READY"; then
      # A prepared journal proves publication never started. Missing or
      # unreadable evidence is ambiguous and must block a new replacement.
      _ptc_saved_txn=$TXN_DIR _ptc_saved_id=$TXN_ID _ptc_saved_backup=$BACKUP
      _ptc_saved_index=$INDEX_FILE _ptc_saved_ready=$READY_FILE
      _ptc_saved_helper=$RECOVERY_HELPER _ptc_saved_ledger=$LEDGER
      TXN_DIR=$_ptc_dir TXN_ID=${_ptc_dir##*/} BACKUP=$_ptc_dir/original
      INDEX_FILE=$_ptc_dir/index READY_FILE=$_ptc_dir/READY
      RECOVERY_HELPER=$_ptc_dir/recover.sh LEDGER=$_ptc_dir/journal
      if ! path_regular "$LEDGER" || ! journal_validate || [ "$JOURNAL_STATE" != prepared ]; then
        TXN_DIR=$_ptc_saved_txn TXN_ID=$_ptc_saved_id BACKUP=$_ptc_saved_backup
        INDEX_FILE=$_ptc_saved_index READY_FILE=$_ptc_saved_ready
        RECOVERY_HELPER=$_ptc_saved_helper LEDGER=$_ptc_saved_ledger
        return 1
      fi
      TXN_DIR=$_ptc_saved_txn TXN_ID=$_ptc_saved_id BACKUP=$_ptc_saved_backup
      INDEX_FILE=$_ptc_saved_index READY_FILE=$_ptc_saved_ready
      RECOVERY_HELPER=$_ptc_saved_helper LEDGER=$_ptc_saved_ledger
      continue
    fi
    _ptc_saved_txn=$TXN_DIR _ptc_saved_id=$TXN_ID _ptc_saved_backup=$BACKUP
    _ptc_saved_index=$INDEX_FILE _ptc_saved_ready=$READY_FILE
    _ptc_saved_helper=$RECOVERY_HELPER _ptc_saved_ledger=$LEDGER
    TXN_DIR=$_ptc_dir TXN_ID=${_ptc_dir##*/} BACKUP=$_ptc_dir/original
    INDEX_FILE=$_ptc_dir/index READY_FILE=$_ptc_dir/READY
    RECOVERY_HELPER=$_ptc_dir/recover.sh LEDGER=$_ptc_dir/journal
    if ! path_regular "$LEDGER" || ! journal_validate; then
      TXN_DIR=$_ptc_saved_txn TXN_ID=$_ptc_saved_id BACKUP=$_ptc_saved_backup
      INDEX_FILE=$_ptc_saved_index READY_FILE=$_ptc_saved_ready
      RECOVERY_HELPER=$_ptc_saved_helper LEDGER=$_ptc_saved_ledger
      return 1
    fi
    case "$JOURNAL_STATE" in prepared|committed|rolled-back) : ;;
      publishing)
        TXN_DIR=$_ptc_saved_txn TXN_ID=$_ptc_saved_id BACKUP=$_ptc_saved_backup
        INDEX_FILE=$_ptc_saved_index READY_FILE=$_ptc_saved_ready
        RECOVERY_HELPER=$_ptc_saved_helper LEDGER=$_ptc_saved_ledger
        return 1 ;;
      *)
        TXN_DIR=$_ptc_saved_txn TXN_ID=$_ptc_saved_id BACKUP=$_ptc_saved_backup
        INDEX_FILE=$_ptc_saved_index READY_FILE=$_ptc_saved_ready
        RECOVERY_HELPER=$_ptc_saved_helper LEDGER=$_ptc_saved_ledger
        return 1 ;;
    esac
    TXN_DIR=$_ptc_saved_txn TXN_ID=$_ptc_saved_id BACKUP=$_ptc_saved_backup
    INDEX_FILE=$_ptc_saved_index READY_FILE=$_ptc_saved_ready
    RECOVERY_HELPER=$_ptc_saved_helper LEDGER=$_ptc_saved_ledger
  done
  return 0
}
publication_selected() {
  [ "${FULL-1}" = 1 ] && return 0
  case "$SELECTED" in *"|$1|"*) return 0 ;; *) return 1 ;; esac
}
stage_hashes() {
  set --
  while IFS=' ' read -r _sh_mode _sh_rel; do
    regular "$STAGE/$_sh_rel" || return 1
    set -- "$@" "$STAGE/$_sh_rel"
  done <"$COHORT"
  if [ "$BACKUP_HASH_STYLE" = individual ]; then
    for _sh_path do
      _sh_hash=$(sha256_file "$_sh_path") || return 1
      printf '%s  %s\n' "$_sh_hash" "$_sh_path" || return 1
    done
  else
    hash_batch "$@"
  fi
}
select_publication() {
  REPLACEMENTS=0 SELECTED='|' SELECTED_BYTES=0
  choose_hash_style
  stage_hashes >"$WORK/stage.hashes" || return 1
  _sp_sep='  '
  if [ "$BACKUP_HASH_STYLE" = openssl ]; then _sp_sep=' *'; fi
  while IFS=' ' read -r _sp_mode _sp_rel; do
    _sp_target="$MERV_BASE/$_sp_rel" _sp_source="$STAGE/$_sp_rel"
    IFS= read -r _sp_line <&6 || return 1
    _sp_newhash=${_sp_line%% *}
    sha_valid "$_sp_newhash" && [ "$_sp_line" = "$_sp_newhash$_sp_sep$_sp_source" ] || return 1
    safe_chain "${_sp_target%/*}" || return 1
    _sp_kind=new _sp_actual=- _sp_oldsize=0 _sp_oldhash=- _sp_selected=1 _sp_cmp=1
    if exists "$_sp_target"; then
      _sp_kind=old
      regular "$_sp_target" && [ -r "$_sp_target" ] || return 1
      _sp_actual=$(mode_value "$_sp_target") || return 1
      mode_record_valid "$_sp_actual" || return 1
      _sp_oldsize=$(wc -c <"$_sp_target") || return 1
      _sp_oldsize=${_sp_oldsize#"${_sp_oldsize%%[! ]*}"}
      case "$_sp_oldsize" in ''|*[!0-9]*) return 1 ;; esac
      [ "$_sp_oldsize" -le 8388608 ] || return 1
      _sp_cmp=0
      cmp -s "$_sp_source" "$_sp_target" || _sp_cmp=$?
      case "$_sp_cmp" in
        0) _sp_oldhash=$_sp_newhash ;;
        1) _sp_oldhash=$(sha256_file "$_sp_target") || return 1 ;;
        *) return 1 ;;
      esac
      case "$_sp_cmp:$_sp_mode:$_sp_actual" in
        0:0755:-rwxr-xr-x|0:0644:-rw-r--r--) _sp_selected=0 ;;
      esac
    fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$_sp_kind" "$_sp_actual" "$_sp_oldsize" \
      "$_sp_oldhash" "$_sp_newhash" "$_sp_rel" "$_sp_selected" || return 1
    [ "$_sp_selected" -eq 1 ] || continue
    _sp_size=$_sp_oldsize
    if [ "$_sp_cmp" -ne 0 ]; then _sp_size=$(wc -c <"$_sp_source") || return 1; fi
    case "$_sp_size" in ''|*[!0-9]*) return 1 ;; esac
    SELECTED_BYTES=$((SELECTED_BYTES + _sp_size))
    SELECTED="$SELECTED$_sp_rel|"
    REPLACEMENTS=$((REPLACEMENTS + 1))
  done <"$COHORT" 6<"$WORK/stage.hashes" >"$WORK/classified" || return 1
  status SELECT "files=58 replacements=$REPLACEMENTS bytes=$SELECTED_BYTES"
}
selective_originals_match() {
  while IFS='|' read -r _som_kind _som_mode _som_size _som_oldhash _som_newhash _som_rel; do
    _som_target="$MERV_BASE/$_som_rel"
    valid_rel "$_som_rel" && safe_chain "${_som_target%/*}" || return 1
    case "$_som_kind" in
      old)
        regular "$_som_target" && regular "$BACKUP/$_som_rel" &&
          cmp -s "$BACKUP/$_som_rel" "$_som_target" &&
          [ "$(mode_value "$_som_target")" = "$_som_mode" ] || return 1 ;;
      new) if exists "$_som_target"; then return 1; fi ;;
      *) return 1 ;;
    esac
  done <"$INDEX_FILE"
}
record_original_state() {
  _ros_all=1
  exec 3<"$INDEX_FILE" || return 1
  while IFS=' ' read -r _ros_newmode _ros_rel; do
    IFS='|' read -r _ros_kind _ros_oldmode _ros_size _ros_oldhash _ros_newhash _ros_path <&3 || { exec 3<&-; return 1; }
    [ "$_ros_rel" = "$_ros_path" ] || { exec 3<&-; return 1; }
    _ros_target="$MERV_BASE/$_ros_rel"
    safe_chain "${_ros_target%/*}" || { exec 3<&-; return 1; }
    case "$_ros_kind" in
      old)
        if ! regular "$_ros_target" || [ "$(sha256_file "$_ros_target" 2>/dev/null)" != "$_ros_oldhash" ] ||
           [ "$(mode_value "$_ros_target" 2>/dev/null)" != "$_ros_oldmode" ]; then _ros_all=0; fi ;;
      new) exists "$_ros_target" && _ros_all=0 ;;
      *) exec 3<&-; return 1 ;;
    esac
  done <"$COHORT"
  exec 3<&-
  [ "$_ros_all" -eq 1 ]
}
restore_entry() {
  _re_kind="$1" _re_oldmode="$2" _re_size="$3" _re_oldhash="$4" _re_newhash="$5" _re_rel="$6" _re_newmode="$7"
  _re_target="$MERV_BASE/$_re_rel"
  _re_publish="$_re_target.mervlan-repair.$TXN_ID.publish.part"
  _re_restore="$_re_target.mervlan-repair.$TXN_ID.restore.part"
  safe_chain "${_re_target%/*}" || return 1
  for _re_tmp in "$_re_publish" "$_re_restore"; do
    if exists "$_re_tmp"; then
      regular "$_re_tmp" || return 1
      case "$_re_tmp" in
        "$_re_publish")
          [ "$(sha256_file "$_re_tmp" 2>/dev/null)" = "$_re_newhash" ] &&
            mode_ok "$_re_newmode" "$_re_tmp" || return 1 ;;
        "$_re_restore")
          [ "$_re_kind" = old ] &&
            [ "$(sha256_file "$_re_tmp" 2>/dev/null)" = "$_re_oldhash" ] &&
            [ "$(mode_value "$_re_tmp" 2>/dev/null)" = "$_re_oldmode" ] || return 1 ;;
      esac
      rm -f "$_re_tmp" || return 1
      exists "$_re_tmp" && return 1
    fi
  done
  case "$_re_kind" in
    old)
      if regular "$_re_target" &&
         [ "$(sha256_file "$_re_target" 2>/dev/null)" = "$_re_oldhash" ] &&
         [ "$(mode_value "$_re_target" 2>/dev/null)" = "$_re_oldmode" ]; then
        return 0
      fi
      if exists "$_re_target"; then
        regular "$_re_target" || return 1
        [ "$(sha256_file "$_re_target" 2>/dev/null)" = "$_re_newhash" ] &&
          mode_ok "$_re_newmode" "$_re_target" || return 1
      fi
      ensure_dir "${_re_target%/*}" || return 1
      cp -p "$BACKUP/$_re_rel" "$_re_restore" 2>/dev/null || return 1
      [ "$(sha256_file "$_re_restore" 2>/dev/null)" = "$_re_oldhash" ] &&
        [ "$(mode_value "$_re_restore" 2>/dev/null)" = "$_re_oldmode" ] || return 1
      owner_ok && scan_processes || return 1
      sync || return 1
      mv -f "$_re_restore" "$_re_target" || return 1
      regular "$_re_target" && [ "$(sha256_file "$_re_target")" = "$_re_oldhash" ] &&
        [ "$(mode_value "$_re_target")" = "$_re_oldmode" ] || return 1
      ;;
    new)
      if exists "$_re_target"; then
        regular "$_re_target" || return 1
        [ "$(sha256_file "$_re_target" 2>/dev/null)" = "$_re_newhash" ] &&
          mode_ok "$_re_newmode" "$_re_target" || return 1
        owner_ok && scan_processes || return 1
        rm -f "$_re_target" || return 1
      fi
      exists "$_re_target" && return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}
destination_states_known() {
  exec 3<"$INDEX_FILE" || return 1
  while IFS=' ' read -r _dsk_mode _dsk_rel; do
    IFS='|' read -r _dsk_kind _dsk_oldmode _dsk_size _dsk_oldhash _dsk_newhash _dsk_path <&3 || { exec 3<&-; return 1; }
    [ "$_dsk_rel" = "$_dsk_path" ] || { exec 3<&-; return 1; }
    _dsk_target="$MERV_BASE/$_dsk_rel"
    safe_chain "${_dsk_target%/*}" || { exec 3<&-; return 1; }
    _dsk_publish="$_dsk_target.mervlan-repair.$TXN_ID.publish.part"
    _dsk_restore="$_dsk_target.mervlan-repair.$TXN_ID.restore.part"
    if exists "$_dsk_publish"; then
      regular "$_dsk_publish" &&
        [ "$(sha256_file "$_dsk_publish" 2>/dev/null)" = "$_dsk_newhash" ] &&
        mode_ok "$_dsk_mode" "$_dsk_publish" || { exec 3<&-; return 1; }
    fi
    if exists "$_dsk_restore"; then
      [ "$_dsk_kind" = old ] && regular "$_dsk_restore" &&
        [ "$(sha256_file "$_dsk_restore" 2>/dev/null)" = "$_dsk_oldhash" ] &&
        [ "$(mode_value "$_dsk_restore" 2>/dev/null)" = "$_dsk_oldmode" ] || { exec 3<&-; return 1; }
    fi
    if exists "$_dsk_target"; then
      regular "$_dsk_target" || { exec 3<&-; return 1; }
      _dsk_hash=$(sha256_file "$_dsk_target" 2>/dev/null) || { exec 3<&-; return 1; }
      _dsk_actual_mode=$(mode_value "$_dsk_target" 2>/dev/null) || { exec 3<&-; return 1; }
      case "$_dsk_kind" in
        old)
          { [ "$_dsk_hash" = "$_dsk_oldhash" ] && [ "$_dsk_actual_mode" = "$_dsk_oldmode" ]; } ||
          { [ "$_dsk_hash" = "$_dsk_newhash" ] && mode_ok "$_dsk_mode" "$_dsk_target"; } || {
            exec 3<&-; return 1;
          } ;;
        new)
          [ "$_dsk_hash" = "$_dsk_newhash" ] && mode_ok "$_dsk_mode" "$_dsk_target" || {
            exec 3<&-; return 1;
          } ;;
        *) exec 3<&-; return 1 ;;
      esac
    else
      [ "$_dsk_kind" = old ] || [ "$_dsk_kind" = new ] || { exec 3<&-; return 1; }
    fi
  done <"$COHORT"
  exec 3<&-
  return 0
}
restore_transaction() {
  backup_verify || return 1
  case "$JOURNAL_STATE" in prepared|publishing|rolled-back) : ;;
    committed) return 1 ;;
    *) return 1 ;;
  esac
  destination_states_known || return 1
  status ROLLBACK "restoring transaction=$TXN_ID"
  exec 3<"$INDEX_FILE" || return 1
  while IFS=' ' read -r _rt_newmode _rt_rel; do
    IFS='|' read -r _rt_kind _rt_oldmode _rt_size _rt_oldhash _rt_newhash _rt_path <&3 || { exec 3<&-; return 1; }
    [ "$_rt_rel" = "$_rt_path" ] || { exec 3<&-; return 1; }
    restore_entry "$_rt_kind" "$_rt_oldmode" "$_rt_size" "$_rt_oldhash" \
      "$_rt_newhash" "$_rt_rel" "$_rt_newmode" || { exec 3<&-; return 1; }
  done <"$COHORT"
  exec 3<&-
  record_original_state || return 1
  sync || return 1
  [ "$JOURNAL_STATE" = rolled-back ] || journal_append state=rolled-back || return 1
  sync || return 1
  ROLLBACK_OK=1 TX=0
  status ROLLBACK 'all manifest targets match original bytes, modes and absent states'
  return 0
}
publish_batch() {
  # All siblings in the batch are verified and flushed before any rename.
  sync || return 1
  while [ "$#" -gt 0 ]; do
    _pu_mode=$1 _pu_rel=$2
    shift 2
    while :; do
      IFS='|' read -r _pu_kind _pu_oldmode _pu_size _pu_oldhash _pu_newhash _pu_path <&4 || return 1
      publication_selected "$_pu_path" && break
    done
    [ "$_pu_rel" = "$_pu_path" ] || return 1
    _pu_target="$MERV_BASE/$_pu_rel"
    _pu_tmp="$_pu_target.mervlan-repair.$TXN_ID.publish.part"
    safe_chain "${_pu_target%/*}" && regular "$_pu_tmp" &&
      cmp -s "$STAGE/$_pu_rel" "$_pu_tmp" && mode_ok "$_pu_mode" "$_pu_tmp" || return 1
    case "$_pu_kind" in
      old) regular "$_pu_target" && [ "$(sha256_file "$_pu_target" 2>/dev/null)" = "$_pu_oldhash" ] &&
             [ "$(mode_value "$_pu_target" 2>/dev/null)" = "$_pu_oldmode" ] || return 1 ;;
      new) if exists "$_pu_target"; then return 1; fi ;;
      *) return 1 ;;
    esac
    owner_ok && scan_processes || return 1
    if repair_test_fault "${MERV_REPAIR_TEST_PAUSE_AT:-}" "$((PUBLISHED+1))"; then sleep 30; fi
    repair_test_fault "${MERV_REPAIR_TEST_FAIL_AT:-}" "$((PUBLISHED+1))" && return 1
    mv -f "$_pu_tmp" "$_pu_target" || return 1
    regular "$_pu_target" && [ "$(sha256_file "$_pu_target" 2>/dev/null)" = "$_pu_newhash" ] &&
      mode_ok "$_pu_mode" "$_pu_target" || return 1
    repair_test_fault "${MERV_REPAIR_TEST_FAIL_AFTER_AT:-}" "$((PUBLISHED+1))" && return 1
    PUBLISHED=$((PUBLISHED + 1))
    VERIFIED=$((VERIFIED + 1))
    if [ $((PUBLISHED % 10)) -eq 0 ] || [ "$PUBLISHED" -eq "$REPLACEMENTS" ]; then
      status PUBLISH "replaced=$PUBLISHED verified=$VERIFIED/58"
    fi
  done
}
prepare_publication() {
  set --
  while IFS=' ' read -r _pb_mode _pb_rel; do
    IFS='|' read -r _pb_kind _pb_oldmode _pb_size _pb_oldhash _pb_newhash _pb_path <&3 || return 1
    [ "$_pb_rel" = "$_pb_path" ] || return 1
    publication_selected "$_pb_rel" || continue
    _pb_target="$MERV_BASE/$_pb_rel" _pb_source="$STAGE/$_pb_rel"
    safe_chain "${_pb_target%/*}" && ensure_dir "${_pb_target%/*}" || return 1
    _pb_tmp="$_pb_target.mervlan-repair.$TXN_ID.publish.part"
    exists "$_pb_tmp" && return 1
    cp "$_pb_source" "$_pb_tmp" && chmod "$_pb_mode" "$_pb_tmp" || return 1
    regular "$_pb_tmp" && [ "$(sha256_file "$_pb_tmp" 2>/dev/null)" = "$_pb_newhash" ] &&
      mode_ok "$_pb_mode" "$_pb_tmp" || return 1
    set -- "$@" "$_pb_mode" "$_pb_rel"
    if [ "$_pb_batch" -eq 1 ]; then
      publish_batch "$@" || return 1
      set --
    fi
  done <"$COHORT"
  if [ "$#" -gt 0 ]; then publish_batch "$@" || return 1; fi
  [ "$PUBLISHED" -eq "$REPLACEMENTS" ] && [ "$VERIFIED" -eq "$REPLACEMENTS" ]
}
publication() {
  # Preserve the ordinary flash floor and allow 1 MiB for batch metadata.
  # With less spare space, keep the original one-sibling footprint.
  _pb_batch=1
  if [ "$flashfree" -ge "$((REPAIR_MIN_DEST_FREE_KIB + 1024 + (SELECTED_BYTES + 1023) / 1024))" ]; then
    _pb_batch=58
    backup_verify || return 1
  else
    backup_verify verify-stage || return 1
  fi
  journal_append state=publishing || return 1
  TX=1
  sync || return 1
  prepare_publication 3<"$INDEX_FILE" 4<"$INDEX_FILE"
}
final_verify() {
  owner_ok && scan_processes || return 1
  while IFS=' ' read -r _fv_mode _fv_rel; do
    _fv_target="$MERV_BASE/$_fv_rel" _fv_source="$STAGE/$_fv_rel"
    safe_chain "${_fv_target%/*}" && regular "$_fv_target" &&
      cmp -s "$_fv_source" "$_fv_target" && mode_ok "$_fv_mode" "$_fv_target" || return 1
  done <"$COHORT"
  protected_unchanged
}
rollback() {
  owner_ok || return 1
  restore_transaction
}
create_recovery_work() {
  safe_chain "$MERV_REPAIR_TMP_ROOT" && [ -d "$MERV_REPAIR_TMP_ROOT" ] || return 1
  _crw_now=$(date +%s 2>/dev/null || printf '')
  case "$_crw_now" in ''|*[!0-9]*) return 1 ;; esac
  _crw_try=0
  while [ "$_crw_try" -lt 16 ]; do
    WORK="$MERV_REPAIR_TMP_ROOT/mervlan_recovery.$_crw_now.$$.$_crw_try"
    if (umask 077; mkdir "$WORK") 2>/dev/null; then break; fi
    _crw_try=$((_crw_try + 1))
  done
  [ -d "$WORK" ] && [ ! -L "$WORK" ] || return 1
  chmod 700 "$WORK" || return 1
  printf 'mervlan-repair-recovery-v1\n' >"$WORK/.owner" || return 1
  chmod 600 "$WORK/.owner" || return 1
  MANIFEST="$WORK/expected.manifest" COHORT="$WORK/cohort"
  write_contract || return 1
}
recover_main() {
  _rm_id="${2:-}"
  case "$_rm_id" in mervlan.repair.*) : ;; *) return 2 ;; esac
  case "$_rm_id" in *..*|*/*|*[!A-Za-z0-9._-]*) return 2 ;; esac
  test_roots_valid || return 2
  MERV_REPAIR_BACKUP_ROOT=${MERV_REPAIR_BACKUP_ROOT%/}
  TXN_ID=$_rm_id TXN_DIR="$MERV_REPAIR_BACKUP_ROOT/$_rm_id"
  BACKUP="$TXN_DIR/original" INDEX_FILE="$TXN_DIR/index"
  READY_FILE="$TXN_DIR/READY" LEDGER="$TXN_DIR/journal" RECOVERY_HELPER="$TXN_DIR/recover.sh"
  safe_chain "$MERV_BASE" && [ -d "$MERV_BASE" ] &&
    safe_chain "$MERV_REPAIR_BACKUP_ROOT" && safe_chain "$TXN_DIR" || return 1
  create_recovery_work || return 1
  action_parent_check || return 1
  scan_processes || return 1
  acquire || return 1
  scan_processes || return 1
  backup_verify || { status REFUSED 'backup is incomplete or corrupt'; return 1; }
  case "$JOURNAL_STATE" in
    committed) status REFUSED 'committed repair is not eligible for rollback'; return 1 ;;
    rolled-back)
      record_original_state || return 1
      ROLLBACK_OK=1
      status RECOVERY 'previous rollback verified'
      ;;
    prepared|publishing)
      restore_transaction || { status RECOVERY 'unknown or unsafe destination state; evidence retained'; return 1; }
      ;;
    *) return 1 ;;
  esac
  owner_ok || return 1
  release || return 1
  COMMITTED=1
  status RECOVERY 'manifest originals restored; persistent evidence retained'
  return 0
}
repair_handoff_write() {
  _rhw_engine="$SOURCE_ROOT/functions/update_mervlan_repair.sh"
  regular "$_rhw_engine" || return 1
  cmp -s "$0" "$_rhw_engine" || {
    status REFUSED 'downloaded Repair executable does not match trusted bootstrap'
    return 1
  }
  HANDOFF_START=$(proc_start "$$" "$MERV_REPAIR_OWNER_PROC_ROOT") || return 1
  HANDOFF_FILE="$WORK/.handoff"
  _rhw_tmp="$HANDOFF_FILE.tmp.$$"
  (umask 077
    printf 'format=1\nref=%s\nroot=%s\npid=%s\nproc_start_time=%s\n' \
      "$REF" "$ROOT" "$$" "$HANDOFF_START" >"$_rhw_tmp"
  ) || return 1
  chmod 600 "$_rhw_tmp" && mv -f "$_rhw_tmp" "$HANDOFF_FILE" || return 1
  # The same PID consumes this scratch handoff immediately, before any transaction.
  exec /bin/sh "$_rhw_engine" --continue "$WORK"
}
repair_handoff_adopt() {
  WORK="${2:-}"
  case "$WORK" in "$MERV_REPAIR_TMP_ROOT"/mervlan_lean.*) : ;; *) return 1 ;; esac
  safe_chain "$WORK" && [ -d "$WORK" ] && [ ! -L "$WORK" ] || return 1
  regular "$WORK/.owner" && [ "$(cat "$WORK/.owner" 2>/dev/null)" = lean-repair-v1 ] || return 1
  regular "$WORK/.handoff" && [ "$(mode_value "$WORK/.handoff")" = -rw------- ] || return 1
  _rha_n=0 REF= ROOT= _rha_pid= _rha_start=
  while IFS= read -r _rha_line || [ -n "$_rha_line" ]; do
    _rha_n=$((_rha_n + 1)); [ "$_rha_n" -le 5 ] || return 1
    case "$_rha_line" in
      format=1) [ "$_rha_n" -eq 1 ] || return 1 ;;
      ref=*) REF=${_rha_line#ref=} ;;
      root=*) ROOT=${_rha_line#root=} ;;
      pid=*) _rha_pid=${_rha_line#pid=} ;;
      proc_start_time=*) _rha_start=${_rha_line#proc_start_time=} ;;
      *) return 1 ;;
    esac
  done <"$WORK/.handoff"
  [ "$_rha_n" -eq 5 ] && valid_ref "$REF" || return 1
  case "$ROOT" in mervlan-[A-Za-z0-9._-]*) : ;; *) return 1 ;; esac
  [ "$_rha_pid" = "$$" ] && [ "$(proc_start "$$" "$MERV_REPAIR_OWNER_PROC_ROOT" 2>/dev/null)" = "$_rha_start" ] || return 1
  ARCHIVE="$WORK/snapshot.tar.gz" STAGE="$WORK/stage" BACKUP= MANIFEST="$WORK/expected.manifest"
  COHORT="$WORK/cohort" SOURCE_ROOT="$WORK/extract/$ROOT"
  regular "$ARCHIVE" && [ ! -L "$SOURCE_ROOT" ] && [ -d "$SOURCE_ROOT" ] || return 1
  regular "$SOURCE_ROOT/functions/update_mervlan_repair.manifest" || return 1
  regular "$SOURCE_ROOT/functions/update_mervlan_repair.sh" || return 1
  cmp -s "$0" "$SOURCE_ROOT/functions/update_mervlan_repair.sh" || return 1
  write_contract || return 1
  cmp -s "$MANIFEST" "$SOURCE_ROOT/functions/update_mervlan_repair.manifest" || return 1
  [ -d "$STAGE" ] && [ ! -L "$STAGE" ] && [ -d "$WORK/protected" ] &&
    [ ! -L "$WORK/protected" ] || return 1
  return 0
}
test_roots_valid() {
  case "$MERV_BASE" in
    /jffs/addons/mervlan)
      [ "${MERV_REPAIR_TEST_ONLY:-0}" = 0 ] || return 1
      [ "$MERV_REPAIR_BACKUP_ROOT" = /jffs/addons/mervlan_backups ] || return 1
      [ "$MERV_REPAIR_SNAPSHOT_BASE" = https://codeload.github.com/r80xcore/mervlan/tar.gz ] || return 1
      ;;
    /tmp/mervlan_standalone_fixture.*/jffs/addons/mervlan)
      [ "${MERV_REPAIR_TEST_ONLY:-0}" = 1 ] || return 1
      case "$MERV_REPAIR_BACKUP_ROOT" in /tmp/mervlan_standalone_fixture.*/jffs/addons/mervlan_backups) : ;; *) return 1 ;; esac
      [ "$MERV_REPAIR_PROC_ROOT" != /proc ] && [ "$MERV_REPAIR_MEMINFO" != /proc/meminfo ] || return 1
      ;;
    *) return 1 ;;
  esac
  [ "${MERV_REPAIR_SNAPSHOT_BASE#https://}" != "$MERV_REPAIR_SNAPSHOT_BASE" ] || return 1
  return 0
}
repair_run() {
  action_parent_check || {
    status ADMISSION 'admission=action_parent_invalid'
    stop 'action lock parent is malformed or unauthenticated'
  }
  scan_processes || stop 'initial legacy mutator exclusion failed'
  acquire || stop 'action, maintenance or Manager ownership is unavailable'
  scan_processes || stop 'post-acquisition legacy mutator exclusion failed'
  protected_files || stop 'protected-state snapshot failed'
  SELECTED_BYTES=$STAGED_BYTES
  if [ "${FULL-1}" = 0 ]; then
    owner_ok && prior_transactions_clear || stop 'ownership lost or previous transaction unresolved'
    select_publication || stop 'installed target classification failed'
    if [ "$REPLACEMENTS" -eq 0 ]; then
      preflight && final_verify && owner_ok || stop 'selective no-op verification failed'
      release || stop 'ownership release failed'
      status SUCCESS 'files=58 replaced=0 verified no-op'
      return 0
    fi
  fi
  if [ "${FULL-1}" = 0 ]; then
    backup_files 5<"$WORK/classified"
  else
    backup_files
  fi || stop 'persistent manifest backup failed; no installed files were replaced'
  preflight || stop 'resource preflight before publication failed'
  publication || stop 'publication failed; rollback will be attempted'
  final_verify || stop 'final content, mode, protected-state or owner verification failed'
  sync || stop 'could not durably flush verified replacement files'
  owner_ok && journal_append state=committed || stop 'could not durably mark the verified repair committed'
  COMMITTED=1 TX=0
  sync || stop 'could not durably finish the Repair transaction'
  owner_ok || stop 'ownership changed before release'
  release || stop 'ownership release failed'
  status SUCCESS "files=58 backup=$TXN_ID replaced=$PUBLISHED no Update/Apply invoked"
}
cleanup() {
  _cleanup_rc=$?
  trap - 0 HUP INT TERM
  if [ "$COMMITTED" -ne 1 ] && [ "$TX" -eq 1 ]; then
    if owner_ok; then rollback || { status RECOVERY 'synchronous rollback incomplete; persistent evidence retained'; _cleanup_rc=1; }
    else status RECOVERY 'owner identity changed; rollback skipped and persistent evidence retained'; _cleanup_rc=1; fi
  fi
  if [ "$MANAGER_LOCKED" -eq 1 ] || [ "$MAINTENANCE_LOCKED" -eq 1 ] || [ "$ACTION_LOCKED" -eq 1 ]; then
    release || { status ERROR 'lock release failed; inspect lock ownership'; _cleanup_rc=1; }
  fi
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ] && [ ! -L "$WORK" ]; then
    case "$WORK" in
      "$MERV_REPAIR_TMP_ROOT"/mervlan_lean.*|"$MERV_REPAIR_TMP_ROOT"/mervlan_recovery.*)
        if [ "$_cleanup_rc" -eq 0 ] && { [ "$COMMITTED" -eq 1 ] || [ "$ROLLBACK_OK" -eq 1 ] || [ "$TX" -eq 0 ]; }; then
          rm -rf "$WORK" 2>/dev/null || { status EVIDENCE "temporary workspace retained=$WORK"; _cleanup_rc=1; }
        else
          status EVIDENCE "temporary workspace retained=$WORK"
        fi ;;
      *) status EVIDENCE 'temporary workspace path was not recognized'; _cleanup_rc=1 ;;
    esac
  fi
  exit "$_cleanup_rc"
}
main() {
  if [ "${1:-}" != recover ]; then
    case "${FULL-1}" in 0|1) : ;; *) stop 'FULL must be 0 or 1' ;; esac
  fi
  case "${1:-}" in
    recover) recover_main "$@"; return $? ;;
    --continue)
      test_roots_valid || stop 'unsafe runtime roots'
      repair_handoff_adopt "$@" || stop 'same-snapshot handoff is invalid'
      stage_files || stop 'trusted snapshot staging failed'
      repair_run
      ;;
    *)
      valid_ref "${1:-}" || stop 'provide a full 40-character immutable source commit SHA'
      test_roots_valid || stop 'unsafe runtime roots'
      safe_chain "$MERV_BASE" && [ -d "$MERV_BASE" ] || stop 'unsafe or missing addon directory'
      preflight || stop 'resource preflight failed'
      create_work || stop 'private workspace unavailable or earlier work remains unresolved'
      fetch_archive || stop 'bounded immutable snapshot download failed'
      validate_archive || stop 'archive or trusted manifest validation failed'
      repair_handoff_write
      ;;
  esac
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
exit $?
