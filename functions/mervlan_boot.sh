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
#                - File: mervlan_boot.sh || version="0.45"                     #
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

# ================================================= MerVLAN Boot Configuration #
BOOT_FLAG="$FLAGDIR/boot_enabled"
ACTION="$1"
VLAN_RUN_LINE="$MERV_BASE/functions/vlan_manager.sh"
TAG="# ENABLE MERVLAN BOOT"
EVENT_TAG="# MERVLAN MANAGER SERVICE-EVENT"
INJ_BASE="${MERV_BASE%/}"
# ========================================== End of MerVLAN Boot Configuration #

# Cron support removed: no enable/disable functions should remain.

render_template_variant() {
  # $1=template path, $2=variant id, $3=output file, $4=resolved MERV_BASE
  local template="${1}" variant="${2}" output="${3}" inj="${4}" raw status

  raw="${output}.raw"
  [ -n "$variant" ] || variant="1"

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

  if ! sed "s|MERV_BASE_PLACEHOLDER|$inj|g" "$raw" > "$output" 2>/dev/null; then
    rm -f "$raw" "$output" 2>/dev/null || :
    return 1
  fi

  rm -f "$raw" 2>/dev/null || :
  return 0
}

copy_inject() {
  # $1=template $2=dest
  local tmpl dest inj tmp injtmp combtmp
  tmpl="$1"; dest="$2"
  [ -f "$tmpl" ] || { error -c vlan,cli "Template missing: $tmpl"; return 1; }

  inj="${MERV_BASE%/}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/merv_inj.XXXXXX" 2>/dev/null || printf '%s/merv_inj.%s' "${TMPDIR:-/tmp}" "$$")"
  injtmp="${tmp}.inj"
  combtmp="${tmp}.combined"

  local variant="1"
  if [ -f "$dest" ] && [ -s "$dest" ] && head -n 1 "$dest" 2>/dev/null | grep -q '^#!'; then
    variant="2"
  fi

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

  # If the rendered block already exists verbatim in dest, skip injection (idempotent)
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
    # Create a new file containing dest without trailing blank lines,
    # then add exactly one blank line followed by the injected content.
    if ! awk '{ lines[NR] = $0 } END { n = NR; while (n>0 && lines[n]=="") n--; for (i=1;i<=n;i++) print lines[i] }' "$dest" > "$combtmp" 2>/dev/null; then
      rm -f "$injtmp" "$combtmp" 2>/dev/null || :
      return 1
    fi
    # add single blank line separator
    printf '\n' >> "$combtmp"
    cat "$injtmp" >> "$combtmp"
    # atomic replace
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

# Remove injected content that matches rendered template from destination file.
# This will remove the first literal occurrence of the rendered template block
# (assuming copy_inject appended it). It is conservative: if no match is found
# the destination is left untouched.
remove_inject() {
  local tmpl dest inj tmp injtmp tmpout variant
  tmpl="$1"; dest="$2"
  [ -f "$tmpl" ] || { error -c vlan,cli "Template missing: $tmpl"; return 1; }
  [ -f "$dest" ] || return 0

  inj="${MERV_BASE%/}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/merv_rmv.XXXXXX" 2>/dev/null || printf '%s/merv_rmv.%s' "${TMPDIR:-/tmp}" "$$")"
  injtmp="${tmp}.inj"
  tmpout="${tmp}.out"
  rm -f "$tmp" 2>/dev/null || :

  local variants="2 1" status
  if [ ! -s "$dest" ]; then
    variants="1 2"
  fi

  for variant in $variants; do
    if ! render_template_variant "$tmpl" "$variant" "$injtmp" "$inj"; then
      continue
    fi

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
        for (i = 1; i <= n; i++) {
          if (m > 0 && lines[i] == inj[1]) {
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
          for (i = 1; i <= n; i++) print lines[i];
          exit 1;
        }
        last = pos - 1;
        while (last > 0 && lines[last] == "") last--;
        for (i = 1; i <= last; i++) print lines[i];
        rem = pos + m;
        if (rem <= n) {
          print "";
          for (i = rem; i <= n; i++) print lines[i];
        }
      }
    ' "$dest" > "$tmpout" 2>/dev/null; then
      if mv -f "$tmpout" "$dest" 2>/dev/null; then
        break
      fi
    else
      status=$?
      rm -f "$tmpout" 2>/dev/null || :
      if [ "$status" -gt 1 ]; then
        rm -f "$injtmp" 2>/dev/null || :
        return 1
      fi
      # status == 1 means template block not found; try next variant
    fi
  done

  rm -f "$injtmp" "$tmpout" "$tmp" 2>/dev/null || :
  return 0
}

# Function to get node IPs from settings.json (same as sync_nodes.sh)
get_node_ips() {
    grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" | \
    sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
    grep -v "none" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# Function to test SSH connection to a node (same as sync_nodes.sh)
test_ssh_connection() {
    local node_ip="$1"
    if dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "echo connected" 2>/dev/null | grep -q "connected"; then
        return 0
    else
        return 1
    fi
}

# Function to run command on a node via SSH
run_ssh_command() {
    local node_ip="$1"
    local cmd="$2"
    
    if ! test_ssh_connection "$node_ip"; then
        error -c cli,vlan "SSH connection failed to $node_ip"
        return 1
    fi
    
    info -c cli,vlan "Running '$cmd' on $node_ip via SSH..."
  if dbclient -y -i "$SSH_KEY" "admin@$node_ip" "cd '$MERV_BASE/functions' && MERV_NODE_CONTEXT=1 ./mervlan_boot.sh '$cmd'" 2>&1; then
        info -c cli,vlan "✓ Command '$cmd' succeeded on $node_ip"
        return 0
    else
        error -c cli,vlan "✗ Command '$cmd' failed on $node_ip"
        return 1
    fi
}

# Function to handle SSH for all nodes
handle_nodes_via_ssh() {
  # Function to remove injected blocks
    local cmd="$1"
  if [ "${MERV_SKIP_NODE_SYNC:-0}" = "1" ]; then
    info -c cli,vlan "Skipping node propagation for '$cmd' (MERV_SKIP_NODE_SYNC=1)"
    return 0
  fi
    local NODE_IPS=$(get_node_ips)
    
    if [ -z "$NODE_IPS" ]; then
        return 0  # No nodes, skip
    fi
    
    info -c cli,vlan "Propagating '$cmd' to nodes: $(echo "$NODE_IPS" | tr '\n' ' ')"
      # Function to remove injected blocks
    
    local overall_success=true
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

# Collect node status without verbose per-node logs (used by status aggregation)
collect_node_status() {
  local NODE_IPS=$(get_node_ips)
  [ -z "$NODE_IPS" ] && return 0
  NODE_STATUS_OUTPUT=""
  for node_ip in $NODE_IPS; do
    # Attempt a lightweight status fetch via internal 'report' action
    if dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "cd '$MERV_BASE/functions' && ./mervlan_boot.sh report" 2>/dev/null; then
      ns=$(dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "cd '$MERV_BASE/functions' && ./mervlan_boot.sh report" 2>/dev/null | tail -1)
      # Expect format: REPORT boot=1 event=active
      [ -n "$ns" ] || ns="REPORT error=empty"
      NODE_STATUS_OUTPUT="$NODE_STATUS_OUTPUT $node_ip:${ns#REPORT }"
    else
      NODE_STATUS_OUTPUT="$NODE_STATUS_OUTPUT $node_ip:unreachable"
    fi
  done
}

case "$ACTION" in
  enable)
    mkdir -p "$SCRIPTS_DIR"

    # Install templates → /jffs/scripts with MERV_BASE injected
    copy_inject "$TPL_SERVICES" "$SERVICES_START" || { error -c vlan,cli "Failed to install services-start"; exit 1; }
    info -c vlan,cli "Installed services-start with MERV_BASE=$MERV_BASE (service-event managed at setup)"

    # Boot flag
    mkdir -p "$FLAGDIR"
    echo 1 > "$BOOT_FLAG"

    # Cron support removed — nothing to enable here

    # Propagate to nodes
    handle_nodes_via_ssh "enable"
    ;;

  disable)
    # Remove injected content from scripts we installed (do not delete whole files)
    if [ -f "$SERVICES_START" ]; then
      remove_inject "$TPL_SERVICES" "$SERVICES_START" || warn -c vlan,cli "Failed to remove injected services-start content"
    fi

    # Boot flag OFF
    mkdir -p "$FLAGDIR"
    echo 0 > "$BOOT_FLAG"

  info -c vlan,cli "Removed services-start injection (service-event unchanged)"
    
    handle_nodes_via_ssh "disable"
    ;;

  # Setup-only management of service-event wrapper
  setupenable)
    mkdir -p "$SCRIPTS_DIR"
    copy_inject "$TPL_EVENT" "$SERVICE_EVENT_WRAPPER" || { error -c vlan,cli "Failed to install service-event"; exit 1; }
    copy_inject "$TPL_ADDON" "$SERVICES_START" || { error -c vlan,cli "Failed to install addon boot entry"; exit 1; }
    info -c vlan,cli "Installed service-event with MERV_BASE=$MERV_BASE (setup-only)"
    handle_nodes_via_ssh "setupenable"
    ;;

  setupdisable)
    if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
      remove_inject "$TPL_EVENT" "$SERVICE_EVENT_WRAPPER" || warn -c vlan,cli "Failed to remove injected service-event content"
      info -c vlan,cli "Removed service-event injection (setup-only disable)"
    else
      info -c vlan,cli "service-event not present; nothing to disable"
    fi
    if [ -f "$SERVICES_START" ]; then
      remove_inject "$TPL_ADDON" "$SERVICES_START" || warn -c vlan,cli "Failed to remove addon boot entry"
    fi
    handle_nodes_via_ssh "setupdisable"
    ;;
  
  # Node setup-only management of service-event and services-start addon entry
  nodeenable)
    scope="${2:-}"
    force_local=0
    case "$scope" in
      --local|-l|local) force_local=1 ;;
    esac
    if [ "${MERV_FORCE_LOCAL:-0}" = "1" ]; then
      force_local=1
    fi
    if [ "${MERV_NODE_CONTEXT:-0}" = "1" ] || [ "$force_local" = "1" ]; then
      mkdir -p "$SCRIPTS_DIR"
      copy_inject "$TPL_EVENT_NODES" "$SERVICE_EVENT_HANDLER" \
        || { error -c vlan,cli "Failed to install node mervlan_boot.sh"; exit 1; }
      copy_inject "$TPL_EVENT" "$SERVICE_EVENT_WRAPPER" \
        || { error -c vlan,cli "Failed to install node service-event"; exit 1; }
      chmod 755 "$SERVICE_EVENT_WRAPPER" "$BOOT_SCRIPT" 2>/dev/null \
        || { warn -c vlan,cli "Could not chmod 755 $SERVICE_EVENT_WRAPPER"; exit 1; }

      info -c vlan,cli "Installed node mervlan_boot.sh, service-event, services-start with MERV_BASE=$MERV_BASE"
      exit 0
    fi

    NODE_IPS=$(get_node_ips)
    if [ -z "$NODE_IPS" ]; then
      info -c vlan,cli "No nodes configured; skipping nodeenable"
      exit 0
    fi

    NODE_LIST=$(echo "$NODE_IPS" | tr '\n' ' ')
    info -c vlan,cli "Propagating nodeenable to nodes: $NODE_LIST"
    handle_nodes_via_ssh "nodeenable"
    exit 0
    ;;



  nodedisable)
    scope="${2:-}"
    force_local=0
    case "$scope" in
      --local|-l|local) force_local=1 ;;
    esac
    if [ "${MERV_FORCE_LOCAL:-0}" = "1" ]; then
      force_local=1
    fi
    if [ "${MERV_NODE_CONTEXT:-0}" = "1" ] || [ "$force_local" = "1" ]; then
      if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
        remove_inject "$TPL_EVENT" "$SERVICE_EVENT_WRAPPER" \
        || { error -c vlan,cli "Failed to remove node service-event"; exit 1; }
      else
        info -c vlan,cli "service-event not present on node; nothing to disable"
      fi
      if [ -f "$SERVICES_START" ]; then
        remove_inject "$TPL_SERVICES" "$SERVICES_START" \
          || warn -c vlan,cli "Failed to remove addon boot entry"
      fi
      exit 0
    fi

    NODE_IPS=$(get_node_ips)
    if [ -z "$NODE_IPS" ]; then
      info -c vlan,cli "No nodes configured; skipping nodedisable"
      exit 0
    fi

    NODE_LIST=$(echo "$NODE_IPS" | tr '\n' ' ')
    info -c vlan,cli "Propagating nodedisable to nodes: $NODE_LIST"
    handle_nodes_via_ssh "nodedisable"
    exit 0
    ;;


  status)
    boot_state=disabled
    addon_state=missing
    event_state=missing
    cron_state=absent

    [ -f "$BOOT_FLAG" ] && [ "$(cat "$BOOT_FLAG" 2>/dev/null)" = "1" ] && boot_state=enabled

    if [ -f "$SERVICES_START" ] && grep -q "/jffs/addons/mervlan/install.sh" "$SERVICES_START" 2>/dev/null; then
      addon_state=active
    fi

    if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
      if grep -q "service-event disabled" "$SERVICE_EVENT_WRAPPER"; then
        event_state=disabled
      elif grep -q "functions/vlan_boot_event.sh" "$SERVICE_EVENT_WRAPPER"; then
        event_state=active
      else
        event_state=custom
      fi
    fi

    # Cron support removed; cron_state remains 'absent'

    NODE_IPS=$(get_node_ips)
    if [ -n "$NODE_IPS" ]; then
      collect_node_status
      info -c vlan,cli "Status: boot=$boot_state addon=$addon_state service-event=$event_state cron=$cron_state nodes:${NODE_STATUS_OUTPUT:- none}"
    else
      info -c vlan,cli "Status: boot=$boot_state addon=$addon_state service-event=$event_state cron=$cron_state (no nodes configured)"
    fi
    ;;


  report)
  # Internal terse report for remote aggregation (stdout only, no log function)
  boot_state=0
  addon_state=missing
  event_state=missing
  cron_state=absent
  if [ -f "$BOOT_FLAG" ] && [ "$(cat "$BOOT_FLAG" 2>/dev/null)" = "1" ]; then boot_state=1; fi
  if [ -f "$SERVICES_START" ] && grep -q "/jffs/addons/mervlan/install.sh" "$SERVICES_START" 2>/dev/null; then addon_state=active; fi
  if [ -f "$SERVICE_EVENT_WRAPPER" ]; then
    if grep -q "service-event disabled" "$SERVICE_EVENT_WRAPPER"; then event_state=disabled; elif grep -q "functions/vlan_boot_event.sh" "$SERVICE_EVENT_WRAPPER"; then event_state=active; else event_state=custom; fi
  fi
    cron_line=""
  # Cron support removed; cron_state remains 'absent'
  echo "REPORT boot=$boot_state addon=$addon_state event=$event_state cron=$cron_state"
    exit 0
    ;;

  *)
echo "Usage: $0 {enable|disable|status|setupenable|setupdisable|nodeenable|nodedisable|report}" >&2
    exit 2
    ;;
esac