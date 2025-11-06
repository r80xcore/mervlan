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
#                - File: mervlan_boot.sh || version="0.46"                     #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Manage MerVLAN Manager auto-start, service-event helper, and   #
#               SSH propagation to nodes for fully automated VLAN management.  #
# ──────────────────────────────────────────────────────────────────────────── #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
# =========================================== End of MerVLAN environment setup #

# ========================================================================== #
# INITIALIZATION & CONSTANTS — Boot state flags, action dispatch, paths      #
# ========================================================================== #

# Boot enabled/disabled flag (filesystem state: 0 or 1)
BOOT_FLAG="$FLAGDIR/boot_enabled"
# Action from command line ($1 parameter: enable/disable/setupenable/etc)
ACTION="$1"
# VLAN manager path (referenced in comments, legacy constant)
VLAN_RUN_LINE="$MERV_BASE/functions/vlan_manager.sh"
# Legacy tag constants (cron support removed, no longer used)
TAG="# ENABLE MERVLAN BOOT"
EVENT_TAG="# MERVLAN MANAGER SERVICE-EVENT"
# INJ_BASE without trailing slash (used for sed substitutions)
INJ_BASE="${MERV_BASE%/}"

# ========================================================================== #
#                      TEMPLATE INJECTION UTILITIES                          #
# Extract variants, inject, remove idempotently                              #
# ========================================================================== #

# render_template_variant — Extract template variant and apply MERV_BASE substitution
# Args: $1=template_path, $2=variant_id (1|2), $3=output_file, $4=MERV_BASE_resolved
# Returns: 0 on success, 1 if variant not found or template malformed
# Explanation: Searches template for TEMPLATE_<id> marker, extracts that section,
#   performs sed substitution of MERV_BASE_PLACEHOLDER. If variant missing, falls back to entire template.
#   Uses AWK for line-by-line parsing to avoid loading entire file into memory.
render_template_variant() {
  # $1=template path, $2=variant id, $3=output file, $4=resolved MERV_BASE
  local template="${1}" variant="${2}" output="${3}" inj="${4}" raw status

  raw="${output}.raw"
  [ -n "$variant" ] || variant="1"

  # AWK script: Extract TEMPLATE_<id> section if present, or entire template as fallback
  if ! awk -v want="$variant" '
    BEGIN {
      capture = 0;
      found = 0;
    }
    /^TEMPLATE_[0-9]+[[:space:]]*$/ {
      section = $0;
      sub(/^TEMPLATE_/, "", section);
      gsub(/[[:space:]]/, "", section);
      capture = (section == want);
      if (capture) {
        found = 1;
      }
      next;
    }
    capture {
      print;
    }
    END {
      if (!found) {
        exit 1;
      }
    }
  ' "$template" > "$raw" 2>/dev/null; then
    status=$?
    rm -f "$raw" 2>/dev/null || :
    if [ "$status" -ne 1 ]; then
      return 1
    fi
    # Variant markers missing or requested variant not found; fall back to entire template
    if ! cp "$template" "$raw" 2>/dev/null; then
      return 1
    fi
  fi

  # Perform sed substitution: replace MERV_BASE_PLACEHOLDER with resolved MERV_BASE
  if ! sed "s|MERV_BASE_PLACEHOLDER|$inj|g" "$raw" > "$output" 2>/dev/null; then
    rm -f "$raw" "$output" 2>/dev/null || :
    return 1
  fi

  # Clean up temporary raw file
  rm -f "$raw" 2>/dev/null || :
  return 0
}

# copy_inject — Idempotently inject template content into destination file
# Args: $1=template_path, $2=dest_file
# Returns: 0 on success (inject completed or already present), 1 on failure
# Explanation: Renders template variant (tries variant 2 for shebang files, falls back to 1).
#   Checks if rendered block already exists verbatim in dest (idempotent). Appends with
#   single blank line separator. Atomically replaces destination via mktemp + mv.
copy_inject() {
  # $1=template $2=dest
  local tmpl dest inj tmp injtmp combtmp
  tmpl="$1"; dest="$2"
  [ -f "$tmpl" ] || { error -c vlan,cli "Template missing: $tmpl"; return 1; }

  inj="${MERV_BASE%/}"
  # Create temporary file for rendered template and combined output
  tmp="$(mktemp "${TMPDIR:-/tmp}/merv_inj.XXXXXX" 2>/dev/null || printf '%s/merv_inj.%s' "${TMPDIR:-/tmp}" "$$")"
  injtmp="${tmp}.inj"
  combtmp="${tmp}.combined"

  # Detect template variant: use variant 2 if dest has shebang (#!), else variant 1
  local variant="1"
  if [ -f "$dest" ] && [ -s "$dest" ] && head -n 1 "$dest" 2>/dev/null | grep -q '^#!'; then
    variant="2"
  fi

  # Render template with detected variant; fallback to variant 1 if variant 2 fails
  if ! render_template_variant "$tmpl" "$variant" "$injtmp" "$inj"; then
    if [ "$variant" = "2" ]; then
      if ! render_template_variant "$tmpl" "1" "$injtmp" "$inj"; then
        rm -f "$tmp" "$injtmp" "$combtmp" 2>/dev/null || :
        return 1
      fi
    else
      rm -f "$tmp" "$injtmp" "$combtmp" 2>/dev/null || :
      return 1
    fi
  fi

  # Check idempotence: if rendered block already exists verbatim in dest, skip injection
  if [ -f "$dest" ]; then
    if awk -v injfile="$injtmp" '
      BEGIN {
        m = 0;
        while ((getline l < injfile) > 0) { m++; inj[m] = l; }
        close(injfile);
      }
      { lines[++n] = $0; }
      END {
        if (m == 0) exit 1;
        for (i = 1; i <= n; i++) {
          ok = 1;
          for (j = 1; j <= m; j++) {
            if (i + j - 1 > n || lines[i + j - 1] != inj[j]) { ok = 0; break; }
          }
          if (ok) exit 0;
        }
        exit 1;
      }
    ' "$dest" >/dev/null 2>&1; then
      info -c vlan,cli "Injection skipped: block already present in $dest"
      rm -f "$tmp" "$injtmp" "$combtmp" 2>/dev/null || :
      return 0
    fi
  fi

  if [ -f "$dest" ]; then
    # Remove trailing blank lines from dest, then append blank separator + rendered content
    if ! awk '{ lines[NR] = $0 } END { n = NR; while (n>0 && lines[n]=="") n--; for (i=1;i<=n;i++) print lines[i] }' "$dest" > "$combtmp" 2>/dev/null; then
      rm -f "$injtmp" "$combtmp" 2>/dev/null || :
      return 1
    fi
    # add single blank line separator
    printf '\n' >> "$combtmp"
    cat "$injtmp" >> "$combtmp"
    # atomic replace via mv (ensures consistency even on crash)
    if ! mv -f "$combtmp" "$dest" 2>/dev/null; then
      rm -f "$injtmp" "$combtmp" 2>/dev/null || :
      return 1
    fi
  else
    # ensure parent dir exists, then install injected file
    mkdir -p "$(dirname "$dest")" 2>/dev/null || { rm -f "$injtmp" 2>/dev/null || :; return 1; }
    if ! mv -f "$injtmp" "$dest" 2>/dev/null; then
      rm -f "$injtmp" 2>/dev/null || :
      return 1
    fi
  fi

  chmod 755 "$dest" 2>/dev/null || warn -c vlan,cli "Could not set chmod on $dest"
  rm -f "$tmp" "$injtmp" "$combtmp" 2>/dev/null || :
  return 0
}

# remove_inject — Conservatively remove injected template content from destination
# Args: $1=template_path, $2=dest_file
# Returns: 0 on success or no-op, 1 on fatal error (template parse failure)
# Explanation: Renders template via multi-variant detection (prefers variant 2 if dest
#   is empty or non-shebang, else tries variant 1 first). Searches for first literal
#   occurrence of rendered block and removes it with preceding/trailing blank lines.
#   Conservative: does nothing if block not found (returns 1 from AWK, interpreted as no-op).
remove_inject() {
  local tmpl dest inj tmp injtmp tmpout variant
  tmpl="$1"; dest="$2"
  [ -f "$tmpl" ] || { error -c vlan,cli "Template missing: $tmpl"; return 1; }
  [ -f "$dest" ] || return 0

  inj="${MERV_BASE%/}"
  # Create temporary files for rendering and output
  tmp="$(mktemp "${TMPDIR:-/tmp}/merv_rmv.XXXXXX" 2>/dev/null || printf '%s/merv_rmv.%s' "${TMPDIR:-/tmp}" "$$")"
  injtmp="${tmp}.inj"
  tmpout="${tmp}.out"
  rm -f "$tmp" 2>/dev/null || :

  # Try variant 2 first if dest has content (likely has shebang), else variant 1 first
  local variants="2 1" status
  if [ ! -s "$dest" ]; then
    variants="1 2"
  fi

  for variant in $variants; do
    # Render the template variant (skip if rendering fails for this variant)
    if ! render_template_variant "$tmpl" "$variant" "$injtmp" "$inj"; then
      continue
    fi

    # AWK: Find first occurrence of rendered block in dest and remove it with blank line cleanup
    if awk -v injfile="$injtmp" '
      BEGIN {
        m = 0;
        while ((getline l < injfile) > 0) {
          m++;
          inj[m] = l;
        }
        close(injfile);
      }
      {
        lines[++n] = $0;
      }
      END {
        pos = 0;
        # Search for block start (first line match of injected content)
        for (i = 1; i <= n; i++) {
          if (m > 0 && lines[i] == inj[1]) {
            # Verify full block match at this position
            ok = 1;
            for (j = 1; j <= m; j++) {
              if (i + j - 1 > n || lines[i + j - 1] != inj[j]) {
                ok = 0;
                break;
              }
            }
            if (ok) {
              pos = i;
            }
          }
        }
        if (pos == 0) {
          # Block not found: output all lines unchanged, signal not-found via exit 1
          for (i = 1; i <= n; i++) print lines[i];
          exit 1;
        }
        # Found at pos: output lines before block (trim trailing blanks), then lines after
        last = pos - 1;
        while (last > 0 && lines[last] == "") last--;
        for (i = 1; i <= last; i++) print lines[i];
        rem = pos + m;
        if (rem <= n) {
          # Output single blank separator and remaining lines after block
          print "";
          for (i = rem; i <= n; i++) print lines[i];
        }
      }
    ' "$dest" > "$tmpout" 2>/dev/null; then
      # Block found and removed; atomically replace dest
      if mv -f "$tmpout" "$dest" 2>/dev/null; then
        break
      fi
    else
      status=$?
      rm -f "$tmpout" 2>/dev/null || :
      if [ "$status" -gt 1 ]; then
        # Fatal error (template parse failed, not just block-not-found)
        rm -f "$injtmp" 2>/dev/null || :
        return 1
      fi
      # status == 1 means template block not found; try next variant
    fi
  done

  # Clean up temporary files
  rm -f "$injtmp" "$tmpout" "$tmp" 2>/dev/null || :
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
# Args: $1 = node_ip (admin@node_ip will be tested)
# Returns: 0 if "connected" echo received, 1 if SSH fails or no response
test_ssh_connection() {
    local node_ip="$1"
    # Use dbclient (Dropbear SSH client) with private key auth, 5-sec timeout
    if dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "echo connected" 2>/dev/null | grep -q "connected"; then
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
    
    # Validate SSH connectivity before attempting command execution
    if ! test_ssh_connection "$node_ip"; then
        error -c cli,vlan "SSH connection failed to $node_ip"
        return 1
    fi
    
    info -c cli,vlan "Running '$cmd' on $node_ip via SSH..."
    # Execute command on node with MERV_NODE_CONTEXT=1 (forces local node execution)
    if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 ./mervlan_boot.sh '$cmd'" 2>&1; then
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
  # Batch operation to remove injected blocks
    local cmd="$1"
  # Check override flag: skip node propagation entirely if set
  if [ "${MERV_SKIP_NODE_SYNC:-0}" = "1" ]; then
    info -c cli,vlan "Skipping node propagation for '$cmd' (MERV_SKIP_NODE_SYNC=1)"
    return 0
  fi
    local NODE_IPS=$(get_node_ips)
    
    if [ -z "$NODE_IPS" ]; then
        return 0  # No nodes configured; skip propagation silently
    fi
    
    info -c cli,vlan "Propagating '$cmd' to nodes: $(echo "$NODE_IPS" | tr '\n' ' ')"
      # Function to remove injected blocks
    
    local overall_success=true
    # Execute action on each node, continue even if some fail
    for node_ip in $NODE_IPS; do
        if ! run_ssh_command "$node_ip" "$cmd"; then
            overall_success=false
        fi
    done
    
    if [ "$overall_success" = "true" ]; then
        info -c cli,vlan "✓ All nodes processed successfully for '$cmd'"
    else
              # Remove injected block previously added by copy_inject
        warn -c cli,vlan "⚠️  Some nodes failed for '$cmd'"
    fi
}

# collect_node_status — Quietly poll all nodes via report action for status aggregation
# Args: none (reads NODE_IPS from get_node_ips)
# Sets: $NODE_STATUS_OUTPUT global (space-separated "ip:status" pairs)
# Returns: none (always succeeds, unreachable nodes marked as such)
# Context: Used by status action to aggregate node state without verbose per-node logs
collect_node_status() {
  local NODE_IPS=$(get_node_ips)
  [ -z "$NODE_IPS" ] && return 0
  NODE_STATUS_OUTPUT=""
  # Poll each node for its report output (minimal logging)
  for node_ip in $NODE_IPS; do
    # Attempt lightweight status fetch via internal 'report' action (no logging output)
    if dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "cd '$MERV_BASE/functions' && ./mervlan_boot.sh report" 2>/dev/null; then
      # Extract report line (format: REPORT boot=1 event=active addon=active cron=absent)
      ns=$(dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "cd '$MERV_BASE/functions' && ./mervlan_boot.sh report" 2>/dev/null | tail -1)
      # Fallback if report returns empty or malformed
      [ -n "$ns" ] || ns="REPORT error=empty"
      # Append to global: format "ip:boot=X event=Y addon=Z cron=W"
      NODE_STATUS_OUTPUT="$NODE_STATUS_OUTPUT $node_ip:${ns#REPORT }"
    else
      # Mark unreachable nodes for aggregation
      NODE_STATUS_OUTPUT="$NODE_STATUS_OUTPUT $node_ip:unreachable"
    fi
  done
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
    copy_inject "$TPL_SERVICES" "$SERVICES_START" || { error -c vlan,cli "Failed to install services-start"; exit 1; }
    info -c vlan,cli "Installed services-start with MERV_BASE=$MERV_BASE (service-event managed at setup)"

    # Create boot flag directory and set enabled state (1 = enabled)
    mkdir -p "$FLAGDIR"
    echo 1 > "$BOOT_FLAG"

    # Cron support removed — nothing to enable here

    # Propagate enable action to all configured nodes via SSH
    handle_nodes_via_ssh "enable"
    ;;

  # =============================================================================== #
  # disable — Disable boot; remove services-start injection but keep service-event  #
  # =============================================================================== #
  disable)
    # Remove injected services-start code (idempotent; no-op if not found)
    if [ -f "$SERVICES_START" ]; then
      remove_inject "$TPL_SERVICES" "$SERVICES_START" || warn -c vlan,cli "Failed to remove injected services-start content"
    fi

    # Create boot flag directory and set disabled state (0 = disabled)
    mkdir -p "$FLAGDIR"
    echo 0 > "$BOOT_FLAG"

    info -c vlan,cli "Removed services-start injection (service-event unchanged)"
    
    # Propagate disable action to all configured nodes via SSH
    handle_nodes_via_ssh "disable"
    ;;

  # ========================================================================== #
  # setupenable — Setup-only: install service-event wrapper on main router     #
  # ========================================================================== #
  setupenable)
    # Ensure /jffs/scripts directory exists
    mkdir -p "$SCRIPTS_DIR"
    # Inject service-event wrapper into system rc_service handler
    copy_inject "$TPL_EVENT" "$SERVICE_EVENT_WRAPPER" || { error -c vlan,cli "Failed to install service-event"; exit 1; }
    # Inject addon boot entry into services-start (for addon install.sh auto-load)
    copy_inject "$TPL_ADDON" "$SERVICES_START" || { error -c vlan,cli "Failed to install addon boot entry"; exit 1; }
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
      remove_inject "$TPL_EVENT" "$SERVICE_EVENT_WRAPPER" || warn -c vlan,cli "Failed to remove injected service-event content"
      info -c vlan,cli "Removed service-event injection (setup-only disable)"
    else
      info -c vlan,cli "service-event not present; nothing to disable"
    fi
    # Remove injected addon boot entry from services-start (idempotent)
    if [ -f "$SERVICES_START" ]; then
      remove_inject "$TPL_ADDON" "$SERVICES_START" || warn -c vlan,cli "Failed to remove addon boot entry"
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
    # Execute locally on this node if MERV_NODE_CONTEXT=1 (SSH propagation) or force_local=1
    if [ "${MERV_NODE_CONTEXT:-0}" = "1" ] || [ "$force_local" = "1" ]; then
      mkdir -p "$SCRIPTS_DIR"
      # Install node service-event handler (mervlan_boot.sh for nodes)
      copy_inject "$TPL_EVENT_NODES" "$SERVICE_EVENT_HANDLER" \
        || { error -c vlan,cli "Failed to install node mervlan_boot.sh"; exit 1; }
      # Install node service-event wrapper
      copy_inject "$TPL_EVENT" "$SERVICE_EVENT_WRAPPER" \
        || { error -c vlan,cli "Failed to install node service-event"; exit 1; }
      # Set executable permissions on installed scripts
      chmod 755 "$SERVICE_EVENT_WRAPPER" "$BOOT_SCRIPT" 2>/dev/null \
        || { warn -c vlan,cli "Could not chmod 755 $SERVICE_EVENT_WRAPPER"; exit 1; }

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
    # Execute locally on this node if MERV_NODE_CONTEXT=1 (SSH propagation) or force_local=1
    if [ "${MERV_NODE_CONTEXT:-0}" = "1" ] || [ "$force_local" = "1" ]; then
      # Remove node service-event wrapper injection if present
      if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
        remove_inject "$TPL_EVENT" "$SERVICE_EVENT_WRAPPER" \
        || { error -c vlan,cli "Failed to remove node service-event"; exit 1; }
      else
        info -c vlan,cli "service-event not present on node; nothing to disable"
      fi
      # Remove addon boot entry from services-start if present
      if [ -f "$SERVICES_START" ]; then
        remove_inject "$TPL_SERVICES" "$SERVICES_START" \
          || warn -c vlan,cli "Failed to remove addon boot entry"
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

    # Check if boot flag exists and is set to "1" (enabled state)
    [ -f "$BOOT_FLAG" ] && [ "$(cat "$BOOT_FLAG" 2>/dev/null)" = "1" ] && boot_state=enabled

    # Check if addon install.sh entry exists in services-start
    if [ -f "$SERVICES_START" ] && grep -q "/jffs/addons/mervlan/install.sh" "$SERVICES_START" 2>/dev/null; then
      addon_state=active
    fi

    # Check if service-event wrapper is present and examine its state
    if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
      # Determine event state: disabled/active/custom based on grep patterns
      if grep -q "service-event disabled" "$SERVICE_EVENT_WRAPPER"; then
        event_state=disabled
      elif grep -q "functions/vlan_boot_event.sh" "$SERVICE_EVENT_WRAPPER"; then
        event_state=active
      else
        event_state=custom
      fi
    fi

    # Cron support removed; cron_state remains 'absent'

    # Get list of configured nodes for status aggregation
    NODE_IPS=$(get_node_ips)
    if [ -n "$NODE_IPS" ]; then
      # Query nodes for their status via report action
      collect_node_status
      # Output combined status with node results
      info -c vlan,cli "Status: boot=$boot_state addon=$addon_state service-event=$event_state cron=$cron_state nodes:${NODE_STATUS_OUTPUT:- none}"
    else
      # No nodes configured; output local status only
      info -c vlan,cli "Status: boot=$boot_state addon=$addon_state service-event=$event_state cron=$cron_state (no nodes configured)"
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
    # Check boot flag and set boot_state to 1 if enabled
    if [ -f "$BOOT_FLAG" ] && [ "$(cat "$BOOT_FLAG" 2>/dev/null)" = "1" ]; then boot_state=1; fi
    # Check for addon install.sh entry in services-start
    if [ -f "$SERVICES_START" ] && grep -q "/jffs/addons/mervlan/install.sh" "$SERVICES_START" 2>/dev/null; then addon_state=active; fi
    # Check service-event wrapper and determine state: disabled/active/custom
    if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
      if grep -q "service-event disabled" "$SERVICE_EVENT_WRAPPER"; then event_state=disabled; elif grep -q "functions/vlan_boot_event.sh" "$SERVICE_EVENT_WRAPPER"; then event_state=active; else event_state=custom; fi
    fi
    # Cron support removed; cron_state remains 'absent'
    cron_line=""
    # Output terse report line: REPORT boot=0/1 addon=<state> event=<state> cron=<state>
    # Used by collect_node_status() for remote aggregation via SSH
    echo "REPORT boot=$boot_state addon=$addon_state event=$event_state cron=$cron_state"
    exit 0
    ;;

  # ========================================================================== #
  # * — Default: unrecognized action or missing argument                       #
  # ========================================================================== #
  *)
    # Display usage information and exit with error code
    echo "Usage: $0 {enable|disable|status|setupenable|setupdisable|nodeenable|nodedisable|report}" >&2
    exit 2
    ;;
esac