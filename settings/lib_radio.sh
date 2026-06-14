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
#                   - File: lib_radio.sh || version="0.01"                     #
# ============================================================================ #
# Purpose: Helpers for wireless radio interface classification, multi-digit    #
#          wl index support, and Limits-section SSID cap management.           #
#                                                                              #
# Sourced by: hw_probe.sh, mervlan_manager.sh, and any script that needs       #
#             dynamic radio index enumeration or SSID cap arithmetic.          #
#                                                                              #
# Guard pattern: LIB_RADIO_LOADED                                              #
# Dependencies: lib_json.sh (for Limits section reads via json_get_section_value)
# ============================================================================ #
[ -n "${LIB_RADIO_LOADED:-}" ] && return 0 2>/dev/null

# ============================================================================ #
#                     Interface classification helpers                         #
# ============================================================================ #

# merv_is_uint — true if $1 is a non-negative decimal integer.
# Empty strings, leading signs, and non-numeric characters return false.
merv_is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# merv_is_wl_base_radio — true if $1 is a Broadcom base radio interface.
# Accepts: wl0..wl9, wl10..wl99
# Rejects: wl0.1 (subinterface), eth*, empty strings
merv_is_wl_base_radio() {
  case "$1" in
    wl[0-9]|wl[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# merv_is_wl_vap_iface — true if $1 is a Broadcom wireless subinterface (VAP).
# Strict: the slot number (after the dot) must be a pure unsigned integer.
# Accepts: wl0.1, wl2.3, wl10.1, wl10.9, wl99.15, etc.
# Rejects: wl0 (base radio), wl0.1abc (trailing garbage), eth*, ra*, ath*, empty
merv_is_wl_vap_iface() {
  local _iface _ridx _slot
  _iface="$1"
  # Must start with wl and contain exactly one dot
  case "$_iface" in
    wl*.*)  ;;
    *)      return 1 ;;
  esac
  _ridx="${_iface#wl}"          # e.g. "0.1" or "10.3"
  _ridx="${_ridx%%.*}"           # radio index, e.g. "0" or "10"
  _slot="${_iface#*.}"           # slot suffix, e.g. "1" or "3"
  # Strip any second dot or further: must be single-dot
  case "$_slot" in *.*) return 1 ;; esac
  merv_is_uint "$_ridx" && merv_is_uint "$_slot" && [ -n "$_slot" ]
}

# merv_is_wl_iface — true if $1 is any Broadcom wireless interface (base or VAP).
merv_is_wl_iface() {
  merv_is_wl_base_radio "$1" || merv_is_wl_vap_iface "$1"
}

# ============================================================================ #
#                       Radio index enumeration                                #
# ============================================================================ #

# merv_list_wl_radio_indexes — Print space-separated radio index numbers (0-based)
# for every wlN_ifname nvram key that resolves to a live interface.
# AiMesh nodes remap wl interfaces to ethX; the /sys/class/net check is
# bypassed when re_mode=1 (same logic as hw_probe.sh).
# Scans indices 0..15 to cover current and near-future ASUS quad-band hardware.
# Prints trailing space after each index; output is empty if no radios found.
merv_list_wl_radio_indexes() {
  local _is_node _idx _ifname
  _is_node=$(nvram get re_mode 2>/dev/null)
  _idx=0
  while [ "$_idx" -le 15 ]; do
    _ifname=$(nvram get "wl${_idx}_ifname" 2>/dev/null)
    if [ -n "$_ifname" ] && { [ "$_is_node" = "1" ] || [ -d "/sys/class/net/$_ifname" ]; }; then
      printf '%s ' "$_idx"
    fi
    _idx=$((_idx + 1))
  done
}

# ============================================================================ #
#                         Limits section helpers                               #
# ============================================================================ #

# merv_get_limit_value — Read a single numeric value from the Limits section of
# settings.json.  Requires lib_json.sh (json_get_section_value) to be loaded.
# Args: $1=key  $2=settings_file  $3=default_value
# Prints the stored numeric value, or $3 if absent, zero, or non-numeric.
merv_get_limit_value() {
  local _key="$1" _file="$2" _default="${3:-0}" _val
  if type json_get_section_value >/dev/null 2>&1 && [ -f "$_file" ]; then
    _val=$(json_get_section_value "Limits" "$_key" "$_file" 2>/dev/null)
  fi
  case "$_val" in
    ''|0|*[!0-9]*) printf '%s\n' "$_default" ;;
    *) printf '%s\n' "$_val" ;;
  esac
}

# merv_effective_ssid_cap — Return the maximum SSID slot count from
# Limits.MAX_SSID_CAP.  Defaults to 16 when the key is absent or zero.
# Args: $1=settings_file (optional; falls back to $SETTINGS_FILE)
merv_effective_ssid_cap() {
  merv_get_limit_value "MAX_SSID_CAP" "${1:-${SETTINGS_FILE:-}}" "16"
}

# merv_guest_slots_per_radio — Return the number of guest SSID slots per radio
# from Limits.GUEST_SLOTS_PER_RADIO.  Defaults to 3 when absent or zero.
# Args: $1=settings_file (optional; falls back to $SETTINGS_FILE)
merv_guest_slots_per_radio() {
  merv_get_limit_value "GUEST_SLOTS_PER_RADIO" "${1:-${SETTINGS_FILE:-}}" "3"
}

# merv_cap_ssids — Clamp $1 to the effective SSID cap from settings.json.
# Empty, non-numeric, or zero values fall back to 12 (safe runtime minimum)
# before being clamped to Limits.MAX_SSID_CAP.  This ensures manager-side
# loops never scan zero slots when hw_probe has not run yet.
# Args: $1=raw_count  $2=settings_file (optional)
# Prints the (possibly clamped) count.
merv_cap_ssids() {
  local _raw="$1" _file="${2:-${SETTINGS_FILE:-}}" _cap _safe
  _cap=$(merv_effective_ssid_cap "$_file")
  merv_is_uint "$_cap" || _cap=16
  # Treat zero and non-numeric as invalid — fall back to 12 then clamp
  case "$_raw" in
    ''|0|*[!0-9]*) _safe=12 ;;
    *)             _safe="$_raw" ;;
  esac
  if [ "$_safe" -gt "$_cap" ]; then
    printf '%s\n' "$_cap"
  else
    printf '%s\n' "$_safe"
  fi
}

LIB_RADIO_LOADED=1
