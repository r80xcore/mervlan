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
#                  - File: lib_mervqt.sh || version="0.4"                      #
# ============================================================================ #
# Purpose: Shared L2 shield enforcement library.
#   Provides shared validators, MERV_MAC ebtables chain lifecycle, db path
#   selection, and the restore helper used by heal_event.sh.
#
# Load contract (in callers):
#   [ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh"
#
# Dependencies:
#   var_settings.sh  — MERV_MAC_CHAIN, MERV_MAC_DB_ACTIVE, MERV_MAC_DB_JFFS
#   log_settings.sh  — info, warn
#
# CALLER CONTRACT for ebt_mac_shield_apply():
#   Caller MUST call ebt_mac_shield_flush() first.
#   ebt_mac_shield_apply() does NOT flush itself so it can be used in
#   partial-rebuild paths. Failure to flush first causes rule accumulation.
#   ebt_mac_shield_apply() also requires ebt_mac_shield_init() to have been
#   called first so the chain exists before rules are appended.
#
# Subinterface scope (this version):
#   Config-derived resolution targets wl*.* (Broadcom) only.
#   ra*.* and ath*.* are accepted in db/rule validation for forward
#   compatibility but are not produced by merv_mac_build_expected_iface_vid.
# ============================================================================ #
if [ -n "${LIB_MERVQT_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# ============================================================================
# Shared validators
# ============================================================================

# mervqt_has_ebtables — true if ebtables binary is present
mervqt_has_ebtables() {
  type ebtables >/dev/null 2>&1
}

# mervqt_mac_lower — normalize a MAC address to lowercase
# Args: $1 = MAC string (any case)
# Prints: lowercase MAC to stdout
mervqt_mac_lower() {
  printf '%s' "$1" | tr 'A-F' 'a-f'
}

# mervqt_valid_mac — true if $1 is a lowercase colon-separated MAC address
# Input MUST already be lowercased (use mervqt_mac_lower first if unsure)
mervqt_valid_mac() {
  case "$1" in
    [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f])
      return 0 ;;
    *) return 1 ;;
  esac
}

# mervqt_valid_wl_subif — true if $1 is a wireless subinterface (not a base radio)
# Accepts: wl*.*, ra*.*, ath*.*
# Rejects: wl0, wl1, eth*, and anything without a dot-index
mervqt_valid_wl_subif() {
  case "$1" in
    wl[0-9].[0-9]*|ra[0-9].[0-9]*|ath[0-9].[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# mervqt_valid_vid — true if $1 is a numeric VLAN ID in the range 2–4094
mervqt_valid_vid() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 2 ] && [ "$1" -le 4094 ] 2>/dev/null
}

# ============================================================================
# DB path selection
# Kept in lib_mervqt.sh because both enforcement (restore_merv_mac_shield)
# and snapshot (mac_shield_snapshot.sh) need this function. Placing it here
# avoids a circular dependency where the enforcement library would need to
# source the snapshot library just to find the db path.
# ============================================================================

# merv_mac_best_db
# Print path of best available db: /tmp active db first, JFFS fallback second.
# Prints nothing and returns 1 if neither exists.
merv_mac_best_db() {
  [ -f "$MERV_MAC_DB_ACTIVE" ] && { printf '%s' "$MERV_MAC_DB_ACTIVE"; return 0; }
  [ -f "$MERV_MAC_DB_JFFS"   ] && { printf '%s' "$MERV_MAC_DB_JFFS";   return 0; }
  return 1
}

# ============================================================================
# MERV_MAC ebtables chain lifecycle
# ============================================================================

# ebt_mac_shield_init
# Create MERV_MAC chain and insert FORWARD/INPUT jump rules. Idempotent.
# Must be called before ebt_mac_shield_apply — chain must exist before
# rules are appended.
ebt_mac_shield_init() {
  mervqt_has_ebtables || return 0
  [ "${DRY_RUN:-no}" = "yes" ] && return 0

  ebtables -t filter -N "$MERV_MAC_CHAIN" 2>/dev/null || true
  ebtables -t filter -L FORWARD 2>/dev/null | grep -qF "$MERV_MAC_CHAIN" || \
    ebtables -t filter -I FORWARD -j "$MERV_MAC_CHAIN" 2>/dev/null || true
  ebtables -t filter -L INPUT 2>/dev/null | grep -qF "$MERV_MAC_CHAIN" || \
    ebtables -t filter -I INPUT -j "$MERV_MAC_CHAIN" 2>/dev/null || true
}

# ebt_mac_shield_flush
# Flush per-MAC DROP rules from MERV_MAC. Chain and jumps survive.
# Must be called before every ebt_mac_shield_apply to prevent accumulation.
ebt_mac_shield_flush() {
  mervqt_has_ebtables || return 0
  [ "${DRY_RUN:-no}" = "yes" ] && return 0
  ebtables -t filter -F "$MERV_MAC_CHAIN" 2>/dev/null || true
}

# ebt_mac_shield_teardown
# Full removal: flush rules → delete jump refs → delete chain.
# Called from mervlan_boot.sh disable flows. Mirrors ebt_quarantine_teardown.
# Safe to call even if chain does not exist.
ebt_mac_shield_teardown() {
  mervqt_has_ebtables || return 0
  ebtables -t filter -F "$MERV_MAC_CHAIN" 2>/dev/null || true
  ebtables -t filter -D FORWARD -j "$MERV_MAC_CHAIN" 2>/dev/null || true
  ebtables -t filter -D INPUT   -j "$MERV_MAC_CHAIN" 2>/dev/null || true
  ebtables -t filter -X "$MERV_MAC_CHAIN" 2>/dev/null || true
}

# ebt_mac_shield_apply [db_path]
# Load DROP rules from db into MERV_MAC chain.
#
# Caller MUST call ebt_mac_shield_flush() first (see file header contract).
# Caller MUST call ebt_mac_shield_init() first — chain must exist.
#
# Validates all 4 fields per record. Uses mervqt_mac_lower before validation.
# Silently skips malformed records. Logs armed count and skip count.
#
# Rule shape: -s <mac> --logical-in br0 -j DROP
#   Fires only while the client's wl interface is enslaved to br0.
#   Goes dormant automatically once the interface is in its correct VLAN bridge.
#   No per-rule cleanup is needed after correct bridge placement.
ebt_mac_shield_apply() {
  mervqt_has_ebtables || return 0
  [ "${DRY_RUN:-no}" = "yes" ] && return 0

  local db="${1:-$MERV_MAC_DB_ACTIVE}"
  [ -f "$db" ] || return 0

  local ts mac iface vid rules=0 skipped=0

  while IFS=' ' read -r ts mac iface vid; do
    [ -n "$ts" ] && [ -n "$mac" ] && [ -n "$iface" ] && [ -n "$vid" ] || {
      skipped=$((skipped + 1)); continue
    }
    case "$ts" in ''|*[!0-9]*) skipped=$((skipped+1)); continue ;; esac
    mac=$(mervqt_mac_lower "$mac")
    mervqt_valid_mac      "$mac"   || { skipped=$((skipped+1)); continue; }
    mervqt_valid_wl_subif "$iface" || { skipped=$((skipped+1)); continue; }
    mervqt_valid_vid      "$vid"   || { skipped=$((skipped+1)); continue; }

    ebtables -t filter -A "$MERV_MAC_CHAIN" \
      -s "$mac" --logical-in br0 -j DROP 2>/dev/null || true
    rules=$((rules + 1))
  done < "$db"

  info -c vlan "MERV_MAC: armed ${rules} rule(s) from $(basename "$db") (skipped malformed: ${skipped})"
}

# ebt_mac_shield_init_and_apply [db_path]
# Convenience wrapper: flush → init → apply. Correct ordering is enforced here.
# Use this for single-call sites (cleanup_existing_config, boot_init).
ebt_mac_shield_init_and_apply() {
  local db="${1:-$MERV_MAC_DB_ACTIVE}"
  ebt_mac_shield_flush
  ebt_mac_shield_init
  ebt_mac_shield_apply "$db"
}

# Script-level state for repair-log deduplication — reset once per process invocation.
_MERV_MAC_SHIELD_STATE=""

# ============================================================================
# restore_merv_mac_shield
# Called every tick inside wait_for_rc_quiet alongside restore_merv_qt_shield.
# Idempotent: fast-paths when chain + jumps are both intact.
# Accepts an optional pre-fetched ebtables dump ($1) to avoid redundant reads.
#
# Repair logic (mirrors restore_merv_qt_shield split):
#   1. Chain + both jump rules intact: return immediately (no-op)
#   2. Chain intact, jumps flushed (orphaned): ebt_mac_shield_init only —
#      chain and per-MAC DROP rules are intact; just re-link jumps.
#   3. Chain wiped: flush → init → apply from best available db
# ============================================================================
restore_merv_mac_shield() {
  mervqt_has_ebtables || return 0

  # Accept shared dump from wait_for_rc_quiet, or fetch independently
  local full_rules="${1:-}"
  [ -n "$full_rules" ] || full_rules=$(ebtables -t filter -L 2>/dev/null)

  local chain_exists=1 jumps_exist=1

  # 1. Did the chain survive?
  printf '%s' "$full_rules" | grep -qF "Bridge chain: $MERV_MAC_CHAIN" || chain_exists=0

  # 2. Did both jump rules (FORWARD and INPUT) survive?
  # MERV_MAC's own rules use -j DROP, so any '-j $MERV_MAC_CHAIN' match
  # originates exclusively from FORWARD/INPUT jump rules.
  # Count >= 2 means both are present.
  # Pattern "j $MERV_MAC_CHAIN" (no leading dash): matches '-j CHAIN' jump rules but NOT
  # 'Bridge chain: CHAIN' (preceding char is ':' not 'j'). Avoids BusyBox v1.25.1
  # grep misinterpreting a leading '-j' pattern as an option flag.
  if [ "$chain_exists" -eq 1 ]; then
    if [ "$(printf '%s' "$full_rules" | grep -cF "j $MERV_MAC_CHAIN")" -lt 2 ]; then
      jumps_exist=0
    fi
  else
    jumps_exist=0
  fi

  # Fast path: chain and both jump rules intact
  if [ "$chain_exists" -eq 1 ] && [ "$jumps_exist" -eq 1 ]; then
    case "$_MERV_MAC_SHIELD_STATE" in
      ""|"ok") ;;
      *) info -c vlan "Heal: MERV_MAC shield stable — firmware flushing stopped" ;;
    esac
    _MERV_MAC_SHIELD_STATE="ok"
    return 0
  fi

  if [ "$chain_exists" -eq 0 ]; then
    # Full chain wipe: flush → init → apply from db
    ebt_mac_shield_flush
    ebt_mac_shield_init
    local db
    db=$(merv_mac_best_db 2>/dev/null) || true
    if [ -n "$db" ]; then
      ebt_mac_shield_apply "$db"
      [ "$_MERV_MAC_SHIELD_STATE" = "wiped" ] || \
        info -c vlan "Heal: MERV_MAC chain flushed by rc — fully rebuilt shield"
    else
      [ "$_MERV_MAC_SHIELD_STATE" = "wiped" ] || \
        info -c vlan "Heal: MERV_MAC chain flushed by rc — re-linked (no db, rules empty until next snapshot)"
    fi
    _MERV_MAC_SHIELD_STATE="wiped"
  else
    # Orphaned: chain and MAC rules intact — re-link jumps only (no flush, no rule reload)
    ebt_mac_shield_init
    [ "$_MERV_MAC_SHIELD_STATE" = "orphaned" ] || \
      info -c vlan "Heal: MERV_MAC orphaned by rc (FORWARD/INPUT jumps flushed) — re-linked shield"
    _MERV_MAC_SHIELD_STATE="orphaned"
  fi
}

LIB_MERVQT_LOADED=1
