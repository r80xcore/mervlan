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
#                - File: collect_local_clients.sh || version: 0.45             #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Collect VLAN→client info via bridge FDB (MAC-only) on local    #
#               node so it can be collected by collect_clients.sh.             #
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

OUT="${1:-$COLLECTDIR/clients_local.json}"
NODE_NAME="${2:-$(hostname)}"
RESOLVE_HOSTNAMES="${RESOLVE_HOSTNAMES:-0}"

# FDB read retry knobs (can be overridden via environment)
FDB_RETRIES="${FDB_RETRIES:-3}"
FDB_RETRY_SLEEP="${FDB_RETRY_SLEEP:-1}"

info -c vlan "Collecting VLAN clients (MAC-only) on $NODE_NAME"
info -c cli  "Collecting VLAN clients (MAC-only) on $NODE_NAME"

# --- Helpers ---
json_escape() { echo "$1" | sed -e 's/\\/\\\\/g' -e 's/\"/\\\"/g'; }

# Only VLAN bridges br[0-9]+; exclude br0; numeric sort without -V
get_bridges() {
  ls /sys/class/net/ 2>/dev/null \
    | grep -E '^br[0-9]+$' \
    | grep -v '^br0$' \
    | sed 's/^br//' \
    | sort -n \
    | sed 's/^/br/'
}

# Non-local MACs learned on this bridge (column 2 where local=no)
collect_macs_for_bridge() {
  local bridge="$1" out="$2" i=0 tmp="$out.tmp"
  : > "$tmp"
  while [ $i -lt "$FDB_RETRIES" ]; do
    brctl showmacs "$bridge" 2>/dev/null | awk '$3=="no"{print tolower($2)}' >> "$tmp"
    i=$((i+1))
    [ $i -lt "$FDB_RETRIES" ] && sleep "$FDB_RETRY_SLEEP"
  done
  sort -u "$tmp" > "$out"
  rm -f "$tmp"
}

# --- Main JSON Output ---
DATE_NOW=$(date +'%Y-%m-%dT%H:%M:%S')

{
  echo "{"
  printf '  "generated": "%s",\n' "$DATE_NOW"
  printf '  "router": "%s",\n' "$(json_escape "$NODE_NAME")"
  echo '  "vlans": ['
} > "$OUT"

FIRST_VLAN=true
TOTAL_COUNT=0
mkdir -p "$COLLECTDIR" 2>/dev/null

# Clean previous per-bridge temp lists to avoid stale merges
rm -f "$COLLECTDIR"/mac_br*.lst "$COLLECTDIR"/mac_exclude.lst 2>/dev/null

BR_LIST="$(get_bridges)"

# First pass: gather MACs per bridge
for BR in $BR_LIST; do
  MACS_FILE="$COLLECTDIR/mac_${BR}.lst"
  collect_macs_for_bridge "$BR" "$MACS_FILE"
done

# Exclude MACs seen on >=2 bridges (likely upstream/parent)
EXC_FILE="$COLLECTDIR/mac_exclude.lst"
cat "$COLLECTDIR"/mac_br*.lst 2>/dev/null | awk 'NF' | sort | uniq -c | awk '$1>=2 {print $2}' > "$EXC_FILE"

# Emit JSON per VLAN
for BR in $BR_LIST; do
  VLAN_ID="${BR#br}"
  MACS_FILE="$COLLECTDIR/mac_${BR}.lst"
  # Open object (always include VLAN, even if no clients)
  if [ "$FIRST_VLAN" = true ]; then FIRST_VLAN=false; else echo ',' >> "$OUT"; fi
  {
    echo '    {'
    printf '      "id": "%s",\n' "$VLAN_ID"
    echo '      "clients": ['
  } >> "$OUT"

  FIRST_CLIENT=true
  VLAN_CLIENTS=0
  while read -r MAC; do
    # skip excluded (upstream)
    if [ -s "$EXC_FILE" ] && grep -q "^$MAC$" "$EXC_FILE" 2>/dev/null; then
      continue
    fi
    if [ "$FIRST_CLIENT" = true ]; then FIRST_CLIENT=false; else echo ',' >> "$OUT"; fi
    printf '        {"mac": "%s"}' "$MAC" >> "$OUT"
    echo "" >> "$OUT"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    VLAN_CLIENTS=$((VLAN_CLIENTS + 1))
  done < "$MACS_FILE"

  {
    echo '      ]'
    echo -n '    }'
  } >> "$OUT"

  info -c cli "VLAN $VLAN_ID: $VLAN_CLIENTS clients"
done

# Close JSON
{
  echo
  echo '  ]'
  echo '}'
} >> "$OUT"

if [ "$TOTAL_COUNT" -eq 0 ]; then
  info -c vlan "No active clients found on $NODE_NAME"
  info -c cli  "No active clients found on $NODE_NAME"
else
  info -c vlan "Found $TOTAL_COUNT clients on $NODE_NAME"
  info -c cli  "Found $TOTAL_COUNT clients on $NODE_NAME"
fi

exit 0