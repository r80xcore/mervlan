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
#               - File: mervlan_trunk.sh || version="0.46"                     #
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

dbg_log "mervlan_trunk.sh invoked with args: ${ORIGINAL_ARGS}"
dbg_var DRY_RUN DRY_RUN_FORCED DEBUG DEBUG_FORCED UPLINK_PORT DEFAULT_BRIDGE MAX_TRUNKS SETTINGS_FILE

run_cmd() {
  if [ "$DRY_RUN" = "yes" ]; then
    info -c vlan,cli "[DRY-RUN] $*"
    return 0
  fi
  "$@" 2>/dev/null
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
  local vid="$1" uplink_vlan="${UPLINK_PORT}.${vid}"

  iface_exists "$UPLINK_PORT" || return 1
  ensure_port_up "$UPLINK_PORT"
  iface_exists "$uplink_vlan" || {
    run_cmd ip link add link "$UPLINK_PORT" name "$uplink_vlan" type vlan id "$vid" || return 1
  }
  run_cmd ip link set "$uplink_vlan" up

  if ! brctl show 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "br${vid}"; then
    run_cmd brctl addbr "br${vid}" || return 1
    run_cmd ip link set "br${vid}" up
  fi

  brctl show "br${vid}" 2>/dev/null | awk '{for (i=4;i<=NF;i++) print $i}' | grep -qx "$uplink_vlan" || \
    run_cmd brctl addif "br${vid}" "$uplink_vlan"
}

bridge_add_if() {
  local br="$1" ifc="$2"
  iface_exists "$ifc" || return 1
  ensure_port_up "$ifc"
  brctl show "$br" 2>/dev/null | awk '{for (i=4;i<=NF;i++) print $i}' | grep -qx "$ifc" && return 0
  run_cmd brctl addif "$br" "$ifc"
}

bridge_del_if() {
  local br="$1" ifc="$2"
  brctl show "$br" 2>/dev/null | awk '{for (i=4;i<=NF;i++) print $i}' | grep -qx "$ifc" || return 0
  run_cmd brctl delif "$br" "$ifc"
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
    return 1
  }

  cfg="$(get_trunk_config "$idx")"
  tagged_raw="${cfg#tagged=}"
  tagged_raw="${tagged_raw% untagged=*}"
  untagged_raw="${cfg##* untagged=}"

  dbg_log "trunk${idx}: effective configuration after parsing"
  dbg_var port tagged_raw untagged_raw

  info -c vlan,cli "trunk${idx}: port=$port tagged=${tagged_raw} untagged=${untagged_raw}"

  if [ "$untagged_raw" = "none" ]; then
    bridge_add_if "$DEFAULT_BRIDGE" "$port"
    info -c vlan,cli "trunk${idx}: $port stays on $DEFAULT_BRIDGE for untagged"
  else
    case "$untagged_raw" in
      *[!0-9]*)
        warn -c vlan,cli "trunk${idx}: invalid untagged VLAN '$untagged_raw'"
        bridge_add_if "$DEFAULT_BRIDGE" "$port"
        untagged_raw="none"
        ;;
      *)
        uvid="$untagged_raw"
        ensure_vlan_bridge "$uvid" || {
          error -c vlan,cli "trunk${idx}: failed preparing br${uvid}"
          return 1
        }
        bridge_del_if "$DEFAULT_BRIDGE" "$port"
        ensure_vlan_iface "$port" "$uvid" || {
          error -c vlan,cli "trunk${idx}: failed creating ${port}.${uvid}"
          return 1
        }
        bridge_add_if "br${uvid}" "${port}.${uvid}"
        info -c vlan,cli "trunk${idx}: $port untagged mapped to VLAN $uvid"
        ;;
    esac
  fi

  for vid in $(parse_vlan_list "$tagged_raw"); do
    [ "$vid" = "$untagged_raw" ] && continue

    ensure_vlan_bridge "$vid" || {
      error -c vlan,cli "trunk${idx}: failed preparing br${vid}"
      continue
    }

    ensure_vlan_iface "$port" "$vid" || {
      error -c vlan,cli "trunk${idx}: failed creating ${port}.${vid}"
      continue
    }

    bridge_add_if "br${vid}" "${port}.${vid}"
    info -c vlan,cli "trunk${idx}: tagged VLAN $vid active"
  done
}

main() {
  ensure_port_up "$UPLINK_PORT" || {
    error -c vlan,cli "Uplink $UPLINK_PORT missing"
    exit 1
  }

  local mode="DRY_RUN=$DRY_RUN"
  [ "$DRY_RUN_FORCED" -eq 1 ] && mode="$mode (forced via CLI)"

  info -c vlan,cli "Applying trunk configuration (DEFAULT_BRIDGE=$DEFAULT_BRIDGE, UPLINK_PORT=$UPLINK_PORT, $mode, SETTINGS_FILE=$SETTINGS_FILE)"

  ensure_port_up "$DEFAULT_BRIDGE" || :

  local idx=1
  while [ "$idx" -le "$MAX_TRUNKS" ]; do
    configure_trunk "$idx"
    idx=$((idx + 1))
  done

  if [ "$DRY_RUN" = "yes" ]; then
    info -c vlan,cli "Trunk configuration DRY-RUN complete (no changes applied)"
  else
    info -c vlan,cli "Trunk configuration complete"
  fi
}

main "$@"
