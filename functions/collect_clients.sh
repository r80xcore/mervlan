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
#                - File: collect_clients.sh || version="0.45"                  #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Orchestrate collection of VLAN bridges and client MAC          # 
#               addresses from main and nodes to be stored in JSON format      #
#               so they can be read by the MerVLAN GUI.                        #
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

TIMEOUT=10

info -c cli,vlan "=== VLAN Client Collection Started ==="

# Prepare dirs
mkdir -p "$COLLECTDIR" "$RESULTDIR"

# Clear previous results
if [ -f "$OUT_FINAL" ]; then
  rm -f "$OUT_FINAL"
  info -c cli,vlan "Cleared previous results at $OUT_FINAL"
fi

# ---- helpers ----
get_node_ips() {
  grep -o '"NODE[1-5]"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" \
    | sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -v "none" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

test_ssh_connection() {
  local node_ip="$1"
  dbclient -y -i "$SSH_KEY" -o ConnectTimeout=5 -o PasswordAuthentication=no "admin@$node_ip" "echo connected" 2>/dev/null | grep -q "connected"
}

# Collect JSON from a node; always write a JSON file (even on error)
collect_from_node() {
  local node_ip="$1"
  local output_file="$2"

  info -c cli,vlan "→ Collecting from node $node_ip"

  # Reachability
  if ! ping -c 1 -W 3 "$node_ip" >/dev/null 2>&1; then
    warn -c cli,vlan "Node $node_ip is not reachable via ping"
    printf '{"router":"%s","error":"unreachable","vlans":[]}' "$node_ip" > "$output_file"
    return 1
  fi

  # SSH
  if ! test_ssh_connection "$node_ip"; then
    warn -c cli,vlan "SSH connection failed to $node_ip"
    printf '{"router":"%s","error":"ssh-failed","vlans":[]}' "$node_ip" > "$output_file"
    return 1
  fi

  # Run remote collector and fetch JSON in one shot
  # Path is the same as synced by actions/sync_nodes.sh: $[collect_local_clients.sh](http://_vscodecontentref_/2)
  # Prefer local timeout if available, otherwise run without it (dbclient has its own ConnectTimeout)
  if command -v timeout >/dev/null 2>&1; then
    if timeout "$TIMEOUT" dbclient -y -i "$SSH_KEY" "admin@$node_ip" \
         "$MERV_BASE/functions/collect_local_clients.sh /tmp/node_clients.json \"$node_ip\" >/dev/null 2>&1 && cat /tmp/node_clients.json" \
         > "$output_file" 2>/dev/null; then
      info -c cli,vlan "✓ Successfully collected from $node_ip"
      return 0
    else
      warn -c cli,vlan "Failed to fetch results from $node_ip"
      printf '{"router":"%s","error":"fetch-failed","vlans":[]}' "$node_ip" > "$output_file"
      return 1
    fi
  else
    if dbclient -y -i "$SSH_KEY" "admin@$node_ip" \
         "$MERV_BASE/functions/collect_local_clients.sh /tmp/node_clients.json \"$node_ip\" >/dev/null 2>&1 && cat /tmp/node_clients.json" \
         > "$output_file" 2>/dev/null; then
      info -c cli,vlan "✓ Successfully collected from $node_ip"
      return 0
    else
      warn -c cli,vlan "Failed to fetch results from $node_ip"
      printf '{"router":"%s","error":"fetch-failed","vlans":[]}' "$node_ip" > "$output_file"
      return 1
    fi
  fi
}

# ---- main router JSON ----
info -c cli,vlan "Collecting clients from main router (JSON)..."
"$FUNCDIR/collect_local_clients.sh" "$COLLECTDIR/main.json" "Main Router"
if [ $? -eq 0 ]; then
  info -c cli,vlan "✓ Main router collection completed"
else
  error -c cli,vlan "✗ Main router collection failed"
fi

# ---- nodes ----
NODE_IPS=$(get_node_ips)
if [ -z "$NODE_IPS" ]; then
  info -c cli,vlan "No nodes configured in settings.json"
  NODES_ENABLED=false
else
  NODES_ENABLED=true
  info -c cli,vlan "Found configured nodes: $(echo "$NODE_IPS" | tr '\n' ' ')"

  # Check SSH keys present and marked installed in hw_settings.json
  if [ ! -f "$SSH_KEY" ] || [ ! -f "$SSH_PUBKEY" ]; then
    warn -c cli,vlan "SSH keys not found - only collecting from main router"
    NODES_ENABLED=false
  elif ! grep -q '"SSH_KEYS_INSTALLED"[[:space:]]*:[[:space:]]*"1"' "$GENERAL_SETTINGS_FILE" 2>/dev/null; then
    warn -c cli,vlan "SSH keys not installed according to hw_settings.json"
    NODES_ENABLED=false
  fi
fi

if [ "$NODES_ENABLED" = "true" ]; then
  for node_ip in $NODE_IPS; do
    collect_from_node "$node_ip" "$COLLECTDIR/node_${node_ip}.json" &
  done
  info -c cli,vlan "Waiting for node collections to complete..."
  wait
  info -c cli,vlan "All node collections finished"
fi

# ---- merge to one JSON ----
info -c cli,vlan "Merging JSON results..."
DATE_NOW=$(date +'%Y-%m-%dT%H:%M:%S')

{
  echo "{"
  echo "  \"generated\": \"$DATE_NOW\","
  echo "  \"nodes\": ["

  FIRST=1
  for json_file in "$COLLECTDIR/main.json" "$COLLECTDIR"/node_*.json; do
    [ -f "$json_file" ] || continue
    if [ $FIRST -eq 1 ]; then FIRST=0; else echo ","; fi
    sed 's/^/    /' "$json_file"
  done

  echo "  ]"
  echo "}"
} > "$OUT_FINAL"

# Cleanup
rm -rf "$COLLECTDIR"

info -c cli,vlan "✓ Client collection completed - JSON saved to $OUT_FINAL"
info -c cli,vlan "=== VLAN Client Collection Finished ==="
exit 0