#!/bin/sh
#
# ──────────────────────────────────────────────────────────────────────────── #
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
# ──────────────────────────────────────────────────────────────────────────── #
#                - File: mervlan_boot.sh || version="0.51"                     #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Manage MerVLAN Manager auto-start, service-event helper, and   #
#               SSH propagation to nodes for fully automated VLAN management.  #
# ──────────────────────────────────────────────────────────────────────────── #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -f "$TEMPLATE_LIB" ] || { error -c vlan,cli "Missing template library: $TEMPLATE_LIB"; exit 1; }
. "$TEMPLATE_LIB"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"
# =========================================== End of MerVLAN environment setup #
SSH_NODE_USER=$(get_node_ssh_user)
SSH_NODE_PORT=$(get_node_ssh_port)
# ========================================================================== #
# INITIALIZATION & CONSTANTS — Boot state flags, action dispatch, paths      #
# ========================================================================== #

# Action from command line ($1 parameter: enable/disable/setupenable/etc)
ACTION="$1"
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

_has_cmd() { command -v "$1" >/dev/null 2>&1; }

: "${MERV_DISABLE_LOCKS:=0}"

# Compute content hash (md5 is in busybox; sha256 may not be)
_content_md5() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

CRON_NAME="mervlan_health"
CRU_BIN=""

if command -v cru >/dev/null 2>&1; then
  CRU_BIN=$(command -v cru)
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
  rm -f "$tpl" 2>/dev/null || :
  return $rc
}

remove_template_block() {
  local name="$1" dest="$2" variant="${3:-}" resolved tpl rc
  resolved=$(select_template_variant "$name" "$dest" "$variant") || return 1
  tpl=$(tpl_path "$name" "$resolved" "$dest") || return 1
  remove_inject "$tpl" "$dest"
  rc=$?
  rm -f "$tpl" 2>/dev/null || :
  return $rc
}

is_node() {
  [ "${MERV_NODE_CONTEXT:-0}" = "1" ] && return 0
  [ -f "$MERV_BASE/.is_node" ] && return 0
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

# copy_inject — Marker-bounded injection that preserves surrounding content
# Args: $1=rendered_template_path, $2=dest_file
# Returns: 0 on success (injected or updated), 1 on failure
copy_inject() {
  local tmpl="$1" dest="$2"
  [ -f "$tmpl" ] || { error -c vlan,cli "Template missing: $tmpl"; return 1; }

  local block_file md5 tplid destid start_tag end_tag start_base end_base shebang_line tmp_sb first_line

  block_file="$(mktemp "${TMPDIR:-/tmp}/merv_inj_block.XXXXXX" 2>/dev/null || printf '%s/merv_inj_block.%s' "${TMPDIR:-/tmp}" "$$")"

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

  mkdir -p "$(dirname "$dest")" 2>/dev/null || { rm -f "$block_file" 2>/dev/null || :; return 1; }
  [ -f "$dest" ] || : > "$dest"

  case "$dest" in
    /jffs/scripts/*)
      [ -n "$shebang_line" ] || shebang_line='#!/bin/sh'
      ;;
  esac

  if [ -n "$shebang_line" ]; then
    if [ -s "$dest" ]; then
      if ! head -n 1 "$dest" 2>/dev/null | grep -q '^#!'; then
        tmp_sb="${dest}.shebang.$$"
        {
          printf '%s\n' "$shebang_line"
          cat "$dest"
        } > "$tmp_sb" 2>/dev/null && mv -f "$tmp_sb" "$dest" 2>/dev/null || rm -f "$tmp_sb" 2>/dev/null || :
      fi
    else
      printf '%s\n' "$shebang_line" > "$dest" 2>/dev/null || :
    fi
  fi

  if LC_ALL=C grep -Fq "$start_base" "$dest"; then
    if ! LC_ALL=C grep -Fq "$end_base" "$dest"; then
      error -c vlan,cli "Cowardly refusing to modify $dest: found START marker without matching END. Please fix markers manually."
      rm -f "$block_file" 2>/dev/null || :
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
        }
      }
    ' "$dest" > "$tmp_new" || return 1

    if LC_ALL=C grep -qF "$start_base" "$dest"; then
      mv -f "$tmp_new" "$dest" || return 1
    else
      rm -f "$tmp_new" 2>/dev/null || :
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
      ' "$dest" > "$dedupe_tmp" || { rm -f "$dedupe_tmp" 2>/dev/null || :; break; }
      mv -f "$dedupe_tmp" "$dest" || { rm -f "$dedupe_tmp" 2>/dev/null || :; break; }
    done

    return 0
  }

  if [ "$MERV_DISABLE_LOCKS" = "1" ] || ! _has_cmd flock; then
    inject_block || { rm -f "$block_file" "$tmp_new" 2>/dev/null || :; return 1; }
  else
    if ! (
      flock -w 5 200 || exit 1
      inject_block
    ) 200>"${dest}.lock"; then
      rm -f "$block_file" "$tmp_new" 2>/dev/null || :
      return 1
    fi
  fi

  if [ ! -x "$dest" ] && head -n 1 "$dest" 2>/dev/null | grep -q '^#!'; then
    chmod 755 "$dest" 2>/dev/null || warn -c vlan,cli "Could not set chmod on $dest"
  fi

  rm -f "$block_file" 2>/dev/null || :
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

  if [ "$MERV_DISABLE_LOCKS" = "1" ] || ! _has_cmd flock; then
    remove_block || { rm -f "$tmp_new" 2>/dev/null || :; return 1; }
  else
    if ! (
      flock -w 5 200 || exit 1
      remove_block
    ) 200>"${dest}.lock"; then
      rm -f "$tmp_new" 2>/dev/null || :
      return 1
    fi
  fi

  return 0
}

# ============================================================================== #
# NODE ORCHESTRATION HELPERS — SSH connectivity, node discovery, status polling  #
# ============================================================================== #

# get_node_ips — Extract NODE1-NODE5 IPs from settings.json (same as sync_nodes.sh)
# Args: none (reads $SETTINGS_FILE global)
# Returns: stdout list of valid IP addresses (one per line), or empty string if none
get_node_ips() {
    # Extract NODE1-NODE5 entries via grep + sed patterns, filter out "none" and non-IPs
    grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | \
    sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
    grep -v "none" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# test_ssh_connection — Validate SSH connectivity to a specific node (same as sync_nodes.sh)
# Args: $1 = node_ip (uses configured SSH credentials from settings.json)
# Returns: 0 if "connected" echo received, 1 if SSH fails or no response
test_ssh_connection() {
    local node_ip="$1"
    # Use db-client (Dropbear SSH client) with private key auth, 5-sec timeout
  if dbclient -p "$SSH_NODE_PORT" -y -i "$SSH_KEY" "$SSH_NODE_USER@$node_ip" "echo connected" 2>/dev/null | grep -q "connected"; then
        return 0
    else
        return 1
    fi
}

# run_ssh_command — Execute a shell command on a remote node via SSH
# Args: $1 = node_ip, $2 = command (e.g., "enable", "disable")
# Returns: 0 on success, 1 if connection fails or command execution fails
# Context: Sets MERV_NODE_CONTEXT=1 so remote mervlan_boot.sh executes locally on node
run_ssh_command() {
    local node_ip="$1"
    local cmd="$2"

  if is_node; then
    info -c cli,vlan "Node context detected; refusing to SSH to $node_ip for '$cmd'"
    return 0
  fi
    
    # Validate SSH connectivity before attempting command execution
    if ! test_ssh_connection "$node_ip"; then
        error -c cli,vlan "SSH connection failed to $node_ip"
        return 1
    fi
    
    info -c cli,vlan "Running '$cmd' on $node_ip via SSH..."
    # Execute command on node with MERV_NODE_CONTEXT=1 (forces local node execution)
  if dbclient -p "$SSH_NODE_PORT" -y -i "$SSH_KEY" "$SSH_NODE_USER@$node_ip" "cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 ./mervlan_boot.sh '$cmd'" 2>&1; then
        info -c cli,vlan "✓ Command '$cmd' succeeded on $node_ip"
        return 0
    else
        error -c cli,vlan "✗ Command '$cmd' failed on $node_ip"
        return 1
    fi
}

# handle_nodes_via_ssh — Batch propagate action to all configured nodes via SSH
# Args: $1 = action_name (e.g., "enable", "disable", "setupenable")
# Returns: 0 if all nodes succeeded, 1 if any failed (but continues all nodes)
# Context: Respects MERV_SKIP_NODE_SYNC=1 override flag for skipping propagation
handle_nodes_via_ssh() {
  local cmd="$1"

  if is_node; then
    info -c cli,vlan "Node context detected; skipping node propagation for '$cmd'"
    return 0
  fi

  if [ "${MERV_SKIP_NODE_SYNC:-0}" = "1" ]; then
    info -c cli,vlan "Skipping node propagation for '$cmd' (MERV_SKIP_NODE_SYNC=1)"
    return 0
  fi

  local NODE_IPS
  NODE_IPS=$(get_node_ips)
  if [ -z "$NODE_IPS" ]; then
    return 0
  fi

  info -c cli,vlan "Propagating '$cmd' to nodes: $(echo "$NODE_IPS" | tr '\n' ' ')"

  local overall_success=true
  for node_ip in $NODE_IPS; do
    if ! run_ssh_command "$node_ip" "$cmd"; then
      overall_success=false
    fi
  done

  if [ "$overall_success" = "true" ]; then
    info -c cli,vlan "✓ All nodes processed successfully for '$cmd'"
  else
    warn -c cli,vlan "⚠️  Some nodes failed for '$cmd'"
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

    local NODE_IPS
    NODE_IPS=$(get_node_ips)
    [ -z "$NODE_IPS" ] && return 0

    NODE_STATUS_OUTPUT=""
    for node_ip in $NODE_IPS; do
      # Single SSH invocation per node; grab the last line from remote's report
      ns=$(dbclient -p "$SSH_NODE_PORT" -y -i "$SSH_KEY" "$SSH_NODE_USER@$node_ip" "cd '$MERV_BASE/functions' && ./mervlan_boot.sh report" 2>/dev/null | tail -1)
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
    done
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

  if "$CRU_BIN" l 2>/dev/null | grep -q "$INJ_BASE/heal_event.sh cron"; then
    warn -c vlan,cli "Cron disable verification failed; entry still present"
  else
    info -c vlan,cli "Cron disabled: $CRON_NAME"
  fi
}

# =============================================================================== #
# MAIN ACTION DISPATCH — Entry point for all actions (enable/disable/status/etc)  #
# =============================================================================== #

case "$ACTION" in
  # =========================================================================== #
  # enable — Boot MerVLAN at router startup; enable mervlan.asp auto-load       #
  # =========================================================================== #
  enable)
    # Ensure /jffs/scripts directory exists for system startup scripts
    mkdir -p "$SCRIPTS_DIR"

    # Inject services-start code to auto-load mervlan.asp at system boot
    inject_template "$TEMPLATE_SERVICES" "$SERVICES_START" || { error -c vlan,cli "Failed to install services-start"; exit 1; }
    info -c vlan,cli "Installed services-start with MERV_BASE=$MERV_BASE (service-event managed at setup)"

    # Persist boot enabled state to settings.json
    if ! json_set_flag "BOOT_ENABLED" "1" "$SETTINGS_FILE" >/dev/null 2>&1; then
      warn -c vlan,cli "Failed to persist BOOT_ENABLED=1"
    fi
    # Enable cron job for periodic VLAN health checks (main + nodes)
    enable_cron_now

    # Propagate enable action to all configured nodes via SSH
    handle_nodes_via_ssh "enable"
    ;;

  # =============================================================================== #
  # disable — Disable boot; remove services-start injection but keep service-event  #
  # =============================================================================== #
  disable)
    # Remove injected services-start code (idempotent; no-op if not found)
    if [ -f "$SERVICES_START" ]; then
      remove_template_block "$TEMPLATE_SERVICES" "$SERVICES_START" || warn -c vlan,cli "Failed to remove injected services-start content"
    fi
    # Persist boot disabled state to settings.json
    if ! json_set_flag "BOOT_ENABLED" "0" "$SETTINGS_FILE" >/dev/null 2>&1; then
      warn -c vlan,cli "Failed to persist BOOT_ENABLED=0"
    fi

    info -c vlan,cli "Removed services-start injection (service-event unchanged)"

    # Disable cron job (main + nodes)
    disable_cron_now
    
    # Propagate disable action to all configured nodes via SSH
    handle_nodes_via_ssh "disable"
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
        error -c vlan,cli "Create $MERV_BASE/.is_node or run via SSH with MERV_NODE_CONTEXT=1"
        exit 1
      fi
      mkdir -p "$SCRIPTS_DIR"
      # Install node service-event handler (mervlan_boot.sh for nodes)
      inject_template "$TEMPLATE_SERVICE_EVENT_NODES" "$SERVICE_EVENT_HANDLER" || { error -c vlan,cli "Failed to install node mervlan_boot.sh"; exit 1; }
  chmod 755 "$SERVICE_EVENT_HANDLER" 2>/dev/null || { warn -c vlan,cli "Could not chmod 755 $SERVICE_EVENT_HANDLER"; exit 1; }
      # Install node service-event wrapper
      inject_template "$TEMPLATE_SERVICE_EVENT" "$SERVICE_EVENT_WRAPPER" || { error -c vlan,cli "Failed to install node service-event"; exit 1; }
      # Set executable permissions on installed scripts
      chmod 755 "$SERVICE_EVENT_WRAPPER" 2>/dev/null || { warn -c vlan,cli "Could not chmod 755 $SERVICE_EVENT_WRAPPER"; exit 1; }
      if [ -n "$BOOT_SCRIPT" ]; then
        chmod 755 "$BOOT_SCRIPT" 2>/dev/null || warn -c vlan,cli "Could not chmod 755 $BOOT_SCRIPT"
      fi

      info -c vlan,cli "Installed node mervlan_boot.sh, service-event, services-start with MERV_BASE=$MERV_BASE"
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
      # Remove addon boot entry from services-start if present
      if [ -f "$SERVICES_START" ]; then
        remove_template_block "$TEMPLATE_SERVICES" "$SERVICES_START" \
          || warn -c vlan,cli "Failed to remove services-start block"
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

    # Check if addon install.sh entry exists in services-start
    if [ -f "$SERVICES_START" ] && grep -q "/jffs/addons/mervlan/install.sh" "$SERVICES_START" 2>/dev/null; then
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
      if "$CRU_BIN" l 2>/dev/null | grep -q "$INJ_BASE/heal_event.sh cron"; then
        cron_state=present
      fi
    fi

    # Local hardware label (main router)
    local hw_label
    hw_label="$(json_get_flag "PRODUCTID" "Unknown" "$HW_SETTINGS_FILE" 2>/dev/null)"

    # Get list of configured nodes for status aggregation
    NODE_IPS=$(get_node_ips)
    if [ -n "$NODE_IPS" ]; then
      # Query nodes for their status via report action
      collect_node_status

      info -c vlan,cli "Status:"
      info -c vlan,cli "<--- Main Unit --->"
      info -c vlan,cli "${hw_label} boot=${boot_state} addon=${addon_state} service-event=${event_state} cron=${cron_state}"
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

        # Parse key=value pairs
        for kv in $rest; do
          case "$kv" in
            hw=*)    node_hw="${kv#hw=}" ;;
            boot=*)  node_boot_raw="${kv#boot=}" ;;
            addon=*) node_addon="${kv#addon=}" ;;
            event=*) node_event="${kv#event=}" ;;
            cron=*)  node_cron="${kv#cron=}" ;;
          esac
        done

        case "$node_boot_raw" in
          1) node_boot="enabled"  ;;
          0) node_boot="disabled" ;;
          *) node_boot="$node_boot_raw" ;;
        esac

        info -c vlan,cli "${node_hw} ${node_ip}:boot=${node_boot} addon=${node_addon} event=${node_event} cron=${node_cron}"
      done
    else
      # No nodes configured; output local status only
      info -c vlan,cli "Status:"
      info -c vlan,cli "<--- Main Unit --->"
      info -c vlan,cli "${hw_label} boot=${boot_state} addon=${addon_state} service-event=${event_state} cron=${cron_state}"
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
    # Check persisted boot state and set boot_state to 1 if enabled
    if [ "$(json_get_flag "BOOT_ENABLED" "0" "$SETTINGS_FILE")" = "1" ]; then boot_state=1; fi
    # Check for addon install.sh entry in services-start
    if [ -f "$SERVICES_START" ] && grep -q "/jffs/addons/mervlan/install.sh" "$SERVICES_START" 2>/dev/null; then addon_state=active; fi
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
      if "$CRU_BIN" l 2>/dev/null | grep -q "$INJ_BASE/heal_event.sh cron"; then
        cron_state=present
      fi
    fi
    # Output terse report line: REPORT hw=<PRODUCTID> boot=0/1 addon=<state> event=<state> cron=<state>
    # Used by collect_node_status() for remote aggregation via SSH
    # Hardware label from settings.json (PRODUCTID may be stored top-level or in
    # the Hardware block; json_get_flag handles legacy top-level keys while
    # var_settings.sh exposes HW_SETTINGS_FILE alias.)
    hw_label="$(json_get_flag "PRODUCTID" "Unknown" "$HW_SETTINGS_FILE" 2>/dev/null)"

    echo "REPORT hw=$hw_label boot=$boot_state addon=$addon_state event=$event_state cron=$cron_state"
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