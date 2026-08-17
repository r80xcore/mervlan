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
#               - File: mervlan_wan.sh || version="0.9"                       #
# ============================================================================ #
# - Purpose:    Own the optional native VLAN transport on the WAN/uplink.      #
#               ASUS/native traffic remains on br0; this script changes only   #
#               the bridge member used to reach the physical uplink:           #
#                 ASUS: br0 -> WAN_IF                                           #
#                 tagged: br0 -> WAN_IF.VID -> WAN_IF                           #
#                                                                              #
# - Modes:      validate  settings/range/conflict checks only                   #
#               apply     converge live bridge transport (transactional)       #
#               verify    read-only live topology verification                  #
#                                                                              #
# - Safety:     Never places the physical uplink and a VLAN upper in br0 as a  #
#               planned steady state. The replacement upper is created and     #
#               validated first, then bridge membership is swapped with        #
#               rollback to the captured original path on failure.             #
# ============================================================================ #

: "${MERV_BASE:=/jffs/addons/mervlan}"

if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED LIB_SSID_FILTER_LOADED LIB_DEBUG_LOADED
fi

[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_SSID_FILTER_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssid_filter.sh"
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_identity.sh"
[ -n "${LIB_DEBUG_LOADED:-}" ] || . "$MERV_BASE/settings/lib_debug.sh"

MODE="${1:-apply}"
case "$MODE" in
  validate|apply|verify|health) ;;
  dryrun|--dry-run|-n)
    MODE="apply"
    DRY_RUN="yes"
    ;;
  *)
    error -c cli,vlan "WAN Native: unsupported mode '$MODE' (use validate, apply, or verify)"
    exit 2
    ;;
esac

DRY_RUN="${DRY_RUN:-$(json_get_flag "DRY_RUN" "yes" "$SETTINGS_FILE" 2>/dev/null)}"
[ "$DRY_RUN" = "no" ] || DRY_RUN="yes"

DEFAULT_BRIDGE="${DEFAULT_BRIDGE:-br0}"
UPLINK_PORT="${UPLINK_PORT:-}"
if [ -z "$UPLINK_PORT" ]; then
  UPLINK_PORT="$(json_get_section_value "Hardware" "WAN_IF" "$SETTINGS_FILE" 2>/dev/null)"
fi
[ -n "$UPLINK_PORT" ] || UPLINK_PORT="$(json_get_flag "WAN_IF" "eth0" "$SETTINGS_FILE" 2>/dev/null)"
[ -n "$UPLINK_PORT" ] || UPLINK_PORT="eth0"

# Test-only filesystem indirection. Production callers use the defaults.
MERV_WAN_NET_ROOT="${MERV_WAN_NET_ROOT:-/sys/class/net}"
MERV_WAN_PROC_VLAN_ROOT="${MERV_WAN_PROC_VLAN_ROOT:-/proc/net/vlan}"
# DHCP handoff is MAIN-only and intentionally has test seams for the
# otherwise firmware-owned NVRAM, process, address, and timeout state.
MERV_WAN_DHCP_PIDFILE="${MERV_WAN_DHCP_PIDFILE:-/var/run/udhcpc_lan.pid}"
MERV_WAN_DHCP_PROC_ROOT="${MERV_WAN_DHCP_PROC_ROOT:-/proc}"
MERV_WAN_DHCP_WAIT_SEC="${MERV_WAN_DHCP_WAIT_SEC:-15}"
MERV_WAN_DHCP_RELEASE_WAIT_SEC="${MERV_WAN_DHCP_RELEASE_WAIT_SEC:-5}"
MERV_WAN_DHCP_TERM_WAIT_SEC="${MERV_WAN_DHCP_TERM_WAIT_SEC:-${MERV_WAN_DHCP_EXIT_WAIT_SEC:-5}}"
MERV_WAN_DHCP_START_WAIT_SEC="${MERV_WAN_DHCP_START_WAIT_SEC:-5}"
MERV_WAN_DHCP_TEST_ADDRESS_FILE="${MERV_WAN_DHCP_TEST_ADDRESS_FILE:-}"
MERV_WAN_DHCP_EXPECTED_ADDRESS="${MERV_WAN_DHCP_EXPECTED_ADDRESS:-}"
MERV_WAN_DHCP_TEST_LIFECYCLE_FILE="${MERV_WAN_DHCP_TEST_LIFECYCLE_FILE:-}"

NODE_ID="${NODE_ID:-${MERV_NODE_ID:-}}"
if [ -z "$NODE_ID" ]; then
  NODE_ID="$(json_get_section_value "General" "NODE_ID" "$SETTINGS_FILE" 2>/dev/null)"
fi
[ -n "$NODE_ID" ] || NODE_ID="$(json_get_flag "NODE_ID" "none" "$SETTINGS_FILE" 2>/dev/null)"
case "$NODE_ID" in
  none|0|'') NODE_ID="none" ;;
  *[!0-9]*)
    error -c cli,vlan "WAN Native: invalid NODE_ID '$NODE_ID'"
    exit 2
    ;;
  *)
    if [ "$NODE_ID" -lt 1 ] 2>/dev/null || [ "$NODE_ID" -gt "${MERV_MAX_NODES:-10}" ] 2>/dev/null; then
      error -c cli,vlan "WAN Native: NODE_ID '$NODE_ID' is out of range"
      exit 2
    fi
    ;;
esac

if [ "$NODE_ID" = "none" ]; then
  WAN_NATIVE_KEY="WAN_NATIVE_MAIN"
  WAN_NATIVE_TARGET="MAIN"
else
  WAN_NATIVE_KEY="WAN_NATIVE_NODE${NODE_ID}"
  WAN_NATIVE_TARGET="NODE${NODE_ID}"
fi

WAN_NATIVE="$(json_get_section2_value "VLAN" "WAN_Native" "$WAN_NATIVE_KEY" "$SETTINGS_FILE" 2>/dev/null)"
[ -n "$WAN_NATIVE" ] || WAN_NATIVE="$(json_get_flag "$WAN_NATIVE_KEY" "none" "$SETTINGS_FILE" 2>/dev/null)"
case "$WAN_NATIVE" in
  ''|none|NONE|asus|ASUS) WAN_NATIVE="none" ;;
esac
WAN_DHCP_WAN_NATIVE_IP_CONFIG="$(json_get_section2_value "VLAN" "WAN_Native" "MAIN_WAN_NATIVE_IP" "$SETTINGS_FILE" 2>/dev/null)"
WAN_DHCP_ASUS_IP_CONFIG="$(json_get_section2_value "VLAN" "WAN_Native" "MAIN_ASUS_IP" "$SETTINGS_FILE" 2>/dev/null)"
# Pre-structured settings saved these endpoint keys at document root. Preserve
# that migration read while all current saves write VLAN.WAN_Native.
case "$WAN_DHCP_WAN_NATIVE_IP_CONFIG" in '')
  WAN_DHCP_WAN_NATIVE_IP_CONFIG="$(json_get_flag "MAIN_WAN_NATIVE_IP" "none" "$SETTINGS_FILE" 2>/dev/null)"
  ;;
esac
case "$WAN_DHCP_ASUS_IP_CONFIG" in '')
  WAN_DHCP_ASUS_IP_CONFIG="$(json_get_flag "MAIN_ASUS_IP" "none" "$SETTINGS_FILE" 2>/dev/null)"
  ;;
esac

wan_vlan_valid() {
  _wvv="$1"
  case "$_wvv" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_wvv" -ge 2 ] 2>/dev/null && [ "$_wvv" -le 4094 ] 2>/dev/null
}

iface_exists() {
  [ -d "$MERV_WAN_NET_ROOT/$1" ]
}

bridge_has_member() {
  _whm_br="$1"
  _whm_if="$2"
  [ -n "$_whm_br" ] && [ -n "$_whm_if" ] || return 1
  if [ -d "$MERV_WAN_NET_ROOT/$_whm_br/brif" ]; then
    [ -e "$MERV_WAN_NET_ROOT/$_whm_br/brif/$_whm_if" ]
    return $?
  fi
  brctl show "$_whm_br" 2>/dev/null | awk -v IF="$_whm_if" '
    NR==1 { next }
    { for (i=1; i<=NF; i++) if ($i == IF) { found=1; exit } }
    END { exit(found ? 0 : 1) }
  '
}

bridge_for_iface() {
  _wbf_if="$1"
  for _wbf_path in "$MERV_WAN_NET_ROOT"/*/brif/"$_wbf_if"; do
    [ -e "$_wbf_path" ] || continue
    _wbf_bridge="${_wbf_path%/brif/$_wbf_if}"
    printf '%s\n' "${_wbf_bridge##*/}"
    return 0
  done
  return 1
}

native_members() {
  if iface_exists "$UPLINK_PORT" && bridge_has_member "$DEFAULT_BRIDGE" "$UPLINK_PORT"; then
    printf '%s\n' "$UPLINK_PORT"
  fi
  for _wnm_path in "$MERV_WAN_NET_ROOT/$UPLINK_PORT".[0-9]*; do
    [ -d "$_wnm_path" ] || continue
    _wnm_if="${_wnm_path##*/}"
    bridge_has_member "$DEFAULT_BRIDGE" "$_wnm_if" && printf '%s\n' "$_wnm_if"
  done
}

vlan_iface_matches() {
  _wvim_if="$1"
  _wvim_vid="$2"
  _wvim_file="$MERV_WAN_PROC_VLAN_ROOT/$_wvim_if"
  # An existing upper is untrusted until both the VID and its lower device
  # are positively identified.  Do not infer identity from the interface
  # name: if procfs metadata is unavailable, fail closed rather than risk
  # deleting or attaching an unrelated interface.
  [ -f "$_wvim_file" ] || return 1
  grep -Eq "VID:[[:space:]]*$_wvim_vid([[:space:]]|$)" "$_wvim_file" 2>/dev/null || return 1
  grep -Eq "Device:[[:space:]]*$UPLINK_PORT([[:space:]]|$)" "$_wvim_file" 2>/dev/null || return 1
}

wan_list_contains_vid() {
  _wlcv_list="$1"
  _wlcv_want="$2"
  _wlcv_oldifs="$IFS"
  IFS=', '
  for _wlcv_item in $_wlcv_list; do
    [ "$_wlcv_item" = "$_wlcv_want" ] && { IFS="$_wlcv_oldifs"; return 0; }
  done
  IFS="$_wlcv_oldifs"
  return 1
}

wan_setting_conflict() {
  _wsc_vid="$1"
  [ "$_wsc_vid" != "none" ] || return 1

  MAX_SSIDS="$(json_get_section_value "Hardware" "MAX_SSIDS" "$SETTINGS_FILE" 2>/dev/null)"
  case "$MAX_SSIDS" in
    ''|0|*[!0-9]*)
      MAX_SSIDS="$(json_get_section_value "Limits" "MAX_SSID_CAP" "$SETTINGS_FILE" 2>/dev/null)"
      ;;
  esac
  case "$MAX_SSIDS" in ''|0|*[!0-9]*) MAX_SSIDS=16 ;; esac
  [ "$MAX_SSIDS" -le 64 ] 2>/dev/null || MAX_SSIDS=64
  ssid_filter_init "$NODE_ID"

  _wsc_i=1
  while [ "$_wsc_i" -le "$MAX_SSIDS" ]; do
    _wsc_ssid="$(get_ssid_slot_value "$_wsc_i" "$SETTINGS_FILE" 2>/dev/null)"
    _wsc_vlan="$(get_vlan_slot_value "$_wsc_i" "$SETTINGS_FILE" 2>/dev/null)"
    if [ -n "$_wsc_ssid" ] && [ "$_wsc_ssid" != "unused-placeholder" ] && [ "$_wsc_vlan" = "$_wsc_vid" ]; then
      error -c cli,vlan "WAN Native: VLAN $_wsc_vid conflicts with SSID slot $_wsc_i on $WAN_NATIVE_TARGET"
      return 0
    fi
    _wsc_i=$((_wsc_i + 1))
  done

  _wsc_i=1
  while [ "$_wsc_i" -le 8 ]; do
    if [ "$NODE_ID" = "none" ]; then
      _wsc_key="ETH${_wsc_i}_VLAN"
    else
      _wsc_key="NODE${NODE_ID}_ETH${_wsc_i}_VLAN"
    fi
    _wsc_vlan="$(json_get_scalar "$_wsc_key" "$SETTINGS_FILE" 2>/dev/null)"
    if [ "$_wsc_vlan" = "$_wsc_vid" ]; then
      error -c cli,vlan "WAN Native: VLAN $_wsc_vid conflicts with LAN port $_wsc_i on $WAN_NATIVE_TARGET"
      return 0
    fi
    _wsc_i=$((_wsc_i + 1))
  done

  # Trunks are a MAIN-only feature. Nodes receive the shared settings file,
  # but mervlan_trunk.sh is intentionally not applied to node LAN ports, so a
  # MAIN trunk VLAN must not falsely block a node-local WAN Native VLAN.
  if [ "$NODE_ID" = "none" ]; then
    _wsc_i=1
    while [ "$_wsc_i" -le 8 ]; do
      _wsc_trunk="$(json_get_flag "TRUNK${_wsc_i}" "0" "$SETTINGS_FILE" 2>/dev/null)"
      if [ "$_wsc_trunk" = "1" ]; then
        _wsc_tagged="$(json_get_flag "TAGGED_TRUNK${_wsc_i}" "none" "$SETTINGS_FILE" 2>/dev/null)"
        _wsc_untagged="$(json_get_flag "UNTAGGED_TRUNK${_wsc_i}" "none" "$SETTINGS_FILE" 2>/dev/null)"
        if wan_list_contains_vid "$_wsc_tagged" "$_wsc_vid" || [ "$_wsc_untagged" = "$_wsc_vid" ]; then
          error -c cli,vlan "WAN Native: VLAN $_wsc_vid conflicts with trunk $_wsc_i on $WAN_NATIVE_TARGET"
          return 0
        fi
      fi
      _wsc_i=$((_wsc_i + 1))
    done
  fi

  return 1
}

validate_settings() {
  if [ "$WAN_NATIVE" != "none" ] && ! wan_vlan_valid "$WAN_NATIVE"; then
    error -c cli,vlan "WAN Native: $WAN_NATIVE_KEY must be ASUS/none or VLAN 2-4094 (got '$WAN_NATIVE')"
    return 1
  fi

  if [ "$WAN_NATIVE" != "none" ] && wan_setting_conflict "$WAN_NATIVE"; then
    return 1
  fi

  return 0
}

validate_live_target() {
  iface_exists "$DEFAULT_BRIDGE" || {
    error -c cli,vlan "WAN Native: $DEFAULT_BRIDGE is missing during live preflight"
    return 1
  }
  iface_exists "$UPLINK_PORT" || {
    error -c cli,vlan "WAN Native: physical uplink $UPLINK_PORT is missing during live preflight"
    return 1
  }

  # Validate every currently attached tagged upper before any mutation.  This
  # proves stale-member ownership as well as the requested target; a name such
  # as eth0.123 alone is not sufficient identity evidence.
  _wvlt_members="$(native_members)"
  if [ "$WAN_NATIVE" != "none" ] && [ -z "$_wvlt_members" ]; then
    error -c cli,vlan "WAN Native: no existing ASUS/native $DEFAULT_BRIDGE uplink path on $UPLINK_PORT"
    return 1
  fi
  for _wvlt_if in $_wvlt_members; do
    case "$_wvlt_if" in
      "$UPLINK_PORT".[0-9]*)
        _wvlt_vid="${_wvlt_if#"$UPLINK_PORT."}"
        wan_vlan_valid "$_wvlt_vid" || {
          error -c cli,vlan "WAN Native: attached upper $_wvlt_if has an invalid VLAN identity"
          return 1
        }
        vlan_iface_matches "$_wvlt_if" "$_wvlt_vid" || {
          error -c cli,vlan "WAN Native: attached upper $_wvlt_if lacks verified VLAN/lower-device metadata"
          return 1
        }
        _wvlt_bridge="$(bridge_for_iface "$_wvlt_if" 2>/dev/null || printf '')"
        if [ -n "$_wvlt_bridge" ] && [ "$_wvlt_bridge" != "$DEFAULT_BRIDGE" ]; then
          error -c cli,vlan "WAN Native: $_wvlt_if is already owned by bridge $_wvlt_bridge"
          return 1
        fi
        ;;
    esac
  done

  [ "$WAN_NATIVE" != "none" ] || return 0
  _wvlt_if="$UPLINK_PORT.$WAN_NATIVE"
  if iface_exists "$_wvlt_if"; then
    vlan_iface_matches "$_wvlt_if" "$WAN_NATIVE" || {
      error -c cli,vlan "WAN Native: existing $_wvlt_if does not match VLAN $WAN_NATIVE on $UPLINK_PORT"
      return 1
    }
    _wvlt_bridge="$(bridge_for_iface "$_wvlt_if" 2>/dev/null || printf '')"
    if [ -n "$_wvlt_bridge" ] && [ "$_wvlt_bridge" != "$DEFAULT_BRIDGE" ]; then
      error -c cli,vlan "WAN Native: $_wvlt_if is already owned by bridge $_wvlt_bridge"
      return 1
    fi
  fi
  return 0
}

bridge_mac_read() {
  cat "$MERV_WAN_NET_ROOT/$DEFAULT_BRIDGE/address" 2>/dev/null
}

bridge_mac_restore() {
  _wmr_want="$1"
  [ -n "$_wmr_want" ] || return 0
  _wmr_have="$(bridge_mac_read)"
  [ "$_wmr_have" = "$_wmr_want" ] && return 0
  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] WAN Native: would restore $DEFAULT_BRIDGE MAC $_wmr_want"
    return 0
  fi
  ip link set "$DEFAULT_BRIDGE" address "$_wmr_want" 2>/dev/null || return 1
  [ "$(bridge_mac_read)" = "$_wmr_want" ]
}

bridge_add() {
  _wba_if="$1"
  bridge_has_member "$DEFAULT_BRIDGE" "$_wba_if" && return 0
  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] WAN Native: brctl addif $DEFAULT_BRIDGE $_wba_if"
    return 0
  fi
  brctl addif "$DEFAULT_BRIDGE" "$_wba_if" 2>/dev/null || return 1
  bridge_has_member "$DEFAULT_BRIDGE" "$_wba_if"
}

bridge_del() {
  _wbd_if="$1"
  bridge_has_member "$DEFAULT_BRIDGE" "$_wbd_if" || return 0
  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] WAN Native: brctl delif $DEFAULT_BRIDGE $_wbd_if"
    return 0
  fi
  brctl delif "$DEFAULT_BRIDGE" "$_wbd_if" 2>/dev/null || return 1
  ! bridge_has_member "$DEFAULT_BRIDGE" "$_wbd_if"
}

ensure_target_iface() {
  _weti_if="$1"
  _weti_vid="$2"

  if [ "$_weti_vid" = "none" ]; then
    iface_exists "$UPLINK_PORT" || {
      error -c cli,vlan "WAN Native: physical uplink $UPLINK_PORT is missing"
      return 1
    }
    if [ "$DRY_RUN" = "yes" ]; then
      info -c cli,vlan "[DRY-RUN] WAN Native: ip link set $UPLINK_PORT up"
      return 0
    fi
    ip link set "$UPLINK_PORT" up 2>/dev/null || return 1
    return 0
  fi

  if iface_exists "$_weti_if"; then
    vlan_iface_matches "$_weti_if" "$_weti_vid" || return 1
  else
    if [ "$DRY_RUN" = "yes" ]; then
      info -c cli,vlan "[DRY-RUN] WAN Native: ip link add link $UPLINK_PORT name $_weti_if type vlan id $_weti_vid"
    else
      ip link add link "$UPLINK_PORT" name "$_weti_if" type vlan id "$_weti_vid" 2>/dev/null || return 1
      iface_exists "$_weti_if" || return 1
    fi
    WAN_CREATED_IF="$_weti_if"
  fi

  if [ "$DRY_RUN" = "yes" ]; then
    info -c cli,vlan "[DRY-RUN] WAN Native: ip link set $_weti_if up"
    return 0
  fi
  ip link set "$_weti_if" up 2>/dev/null || return 1
  vlan_iface_matches "$_weti_if" "$_weti_vid"
}

rollback_original() {
  _wro_original="$1"
  _wro_target="$2"
  _wro_mac="$3"
  [ "$DRY_RUN" = "yes" ] && return 0

  persistent_debug_event bridge-rollback-start "target=$_wro_target"
  persistent_debug_breadcrumb bridge-rollback-start "target=$_wro_target"

  _wro_ok=1
  _wro_is_original=0
  for _wro_if in $_wro_original; do
    [ "$_wro_if" = "$_wro_target" ] && _wro_is_original=1
  done

  # Avoid a duplicate path during rollback as well: if the replacement was not
  # part of the captured original topology, remove it before restoring the old
  # member(s). A failed removal stops a dual-path rollback from being created.
  if [ "$_wro_is_original" -eq 0 ] && bridge_has_member "$DEFAULT_BRIDGE" "$_wro_target"; then
    if ! bridge_del "$_wro_target"; then
      bridge_mac_restore "$_wro_mac" || :
      return 1
    fi
  fi

  for _wro_if in $_wro_original; do
    iface_exists "$_wro_if" || { _wro_ok=0; continue; }
    bridge_add "$_wro_if" || _wro_ok=0
  done

  bridge_mac_restore "$_wro_mac" || _wro_ok=0

  if [ -n "${WAN_CREATED_IF:-}" ] && ! bridge_has_member "$DEFAULT_BRIDGE" "$WAN_CREATED_IF"; then
    ip link del "$WAN_CREATED_IF" 2>/dev/null || :
  fi

  if [ "$_wro_ok" -eq 1 ]; then
    persistent_debug_event bridge-rollback-complete "result=ok"
    persistent_debug_breadcrumb bridge-restored "result=ok"
    return 0
  fi
  persistent_debug_event bridge-rollback-complete "result=failed"
  return 1
}

# Transaction state is deliberately process-local.  The capture is complete
# before the first bridge mutation, and remains active until verification has
# succeeded.  INT/TERM and an unexpected zero-status EXIT therefore all take
# the same idempotent restoration path.
WAN_TXN_ACTIVE=0
WAN_TXN_ROLLBACKING=0
WAN_TXN_ORIGINAL=""
WAN_TXN_TARGET=""
WAN_TXN_MAC=""

wan_txn_restore() {
  [ "${WAN_TXN_ACTIVE:-0}" -eq 1 ] || return 0
  [ "${WAN_TXN_ROLLBACKING:-0}" -eq 0 ] || return 0
  WAN_TXN_ROLLBACKING=1
  # Ignore re-entrant signals while the captured path is being restored; a
  # second interrupt must not cut the best-effort rollback itself short.
  trap ':' INT TERM
  rollback_original "$WAN_TXN_ORIGINAL" "$WAN_TXN_TARGET" "$WAN_TXN_MAC"
  _wtr_rc=$?
  wan_main_dhcp_restore_l3
  _wtr_l3_rc=$?
  if [ "$_wtr_l3_rc" -ne 0 ]; then
    _wtr_rc=1
    error -c cli,vlan "WAN Native: MAIN DHCP L3 address rollback could not be verified"
  fi
  trap - INT TERM
  WAN_TXN_ACTIVE=0
  WAN_TXN_ROLLBACKING=0
  if [ "$_wtr_rc" -eq 0 ]; then
    persistent_debug_complete rollback-ok
  else
    persistent_debug_complete rollback-failed
  fi
  return "$_wtr_rc"
}

wan_txn_on_signal() {
  _wts_status="$1"
  # Stop a second signal from interrupting restoration and making the outcome
  # ambiguous.  The original signal's conventional nonzero status is kept
  # unless restoration itself fails (which is still nonzero).
  trap - INT TERM
  wan_txn_restore || _wts_status=1
  exit "$_wts_status"
}

wan_txn_on_exit() {
  _wte_status="$1"
  [ "${WAN_TXN_ACTIVE:-0}" -eq 1 ] || return "$_wte_status"
  trap - INT TERM
  wan_txn_restore || _wte_status=1
  # An EXIT while a transaction is active is abnormal even when the caller
  # requested status zero.  Force a meaningful failure after best-effort
  # restoration; remove the trap first to avoid recursion.
  [ "$_wte_status" -ne 0 ] || _wte_status=1
  trap - EXIT
  exit "$_wte_status"
}

wan_txn_begin() {
  WAN_TXN_ORIGINAL="$1"
  WAN_TXN_TARGET="$2"
  WAN_TXN_MAC="$3"
  WAN_TXN_ACTIVE=1
  WAN_TXN_ROLLBACKING=0
  persistent_debug_event transaction-armed "target=$WAN_TXN_TARGET"
  persistent_debug_breadcrumb transaction-armed "target=$WAN_TXN_TARGET"
  trap 'wan_txn_on_signal 130' INT
  trap 'wan_txn_on_signal 143' TERM
  trap 'wan_txn_on_exit $?' EXIT
}

wan_txn_commit() {
  persistent_debug_event transaction-commit "result=ok"
  persistent_debug_complete ok
  WAN_TXN_ACTIVE=0
  WAN_DHCP_L3_ACTIVE=0
  trap - INT TERM EXIT
}

verify_live() {
  [ "$DRY_RUN" = "yes" ] && return 0
  iface_exists "$DEFAULT_BRIDGE" || {
    error -c cli,vlan "WAN Native: $DEFAULT_BRIDGE is missing"
    return 1
  }
  iface_exists "$UPLINK_PORT" || {
    error -c cli,vlan "WAN Native: physical uplink $UPLINK_PORT is missing"
    return 1
  }

  _wvl_members="$(native_members)"

  if [ "$WAN_NATIVE" = "none" ]; then
    # Current supported ASUS restore boundary is deliberately narrow: br0 must
    # use the positively discovered physical uplink and no tagged native upper.
    # Do not guess at firmware-owned tagged native topology on unknown devices.
    bridge_has_member "$DEFAULT_BRIDGE" "$UPLINK_PORT" || {
      error -c cli,vlan "WAN Native: ASUS mode requires $DEFAULT_BRIDGE -> physical uplink $UPLINK_PORT"
      return 1
    }
    [ "$(printf '%s\n' "$_wvl_members" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] || {
      error -c cli,vlan "WAN Native: ASUS mode has ambiguous $DEFAULT_BRIDGE uplink membership (${_wvl_members:-none})"
      return 1
    }
    [ "$_wvl_members" = "$UPLINK_PORT" ] || {
      error -c cli,vlan "WAN Native: ASUS mode expected $UPLINK_PORT but found ${_wvl_members:-none}"
      return 1
    }
    return 0
  fi

  _wvl_target="$UPLINK_PORT.$WAN_NATIVE"
  iface_exists "$_wvl_target" || {
    error -c cli,vlan "WAN Native: expected interface $_wvl_target is missing"
    return 1
  }
  vlan_iface_matches "$_wvl_target" "$WAN_NATIVE" || {
    error -c cli,vlan "WAN Native: $_wvl_target VLAN metadata is wrong"
    return 1
  }
  bridge_has_member "$DEFAULT_BRIDGE" "$_wvl_target" || {
    error -c cli,vlan "WAN Native: $_wvl_target is not attached to $DEFAULT_BRIDGE"
    return 1
  }

  _wvl_count=0
  _wvl_seen=0
  for _wvl_if in $_wvl_members; do
    _wvl_count=$((_wvl_count + 1))
    [ "$_wvl_if" = "$_wvl_target" ] && _wvl_seen=1
  done
  if [ "$_wvl_seen" -ne 1 ] || [ "$_wvl_count" -ne 1 ]; then
    error -c cli,vlan "WAN Native: ambiguous $DEFAULT_BRIDGE uplink membership (expected only $_wvl_target; found: ${_wvl_members:-none})"
    return 1
  fi

  return 0
}

# ASUSWRT keeps the LAN DHCP client bound to br0.  Replacing br0's native
# lower transport changes its L2 domain, so a DHCP lease from the old domain
# must be replaced by a fresh, authenticated ASUS LAN client.  Only MAIN in
# DHCP-LAN mode needs this.  Nodes and static-LAN MAIN routers are deliberately
# rejected before any bridge mutation.
WAN_DHCP_L3_ACTIVE=0
WAN_DHCP_L3_ORIGINAL=""
WAN_DHCP_EXPECTED=""
WAN_DHCP_OLD_PID=""
WAN_DHCP_OLD_START=""
WAN_DHCP_CALLBACK=""
WAN_DHCP_HOSTNAME=""
WAN_DHCP_LIFECYCLE_DISRUPTED=0
WAN_DHCP_PRE_RESTART_ADDRESS=""
WAN_DHCP_RELEASED=0
WAN_DHCP_RELEASED_CLIENT_STILL_LIVE=0

# Persistent diagnostics are opt-in and observational. They are initialized
# for every invocation but a run/breadcrumb is created only for a live numeric
# MAIN transaction after all non-mutating preflight checks pass.
persistent_debug_init_from_settings "${SETTINGS_FILE:-}" 2>/dev/null || :

wan_main_dhcp_proto() {
  # The explicit override exists only for deterministic isolated tests.  On a
  # router, NVRAM is authoritative and a failed read is unsafe.
  if [ -n "${MERV_WAN_DHCP_TEST_LAN_PROTO:-}" ]; then
    printf '%s\n' "$MERV_WAN_DHCP_TEST_LAN_PROTO"
    return 0
  fi
  _wmdp_value="$(nvram get lan_proto 2>/dev/null)" || return 1
  case "$_wmdp_value" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '%s\n' "$_wmdp_value"
}

wan_main_dhcp_address_read() {
  if [ -n "$MERV_WAN_DHCP_TEST_ADDRESS_FILE" ]; then
    [ -r "$MERV_WAN_DHCP_TEST_ADDRESS_FILE" ] || return 1
    _wmdar_value="$(sed -n '1p' "$MERV_WAN_DHCP_TEST_ADDRESS_FILE" 2>/dev/null)"
  else
    _wmdar_value="$(ip -4 addr show dev "$DEFAULT_BRIDGE" 2>/dev/null | awk '/[[:space:]]inet[[:space:]]/ { print $2; exit }')"
  fi
  case "$_wmdar_value" in
    ''|*[!0-9./]*) return 1 ;;
  esac
  _wmdar_host="${_wmdar_value%%/*}"
  printf '%s\n' "$_wmdar_host" | awk -F. 'NF==4 { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1; exit 0 } { exit 1 }' || return 1
  printf '%s\n' "$_wmdar_host"
}

wan_main_dhcp_expected_address() {
  # The expected post-handoff endpoint must come from an explicit runtime
  # contract.  lan_ipaddr is the old/static NVRAM value on some firmware and
  # is not evidence that DHCP acquired the new lease.
  if [ -n "${MERV_WAN_DHCP_EXPECTED_ADDRESS:-}" ]; then
    _wmdea_value="$MERV_WAN_DHCP_EXPECTED_ADDRESS"
  elif [ "$WAN_NATIVE" = "none" ]; then
    _wmdea_value="$WAN_DHCP_ASUS_IP_CONFIG"
  else
    _wmdea_value="$WAN_DHCP_WAN_NATIVE_IP_CONFIG"
  fi
  case "$_wmdea_value" in ''|*[!0-9.]*|*.*.*.*.*) return 1 ;; esac
  printf '%s\n' "$_wmdea_value" | awk -F. 'NF==4 { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1; exit 0 } { exit 1 }' || return 1
  printf '%s\n' "$_wmdea_value"
}

wan_main_dhcp_address_matches() {
  [ -n "$1" ] || return 1
  _wmdam_have="$(wan_main_dhcp_address_read 2>/dev/null || printf '')"
  [ "$_wmdam_have" = "$1" ]
}

wan_main_dhcp_address_present() {
  _wmdap_want="$1"
  [ -n "$_wmdap_want" ] || return 1
  if [ -n "$MERV_WAN_DHCP_TEST_ADDRESS_FILE" ]; then
    [ "$(wan_main_dhcp_address_read 2>/dev/null || printf '')" = "$_wmdap_want" ]
    return $?
  fi
  ip -4 addr show dev "$DEFAULT_BRIDGE" 2>/dev/null |
    awk -v WANT="$_wmdap_want" '$1 == "inet" { split($2, a, "/"); if (a[1] == WANT) found=1 } END { exit(found ? 0 : 1) }'
}

wan_main_dhcp_address_absent() {
  ! wan_main_dhcp_address_present "$1"
}

wan_main_dhcp_route_ready() {
  # The isolated fixture models only address/client lifecycle.  Production
  # must also retain a default route through the LAN bridge before commit.
  [ -n "$MERV_WAN_DHCP_TEST_ADDRESS_FILE" ] && return 0
  ip -4 route show default dev "$DEFAULT_BRIDGE" 2>/dev/null |
    grep -Eq '^default([[:space:]]|$)'
}

wan_main_dhcp_state_ready() {
  _wmdsr_expected="$1"
  [ -n "$_wmdsr_expected" ] || return 1
  wan_main_dhcp_address_matches "$_wmdsr_expected" || return 1
  if [ -n "$WAN_DHCP_L3_ORIGINAL" ] && [ "$WAN_DHCP_L3_ORIGINAL" != "$_wmdsr_expected" ]; then
    wan_main_dhcp_address_present "$WAN_DHCP_L3_ORIGINAL" && return 1
  fi
  wan_main_dhcp_route_ready
}

wan_main_dhcp_preflight() {
  [ "$NODE_ID" = "none" ] || return 0
  # An ASUS-mode apply needs DHCP ownership only while actually returning from
  # a MerVLAN tagged transport. An already-normal ASUS bridge remains entirely
  # firmware-owned and is not churned merely because this helper is invoked.
  if [ "$WAN_NATIVE" = "none" ]; then
    _wmdpf_native="$(native_members)"
    case "$_wmdpf_native" in *"$UPLINK_PORT".[0-9]*) ;; *) WAN_DHCP_TRANSITION=0; return 0 ;; esac
  fi

  _wmdpf_proto="$(wan_main_dhcp_proto 2>/dev/null || printf '')"
  case "$_wmdpf_proto" in
    dhcp) ;;
    static)
      error -c cli,vlan "WAN Native: numeric MAIN transport requires LAN DHCP; refusing static LAN before mutation"
      return 1
      ;;
    *)
      error -c cli,vlan "WAN Native: cannot verify MAIN LAN protocol; refusing numeric transport before mutation"
      return 1
      ;;
  esac

  WAN_DHCP_EXPECTED="$(wan_main_dhcp_expected_address 2>/dev/null || printf '')"
  [ -n "$WAN_DHCP_EXPECTED" ] || {
    if [ "$WAN_NATIVE" = "none" ]; then
      error -c cli,vlan "WAN Native: ASUS/default DHCP reservation is not configured; refusing return to ASUS before mutation"
    else
      error -c cli,vlan "WAN Native: WAN Native DHCP reservation is not configured; refusing tagged transition before mutation"
    fi
    return 1
  }
  WAN_DHCP_L3_ORIGINAL="$(wan_main_dhcp_address_read 2>/dev/null || printf '')"
  [ -n "$WAN_DHCP_L3_ORIGINAL" ] || {
    error -c cli,vlan "WAN Native: MAIN DHCP has no current address to protect"
    return 1
  }
  wan_main_dhcp_capture_existing || {
    error -c cli,vlan "WAN Native: MAIN DHCP client identity is invalid; refusing transport mutation"
    return 1
  }
  WAN_DHCP_TRANSITION=1
  return 0
}

wan_main_dhcp_callback_valid() {
  case "$1" in /sbin/rc|/tmp/udhcpc_lan) return 0 ;; esac
  return 1
}

wan_main_dhcp_hostname_valid() {
  # ASUSWRT's observed LAN client hostname is ZenWiFi_XT8-79F0.  Keep the
  # accepted alphabet bounded while allowing that firmware underscore.
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*|*..*|*.) return 1 ;; esac
  [ "${#1}" -le 63 ]
}

# Parse NUL-separated argv, never shell-evaluate it.  The allowlist preserves
# the exact LAN ownership contract while deliberately rejecting arbitrary
# process text, extra options, interfaces, callbacks, or pidfiles.
wan_main_dhcp_cmd_capture() {
  _wmdcc_pid="$1"
  _wmdcc_file="$MERV_WAN_DHCP_PROC_ROOT/$_wmdcc_pid/cmdline"
  [ -r "$_wmdcc_file" ] || return 1
  # The normal volatile MerVLAN tmp root may not exist immediately after a
  # reboot. Parsing an authenticated argv remains read-only with respect to
  # the router; use the always-present system tmp root rather than creating
  # state solely for a preflight check.
  _wmdcc_tmp_root="${MERV_WAN_DHCP_TMP_ROOT:-${TMPDIR:-/tmp}}"
  [ -d "$_wmdcc_tmp_root" ] || _wmdcc_tmp_root=/tmp
  [ -d "$_wmdcc_tmp_root" ] || return 1
  _wmdcc_tmp="$_wmdcc_tmp_root/mervlan-wan-dhcp.$$.${_wmdcc_pid}"
  umask 077
  tr '\000' '\n' < "$_wmdcc_file" > "$_wmdcc_tmp" 2>/dev/null || { rm -f "$_wmdcc_tmp"; return 1; }
  WAN_DHCP_CALLBACK=""; WAN_DHCP_HOSTNAME=""
  _wmdcc_seen_i=0; _wmdcc_seen_p=0; _wmdcc_seen_s=0; _wmdcc_seen_h=0
  _wmdcc_expect="argv0"
  while IFS= read -r _wmdcc_arg || [ -n "$_wmdcc_arg" ]; do
    case "$_wmdcc_expect" in
      argv0)
        case "$_wmdcc_arg" in udhcpc|*/udhcpc) ;; *) rm -f "$_wmdcc_tmp"; return 1 ;; esac
        _wmdcc_expect="option"
        ;;
      interface)
        [ "$_wmdcc_arg" = "$DEFAULT_BRIDGE" ] && [ "$_wmdcc_seen_i" -eq 0 ] || { rm -f "$_wmdcc_tmp"; return 1; }
        _wmdcc_seen_i=1; _wmdcc_expect="option"
        ;;
      pidfile)
        [ "$_wmdcc_arg" = "$MERV_WAN_DHCP_PIDFILE" ] && [ "$_wmdcc_seen_p" -eq 0 ] || { rm -f "$_wmdcc_tmp"; return 1; }
        _wmdcc_seen_p=1; _wmdcc_expect="option"
        ;;
      callback)
        wan_main_dhcp_callback_valid "$_wmdcc_arg" && [ "$_wmdcc_seen_s" -eq 0 ] || { rm -f "$_wmdcc_tmp"; return 1; }
        WAN_DHCP_CALLBACK="$_wmdcc_arg"; _wmdcc_seen_s=1; _wmdcc_expect="option"
        ;;
      hostname)
        wan_main_dhcp_hostname_valid "$_wmdcc_arg" && [ "$_wmdcc_seen_h" -eq 0 ] || { rm -f "$_wmdcc_tmp"; return 1; }
        WAN_DHCP_HOSTNAME="$_wmdcc_arg"; _wmdcc_seen_h=1; _wmdcc_expect="option"
        ;;
      option)
        case "$_wmdcc_arg" in
          -i) _wmdcc_expect="interface" ;;
          -p) _wmdcc_expect="pidfile" ;;
          -s) _wmdcc_expect="callback" ;;
          -H) _wmdcc_expect="hostname" ;;
          *) rm -f "$_wmdcc_tmp"; return 1 ;;
        esac
        ;;
    esac
  done < "$_wmdcc_tmp"
  rm -f "$_wmdcc_tmp"
  [ "$_wmdcc_expect" = option ] && [ "$_wmdcc_seen_i" -eq 1 ] &&
    [ "$_wmdcc_seen_p" -eq 1 ] && [ "$_wmdcc_seen_s" -eq 1 ]
}

wan_main_dhcp_pid_read() {
  [ -r "$MERV_WAN_DHCP_PIDFILE" ] || return 1
  _wmdpr_pid="$(sed -n '1p' "$MERV_WAN_DHCP_PIDFILE" 2>/dev/null)"
  merv_identity_positive_uint "$_wmdpr_pid" || return 1
  printf '%s\n' "$_wmdpr_pid"
}

wan_main_dhcp_pid_start() {
  _wmdps_pid="$1"
  _wmdps_sidecar="${MERV_WAN_DHCP_PIDFILE}.start"
  if [ -r "$_wmdps_sidecar" ]; then
    _wmdps_start="$(sed -n '1p' "$_wmdps_sidecar" 2>/dev/null)"
  else
    _wmdps_start="$(merv_identity_proc_start "$_wmdps_pid" "$MERV_WAN_DHCP_PROC_ROOT" 2>/dev/null || printf '')"
  fi
  merv_identity_positive_uint "$_wmdps_start" || return 1
  printf '%s\n' "$_wmdps_start"
}

wan_main_dhcp_pid_authenticate() {
  _wmdpa_pid="$1"; _wmdpa_start="$2"
  merv_identity_matches "$_wmdpa_pid" "$_wmdpa_start" "$MERV_WAN_DHCP_PROC_ROOT" 2>/dev/null || return 1
  wan_main_dhcp_cmd_capture "$_wmdpa_pid"
}

wan_main_dhcp_capture_existing() {
  WAN_DHCP_OLD_PID="$(wan_main_dhcp_pid_read 2>/dev/null || printf '')"
  [ -n "$WAN_DHCP_OLD_PID" ] || return 1
  WAN_DHCP_OLD_START="$(wan_main_dhcp_pid_start "$WAN_DHCP_OLD_PID" 2>/dev/null || printf '')"
  [ -n "$WAN_DHCP_OLD_START" ] || return 1
  wan_main_dhcp_pid_authenticate "$WAN_DHCP_OLD_PID" "$WAN_DHCP_OLD_START" || return 1
  [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 1 ] || return 1
  [ "$(wan_main_dhcp_any_client_count 2>/dev/null || printf x)" = 1 ]
}

wan_main_dhcp_client_count() {
  _wmdc_count=0
  for _wmdc_path in "$MERV_WAN_DHCP_PROC_ROOT"/[0-9]*; do
    [ -d "$_wmdc_path" ] || continue
    _wmdc_pid="${_wmdc_path##*/}"
    wan_main_dhcp_cmd_capture "$_wmdc_pid" 2>/dev/null && _wmdc_count=$((_wmdc_count + 1))
  done
  printf '%s\n' "$_wmdc_count"
}

# Count every udhcpc visibly bound to br0, including one whose argv no longer
# satisfies our launch allowlist. It is unsafe to signal such a process, but
# also unsafe to ignore it and launch a second LAN DHCP client beside it.
wan_main_dhcp_any_client_count() {
  _wmdac_count=0
  for _wmdac_path in "$MERV_WAN_DHCP_PROC_ROOT"/[0-9]*; do
    [ -d "$_wmdac_path" ] || continue
    _wmdac_file="$_wmdac_path/cmdline"
    [ -r "$_wmdac_file" ] || continue
    tr '\000' '\n' < "$_wmdac_file" 2>/dev/null |
      awk -v BR="$DEFAULT_BRIDGE" '
        NR == 1 { client = ($0 == "udhcpc" || $0 ~ /\/udhcpc$/); next }
        prior == "-i" && $0 == BR { bound = 1 }
        { prior = $0 }
        END { exit(client && bound ? 0 : 1) }
      ' && _wmdac_count=$((_wmdac_count + 1))
  done
  printf '%s\n' "$_wmdac_count"
}

wan_main_dhcp_old_exited() {
  _wmdoe_pid="$1"
  [ ! -d "$MERV_WAN_DHCP_PROC_ROOT/$_wmdoe_pid" ] || return 1
  [ "$MERV_WAN_DHCP_PROC_ROOT" != /proc ] || ! kill -0 "$_wmdoe_pid" 2>/dev/null
}

wan_main_dhcp_clear_dead_pidfile() {
  _wmdcdp_pid="$1"
  wan_main_dhcp_old_exited "$_wmdcdp_pid" || return 1
  [ -r "$MERV_WAN_DHCP_PIDFILE" ] || return 0
  _wmdcdp_recorded="$(sed -n '1p' "$MERV_WAN_DHCP_PIDFILE" 2>/dev/null)"
  [ "$_wmdcdp_recorded" = "$_wmdcdp_pid" ] || return 0
  rm -f "$MERV_WAN_DHCP_PIDFILE" "${MERV_WAN_DHCP_PIDFILE}.start" || return 1
}

wan_main_dhcp_wait_address_absent() {
  _wmdwaa_address="$1"
  _wmdwaa_limit="$2"
  case "$_wmdwaa_limit" in ''|*[!0-9]*) return 1 ;; esac
  _wmdwaa_wait=0
  while [ "$_wmdwaa_wait" -le "$_wmdwaa_limit" ]; do
    wan_main_dhcp_address_absent "$_wmdwaa_address" && return 0
    [ "$_wmdwaa_wait" -lt "$_wmdwaa_limit" ] || break
    sleep 1
    _wmdwaa_wait=$((_wmdwaa_wait + 1))
  done
  return 1
}

wan_main_dhcp_release_existing() {
  wan_main_dhcp_pid_authenticate "$WAN_DHCP_OLD_PID" "$WAN_DHCP_OLD_START"
  _wmdre_auth_rc=$?
  [ "$_wmdre_auth_rc" -eq 0 ] || return 1
  WAN_DHCP_PRE_RESTART_ADDRESS="$(wan_main_dhcp_address_read 2>/dev/null || printf '')"
  # The target-domain client may have started but failed to obtain a lease.
  # During rollback it must still be released and replaced on the restored
  # original domain; only the initial, live lease must be present up front.
  [ -n "$WAN_DHCP_PRE_RESTART_ADDRESS" ] ||
    [ "${WAN_DHCP_LIFECYCLE_DISRUPTED:-0}" -eq 1 ] || return 1
  info -c cli,vlan "WAN Native: MAIN DHCP authenticated ASUS LAN client pid=$WAN_DHCP_OLD_PID"
  info -c cli,vlan "WAN Native: MAIN DHCP releasing existing LAN lease"
  persistent_debug_event dhcp-release-start "pid=$WAN_DHCP_OLD_PID old_ip=${WAN_DHCP_PRE_RESTART_ADDRESS:-unknown}"
  persistent_debug_breadcrumb dhcp-release-start "pid=$WAN_DHCP_OLD_PID old_ip=${WAN_DHCP_PRE_RESTART_ADDRESS:-unknown}"
  if [ -n "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ]; then
    printf '%s\n' "release $WAN_DHCP_OLD_PID" >> "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" || return 1
    [ "${MERV_WAN_DHCP_TEST_RELEASE_STAYS_ALIVE:-0}" = 1 ] || {
      if [ "${MERV_WAN_DHCP_TEST_DUPLICATE_BEFORE_START:-0}" = 1 ]; then
        cp -R "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID" \
          "$MERV_WAN_DHCP_PROC_ROOT/$((WAN_DHCP_OLD_PID + 1))" || return 1
      fi
      rm -rf "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID" || return 1
      [ "${MERV_WAN_DHCP_TEST_STALE_PIDFILE:-0}" = 1 ] ||
        rm -f "$MERV_WAN_DHCP_PIDFILE" "${MERV_WAN_DHCP_PIDFILE}.start" || return 1
    }
    [ "${MERV_WAN_DHCP_TEST_STALE_ADDRESS:-0}" = 1 ] || : > "$MERV_WAN_DHCP_TEST_ADDRESS_FILE" || return 1
  else
    # BusyBox udhcpc documents SIGUSR2 as DHCP RELEASE. On this ASUS build it
    # can remain alive in RELEASED state after its callback deconfigures br0.
    kill -USR2 "$WAN_DHCP_OLD_PID" 2>/dev/null || return 1
  fi
  WAN_DHCP_LIFECYCLE_DISRUPTED=1
  WAN_DHCP_RELEASED=1
  wan_main_dhcp_wait_address_absent "$WAN_DHCP_PRE_RESTART_ADDRESS" "$MERV_WAN_DHCP_RELEASE_WAIT_SEC" || {
    persistent_debug_event dhcp-release-complete "result=stale-address pid=$WAN_DHCP_OLD_PID"
    persistent_debug_breadcrumb dhcp-release-complete "result=stale-address pid=$WAN_DHCP_OLD_PID"
    error -c cli,vlan "WAN Native: MAIN DHCP release left stale address $WAN_DHCP_PRE_RESTART_ADDRESS"
    return 1
  }
  if wan_main_dhcp_old_exited "$WAN_DHCP_OLD_PID"; then
    wan_main_dhcp_clear_dead_pidfile "$WAN_DHCP_OLD_PID" || return 1
    [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 0 ] || return 1
    [ "$(wan_main_dhcp_any_client_count 2>/dev/null || printf x)" = 0 ] || return 1
    persistent_debug_event dhcp-release-complete "result=deconfigured-exited pid=$WAN_DHCP_OLD_PID"
    persistent_debug_breadcrumb dhcp-release-complete "result=deconfigured-exited pid=$WAN_DHCP_OLD_PID"
    return 0
  fi
  # Test-only mutation seams exercise the second authentication boundary.
  # Production never mutates /proc or a client pidfile here.
  if [ -n "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ] &&
     [ "${MERV_WAN_DHCP_TEST_REUSE_AFTER_RELEASE:-0}" = 1 ]; then
    sed 's/ 424242$/ 999999999/' "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID/stat" \
      > "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID/stat.next" || return 1
    mv "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID/stat.next" \
      "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID/stat" || return 1
  fi
  if [ -n "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ] &&
     [ "${MERV_WAN_DHCP_TEST_CMDLINE_CHANGE_AFTER_RELEASE:-0}" = 1 ]; then
    printf 'udhcpc\000-i\000%s\000-p\000%s\000-s\000/not-asus/rc\000' \
      "$DEFAULT_BRIDGE" "$MERV_WAN_DHCP_PIDFILE" > "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID/cmdline" || return 1
  fi
  if [ -n "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ] &&
     [ "${MERV_WAN_DHCP_TEST_DUPLICATE_BEFORE_TERM:-0}" = 1 ]; then
    cp -R "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID" "$MERV_WAN_DHCP_PROC_ROOT/$((WAN_DHCP_OLD_PID + 1))" || return 1
  fi
  wan_main_dhcp_pid_authenticate "$WAN_DHCP_OLD_PID" "$WAN_DHCP_OLD_START" || return 1
  [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 1 ] || return 1
  [ "$(wan_main_dhcp_any_client_count 2>/dev/null || printf x)" = 1 ] || return 1
  WAN_DHCP_RELEASED_CLIENT_STILL_LIVE=1
  persistent_debug_event dhcp-release-complete "result=deconfigured-live pid=$WAN_DHCP_OLD_PID"
  persistent_debug_breadcrumb dhcp-release-complete "result=deconfigured-live pid=$WAN_DHCP_OLD_PID"
  if [ "${MERV_WAN_DHCP_TEST_TERM_AFTER_RELEASE:-0}" = 1 ]; then
    merv_identity_positive_uint "${WAN_TEST_SIGNAL_PID:-}" || return 1
    kill -TERM "$WAN_TEST_SIGNAL_PID" 2>/dev/null || return 1
  fi
  return 0
}

wan_main_dhcp_terminate_released() {
  [ "${WAN_DHCP_RELEASED_CLIENT_STILL_LIVE:-0}" -eq 1 ] || return 0
  # Reauthenticate at the final signal boundary. A PID file is never enough:
  # PID reuse, changed argv, or another LAN client all fail closed.
  wan_main_dhcp_pid_authenticate "$WAN_DHCP_OLD_PID" "$WAN_DHCP_OLD_START" || return 1
  [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 1 ] || return 1
  [ "$(wan_main_dhcp_any_client_count 2>/dev/null || printf x)" = 1 ] || return 1
  info -c cli,vlan "WAN Native: MAIN DHCP terminating released LAN client"
  persistent_debug_event dhcp-terminate-start "pid=$WAN_DHCP_OLD_PID"
  persistent_debug_breadcrumb dhcp-terminate-start "pid=$WAN_DHCP_OLD_PID"
  if [ -n "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ]; then
    printf '%s\n' "terminate $WAN_DHCP_OLD_PID" >> "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" || return 1
    if [ "${MERV_WAN_DHCP_TEST_TERM_AFTER_TERMINATE:-0}" = 1 ]; then
      merv_identity_positive_uint "${WAN_TEST_SIGNAL_PID:-}" || return 1
      kill -TERM "$WAN_TEST_SIGNAL_PID" 2>/dev/null || return 1
    fi
    [ "${MERV_WAN_DHCP_TEST_TERM_STICKS:-0}" = 1 ] ||
      rm -rf "$MERV_WAN_DHCP_PROC_ROOT/$WAN_DHCP_OLD_PID" || return 1
  else
    # Installed BusyBox 1.25.1 documents USR2 for release and handles SIGTERM
    # as process termination. SIGKILL is deliberately not a fallback.
    kill -TERM "$WAN_DHCP_OLD_PID" 2>/dev/null || return 1
  fi
  case "$MERV_WAN_DHCP_TERM_WAIT_SEC" in ''|*[!0-9]*) return 1 ;; esac
  _wmdtr_wait=0
  while [ "$_wmdtr_wait" -le "$MERV_WAN_DHCP_TERM_WAIT_SEC" ]; do
    if wan_main_dhcp_old_exited "$WAN_DHCP_OLD_PID"; then
      wan_main_dhcp_clear_dead_pidfile "$WAN_DHCP_OLD_PID" || return 1
      [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 0 ] || return 1
      [ "$(wan_main_dhcp_any_client_count 2>/dev/null || printf x)" = 0 ] || return 1
WAN_DHCP_RELEASED_CLIENT_STILL_LIVE=0
WAN_DHCP_TRANSITION=0
      persistent_debug_event dhcp-terminate-complete "result=ok pid=$WAN_DHCP_OLD_PID"
      persistent_debug_breadcrumb dhcp-terminate-complete "result=ok pid=$WAN_DHCP_OLD_PID"
      return 0
    fi
    [ "$_wmdtr_wait" -lt "$MERV_WAN_DHCP_TERM_WAIT_SEC" ] || break
    sleep 1
    _wmdtr_wait=$((_wmdtr_wait + 1))
  done
  error -c cli,vlan "WAN Native: MAIN DHCP released client did not terminate"
  persistent_debug_event dhcp-terminate-complete "result=timeout pid=$WAN_DHCP_OLD_PID"
  persistent_debug_breadcrumb dhcp-terminate-complete "result=timeout pid=$WAN_DHCP_OLD_PID"
  return 1
}

wan_main_dhcp_stop_existing() {
  wan_main_dhcp_release_existing || return 1
  wan_main_dhcp_terminate_released
}

wan_main_dhcp_recover_released_client() {
  wan_main_dhcp_pid_authenticate "$WAN_DHCP_OLD_PID" "$WAN_DHCP_OLD_START" || return 1
  [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 1 ] || return 1
  info -c cli,vlan "WAN Native: MAIN DHCP rollback renewing the authenticated live client"
  persistent_debug_event rollback-dhcp-renew "pid=$WAN_DHCP_OLD_PID target=$WAN_DHCP_L3_ORIGINAL"
  persistent_debug_breadcrumb rollback-dhcp-renew "pid=$WAN_DHCP_OLD_PID"
  if [ -n "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ]; then
    printf '%s\n' "renew $WAN_DHCP_OLD_PID" >> "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" || return 1
  else
    # SIGUSR1 is the documented udhcpc RENEW request. It is used only after
    # br0 has been restored to the captured original path.
    kill -USR1 "$WAN_DHCP_OLD_PID" 2>/dev/null || return 1
  fi
  wan_main_dhcp_wait_address "$WAN_DHCP_L3_ORIGINAL"
}

wan_main_dhcp_test_start() {
  _wmdts_pid="${MERV_WAN_DHCP_TEST_NEW_PID:-$((WAN_DHCP_OLD_PID + 1))}"
  _wmdts_start="${MERV_WAN_DHCP_TEST_NEW_START:-424243}"
  merv_identity_positive_uint "$_wmdts_pid" && merv_identity_positive_uint "$_wmdts_start" || return 1
  if [ "${MERV_WAN_DHCP_TEST_LAUNCH_FAIL:-0}" = 1 ] &&
     [ ! -e "${MERV_WAN_DHCP_TEST_LIFECYCLE_FILE}.launch-failed" ]; then
    : > "${MERV_WAN_DHCP_TEST_LIFECYCLE_FILE}.launch-failed" || return 1
    return 1
  fi
  printf '%s\n' "start $_wmdts_pid" >> "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" || return 1
  mkdir -p "$MERV_WAN_DHCP_PROC_ROOT/$_wmdts_pid" || return 1
  {
    printf '%s' '(udhcpc) S'; _wmdts_i=1
    while [ "$_wmdts_i" -lt 19 ]; do printf '%s' ' 0'; _wmdts_i=$((_wmdts_i + 1)); done
    printf ' %s\n' "$_wmdts_start"
  } > "$MERV_WAN_DHCP_PROC_ROOT/$_wmdts_pid/stat" || return 1
  if [ -n "$WAN_DHCP_HOSTNAME" ]; then
    printf 'udhcpc\000-i\000%s\000-p\000%s\000-s\000%s\000-H\000%s\000' "$DEFAULT_BRIDGE" "$MERV_WAN_DHCP_PIDFILE" "$WAN_DHCP_CALLBACK" "$WAN_DHCP_HOSTNAME" > "$MERV_WAN_DHCP_PROC_ROOT/$_wmdts_pid/cmdline"
  else
    printf 'udhcpc\000-i\000%s\000-p\000%s\000-s\000%s\000' "$DEFAULT_BRIDGE" "$MERV_WAN_DHCP_PIDFILE" "$WAN_DHCP_CALLBACK" > "$MERV_WAN_DHCP_PROC_ROOT/$_wmdts_pid/cmdline"
  fi
  printf '%s\n' "$_wmdts_pid" > "$MERV_WAN_DHCP_PIDFILE" || return 1
  printf '%s\n' "$_wmdts_start" > "${MERV_WAN_DHCP_PIDFILE}.start"
}

wan_main_dhcp_start_replacement() {
  [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 0 ] &&
    [ "$(wan_main_dhcp_any_client_count 2>/dev/null || printf x)" = 0 ] || {
    error -c cli,vlan "WAN Native: MAIN DHCP duplicate client detected before replacement"
    return 1
  }
  info -c cli,vlan "WAN Native: MAIN DHCP starting fresh ASUS LAN client on $DEFAULT_BRIDGE"
  persistent_debug_event dhcp-replacement-start "interface=$DEFAULT_BRIDGE callback=$WAN_DHCP_CALLBACK"
  persistent_debug_breadcrumb dhcp-replacement-start "interface=$DEFAULT_BRIDGE"
  if [ -n "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ]; then
    wan_main_dhcp_test_start || return 1
  elif [ -n "$WAN_DHCP_HOSTNAME" ]; then
    udhcpc -i "$DEFAULT_BRIDGE" -p "$MERV_WAN_DHCP_PIDFILE" -s "$WAN_DHCP_CALLBACK" -H "$WAN_DHCP_HOSTNAME" >/dev/null 2>&1 &
  else
    udhcpc -i "$DEFAULT_BRIDGE" -p "$MERV_WAN_DHCP_PIDFILE" -s "$WAN_DHCP_CALLBACK" >/dev/null 2>&1 &
  fi
  case "$MERV_WAN_DHCP_START_WAIT_SEC" in ''|*[!0-9]*) return 1 ;; esac
  _wmdsr_wait=0
  while [ "$_wmdsr_wait" -le "$MERV_WAN_DHCP_START_WAIT_SEC" ]; do
    _wmdsr_pid="$(wan_main_dhcp_pid_read 2>/dev/null || printf '')"
    if [ -n "$_wmdsr_pid" ]; then
      _wmdsr_start="$(wan_main_dhcp_pid_start "$_wmdsr_pid" 2>/dev/null || printf '')"
      if [ -n "$_wmdsr_start" ] && wan_main_dhcp_pid_authenticate "$_wmdsr_pid" "$_wmdsr_start" &&
         [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 1 ] &&
         [ "$(wan_main_dhcp_any_client_count 2>/dev/null || printf x)" = 1 ] &&
         { [ "$_wmdsr_pid" != "$WAN_DHCP_OLD_PID" ] || [ "$_wmdsr_start" != "$WAN_DHCP_OLD_START" ]; }; then
        WAN_DHCP_OLD_PID="$_wmdsr_pid"; WAN_DHCP_OLD_START="$_wmdsr_start"
        info -c cli,vlan "WAN Native: MAIN DHCP replacement client pid=$_wmdsr_pid"
        persistent_debug_event dhcp-replacement-started "pid=$_wmdsr_pid"
        persistent_debug_breadcrumb dhcp-replacement-started "pid=$_wmdsr_pid"
        return 0
      fi
    fi
    [ "$_wmdsr_wait" -lt "$MERV_WAN_DHCP_START_WAIT_SEC" ] || break
    sleep 1; _wmdsr_wait=$((_wmdsr_wait + 1))
  done
  error -c cli,vlan "WAN Native: MAIN DHCP replacement client failed to start"
  persistent_debug_event dhcp-replacement-started "result=failed"
  persistent_debug_breadcrumb dhcp-replacement-started "result=failed"
  return 1
}

wan_main_dhcp_wait_address() {
  _wmdwa_expected="$1"
  case "$MERV_WAN_DHCP_WAIT_SEC" in ''|*[!0-9]*) return 1 ;; esac
  _wmdwa_wait=0
  while [ "$_wmdwa_wait" -le "$MERV_WAN_DHCP_WAIT_SEC" ]; do
    if [ -n "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ] &&
       { [ ! -e "${MERV_WAN_DHCP_TEST_SUPPRESS_FILE:-}" ] || [ "$_wmdwa_expected" = "$WAN_DHCP_L3_ORIGINAL" ]; } &&
       [ "${MERV_WAN_DHCP_TEST_DELAY_POLLS:-0}" -le "$_wmdwa_wait" ] 2>/dev/null; then
      printf '%s%s\n' "$_wmdwa_expected" "${MERV_WAN_DHCP_TEST_ADDRESS_PREFIX:-}" > "$MERV_WAN_DHCP_TEST_ADDRESS_FILE" || return 1
    fi
    wan_main_dhcp_state_ready "$_wmdwa_expected" && return 0
    [ "$_wmdwa_wait" -lt "$MERV_WAN_DHCP_WAIT_SEC" ] || break
    sleep 1; _wmdwa_wait=$((_wmdwa_wait + 1))
  done
  error -c cli,vlan "WAN Native: MAIN DHCP expected address $_wmdwa_expected timed out after ${MERV_WAN_DHCP_WAIT_SEC}s"
  persistent_debug_event dhcp-target-address "result=timeout target=$_wmdwa_expected"
  persistent_debug_breadcrumb dhcp-target-address "result=timeout target=$_wmdwa_expected"
  return 1
}

wan_main_dhcp_restart() {
  _wmdr_expected="$1"
  [ -n "$_wmdr_expected" ] || return 1
  # Avoid `||` around stateful functions: BusyBox ash can evaluate that
  # function context separately, losing WAN_DHCP_LIFECYCLE_DISRUPTED.
  wan_main_dhcp_stop_existing
  _wmdr_stop_rc=$?
  [ "$_wmdr_stop_rc" -eq 0 ] || return 1
  wan_main_dhcp_start_replacement
  _wmdr_start_rc=$?
  [ "$_wmdr_start_rc" -eq 0 ] || return 1
  info -c cli,vlan "WAN Native: MAIN DHCP waiting for expected address $_wmdr_expected"
  persistent_debug_event dhcp-target-address "stage=wait target=$_wmdr_expected"
  persistent_debug_breadcrumb dhcp-target-address "target=$_wmdr_expected"
  wan_main_dhcp_wait_address "$_wmdr_expected"
  _wmdr_wait_rc=$?
  [ "$_wmdr_wait_rc" -eq 0 ] || return 1
  info -c cli,vlan "WAN Native: MAIN DHCP expected address acquired $_wmdr_expected"
  persistent_debug_event dhcp-target-address "result=ok target=$_wmdr_expected"
  persistent_debug_breadcrumb dhcp-target-address "result=ok target=$_wmdr_expected"
}

wan_main_dhcp_restore_l3() {
  [ "${WAN_DHCP_LIFECYCLE_DISRUPTED:-0}" -eq 1 ] || return 0
  [ -n "$WAN_DHCP_L3_ORIGINAL" ] || return 1
  info -c cli,vlan "WAN Native: MAIN DHCP rollback restoring original acquisition"
  persistent_debug_event rollback-dhcp-start "target=$WAN_DHCP_L3_ORIGINAL"
  persistent_debug_breadcrumb rollback-dhcp-start "target=$WAN_DHCP_L3_ORIGINAL"
  # The deterministic fixture suppresses only the target-domain offer.  A
  # rollback models the original DHCP domain independently, as production
  # does after the bridge member has been restored.
  [ -z "$MERV_WAN_DHCP_TEST_LIFECYCLE_FILE" ] || MERV_WAN_DHCP_TEST_SUPPRESS_FILE=""
  # A failed RELEASE can leave the original address, route, and one valid
  # client intact. After L2 restoration that is already a safe recovery; do
  # not churn it into another release/restart cycle.
  if wan_main_dhcp_state_ready "$WAN_DHCP_L3_ORIGINAL" &&
     [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 1 ] &&
     wan_main_dhcp_capture_existing; then
    persistent_debug_event rollback-dhcp-complete "result=already-ready address=$WAN_DHCP_L3_ORIGINAL"
    persistent_debug_breadcrumb rollback-dhcp-complete "result=already-ready"
    return 0
  fi
  if [ "${WAN_DHCP_RELEASED_CLIENT_STILL_LIVE:-0}" -eq 1 ]; then
    wan_main_dhcp_recover_released_client || return 1
    WAN_DHCP_RELEASED_CLIENT_STILL_LIVE=0
    info -c cli,vlan "WAN Native: MAIN DHCP rollback original address restored"
    persistent_debug_event rollback-dhcp-complete "result=ok address=$WAN_DHCP_L3_ORIGINAL mode=renew"
    persistent_debug_breadcrumb rollback-dhcp-complete "result=ok mode=renew"
    return 0
  fi
  _wmdrl_count="$(wan_main_dhcp_client_count 2>/dev/null || printf x)"
  case "$_wmdrl_count" in
    0)
      # A launch failure can leave no client after the release.  The original
      # authenticated argv contract is still retained in memory, so restore
      # one client directly rather than failing merely because no PID exists.
      wan_main_dhcp_start_replacement
      _wmdrl_start_rc=$?
      [ "$_wmdrl_start_rc" -eq 0 ] || return 1
      wan_main_dhcp_wait_address "$WAN_DHCP_L3_ORIGINAL"
      _wmdrl_wait_rc=$?
      [ "$_wmdrl_wait_rc" -eq 0 ] || return 1
      ;;
    1)
      wan_main_dhcp_capture_existing
      _wmdrl_capture_rc=$?
      [ "$_wmdrl_capture_rc" -eq 0 ] || return 1
      wan_main_dhcp_restart "$WAN_DHCP_L3_ORIGINAL"
      _wmdrl_restart_rc=$?
      [ "$_wmdrl_restart_rc" -eq 0 ] || return 1
      ;;
    *)
      error -c cli,vlan "WAN Native: MAIN DHCP rollback found duplicate client state"
      return 1
      ;;
  esac
  info -c cli,vlan "WAN Native: MAIN DHCP rollback original address restored"
  persistent_debug_event rollback-dhcp-complete "result=ok address=$WAN_DHCP_L3_ORIGINAL"
  persistent_debug_breadcrumb rollback-dhcp-complete "result=ok address=$WAN_DHCP_L3_ORIGINAL"
}

wan_main_dhcp_rebind() {
  [ "$NODE_ID" = "none" ] || return 0
  [ "${WAN_DHCP_TRANSITION:-0}" -eq 1 ] || return 0
  [ -n "$WAN_DHCP_EXPECTED" ] || return 1
  if wan_main_dhcp_state_ready "$WAN_DHCP_EXPECTED" &&
     [ "$(wan_main_dhcp_client_count 2>/dev/null || printf x)" = 1 ] &&
     [ "$(wan_main_dhcp_any_client_count 2>/dev/null || printf x)" = 1 ]; then
    info -c cli,vlan "WAN Native: MAIN DHCP already has expected address and one healthy client"
    return 0
  fi
  wan_main_dhcp_restart "$WAN_DHCP_EXPECTED"
}

apply_live() {
  validate_settings || return 1

  if [ "$DRY_RUN" = "yes" ]; then
    if [ "$WAN_NATIVE" = "none" ]; then
      info -c cli,vlan "[DRY-RUN] WAN Native: would converge $DEFAULT_BRIDGE to ASUS native transport on $UPLINK_PORT"
    else
      info -c cli,vlan "[DRY-RUN] WAN Native: would converge $DEFAULT_BRIDGE to tagged transport $UPLINK_PORT.$WAN_NATIVE"
    fi
    return 0
  fi

  # A MAIN transport-domain change in either direction requires a verified
  # DHCP handoff. Static/unknown LAN protocol is rejected before live discovery
  # or any bridge/VLAN mutation. Nodes remain intentionally untouched.
  wan_main_dhcp_preflight || return 1

  validate_live_target || return 1

  iface_exists "$DEFAULT_BRIDGE" || {
    error -c cli,vlan "WAN Native: $DEFAULT_BRIDGE is missing; refusing transport mutation"
    return 1
  }
  iface_exists "$UPLINK_PORT" || {
    error -c cli,vlan "WAN Native: physical uplink $UPLINK_PORT is missing; refusing transport mutation"
    return 1
  }

  WAN_CREATED_IF=""
  WAN_DHCP_L3_ACTIVE=0
  _wal_original="$(native_members | tr '\n' ' ')"
  _wal_mac="$(bridge_mac_read)"

  if [ "$NODE_ID" = "none" ] && [ "${WAN_DHCP_TRANSITION:-0}" -eq 1 ]; then
    persistent_debug_run_start WANMAIN
    persistent_debug_event transaction-start "target=MAIN vid=$WAN_NATIVE old_member=${_wal_original:-none} old_ip=${WAN_DHCP_L3_ORIGINAL:-unknown} target_ip=${WAN_DHCP_EXPECTED:-unknown}"
    persistent_debug_breadcrumb transaction-start "target=MAIN old_ip=${WAN_DHCP_L3_ORIGINAL:-unknown} new_ip=${WAN_DHCP_EXPECTED:-unknown} target_vid=$WAN_NATIVE"
  fi

  if [ "$WAN_NATIVE" = "none" ]; then
    _wal_had_tagged_native=0
    for _wal_if in $_wal_original; do
      case "$_wal_if" in "$UPLINK_PORT".[0-9]*) _wal_had_tagged_native=1 ;; esac
    done
    if [ "$_wal_had_tagged_native" -eq 0 ]; then
      # No MerVLAN WAN-native upper is active. ASUS owns this topology, so
      # leave the supported physical-uplink topology exactly as found. Do not
      # silently accept an unknown firmware topology or invent a bridge path.
      verify_live || return 1
      info -c cli,vlan "WAN Native: ASUS mode active; no tagged native transport to restore"
      return 0
    fi
    _wal_target="$UPLINK_PORT"
  else
    if [ -z "$_wal_original" ]; then
      error -c cli,vlan "WAN Native: no existing ASUS/native $DEFAULT_BRIDGE uplink path on $UPLINK_PORT; refusing to create one"
      return 1
    fi
    _wal_target="$UPLINK_PORT.$WAN_NATIVE"
  fi

  # No bridge or link mutation is allowed before the complete native-member
  # snapshot has been armed for signal/EXIT rollback.
  wan_txn_begin "$_wal_original" "$_wal_target" "$_wal_mac"
  [ "$NODE_ID" = "none" ] && [ "${WAN_DHCP_TRANSITION:-0}" -eq 1 ] && WAN_DHCP_L3_ACTIVE=1

  ensure_target_iface "$_wal_target" "$WAN_NATIVE" || {
    persistent_debug_event target-prepare "result=failed target=$_wal_target"
    persistent_debug_breadcrumb target-prepare "result=failed target=$_wal_target"
    error -c cli,vlan "WAN Native: could not prepare target transport $_wal_target"
    wan_txn_restore || error -c cli,vlan "WAN Native: ROLLBACK FAILED after target preparation error"
    return 1
  }
  persistent_debug_event target-prepare "result=ok target=$_wal_target"

  _wal_target_already=0
  for _wal_if in $_wal_original; do
    [ "$_wal_if" = "$_wal_target" ] && _wal_target_already=1
  done

  # Avoid a duplicate L2 path over the same physical lower device. If the
  # desired transport is not already native, remove the captured old native
  # member(s) immediately before attaching the prepared replacement.
  if [ "$_wal_target_already" -eq 0 ]; then
    persistent_debug_event bridge-swap-start "old_member=${_wal_original:-none} new_member=$_wal_target"
    persistent_debug_breadcrumb bridge-swap-start "member=$_wal_target"
    for _wal_if in $_wal_original; do
      if ! bridge_del "$_wal_if"; then
        persistent_debug_event bridge-detach "result=failed member=$_wal_if"
        error -c cli,vlan "WAN Native: failed detaching old native transport $_wal_if"
        wan_txn_restore || \
          error -c cli,vlan "WAN Native: ROLLBACK FAILED after detach error"
        return 1
      fi
    done
    if ! bridge_add "$_wal_target"; then
      persistent_debug_event bridge-attach "result=failed member=$_wal_target"
      error -c cli,vlan "WAN Native: failed attaching replacement transport $_wal_target"
      wan_txn_restore || \
        error -c cli,vlan "WAN Native: ROLLBACK FAILED after attach error"
      return 1
    fi
    persistent_debug_event bridge-swap-complete "result=ok member=$_wal_target"
    persistent_debug_breadcrumb bridge-swap-complete "result=ok member=$_wal_target"
  fi

  # If the target was already present, or firmware left multiple native uplink
  # members behind, converge by removing every other uplink path from br0.
  for _wal_if in $(native_members); do
    [ "$_wal_if" = "$_wal_target" ] && continue
    if ! bridge_del "$_wal_if"; then
      error -c cli,vlan "WAN Native: failed removing extra native transport $_wal_if"
      wan_txn_restore || \
        error -c cli,vlan "WAN Native: ROLLBACK FAILED after convergence error"
      return 1
    fi
  done

  if ! bridge_mac_restore "$_wal_mac"; then
    error -c cli,vlan "WAN Native: $DEFAULT_BRIDGE MAC changed and could not be restored"
    wan_txn_restore || \
      error -c cli,vlan "WAN Native: ROLLBACK FAILED after bridge-MAC error"
    return 1
  fi

  if ! verify_live; then
    error -c cli,vlan "WAN Native: replacement transport verification failed; restoring prior path"
    wan_txn_restore || \
      error -c cli,vlan "WAN Native: ROLLBACK FAILED after verification error"
    return 1
  fi

  # Do this while rollback is still armed.  A DHCP MAIN must be asked to bind
  # the now-verified br0 transport before the transaction is committed; an
  # absent or unsignalable client is not safe to leave on a new L2 domain.
  # Keep lifecycle state in this shell.  Some BusyBox ash variants execute a
  # function under `!` in a separate context, which would discard the armed
  # DHCP rollback state after a delivered release.
  wan_main_dhcp_rebind
  _wal_dhcp_rc=$?
  if [ "$_wal_dhcp_rc" -ne 0 ]; then
    error -c cli,vlan "WAN Native: MAIN DHCP client could not complete fresh acquisition after transport change; restoring prior path"
    wan_txn_restore || \
      error -c cli,vlan "WAN Native: ROLLBACK FAILED after DHCP restart error"
    return 1
  fi

  # Membership replacement is now verified.  From this point stale detached
  # upper cleanup is best-effort and must not make a later signal undo an
  # already verified bridge path.
  wan_txn_commit

  # Cleanup only VLAN uppers that were part of the previous native path. Never
  # delete arbitrary uplink VLANs: other MerVLAN bridges may legitimately own
  # them. A failed delete is non-fatal because the stale upper is detached and
  # no longer carries br0 traffic; generic manager cleanup can retry later.
  for _wal_if in $_wal_original; do
    [ "$_wal_if" = "$_wal_target" ] && continue
    case "$_wal_if" in
      "$UPLINK_PORT".[0-9]*)
        _wal_master="$(bridge_for_iface "$_wal_if" 2>/dev/null || printf '')"
        if [ -z "$_wal_master" ] && iface_exists "$_wal_if"; then
          if ip link del "$_wal_if" 2>/dev/null; then
            info -c cli,vlan "WAN Native: removed stale native interface $_wal_if"
          else
            warn -c cli,vlan "WAN Native: stale interface $_wal_if is detached but could not be deleted"
          fi
        fi
        ;;
    esac
  done

  if [ "$WAN_NATIVE" = "none" ]; then
    info -c cli,vlan "WAN Native: ASUS native/untagged transport active on $UPLINK_PORT"
  else
    info -c cli,vlan "WAN Native: $DEFAULT_BRIDGE uses $UPLINK_PORT.$WAN_NATIVE; native uplink traffic is tagged VLAN $WAN_NATIVE"
  fi
  return 0
}

case "$MODE" in
  validate)
    validate_settings || exit 1
    # Validation is a read-only live preflight as well as a settings check;
    # callers may rely on it to fail closed before generic bridge cleanup.
    wan_main_dhcp_preflight && validate_live_target
    exit $?
    ;;
  verify)
    validate_settings || exit 1
    validate_live_target || exit 1
    verify_live
    exit $?
    ;;
  health)
    # Read-only health contract for heal. It never arms a transaction, creates
    # an upper, or signals DHCP. L2 is strict for both supported modes; MAIN L3
    # is checked when an explicit endpoint is configured.
    validate_settings || exit 1
    validate_live_target || exit 1
    verify_live || exit 1
    if [ "$NODE_ID" = "none" ]; then
      _wmh_expected="$(wan_main_dhcp_expected_address 2>/dev/null || printf '')"
      if [ -n "$_wmh_expected" ]; then
        wan_main_dhcp_capture_existing || exit 1
        wan_main_dhcp_state_ready "$_wmh_expected" || exit 1
      elif [ "$WAN_NATIVE" != "none" ]; then
        # Numeric MAIN has no safe degraded health state: its configured
        # endpoint is required for management verification.
        exit 1
      fi
    fi
    exit 0
    ;;
  apply)
    apply_live
    exit $?
    ;;
esac
