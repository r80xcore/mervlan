#!/bin/sh
#
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
#             - File: settings/lib_br0_guard.sh || version="0.1"              #
# ============================================================================ #
# - Purpose:    Runtime br0 bridge membership guard.                           #
#               Protects against Asuswrt/Broadcom restart_wireless races      #
#               where firmware re-adds managed VAPs to br0 during service      #
#               restarts. Provides soft (bridge-only) and hard (wl down +     #
#               bridge) eviction, plus a runtime-only NVRAM scrub that removes #
#               managed VAPs from lan_ifnames/br0_ifnames before manager-owned #
#               service restarts.                                              #
#                                                                              #
# CRITICAL DESIGN RULE:                                                        #
#   This file must NEVER call "nvram commit".                                  #
#   "nvram set" is used only as a live-session hint to rc/wlconf.              #
#   settings.json remains the MerVLAN source of truth.                         #
#   A reboot reloads committed/default Asuswrt values; MerVLAN rebuilds from  #
#   settings.json via boot/heal/manager.                                       #
#                                                                              #
# BusyBox ash compatible. No Bash arrays, [[ ]], or process substitution.     #
# ============================================================================ #

LIB_BR0_GUARD_LOADED=1
_MERV_BR0_GUARD_DIAG_DONE=0

# ---------------------------------------------------------------------------- #
# _merv_guard_log — internal log helper                                        #
# Uses MerVLAN's info() if loaded, falls back to logger.                       #
# ---------------------------------------------------------------------------- #
_merv_guard_log() {
  if type info >/dev/null 2>&1; then
    info -c vlan "$*"
  else
    logger -t "VLANMgr" "$*"
  fi
}

# ---------------------------------------------------------------------------- #
# merv_managed_wl_ifaces — list MerVLAN-managed wireless VAP interfaces        #
# Outputs one interface name per line.                                          #
# Depends on merv_mac_build_expected_iface_vid from mac_shield_snapshot.sh.   #
# Returns nothing (and is safe) if that function is not loaded.                #
# ---------------------------------------------------------------------------- #
merv_managed_wl_ifaces() {
  if type merv_mac_build_expected_iface_vid >/dev/null 2>&1; then
    merv_mac_build_expected_iface_vid 2>/dev/null \
      | awk '{print $1}' \
      | grep -E '^(wl|ra|ath)[0-9].*\.[0-9]+$'
  fi
}

# ---------------------------------------------------------------------------- #
# merv_iface_is_managed — check if $1 is a managed VAP                        #
# Returns 0 (true) if managed, 1 (false) otherwise.                           #
# ---------------------------------------------------------------------------- #
merv_iface_is_managed() {
  [ -n "${1:-}" ] || return 1
  merv_managed_wl_ifaces | grep -qxF "$1"
}

# ---------------------------------------------------------------------------- #
# merv_soft_evict_wl_from_br0 — bridge-only eviction of managed VAPs          #
# Args: $1 = log tag (default: guard)                                          #
#                                                                              #
# Only calls "brctl delif br0 IF". Does NOT call "wl -i IF down".             #
# Safe to run on every tick inside rc-quiet wait loops.                        #
# If firmware re-adds a VAP to br0 on the next tick, the next call removes it.#
# ---------------------------------------------------------------------------- #
merv_soft_evict_wl_from_br0() {
  _sg_tag="${1:-guard}"
  _sg_evicted=0

  _sg_managed="$(merv_managed_wl_ifaces | tr '\n' ' ')"
  [ -n "$_sg_managed" ] || return 0
  _sg_managed_set=" $_sg_managed "

  if [ "${MERV_BR0_GUARD_VERBOSE:-0}" = "1" ] && [ "${_MERV_BR0_GUARD_DIAG_DONE:-0}" = "0" ]; then
    _merv_guard_log "BR0 guard[$_sg_tag]: managed VAP set: ${_sg_managed:-none}"
    _MERV_BR0_GUARD_DIAG_DONE=1
  fi

  for _sg_path in /sys/class/net/br0/brif/wl*.* \
                  /sys/class/net/br0/brif/ra*.* \
                  /sys/class/net/br0/brif/ath*.*; do
    [ -e "$_sg_path" ] || continue
    _sg_iface="${_sg_path##*/}"

    case "$_sg_managed_set" in
      *" $_sg_iface "*) ;;
      *) continue ;;
    esac

    if brctl delif br0 "$_sg_iface" 2>/dev/null; then
      _sg_evicted=$((_sg_evicted + 1))
      _merv_guard_log "BR0 guard[$_sg_tag]: soft-evicted $_sg_iface from br0"
    fi
  done

  [ "$_sg_evicted" -gt 0 ] && \
    _merv_guard_log "BR0 guard[$_sg_tag]: soft-evicted ${_sg_evicted} managed VAP(s) from br0 total"

  return 0
}

# ---------------------------------------------------------------------------- #
# merv_hard_evict_wl_from_br0 — wl down + bridge eviction of managed VAPs     #
# Args: $1 = log tag (default: heal)                                           #
#                                                                              #
# Calls "wl -i IF down" then "brctl delif br0 IF".                            #
# Use only once after check_vlan_config/check_wl_iface_placements confirms    #
# a managed VAP is definitely in br0. Do NOT call inside polling loops.       #
# ---------------------------------------------------------------------------- #
merv_hard_evict_wl_from_br0() {
  _hg_tag="${1:-heal}"
  _hg_evicted=0

  _hg_managed="$(merv_managed_wl_ifaces | tr '\n' ' ')"
  [ -n "$_hg_managed" ] || return 0
  _hg_managed_set=" $_hg_managed "

  for _hg_path in /sys/class/net/br0/brif/wl*.* \
                  /sys/class/net/br0/brif/ra*.* \
                  /sys/class/net/br0/brif/ath*.*; do
    [ -e "$_hg_path" ] || continue
    _hg_iface="${_hg_path##*/}"

    case "$_hg_managed_set" in
      *" $_hg_iface "*) ;;
      *) continue ;;
    esac

    type wl >/dev/null 2>&1 && wl -i "$_hg_iface" down 2>/dev/null || true
    brctl delif br0 "$_hg_iface" 2>/dev/null || true
    _hg_evicted=$((_hg_evicted + 1))
    _merv_guard_log "BR0 guard[$_hg_tag]: hard-evicted $_hg_iface from br0"
  done

  [ "$_hg_evicted" -gt 0 ] && \
    _merv_guard_log "BR0 guard[$_hg_tag]: hard-evicted ${_hg_evicted} managed VAP(s) from br0 total"

  return 0
}

# ---------------------------------------------------------------------------- #
# _merv_filter_managed_from_ifnames — remove managed VAPs from an ifnames str #
# Args: $1 = original space-separated ifnames string                           #
# Outputs: filtered string with managed VAPs removed.                          #
# BusyBox-safe: no xargs, no arrays.                                           #
# ---------------------------------------------------------------------------- #
_merv_filter_managed_from_ifnames() {
  _mf_old="$1"
  _mf_managed="$(merv_managed_wl_ifaces | tr '\n' ' ')"
  _mf_new=""

  for _mf_token in $_mf_old; do
    _mf_keep=1
    for _mf_drop in $_mf_managed; do
      [ "$_mf_token" = "$_mf_drop" ] && { _mf_keep=0; break; }
    done
    if [ "$_mf_keep" -eq 1 ]; then
      if [ -n "$_mf_new" ]; then
        _mf_new="${_mf_new} ${_mf_token}"
      else
        _mf_new="${_mf_token}"
      fi
    fi
  done

  printf '%s\n' "$_mf_new"
}

# ---------------------------------------------------------------------------- #
# merv_scrub_br0_nvram_ifnames — runtime-only NVRAM scrub                      #
# Args: $1 = log tag (default: runtime)                                        #
#                                                                              #
# Removes MerVLAN-managed VAPs from lan_ifnames and br0_ifnames so that       #
# rc/wlconf is less likely to re-add them to br0 during restart_wireless.     #
#                                                                              #
# Uses "nvram set" only. NEVER calls "nvram commit".                           #
# This is a live-session hint only. Settings are reset on reboot.             #
# ---------------------------------------------------------------------------- #
merv_scrub_br0_nvram_ifnames() {
  _ns_tag="${1:-runtime}"
  _ns_changed=0

  type nvram >/dev/null 2>&1 || return 0

  _ns_managed="$(merv_managed_wl_ifaces | tr '\n' ' ')"
  [ -n "$_ns_managed" ] || return 0

  # Default to the narrower key only; lan_ifnames scrub is opt-in.
  _ns_keys="${MERV_BR0_GUARD_SCRUB_KEYS:-br0_ifnames}"

  for _ns_nv in $_ns_keys; do
    _ns_old="$(nvram get "$_ns_nv" 2>/dev/null)"
    [ -n "$_ns_old" ] || continue

    _ns_new="$(_merv_filter_managed_from_ifnames "$_ns_old")"

    if [ "$_ns_new" != "$_ns_old" ]; then
      nvram set "${_ns_nv}=${_ns_new}" 2>/dev/null || true
      _ns_changed=1
      _merv_guard_log "BR0 guard[$_ns_tag]: runtime-scrubbed $_ns_nv: [$_ns_old] -> [$_ns_new]"
    fi
  done

  if [ "$_ns_changed" -eq 1 ]; then
    _merv_guard_log "BR0 guard[$_ns_tag]: NVRAM scrub complete — runtime-only, nvram commit intentionally skipped"
  fi

  return 0
}
