#!/bin/sh
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
#               - File: mervlan_trunk.sh || version="0.56"                     #
# ============================================================================ #
# =========================================== MerVLAN environment bootstrap == #
: "${MERV_BASE:=/jffs/addons/mervlan}"

if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSH_LOADED LIB_DEBUG_LOADED LIB_STP_LOADED
fi

[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_DEBUG_LOADED:-}" ] || . "$MERV_BASE/settings/lib_debug.sh"
[ -n "${LIB_STP_LOADED:-}" ] || . "$MERV_BASE/settings/lib_stp.sh"

DBG_CHANNEL="vlan,cli"
: "${DBG_PREFIX:=[DEBUG]}"

# Settings file is set by var_settings.sh
# SETTINGS_FILE="${SETTINGS_FILE:-$MERV_BASE/settings/settings.json}"

DRY_RUN_FORCED=0
DEBUG_FORCED=0
ERROR_SEEN=0
TRUNK_SUMMARY=""

append_summary() {
  # Append a line to TRUNK_SUMMARY, preserving actual newlines.
  # Avoid leading blank line when TRUNK_SUMMARY was empty.
  local line="$1"
  if [ -z "$TRUNK_SUMMARY" ]; then
    TRUNK_SUMMARY="$line"
  else
    TRUNK_SUMMARY="${TRUNK_SUMMARY}
${line}"
  fi
}

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

# Global STP enable flag (0|1); default is 0 (off)
STP_ENABLED_RAW="$(json_get_flag "ENABLE_STP" "0" "$SETTINGS_FILE" 2>/dev/null)"
case "$STP_ENABLED_RAW" in
  1) STP_ENABLED=1 ;;
  *) STP_ENABLED=0 ;;
esac

dbg_var STP_ENABLED

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

# ───── ebtables strict VLAN filtering helpers ─────
#
# Per-port user chains filter tagged frames on trunk ports.
# Only explicitly allowed VLAN IDs pass; all other 802.1Q frames are dropped.
# Rules use RETURN (not ACCEPT) to avoid overriding user rule policy.
#
# Chain naming: MERV_TRUNK_ethX  (e.g. MERV_TRUNK_eth1)
# Hook:         FORWARD  (both -i and -o for bidirectional tag-leak prevention)
# Plan file:    /tmp/mervlan_tmp/ebtables/trunk.rules

MERV_EBT_PLANDIR="$TMPDIR/ebtables"
MERV_EBT_PLANFILE="$MERV_EBT_PLANDIR/trunk.rules"
MERV_EBT_OK=""         # cached preflight result: "1" = usable, "0" = not
MERV_EBT_PROTO="802_1Q" # protocol token (overridden if alternate token needed)

# ebt_ok — check ebtables binary exists and supports --vlan-id + -p 802_1Q
# Sets MERV_EBT_OK=1 on success, MERV_EBT_OK=0 on failure.
# Returns: 0 if usable, 1 otherwise.
ebt_ok() {
  # Return cached result if already tested
  case "$MERV_EBT_OK" in
    1) return 0 ;;
    0) return 1 ;;
  esac

  # 1) binary must exist
  if ! type ebtables >/dev/null 2>&1; then
    info -c vlan,cli "ebtables: binary not found; strict VLAN filtering disabled"
    MERV_EBT_OK=0
    return 1
  fi

  # 2) active test: -p 802_1Q --vlan-id (create disposable chain)
  _t="_merv_test_$$"
  ebtables -t filter -N "$_t" 2>/dev/null
  ebtables -t filter -F "$_t" 2>/dev/null
  if ! ebtables -t filter -A "$_t" -p "$MERV_EBT_PROTO" --vlan-id 188 -j RETURN 2>/dev/null; then
    # Try without explicit proto token (some builds)
    ebtables -t filter -F "$_t" 2>/dev/null
    ebtables -t filter -X "$_t" 2>/dev/null
    warn -c vlan,cli "ebtables: --vlan-id / -p $MERV_EBT_PROTO not supported; strict VLAN filtering disabled"
    MERV_EBT_OK=0
    return 1
  fi
  ebtables -t filter -F "$_t" 2>/dev/null
  ebtables -t filter -X "$_t" 2>/dev/null

  info -c vlan,cli "ebtables: preflight passed (proto=$MERV_EBT_PROTO, --vlan-id ok)"
  MERV_EBT_OK=1
  return 0
}

# ebt_run — run an ebtables command, honouring DRY_RUN
# Args: all arguments forwarded to ebtables
# Returns: ebtables exit code (0 on dry-run)
ebt_run() {
  if [ "$DRY_RUN" = "yes" ]; then
    info -c vlan,cli "[DRY-RUN] ebtables $*"
    return 0
  fi
  ebtables "$@" 2>/dev/null
}

# ebt_port_chain — print the chain name for a given port
# Args: $1=port (e.g. eth1)
# Stdout: MERV_TRUNK_eth1
ebt_port_chain() {
  printf 'MERV_TRUNK_%s\n' "$1"
}

# ebt_begin_plan — create plan directory and truncate plan file
ebt_begin_plan() {
  [ "$DRY_RUN" = "yes" ] && return 0
  mkdir -p "$MERV_EBT_PLANDIR" 2>/dev/null || :
  : > "$MERV_EBT_PLANFILE" 2>/dev/null || :
}

# ebt_plan_line — append a command line to the plan file
# Args: $1=command string
ebt_plan_line() {
  [ "$DRY_RUN" = "yes" ] && return 0
  printf '%s\n' "$1" >> "$MERV_EBT_PLANFILE" 2>/dev/null || :
}

# ebt_cleanup_port — remove all MERV jump rules and chain for a single port
# Args: $1=port (e.g. eth1)
# Safe to call even if no rules/chain exist for that port.
# Respects DRY_RUN — will only log what would be removed.
ebt_cleanup_port() {
  local port="$1" chain
  [ -n "$port" ] || return 0
  chain="$(ebt_port_chain "$port")"

  if [ "$DRY_RUN" = "yes" ]; then
    info -c vlan,cli "[DRY-RUN] would cleanup ebtables chain $chain for $port"
    return 0
  fi

  # Delete ingress jump from FORWARD (-i port)
  while ebtables -t filter -D FORWARD -p "$MERV_EBT_PROTO" -i "$port" -j "$chain" 2>/dev/null; do :; done
  # Delete egress jump from FORWARD (-o port)
  while ebtables -t filter -D FORWARD -p "$MERV_EBT_PROTO" -o "$port" -j "$chain" 2>/dev/null; do :; done
  # Flush and delete the per-port chain
  ebtables -t filter -F "$chain" 2>/dev/null
  ebtables -t filter -X "$chain" 2>/dev/null
}

# ebt_apply_port — create per-port chain with allowed VIDs, install FORWARD jumps
# Args: $1=port, $2=space-separated list of allowed VIDs (may be empty)
# An empty allow list means: drop ALL tagged frames on that trunk port.
ebt_apply_port() {
  local port="$1" allow_vids="$2" chain vid
  [ -n "$port" ] || return 0
  chain="$(ebt_port_chain "$port")"

  # Clean existing rules for this port first (idempotent)
  ebt_cleanup_port "$port"

  # Create user chain (create-or-flush: -N may fail if chain survives cleanup)
  ebt_run -t filter -N "$chain" || :
  ebt_run -t filter -F "$chain" || :
  ebt_plan_line "ebtables -t filter -N $chain"
  ebt_plan_line "ebtables -t filter -F $chain"

  # RETURN rules for each allowed VID
  for vid in $allow_vids; do
    ebt_run -t filter -A "$chain" -p "$MERV_EBT_PROTO" --vlan-id "$vid" -j RETURN
    ebt_plan_line "ebtables -t filter -A $chain -p $MERV_EBT_PROTO --vlan-id $vid -j RETURN"
  done

  # Drop all other tagged frames
  ebt_run -t filter -A "$chain" -p "$MERV_EBT_PROTO" -j DROP
  ebt_plan_line "ebtables -t filter -A $chain -p $MERV_EBT_PROTO -j DROP"

  # Install FORWARD jumps at position 1 (ingress + egress)
  # Using -I (insert) instead of -A (append) ensures strict filtering cannot
  # be bypassed by earlier broad ACCEPT rules in FORWARD.
  ebt_run -t filter -I FORWARD 1 -p "$MERV_EBT_PROTO" -i "$port" -j "$chain"
  ebt_plan_line "ebtables -t filter -I FORWARD 1 -p $MERV_EBT_PROTO -i $port -j $chain"

  ebt_run -t filter -I FORWARD 1 -p "$MERV_EBT_PROTO" -o "$port" -j "$chain"
  ebt_plan_line "ebtables -t filter -I FORWARD 1 -p $MERV_EBT_PROTO -o $port -j $chain"

  local vid_count=0
  for vid in $allow_vids; do vid_count=$((vid_count + 1)); done
  info -c vlan,cli "ebtables: applied strict filter on $port ($vid_count VIDs allowed, allow=${allow_vids:-<none>})"
}

# ───── Low level helpers ─────
iface_exists() { [ -d "/sys/class/net/$1" ]; }

list_bridge_members() {
  local br="$1" path
  [ -n "$br" ] || return 0

  if [ -d "/sys/class/net/$br/brif" ]; then
    for path in "/sys/class/net/$br/brif"/*; do
      [ -e "$path" ] || continue
      printf '%s\n' "${path##*/}"
    done
    return 0
  fi

  brctl show "$br" 2>/dev/null | awk '
    NR==1 { next }
    NF>=4 { for (i=4;i<=NF;i++) print $i; next }
    NF==1 { print $1 }
  '
}

bridge_has_if() {
  local br="$1" ifc="$2"
  [ -n "$br" ] || return 1
  [ -n "$ifc" ] || return 1
  list_bridge_members "$br" | grep -qx "$ifc"
}

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
  local vid="$1"
  local uplink_vlan="${UPLINK_PORT}.${vid}"
  local br="br${vid}"

  # Validate uplink port present
  iface_exists "$UPLINK_PORT" || { error -c vlan,cli "ensure_vlan_bridge: uplink $UPLINK_PORT missing"; return 1; }
  ensure_port_up "$UPLINK_PORT" || { error -c vlan,cli "ensure_vlan_bridge: cannot bring uplink $UPLINK_PORT up"; return 1; }

  # ---- Uplink VLAN sub-interface (needed by every path below) ----
  if ! iface_exists "$uplink_vlan"; then
    if ! run_cmd ip link add link "$UPLINK_PORT" name "$uplink_vlan" type vlan id "$vid"; then
      error -c vlan,cli "ensure_vlan_bridge: failed to create $uplink_vlan"
      return 1
    fi
  fi
  run_cmd ip link set "$uplink_vlan" up || { error -c vlan,cli "ensure_vlan_bridge: failed to set $uplink_vlan up"; return 1; }

  # ---- Bridge (sysfs-first detection) ----
  if ! iface_exists "$br"; then
    # --- New bridge ---
    if ! run_cmd brctl addbr "$br"; then
      error -c vlan,cli "ensure_vlan_bridge: failed to create bridge $br"
      return 1
    fi
    # Set deterministic MAC while bridge is still empty/down
    if ! stp_set_bridge_mac "$vid" "${DRY_RUN:-no}"; then
      if [ "${STP_ENABLED:-0}" -eq 1 ] 2>/dev/null; then
        error -c vlan,cli "ensure_vlan_bridge: FATAL — MAC set failed on new $br with STP enabled; removing bridge"
        run_cmd brctl delbr "$br"
        return 1
      fi
      warn -c vlan,cli "ensure_vlan_bridge: MAC set failed on new $br (STP off, continuing)"
    fi
    # Add uplink VLAN interface to bridge
    if ! run_cmd brctl addif "$br" "$uplink_vlan"; then
      error -c vlan,cli "ensure_vlan_bridge: failed to attach uplink $uplink_vlan to $br"
      run_cmd brctl delbr "$br"
      return 1
    fi
    # Bring bridge up
    run_cmd ip link set "$br" up || warn -c vlan,cli "ensure_vlan_bridge: failed to set $br up"
    # STP policy
    stp_apply_policy "$vid" "${DRY_RUN:-no}" "${STP_ENABLED:-0}"
    info -c vlan,cli "ensure_vlan_bridge: created bridge $br"
  else
    # --- Existing bridge: enforce MAC + policy ---
    if [ "${STP_ENABLED:-0}" -eq 1 ] 2>/dev/null; then
      if ! stp_force_bridge_mac "$vid" "${DRY_RUN:-no}"; then
        error -c vlan,cli "ensure_vlan_bridge: FATAL — failed to enforce bridge MAC on $br with STP enabled"
        return 1
      fi
    else
      stp_set_bridge_mac "$vid" "${DRY_RUN:-no}"
    fi
    # Ensure uplink VLAN iface is a member (force-mac may have detached it)
    if [ "${DRY_RUN:-}" = "yes" ]; then
      info -c vlan,cli "[DRY-RUN] ensure $uplink_vlan is member of $br"
    else
      if ! bridge_has_if "$br" "$uplink_vlan"; then
        if ! run_cmd brctl addif "$br" "$uplink_vlan"; then
          error -c vlan,cli "ensure_vlan_bridge: FATAL — could not attach uplink $uplink_vlan to $br"
          return 1
        fi
        info -c vlan,cli "ensure_vlan_bridge: re-attached uplink $uplink_vlan to $br"
      fi
      # Best-effort: make sure bridge is up
      run_cmd ip link set "$br" up
      # Post-enforcement verification (STP only)
      if [ "${STP_ENABLED:-0}" -eq 1 ] 2>/dev/null; then
        stp_verify_bridge_mac "$vid" || {
          error -c vlan,cli "ensure_vlan_bridge: FATAL — bridge MAC verification failed on $br"
          return 1
        }
      fi
    fi
    stp_apply_policy "$vid" "${DRY_RUN:-no}" "${STP_ENABLED:-0}"
  fi

  dbg_log "ensure_vlan_bridge: $br ready with uplink $uplink_vlan"
}

bridge_add_if() {
  local br="$1" ifc="$2"
  # In DRY-RUN, do not depend on kernel state for just-created subinterfaces.
  # Print what would happen and succeed to make dry-run output clean.
  if [ "${DRY_RUN:-}" = "yes" ]; then
    info -c vlan,cli "[DRY-RUN] brctl addif $br $ifc"
    return 0
  fi
  iface_exists "$ifc" || return 1
  ensure_port_up "$ifc" || return 1
  bridge_has_if "$br" "$ifc" && return 0
  if ! run_cmd brctl addif "$br" "$ifc"; then
    if bridge_has_if "$br" "$ifc"; then
      warn -c vlan,cli "bridge_add_if: $ifc already on $br (continuing)"
      return 0
    fi
    error -c vlan,cli "bridge_add_if: failed to add $ifc to $br"
    return 1
  fi
}

bridge_del_if() {
  local br="$1" ifc="$2"
  bridge_has_if "$br" "$ifc" || return 0
  if ! run_cmd brctl delif "$br" "$ifc"; then
    if ! bridge_has_if "$br" "$ifc"; then
      return 0
    fi
    warn -c vlan,cli "bridge_del_if: failed to remove $ifc from $br"
    return 1
  fi
}

detach_from_all_bridges() {
  local ifc="$1" _dab_br
  [ -n "$ifc" ] || return 0
  [ "${DRY_RUN:-}" = "yes" ] && return 0
  for _dab_br in $(brctl show 2>/dev/null | awk 'NR>1 && $1!="" {print $1}' | sort -u); do
    brctl delif "$_dab_br" "$ifc" 2>/dev/null
  done
}

parse_vlan_list() {
  local raw="$1"
  local vid _seen

  [ -n "$raw" ] || return 0
  [ "$raw" = "none" ] && return 0

  _seen=" "
  printf '%s\n' "$raw" | tr ',;' ' ' | tr -s ' ' | tr ' ' '\n' | while read -r vid; do
    [ -n "$vid" ] || continue
    case "$vid" in
      *[!0-9]*) continue ;;
    esac
    if [ "$vid" -ge 2 ] 2>/dev/null && [ "$vid" -le 4094 ] 2>/dev/null; then
      # dedup: skip if already seen
      case "$_seen" in
        *" ${vid} "*) continue ;;
      esac
      _seen="${_seen}${vid} "
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

  if [ "$raw" -lt 0 ] 2>/dev/null; then
    # Fallback to nested settings: VLAN -> Trunks -> TRUNKx
    raw="$(json_get_section2_int "VLAN" "Trunks" "TRUNK${idx}" "$SETTINGS_FILE" 2>/dev/null)"
    [ -n "$raw" ] || raw=-1
    dbg_log "trunk${idx}: nested TRUNK lookup returned '${raw}'"
    dbg_var raw
  fi

  if [ "$raw" -lt 0 ] 2>/dev/null; then
    raw="$(json_get_section2_int "VLAN" "Trunks" "trunk${idx}" "$SETTINGS_FILE" 2>/dev/null)"
    [ -n "$raw" ] || raw=-1
    dbg_log "trunk${idx}: nested lowercase fallback returned '${raw}'"
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
  local idx="$1"
  local tagged_key="TAGGED_TRUNK${idx}"
  local untagged_key="UNTAGGED_TRUNK${idx}"
  local tagged_raw untagged_raw

  tagged_raw="$(json_get_flag "$tagged_key" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)"
  untagged_raw="$(json_get_flag "$untagged_key" "__MISSING__" "$SETTINGS_FILE" 2>/dev/null)"

  if [ -z "$tagged_raw" ] || [ "$tagged_raw" = "__MISSING__" ]; then
    tagged_raw="$(json_get_section2_value "VLAN" "Trunks" "$tagged_key" "$SETTINGS_FILE" 2>/dev/null)"
  fi
  if [ -z "$untagged_raw" ] || [ "$untagged_raw" = "__MISSING__" ]; then
    untagged_raw="$(json_get_section2_value "VLAN" "Trunks" "$untagged_key" "$SETTINGS_FILE" 2>/dev/null)"
  fi

  [ -n "$tagged_raw" ] || tagged_raw="none"
  [ -n "$untagged_raw" ] || untagged_raw="none"

  dbg_log "trunk${idx}: resolved tagged/untagged payloads"
  dbg_var tagged_raw untagged_raw

  printf 'tagged=%s untagged=%s\n' "$tagged_raw" "$untagged_raw"
}

configure_trunk() {
  local idx="$1" port cfg tagged_raw untagged_raw uvid vid

  port="$(get_trunk_port "$idx")" || {
    info -c vlan,cli "trunk${idx}: disabled"
    append_summary "trunk${idx}: disabled"
    return 0
  }

  ensure_port_up "$port" || {
    warn -c vlan,cli "trunk${idx}: $port missing"
    ERROR_SEEN=1
    append_summary "trunk${idx}: port=${port} missing"
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
    # Native = DEFAULT_BRIDGE: detach base port first (convergence from prior UVID)
    detach_from_all_bridges "$port"
    bridge_add_if "$DEFAULT_BRIDGE" "$port" || warn -c vlan,cli "trunk${idx}: failed to ensure $port on $DEFAULT_BRIDGE"
    info -c vlan,cli "trunk${idx}: $port (base) in $DEFAULT_BRIDGE for native/untagged"
    u_summary="$DEFAULT_BRIDGE"
  else
    case "$untagged_raw" in
      *[!0-9]*)
        warn -c vlan,cli "trunk${idx}: invalid untagged VLAN '$untagged_raw'; keeping $port on $DEFAULT_BRIDGE"
        detach_from_all_bridges "$port"
        if ! bridge_add_if "$DEFAULT_BRIDGE" "$port"; then
          warn -c vlan,cli "trunk${idx}: failed to ensure $port on $DEFAULT_BRIDGE after invalid untagged"
        fi
        untagged_raw="none"
        u_summary="invalid"
        ;;
      *)
        uvid="$untagged_raw"
        # Detach physical port from any bridge it may be in (previous run, manual config)
        detach_from_all_bridges "$port"

        # Prepare uplink and VLAN bridge first
        if ! ensure_vlan_bridge "$uvid"; then
          warn -c vlan,cli "trunk${idx}: failed preparing br${uvid}; keeping $port on $DEFAULT_BRIDGE"
          bridge_add_if "$DEFAULT_BRIDGE" "$port" 2>/dev/null
          ERROR_SEEN=1
          append_summary "trunk${idx}: port=${port} failed to prepare br${uvid} (keeps on ${DEFAULT_BRIDGE})"
          return 1
        fi

        # Netgear native/PVID: base port goes into br<UVID> (NOT a subinterface)
        # Untagged frames arriving on base port are classified into this VLAN.
        if ! bridge_add_if "br${uvid}" "$port"; then
          warn -c vlan,cli "trunk${idx}: failed adding $port to br${uvid}; keeping on $DEFAULT_BRIDGE"
          bridge_add_if "$DEFAULT_BRIDGE" "$port" 2>/dev/null
          ERROR_SEEN=1
          append_summary "trunk${idx}: port=${port} failed to add to br${uvid} (keeps on ${DEFAULT_BRIDGE})"
          return 1
        fi

        # Clean up stale subinterface from previous "tag-native" implementation
        if [ "${DRY_RUN:-}" != "yes" ] && iface_exists "${port}.${uvid}"; then
          detach_from_all_bridges "${port}.${uvid}"
          run_cmd ip link del "${port}.${uvid}" || \
            warn -c vlan,cli "trunk${idx}: failed to delete stale ${port}.${uvid}"
          info -c vlan,cli "trunk${idx}: removed stale subinterface ${port}.${uvid} (native uses base port)"
        fi

        info -c vlan,cli "trunk${idx}: $port (base) in br${uvid} for native VLAN $uvid"
        u_summary="$uvid"
        ;;
    esac
  fi

  # Build tagged list and ensure membership; skip if none
  tagged_list=""
  ebt_allow=""  # ebtables: accumulate successfully configured VIDs
  for vid in $(parse_vlan_list "$tagged_raw"); do
    # Forbid overlap: native VLAN must not also appear as tagged
    if [ "$vid" = "$untagged_raw" ]; then
      warn -c vlan,cli "trunk${idx}: VLAN $vid is the native VLAN; removing from tagged list"
      continue
    fi

    if ! ensure_vlan_bridge "$vid"; then
      warn -c vlan,cli "trunk${idx}: failed preparing br${vid}; skipping tag $vid"
      ERROR_SEEN=1
      tagged_list="${tagged_list}${tagged_list:+,}${vid}:skipped"
      continue
    fi

    if ! ensure_vlan_iface "$port" "$vid"; then
      warn -c vlan,cli "trunk${idx}: failed creating ${port}.${vid}; skipping tag $vid"
      ERROR_SEEN=1
      tagged_list="${tagged_list}${tagged_list:+,}${vid}:iface-failed"
      continue
    fi

    if ! bridge_add_if "br${vid}" "${port}.${vid}"; then
      warn -c vlan,cli "trunk${idx}: failed adding ${port}.${vid} to br${vid}; skipping tag $vid"
      ERROR_SEEN=1
      tagged_list="${tagged_list}${tagged_list:+,}${vid}:bridge-failed"
      continue
    fi

    info -c vlan,cli "trunk${idx}: tagged VLAN $vid active"
    tagged_list="${tagged_list}${tagged_list:+,}${vid}"
    ebt_allow="${ebt_allow}${ebt_allow:+ }${vid}"
  done

  # --- Tag reconciliation: detach stale VLAN subinterfaces for this port ---
  # Enumerate existing ${port}.* subinterfaces; detach any whose VID is not in
  # the desired tagged set. This removes explicit VLAN handling so stale VLANs
  # are no longer bridged. NOTE: on Linux without VLAN-aware bridge filtering,
  # tagged frames may still traverse via the native bridge path; this step does
  # NOT guarantee "drop tags not in list" — a tag-leak test is required to
  # confirm platform behavior (see §1.2 / §7 in the implementation guide).
  if [ "${DRY_RUN:-}" != "yes" ]; then
    # Build effective desired set (excluding native UVID, matching tagged loop)
    _desired_tags=" "
    for _v in $(parse_vlan_list "$tagged_raw"); do
      [ "$_v" = "$untagged_raw" ] && continue
      _desired_tags="${_desired_tags}${_v} "
    done
    for _stale_path in /sys/class/net/${port}.[0-9]*; do
      [ -e "$_stale_path" ] || continue
      _stale_ifc="${_stale_path##*/}"
      _stale_vid="${_stale_ifc#${port}.}"
      # Skip if this VID is in the desired tagged set
      case "$_desired_tags" in
        *" ${_stale_vid} "*) continue ;;
      esac
      # Skip if this is the native VLAN (already handled above)
      [ "$_stale_vid" = "$untagged_raw" ] && continue
      # Stale: detach from all bridges (safe — does not delete the interface)
      detach_from_all_bridges "$_stale_ifc"
      info -c vlan,cli "trunk${idx}: detached stale ${_stale_ifc} (VID $_stale_vid not in tagged list)"
    done
  fi

  # --- ebtables strict VLAN filtering for this trunk port ---
  if ebt_ok; then
    ebt_apply_port "$port" "$ebt_allow"
  fi

  # After operations, log membership for debugging
  log_bridge_membership "$port"

  # Append trunk summary (show untagged + tagged planned/actual)
  [ -z "${u_summary:-}" ] && u_summary="none"
  [ -z "${tagged_list:-}" ] && tagged_list="none"
  append_summary "trunk${idx}: port=${port} untagged=${u_summary} tagged=${tagged_list}"
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

  # Initialise ebtables plan file only if ebtables is usable
  if ebt_ok; then
    ebt_begin_plan
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

  # Print compact trunk summary (what was applied or would be applied)
  if [ -n "$TRUNK_SUMMARY" ]; then
    info -c vlan,cli "=== Trunk summary ==="
    printf '%s\n' "$TRUNK_SUMMARY" | while IFS= read -r l; do
      [ -z "$l" ] && continue
      info -c vlan,cli "  $l"
    done
  fi

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
