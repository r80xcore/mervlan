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
#                - File: lib_stp.sh || version="0.57"                          #
# ============================================================================ #
# - Purpose:    Deterministic STP Bridge-ID (bridge MAC) generation for        #
#               MerVLAN VLAN bridges. Guarantees unique, stable Bridge IDs     #
#               across Main router + up to 5 AiMesh nodes.                     #
# ============================================================================ #
#                                                                              #
# DESIGN DECISION — Option A (unit_id + vlan_id only)                          #
# ====================================================                         #
# STP runs on bridges, not interfaces. A bridge br187 is a single STP          #
# participant with one Bridge ID. Including SSID/ETH slot information in the   #
# MAC would risk flip-flopping if the same VLAN is used by multiple ports and  #
# the "canonical" slot changes when config is edited. Option A is              #
# deterministic by construction: same unit + same VLAN = same bridge MAC,      #
# regardless of which interfaces are bridged into it.                          #
#                                                                              #
# MAC layout (6 bytes, locally-administered unicast):                          #
#   Byte1: 02              — LA unicast prefix                                 #
#   Byte2: A0 + unit_id    — unit identity (A0=main, A1..A5=nodes)             #
#   Byte3: 4D              — product tag ('M' for MerVLAN)                     #
#   Byte4: (vid >> 8)      — VLAN high byte                                    #
#   Byte5: (vid & 0xFF)    — VLAN low byte                                     #
#   Byte6: 01              — version byte (bump on layout changes)             #
#                                                                              #
# Example: Main router, VLAN 187                                               #
#   unit_id=0, vid=187 → 02:a0:4d:00:bb:01                                     #
# Example: Node 2, VLAN 187                                                    #
#   unit_id=2, vid=187 → 02:a2:4d:00:bb:01                                     #
# ============================================================================ #

[ -n "${LIB_STP_LOADED:-}" ] && return 0 2>/dev/null

# ---- merv: portable `command -v` replacement ----
if ! type merv_has >/dev/null 2>&1; then
  merv_has() { type "$1" >/dev/null 2>&1; }
  merv_cmd() {
    _merv_c="$1"
    case "$_merv_c" in
      */*) [ -x "$_merv_c" ] && { printf '%s\n' "$_merv_c"; return 0; } ;;
    esac
    _merv_oldIFS="$IFS"; IFS=:
    for _merv_d in $PATH; do
      [ -z "$_merv_d" ] && _merv_d="."
      [ -x "$_merv_d/$_merv_c" ] && { IFS="$_merv_oldIFS"; printf '%s\n' "$_merv_d/$_merv_c"; return 0; }
    done
    IFS="$_merv_oldIFS"
    return 1
  }
fi
# ---- end shim ----

# ============================================================================ #
# STP BRIDGE MAC GENERATION                                                    #
# ============================================================================ #

# stp_get_unit_id — Determine the numeric unit identity for this device
# Args: none (reads NODE_ID from caller's environment or settings)
# Returns: stdout 0 (main router) or 1-5 (node)
stp_get_unit_id() {
  # NODE_ID is set by mervlan_manager.sh or execute_nodes.sh before we are called.
  # Accept both the script-global NODE_ID and the MERV_NODE_ID variant.
  _stp_nid="${NODE_ID:-${MERV_NODE_ID:-none}}"
  case "$_stp_nid" in
    1|2|3|4|5) printf '%s' "$_stp_nid" ;;
    *)         printf '0' ;;
  esac
}

# stp_mac_for_vlan_bridge — Compute deterministic bridge MAC for a VLAN bridge
# Args: $1=vlan_id (2-4094)
# Returns: stdout MAC address (xx:xx:xx:xx:xx:xx), or empty + rc=1 on bad input
# Side effects: none (pure computation)
stp_mac_for_vlan_bridge() {
  _stp_vid="$1"

  # Validate VLAN ID is numeric and in range 2-4094
  case "$_stp_vid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_stp_vid" -ge 2 ] 2>/dev/null && [ "$_stp_vid" -le 4094 ] 2>/dev/null || return 1

  _stp_uid="$(stp_get_unit_id)"

  # Byte 1: 02 (locally-administered unicast)
  _stp_b1="02"

  # Byte 2: A0 + unit_id (0xA0 = 160; range 160..165)
  _stp_b2_dec=$((160 + _stp_uid))
  _stp_b2=$(printf '%02x' "$_stp_b2_dec")

  # Byte 3: 4D (product tag 'M' for MerVLAN)
  _stp_b3="4d"

  # Bytes 4-5: VLAN ID packed into two bytes (big-endian)
  _stp_b4_dec=$((_stp_vid / 256))
  _stp_b5_dec=$((_stp_vid % 256))
  _stp_b4=$(printf '%02x' "$_stp_b4_dec")
  _stp_b5=$(printf '%02x' "$_stp_b5_dec")

  # Byte 6: version (01)
  _stp_b6="01"

  printf '%s:%s:%s:%s:%s:%s' "$_stp_b1" "$_stp_b2" "$_stp_b3" "$_stp_b4" "$_stp_b5" "$_stp_b6"
}

# stp_set_bridge_mac — Set deterministic MAC on a VLAN bridge (MAC only, no STP)
# Args: $1=vlan_id (2-4094)
#       $2=dry_run ("yes" or anything else)
# Returns: 0 on success, 1 on failure
# Explanation: Computes the bridge MAC via stp_mac_for_vlan_bridge, then
#   idempotently sets it on br<VID>. Skips the write when the current MAC
#   already matches (avoids unnecessary churn). Best called on a freshly
#   created bridge before adding ports or bringing it up.
stp_set_bridge_mac() {
  _stp_m_vid="$1"
  _stp_m_dry="${2:-no}"
  _stp_m_br="br${_stp_m_vid}"

  # Compute deterministic MAC
  _stp_m_mac="$(stp_mac_for_vlan_bridge "$_stp_m_vid")"
  if [ -z "$_stp_m_mac" ]; then
    warn -c vlan,cli "stp_set_bridge_mac: failed to compute MAC for VID=$_stp_m_vid"
    return 1
  fi

  _stp_m_uid="$(stp_get_unit_id)"

  # Audit trail
  info -c vlan "STP bridge-mac: bridge=$_stp_m_br unit_id=$_stp_m_uid vid=$_stp_m_vid mac=$_stp_m_mac"

  if [ "$_stp_m_dry" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] ip link set $_stp_m_br address $_stp_m_mac"
    return 0
  fi

  # Skip write when the bridge already has the correct MAC (sysfs read is fast)
  _stp_m_cur="$(cat /sys/class/net/"$_stp_m_br"/address 2>/dev/null)"
  if [ "$_stp_m_cur" = "$_stp_m_mac" ]; then
    info -c vlan "stp_set_bridge_mac: $_stp_m_br already has correct MAC, skipping"
    return 0
  fi

  # Live mode: set bridge MAC
  ip link set "$_stp_m_br" address "$_stp_m_mac" 2>/dev/null
  _stp_m_rc=$?
  if [ $_stp_m_rc -ne 0 ]; then
    warn -c vlan,cli "stp_set_bridge_mac: ip link set $_stp_m_br address $_stp_m_mac failed (rc=$_stp_m_rc)"
    return 1
  fi

  # Verify sysfs reflects the new MAC
  _stp_m_verify="$(cat /sys/class/net/"$_stp_m_br"/address 2>/dev/null)"
  if [ "$_stp_m_verify" != "$_stp_m_mac" ]; then
    warn -c vlan,cli "stp_set_bridge_mac: post-set verify failed on $_stp_m_br (got=$_stp_m_verify want=$_stp_m_mac)"
    return 1
  fi

  return 0
}

# stp_verify_bridge_mac — Verify bridge MAC matches the deterministic value
# Args: $1=vlan_id (2-4094)
# Returns: 0 if MAC matches (or bridge does not exist), 1 if mismatch
# Side effects: none (read-only)
stp_verify_bridge_mac() {
  _stp_v_vid="$1"
  _stp_v_br="br${_stp_v_vid}"

  # If bridge doesn't exist yet, nothing to verify
  [ -d "/sys/class/net/$_stp_v_br" ] || return 0

  _stp_v_want="$(stp_mac_for_vlan_bridge "$_stp_v_vid")"
  [ -n "$_stp_v_want" ] || return 1

  _stp_v_have="$(cat /sys/class/net/"$_stp_v_br"/address 2>/dev/null)"
  [ "$_stp_v_have" = "$_stp_v_want" ]
}

# stp_list_bridge_members — List member interfaces of a bridge (sysfs-first)
# Args: $1=bridge_name
# Returns: stdout, one interface name per line
_stp_list_bridge_members() {
  _stp_lb_br="$1"
  if [ -d "/sys/class/net/$_stp_lb_br/brif" ]; then
    # sysfs: fast, reliable
    for _stp_lb_p in /sys/class/net/"$_stp_lb_br"/brif/*; do
      [ -e "$_stp_lb_p" ] || continue
      printf '%s\n' "${_stp_lb_p##*/}"
    done
  else
    # Fallback: parse brctl output (only print tokens that look like interface names)
    brctl show "$_stp_lb_br" 2>/dev/null | awk '
      NR==1 { next }
      { for (i=1; i<=NF; i++)
          if ($i ~ /^(wl|eth|vlan|wds|tap|tun|ra|ap|nas|bond|vxlan)[0-9.:-]*$/)
            print $i
      }
    '
  fi
}

# stp_list_bridge_members — Public wrapper for _stp_list_bridge_members
# Args: $1=bridge_name
# Returns: stdout, one interface name per line
stp_list_bridge_members() { _stp_list_bridge_members "$@"; }

# stp_force_bridge_mac — Disruptive MAC enforcement for an existing bridge
# Args: $1=vlan_id (2-4094)
#       $2=dry_run ("yes" or anything else)
# Returns: 0 on success (MAC verified), 1 on failure
# Explanation: When STP is enabled (caller decides), the bridge MAC MUST match
#   the deterministic value. If a non-disruptive set fails (bridge is up with
#   ports), this function brings the bridge down, detaches all members, sets
#   the MAC, reattaches members, and brings it back up. Causes a brief but
#   acceptable traffic disruption.
stp_force_bridge_mac() {
  _stp_f_vid="$1"
  _stp_f_dry="${2:-no}"
  _stp_f_br="br${_stp_f_vid}"

  # Compute desired MAC
  _stp_f_mac="$(stp_mac_for_vlan_bridge "$_stp_f_vid")"
  if [ -z "$_stp_f_mac" ]; then
    error -c vlan,cli "stp_force_bridge_mac: failed to compute MAC for VID=$_stp_f_vid"
    return 1
  fi

  _stp_f_uid="$(stp_get_unit_id)"
  info -c vlan "STP force-mac: bridge=$_stp_f_br unit_id=$_stp_f_uid vid=$_stp_f_vid desired=$_stp_f_mac"

  # Dry-run: show the full forced-rewrite sequence
  if [ "$_stp_f_dry" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] stp_force_bridge_mac: would enforce $_stp_f_mac on $_stp_f_br (down+detach+set+reattach+up)"
    return 0
  fi

  # Check if bridge exists
  if [ ! -d "/sys/class/net/$_stp_f_br" ]; then
    error -c vlan,cli "stp_force_bridge_mac: FATAL — $_stp_f_br missing; cannot enforce Bridge ID"
    return 1
  fi

  # Fast path: already correct
  _stp_f_cur="$(cat /sys/class/net/"$_stp_f_br"/address 2>/dev/null)"
  if [ "$_stp_f_cur" = "$_stp_f_mac" ]; then
    info -c vlan "stp_force_bridge_mac: $_stp_f_br already has correct MAC, skipping"
    return 0
  fi

  # Try non-disruptive set first (may work on some kernels even while up)
  ip link set "$_stp_f_br" address "$_stp_f_mac" 2>/dev/null
  _stp_f_cur="$(cat /sys/class/net/"$_stp_f_br"/address 2>/dev/null)"
  if [ "$_stp_f_cur" = "$_stp_f_mac" ]; then
    info -c vlan "stp_force_bridge_mac: $_stp_f_br MAC set non-disruptively"
    return 0
  fi

  # Non-disruptive set failed — proceed with disruptive rewrite
  info -c vlan,cli "stp_force_bridge_mac: non-disruptive set failed on $_stp_f_br, performing disruptive rewrite"

  # 1. Snapshot current member ports
  _stp_f_members="$(_stp_list_bridge_members "$_stp_f_br")"
  _stp_f_mcnt=0
  for _stp_f_port in $_stp_f_members; do _stp_f_mcnt=$((_stp_f_mcnt + 1)); done
  info -c vlan "stp_force_bridge_mac: $_stp_f_br has $_stp_f_mcnt member(s) to detach/reattach"

  # 2. Bring bridge down
  ip link set "$_stp_f_br" down 2>/dev/null

  # 3. Detach all member ports
  for _stp_f_port in $_stp_f_members; do
    brctl delif "$_stp_f_br" "$_stp_f_port" 2>/dev/null
  done

  # 4. Set MAC on empty/down bridge
  ip link set "$_stp_f_br" address "$_stp_f_mac" 2>/dev/null

  # 5. Verify
  _stp_f_cur="$(cat /sys/class/net/"$_stp_f_br"/address 2>/dev/null)"
  if [ "$_stp_f_cur" != "$_stp_f_mac" ]; then
    # Retry once
    ip link set "$_stp_f_br" address "$_stp_f_mac" 2>/dev/null
    _stp_f_cur="$(cat /sys/class/net/"$_stp_f_br"/address 2>/dev/null)"
  fi

  # 6. Verify MAC was set on the empty/down bridge before proceeding
  #    If it still doesn't match, leave bridge DOWN (fail-closed) and abort.
  if [ "$_stp_f_cur" != "$_stp_f_mac" ]; then
    error -c vlan,cli "stp_force_bridge_mac: FATAL — $_stp_f_br MAC is '$_stp_f_cur', wanted '$_stp_f_mac' after disruptive set (bridge left DOWN)"
    return 1
  fi

  # 7. Reattach all member ports (do NOT force ports up; let the system manage link state)
  for _stp_f_port in $_stp_f_members; do
    brctl addif "$_stp_f_br" "$_stp_f_port" 2>/dev/null
  done

  # 8. Bring bridge back up
  ip link set "$_stp_f_br" up 2>/dev/null

  # 9. Final verification (fresh sysfs read after bridge is up)
  _stp_f_cur="$(cat /sys/class/net/"$_stp_f_br"/address 2>/dev/null)"
  if [ "$_stp_f_cur" != "$_stp_f_mac" ]; then
    error -c vlan,cli "stp_force_bridge_mac: FATAL — $_stp_f_br MAC drifted to '$_stp_f_cur' after bring-up, wanted '$_stp_f_mac'"
    ip link set "$_stp_f_br" down 2>/dev/null
    return 1
  fi

  info -c vlan,cli "stp_force_bridge_mac: $_stp_f_br MAC enforced via disruptive rewrite"
  return 0
}

# stp_apply_policy — Apply STP on/off and forwarding-delay policy to a VLAN bridge
# Args: $1=vlan_id (2-4094)
#       $2=dry_run ("yes" or anything else)
#       $3=stp_enabled (1 to enable STP, 0 or anything else to disable)
# Returns: 0 always
# Explanation: Call this after the bridge is up and MAC is already set.
stp_apply_policy() {
  _stp_p_vid="$1"
  _stp_p_dry="${2:-no}"
  _stp_p_stp="${3:-0}"
  _stp_p_br="br${_stp_p_vid}"

  info -c vlan "STP policy: bridge=$_stp_p_br stp=$_stp_p_stp"

  if [ "$_stp_p_dry" = "yes" ]; then
    if [ "$_stp_p_stp" -eq 1 ] 2>/dev/null; then
      info -c cli,vlan "[DRY-RUN] brctl stp $_stp_p_br on"
      info -c cli,vlan "[DRY-RUN] brctl setfd $_stp_p_br 15"
    else
      info -c cli,vlan "[DRY-RUN] brctl stp $_stp_p_br off"
      info -c cli,vlan "[DRY-RUN] brctl setfd $_stp_p_br 0"
    fi
    return 0
  fi

  if [ "$_stp_p_stp" -eq 1 ] 2>/dev/null; then
    brctl stp "$_stp_p_br" on 2>/dev/null  || :
    brctl setfd "$_stp_p_br" 15 2>/dev/null || :
  else
    brctl stp "$_stp_p_br" off 2>/dev/null || :
    brctl setfd "$_stp_p_br" 0 2>/dev/null  || :
  fi

  return 0
}

# stp_apply_bridge_mac — Convenience: set bridge MAC + apply STP policy in one call
# Args: $1=vlan_id, $2=dry_run, $3=stp_enabled
# Returns: 0 on success, 1 on MAC computation failure
# Use for existing bridges where ordering is less critical. For new bridges,
# prefer calling stp_set_bridge_mac() and stp_apply_policy() separately with
# the correct creation-order interleaving.
stp_apply_bridge_mac() {
  stp_set_bridge_mac "$1" "${2:-no}" || return 1
  stp_apply_policy "$1" "${2:-no}" "${3:-0}"
}

LIB_STP_LOADED=1
