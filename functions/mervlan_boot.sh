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
#              - File: mervlan_boot.sh || version="0.72.0"                  #
# ============================================================================ #
# - Purpose:    Manage MerVLAN Manager auto-start, service-event helper, and   #
#               SSH propagation to nodes for fully automated VLAN management.  #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED LIB_MERVQT_LOADED LIB_ACTION_ACK_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -f "$TEMPLATE_LIB" ] || { error -c vlan,cli "Missing template library: $TEMPLATE_LIB"; exit 1; }
. "$TEMPLATE_LIB"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || {
  error -c vlan,cli "Unable to load the DHCP/L2 safety library; refusing boot action"
  exit 1
}
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
    [ -e "$_rbl_lock" ] || continue
    [ -d "$_rbl_lock" ] && continue
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

cleanup_boot_temp_files() {
  _boot_cleanup_failed=0
  for _boot_cleanup_path in "$@"; do
    [ -n "$_boot_cleanup_path" ] || continue
    [ -e "$_boot_cleanup_path" ] || continue
    if ! rm -f "$_boot_cleanup_path" 2>/dev/null; then
      warn -c vlan,cli "Could not remove temporary boot-injection file $_boot_cleanup_path"
      _boot_cleanup_failed=1
    fi
  done
  [ "$_boot_cleanup_failed" -eq 0 ]
}

# copy_inject — Marker-bounded injection that preserves surrounding content
# Args: $1=rendered_template_path, $2=dest_file
# Returns: 0 on success (injected or updated), 1 on failure
copy_inject() {
  local tmpl="$1" dest="$2"
  [ -f "$tmpl" ] || { error -c vlan,cli "Template missing: $tmpl"; return 1; }

  local block_file md5 tplid destid start_tag end_tag start_base end_base shebang_line tmp_sb first_line

  block_file="${TMPDIR:-/tmp}/merv_inj_block.$$"
  [ ! -e "$block_file" ] || { error -c vlan,cli "Temporary injection path already exists"; return 1; }
  ( umask 077; : > "$block_file" ) 2>/dev/null || return 1

  md5="$(_content_md5 "$tmpl")"
  tplid="$(_template_id "$tmpl")"
  destid="$(_dest_id "$dest")"
  start_tag="$MARKER_PREFIX $destid [tpl=$tplid md5=$md5]"
  end_tag="$MARKER_SUFFIX $destid [tpl=$tplid md5=$md5]"
  start_base="$MARKER_PREFIX $destid [tpl=$tplid "
  end_base="$MARKER_SUFFIX $destid [tpl=$tplid "

  if IFS= read -r first_line < "$tmpl" 2>/dev/null; then
    case "$first_line" in
      '#!'*) shebang_line="$first_line" ;;
    esac
  fi

  {
    printf '%s\n' "$start_tag"
    if [ -n "$shebang_line" ]; then
      sed '1d' "$tmpl"
    else
      cat "$tmpl"
    fi
    printf '%s\n' "$end_tag"
  } > "$block_file"

  if ! mkdir -p "$(dirname "$dest")" 2>/dev/null; then
    cleanup_boot_temp_files "$block_file"
    return 1
  fi
  if [ ! -f "$dest" ] && ! : > "$dest" 2>/dev/null; then
    cleanup_boot_temp_files "$block_file"
    return 1
  fi

  case "$dest" in
    /jffs/scripts/*)
      [ -n "$shebang_line" ] || shebang_line='#!/bin/sh'
      ;;
  esac

  if [ -n "$shebang_line" ]; then
    if [ -s "$dest" ]; then
      if ! head -n 1 "$dest" 2>/dev/null | grep -q '^#!'; then
        tmp_sb="${dest}.shebang.$$"
        if ! {
          printf '%s\n' "$shebang_line"
          cat "$dest"
        } > "$tmp_sb" 2>/dev/null || ! mv -f "$tmp_sb" "$dest" 2>/dev/null; then
          cleanup_boot_temp_files "$tmp_sb"
          return 1
        fi
      fi
    else
      if ! printf '%s\n' "$shebang_line" > "$dest" 2>/dev/null; then
        cleanup_boot_temp_files "$block_file"
        return 1
      fi
    fi
  fi

  if LC_ALL=C grep -Fq "$start_base" "$dest"; then
    if ! LC_ALL=C grep -Fq "$end_base" "$dest"; then
      error -c vlan,cli "Cowardly refusing to modify $dest: found START marker without matching END. Please fix markers manually."
      cleanup_boot_temp_files "$block_file" "$tmp_sb"
      return 1
    fi
  fi

  tmp_new="${dest}.new"
  inject_block() {
    local count dedupe_tmp last_char
    awk -v start_base="$start_base" -v end_base="$end_base" -v blockf="$block_file" '
      BEGIN { replaced = 0; skipping = 0; }
      {
        if (!replaced) {
          if (index($0, start_base) == 1) {
            while ((getline line < blockf) > 0) {
              print line;
            }
            close(blockf);
            replaced = 1;
            skipping = 1;
          } else {
            print;
          }
        } else if (skipping) {
          if (index($0, end_base) == 1) {
            skipping = 0;
          }
        } else {
          print;
        }
      }
    ' "$dest" > "$tmp_new" || return 1

    if LC_ALL=C grep -qF "$start_base" "$dest"; then
      mv -f "$tmp_new" "$dest" || return 1
    else
      if ! rm -f "$tmp_new" 2>/dev/null; then
        warn -c vlan,cli "Could not remove unused injection staging file $tmp_new"
        return 1
      fi
      if [ -s "$dest" ]; then
        last_char=$(tail -c 1 "$dest" 2>/dev/null | tr '\n' '_')
        [ "$last_char" = "_" ] || printf '\n' >> "$dest"
      fi
      cat "$block_file" >> "$dest" || return 1
    fi

    while :; do
      count=$(LC_ALL=C grep -Fc "$start_base" "$dest" 2>/dev/null || printf '0')
      [ "$count" -gt 1 ] 2>/dev/null || break
      dedupe_tmp="${dest}.dedupe.$$"
      awk -v start_base="$start_base" -v end_base="$end_base" '
        BEGIN { skipping = 0; seen = 0 }
        {
          if (!skipping) {
            if (index($0, start_base) == 1) {
              if (seen) { skipping = 1; next }
              seen = 1
            }
            print
          } else if (index($0, end_base) == 1) {
            skipping = 0
          }
        }
      ' "$dest" > "$dedupe_tmp" || {
        if ! rm -f "$dedupe_tmp" 2>/dev/null; then
          warn -c vlan,cli "Could not remove duplicate-injection staging file $dedupe_tmp"
        fi
        return 1
      }
      if ! mv -f "$dedupe_tmp" "$dest"; then
        if ! rm -f "$dedupe_tmp" 2>/dev/null; then
          warn -c vlan,cli "Could not remove duplicate-injection staging file $dedupe_tmp"
        fi
        return 1
      fi
    done

    return 0
  }

  if [ "$MERV_DISABLE_LOCKS" = "1" ]; then
    if ! inject_block; then
      cleanup_boot_temp_files "$block_file" "$tmp_new"
      return 1
    fi
  else
    _boot_file_lock="$LOCKDIR/$(basename "$dest").lock"
    merv_lock_acquire "$_boot_file_lock" 0 0 boot-file || {
      cleanup_boot_temp_files "$block_file" "$tmp_new"
      return 1
    }
    _boot_lock_nonce="$MERV_LOCK_NONCE"; _boot_lock_start="$MERV_LOCK_START"
    if inject_block; then _boot_inject_rc=0; else _boot_inject_rc=$?; fi
    if ! merv_lock_release "$_boot_file_lock" "$_boot_lock_nonce" >/dev/null 2>&1; then _boot_inject_rc=1; fi
    if [ "$_boot_inject_rc" -ne 0 ]; then
      cleanup_boot_temp_files "$block_file" "$tmp_new"
      return 1
    fi
  fi

  if [ ! -x "$dest" ] && head -n 1 "$dest" 2>/dev/null | grep -q '^#!'; then
    chmod 755 "$dest" 2>/dev/null || warn -c vlan,cli "Could not set chmod on $dest"
  fi

  cleanup_boot_temp_files "$block_file" "$tmp_new" || return 1
  return 0
}

# remove_inject — Remove only the marker-bounded block for the given template
# Args: $1=template_path, $2=dest_file
# Returns: 0 on success (or block absent), 1 on fatal error
remove_inject() {
  local tmpl="$1" dest="$2"
  [ -f "$tmpl" ] || { error -c vlan,cli "Template missing: $tmpl"; return 1; }
  [ -f "$dest" ] || return 0

  local tplid destid start_base end_base
  tplid="$(_template_id "$tmpl")"
  destid="$(_dest_id "$dest")"
  start_base="$MARKER_PREFIX $destid [tpl=$tplid "
  end_base="$MARKER_SUFFIX $destid [tpl=$tplid "

  if ! LC_ALL=C grep -Fq "$start_base" "$dest"; then
    return 0
  fi

  if ! LC_ALL=C grep -Fq "$end_base" "$dest"; then
    error -c vlan,cli "Cowardly refusing to modify $dest: found START marker without matching END. Please fix markers manually."
    return 1
  fi

  tmp_new="${dest}.new"
  remove_block() {
    awk -v start_base="$start_base" -v end_base="$end_base" '
      BEGIN { skipping = 0; removed = 0; }
      {
        if (!skipping) {
          if (index($0, start_base) == 1) {
            skipping = 1;
            removed = 1;
            next;
          }
          print;
        } else {
          if (index($0, end_base) == 1) {
            skipping = 0;
            next;
          }
        }
      }
      END { }
    ' "$dest" > "$tmp_new" || return 1

    mv -f "$tmp_new" "$dest"
  }

  if [ "$MERV_DISABLE_LOCKS" = "1" ]; then
    if ! remove_block; then
      cleanup_boot_temp_files "$tmp_new"
      return 1
    fi
  else
    _boot_file_lock="$LOCKDIR/$(basename "$dest").lock"
    merv_lock_acquire "$_boot_file_lock" 0 0 boot-file || {
      cleanup_boot_temp_files "$tmp_new"
      return 1
    }
    _boot_lock_nonce="$MERV_LOCK_NONCE"; _boot_lock_start="$MERV_LOCK_START"
    if remove_block; then _boot_remove_rc=0; else _boot_remove_rc=$?; fi
    if ! merv_lock_release "$_boot_file_lock" "$_boot_lock_nonce" >/dev/null 2>&1; then _boot_remove_rc=1; fi
    if [ "$_boot_remove_rc" -ne 0 ]; then
      cleanup_boot_temp_files "$tmp_new"
      return 1
    fi
  fi

  cleanup_boot_temp_files "$tmp_new" || return 1
  return 0
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

  if "$CRU_BIN" l 2>/dev/null | grep -q "$INJ_BASE/functions/heal_event.sh cron"; then
    info -c vlan,cli "Cron confirmed for $CRON_NAME"
  else
    warn -c vlan,cli "Cron verification failed: $CRON_NAME not listed"
  fi
}

disable_cron_now() {
  if [ -z "$CRU_BIN" ]; then
    warn -c vlan,cli "Cron disable skipped: cru command not available"
    return 0
  fi

  "$CRU_BIN" d "$CRON_NAME" 2>/dev/null

  if "$CRU_BIN" l 2>/dev/null | grep -q "$INJ_BASE/functions/heal_event.sh cron"; then
    warn -c vlan,cli "Cron disable verification failed; entry still present"
  else
    info -c vlan,cli "Cron disabled: $CRON_NAME"
  fi
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
        boot_action_ack_error "Boot action blocked: complete SSH trust preflight failed" "SSH_TRUST_REQUIRED"
        error -c vlan,cli "Boot action '$ACTION' refused before local mutation: SSH trust preflight failed"
        exit 1
      fi
    fi
    ;;
esac

case "$ACTION" in
  # =========================================================================== #
  # enable — Boot MerVLAN at router startup; enable mervlan.asp auto-load       #
  # =========================================================================== #
  enable)
    _boot_partial=0
    _boot_warnings='[]'
    # Ensure /jffs/scripts directory exists for system startup scripts
    mkdir -p "$SCRIPTS_DIR" || {
      boot_action_ack_error "Failed to create scripts directory" "SCRIPTS_DIR_CREATE_FAILED"
      exit 1
    }

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

    # Arm MERV_MAC secondary shield from best available db (JFFS checkpoint or active)
    type ebt_mac_shield_init_and_apply >/dev/null 2>&1 && {
      ebt_mac_shield_init_and_apply "$(merv_mac_best_db 2>/dev/null || true)"
      info -c vlan,cli "MERV_MAC: secondary shield armed"
    }

    # Propagate enable action to all configured nodes via SSH
    if ! handle_nodes_via_ssh "enable"; then
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
    # Ensure /jffs/scripts directory exists
    mkdir -p "$SCRIPTS_DIR"
    # Inject service-event wrapper into system rc_service handler
  inject_template "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER" || { error -c vlan,cli "Failed to install service-event"; exit 1; }
    # Inject addon boot entry into services-start (for addon install.sh auto-load)
  inject_template "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START" || { error -c vlan,cli "Failed to install addon boot entry"; exit 1; }
    info -c vlan,cli "Installed service-event with MERV_BASE=$MERV_BASE (setup-only)"
    # Propagate setupenable to all configured nodes via SSH
    handle_nodes_via_ssh "setupenable"
    ;;

  # ========================================================================== #
  # setupdisable — Setup-only: remove service-event wrapper and addon entry    #
  # ========================================================================== #
  setupdisable)
    # Remove injected service-event wrapper content (idempotent)
    if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
  remove_template_block "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER" || warn -c vlan,cli "Failed to remove injected service-event content"
      info -c vlan,cli "Removed service-event injection (setup-only disable)"
    else
      info -c vlan,cli "service-event not present; nothing to disable"
    fi
    # Remove injected addon boot entry from services-start (idempotent)
    if [ -f "$SERVICES_START" ]; then
  remove_template_block "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START" || warn -c vlan,cli "Failed to remove addon boot entry"
    fi
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
    # Propagate setupdisable to all configured nodes via SSH
    handle_nodes_via_ssh "setupdisable"
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
      mkdir -p "$SCRIPTS_DIR"
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
      chmod 755 "$SERVICE_EVENT_WRAPPER" 2>/dev/null || \
        warn -c vlan,cli "Could not chmod 755 $SERVICE_EVENT_WRAPPER"
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
      if [ -f "$SERVICES_START" ]; then
        remove_template_block "$TEMPLATE_SERVICES" "$SERVICES_START" \
          || warn -c vlan,cli "Failed to remove services-start block"
        remove_template_block "$TEMPLATE_SERVICES_ADDON" "$SERVICES_START" \
          || warn -c vlan,cli "Failed to remove addon boot block"
      fi
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
    boot_state=disabled
    addon_state=missing
    event_state=missing
    cron_state=absent

    # Check persisted boot state in settings.json
    if [ "$(json_get_flag "BOOT_ENABLED" "0" "$SETTINGS_FILE")" = "1" ]; then
      boot_state=enabled
    fi

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

    if [ -n "$CRU_BIN" ]; then
      if "$CRU_BIN" l 2>/dev/null | grep -q "$INJ_BASE/functions/heal_event.sh cron"; then
        cron_state=present
      fi
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
      info -c vlan,cli "${hw_label} boot=${boot_state} addon=${addon_state} service-event=${event_state} cron=${cron_state} is_node=${is_node_state} mac_shield=${mac_shield_state}"
      info -c vlan,cli "<--- Configured Nodes --->"

      # NODE_STATUS_OUTPUT is newline-separated entries: ip:hw=LABEL boot=1 addon=.. event=.. cron=..
      printf '%s
    ' "$NODE_STATUS_OUTPUT" | sed 's/^[[:space:]]*//; /^$/d' | while IFS= read -r entry; do
        node_ip="${entry%%:*}"
        rest="${entry#*:}"

        # Default values
        node_hw="Unknown"
        node_boot_raw=""
        node_addon=""
        node_event=""
        node_cron=""
        node_is_node=""
        node_mac_shield=""

        # Parse key=value pairs
        for kv in $rest; do
          case "$kv" in
            hw=*)           node_hw="${kv#hw=}" ;;
            boot=*)         node_boot_raw="${kv#boot=}" ;;
            addon=*)        node_addon="${kv#addon=}" ;;
            event=*)        node_event="${kv#event=}" ;;
            cron=*)         node_cron="${kv#cron=}" ;;
            is_node=*)      node_is_node="${kv#is_node=}" ;;
            mac_shield=*)   node_mac_shield="${kv#mac_shield=}" ;;
          esac
        done

        case "$node_boot_raw" in
          1) node_boot="enabled"  ;;
          0) node_boot="disabled" ;;
          *) node_boot="$node_boot_raw" ;;
        esac

        info -c vlan,cli "${node_hw} ${node_ip}:boot=${node_boot} addon=${node_addon} event=${node_event} cron=${node_cron} is_node=${node_is_node} mac_shield=${node_mac_shield}"
      done
    else
      # No nodes configured; output local status only
      info -c vlan,cli "Status:"
      info -c vlan,cli "<--- Main Unit --->"
      info -c vlan,cli "${hw_label} boot=${boot_state} addon=${addon_state} service-event=${event_state} cron=${cron_state} is_node=${is_node_state} mac_shield=${mac_shield_state}"
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
          _nh="Unknown"; _nb="?"; _na="?"; _nev="?"; _nc="?"; _nm="off"
          for _kv in $_nr; do
            case "$_kv" in
              hw=*)         _nh="${_kv#hw=}" ;;
              boot=*)       _nb="${_kv#boot=}" ;;
              addon=*)      _na="${_kv#addon=}" ;;
              event=*)      _nev="${_kv#event=}" ;;
              cron=*)       _nc="${_kv#cron=}" ;;
              mac_shield=*) _nm="${_kv#mac_shield=}" ;;
            esac
          done
          case "$_nb" in 1) _nb="enabled";; 0) _nb="disabled";; esac
          printf '%s{"ip":"%s","hw":"%s","boot":"%s","addon":"%s","event":"%s","cron":"%s","mac":"%s"}' \
            "$_sep" "$_nip" "$(_json_str "$_nh")" "$_nb" "$_na" "$_nev" "$_nc" "$_nm"
          _sep=","
        done
      }
    )"

    if ! printf '{"ts":"%s","main":{"hw":"%s","boot":"%s","addon":"%s","event":"%s","cron":"%s","mac":"%s"},"nodes":[%s]}\n' \
      "$_sj_ts" "$(_json_str "$hw_label")" \
      "$boot_state" "$addon_state" "$event_state" "$cron_state" "$mac_shield_state" \
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
    addon_state=missing
    event_state=missing
    cron_state=absent
    is_node_state=no
    # Check persisted boot state and set boot_state to 1 if enabled
    if [ "$(json_get_flag "BOOT_ENABLED" "0" "$SETTINGS_FILE")" = "1" ]; then boot_state=1; fi
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
    if [ -n "$CRU_BIN" ]; then
      if "$CRU_BIN" l 2>/dev/null | grep -q "$INJ_BASE/functions/heal_event.sh cron"; then
        cron_state=present
      fi
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

    echo "REPORT hw=$hw_label boot=$boot_state addon=$addon_state event=$event_state cron=$cron_state is_node=$is_node_state mac_shield=$mac_shield_state"
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
