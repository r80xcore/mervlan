#!/bin/sh
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
#               - File: mervlan_trunk.sh || version="0.50"                     #
# ──────────────────────────────────────────────────────────────────────────── #
# ───── MerVLAN environment bootstrap ─────
: "${MERV_BASE:=/jffs/addons/mervlan}"

if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED LIB_DEBUG_LOADED
fi

[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_DEBUG_LOADED:-}" ] || . "$MERV_BASE/settings/lib_debug.sh"

DBG_CHANNEL="vlan,cli"
: "${DBG_PREFIX:=[DEBUG]}"

# Settings file is set by var_settings.sh
# SETTINGS_FILE="${SETTINGS_FILE:-$MERV_BASE/settings/settings.json}"

DRY_RUN_FORCED=0
DEBUG_FORCED=0
ERROR_SEEN=0

ORIGINAL_ARGS="$*"

# ───── CLI arg parsing: dryrun + debug ─────
while [ "$#" -gt 0 ]; do
  case "$1" in
    dryrun|--dry-run|-n)
      DRY_RUN="yes"
      DRY_RUN_FORCED=1
      shift
      ;;
    debug|--debug|-d)
      DEBUG=1
      DEBUG_FORCED=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [ -z "${DRY_RUN:-}" ]; then
  DRY_RUN="$(json_get_flag "DRY_RUN" "yes" "$SETTINGS_FILE" 2>/dev/null)"
fi
[ -z "$DRY_RUN" ] && DRY_RUN="yes"

if [ "$DEBUG_FORCED" -eq 1 ]; then
  debug_enable
else
  debug_init_from_json "TRUNK_DEBUG" "0"
fi

if [ ! -f "$SETTINGS_FILE" ]; then
  warn -c vlan,cli "Settings file $SETTINGS_FILE missing; trunk values will default"
fi

UPLINK_PORT="${UPLINK_PORT:-eth0}"
DEFAULT_BRIDGE="${DEFAULT_BRIDGE:-$(json_get_flag "DEFAULT_UNTAGGED_BRIDGE" "br0" "$SETTINGS_FILE" 2>/dev/null)}"
[ -n "$DEFAULT_BRIDGE" ] || DEFAULT_BRIDGE="br0"
MAX_TRUNKS="${MAX_TRUNKS:-3}"

# Validate mandatory environment (manager should provide these)
if [ -z "$UPLINK_PORT" ]; then
  error -c vlan,cli "UPLINK_PORT not set; trunk script requires UPLINK_PORT"
  exit 1
fi
if [ -z "$DEFAULT_BRIDGE" ]; then
  error -c vlan,cli "DEFAULT_BRIDGE not set; trunk script requires DEFAULT_BRIDGE"
  exit 1
fi
case "$MAX_TRUNKS" in ''|*[!0-9]*) MAX_TRUNKS=3 ;; esac

dbg_log "mervlan_trunk.sh invoked with args: ${ORIGINAL_ARGS}"
dbg_var DRY_RUN DRY_RUN_FORCED DEBUG DEBUG_FORCED UPLINK_PORT DEFAULT_BRIDGE MAX_TRUNKS SETTINGS_FILE

run_cmd() {
  if [ "$DRY_RUN" = "yes" ]; then
    info -c vlan,cli "[DRY-RUN] $*"
    return 0
  fi
  "$@" 2>/dev/null
}

# Debug: log a filtered snapshot of the bridge table containing the iface
log_bridge_membership() {
  # quiet when debug is off
  debug_is_enabled || return 0
  local ifc="$1" out
  [ -n "$ifc" ] || return 0

  # Show only the header and lines where the interface name occurs to avoid
  # dumping the entire bridge table (can be very noisy on busy systems).
  out=$(brctl show 2>/dev/null | awk -v IF="$ifc" 'NR==1{print; next} index($0,IF){print}') || out=""

  [ -n "$out" ] && dbg_log "Bridge table snapshot (filtered) for $ifc:" && dbg_log "$out"
}

# ───── Low level helpers ─────
iface_exists() { [ -d "/sys/class/net/$1" ]; }

ensure_port_up() {
  local ifc="$1"
  iface_exists "$ifc" || return 1
  run_cmd ip link set "$ifc" up
}

ensure_vlan_iface() {
  local ifc="$1" vid="$2"
  iface_exists "$ifc" || return 1
  iface_exists "${ifc}.${vid}" || {
    run_cmd ip link add link "$ifc" name "${ifc}.${vid}" type vlan id "$vid" || return 1
  }
  run_cmd ip link set "${ifc}.${vid}" up
}

ensure_vlan_bridge() {
  local vid="$1" uplink_vlan="${UPLINK_PORT}.${vid}" br="br${vid}"

  # Validate uplink port present
  iface_exists "$UPLINK_PORT" || { error -c vlan,cli "ensure_vlan_bridge: uplink $UPLINK_PORT missing"; return 1; }
  ensure_port_up "$UPLINK_PORT" || { error -c vlan,cli "ensure_vlan_bridge: cannot bring uplink $UPLINK_PORT up"; return 1; }

  # Create VLAN sub-interface on uplink only if it doesn't exist
  if ! iface_exists "$uplink_vlan"; then
    if ! run_cmd ip link add link "$UPLINK_PORT" name "$uplink_vlan" type vlan id "$vid"; then
      error -c vlan,cli "ensure_vlan_bridge: failed to create $uplink_vlan"
      return 1
    fi
  fi
  run_cmd ip link set "$uplink_vlan" up || { error -c vlan,cli "ensure_vlan_bridge: failed to set $uplink_vlan up"; return 1; }

  # Create bridge only if missing (idempotent and additive)
  if ! brctl show 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$br"; then
    if ! run_cmd brctl addbr "$br"; then
      error -c vlan,cli "ensure_vlan_bridge: failed to create bridge $br"
      return 1
    fi
    run_cmd ip link set "$br" up || warn -c vlan,cli "ensure_vlan_bridge: failed to set $br up"
  fi

  # Ensure uplink vlan is a member of the bridge (single brctl call for membership)
  members=$(brctl show "$br" 2>/dev/null | awk '{for (i=4;i<=NF;i++) print $i}')
  if ! printf '%s
' "$members" | grep -qx "$uplink_vlan"; then
    if ! run_cmd brctl addif "$br" "$uplink_vlan"; then
      error -c vlan,cli "ensure_vlan_bridge: failed to add $uplink_vlan to $br"
      return 1
    fi
  fi

  dbg_log "ensure_vlan_bridge: $br ready with uplink $uplink_vlan"

  # Ensure STP disabled and forwarding delay is zero (idempotent)
  run_cmd brctl stp "$br" off || :
  run_cmd brctl setfd "$br" 0 || :
}

bridge_add_if() {
  local br="$1" ifc="$2"
  iface_exists "$ifc" || return 1
  ensure_port_up "$ifc"
  brctl show "$br" 2>/dev/null | awk '{for (i=4;i<=NF;i++) print $i}' | grep -qx "$ifc" && return 0
  if ! run_cmd brctl addif "$br" "$ifc"; then
    error -c vlan,cli "bridge_add_if: failed to add $ifc to $br"
    return 1
  fi
}

bridge_del_if() {
  local br="$1" ifc="$2"
  brctl show "$br" 2>/dev/null | awk '{for (i=4;i<=NF;i++) print $i}' | grep -qx "$ifc" || return 0
  if ! run_cmd brctl delif "$br" "$ifc"; then
    warn -c vlan,cli "bridge_del_if: failed to remove $ifc from $br"
    return 1
  fi
}

parse_vlan_list() {
  local raw="$1"
  local vid

  [ -n "$raw" ] || return 0
  [ "$raw" = "none" ] && return 0

  printf '%s\n' "$raw" | tr ',;' ' ' | tr -s ' ' | tr ' ' '\n' | while read -r vid; do
    [ -n "$vid" ] || continue
    case "$vid" in
      *[!0-9]*) continue ;;
    esac
    if [ "$vid" -ge 2 ] 2>/dev/null && [ "$vid" -le 4094 ] 2>/dev/null; then
      printf '%s ' "$vid"
    fi
  done
}

get_trunk_port() {
  local idx="$1" raw num

  # Read TRUNKx as integer. -1 means "missing".
  raw="$(json_get_int "TRUNK${idx}" -1 "$SETTINGS_FILE" 2>/dev/null)"
  dbg_log "trunk${idx}: primary key lookup returned '${raw}'"
  dbg_var raw
  if [ "$raw" -lt 0 ] 2>/dev/null; then
    # Fallback to lowercase key if that ever appears
    raw="$(json_get_int "trunk${idx}" -1 "$SETTINGS_FILE" 2>/dev/null)"
    dbg_log "trunk${idx}: lowercase fallback returned '${raw}'"
    dbg_var raw
  fi

  # If still negative, key truly missing → disabled
  if [ "$raw" -lt 0 ] 2>/dev/null; then
    dbg_log "trunk${idx}: key not found, treating as disabled"
    return 1
  fi

  num="$raw"
  dbg_var num

  case "$num" in
    0)
      dbg_log "trunk${idx}: value=0, interpreted as disabled"
      return 1
      ;;
    1)
      dbg_log "trunk${idx}: value=1, interpreted as enabled on eth${idx}"
      printf 'eth%s\n' "$idx"
      return 0
      ;;
  esac

  # Any other positive integer → interpret as eth<num>
  if printf '%s\n' "$num" | grep -Eq '^[0-9]+$'; then
    dbg_log "trunk${idx}: integer '${num}', interpreted as eth${num}"
    printf 'eth%s\n' "$num"
    return 0
  fi

  dbg_log "trunk${idx}: unrecognized numeric '${num}', treating as disabled"
  return 1
}



get_trunk_config() {
  local idx="$1" tagged_key="TAGGED_TRUNK${idx}" untagged_key="UNTAGGED_TRUNK${idx}"
  local tagged_raw untagged_raw

  tagged_raw="$(json_get_flag "$tagged_key" "none" "$SETTINGS_FILE" 2>/dev/null)"
  untagged_raw="$(json_get_flag "$untagged_key" "none" "$SETTINGS_FILE" 2>/dev/null)"

  dbg_log "trunk${idx}: resolved tagged/untagged payloads"
  dbg_var tagged_raw untagged_raw

  printf 'tagged=%s untagged=%s\n' "$tagged_raw" "$untagged_raw"
}

configure_trunk() {
  local idx="$1" port cfg tagged_raw untagged_raw uvid vid

  port="$(get_trunk_port "$idx")" || {
    info -c vlan,cli "trunk${idx}: disabled"
    return 0
  }

  ensure_port_up "$port" || {
    warn -c vlan,cli "trunk${idx}: $port missing"
    ERROR_SEEN=1
    return 1
  }

  cfg="$(get_trunk_config "$idx")"
  tagged_raw="${cfg#tagged=}"
  tagged_raw="${tagged_raw% untagged=*}"
  untagged_raw="${cfg##* untagged=}"

  dbg_log "trunk${idx}: effective configuration after parsing"
  dbg_var port tagged_raw untagged_raw

  info -c vlan,cli "trunk${idx}: port=$port tagged=${tagged_raw} untagged=${untagged_raw}"

  # Helpful bridge membership snapshot when debugging
  log_bridge_membership "$port"

  if [ "$untagged_raw" = "none" ]; then
    # Keep physical port attached to default bridge
    bridge_add_if "$DEFAULT_BRIDGE" "$port" || warn -c vlan,cli "trunk${idx}: failed to ensure $port on $DEFAULT_BRIDGE"
    info -c vlan,cli "trunk${idx}: $port stays on $DEFAULT_BRIDGE for untagged"
  else
    case "$untagged_raw" in
      *[!0-9]*)
        warn -c vlan,cli "trunk${idx}: invalid untagged VLAN '$untagged_raw'; keeping $port on $DEFAULT_BRIDGE"
        if ! bridge_add_if "$DEFAULT_BRIDGE" "$port"; then
          warn -c vlan,cli "trunk${idx}: failed to ensure $port on $DEFAULT_BRIDGE after invalid untagged"
        fi
        untagged_raw="none"
        ;;
      *)
        uvid="$untagged_raw"
        # Prepare uplink and VLAN bridge first
        if ! ensure_vlan_bridge "$uvid"; then
          warn -c vlan,cli "trunk${idx}: failed preparing br${uvid}; keeping $port on $DEFAULT_BRIDGE"
          ERROR_SEEN=1
          return 1
        fi

        # Ensure per-port VLAN subinterface ready
        if ! ensure_vlan_iface "$port" "$uvid"; then
          warn -c vlan,cli "trunk${idx}: failed creating ${port}.${uvid}; keeping $port on $DEFAULT_BRIDGE"
          ERROR_SEEN=1
          return 1
        fi

        # Add the created subinterface to the VLAN bridge
        if ! bridge_add_if "br${uvid}" "${port}.${uvid}"; then
          warn -c vlan,cli "trunk${idx}: failed adding ${port}.${uvid} to br${uvid}; keeping $port on $DEFAULT_BRIDGE"
          ERROR_SEEN=1
          return 1
        fi

        # Only after the new untagged path is ready, remove the physical port from default bridge
        if ! bridge_del_if "$DEFAULT_BRIDGE" "$port"; then
          warn -c vlan,cli "trunk${idx}: failed to remove $port from $DEFAULT_BRIDGE (may be already detached)"
        fi

        info -c vlan,cli "trunk${idx}: $port untagged mapped to VLAN $uvid"
        ;;
    esac
  fi

  for vid in $(parse_vlan_list "$tagged_raw"); do
    [ "$vid" = "$untagged_raw" ] && continue

    if ! ensure_vlan_bridge "$vid"; then
      warn -c vlan,cli "trunk${idx}: failed preparing br${vid}; skipping tag $vid"
      ERROR_SEEN=1
      continue
    fi

    if ! ensure_vlan_iface "$port" "$vid"; then
      warn -c vlan,cli "trunk${idx}: failed creating ${port}.${vid}; skipping tag $vid"
      ERROR_SEEN=1
      continue
    fi

    if ! bridge_add_if "br${vid}" "${port}.${vid}"; then
      warn -c vlan,cli "trunk${idx}: failed adding ${port}.${vid} to br${vid}; skipping tag $vid"
      ERROR_SEEN=1
      continue
    fi

    info -c vlan,cli "trunk${idx}: tagged VLAN $vid active"
  done

  # After operations, log membership for debugging
  log_bridge_membership "$port"
}

main() {
  ensure_port_up "$UPLINK_PORT" || {
    error -c vlan,cli "Uplink $UPLINK_PORT missing"
    exit 1
  }

  local mode="DRY_RUN=$DRY_RUN"
  [ "$DRY_RUN_FORCED" -eq 1 ] && mode="$mode (forced via CLI)"

  info -c vlan,cli "Applying trunk configuration (DEFAULT_BRIDGE=$DEFAULT_BRIDGE, UPLINK_PORT=$UPLINK_PORT, $mode, SETTINGS_FILE=$SETTINGS_FILE)"

  # Ensure the default bridge is up if it exists; manager generally creates it
  if iface_exists "$DEFAULT_BRIDGE"; then
    ensure_port_up "$DEFAULT_BRIDGE" || warn -c vlan,cli "Could not bring $DEFAULT_BRIDGE up"
  fi

  # quick pre-check: if no trunks configured, no-op
  local idx=1 any=0
  while [ "$idx" -le "$MAX_TRUNKS" ]; do
    if get_trunk_port "$idx" >/dev/null 2>&1; then
      any=1
      break
    fi
    idx=$((idx + 1))
  done
  if [ "$any" -eq 0 ]; then
    info -c vlan,cli "No trunks configured; exiting"
    return 0
  fi

  idx=1
  while [ "$idx" -le "$MAX_TRUNKS" ]; do
    configure_trunk "$idx"
    idx=$((idx + 1))
  done

  if [ "$DRY_RUN" = "yes" ]; then
    info -c vlan,cli "Trunk configuration DRY-RUN complete (no changes applied)"
  else
    if [ "$ERROR_SEEN" -ne 0 ]; then
      warn -c vlan,cli "Trunk configuration completed with errors (see above)"
      exit 1
    fi
    info -c vlan,cli "Trunk configuration complete"
  fi
}

main "$@"
