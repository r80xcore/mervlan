#!/bin/sh
# Standalone emergency repair.  This file is deliberately source-free: it is
# the rescue ABI used when the installed updater, settings libraries, or lock
# libraries are missing or too old to load safely.
set -u

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${MERV_REPAIR_TMP_ROOT:=/tmp}"
: "${MERV_REPAIR_SNAPSHOT_BASE:=https://codeload.github.com/r80xcore/mervlan/tar.gz}"
: "${MERV_REPAIR_CONNECT_TIMEOUT:=15}"
: "${MERV_REPAIR_MAX_TIME:=120}"
: "${MERV_REPAIR_MAINTENANCE_LOCK:=/tmp/mervlan_tmp/locks/mervlan_maintenance.lock}"
: "${MERV_REPAIR_LEGACY_LOCK_ROOT:=/tmp/mervlan_tmp/locks}"
: "${MERV_REPAIR_PROC_ROOT:=/proc}"

RUN_DIR=""
EXTRACT_DIR=""
STAGE_DIR=""
BACKUP_DIR=""
PATHS_FILE=""
LEDGER_FILE=""
PROTECTED_DIR=""
SNAPSHOT_ARCHIVE=""
SNAPSHOT_RAW=""
SNAPSHOT_ROOT=""
CURL_BIN="${MERV_REPAIR_CURL:-}"
REF=""
REPAIR_LOCK_OWNED=0
REPAIR_LOCK_NONCE=""
REPAIR_LOCK_START=""
REPAIR_LOCK_CREATED=""
REPAIR_LEDGER_SEQ=0
REPAIR_PROGRESS_SEQ=0
REPAIR_PROGRESS_TOKEN="${MERV_PROGRESS_TOKEN:-}"
REPAIR_PROGRESS_ACTION=""
REPAIR_PROGRESS_STARTED=""
REPAIR_SUCCESS=0
REPAIR_ROLLBACK_FAILED=0
REPAIR_INTERRUPTED=0
REPAIR_OWNER_LOST=0
REPAIR_PUBLISH_TMP=""
REPAIR_PUBLISH_SOURCE=""
REPAIR_HANDOFF_STATE="${MERV_REPAIR_HANDOFF_STATE:-}"

log() { printf '%s\n' "[mervlan-repair] $*" >&2; }

json_escape() {
  printf '%s' "${1:-}" | tr -d '\000-\010\013\014\016-\037' |
    sed 's/\\/\\\\/g; s/"/\\"/g'
}

token_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 96 ]
}

# Progress is diagnostic only.  A failed progress publication never changes
# the repair admission, ledger, rollback, or terminal result.
progress() {
  _rp_state="$1" _rp_phase="$2" _rp_percent="$3" _rp_message="$4"
  token_valid "$REPAIR_PROGRESS_TOKEN" || return 0
  _rp_root="${MERV_REPAIR_PROGRESS_ROOT:-/tmp/mervlan_tmp/progress}"
  case "$_rp_root" in ''|*..*|*//*|*[!A-Za-z0-9_./-]*) return 0 ;; esac
  [ -d "$_rp_root" ] || mkdir -p "$_rp_root" 2>/dev/null || return 0
  REPAIR_PROGRESS_SEQ=$((REPAIR_PROGRESS_SEQ + 1))
  _rp_tmp="$_rp_root/$REPAIR_PROGRESS_TOKEN.json.tmp.$$.$REPAIR_PROGRESS_SEQ"
  _rp_path="$_rp_root/$REPAIR_PROGRESS_TOKEN.json"
  _rp_now=$(date +%s 2>/dev/null || printf '0')
  case "$_rp_now" in ''|*[!0-9]*) _rp_now=0 ;; esac
  [ -n "$REPAIR_PROGRESS_STARTED" ] || REPAIR_PROGRESS_STARTED="$_rp_now"
  _rp_error=null
  [ "$_rp_state" = failed ] && _rp_error="\"$(json_escape "$_rp_message")\""
  {
    printf '{"format_version":2,"token":"%s","action":"%s","label":"Emergency MerVLAN Repair"' \
      "$(json_escape "$REPAIR_PROGRESS_TOKEN")" "$(json_escape "$REPAIR_PROGRESS_ACTION")"
    printf ',"state":"%s","mode":"phase","phase":"%s","current":0,"total":0,"percent":%s' \
      "$_rp_state" "$(json_escape "$_rp_phase")" "$_rp_percent"
    printf ',"message":"%s","error":%s,"started_at":%s,"owner_pid":%s,"owner_start":%s,"owner_nonce":"%s","terminal_state":"%s","updated_at":%s}\n' \
      "$(json_escape "$_rp_message")" "$_rp_error" "$REPAIR_PROGRESS_STARTED" "$$" \
      "${REPAIR_LOCK_START:-0}" "$(json_escape "${REPAIR_LOCK_NONCE:-repair}")" \
      "$_rp_state" "$_rp_now"
  } >"$_rp_tmp" 2>/dev/null || { rm -f "$_rp_tmp" 2>/dev/null || :; return 0; }
  chmod 644 "$_rp_tmp" 2>/dev/null || :
  mv -f "$_rp_tmp" "$_rp_path" 2>/dev/null || rm -f "$_rp_tmp" 2>/dev/null || :
  return 0
}

valid_ref() {
  REF="${1:-main}"
  case "$REF" in main|dev) return 0 ;; esac
  case "$REF" in ''|/*|*/|*..*|*//*|*.lock|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "$REF" in [A-Za-z0-9]*) ;; *) return 1 ;; esac
  case "$REF" in *[A-Za-z0-9]) return 0 ;; *) return 1 ;; esac
}

path_present() {
  ls -ld "$1" >/dev/null 2>&1
}

path_regular() {
  path_present "$1" && [ ! -L "$1" ] && [ -f "$1" ]
}

# Check every existing component without following a symlink.  The rescue
# path only accepts absolute, normalized paths and never makes a destination
# parent through a symlink.
path_chain_safe() {
  _pcs_path="$1"
  case "$_pcs_path" in /*) ;; *) return 1 ;; esac
  case "$_pcs_path" in *..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  _pcs_current=/
  _pcs_rest=${_pcs_path#/}
  while [ -n "$_pcs_rest" ]; do
    case "$_pcs_rest" in
      */*) _pcs_component=${_pcs_rest%%/*}; _pcs_rest=${_pcs_rest#*/} ;;
      *) _pcs_component=$_pcs_rest; _pcs_rest="" ;;
    esac
    [ -n "$_pcs_component" ] || return 1
    _pcs_current="$_pcs_current$_pcs_component"
    if path_present "$_pcs_current"; then
      [ ! -L "$_pcs_current" ] && [ -d "$_pcs_current" ] || return 1
    fi
    _pcs_current="$_pcs_current/"
  done
  return 0
}

mkdir_chain_safe() {
  _mcs_path="$1"
  path_chain_safe "$_mcs_path" || return 1
  _mcs_current=/
  _mcs_rest=${_mcs_path#/}
  while [ -n "$_mcs_rest" ]; do
    case "$_mcs_rest" in
      */*) _mcs_component=${_mcs_rest%%/*}; _mcs_rest=${_mcs_rest#*/} ;;
      *) _mcs_component=$_mcs_rest; _mcs_rest="" ;;
    esac
    _mcs_current="$_mcs_current$_mcs_component"
    if ! path_present "$_mcs_current"; then
      mkdir "$_mcs_current" 2>/dev/null || return 1
    fi
    [ ! -L "$_mcs_current" ] && [ -d "$_mcs_current" ] || return 1
    _mcs_current="$_mcs_current/"
  done
  return 0
}

safe_rel_path() {
  _srp_path="$1"
  case "$_srp_path" in
    ''|/*|*..*|*//*|*' '*|*'	'*|*'\\'*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  case "$_srp_path" in
    .|./*|*/.|*/./*|*/..|../*) return 1 ;;
  esac
  return 0
}

find_curl() {
  [ -n "$CURL_BIN" ] && [ -x "$CURL_BIN" ] && return 0
  CURL_BIN=""
  _fc_oldIFS="$IFS"
  IFS=:
  for _fc_dir in ${PATH:-}; do
    [ -n "$_fc_dir" ] || _fc_dir=.
    if [ -x "$_fc_dir/curl" ]; then CURL_BIN="$_fc_dir/curl"; break; fi
  done
  IFS="$_fc_oldIFS"
  [ -n "$CURL_BIN" ] || { [ -x /usr/sbin/curl ] && CURL_BIN=/usr/sbin/curl; }
  [ -x "$CURL_BIN" ]
}

fetch_snapshot() {
  _fs_dest="$1" _fs_part="${1}.part" _fs_url="$MERV_REPAIR_SNAPSHOT_BASE/$REF"
  rm -f "$_fs_part" 2>/dev/null || return 1
  "$CURL_BIN" -f -sS -L --retry 3 --retry-delay 1 \
    --connect-timeout "$MERV_REPAIR_CONNECT_TIMEOUT" \
    --max-time "$MERV_REPAIR_MAX_TIME" -o "$_fs_part" "$_fs_url" || {
      rm -f "$_fs_part" 2>/dev/null || :
      return 1
    }
  [ -s "$_fs_part" ] || { rm -f "$_fs_part" 2>/dev/null || :; return 1; }
  mv -f "$_fs_part" "$_fs_dest" 2>/dev/null || {
    rm -f "$_fs_part" 2>/dev/null || :
    return 1
  }
  return 0
}

archive_members_valid() {
  _amv_archive="$1"
  _amv_members="$RUN_DIR/archive.members"
  _amv_verbose="$RUN_DIR/archive.verbose"
  SNAPSHOT_ROOT=""
  rm -f "$_amv_members" "$_amv_verbose" "$SNAPSHOT_RAW" 2>/dev/null || return 1
  if tar -tzf "$_amv_archive" >"$_amv_members" 2>/dev/null &&
     tar -tvzf "$_amv_archive" >"$_amv_verbose" 2>/dev/null; then
    SNAPSHOT_RAW=""
  else
    SNAPSHOT_RAW="$RUN_DIR/snapshot.tar"
    gzip -dc "$_amv_archive" >"$SNAPSHOT_RAW" 2>/dev/null || return 1
    tar -tf "$SNAPSHOT_RAW" >"$_amv_members" 2>/dev/null || return 1
    tar -tvf "$SNAPSHOT_RAW" >"$_amv_verbose" 2>/dev/null || return 1
  fi
  [ -s "$_amv_members" ] || return 1
  : >"$RUN_DIR/archive.seen" || return 1
  _amv_count=0
  while IFS= read -r _amv_member || [ -n "$_amv_member" ]; do
    _amv_normalized="$_amv_member"
    case "$_amv_normalized" in */) _amv_normalized=${_amv_normalized%/} ;; esac
    safe_rel_path "$_amv_normalized" || return 1
    _amv_root=${_amv_normalized%%/*}
    case "$_amv_root" in ''|.|..|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    if [ -z "$SNAPSHOT_ROOT" ]; then SNAPSHOT_ROOT="$_amv_root"; fi
    [ "$SNAPSHOT_ROOT" = "$_amv_root" ] || return 1
    grep -Fqx "$_amv_normalized" "$RUN_DIR/archive.seen" 2>/dev/null && return 1
    printf '%s\n' "$_amv_normalized" >>"$RUN_DIR/archive.seen" || return 1
    _amv_count=$((_amv_count + 1))
    [ "$_amv_count" -le 4096 ] || return 1
  done <"$_amv_members"
  while IFS= read -r _amv_verbose_line || [ -n "$_amv_verbose_line" ]; do
    _amv_type=$(printf '%s' "$_amv_verbose_line" | cut -c1)
    case "$_amv_type" in -|d) ;; *) return 1 ;; esac
    case "$_amv_verbose_line" in *' -> '*|*' link to '*) return 1 ;; esac
  done <"$_amv_verbose"
  [ -n "$SNAPSHOT_ROOT" ] || return 1
  case "$SNAPSHOT_ROOT" in mervlan-[A-Za-z0-9._-]*) return 0 ;; *) return 1 ;; esac
}

repair_path_allowed() {
  case "$1" in
    install.sh|uninstall.sh|changelog.txt|mervlan.asp) return 0 ;;
    www/index.html|www/vlan_index_style.css|www/vlan_form_style.css|www/help.html|www/view_logs.html|www/settings/loading_actions.json) return 0 ;;
    functions/mervlan_boot.sh|functions/mervlan_boot_wrap.sh|functions/mervlan_wan.sh|functions/hw_probe.sh|functions/settings_reconcile.sh|functions/ssh_trust_action.sh) return 0 ;;
    functions/device_support_mapper.sh|functions/heal_event.sh|functions/mervlan_trunk.sh|functions/mervlan_node_runner.sh) return 0 ;;
    functions/update_mervlan.sh|functions/update_mervlan_repair.sh|functions/update_mervlan_repair.manifest|functions/mervlan_backup.sh|functions/mervlan_recover.sh|functions/sync_nodes.sh) return 0 ;;
    functions/service-event-handler.sh|functions/mervlan_manager.sh|functions/execute_nodes.sh|functions/post_apply_worker.sh|functions/collect_clients.sh|functions/collect_local_clients.sh) return 0 ;;
    functions/save_settings.sh|functions/mac_refresh.sh|functions/mac_client_meta.sh|functions/dropbear_sshkey_gen.sh|functions/ssh_hostkey_probe.sh) return 0 ;;
    settings/var_settings.sh|settings/log_settings.sh|settings/lib_identity.sh|settings/lib_owner_lock.sh|settings/lib_action_lock.sh) return 0 ;;
    settings/lib_action_ack.sh|settings/lib_action_progress.sh|settings/lib_action_runtime.sh|settings/lib_maintenance_recovery.sh) return 0 ;;
    settings/lib_br0_guard.sh|settings/lib_debug.sh|settings/lib_radio.sh|settings/lib_ssid_filter.sh|settings/lib_stp.sh) return 0 ;;
    settings/lib_update_state.sh|settings/lib_json.sh|settings/lib_ssh.sh|settings/lib_ssh_trust.sh|settings/lib_mervqt.sh) return 0 ;;
    settings/lib_node_jobs.sh|settings/lib_node_reconcile.sh|settings/lib_settings_reconcile.sh|settings/lib_progress.sh) return 0 ;;
    settings/log_settings.sh|settings/mac_shield_snapshot.sh|settings/var_settings.sh) return 0 ;;
    templates/mervlan_templates.sh) return 0 ;;
    *) return 1 ;;
  esac
}

path_protected() {
  case "$1" in
    settings/settings.json|.ssh|.ssh/*|tmp|tmp/*|flags|flags/*|www/.ssh|www/.ssh/*|www/tmp|www/tmp/*|www/settings/hardware_profiles.json) return 0 ;;
    *) return 1 ;;
  esac
}

parse_manifest() {
  _pm_manifest="$1"
  : >"$PATHS_FILE" || return 1
  _pm_format=0 _pm_cohort=0 _pm_entries=0
  while IFS= read -r _pm_line || [ -n "$_pm_line" ]; do
    [ -n "$_pm_line" ] || continue
    case "$_pm_line" in
      \#*) continue ;;
      format=2) [ "$_pm_format" -eq 0 ] || return 1; _pm_format=1; continue ;;
      cohort=control-plane) [ "$_pm_cohort" -eq 0 ] || return 1; _pm_cohort=1; continue ;;
    esac
    [ "$_pm_format" -eq 1 ] && [ "$_pm_cohort" -eq 1 ] || return 1
    _pm_mode=${_pm_line%% *}; _pm_path=${_pm_line#* }
    [ "$_pm_mode" != "$_pm_line" ] && [ -n "$_pm_path" ] || return 1
    case "$_pm_path" in *' '*|*'	'*) return 1 ;; esac
    case "$_pm_mode" in 0644|0755) ;; *) return 1 ;; esac
    safe_rel_path "$_pm_path" || return 1
    repair_path_allowed "$_pm_path" || return 1
    path_protected "$_pm_path" && return 1
    grep -Fqx "$_pm_path" "$PATHS_FILE" 2>/dev/null && return 1
    printf '%s %s\n' "$_pm_mode" "$_pm_path" >>"$PATHS_FILE" || return 1
    _pm_entries=$((_pm_entries + 1))
    [ "$_pm_entries" -le 256 ] || return 1
  done <"$_pm_manifest"
  [ "$_pm_format" -eq 1 ] && [ "$_pm_cohort" -eq 1 ] && [ "$_pm_entries" -gt 0 ] || return 1
  for _pm_required in install.sh uninstall.sh functions/update_mervlan.sh \
    functions/update_mervlan_repair.sh functions/update_mervlan_repair.manifest \
    functions/mervlan_boot.sh functions/mervlan_wan.sh settings/lib_owner_lock.sh \
    settings/lib_update_state.sh settings/lib_maintenance_recovery.sh
  do
    grep -Fq " $_pm_required" "$PATHS_FILE" || return 1
  done
  grep -Fqx '0755 functions/mervlan_wan.sh' "$PATHS_FILE" || return 1
  grep -Fqx '0644 functions/update_mervlan_repair.manifest' "$PATHS_FILE" || return 1
  return 0
}

mode_matches() {
  _mm_mode="$1" _mm_file="$2"
  _mm_actual=$(ls -l "$_mm_file" 2>/dev/null | awk '{print $1}')
  case "$_mm_mode:$_mm_actual" in
    0755:-rwxr-xr-x|0644:-rw-r--r--) return 0 ;;
    *) return 1 ;;
  esac
}

validate_stage() {
  while IFS=' ' read -r _vs_mode _vs_path; do
    _vs_file="$STAGE_DIR/$_vs_path"
    path_regular "$_vs_file" && [ -s "$_vs_file" ] || return 1
    mode_matches "$_vs_mode" "$_vs_file" || return 1
    case "$_vs_path" in *.sh) sh -n "$_vs_file" >/dev/null 2>&1 || return 1 ;; esac
  done <"$PATHS_FILE"
  [ -x "$STAGE_DIR/functions/mervlan_wan.sh" ] || return 1
  return 0
}

repair_owner_positive_uint() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "$1" in *[1-9]*) return 0 ;; *) return 1 ;; esac
}

repair_owner_nonce_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 160 ]
}

repair_proc_start() {
  _rps_pid="$1" _rps_root="${2:-/proc}"
  repair_owner_positive_uint "$_rps_pid" || return 1
  [ -r "$_rps_root/$_rps_pid/stat" ] || return 1
  _rps_stat=$(cat "$_rps_root/$_rps_pid/stat" 2>/dev/null) || return 1
  _rps_after=${_rps_stat#*)}
  [ "$_rps_after" != "$_rps_stat" ] || return 1
  set -- $_rps_after
  _rps_start=${20:-}
  repair_owner_positive_uint "$_rps_start" || return 1
  printf '%s\n' "$_rps_start"
}

# Classify an existing canonical-owner PID without conflating an unreadable
# process identity with a dead one.  Rescue may reclaim only an authoritatively
# absent PID or a readable, mismatched start identity; a present-but-unreadable
# process is an active ambiguity and remains blocking.
repair_owner_identity_state() {
  _rois_pid="$1" _rois_expected="$2" _rois_root="$MERV_REPAIR_PROC_ROOT"
  repair_owner_positive_uint "$_rois_pid" || return 1
  repair_owner_positive_uint "$_rois_expected" || return 1
  path_chain_safe "$_rois_root" || { printf 'unknown\n'; return 1; }
  [ -d "$_rois_root" ] && [ ! -L "$_rois_root" ] || { printf 'unknown\n'; return 1; }
  if ! path_present "$_rois_root/$_rois_pid"; then
    # Do not treat a failed proc lookup as absence while the kernel still
    # reports that PID alive.  That combination is unobservable, not stale.
    kill -0 "$_rois_pid" 2>/dev/null && { printf 'unknown\n'; return 1; }
    printf 'absent\n'
    return 0
  fi
  [ ! -L "$_rois_root/$_rois_pid" ] && [ -d "$_rois_root/$_rois_pid" ] || {
    printf 'unknown\n'
    return 1
  }
  kill -0 "$_rois_pid" 2>/dev/null || { printf 'unknown\n'; return 1; }
  _rois_actual=$(repair_proc_start "$_rois_pid" "$_rois_root" 2>/dev/null || printf '')
  repair_owner_positive_uint "$_rois_actual" || { printf 'unknown\n'; return 1; }
  if [ "$_rois_actual" = "$_rois_expected" ]; then
    printf 'live\n'
  else
    printf 'reused\n'
  fi
  return 0
}

repair_owner_read() {
  _ror_file="$1"
  REPAIR_OWNER_PID="" REPAIR_OWNER_START="" REPAIR_OWNER_NONCE="" REPAIR_OWNER_CREATED="" REPAIR_OWNER_HEARTBEAT=""
  path_regular "$_ror_file" || return 1
  _ror_size=$(wc -c <"$_ror_file" 2>/dev/null | awk '{print $1}') || return 1
  case "$_ror_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_ror_size" -gt 0 ] && [ "$_ror_size" -le 512 ] || return 1
  LC_ALL=C grep -q '[^ -~]' "$_ror_file" 2>/dev/null && return 1
  _ror_lines=0 _ror_seen=""
  while IFS= read -r _ror_line || [ -n "$_ror_line" ]; do
    _ror_lines=$((_ror_lines + 1))
    case " $_ror_seen " in *" ${_ror_line%%=*} "*) return 1 ;; esac
    case "$_ror_line" in
      pid=*) REPAIR_OWNER_PID=${_ror_line#pid=} ;;
      proc_start_time=*) REPAIR_OWNER_START=${_ror_line#proc_start_time=} ;;
      owner_nonce=*) REPAIR_OWNER_NONCE=${_ror_line#owner_nonce=} ;;
      created=*) REPAIR_OWNER_CREATED=${_ror_line#created=} ;;
      heartbeat=*) REPAIR_OWNER_HEARTBEAT=${_ror_line#heartbeat=} ;;
      *) return 1 ;;
    esac
    _ror_seen="$_ror_seen ${_ror_line%%=*}"
  done <"$_ror_file"
  [ "$_ror_lines" -eq 5 ] || return 1
  repair_owner_positive_uint "$REPAIR_OWNER_PID" &&
    repair_owner_positive_uint "$REPAIR_OWNER_START" &&
    repair_owner_nonce_valid "$REPAIR_OWNER_NONCE" &&
    repair_owner_positive_uint "$REPAIR_OWNER_CREATED" &&
    repair_owner_positive_uint "$REPAIR_OWNER_HEARTBEAT"
}

repair_owner_write() {
  _row_dir="$1" _row_pid="$2" _row_start="$3" _row_nonce="$4" _row_now="$5"
  repair_owner_positive_uint "$_row_pid" && repair_owner_positive_uint "$_row_start" &&
    repair_owner_nonce_valid "$_row_nonce" && repair_owner_positive_uint "$_row_now" || return 1
  _row_tmp="$_row_dir/.owner.tmp.$$.$REPAIR_LEDGER_SEQ.$_row_nonce"
  while path_present "$_row_tmp"; do REPAIR_LEDGER_SEQ=$((REPAIR_LEDGER_SEQ + 1)); _row_tmp="$_row_dir/.owner.tmp.$$.$REPAIR_LEDGER_SEQ.$_row_nonce"; done
  ( umask 077
    printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=%s\nheartbeat=%s\n' \
      "$_row_pid" "$_row_start" "$_row_nonce" "$_row_now" "$_row_now" >"$_row_tmp"
  ) 2>/dev/null || { rm -f "$_row_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_row_tmp" 2>/dev/null || { rm -f "$_row_tmp" 2>/dev/null || :; return 1; }
  repair_owner_read "$_row_tmp" || { rm -f "$_row_tmp" 2>/dev/null || :; return 1; }
  mv -f "$_row_tmp" "$_row_dir/owner" 2>/dev/null || { rm -f "$_row_tmp" 2>/dev/null || :; return 1; }
  return 0
}

repair_owner_matches_tuple() {
  _rom_lock="$1" _rom_pid="$2" _rom_start="$3" _rom_nonce="$4"
  repair_owner_read "$_rom_lock/owner" || return 1
  [ "$REPAIR_OWNER_PID" = "$_rom_pid" ] &&
    [ "$REPAIR_OWNER_START" = "$_rom_start" ] &&
    [ "$REPAIR_OWNER_NONCE" = "$_rom_nonce" ] || return 1
  _rom_actual=$(repair_proc_start "$_rom_pid" 2>/dev/null || printf '')
  [ "$_rom_actual" = "$_rom_start" ] && kill -0 "$_rom_pid" 2>/dev/null
}

# Re-authenticate the owner immediately before every externally visible repair
# publication.  This is intentionally independent of the legacy-process scan:
# a replaced/successor canonical owner must stop repair even when no legacy
# lock is present.
repair_owner_owned_and_current() {
  [ "$REPAIR_LOCK_OWNED" = 1 ] || return 1
  repair_lock_path_valid || return 1
  _rooc_lock="$MERV_REPAIR_MAINTENANCE_LOCK"
  path_present "$_rooc_lock" || return 1
  [ ! -L "$_rooc_lock" ] && [ -d "$_rooc_lock" ] || return 1
  repair_owner_read "$_rooc_lock/owner" || return 1
  [ "$REPAIR_OWNER_PID" = "$$" ] &&
    [ "$REPAIR_OWNER_START" = "$REPAIR_LOCK_START" ] &&
    [ "$REPAIR_OWNER_NONCE" = "$REPAIR_LOCK_NONCE" ] &&
    [ "$REPAIR_OWNER_CREATED" = "$REPAIR_LOCK_CREATED" ] &&
    [ "$REPAIR_OWNER_HEARTBEAT" = "$REPAIR_LOCK_CREATED" ] || return 1
  _rooc_actual=$(repair_proc_start "$$" 2>/dev/null || printf '')
  [ "$_rooc_actual" = "$REPAIR_LOCK_START" ] || return 1
  kill -0 "$$" 2>/dev/null
}

repair_action_parent_valid() {
  [ "${MERV_ACTION_LOCK_PARENT_HELD:-0}" = 1 ] || return 1
  repair_owner_positive_uint "${MERV_ACTION_LOCK_PARENT_PID:-}" || return 1
  repair_owner_positive_uint "${MERV_ACTION_LOCK_PARENT_START:-}" || return 1
  repair_owner_nonce_valid "${MERV_ACTION_LOCK_PARENT_NONCE:-}" || return 1
  _rap_lock="${MERV_ACTION_LOCK_PATH:-${MERV_REPAIR_LEGACY_LOCK_ROOT%/}/mervlan_action.lock}"
  path_chain_safe "$_rap_lock" || return 1
  repair_owner_matches_tuple "$_rap_lock" "$MERV_ACTION_LOCK_PARENT_PID" \
    "$MERV_ACTION_LOCK_PARENT_START" "$MERV_ACTION_LOCK_PARENT_NONCE"
}

# WebUI repair terminal success is normally published by this standalone
# worker.  A supervising dispatcher may take that final publication over, but
# only with an explicit capability and its still-authenticated global owner.
# The parent-held marker alone is deliberately insufficient: older dispatchers
# do not know to complete a deferred progress record after releasing locks.
repair_webui_terminal_deferred() {
  [ "${MERV_REPAIR_DEFER_WEBUI_TERMINAL:-}" = v1 ] || return 1
  token_valid "$REPAIR_PROGRESS_TOKEN" || return 1
  repair_action_parent_valid
}

# The old .15 dispatcher used per-event `.lock` directories with pid/created
# metadata and no canonical maintenance owner.  Repair never deletes those
# objects.  Repair also scans only the exact historical mutator entrypoints
# whose command lines can race repair publication; this closes the direct-SSH
# updater/installer gap without turning rescue into a broad process search.
#
# Bounded v0.53.15 direct-mutator review:
# - save_settings.sh and hw_probe.sh rewrite protected settings/settings.json;
# - dropbear_sshkey_gen.sh regenerates protected .ssh key material; and
# - mervlan_boot_wrap.sh can launch install.sh or mervlan_manager.sh.
# They are therefore included.  Other executables were not added merely for
# being executable: this list is limited to directly invokable lifecycle,
# runtime, repair-destination, or protected-data writers.
repair_legacy_process_target() {
  case "$1" in
    "$MERV_BASE/functions/update_mervlan.sh"|\
    "$MERV_BASE/install.sh"|\
    "$MERV_BASE/uninstall.sh"|\
    "$MERV_BASE/functions/mervlan_manager.sh"|\
    "$MERV_BASE/functions/sync_nodes.sh"|\
    "$MERV_BASE/functions/execute_nodes.sh"|\
    "$MERV_BASE/functions/service-event-handler.sh"|\
    "$MERV_BASE/functions/mervlan_boot.sh"|\
    "$MERV_BASE/functions/mervlan_boot_wrap.sh"|\
    "$MERV_BASE/functions/heal_event.sh"|\
    "$MERV_BASE/functions/save_settings.sh"|\
    "$MERV_BASE/functions/hw_probe.sh"|\
    "$MERV_BASE/functions/dropbear_sshkey_gen.sh") return 0 ;;
    *) return 1 ;;
  esac
}

repair_legacy_relative_script_candidate() {
  _rlrsc_arg="${1:-}"
  case "$_rlrsc_arg" in ''|/*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  _rlrsc_base=${_rlrsc_arg##*/}
  case "$_rlrsc_base" in
    update_mervlan.sh|install.sh|uninstall.sh|mervlan_manager.sh|sync_nodes.sh|\
    execute_nodes.sh|service-event-handler.sh|mervlan_boot.sh|\
    mervlan_boot_wrap.sh|heal_event.sh|save_settings.sh|hw_probe.sh|\
    dropbear_sshkey_gen.sh) return 0 ;;
    *) return 1 ;;
  esac
}

repair_relative_script_normalize() {
  _rrsn_rest="${1:-}" _rrsn_out="" _rrsn_component=""
  case "$_rrsn_rest" in ''|/*|*..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  while [ -n "$_rrsn_rest" ]; do
    case "$_rrsn_rest" in
      */*) _rrsn_component=${_rrsn_rest%%/*}; _rrsn_rest=${_rrsn_rest#*/} ;;
      *) _rrsn_component=$_rrsn_rest; _rrsn_rest='' ;;
    esac
    case "$_rrsn_component" in
      ''|.) : ;;
      ..) return 1 ;;
      *[!A-Za-z0-9_.-]*) return 1 ;;
      *)
        if [ -n "$_rrsn_out" ]; then
          _rrsn_out="$_rrsn_out/$_rrsn_component"
        else
          _rrsn_out=$_rrsn_component
        fi
        ;;
    esac
  done
  [ -n "$_rrsn_out" ] || return 1
  printf '%s\n' "$_rrsn_out"
}

repair_proc_cwd() {
  _rpc_pid="$1" _rpc_root="$MERV_REPAIR_PROC_ROOT" _rpc_cwd=""
  repair_owner_positive_uint "$_rpc_pid" || return 1
  [ -L "$_rpc_root/$_rpc_pid/cwd" ] || return 1
  type readlink >/dev/null 2>&1 || return 1
  _rpc_cwd=$(readlink "$_rpc_root/$_rpc_pid/cwd" 2>/dev/null || printf '')
  case "$_rpc_cwd" in ''|/*) : ;; *) return 1 ;; esac
  _rpc_cwd=${_rpc_cwd%/}
  [ -n "$_rpc_cwd" ] || _rpc_cwd=/
  path_chain_safe "$_rpc_cwd" && [ -d "$_rpc_cwd" ] && [ ! -L "$_rpc_cwd" ] || return 1
  printf '%s\n' "$_rpc_cwd"
}

repair_legacy_relative_target() {
  _rlrt_pid="$1" _rlrt_arg="$2"
  repair_legacy_relative_script_candidate "$_rlrt_arg" || return 1
  _rlrt_cwd=$(repair_proc_cwd "$_rlrt_pid" 2>/dev/null || printf '')
  [ -n "$_rlrt_cwd" ] || return 2
  _rlrt_rel=$(repair_relative_script_normalize "$_rlrt_arg" 2>/dev/null || printf '')
  [ -n "$_rlrt_rel" ] || return 2
  _rlrt_target="$_rlrt_cwd/$_rlrt_rel"
  repair_legacy_process_target "$_rlrt_target"
}

repair_legacy_process_scan() {
  _rlps_root="$MERV_REPAIR_PROC_ROOT"
  path_chain_safe "$_rlps_root" || return 2
  [ -d "$_rlps_root" ] && [ ! -L "$_rlps_root" ] &&
    [ -r "$_rlps_root" ] && [ -x "$_rlps_root" ] || return 2
  for _rlps_pid_dir in "$_rlps_root"/[0-9]*; do
    path_present "$_rlps_pid_dir" || continue
    [ ! -L "$_rlps_pid_dir" ] && [ -d "$_rlps_pid_dir" ] || return 2
    _rlps_pid=${_rlps_pid_dir##*/}
    repair_owner_positive_uint "$_rlps_pid" || return 2
    _rlps_cmdline="$_rlps_pid_dir/cmdline"
    path_regular "$_rlps_cmdline" && [ -r "$_rlps_cmdline" ] || return 2
    _rlps_cmdline_text=$(LC_ALL=C tr '\000' '\n' <"$_rlps_cmdline" 2>/dev/null) || return 2
    [ -n "$_rlps_cmdline_text" ] || continue
    _rlps_match=0
    for _rlps_arg in \
      "$MERV_BASE/functions/update_mervlan.sh" \
      "$MERV_BASE/install.sh" \
      "$MERV_BASE/uninstall.sh" \
      "$MERV_BASE/functions/mervlan_manager.sh" \
      "$MERV_BASE/functions/sync_nodes.sh" \
      "$MERV_BASE/functions/execute_nodes.sh" \
      "$MERV_BASE/functions/service-event-handler.sh" \
      "$MERV_BASE/functions/mervlan_boot.sh" \
      "$MERV_BASE/functions/mervlan_boot_wrap.sh" \
      "$MERV_BASE/functions/heal_event.sh" \
      "$MERV_BASE/functions/save_settings.sh" \
      "$MERV_BASE/functions/hw_probe.sh" \
      "$MERV_BASE/functions/dropbear_sshkey_gen.sh"
    do
      printf '%s\n' "$_rlps_cmdline_text" | grep -Fqx "$_rlps_arg" 2>/dev/null && {
        _rlps_match=1
        break
      }
    done
    if [ "$_rlps_match" = 0 ]; then
      while IFS= read -r _rlps_cmd_arg || [ -n "$_rlps_cmd_arg" ]; do
        repair_legacy_relative_target "$_rlps_pid" "$_rlps_cmd_arg"
        _rlps_relative_rc=$?
        case "$_rlps_relative_rc" in
          0) _rlps_match=1; break ;;
          1) : ;;
          *) return 2 ;;
        esac
      done <<EOF
$_rlps_cmdline_text
EOF
    fi
    [ "$_rlps_match" = 1 ] || continue
    # A matching command line is a candidate.  It must have a readable,
    # identity-verifiable process record and still be alive; otherwise rescue
    # cannot distinguish a live mutator from a reused/unobservable PID.
    _rlps_start=$(repair_proc_start "$_rlps_pid" "$_rlps_root" 2>/dev/null || printf '')
    [ -n "$_rlps_start" ] || return 2
    kill -0 "$_rlps_pid" 2>/dev/null || continue
    return 1
  done
  return 0
}

repair_legacy_exclusion_check() {
  _rle_root="$MERV_REPAIR_LEGACY_LOCK_ROOT"
  path_chain_safe "$_rle_root" || return 2
  path_present "$MERV_REPAIR_PROC_ROOT" && [ -d "$MERV_REPAIR_PROC_ROOT" ] &&
    [ -r "$MERV_REPAIR_PROC_ROOT" ] || return 2
  repair_legacy_process_scan || {
    _rle_process_rc=$?
    [ "$_rle_process_rc" -eq 1 ] && return 1
    return 2
  }
  for _rle_lock in "$_rle_root"/*.lock; do
    path_present "$_rle_lock" || continue
    [ "$_rle_lock" != "$MERV_REPAIR_MAINTENANCE_LOCK" ] || continue
    _rle_base=${_rle_lock##*/}
    case "$_rle_base" in
      mervlan_action.lock)
        repair_action_parent_valid || return 2
        continue
        ;;
      *.lock) : ;;
      *) return 2 ;;
    esac
    [ ! -L "$_rle_lock" ] && [ -d "$_rle_lock" ] || return 2
    path_regular "$_rle_lock/pid" || return 2
    _rle_pid=$(sed -n '1p' "$_rle_lock/pid" 2>/dev/null)
    repair_owner_positive_uint "$_rle_pid" || return 2
    if path_present "$MERV_REPAIR_PROC_ROOT/$_rle_pid"; then
      _rle_start=$(repair_proc_start "$_rle_pid" "$MERV_REPAIR_PROC_ROOT" 2>/dev/null || printf '')
      [ -n "$_rle_start" ] || return 2
      kill -0 "$_rle_pid" 2>/dev/null && return 1
    fi
    # A missing /proc/<pid> proves that this legacy process is gone; the lock
    # remains untouched and is left for the old runtime's own cleanup. An
    # existing but unreadable process record is unverifiable and blocks.
  done
  return 0
}

repair_lock_path_valid() {
  case "$MERV_REPAIR_MAINTENANCE_LOCK" in
    ''|*..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;;
    /*) : ;;
    *) return 1 ;;
  esac
  path_chain_safe "${MERV_REPAIR_MAINTENANCE_LOCK%/*}"
}

repair_lock_release() {
  [ "$REPAIR_LOCK_OWNED" = 1 ] || return 0
  _rlr_lock="$MERV_REPAIR_MAINTENANCE_LOCK"
  # Once this process has claimed the lock, disappearance is a replacement
  # race or external tampering, not an already-successful release.
  path_present "$_rlr_lock" || return 1
  [ ! -L "$_rlr_lock" ] && [ -d "$_rlr_lock" ] || return 1
  repair_owner_read "$_rlr_lock/owner" || return 1
  [ "$REPAIR_OWNER_PID" = "$$" ] &&
    [ "$REPAIR_OWNER_START" = "$REPAIR_LOCK_START" ] &&
    [ "$REPAIR_OWNER_NONCE" = "$REPAIR_LOCK_NONCE" ] || return 1
  [ "$REPAIR_OWNER_CREATED" = "$REPAIR_LOCK_CREATED" ] || return 1
  [ "$REPAIR_OWNER_HEARTBEAT" = "$REPAIR_LOCK_CREATED" ] || return 1
  _rlr_restore="${_rlr_lock}.owner.restore.$$.$REPAIR_LEDGER_SEQ"
  cp -p "$_rlr_lock/owner" "$_rlr_restore" 2>/dev/null || return 1
  repair_owner_read "$_rlr_restore" || { rm -f "$_rlr_restore" 2>/dev/null || :; return 1; }
  # Re-read the authoritative record immediately before unlinking it.  A
  # successor may have replaced the owner between the initial check and this
  # point; in that case preserve the successor and its evidence.
  path_present "$_rlr_lock/owner" || { rm -f "$_rlr_restore" 2>/dev/null || :; return 1; }
  repair_owner_read "$_rlr_lock/owner" || { rm -f "$_rlr_restore" 2>/dev/null || :; return 1; }
  [ "$REPAIR_OWNER_PID" = "$$" ] &&
    [ "$REPAIR_OWNER_START" = "$REPAIR_LOCK_START" ] &&
    [ "$REPAIR_OWNER_NONCE" = "$REPAIR_LOCK_NONCE" ] &&
    [ "$REPAIR_OWNER_CREATED" = "$REPAIR_LOCK_CREATED" ] &&
    [ "$REPAIR_OWNER_HEARTBEAT" = "$REPAIR_LOCK_CREATED" ] || {
      rm -f "$_rlr_restore" 2>/dev/null || :
      return 1
    }
  for _rlr_sidecar in heartbeat state; do
    if path_present "$_rlr_lock/$_rlr_sidecar"; then
      [ ! -L "$_rlr_lock/$_rlr_sidecar" ] && [ -f "$_rlr_lock/$_rlr_sidecar" ] || {
        rm -f "$_rlr_restore" 2>/dev/null || :
        return 1
      }
    fi
  done
  rm -f "$_rlr_lock/owner" 2>/dev/null || { rm -f "$_rlr_restore" 2>/dev/null || :; return 1; }
  if ! rmdir "$_rlr_lock" 2>/dev/null; then
    if path_present "$_rlr_lock" && [ ! -L "$_rlr_lock" ] && [ -d "$_rlr_lock" ] &&
       ! path_present "$_rlr_lock/owner"; then
      mv -f "$_rlr_restore" "$_rlr_lock/owner" 2>/dev/null || return 1
    else
      return 1
    fi
    return 1
  fi
  rm -f "$_rlr_restore" 2>/dev/null || :
  REPAIR_LOCK_OWNED=0
  return 0
}

repair_admit() {
  repair_lock_path_valid || { log 'Maintenance lock path is unsafe or unverifiable.'; return 1; }
  repair_legacy_exclusion_check || {
    _rac_rc=$?
    [ "$_rac_rc" -eq 1 ] && log 'A legacy MerVLAN mutator is live; repair is blocked.'
    [ "$_rac_rc" -ne 1 ] && log 'Legacy MerVLAN lock state is unknown; repair is blocked.'
    return 1
  }
  if path_present "$MERV_REPAIR_MAINTENANCE_LOCK"; then
    [ ! -L "$MERV_REPAIR_MAINTENANCE_LOCK" ] && [ -d "$MERV_REPAIR_MAINTENANCE_LOCK" ] || return 1
    repair_owner_read "$MERV_REPAIR_MAINTENANCE_LOCK/owner" || return 1
    _rac_owner_state=$(repair_owner_identity_state "$REPAIR_OWNER_PID" "$REPAIR_OWNER_START" 2>/dev/null || printf 'unknown')
    case "$_rac_owner_state" in
      live)
        log 'Another authenticated maintenance owner is live; repair is blocked.'
        return 1
        ;;
      absent|reused) : ;;
      *)
        log 'Canonical maintenance owner identity is unobservable; repair is blocked.'
        return 1
        ;;
    esac
    _rac_old_pid="$REPAIR_OWNER_PID"
    _rac_old_start="$REPAIR_OWNER_START"
    _rac_old_nonce="$REPAIR_OWNER_NONCE"
    _rac_old_created="$REPAIR_OWNER_CREATED"
    _rac_old_heartbeat="$REPAIR_OWNER_HEARTBEAT"
    # A dead/reused owner is retained for inspection and moved only after the
    # complete record is re-read.  Never unlink a foreign stale lock in rescue.
    _rac_quarantine="${MERV_REPAIR_MAINTENANCE_LOCK}.repair-stale.$$.$REPAIR_LEDGER_SEQ"
    path_present "$_rac_quarantine" && return 1
    path_present "$MERV_REPAIR_MAINTENANCE_LOCK/owner" || return 1
    repair_owner_read "$MERV_REPAIR_MAINTENANCE_LOCK/owner" || return 1
    [ "$REPAIR_OWNER_PID" = "$_rac_old_pid" ] &&
      [ "$REPAIR_OWNER_START" = "$_rac_old_start" ] &&
      [ "$REPAIR_OWNER_NONCE" = "$_rac_old_nonce" ] &&
      [ "$REPAIR_OWNER_CREATED" = "$_rac_old_created" ] &&
      [ "$REPAIR_OWNER_HEARTBEAT" = "$_rac_old_heartbeat" ] || return 1
    mv "${MERV_REPAIR_MAINTENANCE_LOCK}" "$_rac_quarantine" 2>/dev/null || return 1
  fi
  _rac_parent=${MERV_REPAIR_MAINTENANCE_LOCK%/*}
  mkdir_chain_safe "$_rac_parent" || return 1
  if ! mkdir "$MERV_REPAIR_MAINTENANCE_LOCK" 2>/dev/null; then return 1; fi
  REPAIR_LOCK_START=$(repair_proc_start "$$" 2>/dev/null || printf '')
  if ! repair_owner_positive_uint "$REPAIR_LOCK_START"; then
    if path_present "$MERV_REPAIR_MAINTENANCE_LOCK" &&
       [ ! -L "$MERV_REPAIR_MAINTENANCE_LOCK" ] &&
       [ -d "$MERV_REPAIR_MAINTENANCE_LOCK" ] &&
       ! path_present "$MERV_REPAIR_MAINTENANCE_LOCK/owner"; then
      rmdir "$MERV_REPAIR_MAINTENANCE_LOCK" 2>/dev/null || :
    fi
    return 1
  fi
  REPAIR_LOCK_NONCE="repair.$$.${REPAIR_LEDGER_SEQ}"
  REPAIR_LOCK_CREATED=$(date +%s 2>/dev/null || printf '0')
  if ! repair_owner_positive_uint "$REPAIR_LOCK_CREATED" ||
     ! repair_owner_write "$MERV_REPAIR_MAINTENANCE_LOCK" "$$" "$REPAIR_LOCK_START" \
       "$REPAIR_LOCK_NONCE" "$REPAIR_LOCK_CREATED"; then
    if path_present "$MERV_REPAIR_MAINTENANCE_LOCK" &&
       [ ! -L "$MERV_REPAIR_MAINTENANCE_LOCK" ] &&
       [ -d "$MERV_REPAIR_MAINTENANCE_LOCK" ] &&
       ! path_present "$MERV_REPAIR_MAINTENANCE_LOCK/owner"; then
      rmdir "$MERV_REPAIR_MAINTENANCE_LOCK" 2>/dev/null || :
    fi
    return 1
  fi
  REPAIR_LOCK_OWNED=1
  repair_legacy_exclusion_check || { repair_lock_release || :; return 1; }
  return 0
}

snapshot_protected_files() {
  for _spf_rel in settings/settings.json .ssh/vlan_manager .ssh/vlan_manager.pub \
    tmp/mac_shield.db tmp/mac_shield_override.db tmp/client_name_override.db \
    flags/.install_ok www/settings/hardware_profiles.json
  do
    _spf_src="$MERV_BASE/$_spf_rel" _spf_dst="$PROTECTED_DIR/$_spf_rel"
    if path_present "$_spf_src"; then
      path_regular "$_spf_src" || return 1
      mkdir_chain_safe "${_spf_dst%/*}" || return 1
      cp -p "$_spf_src" "$_spf_dst" 2>/dev/null || return 1
      printf 'present %s\n' "$_spf_rel" >>"$PROTECTED_DIR/index" || return 1
    else
      printf 'absent %s\n' "$_spf_rel" >>"$PROTECTED_DIR/index" || return 1
    fi
  done
  return 0
}

verify_protected_files() {
  while IFS=' ' read -r _vpf_state _vpf_rel; do
    _vpf_src="$MERV_BASE/$_vpf_rel" _vpf_saved="$PROTECTED_DIR/$_vpf_rel"
    case "$_vpf_state" in
      present) path_regular "$_vpf_src" && cmp -s "$_vpf_saved" "$_vpf_src" || return 1 ;;
      absent) path_present "$_vpf_src" && return 1 ;;
      *) return 1 ;;
    esac
  done <"$PROTECTED_DIR/index"
  return 0
}

ledger_append() {
  _la_record="$1"
  [ "${MERV_REPAIR_TEST_FAIL_LEDGER:-}" != before ] || return 1
  REPAIR_LEDGER_SEQ=$((REPAIR_LEDGER_SEQ + 1))
  _la_tmp="$LEDGER_FILE.tmp.$$.$REPAIR_LEDGER_SEQ"
  ( umask 077
    [ ! -f "$LEDGER_FILE" ] || cat "$LEDGER_FILE"
    printf '%s\n' "$_la_record"
  ) >"$_la_tmp" 2>/dev/null || { rm -f "$_la_tmp" 2>/dev/null || :; return 1; }
  chmod 600 "$_la_tmp" 2>/dev/null || { rm -f "$_la_tmp" 2>/dev/null || :; return 1; }
  mv -f "$_la_tmp" "$LEDGER_FILE" 2>/dev/null || { rm -f "$_la_tmp" 2>/dev/null || :; return 1; }
  return 0
}

ledger_mark_published() {
  _lmp_path="$1"
  REPAIR_LEDGER_SEQ=$((REPAIR_LEDGER_SEQ + 1))
  _lmp_tmp="$LEDGER_FILE.tmp.$$.$REPAIR_LEDGER_SEQ"
  awk -F '|' -v target="$_lmp_path" 'BEGIN{OFS="|"} {if($1=="pending" && $3==target)$1="published"; print}' \
    "$LEDGER_FILE" >"$_lmp_tmp" 2>/dev/null || { rm -f "$_lmp_tmp" 2>/dev/null || :; return 1; }
  mv -f "$_lmp_tmp" "$LEDGER_FILE" 2>/dev/null || { rm -f "$_lmp_tmp" 2>/dev/null || :; return 1; }
  return 0
}

rollback_transaction() {
  [ -f "$LEDGER_FILE" ] || return 0
  _rt_reverse="$RUN_DIR/ledger.reverse"
  sed '1!G;h;$!d' "$LEDGER_FILE" >"$_rt_reverse" 2>/dev/null || return 1
  _rt_failed=0
  while IFS='|' read -r _rt_state _rt_mode _rt_rel _rt_kind _rt_backup _rt_source; do
    [ -n "$_rt_rel" ] || continue
    _rt_dest="$MERV_BASE/$_rt_rel"
    _rt_tmp="$_rt_dest.repair-rollback.$$.$REPAIR_LEDGER_SEQ"
    if [ "$_rt_state" = pending ] &&
       ! { path_regular "$_rt_dest" && cmp -s "$_rt_source" "$_rt_dest"; }; then
      # A pending record can legitimately describe a destination whose backup
      # was captured but whose publication never started. Treat that exact
      # unchanged pre-image as already rolled back; anything else is a
      # successor/obstruction and must remain a recovery failure.
      case "$_rt_kind" in
        old) path_regular "$_rt_dest" && path_regular "$_rt_backup" &&
              cmp -s "$_rt_backup" "$_rt_dest" || _rt_failed=1 ;;
        new) path_present "$_rt_dest" && _rt_failed=1 ;;
        *) _rt_failed=1 ;;
      esac
      continue
    fi
    if [ "$_rt_state" != pending ] && [ "$_rt_state" != published ]; then
      _rt_failed=1
      continue
    fi
    if ! path_regular "$_rt_dest" || ! cmp -s "$_rt_source" "$_rt_dest"; then
      _rt_failed=1
      continue
    fi
    case "$_rt_kind" in
      old)
        path_regular "$_rt_backup" || { _rt_failed=1; continue; }
        cp -p "$_rt_backup" "$_rt_tmp" 2>/dev/null && chmod "$_rt_mode" "$_rt_tmp" 2>/dev/null &&
          mv -f "$_rt_tmp" "$_rt_dest" 2>/dev/null || _rt_failed=1
        path_regular "$_rt_dest" && cmp -s "$_rt_backup" "$_rt_dest" || _rt_failed=1
        ;;
      new)
        rm -f "$_rt_dest" 2>/dev/null || _rt_failed=1
        path_present "$_rt_dest" && _rt_failed=1
        ;;
      *) _rt_failed=1 ;;
    esac
    rm -f "$_rt_tmp" 2>/dev/null || :
  done <"$_rt_reverse"
  [ "$_rt_failed" -eq 0 ] || { REPAIR_ROLLBACK_FAILED=1; return 1; }
  return 0
}

repair_publish_temp_cleanup() {
  [ -n "$REPAIR_PUBLISH_TMP" ] || return 0
  if path_present "$REPAIR_PUBLISH_TMP"; then
    path_regular "$REPAIR_PUBLISH_TMP" &&
      cmp -s "$REPAIR_PUBLISH_SOURCE" "$REPAIR_PUBLISH_TMP" || return 1
    rm -f "$REPAIR_PUBLISH_TMP" 2>/dev/null || return 1
    path_present "$REPAIR_PUBLISH_TMP" && return 1
  fi
  REPAIR_PUBLISH_TMP=""
  REPAIR_PUBLISH_SOURCE=""
  return 0
}

publish() {
  REPAIR_PUBLISH_TMP=""
  REPAIR_PUBLISH_SOURCE=""
  : >"$LEDGER_FILE" || return 1
  while IFS=' ' read -r _pub_mode _pub_rel; do
    _pub_source="$STAGE_DIR/$_pub_rel"
    _pub_dest="$MERV_BASE/$_pub_rel"
    _pub_parent=${_pub_dest%/*}
    path_chain_safe "$_pub_parent" || return 1
    mkdir_chain_safe "$_pub_parent" || return 1
    _pub_kind=new _pub_backup=none
    if path_present "$_pub_dest"; then
      path_regular "$_pub_dest" || return 1
      _pub_kind=old
      _pub_backup="$BACKUP_DIR/$_pub_rel"
      mkdir_chain_safe "${_pub_backup%/*}" || return 1
    fi
    # The ledger is the first durable mutation record for this destination.
    # It is written before backup copy, temp publication, or destination mv.
    ledger_append "pending|$_pub_mode|$_pub_rel|$_pub_kind|$_pub_backup|$_pub_source" || return 1
    if [ "$_pub_kind" = old ]; then
      cp -p "$_pub_dest" "$_pub_backup" 2>/dev/null || return 1
      path_regular "$_pub_backup" || return 1
    fi
    _pub_tmp="$_pub_dest.repair.$$.$REPAIR_LEDGER_SEQ"
    path_present "$_pub_tmp" && return 1
    REPAIR_PUBLISH_TMP="$_pub_tmp"
    REPAIR_PUBLISH_SOURCE="$_pub_source"
    cp -p "$_pub_source" "$_pub_tmp" 2>/dev/null || return 1
    chmod "$_pub_mode" "$_pub_tmp" 2>/dev/null || return 1
    if ! repair_owner_owned_and_current; then
      REPAIR_OWNER_LOST=1
      return 1
    fi
    repair_legacy_exclusion_check || return 1
    [ "${MERV_REPAIR_TEST_FAIL_PATH:-}" != "$_pub_rel" ] || return 1
    mv -f "$_pub_tmp" "$_pub_dest" 2>/dev/null || return 1
    REPAIR_PUBLISH_TMP=""
    REPAIR_PUBLISH_SOURCE=""
    path_regular "$_pub_dest" && cmp -s "$_pub_source" "$_pub_dest" || return 1
    ledger_mark_published "$_pub_rel" || return 1
  done <"$PATHS_FILE"
  return 0
}

post_publish_verify() {
  if ! repair_owner_owned_and_current; then
    REPAIR_OWNER_LOST=1
    return 1
  fi
  repair_legacy_exclusion_check || return 1
  while IFS=' ' read -r _ppv_mode _ppv_rel; do
    _ppv_dest="$MERV_BASE/$_ppv_rel" _ppv_source="$STAGE_DIR/$_ppv_rel"
    path_regular "$_ppv_dest" && cmp -s "$_ppv_source" "$_ppv_dest" || return 1
    mode_matches "$_ppv_mode" "$_ppv_dest" || return 1
  done <"$PATHS_FILE"
  verify_protected_files || return 1
  return 0
}

repair_prior_workspace_check() {
  _rpw_root="${MERV_REPAIR_BOOTSTRAP_DIR:-$MERV_REPAIR_TMP_ROOT}"
  path_chain_safe "$_rpw_root" || return 1
  [ -d "$_rpw_root" ] && [ ! -L "$_rpw_root" ] || return 1
  for _rpw_entry in "$_rpw_root"/mervlan_repair.*; do
    path_present "$_rpw_entry" || continue
    if [ ! -L "$_rpw_entry" ] && [ -d "$_rpw_entry" ] &&
       path_regular "$_rpw_entry/.owner" &&
       grep -Fqx 'mervlan-repair-workspace-v2' "$_rpw_entry/.owner" 2>/dev/null; then
      # A retained workspace with no ledger has not reached a destination
      # mutation.  Leave its evidence untouched and allow a fresh, exclusive
      # run.  Any non-empty ledger represents an admitted transaction and is
      # conservatively blocked for explicit recovery inspection.
      if ! path_present "$_rpw_entry/ledger"; then
        continue
      fi
      [ ! -L "$_rpw_entry/ledger" ] && [ -f "$_rpw_entry/ledger" ] || return 1
      [ ! -s "$_rpw_entry/ledger" ] && continue
    fi
    log "A preserved repair workspace is present at $_rpw_entry; inspect it before retrying repair."
    return 1
  done
  return 0
}

prepare_workspace() {
  _pw_root="${MERV_REPAIR_BOOTSTRAP_DIR:-$MERV_REPAIR_TMP_ROOT}"
  path_chain_safe "$_pw_root" || return 1
  [ -d "$_pw_root" ] && [ ! -L "$_pw_root" ] || return 1
  _pw_now=$(date +%s 2>/dev/null || printf '0')
  case "$_pw_now" in ''|*[!0-9]*) _pw_now=0 ;; esac
  _pw_try=0
  while [ "$_pw_try" -lt 16 ]; do
    RUN_DIR="${_pw_root%/}/mervlan_repair.${_pw_now}.$$.$_pw_try"
    if ( umask 077; mkdir "$RUN_DIR" ) 2>/dev/null; then
      printf 'mervlan-repair-workspace-v2\n' >"$RUN_DIR/.owner" || return 1
      chmod 600 "$RUN_DIR/.owner" 2>/dev/null || return 1
      EXTRACT_DIR="$RUN_DIR/extract"
      STAGE_DIR="$RUN_DIR/stage"
      BACKUP_DIR="$RUN_DIR/backup"
      PATHS_FILE="$RUN_DIR/paths"
      LEDGER_FILE="$RUN_DIR/ledger"
      PROTECTED_DIR="$RUN_DIR/protected"
      SNAPSHOT_ARCHIVE="$RUN_DIR/snapshot.tar.gz"
      mkdir "$EXTRACT_DIR" "$STAGE_DIR" "$BACKUP_DIR" "$PROTECTED_DIR" || return 1
      : >"$PROTECTED_DIR/index" || return 1
      return 0
    fi
    _pw_try=$((_pw_try + 1))
  done
  RUN_DIR=""
  return 1
}

extract_snapshot() {
  archive_members_valid "$SNAPSHOT_ARCHIVE" || return 1
  if [ -n "$SNAPSHOT_RAW" ]; then
    tar -xf "$SNAPSHOT_RAW" -C "$EXTRACT_DIR" || return 1
  else
    tar -xzf "$SNAPSHOT_ARCHIVE" -C "$EXTRACT_DIR" || return 1
  fi
  path_regular "$EXTRACT_DIR/$SNAPSHOT_ROOT/functions/update_mervlan_repair.manifest" || return 1
  printf '%s\n' "$EXTRACT_DIR/$SNAPSHOT_ROOT" >"$RUN_DIR/source-root" || return 1
  return 0
}

# The initial raw bootstrap is only a transport.  Once the immutable archive
# has been validated and extracted, the repair engine from that exact snapshot
# takes over before admission or active-tree publication.
repair_handoff_exec() {
  if [ "${MERV_REPAIR_HANDOFF_STATE:-}" = v2 ]; then
    return 0
  fi
    _rhe_engine="$EXTRACT_DIR/$SNAPSHOT_ROOT/functions/update_mervlan_repair.sh"
    path_regular "$_rhe_engine" || return 1
    _rhe_token="handoff.$$.${REPAIR_LEDGER_SEQ}"
    token_valid "$_rhe_token" || return 1
    {
      printf 'format=2\n'
      printf 'token=%s\n' "$_rhe_token"
      printf 'run_dir=%s\n' "$RUN_DIR"
      printf 'source_root=%s\n' "$EXTRACT_DIR/$SNAPSHOT_ROOT"
      printf 'snapshot_root=%s\n' "$SNAPSHOT_ROOT"
      printf 'archive=%s\n' "$SNAPSHOT_ARCHIVE"
      printf 'protected=%s\n' "$PROTECTED_DIR"
    } >"$RUN_DIR/.handoff" 2>/dev/null || return 1
    chmod 600 "$RUN_DIR/.handoff" 2>/dev/null || return 1
    MERV_REPAIR_HANDOFF_STATE=v2 \
    MERV_REPAIR_HANDOFF_TOKEN="$_rhe_token" \
    MERV_REPAIR_HANDOFF_RUN_DIR="$RUN_DIR" \
    MERV_REPAIR_HANDOFF_SOURCE_ROOT="$EXTRACT_DIR/$SNAPSHOT_ROOT" \
    MERV_REPAIR_HANDOFF_SNAPSHOT_ROOT="$SNAPSHOT_ROOT" \
    MERV_REPAIR_HANDOFF_ARCHIVE="$SNAPSHOT_ARCHIVE" \
    MERV_REPAIR_HANDOFF_PROTECTED_DIR="$PROTECTED_DIR" \
    exec /bin/sh "$_rhe_engine" "$REF"
    return $?
}

repair_handoff_adopt() {
  [ "${MERV_REPAIR_HANDOFF_STATE:-}" = v2 ] || return 1
  _rha_run="${MERV_REPAIR_HANDOFF_RUN_DIR:-}"
  _rha_source="${MERV_REPAIR_HANDOFF_SOURCE_ROOT:-}"
  _rha_archive="${MERV_REPAIR_HANDOFF_ARCHIVE:-}"
  _rha_protected="${MERV_REPAIR_HANDOFF_PROTECTED_DIR:-}"
  _rha_token="${MERV_REPAIR_HANDOFF_TOKEN:-}"
  [ -n "$_rha_run" ] && [ -n "$_rha_source" ] && [ -n "$_rha_archive" ] &&
    [ -n "$_rha_protected" ] || return 1
  path_chain_safe "$_rha_run" || return 1
  [ ! -L "$_rha_run" ] && [ -d "$_rha_run" ] || return 1
  _rha_parent=${_rha_run%/*}
  _rha_base=${_rha_run##*/}
  case "$_rha_base" in mervlan_repair.*) ;; *) return 1 ;; esac
  case "$_rha_run" in "$_rha_parent"/mervlan_repair.*) ;; *) return 1 ;; esac
  path_regular "$_rha_run/.owner" || return 1
  grep -Fqx 'mervlan-repair-workspace-v2' "$_rha_run/.owner" 2>/dev/null || return 1
  path_regular "$_rha_run/.handoff" || return 1
  token_valid "$_rha_token" || return 1
  grep -Fqx 'format=2' "$_rha_run/.handoff" 2>/dev/null || return 1
  grep -Fqx "token=$_rha_token" "$_rha_run/.handoff" 2>/dev/null || return 1
  grep -Fqx "run_dir=$_rha_run" "$_rha_run/.handoff" 2>/dev/null || return 1
  grep -Fqx "source_root=$_rha_source" "$_rha_run/.handoff" 2>/dev/null || return 1
  grep -Fqx "archive=$_rha_archive" "$_rha_run/.handoff" 2>/dev/null || return 1
  grep -Fqx "protected=$_rha_protected" "$_rha_run/.handoff" 2>/dev/null || return 1
  case "$_rha_source" in "$_rha_run/extract"/mervlan-*) ;; *) return 1 ;; esac
  case "$_rha_archive" in "$_rha_run/snapshot.tar.gz") ;; *) return 1 ;; esac
  case "$_rha_protected" in "$_rha_run/protected") ;; *) return 1 ;; esac
  path_regular "$_rha_source/functions/update_mervlan_repair.manifest" || return 1
  [ ! -L "$_rha_source" ] && [ -d "$_rha_source" ] || return 1
  path_regular "$_rha_archive" || return 1
  [ ! -L "$_rha_protected" ] && [ -d "$_rha_protected" ] || return 1
  path_regular "$_rha_protected/index" || return 1

  RUN_DIR="$_rha_run"
  EXTRACT_DIR="$_rha_run/extract"
  STAGE_DIR="$_rha_run/stage"
  BACKUP_DIR="$_rha_run/backup"
  PATHS_FILE="$_rha_run/paths"
  LEDGER_FILE="$_rha_run/ledger"
  PROTECTED_DIR="$_rha_protected"
  SNAPSHOT_ARCHIVE="$_rha_archive"
  SNAPSHOT_ROOT="${_rha_source##*/}"
  [ ! -L "$EXTRACT_DIR" ] && [ -d "$EXTRACT_DIR" ] || return 1
  [ ! -L "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ] || return 1
  [ ! -L "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || return 1
  archive_members_valid "$SNAPSHOT_ARCHIVE" || return 1
  [ "$SNAPSHOT_ROOT" = "${MERV_REPAIR_HANDOFF_SNAPSHOT_ROOT:-$SNAPSHOT_ROOT}" ] || return 1
  [ "$EXTRACT_DIR/$SNAPSHOT_ROOT" = "$_rha_source" ] || return 1
  return 0
}

stage_snapshot_payload() {
  _ssp_root="$EXTRACT_DIR/$SNAPSHOT_ROOT"
  _ssp_manifest="$_ssp_root/functions/update_mervlan_repair.manifest"
  parse_manifest "$_ssp_manifest" || return 1
  while IFS=' ' read -r _ssp_mode _ssp_rel; do
    _ssp_source="$_ssp_root/$_ssp_rel" _ssp_dest="$STAGE_DIR/$_ssp_rel"
    path_regular "$_ssp_source" || return 1
    mkdir_chain_safe "${_ssp_dest%/*}" || return 1
    cp -p "$_ssp_source" "$_ssp_dest" 2>/dev/null || return 1
    chmod "$_ssp_mode" "$_ssp_dest" 2>/dev/null || return 1
  done <"$PATHS_FILE"
  return 0
}

repair_exit_handler() {
  _reh_status=$?
  trap - EXIT HUP INT TERM
  if [ "$REPAIR_SUCCESS" = 1 ] && [ "$REPAIR_ROLLBACK_FAILED" = 0 ] && [ "$REPAIR_LOCK_OWNED" = 0 ]; then
    case "${RUN_DIR:-}" in
      "${MERV_REPAIR_BOOTSTRAP_DIR:-$MERV_REPAIR_TMP_ROOT}"/mervlan_repair.*) rm -rf "$RUN_DIR" 2>/dev/null || : ;;
    esac
  elif [ -n "${RUN_DIR:-}" ]; then
    log "Repair evidence retained at $RUN_DIR"
  fi
  exit "$_reh_status"
}

repair_signal_handler() {
  _rsh_status="$1"
  REPAIR_INTERRUPTED=1
  trap - HUP INT TERM
  if [ "$REPAIR_LOCK_OWNED" = 1 ] && [ -f "$LEDGER_FILE" ]; then
    rollback_transaction || :
  fi
  repair_lock_release || :
  exit "$_rsh_status"
}

main() {
  valid_ref "${1:-main}" || { log 'Invalid branch; use main, dev, or a safe custom branch name.'; return 2; }
  case "$MERV_BASE" in ''|/|/tmp|/jffs|/jffs/addons|*..*|*//*|*[!A-Za-z0-9_./-]*) log 'Unsafe MERV_BASE refused.'; return 2 ;; esac
  path_chain_safe "$MERV_BASE" && [ -d "$MERV_BASE" ] && [ ! -L "$MERV_BASE" ] || { log 'MERV_BASE is missing or unsafe.'; return 2; }
  if [ "${MERV_REPAIR_HANDOFF_STATE:-}" != v2 ]; then
    find_curl || { log 'curl is unavailable.'; return 2; }
    repair_prior_workspace_check || { log 'A prior repair workspace blocks automatic rerun; inspect the retained evidence first.'; return 1; }
    prepare_workspace || { log 'Could not allocate an exclusive repair workspace.'; return 1; }
  else
    repair_handoff_adopt || { log 'The same-snapshot repair handoff is invalid; evidence was retained.'; return 1; }
  fi
  REPAIR_PROGRESS_ACTION=repairmain_vlanmgr
  [ "$REF" = dev ] && REPAIR_PROGRESS_ACTION=repairdev_vlanmgr
  if [ "${MERV_REPAIR_HANDOFF_STATE:-}" != v2 ]; then
    progress starting prepare 1 'Preparing emergency repair'
    snapshot_protected_files || { progress failed failed 0 'Protected-data snapshot failed'; return 1; }
    progress running snapshot 10 'Downloading one immutable repair snapshot'
    fetch_snapshot "$SNAPSHOT_ARCHIVE" || { progress failed failed 0 'Repair snapshot download failed'; return 1; }
    extract_snapshot || { progress failed failed 0 'Repair snapshot archive validation failed'; return 1; }
    repair_handoff_exec || { progress failed failed 0 'Same-snapshot repair-engine handoff failed'; return 1; }
  fi
  repair_admit || { progress failed failed 0 'Maintenance admission failed'; return 1; }
  progress running manifest 30 'Validating the snapshot manifest'
  stage_snapshot_payload || { progress failed failed 0 'Repair manifest or dependency closure failed'; return 1; }
  progress running validate 70 'Validating the complete repair cohort'
  validate_stage || { progress failed failed 0 'Staged repair validation failed'; return 1; }
  progress running publish 88 'Publishing the admitted repair transaction'
  REPAIR_OWNER_LOST=0
  if ! publish; then
    repair_publish_temp_cleanup || log 'Repair publication temporary successor could not be safely removed; do not remove the retained evidence.'
    if [ "$REPAIR_OWNER_LOST" = 0 ]; then
      rollback_transaction || log 'Repair rollback was incomplete; do not remove the retained evidence.'
    else
      log 'Canonical maintenance owner changed during repair publication; preserving the successor and retained evidence.'
    fi
    repair_lock_release || :
    progress failed failed 0 'Repair publication failed; evidence was retained'
    return 1
  fi
  if ! post_publish_verify; then
    if [ "$REPAIR_OWNER_LOST" = 0 ]; then
      rollback_transaction || log 'Post-publication rollback was incomplete; do not remove the retained evidence.'
    else
      log 'Canonical maintenance owner changed before post-publication rollback; preserving the successor and retained evidence.'
    fi
    repair_lock_release || :
    progress failed failed 0 'Post-publication verification failed; evidence was retained'
    return 1
  fi
  repair_owner_owned_and_current || {
    log 'Canonical maintenance owner changed before repair finalization; evidence was retained.'
    progress failed failed 0 'Maintenance owner changed before repair finalization; evidence was retained'
    return 1
  }
  if ! repair_lock_release; then
    progress failed failed 0 'Maintenance owner release failed; evidence was retained'
    return 1
  fi
  REPAIR_SUCCESS=1
  if repair_webui_terminal_deferred; then
    progress running dispatcher-finalize 99 'Repair completed; finalizing WebUI action ownership'
    log 'Repair completed; dispatcher will finalize WebUI action ownership.'
  else
    progress complete complete 100 'Emergency repair completed'
  fi
  log "MerVLAN update components repaired successfully from branch: $REF"
  log 'No update was started.'
  return 0
}

trap repair_exit_handler EXIT
trap 'repair_signal_handler 129' HUP
trap 'repair_signal_handler 130' INT
trap 'repair_signal_handler 143' TERM

main "$@"
exit $?
