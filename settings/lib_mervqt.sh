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
#                  - File: lib_mervqt.sh || version="0.54"                      #
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

# lib_radio.sh provides merv_is_wl_vap_iface and merv_is_wl_base_radio.
# Source it here so lib_mervqt.sh validators are self-consistent even when
# lib_mervqt.sh is loaded without a full manager environment (e.g. heal_event).
: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${LIB_RADIO_LOADED:-}" ] || . "$MERV_BASE/settings/lib_radio.sh" 2>/dev/null || true

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
# For Broadcom (wl*.*) delegates to merv_is_wl_vap_iface for strict numeric
# validation of both the radio index and slot number (rejects trailing garbage
# like wl0.1abc).  ra*.* and ath*.* are accepted via glob for forward
# compatibility with non-Broadcom drivers.
mervqt_valid_wl_subif() {
  case "$1" in
    wl*.*)
      if type merv_is_wl_vap_iface >/dev/null 2>&1; then
        merv_is_wl_vap_iface "$1"
      else
        # lib_radio.sh not available; fall back to conservative glob
        case "$1" in wl[0-9].[0-9]*|wl[0-9][0-9].[0-9]*) return 0 ;; esac
        return 1
      fi
      ;;
    ra[0-9].[0-9]*|ath[0-9].[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# mervqt_valid_vid — true if $1 is a numeric VLAN ID in the range 2–4094
mervqt_valid_vid() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 2 ] && [ "$1" -le 4094 ] 2>/dev/null
}

# ============================================================================
# MAC shield override list
# The override DB (MERV_MAC_OVERRIDE_DB) lists MACs whose MERV_MAC DROP rule is
# suppressed cluster-wide. It is a plain newline-separated list of lowercase
# MACs (one per line; blank lines and '#' comments ignored). MACs stay in the
# shield db; only their DROP rule is withheld while overridden.
# ============================================================================

# mervqt_override_list_read [db_path]
# Print a normalized, space-padded single-line override list: " mac1 mac2 ...".
# Leading/trailing spaces let mervqt_mac_is_overridden do exact substring match.
# Prints a single space (empty list) when the db is absent or empty.
mervqt_override_list_read() {
  local db="${1:-$MERV_MAC_OVERRIDE_DB}"
  local line mac out=' '
  [ -n "$db" ] && [ -f "$db" ] || { printf ' '; return 0; }
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    mac=$(mervqt_mac_lower "$line")
    mervqt_valid_mac "$mac" || continue
    case "$out" in *" $mac "*) continue ;; esac
    out="${out}${mac} "
  done < "$db"
  printf '%s' "$out"
}

# mervqt_mac_is_overridden <mac> <list>
# Return 0 if <mac> appears in the space-padded <list>, else 1.
mervqt_mac_is_overridden() {
  local mac; mac=$(mervqt_mac_lower "$1")
  local list="$2"
  case "$list" in *" $mac "*) return 0 ;; esac
  return 1
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
# Override-aware: MACs listed in MERV_MAC_OVERRIDE_DB are kept in the shield db
# but their DROP rule is suppressed (no rule armed). Removing the override and
# reloading re-locks the MAC. The override list is read once up-front.
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

  local _ovr_list
  _ovr_list=$(mervqt_override_list_read 2>/dev/null)

  local ts mac iface vid rules=0 skipped=0 overridden=0

  while IFS=' ' read -r ts mac iface vid; do
    [ -n "$ts" ] && [ -n "$mac" ] && [ -n "$iface" ] && [ -n "$vid" ] || {
      skipped=$((skipped + 1)); continue
    }
    case "$ts" in ''|*[!0-9]*) skipped=$((skipped+1)); continue ;; esac
    mac=$(mervqt_mac_lower "$mac")
    mervqt_valid_mac      "$mac"   || { skipped=$((skipped+1)); continue; }
    mervqt_valid_wl_subif "$iface" || { skipped=$((skipped+1)); continue; }
    mervqt_valid_vid      "$vid"   || { skipped=$((skipped+1)); continue; }

    if mervqt_mac_is_overridden "$mac" "$_ovr_list"; then
      overridden=$((overridden + 1))
      continue
    fi

    ebtables -t filter -A "$MERV_MAC_CHAIN" \
      -s "$mac" --logical-in br0 -j DROP 2>/dev/null || true
    rules=$((rules + 1))
  done < "$db"

  info -c vlan "MERV_MAC: armed ${rules} rule(s) from $(basename "$db") (overridden: ${overridden}, skipped malformed: ${skipped})"
}

# ebt_mac_shield_init_and_apply [db_path]
# Convenience wrapper: init → flush → apply. A first-run or post-teardown
# reload must create/re-link the chain before its per-MAC rules are flushed.
# Use this for single-call sites (cleanup_existing_config, boot_init).
ebt_mac_shield_init_and_apply() {
  local db="${1:-$MERV_MAC_DB_ACTIVE}"
  ebt_mac_shield_init
  ebt_mac_shield_flush
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
#   3. Chain wiped: init → flush → apply from best available db
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
    # Full chain wipe: create/re-link first, then flush and apply from db.
    ebt_mac_shield_init
    ebt_mac_shield_flush
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

# ============================================================================
# MERV_QT (L2 quarantine) restore — shared between heal and manager
# Chain name comes from $MERV_QT_CHAIN (var_settings). All literal "MERV_QT"
# references below are kept for BusyBox grep-pattern stability; they match the
# canonical default. Both values are identical by construction.
# ============================================================================

# Script-level state for repair-log deduplication — reset once per process.
_MERV_QT_SHIELD_STATE=""

# merv_qt_ensure_expected_rules
# Authoritative MERV_QT builder: create chain, link FORWARD/INPUT jumps, then
# install one DROP rule (scoped --logical-in br0) per MERVLAN-managed VLAN VAP.
# Expensive (calls merv_mac_build_expected_iface_vid). Call once before a wait
# loop, not per-tick — restore_merv_qt_shield handles cheap per-tick repair.
merv_qt_ensure_expected_rules() {
  local iface vid qt_rules _qt_pairs

  type ebtables >/dev/null 2>&1 || return 0
  [ "${DRY_RUN:-no}" = "yes" ] && return 0

  ebtables -t filter -N MERV_QT 2>/dev/null || true
  ebtables -t filter -L FORWARD 2>/dev/null | grep -qF 'MERV_QT' || \
    ebtables -t filter -I FORWARD -j MERV_QT 2>/dev/null || true
  ebtables -t filter -L INPUT 2>/dev/null | grep -qF 'MERV_QT' || \
    ebtables -t filter -I INPUT -j MERV_QT 2>/dev/null || true

  type merv_mac_build_expected_iface_vid >/dev/null 2>&1 || return 0

  # Use cached wrapper when available (manager apply path); falls through to
  # the raw builder otherwise.
  if type merv_iface_vid_list >/dev/null 2>&1; then
    _qt_pairs=$(merv_iface_vid_list)
  else
    _qt_pairs=$(merv_mac_build_expected_iface_vid 2>/dev/null)
  fi
  printf '%s\n' "$_qt_pairs" | while IFS=' ' read -r iface vid; do
    [ -n "$iface" ] && [ -n "$vid" ] || continue
    # Only quarantine VLAN-bound VAPs (real VID >= 2, purely numeric).
    # Never quarantine intentionally-native/br0 interfaces.
    case "$vid" in
      ''|none|trunk|0|1|*[!0-9]*) continue ;;
    esac
    [ "$vid" -ge 2 ] 2>/dev/null || continue

    qt_rules=$(ebtables -t filter -L MERV_QT 2>/dev/null)
    if printf '%s\n' "$qt_rules" | grep -qF -- "-i $iface" &&
       printf '%s\n' "$qt_rules" | grep -qF -- "logical-in br0"; then
      continue
    fi

    ebtables -t filter -A MERV_QT -i "$iface" --logical-in br0 -j DROP 2>/dev/null || true
  done
}

# restore_merv_qt_shield [ebtables_dump]
# Cheap per-tick re-arm of the MERV_QT chain after rc flushed ebtables.
# Fast paths:
#   chain + both jumps intact -> no-op (one stale-gate sweep only)
#   chain intact, jumps gone  -> relink jumps only (no DROP-rule rebuild)
#   chain wiped               -> relink jumps + rebuild expected DROP rules
# Accepts an optional pre-fetched `ebtables -t filter -L` dump to avoid a
# redundant read when called from a guard tick.
restore_merv_qt_shield() {
  type ebtables >/dev/null 2>&1 || return 0

  local full_rules="${1:-}"
  [ -n "$full_rules" ] || full_rules=$(ebtables -t filter -L 2>/dev/null)

  local chain_exists=1
  local jumps_exist=1

  printf '%s' "$full_rules" | grep -qF 'Bridge chain: MERV_QT' || chain_exists=0

  # MERV_QT's own rules use -j DROP, so any '-j MERV_QT' match originates only
  # from FORWARD/INPUT jumps. Count >= 2 means both are present. Pattern
  # 'j MERV_QT' (no leading dash) avoids BusyBox grep treating '-j' as a flag.
  if [ "$chain_exists" -eq 1 ]; then
    if [ "$(printf '%s' "$full_rules" | grep -cF 'j MERV_QT')" -lt 2 ]; then
      jumps_exist=0
    fi
  else
    jumps_exist=0
  fi

  # Fast path: shield completely intact. Sweep any stale emergency DHCP gate a
  # crashed re-link path may have left in FORWARD (-D is a no-op if absent).
  if [ "$chain_exists" -eq 1 ] && [ "$jumps_exist" -eq 1 ]; then
    ebtables -t filter -D FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
      --logical-in br0 -j DROP 2>/dev/null || true
    case "$_MERV_QT_SHIELD_STATE" in
      ""|"ok") ;;
      *) info -c vlan "Heal: MERV_QT shield stable — firmware flushing stopped" ;;
    esac
    _MERV_QT_SHIELD_STATE="ok"
    return 0
  fi

  # Re-link jumps. Reactive DHCP gate covers the <2ms window where the chain
  # exists but is not yet jumped from FORWARD. Stale-gate cleanup is idempotent.
  ebtables -t filter -D FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
    --logical-in br0 -j DROP 2>/dev/null || true
  ebtables -t filter -I FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
    --logical-in br0 -j DROP 2>/dev/null || true
  ebtables -t filter -N MERV_QT 2>/dev/null || true
  ebtables -t filter -L FORWARD 2>/dev/null | grep -qF 'MERV_QT' || \
    ebtables -t filter -I FORWARD -j MERV_QT 2>/dev/null || true
  ebtables -t filter -L INPUT   2>/dev/null | grep -qF 'MERV_QT' || \
    ebtables -t filter -I INPUT   -j MERV_QT 2>/dev/null || true
  ebtables -t filter -D FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
    --logical-in br0 -j DROP 2>/dev/null || true

  # Rebuild per-interface DROP rules only when the chain itself was wiped.
  if [ "$chain_exists" -eq 0 ]; then
    if type merv_qt_ensure_expected_rules >/dev/null 2>&1; then
      merv_qt_ensure_expected_rules
    elif type merv_iface_vid_list >/dev/null 2>&1; then
      merv_iface_vid_list | while IFS=' ' read -r _qt_iface _qt_vid; do
        [ -n "$_qt_iface" ] && [ -n "$_qt_vid" ] || continue
        case "$_qt_vid" in
          ''|none|trunk|0|1|*[!0-9]*) continue ;;
        esac
        [ "$_qt_vid" -ge 2 ] 2>/dev/null || continue
        ebtables -t filter -A MERV_QT -i "$_qt_iface" --logical-in br0 -j DROP 2>/dev/null || true
      done
    elif type merv_mac_build_expected_iface_vid >/dev/null 2>&1; then
      merv_mac_build_expected_iface_vid 2>/dev/null | while IFS=' ' read -r _qt_iface _qt_vid; do
        [ -n "$_qt_iface" ] && [ -n "$_qt_vid" ] || continue
        case "$_qt_vid" in
          ''|none|trunk|0|1|*[!0-9]*) continue ;;
        esac
        [ "$_qt_vid" -ge 2 ] 2>/dev/null || continue
        ebtables -t filter -A MERV_QT -i "$_qt_iface" --logical-in br0 -j DROP 2>/dev/null || true
      done
    else
      # Last-resort sysfs scan (partial-install/test recovery only).
      for _qt_path in /sys/class/net/wl*.* /sys/class/net/ra*.* /sys/class/net/ath*.*; do
        [ -e "$_qt_path" ] || continue
        ebtables -t filter -A MERV_QT -i "${_qt_path##*/}" --logical-in br0 -j DROP 2>/dev/null || true
      done
    fi
    [ "$_MERV_QT_SHIELD_STATE" = "wiped" ] || \
      info -c vlan "Heal: MERV_QT chain flushed by rc — fully rebuilt shield"
    _MERV_QT_SHIELD_STATE="wiped"
  else
    [ "$_MERV_QT_SHIELD_STATE" = "orphaned" ] || \
      info -c vlan "Heal: MERV_QT orphaned by rc (FORWARD/INPUT jumps flushed) — re-linked shield"
    _MERV_QT_SHIELD_STATE="orphaned"
  fi
}

# ============================================================================
# MERV_DHCP_HOLD — critical-section DHCP kill switch (shared)
# Blocks DHCP (udp dport 67) entering br0 while heal/manager owns a critical
# section. A .active marker under $LOCKDIR lets any tick re-arm idempotently.
# ============================================================================

# merv_dhcp_hold_arm [quiet] [no-marker]
#
# The hold marker records ownership by manager/heal callers so their guard
# ticks can restore the rule if firmware flushes ebtables mid-operation.  The
# boot shield is deliberately not an owner: it has its own
# merv_boot_shield.active marker and must not recreate the shared ownership
# marker after the manager has released it.
# ============================================================================
# Unified guard tick — restore every active L2 guard layer in one cheap call.
# Fetches the ebtables dump once and shares it with both shield restorers so a
# guard tick costs a single netlink read plus idempotent repairs. Each restorer
# fast-paths to a no-op when its chain and jumps are intact.
#
#   merv_l2_guard_restore_all [dump]  — restore QT + MAC + DHCP hold
#   merv_guard_tick                   — fetch dump once, then restore_all
#   merv_guarded_sleep N              — sleep N seconds, guard-ticking each 1s
#
# Use inside any non-trivial wait that overlaps firmware instability while a
# DHCP hold is (or may be) active. Do NOT sprinkle on trivial settle sleeps —
# the per-tick ebtables read is cheap but not free.
# ============================================================================
# ============================================================================
# Round 1 DHCP-hold protocol foundation
# ============================================================================
# Result classes: 0 success; 1 invalid/unsafe argument; 2 state transaction
# failure; 3 ebtables unavailable; 4 rule command/verification failure;
# 5 unsafe cleanup refused (reserved for the lease engine).

_merv_dhcp_log() {
  local _mdl_level="$1"
  shift
  if type "$_mdl_level" >/dev/null 2>&1; then
    "$_mdl_level" -c vlan "$*"
  else
    printf 'MerVLAN DHCP hold: %s\n' "$*" >&2
  fi
  return 0
}

merv_dhcp_hold_valid_id() {
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

merv_dhcp_hold_test_root_valid() {
  local _mdtr_root="${MERV_DHCP_HOLD_TEST_ROOT:-}"
  [ "${MERV_DHCP_HOLD_TEST_MODE:-0}" = "1" ] || return 1
  case "$_mdtr_root" in
    /tmp/mervlan_tmp/selftest.*) ;;
    *) return 1 ;;
  esac
  case "$_mdtr_root" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
  [ "$_mdtr_root" != "/tmp/mervlan_tmp/selftest." ] || return 1
  return 0
}

merv_dhcp_hold_state_root_valid() {
  local _mdsr_root="${MERV_DHCP_HOLD_STATE_ROOT:-}"
  [ -n "$_mdsr_root" ] || return 1
  if [ "${MERV_DHCP_HOLD_TEST_MODE:-0}" = "1" ]; then
    merv_dhcp_hold_test_root_valid || return 1
    case "$_mdsr_root" in
      "$MERV_DHCP_HOLD_TEST_ROOT"|"$MERV_DHCP_HOLD_TEST_ROOT"/*) ;;
      *) return 1 ;;
    esac
    case "$_mdsr_root" in *..*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    return 0
  fi
  [ "$_mdsr_root" = "${LOCKDIR:-/tmp/mervlan_tmp/locks}/dhcp_hold" ]
}

merv_dhcp_hold_state_init() {
  merv_dhcp_hold_state_root_valid || {
    _merv_dhcp_log error "refusing unsafe state root '${MERV_DHCP_HOLD_STATE_ROOT:-}'"
    return 1
  }
  mkdir -p "$MERV_DHCP_HOLD_STATE_ROOT/faults" \
    "$MERV_DHCP_HOLD_STATE_ROOT/intents" \
    "$MERV_DHCP_HOLD_STATE_ROOT/owners" \
    "$MERV_DHCP_HOLD_STATE_ROOT/failsafe" \
    "$MERV_DHCP_HOLD_STATE_ROOT/handoffs" 2>/dev/null || return 2
  return 0
}

# merv_proc_start_time <pid> [proc-root]
# Parse after the final ") " so spaces/parentheses in comm cannot shift field 22.
merv_proc_start_time() {
  local _mps_pid="$1" _mps_root="${2:-/proc}" _mps_line _mps_tail _mps_start
  case "$_mps_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$_mps_root" != "/proc" ]; then
    merv_dhcp_hold_test_root_valid || return 1
    case "$_mps_root" in "$MERV_DHCP_HOLD_TEST_ROOT"/*) ;; *) return 1 ;; esac
  fi
  _mps_line=$(cat "$_mps_root/$_mps_pid/stat" 2>/dev/null) || return 1
  case "$_mps_line" in *") "*) _mps_tail=${_mps_line##*) } ;; *) return 1 ;; esac
  _mps_start=$(printf '%s\n' "$_mps_tail" | awk '{print $20}')
  case "$_mps_start" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$_mps_start"
  return 0
}

merv_dhcp_proc_root() {
  local _mdpr_root="${MERV_DHCP_HOLD_PROC_ROOT:-/proc}"
  if [ "$_mdpr_root" = "/proc" ]; then
    printf '/proc\n'
    return 0
  fi
  merv_dhcp_hold_test_root_valid || return 1
  case "$_mdpr_root" in "$MERV_DHCP_HOLD_TEST_ROOT"/*) ;; *) return 1 ;; esac
  printf '%s\n' "$_mdpr_root"
  return 0
}

merv_process_identity_matches() {
  local _mpim_pid="$1" _mpim_expected="$2" _mpim_root="${3:-/proc}" _mpim_actual
  case "$_mpim_expected" in ''|*[!0-9]*) return 1 ;; esac
  _mpim_actual=$(merv_proc_start_time "$_mpim_pid" "$_mpim_root" 2>/dev/null) || return 1
  [ "$_mpim_actual" = "$_mpim_expected" ] || return 1
  if [ "$_mpim_root" = "/proc" ]; then
    kill -0 "$_mpim_pid" 2>/dev/null || return 1
  fi
  return 0
}

_merv_dhcp_nonce() {
  local _mdn_start _mdn_now _mdn_proc
  _mdn_proc=$(merv_dhcp_proc_root 2>/dev/null || printf '/proc')
  _mdn_start=$(merv_proc_start_time "$$" "$_mdn_proc" 2>/dev/null || printf '0')
  _mdn_now=$(date +%s 2>/dev/null || printf '0')
  printf '%s-%s-%s-%s\n' "$_mdn_now" "$$" "$_mdn_start" "${RANDOM:-0}"
}

# Dedicated DHCP state lock. Live PID/start-time owners are never reclaimed
# because of age. Dead or reused-PID locks are atomically quarantined first.
merv_dhcp_state_lock_acquire() {
  local _mdla_lock _mdla_pid _mdla_start _mdla_nonce _mdla_created _mdla_owner_nonce
  local _mdla_quarantine _mdla_proc _mdla_attempt=0 _mdla_max=5
  local _mdla_now _mdla_mtime _mdla_age _mdla_incomplete_stale
  merv_dhcp_hold_state_init || return $?
  _mdla_proc=$(merv_dhcp_proc_root) || return 1
  type usleep >/dev/null 2>&1 && _mdla_max=100
  _mdla_pid="$$"
  _mdla_start=$(merv_proc_start_time "$$" "$_mdla_proc" 2>/dev/null) || return 1
  _mdla_created=$(date +%s 2>/dev/null || printf '0')
  _mdla_nonce=$(_merv_dhcp_nonce)
  _mdla_incomplete_stale="${MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC:-30}"
  case "$_mdla_incomplete_stale" in ''|*[!0-9]*) _mdla_incomplete_stale=30 ;; esac
  _mdla_lock="$MERV_DHCP_HOLD_STATE_ROOT/state.lock"
  while [ "$_mdla_attempt" -lt "$_mdla_max" ]; do
    if mkdir "$_mdla_lock" 2>/dev/null; then
      # The probe fields below are overwritten while inspecting a contended
      # lock. Re-read this process identity after our mkdir succeeds so a
      # waiter can never publish the previous owner's start time.
      _mdla_pid="$$"
      _mdla_start=$(merv_proc_start_time "$$" "$_mdla_proc" 2>/dev/null) || {
        rmdir "$_mdla_lock" 2>/dev/null || :
        return 2
      }
      _mdla_created=$(date +%s 2>/dev/null || printf '0')
      _mdla_nonce=$(_merv_dhcp_nonce)
      if printf '%s\n' "$_mdla_pid" > "$_mdla_lock/pid" 2>/dev/null &&
         printf '%s\n' "$_mdla_start" > "$_mdla_lock/proc_start_time" 2>/dev/null &&
         printf '%s\n' "$_mdla_created" > "$_mdla_lock/created_epoch" 2>/dev/null &&
         printf '%s\n' "$_mdla_nonce" > "$_mdla_lock/owner_nonce" 2>/dev/null; then
        MERV_DHCP_STATE_LOCK_NONCE="$_mdla_nonce"
        return 0
      fi
      _mdla_quarantine="${_mdla_lock}.incomplete.${_mdla_created}.$$"
      mv "$_mdla_lock" "$_mdla_quarantine" 2>/dev/null || :
      return 2
    fi

    _mdla_pid=$(cat "$_mdla_lock/pid" 2>/dev/null || printf '')
    _mdla_start=$(cat "$_mdla_lock/proc_start_time" 2>/dev/null || printf '')
    _mdla_created=$(cat "$_mdla_lock/created_epoch" 2>/dev/null || printf '')
    _mdla_owner_nonce=$(cat "$_mdla_lock/owner_nonce" 2>/dev/null || printf '')
    case "$_mdla_pid:$_mdla_start:$_mdla_created:$_mdla_owner_nonce" in
      :*|*::*|*:|*[!A-Za-z0-9._:-]*) _mdla_owner_nonce="" ;;
    esac
    if [ -z "$_mdla_owner_nonce" ]; then
      # mkdir publishes the exclusion point before its metadata files can be
      # written. Treat that brief incomplete directory as a live publication,
      # not a stale lock. A PID whose current start time is readable is also
      # never stolen even when the remaining fields are incomplete.
      if case "$_mdla_pid" in ''|*[!0-9]*) false ;; *) merv_proc_start_time "$_mdla_pid" "$_mdla_proc" >/dev/null 2>&1 ;; esac; then
        :
      else
        _mdla_now=$(date +%s 2>/dev/null || printf '0')
        _mdla_mtime=$(stat -c %Y "$_mdla_lock" 2>/dev/null || printf '%s' "$_mdla_now")
        case "$_mdla_now:$_mdla_mtime" in *[!0-9:]*) _mdla_age=0 ;; *)
          _mdla_age=$((_mdla_now - _mdla_mtime))
          [ "$_mdla_age" -ge 0 ] || _mdla_age=0
          ;;
        esac
        if [ "$_mdla_age" -ge "$_mdla_incomplete_stale" ]; then
          _mdla_quarantine="${_mdla_lock}.incomplete-stale.${_mdla_now}.$$.$_mdla_attempt"
          if mv "$_mdla_lock" "$_mdla_quarantine" 2>/dev/null; then
            _merv_dhcp_log warn "quarantined stale incomplete DHCP state lock"
          fi
          _mdla_attempt=$((_mdla_attempt + 1))
          continue
        fi
      fi
      if type usleep >/dev/null 2>&1; then usleep 50000; else sleep 1; fi
      _mdla_attempt=$((_mdla_attempt + 1))
      continue
    fi
    if merv_process_identity_matches "$_mdla_pid" "$_mdla_start" "$_mdla_proc" 2>/dev/null; then
      # A legitimate state transaction is normally held for milliseconds.
      # Honour it and wait within a strict bound; never steal a matching live
      # owner, and do not turn harmless poll/publication contention into a
      # failed security handoff.
      if type usleep >/dev/null 2>&1; then
        usleep 50000
      else
        sleep 1
      fi
      _mdla_attempt=$((_mdla_attempt + 1))
      continue
    fi
    _mdla_created=$(date +%s 2>/dev/null || printf '0')
    _mdla_quarantine="${_mdla_lock}.stale.${_mdla_created}.$$.$_mdla_attempt"
    if mv "$_mdla_lock" "$_mdla_quarantine" 2>/dev/null; then
      _merv_dhcp_log warn "quarantined dead or reused-PID DHCP state lock"
    fi
    _mdla_attempt=$((_mdla_attempt + 1))
  done
  return 2
}

merv_dhcp_state_lock_release() {
  local _mdlr_lock _mdlr_expected _mdlr_actual _mdlr_pid _mdlr_start _mdlr_proc
  merv_dhcp_hold_state_root_valid || return 1
  _mdlr_lock="$MERV_DHCP_HOLD_STATE_ROOT/state.lock"
  _mdlr_expected="${1:-${MERV_DHCP_STATE_LOCK_NONCE:-}}"
  [ -n "$_mdlr_expected" ] || return 2
  _mdlr_proc=$(merv_dhcp_proc_root) || return 2
  _mdlr_pid=$(cat "$_mdlr_lock/pid" 2>/dev/null || printf '')
  _mdlr_start=$(cat "$_mdlr_lock/proc_start_time" 2>/dev/null || printf '')
  [ "$_mdlr_pid" = "$$" ] || return 2
  merv_process_identity_matches "$_mdlr_pid" "$_mdlr_start" "$_mdlr_proc" 2>/dev/null || return 2
  _mdlr_actual=$(cat "$_mdlr_lock/owner_nonce" 2>/dev/null || printf '')
  [ "$_mdlr_actual" = "$_mdlr_expected" ] || return 2
  rm -f "$_mdlr_lock/pid" "$_mdlr_lock/proc_start_time" \
    "$_mdlr_lock/created_epoch" "$_mdlr_lock/owner_nonce" 2>/dev/null || return 2
  rmdir "$_mdlr_lock" 2>/dev/null || return 2
  MERV_DHCP_STATE_LOCK_NONCE=""
  return 0
}

# A state-lock release is part of the transaction result. Callers use this
# helper on failure paths so a cleanup/ownership failure is reported and
# cannot be silently converted into success.
merv_dhcp_state_lock_release_or_report() {
  local _mdrl_expected="${1:-${MERV_DHCP_STATE_LOCK_NONCE:-}}"
  merv_dhcp_state_lock_release "$_mdrl_expected" && return 0
  _merv_dhcp_log error "DHCP state-lock release failed; state retained for reconciliation"
  return 1
}

merv_dhcp_hold_fault_checkpoint() {
  local _mdfc_name="$1"
  merv_dhcp_hold_valid_id "$_mdfc_name" || return 1
  [ "${MERV_DHCP_HOLD_FAULT_POINT:-}" = "$_mdfc_name" ] || return 0
  _merv_dhcp_log warn "fault injection checkpoint reached: $_mdfc_name"
  case "${MERV_DHCP_HOLD_FAULT_ACTION:-return}" in
    kill)
      kill -9 "$$" 2>/dev/null
      ;;
    return) ;;
    *) return 1 ;;
  esac
  return 99
}

merv_dhcp_hold_record_fault() {
  local _mdrf_reason="$1" _mdrf_desired="${2:-unknown}" _mdrf_observed="${3:-unknown}"
  local _mdrf_now _mdrf_id _mdrf_tmp _mdrf_dst
  merv_dhcp_hold_valid_id "$_mdrf_reason" || _mdrf_reason="invalid-reason"
  merv_dhcp_hold_state_init || return 2
  _mdrf_now=$(date +%s 2>/dev/null || printf '0')
  _mdrf_id="${_mdrf_reason}.${_mdrf_now}.$$.$(_merv_dhcp_nonce)"
  _mdrf_tmp="$MERV_DHCP_HOLD_STATE_ROOT/faults/.${_mdrf_id}.tmp"
  _mdrf_dst="$MERV_DHCP_HOLD_STATE_ROOT/faults/${_mdrf_id}"
  {
    printf 'reason=%s\n' "$_mdrf_reason"
    printf 'desired=%s\n' "$_mdrf_desired"
    printf 'observed=%s\n' "$_mdrf_observed"
    printf 'epoch=%s\n' "$_mdrf_now"
  } > "$_mdrf_tmp" 2>/dev/null || return 2
  mv "$_mdrf_tmp" "$_mdrf_dst" 2>/dev/null || return 2
  return 0
}

_merv_dhcp_has_ebtables() {
  if [ -n "${MERV_DHCP_HOLD_EBTABLES:-}" ]; then
    merv_dhcp_hold_test_root_valid || return 1
    case "$MERV_DHCP_HOLD_EBTABLES" in
      "$MERV_DHCP_HOLD_TEST_ROOT"/*) [ -x "$MERV_DHCP_HOLD_EBTABLES" ] ;;
      *) return 1 ;;
    esac
    return $?
  fi
  type ebtables >/dev/null 2>&1
}

_merv_dhcp_ebtables() {
  if [ -n "${MERV_DHCP_HOLD_EBTABLES:-}" ]; then
    _merv_dhcp_has_ebtables || return 127
    "$MERV_DHCP_HOLD_EBTABLES" "$@"
  else
    ebtables "$@"
  fi
}

_merv_dhcp_list_chain() {
  _merv_dhcp_ebtables -t filter -L "$1" --Lx 2>/dev/null ||
    _merv_dhcp_ebtables -t filter -L "$1" 2>/dev/null
}

# Prints: exact-rule-count target-jump-count total-rule-count.
_merv_dhcp_rule_stats() {
  local _mdrs_chain="$1" _mdrs_exact="$2" _mdrs_target="${3:-}" _mdrs_dump
  _mdrs_dump=$(_merv_dhcp_list_chain "$_mdrs_chain") || return 1
  printf '%s\n' "$_mdrs_dump" | awk -v chain="$_mdrs_chain" \
    -v exact="$_mdrs_exact" -v target="$_mdrs_target" '
    function normalize(s, p) {
      gsub(/[[:space:]]+/, " ", s)
      sub(/^ /, "", s); sub(/ $/, "", s)
      p = "-A " chain " "
      if (index(s, p) > 0) s = substr(s, index(s, p) + length(p))
      return s
    }
    {
      line = normalize($0)
      if (line !~ /^-/) next
      total++
      if (line == exact) exact_count++
      if (target != "") {
        n = split(line, word, " ")
        for (i = 1; i < n; i++)
          if (word[i] == "-j" && word[i + 1] == target) { target_count++; break }
      }
    }
    END { print exact_count + 0, target_count + 0, total + 0 }
  '
}

_merv_dhcp_first_target_rule() {
  local _mdftr_chain="$1" _mdftr_target="$2" _mdftr_dump
  _mdftr_dump=$(_merv_dhcp_list_chain "$_mdftr_chain") || return 1
  printf '%s\n' "$_mdftr_dump" | awk -v chain="$_mdftr_chain" -v target="$_mdftr_target" '
    function normalize(s, p) {
      gsub(/[[:space:]]+/, " ", s)
      sub(/^ /, "", s); sub(/ $/, "", s)
      p = "-A " chain " "
      if (index(s, p) > 0) s = substr(s, index(s, p) + length(p))
      return s
    }
    {
      line = normalize($0)
      if (line !~ /^-/) next
      n = split(line, word, " ")
      for (i = 1; i < n; i++)
        if (word[i] == "-j" && word[i + 1] == target) { print line; exit }
    }
  '
}

_merv_dhcp_remove_target_jumps() {
  local _mdrtj_parent="$1" _mdrtj_rule _mdrtj_count=0
  while :; do
    _mdrtj_rule=$(_merv_dhcp_first_target_rule "$_mdrtj_parent" "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null)
    [ -n "$_mdrtj_rule" ] || return 0
    set -- $_mdrtj_rule
    _merv_dhcp_ebtables -t filter -D "$_mdrtj_parent" "$@" 2>/dev/null || return 4
    _mdrtj_count=$((_mdrtj_count + 1))
    [ "$_mdrtj_count" -lt 128 ] || return 4
  done
}

merv_dhcp_hold_rules_observed() {
  local _mdro_drop _mdro_forward _mdro_input _mdro_chain
  _merv_dhcp_has_ebtables || {
    printf 'ebtables=unavailable\n'
    return 3
  }
  if _merv_dhcp_list_chain "$MERV_DHCP_HOLD_CHAIN" >/dev/null 2>&1; then
    _mdro_chain=yes
    _mdro_drop=$(_merv_dhcp_rule_stats "$MERV_DHCP_HOLD_CHAIN" \
      "-p IPv4 --ip-proto udp --ip-dport 67 -j DROP" "")
  else
    _mdro_chain=no
    _mdro_drop="0 0 0"
  fi
  _mdro_forward=$(_merv_dhcp_rule_stats FORWARD "-j $MERV_DHCP_HOLD_CHAIN" "$MERV_DHCP_HOLD_CHAIN") || _mdro_forward="0 0 0"
  _mdro_input=$(_merv_dhcp_rule_stats INPUT "-j $MERV_DHCP_HOLD_CHAIN" "$MERV_DHCP_HOLD_CHAIN") || _mdro_input="0 0 0"
  set -- $_mdro_drop
  printf 'chain=%s drop_exact=%s chain_rules=%s ' "$_mdro_chain" "${1:-0}" "${3:-0}"
  set -- $_mdro_forward
  printf 'forward_exact=%s forward_target=%s ' "${1:-0}" "${2:-0}"
  set -- $_mdro_input
  printf 'input_exact=%s input_target=%s\n' "${1:-0}" "${2:-0}"
  return 0
}

merv_dhcp_hold_rules_present() {
  local _mdrp_drop _mdrp_forward _mdrp_input
  merv_dhcp_hold_valid_id "$MERV_DHCP_HOLD_CHAIN" || return 1
  _merv_dhcp_has_ebtables || return 3
  _merv_dhcp_list_chain "$MERV_DHCP_HOLD_CHAIN" >/dev/null 2>&1 || return 4
  _mdrp_drop=$(_merv_dhcp_rule_stats "$MERV_DHCP_HOLD_CHAIN" \
    "-p IPv4 --ip-proto udp --ip-dport 67 -j DROP" "") || return 4
  _mdrp_forward=$(_merv_dhcp_rule_stats FORWARD "-j $MERV_DHCP_HOLD_CHAIN" "$MERV_DHCP_HOLD_CHAIN") || return 4
  _mdrp_input=$(_merv_dhcp_rule_stats INPUT "-j $MERV_DHCP_HOLD_CHAIN" "$MERV_DHCP_HOLD_CHAIN") || return 4
  set -- $_mdrp_drop
  [ "${1:-0}" -eq 1 ] && [ "${3:-0}" -eq 1 ] || return 4
  set -- $_mdrp_forward
  [ "${1:-0}" -eq 1 ] && [ "${2:-0}" -eq 1 ] || return 4
  set -- $_mdrp_input
  [ "${1:-0}" -eq 1 ] && [ "${2:-0}" -eq 1 ] || return 4
  return 0
}

merv_dhcp_hold_rules_absent() {
  local _mdra_forward _mdra_input
  _merv_dhcp_has_ebtables || return 3
  _merv_dhcp_list_chain "$MERV_DHCP_HOLD_CHAIN" >/dev/null 2>&1 && return 4
  _mdra_forward=$(_merv_dhcp_rule_stats FORWARD "" "$MERV_DHCP_HOLD_CHAIN") || return 4
  _mdra_input=$(_merv_dhcp_rule_stats INPUT "" "$MERV_DHCP_HOLD_CHAIN") || return 4
  set -- $_mdra_forward
  [ "${2:-0}" -eq 0 ] || return 4
  set -- $_mdra_input
  [ "${2:-0}" -eq 0 ] || return 4
  return 0
}

_merv_dhcp_enforce_fail() {
  local _mdef_rc="$1" _mdef_reason="$2" _mdef_observed
  _mdef_observed=$(merv_dhcp_hold_rules_observed 2>/dev/null || printf 'unavailable')
  merv_dhcp_hold_record_fault "$_mdef_reason" hold "$_mdef_observed" >/dev/null 2>&1 || :
  return "$_mdef_rc"
}

_merv_dhcp_hold_enforce_locked() {
  local _mdhe_point
  merv_dhcp_hold_state_init || return $?
  merv_dhcp_hold_valid_id "$MERV_DHCP_HOLD_CHAIN" || return 1
  _merv_dhcp_has_ebtables || {
    merv_dhcp_hold_record_fault ebtables-unavailable hold unavailable >/dev/null 2>&1 || :
    return 3
  }

  # A watchdog tick against an already exact gate must be read-only. Rebuilding
  # the same rules every second briefly removed each parent jump before
  # reinserting it, creating an observable FORWARD-only gap on real ebtables.
  # Firmware-flushed or otherwise non-exact state still takes the repair path.
  merv_dhcp_hold_rules_present && return 0

  for _mdhe_point in enforce-before-chain enforce-after-chain enforce-after-drop \
    enforce-after-forward enforce-after-input enforce-before-verify; do
    case "$_mdhe_point" in
      enforce-before-chain) ;;
      enforce-after-chain)
        _merv_dhcp_ebtables -t filter -N "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || \
          _merv_dhcp_list_chain "$MERV_DHCP_HOLD_CHAIN" >/dev/null 2>&1 || \
          { _merv_dhcp_enforce_fail 4 chain-create-failed; return $?; }
        ;;
      enforce-after-drop)
        _merv_dhcp_ebtables -t filter -F "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || \
          { _merv_dhcp_enforce_fail 4 chain-flush-failed; return $?; }
        _merv_dhcp_ebtables -t filter -A "$MERV_DHCP_HOLD_CHAIN" \
          -p IPv4 --ip-proto udp --ip-dport 67 -j DROP 2>/dev/null || \
          { _merv_dhcp_enforce_fail 4 drop-install-failed; return $?; }
        ;;
      enforce-after-forward)
        _merv_dhcp_remove_target_jumps FORWARD || \
          { _merv_dhcp_enforce_fail 4 forward-cleanup-failed; return $?; }
        _merv_dhcp_ebtables -t filter -I FORWARD -j "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || \
          { _merv_dhcp_enforce_fail 4 forward-install-failed; return $?; }
        ;;
      enforce-after-input)
        _merv_dhcp_remove_target_jumps INPUT || \
          { _merv_dhcp_enforce_fail 4 input-cleanup-failed; return $?; }
        _merv_dhcp_ebtables -t filter -I INPUT -j "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || \
          { _merv_dhcp_enforce_fail 4 input-install-failed; return $?; }
        ;;
      enforce-before-verify) ;;
    esac
    if ! merv_dhcp_hold_fault_checkpoint "$_mdhe_point"; then
      _merv_dhcp_enforce_fail 4 checkpoint-interrupted
      return 4
    fi
  done

  merv_dhcp_hold_rules_present || {
    _merv_dhcp_enforce_fail 4 exact-verification-failed
    return 4
  }
  return 0
}

merv_dhcp_hold_enforce() {
  local _mdhe_nonce _mdhe_rc
  merv_dhcp_state_lock_acquire || return 2
  _mdhe_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_hold_enforce_locked
  _mdhe_rc=$?
  merv_dhcp_state_lock_release "$_mdhe_nonce" || return 2
  return "$_mdhe_rc"
}

_merv_dhcp_hold_rules_remove_locked() {
  local _mdhrr_observed
  merv_dhcp_hold_state_init || return $?
  merv_dhcp_hold_valid_id "$MERV_DHCP_HOLD_CHAIN" || return 1
  _merv_dhcp_has_ebtables || {
    merv_dhcp_hold_record_fault cleanup-unavailable clear unavailable >/dev/null 2>&1 || :
    return 3
  }
  _merv_dhcp_remove_target_jumps FORWARD || {
    merv_dhcp_hold_record_fault forward-remove-failed clear mismatch >/dev/null 2>&1 || :
    return 4
  }
  _merv_dhcp_remove_target_jumps INPUT || {
    merv_dhcp_hold_record_fault input-remove-failed clear mismatch >/dev/null 2>&1 || :
    return 4
  }
  if _merv_dhcp_list_chain "$MERV_DHCP_HOLD_CHAIN" >/dev/null 2>&1; then
    _merv_dhcp_ebtables -t filter -F "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || return 4
    _merv_dhcp_ebtables -t filter -X "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || return 4
  fi
  merv_dhcp_hold_rules_absent || {
    _mdhrr_observed=$(merv_dhcp_hold_rules_observed 2>/dev/null || printf 'unavailable')
    merv_dhcp_hold_record_fault cleanup-mismatch clear "$_mdhrr_observed" >/dev/null 2>&1 || :
    return 4
  }
  return 0
}

merv_dhcp_hold_rules_remove() {
  local _mdhrr_nonce _mdhrr_rc
  merv_dhcp_state_lock_acquire || return 2
  _mdhrr_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_hold_rules_remove_locked
  _mdhrr_rc=$?
  merv_dhcp_state_lock_release "$_mdhrr_nonce" || return 2
  return "$_mdhrr_rc"
}

_merv_dhcp_atomic_field() {
  local _mdaf_dir="$1" _mdaf_name="$2" _mdaf_value="$3" _mdaf_tmp
  [ -d "$_mdaf_dir" ] || return 2
  case "$_mdaf_name" in
    owner_type|run_id|pid|proc_start_time|created_epoch|phase|reason|parent_run_id|handoff_id|heartbeat_epoch|ready|verification_id|owner_token_reference|requested_epoch|source|handoff_state|parent_owner_type|parent_token_reference|child_owner_type|ack_child_run_id|ack_child_token_reference|ack_epoch|completed_epoch|parent_retired_epoch|coalesced_epoch|failed_epoch|failure_reason|failed_interfaces|expected_bridges|observed_bridges|missing_rules|asus_work|suggested_action|last_retry_epoch) ;;
    *) return 1 ;;
  esac
  _mdaf_tmp="$_mdaf_dir/.${_mdaf_name}.tmp.$$"
  printf '%s\n' "$_mdaf_value" > "$_mdaf_tmp" 2>/dev/null || return 2
  mv "$_mdaf_tmp" "$_mdaf_dir/$_mdaf_name" 2>/dev/null || return 2
  return 0
}

_merv_dhcp_record_remove_locked() {
  local _mdrr_kind="$1" _mdrr_id="$2" _mdrr_dir
  merv_dhcp_hold_valid_id "$_mdrr_id" || return 1
  case "$_mdrr_kind" in
    intents|owners|failsafe|handoffs) ;;
    *) return 1 ;;
  esac
  _mdrr_dir="$MERV_DHCP_HOLD_STATE_ROOT/$_mdrr_kind/$_mdrr_id"
  [ -d "$_mdrr_dir" ] || return 0
  rm -f "$_mdrr_dir/owner_type" "$_mdrr_dir/run_id" "$_mdrr_dir/pid" \
    "$_mdrr_dir/proc_start_time" "$_mdrr_dir/created_epoch" \
    "$_mdrr_dir/phase" "$_mdrr_dir/reason" "$_mdrr_dir/parent_run_id" \
    "$_mdrr_dir/handoff_id" "$_mdrr_dir/heartbeat_epoch" \
    "$_mdrr_dir/verification_id" "$_mdrr_dir/owner_token_reference" \
    "$_mdrr_dir/requested_epoch" "$_mdrr_dir/source" \
    "$_mdrr_dir/handoff_state" "$_mdrr_dir/parent_owner_type" \
    "$_mdrr_dir/parent_token_reference" "$_mdrr_dir/child_owner_type" \
    "$_mdrr_dir/ack_child_run_id" "$_mdrr_dir/ack_child_token_reference" \
    "$_mdrr_dir/ack_epoch" "$_mdrr_dir/completed_epoch" \
    "$_mdrr_dir/parent_retired_epoch" "$_mdrr_dir/coalesced_epoch" \
    "$_mdrr_dir/failed_epoch" "$_mdrr_dir/failure_reason" \
    "$_mdrr_dir/failed_interfaces" "$_mdrr_dir/expected_bridges" \
    "$_mdrr_dir/observed_bridges" "$_mdrr_dir/missing_rules" \
    "$_mdrr_dir/asus_work" "$_mdrr_dir/suggested_action" \
    "$_mdrr_dir/last_retry_epoch" \
    "$_mdrr_dir/ready" 2>/dev/null || return 2
  rmdir "$_mdrr_dir" 2>/dev/null || return 2
  return 0
}

_merv_dhcp_pending_remove_locked() {
  local _mdpr_dir="$1"
  case "$_mdpr_dir" in "$MERV_DHCP_HOLD_STATE_ROOT/owners/".*.pending.*) ;; *) return 1 ;; esac
  [ -d "$_mdpr_dir" ] || return 0
  rm -f "$_mdpr_dir/owner_type" "$_mdpr_dir/run_id" "$_mdpr_dir/pid" \
    "$_mdpr_dir/proc_start_time" "$_mdpr_dir/created_epoch" \
    "$_mdpr_dir/phase" "$_mdpr_dir/reason" "$_mdpr_dir/parent_run_id" \
    "$_mdpr_dir/handoff_id" "$_mdpr_dir/heartbeat_epoch" \
    "$_mdpr_dir/verification_id" "$_mdpr_dir/ready" 2>/dev/null || return 2
  rmdir "$_mdpr_dir" 2>/dev/null || return 2
  return 0
}

_merv_dhcp_owner_type_valid() {
  case "$1" in boot-watchdog|manager|heal|recovery) return 0 ;; *) return 1 ;; esac
}

_merv_dhcp_short_token() {
  printf '%s' "$1" | cut -c 1-12
}

_merv_dhcp_owner_load_locked() {
  local _mdol_token="$1" _mdol_dir
  merv_dhcp_hold_valid_id "$_mdol_token" || return 1
  _mdol_dir="$MERV_DHCP_HOLD_STATE_ROOT/owners/$_mdol_token"
  [ -d "$_mdol_dir" ] && [ -f "$_mdol_dir/ready" ] || return 1
  _MERV_DHCP_OWNER_DIR="$_mdol_dir"
  _MERV_DHCP_OWNER_TYPE=$(cat "$_mdol_dir/owner_type" 2>/dev/null || printf '')
  _MERV_DHCP_OWNER_RUN_ID=$(cat "$_mdol_dir/run_id" 2>/dev/null || printf '')
  _MERV_DHCP_OWNER_PID=$(cat "$_mdol_dir/pid" 2>/dev/null || printf '')
  _MERV_DHCP_OWNER_START=$(cat "$_mdol_dir/proc_start_time" 2>/dev/null || printf '')
  _MERV_DHCP_OWNER_PHASE=$(cat "$_mdol_dir/phase" 2>/dev/null || printf '')
  _merv_dhcp_owner_type_valid "$_MERV_DHCP_OWNER_TYPE" || return 1
  merv_dhcp_hold_valid_id "$_MERV_DHCP_OWNER_RUN_ID" || return 1
  case "$_MERV_DHCP_OWNER_PHASE" in protected|mutating|handoff_wait|verified) ;; *) return 1 ;; esac
  return 0
}

_merv_dhcp_owner_is_caller_locked() {
  local _mdoic_proc _mdoic_start
  _merv_dhcp_owner_load_locked "$1" || return 1
  [ "$_MERV_DHCP_OWNER_PID" = "$$" ] || return 1
  _mdoic_proc=$(merv_dhcp_proc_root) || return 1
  _mdoic_start=$(merv_proc_start_time "$$" "$_mdoic_proc" 2>/dev/null) || return 1
  [ "$_MERV_DHCP_OWNER_START" = "$_mdoic_start" ] || return 1
  merv_process_identity_matches "$_MERV_DHCP_OWNER_PID" "$_MERV_DHCP_OWNER_START" "$_mdoic_proc"
}

_merv_dhcp_required_locked() {
  local _mdreq_dir
  [ -f "${MERV_DHCP_HOLD_LEGACY_MARKER:-${LOCKDIR}/merv_dhcp_hold.active}" ] && return 0
  for _mdreq_dir in "$MERV_DHCP_HOLD_STATE_ROOT/owners/"*; do
    [ -d "$_mdreq_dir" ] && [ -f "$_mdreq_dir/ready" ] && return 0
  done
  for _mdreq_dir in "$MERV_DHCP_HOLD_STATE_ROOT/failsafe/"*; do
    [ -d "$_mdreq_dir" ] && [ -f "$_mdreq_dir/ready" ] && return 0
  done
  return 1
}

merv_dhcp_hold_required() {
  merv_dhcp_hold_state_root_valid || return 1
  _merv_dhcp_required_locked
}

_merv_dhcp_rules_reconcile_locked() {
  if _merv_dhcp_required_locked; then
    _merv_dhcp_hold_enforce_locked
  else
    _merv_dhcp_hold_rules_remove_locked
  fi
}

_merv_dhcp_queue_recovery_locked() {
  local _mdqr_reason="$1" _mdqr_tmp
  merv_dhcp_hold_valid_id "$_mdqr_reason" || _mdqr_reason="security-failsafe"
  _mdqr_tmp="$MERV_DHCP_HOLD_STATE_ROOT/.recovery.pending.tmp.$$"
  {
    printf 'reason=%s\n' "$_mdqr_reason"
    printf 'requested_epoch=%s\n' "$(date +%s 2>/dev/null || printf '0')"
    printf 'source=dhcp-hold-reconcile\n'
  } > "$_mdqr_tmp" 2>/dev/null || return 2
  mv "$_mdqr_tmp" "$MERV_DHCP_HOLD_STATE_ROOT/recovery.pending" 2>/dev/null || return 2
  return 0
}

_merv_dhcp_failsafe_create_locked() {
  local _mdfc_type="$1" _mdfc_run="$2" _mdfc_phase="$3" _mdfc_reason="$4" _mdfc_token="$5"
  local _mdfc_now _mdfc_id _mdfc_tmp _mdfc_dir
  _merv_dhcp_owner_type_valid "$_mdfc_type" || _mdfc_type=recovery
  merv_dhcp_hold_valid_id "$_mdfc_run" || _mdfc_run=unknown
  merv_dhcp_hold_valid_id "$_mdfc_reason" || _mdfc_reason=interrupted-owner
  _mdfc_now=$(date +%s 2>/dev/null || printf '0')
  _mdfc_id="${_mdfc_type}-${_mdfc_run}-${_mdfc_now}-$$"
  merv_dhcp_hold_valid_id "$_mdfc_id" || return 1
  _mdfc_dir="$MERV_DHCP_HOLD_STATE_ROOT/failsafe/$_mdfc_id"
  [ ! -e "$_mdfc_dir" ] || _mdfc_dir="${_mdfc_dir}-$(_merv_dhcp_nonce)"
  _mdfc_tmp="${_mdfc_dir}.pending"
  mkdir "$_mdfc_tmp" 2>/dev/null || return 2
  _merv_dhcp_atomic_field "$_mdfc_tmp" owner_type "$_mdfc_type" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" run_id "$_mdfc_run" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" phase "$_mdfc_phase" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" reason "$_mdfc_reason" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" created_epoch "$_mdfc_now" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" owner_token_reference "$_mdfc_token" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" failed_interfaces "${MERV_DHCP_FAILSAFE_FAILED_INTERFACES:-unknown}" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" expected_bridges "${MERV_DHCP_FAILSAFE_EXPECTED_BRIDGES:-unknown}" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" observed_bridges "${MERV_DHCP_FAILSAFE_OBSERVED_BRIDGES:-unknown}" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" missing_rules "${MERV_DHCP_FAILSAFE_MISSING_RULES:-unknown}" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" asus_work "${MERV_DHCP_FAILSAFE_ASUS_WORK:-unknown}" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" suggested_action "${MERV_DHCP_FAILSAFE_SUGGESTED_ACTION:-mervlan-recovery}" &&
    _merv_dhcp_atomic_field "$_mdfc_tmp" ready 1 || return 2
  mv "$_mdfc_tmp" "$_mdfc_dir" 2>/dev/null || return 2
  _merv_dhcp_queue_recovery_locked "$_mdfc_reason" || :
  return 0
}

_merv_dhcp_phase_set_locked() {
  local _mdps_token="$1" _mdps_phase="$2" _mdps_reason="${3:-}"
  _merv_dhcp_owner_is_caller_locked "$_mdps_token" || return 1
  _merv_dhcp_atomic_field "$_MERV_DHCP_OWNER_DIR" phase "$_mdps_phase" || return 2
  [ -z "$_mdps_reason" ] || _merv_dhcp_atomic_field "$_MERV_DHCP_OWNER_DIR" reason "$_mdps_reason" || return 2
  _merv_dhcp_atomic_field "$_MERV_DHCP_OWNER_DIR" heartbeat_epoch "$(date +%s 2>/dev/null || printf '0')" || return 2
  return 0
}

_merv_dhcp_acquire_abort_locked() {
  local _mdaa_token="$1" _mdaa_pending="$2"
  [ -z "$_mdaa_pending" ] || _merv_dhcp_pending_remove_locked "$_mdaa_pending" || :
  _merv_dhcp_record_remove_locked owners "$_mdaa_token" || :
  _merv_dhcp_record_remove_locked intents "$_mdaa_token" || :
  _merv_dhcp_rules_reconcile_locked || :
  return 0
}

merv_dhcp_hold_acquire() {
  local _mdac_type="$1" _mdac_run="${2:-}" _mdac_parent="${3:-}"
  local _mdac_now _mdac_proc _mdac_start _mdac_token _mdac_intent
  local _mdac_pending="" _mdac_owner _mdac_nonce _mdac_rc
  _merv_dhcp_owner_type_valid "$_mdac_type" || return 1
  _mdac_now=$(date +%s 2>/dev/null || printf '0')
  [ -n "$_mdac_run" ] || _mdac_run="${_mdac_type}-${_mdac_now}-$$"
  merv_dhcp_hold_valid_id "$_mdac_run" || return 1
  [ -z "$_mdac_parent" ] || merv_dhcp_hold_valid_id "$_mdac_parent" || return 1
  _mdac_proc=$(merv_dhcp_proc_root) || return 1
  _mdac_start=$(merv_proc_start_time "$$" "$_mdac_proc" 2>/dev/null) || return 1
  _mdac_token="${_mdac_type}.${_mdac_run}.${_mdac_now}.$$.$_mdac_start.$(_merv_dhcp_nonce)"
  merv_dhcp_hold_valid_id "$_mdac_token" || return 1

  merv_dhcp_state_lock_acquire || return 2
  _mdac_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _mdac_intent="$MERV_DHCP_HOLD_STATE_ROOT/intents/$_mdac_token"
  mkdir "$_mdac_intent" 2>/dev/null || { merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2; return 2; }
  _merv_dhcp_atomic_field "$_mdac_intent" owner_type "$_mdac_type" &&
    _merv_dhcp_atomic_field "$_mdac_intent" run_id "$_mdac_run" &&
    _merv_dhcp_atomic_field "$_mdac_intent" pid "$$" &&
    _merv_dhcp_atomic_field "$_mdac_intent" proc_start_time "$_mdac_start" &&
    _merv_dhcp_atomic_field "$_mdac_intent" created_epoch "$_mdac_now" &&
    _merv_dhcp_atomic_field "$_mdac_intent" phase intent &&
    _merv_dhcp_atomic_field "$_mdac_intent" reason acquisition || {
      _merv_dhcp_acquire_abort_locked "$_mdac_token" ""
      merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
      return 2
    }
  [ -z "$_mdac_parent" ] || _merv_dhcp_atomic_field "$_mdac_intent" parent_run_id "$_mdac_parent" || {
    _merv_dhcp_acquire_abort_locked "$_mdac_token" ""
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 2
  }
  if ! merv_dhcp_hold_fault_checkpoint acquire-intent-published; then
    _merv_dhcp_acquire_abort_locked "$_mdac_token" ""
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 4
  fi

  _merv_dhcp_hold_enforce_locked || {
    _mdac_rc=$?
    merv_dhcp_hold_record_fault acquire-enforcement-failed hold unavailable >/dev/null 2>&1 || :
    _merv_dhcp_acquire_abort_locked "$_mdac_token" ""
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return "$_mdac_rc"
  }
  if ! merv_dhcp_hold_fault_checkpoint acquire-rules-enforced; then
    _merv_dhcp_acquire_abort_locked "$_mdac_token" ""
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 4
  fi

  _mdac_pending="$MERV_DHCP_HOLD_STATE_ROOT/owners/.${_mdac_token}.pending.$$"
  _mdac_owner="$MERV_DHCP_HOLD_STATE_ROOT/owners/$_mdac_token"
  mkdir "$_mdac_pending" 2>/dev/null || {
    _merv_dhcp_acquire_abort_locked "$_mdac_token" ""
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 2
  }
  _merv_dhcp_atomic_field "$_mdac_pending" owner_type "$_mdac_type" &&
    _merv_dhcp_atomic_field "$_mdac_pending" run_id "$_mdac_run" &&
    _merv_dhcp_atomic_field "$_mdac_pending" pid "$$" &&
    _merv_dhcp_atomic_field "$_mdac_pending" proc_start_time "$_mdac_start" &&
    _merv_dhcp_atomic_field "$_mdac_pending" created_epoch "$_mdac_now" &&
    _merv_dhcp_atomic_field "$_mdac_pending" phase protected &&
    _merv_dhcp_atomic_field "$_mdac_pending" reason acquisition-complete || {
      _merv_dhcp_acquire_abort_locked "$_mdac_token" "$_mdac_pending"
      merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
      return 2
    }
  [ -z "$_mdac_parent" ] || _merv_dhcp_atomic_field "$_mdac_pending" parent_run_id "$_mdac_parent" || {
    _merv_dhcp_acquire_abort_locked "$_mdac_token" "$_mdac_pending"
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 2
  }
  if ! merv_dhcp_hold_fault_checkpoint acquire-owner-staged; then
    _merv_dhcp_acquire_abort_locked "$_mdac_token" "$_mdac_pending"
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 4
  fi
  _merv_dhcp_atomic_field "$_mdac_pending" ready 1 || {
    _merv_dhcp_acquire_abort_locked "$_mdac_token" "$_mdac_pending"
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 2
  }
  mv "$_mdac_pending" "$_mdac_owner" 2>/dev/null || {
    _merv_dhcp_acquire_abort_locked "$_mdac_token" "$_mdac_pending"
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 2
  }
  _mdac_pending=""
  if ! merv_dhcp_hold_fault_checkpoint acquire-owner-published; then
    _merv_dhcp_acquire_abort_locked "$_mdac_token" ""
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 4
  fi
  _merv_dhcp_record_remove_locked intents "$_mdac_token" || {
    _merv_dhcp_acquire_abort_locked "$_mdac_token" ""
    merv_dhcp_state_lock_release_or_report "$_mdac_nonce" || return 2
    return 2
  }
  merv_dhcp_state_lock_release "$_mdac_nonce" || return 2
  MERV_DHCP_HOLD_TOKEN="$_mdac_token"
  _merv_dhcp_log info "owner acquired type=$_mdac_type run=$_mdac_run token=$(_merv_dhcp_short_token "$_mdac_token")"
  return 0
}

merv_dhcp_hold_mark_mutating() {
  local _mdmm_token="$1" _mdmm_reason="${2:-mutation}" _mdmm_nonce
  merv_dhcp_hold_valid_id "$_mdmm_reason" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdmm_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_owner_is_caller_locked "$_mdmm_token" || { merv_dhcp_state_lock_release_or_report "$_mdmm_nonce" || return 2; return 1; }
  case "$_MERV_DHCP_OWNER_PHASE" in
    protected) _merv_dhcp_phase_set_locked "$_mdmm_token" mutating "$_mdmm_reason" || { merv_dhcp_state_lock_release_or_report "$_mdmm_nonce" || return 2; return 2; } ;;
    mutating) ;;
    *) merv_dhcp_state_lock_release_or_report "$_mdmm_nonce" || return 2; return 1 ;;
  esac
  if ! merv_dhcp_hold_fault_checkpoint mutate-phase-published; then
    merv_dhcp_state_lock_release_or_report "$_mdmm_nonce" || return 2
    return 4
  fi
  merv_dhcp_state_lock_release "$_mdmm_nonce" || return 2
  _merv_dhcp_log info "mutation begun token=$(_merv_dhcp_short_token "$_mdmm_token") reason=$_mdmm_reason"
  return 0
}

merv_dhcp_hold_mark_handoff_wait() {
  local _mdhw_token="$1" _mdhw_handoff="$2" _mdhw_nonce
  merv_dhcp_hold_valid_id "$_mdhw_handoff" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdhw_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_owner_is_caller_locked "$_mdhw_token" || { merv_dhcp_state_lock_release_or_report "$_mdhw_nonce" || return 2; return 1; }
  case "$_MERV_DHCP_OWNER_PHASE" in
    protected|mutating) ;;
    *) merv_dhcp_state_lock_release_or_report "$_mdhw_nonce" || return 2; return 1 ;;
  esac
  _merv_dhcp_phase_set_locked "$_mdhw_token" handoff_wait handoff-requested &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_OWNER_DIR" handoff_id "$_mdhw_handoff" || {
      merv_dhcp_state_lock_release_or_report "$_mdhw_nonce" || return 2
      return 2
    }
  merv_dhcp_state_lock_release "$_mdhw_nonce" || return 2
  return 0
}

_merv_dhcp_handoff_load_locked() {
  local _mdhl_id="$1" _mdhl_dir
  merv_dhcp_hold_valid_id "$_mdhl_id" || return 1
  _mdhl_dir="$MERV_DHCP_HOLD_STATE_ROOT/handoffs/$_mdhl_id"
  [ -d "$_mdhl_dir" ] && [ -f "$_mdhl_dir/ready" ] || return 1
  _MERV_DHCP_HANDOFF_DIR="$_mdhl_dir"
  _MERV_DHCP_HANDOFF_PARENT_TYPE=$(cat "$_mdhl_dir/parent_owner_type" 2>/dev/null || printf '')
  _MERV_DHCP_HANDOFF_PARENT_RUN=$(cat "$_mdhl_dir/parent_run_id" 2>/dev/null || printf '')
  _MERV_DHCP_HANDOFF_PARENT_TOKEN=$(cat "$_mdhl_dir/parent_token_reference" 2>/dev/null || printf '')
  _MERV_DHCP_HANDOFF_CHILD_TYPE=$(cat "$_mdhl_dir/child_owner_type" 2>/dev/null || printf '')
  _MERV_DHCP_HANDOFF_STATE=$(cat "$_mdhl_dir/handoff_state" 2>/dev/null || printf '')
  _merv_dhcp_owner_type_valid "$_MERV_DHCP_HANDOFF_PARENT_TYPE" || return 1
  _merv_dhcp_owner_type_valid "$_MERV_DHCP_HANDOFF_CHILD_TYPE" || return 1
  merv_dhcp_hold_valid_id "$_MERV_DHCP_HANDOFF_PARENT_RUN" || return 1
  merv_dhcp_hold_valid_id "$_MERV_DHCP_HANDOFF_PARENT_TOKEN" || return 1
  case "$_MERV_DHCP_HANDOFF_STATE" in requested|acknowledged|completed|failed) ;; *) return 1 ;; esac
  return 0
}

_merv_dhcp_handoff_ack_valid_locked() {
  local _mdhav_id="$1" _mdhav_child_dir _mdhav_parent_dir
  _merv_dhcp_handoff_load_locked "$_mdhav_id" || return 1
  case "$_MERV_DHCP_HANDOFF_STATE" in acknowledged|completed) ;; *) return 1 ;; esac
  _MERV_DHCP_HANDOFF_ACK_RUN=$(cat "$_MERV_DHCP_HANDOFF_DIR/ack_child_run_id" 2>/dev/null || printf '')
  _MERV_DHCP_HANDOFF_ACK_TOKEN=$(cat "$_MERV_DHCP_HANDOFF_DIR/ack_child_token_reference" 2>/dev/null || printf '')
  merv_dhcp_hold_valid_id "$_MERV_DHCP_HANDOFF_ACK_RUN" || return 1
  merv_dhcp_hold_valid_id "$_MERV_DHCP_HANDOFF_ACK_TOKEN" || return 1
  _mdhav_parent_dir="$MERV_DHCP_HOLD_STATE_ROOT/owners/$_MERV_DHCP_HANDOFF_PARENT_TOKEN"
  if [ -d "$_mdhav_parent_dir" ] && [ -f "$_mdhav_parent_dir/ready" ]; then
    [ "$(cat "$_mdhav_parent_dir/run_id" 2>/dev/null)" = "$_MERV_DHCP_HANDOFF_PARENT_RUN" ] || return 1
    [ "$(cat "$_mdhav_parent_dir/handoff_id" 2>/dev/null)" = "$_mdhav_id" ] || return 1
    [ "$(cat "$_mdhav_parent_dir/phase" 2>/dev/null)" = handoff_wait ] || return 1
  else
    [ -n "$(cat "$_MERV_DHCP_HANDOFF_DIR/parent_retired_epoch" 2>/dev/null)" ] || return 1
  fi
  _mdhav_child_dir="$MERV_DHCP_HOLD_STATE_ROOT/owners/$_MERV_DHCP_HANDOFF_ACK_TOKEN"
  if [ -d "$_mdhav_child_dir" ] && [ -f "$_mdhav_child_dir/ready" ]; then
    [ "$(cat "$_mdhav_child_dir/owner_type" 2>/dev/null)" = "$_MERV_DHCP_HANDOFF_CHILD_TYPE" ] || return 1
    [ "$(cat "$_mdhav_child_dir/run_id" 2>/dev/null)" = "$_MERV_DHCP_HANDOFF_ACK_RUN" ] || return 1
    [ "$(cat "$_mdhav_child_dir/parent_run_id" 2>/dev/null)" = "$_MERV_DHCP_HANDOFF_PARENT_RUN" ] || return 1
    [ "$(cat "$_mdhav_child_dir/handoff_id" 2>/dev/null)" = "$_mdhav_id" ] || return 1
    return 0
  fi
  [ "$_MERV_DHCP_HANDOFF_STATE" = completed ] &&
    [ -n "$(cat "$_MERV_DHCP_HANDOFF_DIR/verification_id" 2>/dev/null)" ]
}

merv_dhcp_handoff_request() {
  local _mdhr_token="$1" _mdhr_child="$2" _mdhr_id="${3:-}"
  local _mdhr_now _mdhr_nonce _mdhr_tmp _mdhr_dir
  _merv_dhcp_owner_type_valid "$_mdhr_child" || return 1
  _mdhr_now=$(date +%s 2>/dev/null || printf '0')
  [ -n "$_mdhr_id" ] || _mdhr_id="handoff-${_mdhr_now}-$$-$(_merv_dhcp_nonce)"
  merv_dhcp_hold_valid_id "$_mdhr_id" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdhr_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_owner_is_caller_locked "$_mdhr_token" || {
    merv_dhcp_state_lock_release_or_report "$_mdhr_nonce" || return 2
    return 1
  }
  case "$_MERV_DHCP_OWNER_PHASE" in protected|mutating) ;; *)
    merv_dhcp_state_lock_release_or_report "$_mdhr_nonce" || return 2
    return 1
  esac
  _mdhr_dir="$MERV_DHCP_HOLD_STATE_ROOT/handoffs/$_mdhr_id"
  [ ! -e "$_mdhr_dir" ] || {
    merv_dhcp_state_lock_release_or_report "$_mdhr_nonce" || return 2
    return 1
  }
  _mdhr_tmp="${_mdhr_dir}.pending.$$"
  mkdir "$_mdhr_tmp" 2>/dev/null || {
    merv_dhcp_state_lock_release_or_report "$_mdhr_nonce" || return 2
    return 2
  }
  _merv_dhcp_atomic_field "$_mdhr_tmp" handoff_id "$_mdhr_id" &&
    _merv_dhcp_atomic_field "$_mdhr_tmp" parent_owner_type "$_MERV_DHCP_OWNER_TYPE" &&
    _merv_dhcp_atomic_field "$_mdhr_tmp" parent_run_id "$_MERV_DHCP_OWNER_RUN_ID" &&
    _merv_dhcp_atomic_field "$_mdhr_tmp" parent_token_reference "$_mdhr_token" &&
    _merv_dhcp_atomic_field "$_mdhr_tmp" child_owner_type "$_mdhr_child" &&
    _merv_dhcp_atomic_field "$_mdhr_tmp" requested_epoch "$_mdhr_now" &&
    _merv_dhcp_atomic_field "$_mdhr_tmp" handoff_state requested &&
    _merv_dhcp_atomic_field "$_mdhr_tmp" ready 1 &&
    mv "$_mdhr_tmp" "$_mdhr_dir" 2>/dev/null || {
      rm -f "$_mdhr_tmp/"* 2>/dev/null || :
      rmdir "$_mdhr_tmp" 2>/dev/null || :
      merv_dhcp_state_lock_release_or_report "$_mdhr_nonce" || return 2
      return 2
    }
  merv_dhcp_state_lock_release "$_mdhr_nonce" || return 2
  MERV_DHCP_HANDOFF_ID="$_mdhr_id"
  _merv_dhcp_log info "handoff requested id=$_mdhr_id parent=$_MERV_DHCP_OWNER_RUN_ID child=$_mdhr_child"
  return 0
}

merv_dhcp_handoff_ack() {
  local _mdha_id="$1" _mdha_parent_run="$2" _mdha_child_token="$3"
  local _mdha_nonce _mdha_now
  merv_dhcp_hold_valid_id "$_mdha_parent_run" || {
    _merv_dhcp_log error "handoff ack rejected: invalid parent run id=$_mdha_id"
    return 1
  }
  merv_dhcp_state_lock_acquire || {
    _merv_dhcp_log error "handoff ack failed: state lock unavailable id=$_mdha_id"
    return 2
  }
  _mdha_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_handoff_load_locked "$_mdha_id" || {
    _merv_dhcp_log error "handoff ack rejected: record missing/invalid id=$_mdha_id"
    merv_dhcp_state_lock_release_or_report "$_mdha_nonce" || return 2
    return 1
  }
  [ "$_MERV_DHCP_HANDOFF_STATE" = requested ] &&
    [ "$_MERV_DHCP_HANDOFF_PARENT_RUN" = "$_mdha_parent_run" ] || {
      _merv_dhcp_log error "handoff ack rejected: state/parent mismatch id=$_mdha_id state=$_MERV_DHCP_HANDOFF_STATE"
      merv_dhcp_state_lock_release_or_report "$_mdha_nonce" || return 2
      return 1
    }
  _merv_dhcp_owner_is_caller_locked "$_mdha_child_token" || {
    _merv_dhcp_log error "handoff ack rejected: child owner identity mismatch id=$_mdha_id"
    merv_dhcp_state_lock_release_or_report "$_mdha_nonce" || return 2
    return 1
  }
  [ "$_MERV_DHCP_OWNER_TYPE" = "$_MERV_DHCP_HANDOFF_CHILD_TYPE" ] &&
    [ "$(cat "$_MERV_DHCP_OWNER_DIR/parent_run_id" 2>/dev/null)" = "$_mdha_parent_run" ] || {
      _merv_dhcp_log error "handoff ack rejected: child type/parent mismatch id=$_mdha_id"
      merv_dhcp_state_lock_release_or_report "$_mdha_nonce" || return 2
      return 1
    }
  _mdha_now=$(date +%s 2>/dev/null || printf '0')
  _merv_dhcp_atomic_field "$_MERV_DHCP_OWNER_DIR" handoff_id "$_mdha_id" &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" ack_child_run_id "$_MERV_DHCP_OWNER_RUN_ID" &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" ack_child_token_reference "$_mdha_child_token" &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" ack_epoch "$_mdha_now" &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" handoff_state acknowledged || {
      _merv_dhcp_log error "handoff ack failed: atomic publication error id=$_mdha_id"
      merv_dhcp_state_lock_release_or_report "$_mdha_nonce" || return 2
      return 2
    }
  merv_dhcp_state_lock_release "$_mdha_nonce" || return 2
  _merv_dhcp_log info "handoff acknowledged id=$_mdha_id child=$_MERV_DHCP_OWNER_RUN_ID"
  return 0
}

merv_dhcp_handoff_is_acknowledged() {
  local _mdhia_id="$1" _mdhia_parent="$2" _mdhia_child="${3:-}" _mdhia_nonce _mdhia_rc=1
  merv_dhcp_hold_valid_id "$_mdhia_parent" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdhia_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  if _merv_dhcp_handoff_ack_valid_locked "$_mdhia_id" &&
     [ "$_MERV_DHCP_HANDOFF_PARENT_RUN" = "$_mdhia_parent" ]; then
    [ -z "$_mdhia_child" ] || [ "$_MERV_DHCP_HANDOFF_ACK_RUN" = "$_mdhia_child" ]
    _mdhia_rc=$?
  fi
  merv_dhcp_state_lock_release "$_mdhia_nonce" || return 2
  return "$_mdhia_rc"
}

merv_dhcp_handoff_wait_ack() {
  local _mdhwa_id="$1" _mdhwa_parent="$2" _mdhwa_max="${3:-10}" _mdhwa_elapsed=0
  case "$_mdhwa_max" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$_mdhwa_elapsed" -le "$_mdhwa_max" ]; do
    merv_dhcp_handoff_is_acknowledged "$_mdhwa_id" "$_mdhwa_parent" && return 0
    [ "$_mdhwa_elapsed" -eq "$_mdhwa_max" ] && break
    sleep 1
    _mdhwa_elapsed=$((_mdhwa_elapsed + 1))
  done
  return 1
}

merv_dhcp_handoff_fail() {
  local _mdhf_id="$1" _mdhf_parent_token="$2" _mdhf_reason="$3"
  local _mdhf_nonce _mdhf_now
  merv_dhcp_hold_valid_id "$_mdhf_id" || return 1
  merv_dhcp_hold_valid_id "$_mdhf_reason" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdhf_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_handoff_load_locked "$_mdhf_id" || {
    merv_dhcp_state_lock_release_or_report "$_mdhf_nonce" || return 2
    return 1
  }
  case "$_MERV_DHCP_HANDOFF_STATE" in requested|acknowledged) ;; *)
    merv_dhcp_state_lock_release_or_report "$_mdhf_nonce" || return 2
    return 1
  esac
  _merv_dhcp_owner_is_caller_locked "$_mdhf_parent_token" || {
    merv_dhcp_state_lock_release_or_report "$_mdhf_nonce" || return 2
    return 1
  }
  [ "$_MERV_DHCP_OWNER_RUN_ID" = "$_MERV_DHCP_HANDOFF_PARENT_RUN" ] &&
    [ "$_MERV_DHCP_HANDOFF_PARENT_TOKEN" = "$_mdhf_parent_token" ] &&
    [ "$_MERV_DHCP_OWNER_PHASE" = handoff_wait ] &&
    [ "$(cat "$_MERV_DHCP_OWNER_DIR/handoff_id" 2>/dev/null)" = "$_mdhf_id" ] || {
      merv_dhcp_state_lock_release_or_report "$_mdhf_nonce" || return 2
      return 1
    }
  _mdhf_now=$(date +%s 2>/dev/null || printf '0')
  _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" failed_epoch "$_mdhf_now" &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" failure_reason "$_mdhf_reason" &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" handoff_state failed &&
    _merv_dhcp_queue_recovery_locked handoff-failed || {
      merv_dhcp_state_lock_release_or_report "$_mdhf_nonce" || return 2
      return 2
    }
  merv_dhcp_state_lock_release "$_mdhf_nonce" || return 2
  _merv_dhcp_log error "handoff failed id=$_mdhf_id reason=$_mdhf_reason"
  return 0
}

merv_dhcp_handoff_parent_release() {
  local _mdhpr_token="$1" _mdhpr_id="$2" _mdhpr_nonce _mdhpr_now _mdhpr_rc
  merv_dhcp_state_lock_acquire || return 2
  _mdhpr_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_owner_is_caller_locked "$_mdhpr_token" || {
    merv_dhcp_state_lock_release_or_report "$_mdhpr_nonce" || return 2
    return 1
  }
  [ "$_MERV_DHCP_OWNER_PHASE" = handoff_wait ] &&
    [ "$(cat "$_MERV_DHCP_OWNER_DIR/handoff_id" 2>/dev/null)" = "$_mdhpr_id" ] &&
    _merv_dhcp_handoff_ack_valid_locked "$_mdhpr_id" || {
      merv_dhcp_state_lock_release_or_report "$_mdhpr_nonce" || return 2
      return 1
    }
  [ "$_MERV_DHCP_HANDOFF_PARENT_TOKEN" = "$_mdhpr_token" ] || {
    merv_dhcp_state_lock_release_or_report "$_mdhpr_nonce" || return 2
    return 1
  }
  if [ "$_MERV_DHCP_HANDOFF_PARENT_TYPE" = boot-watchdog ] &&
     [ "$_MERV_DHCP_HANDOFF_STATE" != completed ]; then
    merv_dhcp_state_lock_release_or_report "$_mdhpr_nonce" || return 2
    return 5
  fi
  _merv_dhcp_record_remove_locked owners "$_mdhpr_token" || {
    merv_dhcp_state_lock_release_or_report "$_mdhpr_nonce" || return 2
    return 2
  }
  _mdhpr_now=$(date +%s 2>/dev/null || printf '0')
  _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" parent_retired_epoch "$_mdhpr_now" || :
  _merv_dhcp_rules_reconcile_locked
  _mdhpr_rc=$?
  merv_dhcp_state_lock_release "$_mdhpr_nonce" || return 2
  [ "$_mdhpr_rc" -eq 0 ] && _merv_dhcp_log info "handoff parent retired id=$_mdhpr_id"
  return "$_mdhpr_rc"
}

merv_dhcp_handoff_child_verified() {
  local _mdhcv_id="$1" _mdhcv_token="$2" _mdhcv_verification="$3"
  local _mdhcv_nonce _mdhcv_now
  merv_dhcp_hold_valid_id "$_mdhcv_verification" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdhcv_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_handoff_ack_valid_locked "$_mdhcv_id" || {
    merv_dhcp_state_lock_release_or_report "$_mdhcv_nonce" || return 2
    return 1
  }
  [ "$_MERV_DHCP_HANDOFF_ACK_TOKEN" = "$_mdhcv_token" ] || {
    merv_dhcp_state_lock_release_or_report "$_mdhcv_nonce" || return 2
    return 1
  }
  _merv_dhcp_owner_is_caller_locked "$_mdhcv_token" || {
    merv_dhcp_state_lock_release_or_report "$_mdhcv_nonce" || return 2
    return 1
  }
  [ "$_MERV_DHCP_OWNER_PHASE" = verified ] || {
    merv_dhcp_state_lock_release_or_report "$_mdhcv_nonce" || return 2
    return 1
  }
  _mdhcv_now=$(date +%s 2>/dev/null || printf '0')
  _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" verification_id "$_mdhcv_verification" &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" completed_epoch "$_mdhcv_now" &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_HANDOFF_DIR" handoff_state completed || {
      merv_dhcp_state_lock_release_or_report "$_mdhcv_nonce" || return 2
      return 2
    }
  merv_dhcp_state_lock_release "$_mdhcv_nonce" || return 2
  _merv_dhcp_log info "handoff completed id=$_mdhcv_id verification=$_mdhcv_verification"
  return 0
}

merv_dhcp_handoff_coalesce() {
  local _mdhc_parent="$1" _mdhc_child="$2" _mdhc_reason="${3:-duplicate-event}"
  local _mdhc_nonce _mdhc_dir _mdhc_state _mdhc_tmp _mdhc_found=1
  _merv_dhcp_owner_type_valid "$_mdhc_parent" || return 1
  _merv_dhcp_owner_type_valid "$_mdhc_child" || return 1
  merv_dhcp_hold_valid_id "$_mdhc_reason" || _mdhc_reason=duplicate-event
  merv_dhcp_state_lock_acquire || return 2
  _mdhc_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  for _mdhc_dir in "$MERV_DHCP_HOLD_STATE_ROOT/handoffs/"*; do
    [ -d "$_mdhc_dir" ] && [ -f "$_mdhc_dir/ready" ] || continue
    [ "$(cat "$_mdhc_dir/parent_owner_type" 2>/dev/null)" = "$_mdhc_parent" ] || continue
    [ "$(cat "$_mdhc_dir/child_owner_type" 2>/dev/null)" = "$_mdhc_child" ] || continue
    _mdhc_state=$(cat "$_mdhc_dir/handoff_state" 2>/dev/null || printf '')
    case "$_mdhc_state" in requested|acknowledged) _mdhc_found=0; break ;; esac
  done
  _mdhc_tmp="$MERV_DHCP_HOLD_STATE_ROOT/.${_mdhc_parent}.pending.tmp.$$"
  {
    printf 'reason=%s\n' "$_mdhc_reason"
    printf 'requested_epoch=%s\n' "$(date +%s 2>/dev/null || printf '0')"
    [ "$_mdhc_found" -ne 0 ] || printf 'attached_handoff=%s\n' "${_mdhc_dir##*/}"
  } > "$_mdhc_tmp" 2>/dev/null &&
    mv "$_mdhc_tmp" "$MERV_DHCP_HOLD_STATE_ROOT/${_mdhc_parent}.pending" 2>/dev/null || :
  merv_dhcp_state_lock_release "$_mdhc_nonce" || return 2
  return "$_mdhc_found"
}

merv_dhcp_hold_mark_verified() {
  local _mdmv_token="$1" _mdmv_verification="$2" _mdmv_nonce
  merv_dhcp_hold_valid_id "$_mdmv_verification" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdmv_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_owner_is_caller_locked "$_mdmv_token" || { merv_dhcp_state_lock_release_or_report "$_mdmv_nonce" || return 2; return 1; }
  case "$_MERV_DHCP_OWNER_PHASE" in mutating|protected) ;; *) merv_dhcp_state_lock_release_or_report "$_mdmv_nonce" || return 2; return 1 ;; esac
  _merv_dhcp_phase_set_locked "$_mdmv_token" verified final-verification &&
    _merv_dhcp_atomic_field "$_MERV_DHCP_OWNER_DIR" verification_id "$_mdmv_verification" || {
      merv_dhcp_state_lock_release_or_report "$_mdmv_nonce" || return 2
      return 2
    }
  if ! merv_dhcp_hold_fault_checkpoint verify-phase-published; then
    merv_dhcp_state_lock_release_or_report "$_mdmv_nonce" || return 2
    return 4
  fi
  merv_dhcp_state_lock_release "$_mdmv_nonce" || return 2
  _merv_dhcp_log info "final verification passed token=$(_merv_dhcp_short_token "$_mdmv_token") verification=$_mdmv_verification"
  return 0
}

_merv_dhcp_token_release() {
  local _mdtr_token="$1" _mdtr_nonce _mdtr_rc
  merv_dhcp_state_lock_acquire || return 2
  _mdtr_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_owner_is_caller_locked "$_mdtr_token" || { merv_dhcp_state_lock_release_or_report "$_mdtr_nonce" || return 2; return 1; }
  case "$_MERV_DHCP_OWNER_PHASE" in protected|verified) ;; *) merv_dhcp_state_lock_release_or_report "$_mdtr_nonce" || return 2; return 5 ;; esac
  _merv_dhcp_record_remove_locked owners "$_mdtr_token" || { merv_dhcp_state_lock_release_or_report "$_mdtr_nonce" || return 2; return 2; }
  if ! merv_dhcp_hold_fault_checkpoint release-owner-removed; then
    merv_dhcp_state_lock_release_or_report "$_mdtr_nonce" || return 2
    return 4
  fi
  _merv_dhcp_rules_reconcile_locked
  _mdtr_rc=$?
  merv_dhcp_state_lock_release "$_mdtr_nonce" || return 2
  [ "$_mdtr_rc" -eq 0 ] && _merv_dhcp_log info "own lease released token=$(_merv_dhcp_short_token "$_mdtr_token")"
  return "$_mdtr_rc"
}

merv_dhcp_hold_abandon() {
  local _mdab_token="$1" _mdab_reason="$2" _mdab_nonce _mdab_rc
  merv_dhcp_hold_valid_id "$_mdab_reason" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdab_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  if ! _merv_dhcp_owner_is_caller_locked "$_mdab_token"; then
    merv_dhcp_hold_record_fault abandon-identity-mismatch hold untouched >/dev/null 2>&1 || :
    _merv_dhcp_queue_recovery_locked abandon-identity-mismatch || :
    merv_dhcp_state_lock_release_or_report "$_mdab_nonce" || return 2
    return 1
  fi
  case "$_MERV_DHCP_OWNER_PHASE" in
    protected|verified)
      _merv_dhcp_record_remove_locked owners "$_mdab_token" || { merv_dhcp_state_lock_release_or_report "$_mdab_nonce" || return 2; return 2; }
      ;;
    mutating|handoff_wait)
      _merv_dhcp_failsafe_create_locked "$_MERV_DHCP_OWNER_TYPE" "$_MERV_DHCP_OWNER_RUN_ID" \
        "$_MERV_DHCP_OWNER_PHASE" "$_mdab_reason" "$_mdab_token" || {
        merv_dhcp_state_lock_release_or_report "$_mdab_nonce" || return 2
        return 2
      }
      _merv_dhcp_record_remove_locked owners "$_mdab_token" || { merv_dhcp_state_lock_release_or_report "$_mdab_nonce" || return 2; return 2; }
      _merv_dhcp_log error "lease converted to failsafe token=$(_merv_dhcp_short_token "$_mdab_token") reason=$_mdab_reason"
      ;;
    *) merv_dhcp_state_lock_release_or_report "$_mdab_nonce" || return 2; return 1 ;;
  esac
  _merv_dhcp_rules_reconcile_locked
  _mdab_rc=$?
  merv_dhcp_state_lock_release "$_mdab_nonce" || return 2
  return "$_mdab_rc"
}

_merv_dhcp_reconcile_records_locked() {
  local _mdrec_dir _mdrec_id _mdrec_pid _mdrec_start _mdrec_phase
  local _mdrec_type _mdrec_run _mdrec_proc
  _mdrec_proc=$(merv_dhcp_proc_root) || return 1

  for _mdrec_dir in "$MERV_DHCP_HOLD_STATE_ROOT/intents/"*; do
    [ -d "$_mdrec_dir" ] || continue
    _mdrec_id=${_mdrec_dir##*/}
    merv_dhcp_hold_valid_id "$_mdrec_id" || continue
    _mdrec_pid=$(cat "$_mdrec_dir/pid" 2>/dev/null || printf '')
    _mdrec_start=$(cat "$_mdrec_dir/proc_start_time" 2>/dev/null || printf '')
    if ! merv_process_identity_matches "$_mdrec_pid" "$_mdrec_start" "$_mdrec_proc" 2>/dev/null; then
      _merv_dhcp_record_remove_locked intents "$_mdrec_id" || :
    fi
  done

  for _mdrec_dir in "$MERV_DHCP_HOLD_STATE_ROOT/owners/".*.pending.*; do
    [ -d "$_mdrec_dir" ] || continue
    _mdrec_pid=$(cat "$_mdrec_dir/pid" 2>/dev/null || printf '')
    _mdrec_start=$(cat "$_mdrec_dir/proc_start_time" 2>/dev/null || printf '')
    if ! merv_process_identity_matches "$_mdrec_pid" "$_mdrec_start" "$_mdrec_proc" 2>/dev/null; then
      _merv_dhcp_pending_remove_locked "$_mdrec_dir" || :
    fi
  done

  for _mdrec_dir in "$MERV_DHCP_HOLD_STATE_ROOT/owners/"*; do
    [ -d "$_mdrec_dir" ] || continue
    _mdrec_id=${_mdrec_dir##*/}
    case "$_mdrec_id" in .*) continue ;; esac
    if ! merv_dhcp_hold_valid_id "$_mdrec_id" || [ ! -f "$_mdrec_dir/ready" ]; then
      merv_dhcp_hold_record_fault invalid-owner-record hold retained >/dev/null 2>&1 || :
      continue
    fi
    _mdrec_pid=$(cat "$_mdrec_dir/pid" 2>/dev/null || printf '')
    _mdrec_start=$(cat "$_mdrec_dir/proc_start_time" 2>/dev/null || printf '')
    merv_process_identity_matches "$_mdrec_pid" "$_mdrec_start" "$_mdrec_proc" 2>/dev/null && continue
    _mdrec_phase=$(cat "$_mdrec_dir/phase" 2>/dev/null || printf '')
    _mdrec_type=$(cat "$_mdrec_dir/owner_type" 2>/dev/null || printf '')
    _mdrec_run=$(cat "$_mdrec_dir/run_id" 2>/dev/null || printf '')
    case "$_mdrec_phase" in
      protected|verified)
        _merv_dhcp_record_remove_locked owners "$_mdrec_id" || :
        ;;
      mutating|handoff_wait)
        _merv_dhcp_failsafe_create_locked "$_mdrec_type" "$_mdrec_run" "$_mdrec_phase" \
          interrupted-owner "$_mdrec_id" || :
        _merv_dhcp_record_remove_locked owners "$_mdrec_id" || :
        ;;
      *)
        merv_dhcp_hold_record_fault invalid-owner-phase hold retained >/dev/null 2>&1 || :
        ;;
    esac
  done
  return 0
}

_merv_dhcp_reconcile_handoffs_locked() {
  local _mdrh_dir _mdrh_id _mdrh_state _mdrh_parent_type _mdrh_parent_token
  local _mdrh_parent_dir _mdrh_child_dir _mdrh_pid _mdrh_start _mdrh_proc _mdrh_now
  _mdrh_proc=$(merv_dhcp_proc_root) || return 1
  for _mdrh_dir in "$MERV_DHCP_HOLD_STATE_ROOT/handoffs/"*; do
    [ -d "$_mdrh_dir" ] && [ -f "$_mdrh_dir/ready" ] || continue
    _mdrh_id=${_mdrh_dir##*/}
    if ! _merv_dhcp_handoff_load_locked "$_mdrh_id"; then
      merv_dhcp_hold_record_fault invalid-handoff-record hold retained >/dev/null 2>&1 || :
      continue
    fi
    _mdrh_state="$_MERV_DHCP_HANDOFF_STATE"
    case "$_mdrh_state" in
      requested)
        _mdrh_parent_dir="$MERV_DHCP_HOLD_STATE_ROOT/owners/$_MERV_DHCP_HANDOFF_PARENT_TOKEN"
        _mdrh_pid=$(cat "$_mdrh_parent_dir/pid" 2>/dev/null || printf '')
        _mdrh_start=$(cat "$_mdrh_parent_dir/proc_start_time" 2>/dev/null || printf '')
        if [ -f "$_mdrh_parent_dir/ready" ] &&
           [ "$(cat "$_mdrh_parent_dir/run_id" 2>/dev/null)" = "$_MERV_DHCP_HANDOFF_PARENT_RUN" ] &&
           [ "$(cat "$_mdrh_parent_dir/handoff_id" 2>/dev/null)" = "$_mdrh_id" ] &&
           merv_process_identity_matches "$_mdrh_pid" "$_mdrh_start" "$_mdrh_proc" 2>/dev/null; then
          continue
        fi
        _mdrh_now=$(date +%s 2>/dev/null || printf '0')
        _merv_dhcp_atomic_field "$_mdrh_dir" failed_epoch "$_mdrh_now" &&
          _merv_dhcp_atomic_field "$_mdrh_dir" failure_reason orphaned-parent &&
          _merv_dhcp_atomic_field "$_mdrh_dir" handoff_state failed || return 1
        _merv_dhcp_queue_recovery_locked handoff-failed || :
        _merv_dhcp_log error "orphaned requested handoff failed id=$_mdrh_id"
        ;;
      acknowledged|completed)
        if ! _merv_dhcp_handoff_ack_valid_locked "$_mdrh_id"; then
          _mdrh_now=$(date +%s 2>/dev/null || printf '0')
          _merv_dhcp_atomic_field "$_mdrh_dir" failed_epoch "$_mdrh_now" &&
            _merv_dhcp_atomic_field "$_mdrh_dir" failure_reason invalid-successor &&
            _merv_dhcp_atomic_field "$_mdrh_dir" handoff_state failed || return 1
          _merv_dhcp_queue_recovery_locked handoff-failed || :
          _merv_dhcp_log error "handoff successor invalid; marked failed id=$_mdrh_id"
          continue
        fi
        if [ "$_mdrh_state" = acknowledged ]; then
          _mdrh_child_dir="$MERV_DHCP_HOLD_STATE_ROOT/owners/$_MERV_DHCP_HANDOFF_ACK_TOKEN"
          _mdrh_pid=$(cat "$_mdrh_child_dir/pid" 2>/dev/null || printf '')
          _mdrh_start=$(cat "$_mdrh_child_dir/proc_start_time" 2>/dev/null || printf '')
          if ! merv_process_identity_matches "$_mdrh_pid" "$_mdrh_start" "$_mdrh_proc" 2>/dev/null; then
            _mdrh_now=$(date +%s 2>/dev/null || printf '0')
            _merv_dhcp_atomic_field "$_mdrh_dir" failed_epoch "$_mdrh_now" &&
              _merv_dhcp_atomic_field "$_mdrh_dir" failure_reason dead-successor &&
              _merv_dhcp_atomic_field "$_mdrh_dir" handoff_state failed || return 1
            _merv_dhcp_queue_recovery_locked handoff-failed || :
            _merv_dhcp_log error "acknowledged handoff successor died; marked failed id=$_mdrh_id"
            continue
          fi
        fi
        _mdrh_parent_type="$_MERV_DHCP_HANDOFF_PARENT_TYPE"
        _mdrh_parent_token="$_MERV_DHCP_HANDOFF_PARENT_TOKEN"
        case "$_mdrh_parent_type:$_mdrh_state" in
          heal:acknowledged|heal:completed|boot-watchdog:completed)
            _mdrh_parent_dir="$MERV_DHCP_HOLD_STATE_ROOT/owners/$_mdrh_parent_token"
            if [ -d "$_mdrh_parent_dir" ] && [ -f "$_mdrh_parent_dir/ready" ]; then
              _merv_dhcp_record_remove_locked owners "$_mdrh_parent_token" || :
              _mdrh_now=$(date +%s 2>/dev/null || printf '0')
              _merv_dhcp_atomic_field "$_mdrh_dir" parent_retired_epoch "$_mdrh_now" || :
              _merv_dhcp_log info "handoff parent reconciled id=$_mdrh_id"
            fi
            ;;
        esac
        ;;
      failed)
        _merv_dhcp_queue_recovery_locked handoff-failed || :
        ;;
    esac
  done
  return 0
}

merv_dhcp_hold_reconcile() {
  local _mdhr_reason="${1:-state-reconcile}" _mdhr_nonce _mdhr_rc
  merv_dhcp_hold_valid_id "$_mdhr_reason" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdhr_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_reconcile_handoffs_locked || {
    merv_dhcp_state_lock_release_or_report "$_mdhr_nonce" || return 2
    return 2
  }
  _merv_dhcp_reconcile_records_locked || {
    merv_dhcp_state_lock_release_or_report "$_mdhr_nonce" || return 2
    return 2
  }
  _merv_dhcp_rules_reconcile_locked
  _mdhr_rc=$?
  merv_dhcp_state_lock_release "$_mdhr_nonce" || return 2
  return "$_mdhr_rc"
}

merv_dhcp_hold_settle_tick() {
  case "${1:-}" in
    :) return 0 ;;
    sleep) sleep 1 ;;
    "sleep 1") sleep 1 ;;
    sleep\ [0-9]*)
      _mdst_seconds=${1#sleep }
      case "$_mdst_seconds" in ''|*[!0-9]*) return 1 ;; esac
      sleep "$_mdst_seconds"
      ;;
    *) return 1 ;;
  esac
}

merv_dhcp_hold_wait_stable() {
  local _mdws_observe="$1" _mdws_correct="${2:-:}"
  local _mdws_need="${3:-${MERV_DHCP_SETTLE_STABLE_SEC:-3}}"
  local _mdws_max="${4:-${MERV_DHCP_SETTLE_MAX_SEC:-60}}"
  local _mdws_tick="${MERV_DHCP_SETTLE_TICK_CMD:-sleep 1}"
  local _mdws_pass=1 _mdws_elapsed _mdws_stable _mdws_state _mdws_last
  type "$_mdws_observe" >/dev/null 2>&1 || return 1
  type "$_mdws_correct" >/dev/null 2>&1 || return 1
  merv_dhcp_hold_settle_tick "$_mdws_tick" || return 1
  case "$_mdws_need:$_mdws_max" in *[!0-9:]*) return 1 ;; esac
  [ "$_mdws_need" -gt 0 ] && [ "$_mdws_max" -gt 0 ] || return 1

  while [ "$_mdws_pass" -le 2 ]; do
    _mdws_elapsed=0
    _mdws_stable=0
    _mdws_last=unhealthy
    while [ "$_mdws_elapsed" -lt "$_mdws_max" ]; do
      merv_dhcp_hold_enforce >/dev/null 2>&1 || return 4
      _mdws_state=$("$_mdws_observe" 2>/dev/null | tail -n 1)
      case "$_mdws_state" in
        healthy)
          _mdws_stable=$((_mdws_stable + 1))
          [ "$_mdws_stable" -ge "$_mdws_need" ] && return 0
          ;;
        busy|busy:*)
          _mdws_stable=0
          ;;
        *)
          _mdws_stable=0
          ;;
      esac
      _mdws_last="$_mdws_state"
      merv_dhcp_hold_settle_tick "$_mdws_tick" || return 5
      _mdws_elapsed=$((_mdws_elapsed + 1))
    done
    case "$_mdws_last" in
      busy|busy:*)
        merv_dhcp_hold_record_fault settle-asus-work-active hold "$_mdws_last" >/dev/null 2>&1 || :
        merv_dhcp_state_lock_acquire >/dev/null 2>&1 || return 6
        _mdws_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
        _merv_dhcp_queue_recovery_locked asus-work-active >/dev/null 2>&1 || :
        merv_dhcp_state_lock_release_or_report "$_mdws_nonce" || return 2
        return 6
        ;;
    esac
    [ "$_mdws_pass" -eq 1 ] || break
    "$_mdws_correct" || :
    _mdws_pass=2
  done
  merv_dhcp_hold_record_fault settle-verification-failed hold "${_mdws_last:-unhealthy}" >/dev/null 2>&1 || :
  merv_dhcp_state_lock_acquire >/dev/null 2>&1 || return 7
  _mdws_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_queue_recovery_locked settle-verification-failed >/dev/null 2>&1 || :
  merv_dhcp_state_lock_release_or_report "$_mdws_nonce" || return 2
  return 7
}

merv_dhcp_hold_clear_failsafes() {
  local _mdcf_token="$1" _mdcf_verification="$2" _mdcf_run="${3:-}"
  local _mdcf_nonce _mdcf_dir _mdcf_id _mdcf_remaining=0 _mdcf_handoff_state
  merv_dhcp_hold_valid_id "$_mdcf_verification" || return 1
  [ -z "$_mdcf_run" ] || merv_dhcp_hold_valid_id "$_mdcf_run" || return 1
  merv_dhcp_state_lock_acquire || return 2
  _mdcf_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_owner_is_caller_locked "$_mdcf_token" || {
    merv_dhcp_state_lock_release_or_report "$_mdcf_nonce" || return 2
    return 1
  }
  case "$_MERV_DHCP_OWNER_TYPE" in recovery|manager) ;; *)
    merv_dhcp_state_lock_release_or_report "$_mdcf_nonce" || return 2
    return 1
  esac
  [ "$_MERV_DHCP_OWNER_PHASE" = verified ] &&
    [ "$(cat "$_MERV_DHCP_OWNER_DIR/verification_id" 2>/dev/null)" = "$_mdcf_verification" ] || {
      merv_dhcp_state_lock_release_or_report "$_mdcf_nonce" || return 2
      return 1
    }
  for _mdcf_dir in "$MERV_DHCP_HOLD_STATE_ROOT/failsafe/"*; do
    [ -d "$_mdcf_dir" ] && [ -f "$_mdcf_dir/ready" ] || continue
    if [ -n "$_mdcf_run" ] && [ "$(cat "$_mdcf_dir/run_id" 2>/dev/null)" != "$_mdcf_run" ]; then
      _mdcf_remaining=1
      continue
    fi
    _mdcf_id=${_mdcf_dir##*/}
    _merv_dhcp_atomic_field "$_mdcf_dir" verification_id "$_mdcf_verification" || :
    _merv_dhcp_log info "failsafe cleared id=$_mdcf_id verification=$_mdcf_verification"
    _merv_dhcp_record_remove_locked failsafe "$_mdcf_id" || {
      merv_dhcp_state_lock_release_or_report "$_mdcf_nonce" || return 2
      return 2
    }
  done
  # A terminal failed handoff is also a recovery request.  Once this exact
  # manager/recovery owner has published final verification, retaining that
  # record would re-queue recovery forever even though the current topology
  # has been checked and is safe.  Do not touch live handoffs here.
  for _mdcf_dir in "$MERV_DHCP_HOLD_STATE_ROOT/handoffs/"*; do
    [ -d "$_mdcf_dir" ] && [ -f "$_mdcf_dir/ready" ] || continue
    _mdcf_id=${_mdcf_dir##*/}
    _mdcf_handoff_state=$(cat "$_mdcf_dir/handoff_state" 2>/dev/null || printf '')
    case "$_mdcf_handoff_state" in
      failed)
        _merv_dhcp_atomic_field "$_mdcf_dir" verification_id "$_mdcf_verification" || :
        _merv_dhcp_log info "failed handoff cleared id=$_mdcf_id verification=$_mdcf_verification"
        _merv_dhcp_record_remove_locked handoffs "$_mdcf_id" || {
          merv_dhcp_state_lock_release_or_report "$_mdcf_nonce" || return 2
          return 2
        }
        ;;
      requested|acknowledged)
        _mdcf_remaining=1
        ;;
    esac
  done
  if [ "$_mdcf_remaining" -eq 0 ]; then
    for _mdcf_dir in "$MERV_DHCP_HOLD_STATE_ROOT/failsafe/"*; do
      [ -d "$_mdcf_dir" ] && [ -f "$_mdcf_dir/ready" ] && _mdcf_remaining=1
    done
  fi
  [ "$_mdcf_remaining" -ne 0 ] || rm -f "$MERV_DHCP_HOLD_STATE_ROOT/recovery.pending" 2>/dev/null || :
  _merv_dhcp_rules_reconcile_locked
  _mdcf_rc=$?
  merv_dhcp_state_lock_release "$_mdcf_nonce" || return 2
  return "$_mdcf_rc"
}

merv_dhcp_hold_status() {
  local _mdhs_desired=clear _mdhs_observed _mdhs_rc _mdhs_dir _mdhs_id
  local _mdhs_type _mdhs_run _mdhs_phase _mdhs_pid _mdhs_start _mdhs_valid _mdhs_proc
  merv_dhcp_hold_state_root_valid || return 1
  _merv_dhcp_required_locked && _mdhs_desired=hold
  _mdhs_observed=$(merv_dhcp_hold_rules_observed)
  _mdhs_rc=$?
  printf 'desired=%s\n' "$_mdhs_desired"
  printf 'observed=%s\n' "$_mdhs_observed"
  _mdhs_proc=$(merv_dhcp_proc_root 2>/dev/null || printf '/proc')
  for _mdhs_dir in "$MERV_DHCP_HOLD_STATE_ROOT/owners/"*; do
    [ -d "$_mdhs_dir" ] && [ -f "$_mdhs_dir/ready" ] || continue
    _mdhs_id=${_mdhs_dir##*/}
    _mdhs_type=$(cat "$_mdhs_dir/owner_type" 2>/dev/null || printf unknown)
    _mdhs_run=$(cat "$_mdhs_dir/run_id" 2>/dev/null || printf unknown)
    _mdhs_phase=$(cat "$_mdhs_dir/phase" 2>/dev/null || printf unknown)
    _mdhs_pid=$(cat "$_mdhs_dir/pid" 2>/dev/null || printf 0)
    _mdhs_start=$(cat "$_mdhs_dir/proc_start_time" 2>/dev/null || printf 0)
    _mdhs_valid=no
    merv_process_identity_matches "$_mdhs_pid" "$_mdhs_start" "$_mdhs_proc" 2>/dev/null && _mdhs_valid=yes
    printf 'owner token=%s type=%s run=%s phase=%s pid=%s identity_valid=%s\n' \
      "$(_merv_dhcp_short_token "$_mdhs_id")" "$_mdhs_type" "$_mdhs_run" "$_mdhs_phase" "$_mdhs_pid" "$_mdhs_valid"
  done
  for _mdhs_dir in "$MERV_DHCP_HOLD_STATE_ROOT/failsafe/"*; do
    [ -d "$_mdhs_dir" ] && [ -f "$_mdhs_dir/ready" ] || continue
    printf 'failsafe type=%s run=%s phase=%s reason=%s failed_interfaces=%s expected_bridges=%s observed_bridges=%s missing_rules=%s asus_work=%s suggested_action=%s\n' \
      "$(cat "$_mdhs_dir/owner_type" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/run_id" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/phase" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/reason" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/failed_interfaces" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/expected_bridges" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/observed_bridges" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/missing_rules" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/asus_work" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/suggested_action" 2>/dev/null || printf mervlan-recovery)"
  done
  if [ -f "$MERV_DHCP_HOLD_STATE_ROOT/recovery.pending" ]; then
    printf 'pending_recovery=yes\n'
  else
    printf 'pending_recovery=no\n'
  fi
  for _mdhs_dir in "$MERV_DHCP_HOLD_STATE_ROOT/handoffs/"*; do
    [ -d "$_mdhs_dir" ] && [ -f "$_mdhs_dir/ready" ] || continue
    printf 'handoff id=%s parent=%s parent_run=%s child=%s child_run=%s state=%s failure_reason=%s\n' \
      "${_mdhs_dir##*/}" \
      "$(cat "$_mdhs_dir/parent_owner_type" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/parent_run_id" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/child_owner_type" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/ack_child_run_id" 2>/dev/null || printf pending)" \
      "$(cat "$_mdhs_dir/handoff_state" 2>/dev/null || printf unknown)" \
      "$(cat "$_mdhs_dir/failure_reason" 2>/dev/null || printf none)"
  done
  if [ "$_mdhs_desired" = hold ]; then
    merv_dhcp_hold_rules_present || return $?
  else
    merv_dhcp_hold_rules_absent || return $?
  fi
  return "$_mdhs_rc"
}

# Compatibility wrappers remain for boot and heal during mixed-version rounds.
merv_dhcp_hold_arm() {
  local _mdha_quiet="${1:-0}" _mdha_marker_mode="${2:-marker}"
  local _mdha_parent _mdha_tmp _mdha_nonce _mdha_rc
  if [ "$_mdha_marker_mode" = "no-marker" ]; then
    merv_dhcp_hold_enforce
    return $?
  fi
  merv_dhcp_state_lock_acquire || return 2
  _mdha_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _merv_dhcp_hold_enforce_locked || {
    _mdha_rc=$?
    merv_dhcp_state_lock_release_or_report "$_mdha_nonce" || return 2
    return "$_mdha_rc"
  }
  _mdha_parent=${MERV_DHCP_HOLD_LEGACY_MARKER%/*}
  mkdir -p "$_mdha_parent" 2>/dev/null || { merv_dhcp_state_lock_release_or_report "$_mdha_nonce" || return 2; return 2; }
  _mdha_tmp="${MERV_DHCP_HOLD_LEGACY_MARKER}.tmp.$$"
  printf '%s\n' "$(date +%s 2>/dev/null || printf '0')" > "$_mdha_tmp" 2>/dev/null &&
    mv "$_mdha_tmp" "$MERV_DHCP_HOLD_LEGACY_MARKER" 2>/dev/null || {
      merv_dhcp_state_lock_release_or_report "$_mdha_nonce" || return 2
      return 2
    }
  merv_dhcp_state_lock_release "$_mdha_nonce" || return 2
  [ "$_mdha_quiet" = "quiet" ] || _merv_dhcp_log info "legacy hold armed"
  return 0
}

merv_dhcp_hold_release() {
  local _mdhrel_token="${1:-}" _mdhrel_nonce _mdhrel_rc
  [ -z "$_mdhrel_token" ] || { _merv_dhcp_token_release "$_mdhrel_token"; return $?; }
  merv_dhcp_state_lock_acquire || return 2
  _mdhrel_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  rm -f "${MERV_DHCP_HOLD_LEGACY_MARKER:-${LOCKDIR}/merv_dhcp_hold.active}" 2>/dev/null || {
    merv_dhcp_state_lock_release_or_report "$_mdhrel_nonce" || return 2
    return 2
  }
  _merv_dhcp_rules_reconcile_locked
  _mdhrel_rc=$?
  merv_dhcp_state_lock_release "$_mdhrel_nonce" || return 2
  [ "$_mdhrel_rc" -eq 0 ] && _merv_dhcp_log info "legacy hold released"
  return "$_mdhrel_rc"
}

merv_dhcp_hold_restore_if_active() {
  merv_dhcp_hold_required || return 0
  merv_dhcp_hold_enforce
  return $?
}

merv_observation_wait_idle() {
  local _mowi_max="${1:-120}" _mowi_elapsed=0
  local _mowi_lock="${LOCKDIR:-/tmp/mervlan_tmp/locks}/observation/worker.lock"
  local _mowi_pid _mowi_start _mowi_proc
  case "$_mowi_max" in ''|*[!0-9]*) return 1 ;; esac
  _mowi_proc=$(merv_dhcp_proc_root 2>/dev/null || printf '/proc')
  while [ -d "$_mowi_lock" ]; do
    _mowi_pid=$(cat "$_mowi_lock/pid" 2>/dev/null || printf '')
    _mowi_start=$(cat "$_mowi_lock/proc_start_time" 2>/dev/null || printf '')
    merv_process_identity_matches "$_mowi_pid" "$_mowi_start" "$_mowi_proc" 2>/dev/null || return 0
    [ "$_mowi_elapsed" -lt "$_mowi_max" ] || return 1
    sleep 1
    _mowi_elapsed=$((_mowi_elapsed + 1))
  done
  return 0
}

merv_l2_guard_restore_all() {
  local _rules="${1:-}"
  type ebtables >/dev/null 2>&1 || return 0
  [ -n "$_rules" ] || _rules=$(ebtables -t filter -L 2>/dev/null)

  type restore_merv_qt_shield          >/dev/null 2>&1 && restore_merv_qt_shield  "$_rules"
  type restore_merv_mac_shield         >/dev/null 2>&1 && restore_merv_mac_shield "$_rules"
  type merv_dhcp_hold_restore_if_active >/dev/null 2>&1 && merv_dhcp_hold_restore_if_active
}

merv_guard_tick() {
  local _rules=""
  type ebtables >/dev/null 2>&1 && _rules=$(ebtables -t filter -L 2>/dev/null)
  merv_l2_guard_restore_all "$_rules"
}

merv_guarded_sleep() {
  local _n="${1:-1}"
  case "$_n" in ''|*[!0-9]*) _n=1 ;; esac
  while [ "$_n" -gt 0 ]; do
    merv_guard_tick
    sleep 1
    _n=$((_n - 1))
  done
}

# ============================================================================
# Lock helpers — shared age/state logic so heal, the MERV_MAC snapshot and the
# manager itself all agree on when mervlan_manager.lock is alive vs. abandoned.
# A crashed manager must never block recovery forever.
# ============================================================================

# merv_lock_now — current epoch (0 on failure)
merv_lock_now() {
  local _n
  _n=$(date +%s 2>/dev/null || echo 0)
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  printf '%s' "$_n"
}

# ============================================================================
# Centralized directory-lock primitives
# ----------------------------------------------------------------------------
# One implementation shared by mervlan_manager.sh, heal_event.sh and any other
# script that needs a robust mutex. The authoritative owner-aware implementation
# is defined at the end of this file so every caller observes the same contract.
# ============================================================================

# Internal: best-effort log line for the lock helpers. Prefers the project's
# log helpers (info/warn/error) when present, falls back to syslog.
_merv_lock_log() {
  _mll_lvl="$1"; shift
  if type "$_mll_lvl" >/dev/null 2>&1; then
    "$_mll_lvl" -c vlan "$*"
  else
    logger -t "VLANMgr" "$*" 2>/dev/null || :
  fi
}

# ============================================================================
# Boot shield precondition
# ----------------------------------------------------------------------------
# merv_boot_shield_lan_configured [settings_file]
# Returns 0 (true) iff settings.json declares at least one VLAN with a real,
# numeric VID >= 2 in the VLAN.Pool slots VLAN_01..VLAN_12. Used by
# mervlan_boot_wrap.sh `shield` mode to avoid arming the boot DHCP hold on a
# fresh or unconfigured install, which would otherwise brick br0 DHCP until
# the watchdog timeout elapses.
# ============================================================================
merv_boot_shield_lan_configured() {
  local _file="${1:-$SETTINGS_FILE}" _i _slot _val _max
  [ -s "$_file" ] || return 1
  type json_get_flag >/dev/null 2>&1 || return 1

  # Determine how many VLAN slots to scan dynamically.
  # Prefer Hardware.MAX_SSIDS (post-probe actual count); if zero or absent fall
  # back to Limits.MAX_SSID_CAP; finally default to 16 (new cap).
  _max=$(json_get_section_value "Hardware" "MAX_SSIDS" "$_file" 2>/dev/null)
  case "$_max" in
    ''|0|*[!0-9]*)
      _max=$(json_get_section_value "Limits" "MAX_SSID_CAP" "$_file" 2>/dev/null)
      case "$_max" in ''|0|*[!0-9]*) _max=16 ;; esac
      ;;
  esac

  _i=1
  while [ "$_i" -le "$_max" ]; do
    if [ "$_i" -lt 10 ]; then
      _slot="VLAN_0$_i"
    else
      _slot="VLAN_$_i"
    fi
    _val=$(json_get_flag "$_slot" "none" "$_file" 2>/dev/null)
    case "$_val" in
      ''|none|0|1|*[!0-9]*) : ;;
      *)
        if [ "$_val" -ge 2 ] 2>/dev/null; then
          return 0
        fi
        ;;
    esac
    _i=$((_i + 1))
  done
  return 1
}

# ============================================================================
# Fail-closed owner-aware lock implementation (v2)
# ============================================================================
# The older helpers above remain in the file for compatibility with already
# synced scripts, but these definitions are intentionally last so every fresh
# caller uses the v2 contract.  A lock is reclaimable only when its complete
# recorded process identity is proven dead or PID-reused.  Age is diagnostic
# only; it never overrides a live owner.

_merv_lock_v2_nonce() {
  _ml2_now=$(merv_lock_now)
  _ml2_start=$(merv_proc_start_time "$$" 2>/dev/null || printf '0')
  printf '%s.%s.%s.%s\n' "$_ml2_now" "$$" "$_ml2_start" "${RANDOM:-0}"
}

_merv_lock_v2_write() {
  _ml2_lock="$1"; _ml2_start="$2"; _ml2_nonce="$3"; _ml2_now="$4"
  case "$_ml2_start:$_ml2_now" in *[!0-9:]*|:*|*::*) return 1 ;; esac
  case "$_ml2_nonce" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  _ml2_tmp="$_ml2_lock/.owner.tmp.$$"
  ( umask 077
    printf 'pid=%s\nproc_start_time=%s\nowner_nonce=%s\ncreated=%s\nheartbeat=%s\n' \
      "$$" "$_ml2_start" "$_ml2_nonce" "$_ml2_now" "$_ml2_now" > "$_ml2_tmp"
  ) 2>/dev/null || { rm -f "$_ml2_tmp" 2>/dev/null; return 1; }
  chmod 600 "$_ml2_tmp" 2>/dev/null || { rm -f "$_ml2_tmp" 2>/dev/null; return 1; }
  mv -f "$_ml2_tmp" "$_ml2_lock/owner" 2>/dev/null || { rm -f "$_ml2_tmp" 2>/dev/null; return 1; }
  # Compatibility fields are informational only.  The single owner record is
  # authoritative and is the one observers validate atomically.
  printf '%s\n' "$$" > "$_ml2_lock/pid" 2>/dev/null || return 1
  printf '%s\n' "$_ml2_start" > "$_ml2_lock/proc_start_time" 2>/dev/null || return 1
  printf '%s\n' "$_ml2_nonce" > "$_ml2_lock/owner_nonce" 2>/dev/null || return 1
  printf '%s\n' "$_ml2_now" > "$_ml2_lock/created" 2>/dev/null || return 1
  printf '%s\n' "$_ml2_now" > "$_ml2_lock/heartbeat" 2>/dev/null || return 1
  chmod 600 "$_ml2_lock/pid" "$_ml2_lock/proc_start_time" "$_ml2_lock/owner_nonce" "$_ml2_lock/created" "$_ml2_lock/heartbeat" 2>/dev/null || return 1
}

_merv_lock_v2_read() {
  _ml2_lock="$1"
  [ -f "$_ml2_lock/owner" ] || return 1
  MERV_LOCK_OWNER_PID=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$_ml2_lock/owner" 2>/dev/null | head -n 1)
  MERV_LOCK_OWNER_START=$(sed -n 's/^proc_start_time=\([0-9][0-9]*\)$/\1/p' "$_ml2_lock/owner" 2>/dev/null | head -n 1)
  MERV_LOCK_OWNER_NONCE=$(sed -n 's/^owner_nonce=\([A-Za-z0-9._:-][A-Za-z0-9._:-]*\)$/\1/p' "$_ml2_lock/owner" 2>/dev/null | head -n 1)
  MERV_LOCK_OWNER_CREATED=$(sed -n 's/^created=\([0-9][0-9]*\)$/\1/p' "$_ml2_lock/owner" 2>/dev/null | head -n 1)
  MERV_LOCK_OWNER_HEARTBEAT=$(sed -n 's/^heartbeat=\([0-9][0-9]*\)$/\1/p' "$_ml2_lock/owner" 2>/dev/null | head -n 1)
  case "$MERV_LOCK_OWNER_PID:$MERV_LOCK_OWNER_START:$MERV_LOCK_OWNER_CREATED:$MERV_LOCK_OWNER_HEARTBEAT" in
    *[!0-9:]*|:*|*::*) return 1 ;;
  esac
  [ -n "$MERV_LOCK_OWNER_NONCE" ] || return 1
}

_merv_lock_v2_quarantine() {
  _ml2_lock="$1"; _ml2_parent=${_ml2_lock%/*}; _ml2_base=${_ml2_lock##*/}; _ml2_try=0
  while [ "$_ml2_try" -lt 8 ]; do
    _ml2_dest="$_ml2_parent/.${_ml2_base}.quarantine.$$.$_ml2_try"
    mv "$_ml2_lock" "$_ml2_dest" 2>/dev/null && return 0
    _ml2_try=$((_ml2_try + 1))
  done
  return 1
}

# Upgrade-only compatibility for pre-owner-aware template locks.  Those locks
# were regular empty files, while the current protocol uses an owner-record
# directory.  An empty legacy file is preserved safely by quarantining it only
# after its mtime is older than the bounded migration window; fresh,
# non-empty, or ambiguous state remains fail-closed.
merv_lock_quarantine_legacy_file() {
  _ml2_legacy="${1:-}"
  _ml2_label="${2:-legacy-lock}"
  [ -n "$_ml2_legacy" ] || return 1
  [ -f "$_ml2_legacy" ] && [ ! -d "$_ml2_legacy" ] || return 0
  [ ! -s "$_ml2_legacy" ] || {
    _merv_lock_log warn "lock $_ml2_label has non-empty legacy metadata; refusing migration"
    return 1
  }
  _ml2_stale="${MERV_LEGACY_LOCK_STALE_SEC:-60}"
  case "$_ml2_stale" in ''|*[!0-9]*) _ml2_stale=60 ;; esac
  _ml2_now=$(merv_lock_now)
  _ml2_mtime=$(date -r "$_ml2_legacy" +%s 2>/dev/null || printf '')
  case "$_ml2_now:$_ml2_mtime" in
    *[!0-9:]*|:*|*::)
      _merv_lock_log warn "lock $_ml2_label has unreadable legacy age; refusing migration"
      return 1
      ;;
  esac
  [ "$_ml2_now" -ge "$_ml2_mtime" ] || return 1
  _ml2_age=$((_ml2_now - _ml2_mtime))
  [ "$_ml2_age" -ge "$_ml2_stale" ] || {
    _merv_lock_log warn "lock $_ml2_label is a fresh legacy file; refusing migration"
    return 1
  }
  _ml2_dest="${_ml2_legacy}.legacy.quarantine.${_ml2_now}.$$"
  mv "$_ml2_legacy" "$_ml2_dest" 2>/dev/null || return 1
  _merv_lock_log warn "quarantined stale legacy lock file for $_ml2_label"
  return 0
}

merv_lock_state() {
  _ml2_lock="${1:-$LOCKDIR/mervlan_manager.lock}"
  [ -d "$_ml2_lock" ] || { printf 'absent'; return 0; }
  _merv_lock_v2_read "$_ml2_lock" 2>/dev/null || { printf 'unknown'; return 0; }
  if merv_process_identity_matches "$MERV_LOCK_OWNER_PID" "$MERV_LOCK_OWNER_START" 2>/dev/null; then
    printf 'active'
  else
    printf 'stale'
  fi
}

merv_manager_lock_state() { merv_lock_state "$@"; }

merv_lock_acquire() {
  _ml2_lock="$1"; _ml2_stale="$2"; _ml2_max="${3:-30}"; _ml2_label="${4:-${1##*/}}"; _ml2_attempt=0
  [ -n "$_ml2_lock" ] || return 1
  case "$_ml2_max" in ''|*[!0-9]*) _ml2_max=30 ;; esac
  mkdir -p "${_ml2_lock%/*}" 2>/dev/null || return 1
  # Older installations used an empty regular file for the same lock name.
  # Migrate only a provably stale, empty legacy file; fresh, non-empty, or
  # unreadable metadata remains fail-closed in merv_lock_state below.
  if [ -f "$_ml2_lock" ] && [ ! -d "$_ml2_lock" ]; then
    merv_lock_quarantine_legacy_file "$_ml2_lock" "$_ml2_label" || return 1
  fi
  while ! mkdir "$_ml2_lock" 2>/dev/null; do
    _ml2_state=$(merv_lock_state "$_ml2_lock")
    case "$_ml2_state" in
      active)
        [ "$_ml2_attempt" -lt "$_ml2_max" ] || return 1
        sleep 2; _ml2_attempt=$((_ml2_attempt + 1))
        ;;
      stale)
        _merv_lock_v2_quarantine "$_ml2_lock" || return 1
        ;;
      unknown|*)
        _merv_lock_log warn "lock ${_ml2_label} has unknown owner metadata; refusing reclaim"
        return 1
        ;;
    esac
  done
  _ml2_start=$(merv_proc_start_time "$$" 2>/dev/null || printf '')
  [ -n "$_ml2_start" ] || return 1
  _ml2_nonce=$(_merv_lock_v2_nonce); _ml2_now=$(merv_lock_now)
  _merv_lock_v2_write "$_ml2_lock" "$_ml2_start" "$_ml2_nonce" "$_ml2_now" || return 1
  MERV_LOCK_NONCE="$_ml2_nonce"; MERV_LOCK_START="$_ml2_start"
  return 0
}

merv_lock_heartbeat() {
  _ml2_lock="$1"
  _merv_lock_v2_read "$_ml2_lock" 2>/dev/null || return 1
  [ "$MERV_LOCK_OWNER_PID" = "$$" ] && [ "$MERV_LOCK_OWNER_START" = "$(merv_proc_start_time "$$" 2>/dev/null)" ] || return 1
  _ml2_now=$(merv_lock_now); _ml2_tmp="$_ml2_lock/.owner.tmp.$$"
  sed "s/^heartbeat=.*/heartbeat=$_ml2_now/" "$_ml2_lock/owner" > "$_ml2_tmp" 2>/dev/null || { rm -f "$_ml2_tmp" 2>/dev/null; return 1; }
  chmod 600 "$_ml2_tmp" 2>/dev/null || { rm -f "$_ml2_tmp" 2>/dev/null; return 1; }
  mv -f "$_ml2_tmp" "$_ml2_lock/owner" 2>/dev/null || return 1
  printf '%s\n' "$_ml2_now" > "$_ml2_lock/heartbeat" 2>/dev/null
}

merv_lock_release() {
  _ml2_lock="$1"; _ml2_nonce="${2:-${MERV_LOCK_NONCE:-}}"
  [ -n "$_ml2_lock" ] || return 0
  [ -d "$_ml2_lock" ] || return 0
  _merv_lock_v2_read "$_ml2_lock" 2>/dev/null || return 1
  [ "$MERV_LOCK_OWNER_PID" = "$$" ] && [ "$MERV_LOCK_OWNER_START" = "$(merv_proc_start_time "$$" 2>/dev/null)" ] &&
    [ "$MERV_LOCK_OWNER_NONCE" = "$_ml2_nonce" ] || return 1
  rm -f "$_ml2_lock/owner" "$_ml2_lock/pid" "$_ml2_lock/proc_start_time" "$_ml2_lock/owner_nonce" \
    "$_ml2_lock/created" "$_ml2_lock/heartbeat" 2>/dev/null || return 1
  rmdir "$_ml2_lock" 2>/dev/null || return 1
  return 0
}

_merv_ebtables_get_dump() {
  mervqt_has_ebtables || return 3
  _megd=$(ebtables -t filter -L --Lx 2>/dev/null) && [ -n "$_megd" ] && { printf '%s\n' "$_megd"; return 0; }
  _megd=$(ebtables -t filter -L 2>/dev/null) || return 4
  [ -n "$_megd" ] || return 4
  printf '%s\n' "$_megd"
}

merv_ebtables_chain_declared_exact() {
  _mecde_dump="$1"; _mecde_chain="$2"
  # ASUSWRT ebtables renders -L --Lx as restore-style commands, while other
  # firmware builds use the traditional "Bridge chain:" listing. Accept either
  # canonical representation without weakening the exact-one chain invariant.
  printf '%s\n' "$_mecde_dump" | awk -v c="$_mecde_chain" '
    /^Bridge chain:/ {
      x=$3; sub(/,$/,"",x)
      if (x==c) n++
      next
    }
    /^ebtables -t filter -N / {
      if ($5==c) n++
    }
    END { exit !(n==1) }'
}

merv_ebtables_jump_count_exact() {
  _mej_dump="$1"; _mej_parent="$2"; _mej_chain="$3"
  printf '%s\n' "$_mej_dump" | awk -v p="$_mej_parent" -v c="$_mej_chain" '
    /^Bridge chain:/ {x=$3; sub(/,$/,"",x); on=(x==p); next}
    on {for(i=1;i<NF;i++) if($i=="-j" && $(i+1)==c)n++}
    /^ebtables -t filter -A / {
      if ($5==p) for(i=6;i<NF;i++) if($i=="-j" && $(i+1)==c)n++
    }
    END{print n+0}'
}

merv_ebtables_rule_count_exact() {
  _mer_dump="$1"; _mer_chain="$2"; _mer_expected="$3"
  printf '%s\n' "$_mer_dump" | awk -v c="$_mer_chain" -v e="$_mer_expected" '
    # ASUSWRT ebtables renders MAC octets without leading zeroes (08:... as
    # 8:...), while the database and command arguments use two-digit octets.
    # Compare canonical rule tokens so the verifier checks rule identity rather
    # than a firmware-specific presentation detail.
    function mac_canonical(x, a, n, i, v, out) {
      n=split(x,a,":")
      if(n!=6) return tolower(x)
      out=""
      for(i=1;i<=n;i++) {
        v=tolower(a[i])
        if(v !~ /^[[:xdigit:]][[:xdigit:]]?$/) return tolower(x)
        if(length(v)==1) v="0" v
        out=out (i==1 ? "" : ":") v
      }
      return out
    }
    function rule_canonical(s, a, n, i, v, out) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/[[:space:]]+/, " ", s)
      n=split(s,a," ")
      for(i=1;i<n;i++) {
        if(a[i]=="-s" || a[i]=="-d" ||
           a[i]=="--mac-source" || a[i]=="--mac-destination") {
          a[i+1]=mac_canonical(a[i+1])
        }
      }
      out=""
      for(i=1;i<=n;i++) out=out (i==1 ? "" : " ") a[i]
      return out
    }
    /^Bridge chain:/ {x=$3; sub(/,$/,"",x); on=(x==c); next}
    on {
      line=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); gsub(/[[:space:]]+/, " ", line)
      if(line ~ /^policy:/ || line ~ /^-P / || line ~ /^num[[:space:]]/) next
      if(line ~ /^-A /) { sub(/^-A [^ ]+[[:space:]]+/, "", line) }
      if(rule_canonical(line)==rule_canonical(e))n++
    }
    /^ebtables -t filter -A / {
      if ($5!=c) next
      line=""
      for(i=6;i<=NF;i++) line=line (line=="" ? "" : " ") $i
      if(rule_canonical(line)==rule_canonical(e))n++
    }
    END{print n+0}'
}

merv_ebtables_chain_rule_count() {
  _merc_dump="$1"; _merc_chain="$2"
  printf '%s\n' "$_merc_dump" | awk -v c="$_merc_chain" '
    /^Bridge chain:/ {x=$3; sub(/,$/,"",x); on=(x==c); next}
    on {
      line=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if(line ~ /^policy:/ || line ~ /^-P / || line ~ /^num[[:space:]]/) next
      if(line ~ /^-A /) { sub(/^-A [^ ]+[[:space:]]+/, "", line) }
      if(length(line)>0)n++
    }
    /^ebtables -t filter -A / {
      if ($5!=c) next
      line=""
      for(i=6;i<=NF;i++) line=line (line=="" ? "" : " ") $i
      if(length(line)>0)n++
    }
    END{print n+0}'
}

merv_ebtables_verify_parent_jumps() {
  _mevp_dump="$1"; _mevp_chain="$2"
  merv_ebtables_chain_declared_exact "$_mevp_dump" "$_mevp_chain" || return 1
  [ "$(merv_ebtables_jump_count_exact "$_mevp_dump" FORWARD "$_mevp_chain")" = 1 ] || return 1
  [ "$(merv_ebtables_jump_count_exact "$_mevp_dump" INPUT "$_mevp_chain")" = 1 ] || return 1
}

merv_mac_shield_verify_exact() {
  [ "${DRY_RUN:-no}" = yes ] && return 0
  _mev_dump=$(_merv_ebtables_get_dump) || return 1
  merv_ebtables_verify_parent_jumps "$_mev_dump" "$MERV_MAC_CHAIN" || return 1
  _mev_db=$(merv_mac_best_db 2>/dev/null || printf '')
  _mev_expected=0
  if [ -n "$_mev_db" ]; then
    _mev_ovr=$(mervqt_override_list_read 2>/dev/null || printf ' ')
    while IFS=' ' read -r _mev_ts _mev_mac _mev_iface _mev_vid; do
      [ -n "$_mev_ts" ] || continue
      case "$_mev_ts" in *[!0-9]*) return 1 ;; esac
      _mev_mac=$(mervqt_mac_lower "$_mev_mac"); mervqt_valid_mac "$_mev_mac" || return 1
      mervqt_valid_wl_subif "$_mev_iface" || return 1; mervqt_valid_vid "$_mev_vid" || return 1
      mervqt_mac_is_overridden "$_mev_mac" "$_mev_ovr" && continue
      _mev_expected=$((_mev_expected + 1))
      _mev_rule="-s $_mev_mac --logical-in br0 -j DROP"
      [ "$(merv_ebtables_rule_count_exact "$_mev_dump" "$MERV_MAC_CHAIN" "$_mev_rule")" = 1 ] || return 1
    done < "$_mev_db"
  fi
  [ "$(merv_ebtables_chain_rule_count "$_mev_dump" "$MERV_MAC_CHAIN")" = "$_mev_expected" ] || return 1
  return 0
}

merv_qt_verify_exact() {
  [ "${DRY_RUN:-no}" = yes ] && return 0
  _qtev_dump=$(_merv_ebtables_get_dump) || return 1
  merv_ebtables_verify_parent_jumps "$_qtev_dump" "$MERV_QT_CHAIN" || return 1
  _qtev_pairs=""
  if type merv_iface_vid_list >/dev/null 2>&1; then _qtev_pairs=$(merv_iface_vid_list 2>/dev/null); elif type merv_mac_build_expected_iface_vid >/dev/null 2>&1; then _qtev_pairs=$(merv_mac_build_expected_iface_vid 2>/dev/null); fi
  _qtev_expected=0
  while IFS=' ' read -r _qtev_iface _qtev_vid; do
    [ -n "$_qtev_iface" ] && [ -n "$_qtev_vid" ] || continue
    case "$_qtev_vid" in ''|*[!0-9]*) continue ;; esac
    [ "$_qtev_vid" -ge 2 ] 2>/dev/null || continue
    mervqt_valid_wl_subif "$_qtev_iface" || return 1
    _qtev_expected=$((_qtev_expected + 1))
    _qtev_rule="-i $_qtev_iface --logical-in br0 -j DROP"
    [ "$(merv_ebtables_rule_count_exact "$_qtev_dump" "$MERV_QT_CHAIN" "$_qtev_rule")" = 1 ] || return 1
  done <<EOF
$_qtev_pairs
EOF
  [ "$(merv_ebtables_chain_rule_count "$_qtev_dump" "$MERV_QT_CHAIN")" = "$_qtev_expected" ] || return 1
  return 0
}

merv_l2_guard_verify_exact() {
  merv_mac_shield_verify_exact || return 1
  merv_qt_verify_exact || return 1
  return 0
}

# ============================================================================
# Strict mutation definitions (v3)
# ============================================================================
# The historical implementations above intentionally tolerated every ebtables
# error.  Keep their names for compatibility, but make the final definitions
# transactional: each mutating call is followed by an exact dump check, and a
# failed command is never converted into success.

_merv_ebtables_chain_present() {
  _mep_dump=$(_merv_ebtables_get_dump) || return 1
  merv_ebtables_chain_declared_exact "$_mep_dump" "$1"
}

_merv_ebtables_parent_jump_present_once() {
  _mep_dump=$(_merv_ebtables_get_dump) || return 1
  [ "$(merv_ebtables_jump_count_exact "$_mep_dump" "$1" "$2")" = 1 ]
}

ebt_mac_shield_init() {
  [ "${DRY_RUN:-no}" = yes ] && return 0
  mervqt_has_ebtables || return 3
  if ! _merv_ebtables_chain_present "$MERV_MAC_CHAIN"; then
    ebtables -t filter -N "$MERV_MAC_CHAIN" 2>/dev/null || return 1
  fi
  _mep_parent=FORWARD
  while [ -n "$_mep_parent" ]; do
    if [ "$(merv_ebtables_jump_count_exact "$(_merv_ebtables_get_dump 2>/dev/null || printf '')" "$_mep_parent" "$MERV_MAC_CHAIN")" = 0 ]; then
      ebtables -t filter -I "$_mep_parent" -j "$MERV_MAC_CHAIN" 2>/dev/null || return 1
    fi
    [ "$(merv_ebtables_jump_count_exact "$(_merv_ebtables_get_dump 2>/dev/null || printf '')" "$_mep_parent" "$MERV_MAC_CHAIN")" = 1 ] || return 1
    [ "$_mep_parent" = FORWARD ] && _mep_parent=INPUT || _mep_parent=
  done
  _mep_dump=$(_merv_ebtables_get_dump) || return 1
  merv_ebtables_verify_parent_jumps "$_mep_dump" "$MERV_MAC_CHAIN"
}

ebt_mac_shield_flush() {
  [ "${DRY_RUN:-no}" = yes ] && return 0
  mervqt_has_ebtables || return 3
  ebtables -t filter -F "$MERV_MAC_CHAIN" 2>/dev/null || return 1
  _mep_dump=$(_merv_ebtables_get_dump) || return 1
  merv_ebtables_verify_parent_jumps "$_mep_dump" "$MERV_MAC_CHAIN" || return 1
  [ "$(merv_ebtables_chain_rule_count "$_mep_dump" "$MERV_MAC_CHAIN")" = 0 ]
}

ebt_mac_shield_teardown() {
  [ "${DRY_RUN:-no}" = yes ] && return 0
  mervqt_has_ebtables || return 3
  if _merv_ebtables_chain_present "$MERV_MAC_CHAIN"; then
    ebtables -t filter -F "$MERV_MAC_CHAIN" 2>/dev/null || return 1
    ebtables -t filter -D FORWARD -j "$MERV_MAC_CHAIN" 2>/dev/null || return 1
    ebtables -t filter -D INPUT -j "$MERV_MAC_CHAIN" 2>/dev/null || return 1
    ebtables -t filter -X "$MERV_MAC_CHAIN" 2>/dev/null || return 1
  fi
  _mep_dump=$(_merv_ebtables_get_dump 2>/dev/null || printf '')
  [ -z "$_mep_dump" ] || ! merv_ebtables_chain_declared_exact "$_mep_dump" "$MERV_MAC_CHAIN"
}

ebt_mac_shield_apply() {
  [ "${DRY_RUN:-no}" = yes ] && return 0
  mervqt_has_ebtables || return 3
  _mep_db="${1:-$MERV_MAC_DB_ACTIVE}"
  [ -f "$_mep_db" ] || return 0
  _mep_dump=$(_merv_ebtables_get_dump) || return 1
  merv_ebtables_verify_parent_jumps "$_mep_dump" "$MERV_MAC_CHAIN" || return 1
  _mep_ovr=$(mervqt_override_list_read 2>/dev/null || printf ' ')
  _mep_failed=0; _mep_rules=0
  while IFS=' ' read -r _mep_ts _mep_mac _mep_iface _mep_vid; do
    [ -n "$_mep_ts" ] || continue
    case "$_mep_ts" in *[!0-9]*) _mep_failed=1; continue ;; esac
    _mep_mac=$(mervqt_mac_lower "$_mep_mac")
    mervqt_valid_mac "$_mep_mac" || { _mep_failed=1; continue; }
    mervqt_valid_wl_subif "$_mep_iface" || { _mep_failed=1; continue; }
    mervqt_valid_vid "$_mep_vid" || { _mep_failed=1; continue; }
    mervqt_mac_is_overridden "$_mep_mac" "$_mep_ovr" && continue
    ebtables -t filter -A "$MERV_MAC_CHAIN" -s "$_mep_mac" --logical-in br0 -j DROP 2>/dev/null || _mep_failed=1
    _mep_rules=$((_mep_rules + 1))
  done < "$_mep_db"
  [ "$_mep_failed" -eq 0 ] || return 1
  merv_mac_shield_verify_exact
}

ebt_mac_shield_init_and_apply() {
  ebt_mac_shield_init || return 1
  ebt_mac_shield_flush || return 1
  ebt_mac_shield_apply "${1:-$MERV_MAC_DB_ACTIVE}"
}

merv_qt_ensure_expected_rules() {
  [ "${DRY_RUN:-no}" = yes ] && return 0
  mervqt_has_ebtables || return 3
  if ! _merv_ebtables_chain_present "$MERV_QT_CHAIN"; then
    ebtables -t filter -N "$MERV_QT_CHAIN" 2>/dev/null || return 1
  fi
  for _meq_parent in FORWARD INPUT; do
    _meq_dump=$(_merv_ebtables_get_dump) || return 1
    if [ "$(merv_ebtables_jump_count_exact "$_meq_dump" "$_meq_parent" "$MERV_QT_CHAIN")" = 0 ]; then
      ebtables -t filter -I "$_meq_parent" -j "$MERV_QT_CHAIN" 2>/dev/null || return 1
    fi
    _meq_dump=$(_merv_ebtables_get_dump) || return 1
    [ "$(merv_ebtables_jump_count_exact "$_meq_dump" "$_meq_parent" "$MERV_QT_CHAIN")" = 1 ] || return 1
  done
  type merv_mac_build_expected_iface_vid >/dev/null 2>&1 || return 1
  if type merv_iface_vid_list >/dev/null 2>&1; then _meq_pairs=$(merv_iface_vid_list); else _meq_pairs=$(merv_mac_build_expected_iface_vid 2>/dev/null); fi
  while IFS=' ' read -r _meq_iface _meq_vid; do
    [ -n "$_meq_iface" ] && [ -n "$_meq_vid" ] || continue
    case "$_meq_vid" in ''|*[!0-9]*) continue ;; esac
    [ "$_meq_vid" -ge 2 ] 2>/dev/null || continue
    mervqt_valid_wl_subif "$_meq_iface" || return 1
    _meq_dump=$(_merv_ebtables_get_dump) || return 1
    _meq_rule="-i $_meq_iface --logical-in br0 -j DROP"
    [ "$(merv_ebtables_rule_count_exact "$_meq_dump" "$MERV_QT_CHAIN" "$_meq_rule")" = 1 ] || {
      ebtables -t filter -A "$MERV_QT_CHAIN" -i "$_meq_iface" --logical-in br0 -j DROP 2>/dev/null || return 1
    }
  done <<EOF
$_meq_pairs
EOF
  merv_qt_verify_exact
}

merv_qt_teardown() {
  [ "${DRY_RUN:-no}" = yes ] && return 0
  mervqt_has_ebtables || return 3
  _meqt_dump=$(_merv_ebtables_get_dump) || return 1
  merv_ebtables_chain_declared_exact "$_meqt_dump" "$MERV_QT_CHAIN" || return 0
  ebtables -t filter -F "$MERV_QT_CHAIN" 2>/dev/null || return 1
  _meqt_dump=$(_merv_ebtables_get_dump) || return 1
  [ "$(merv_ebtables_chain_rule_count "$_meqt_dump" "$MERV_QT_CHAIN")" = 0 ] || return 1
  for _meqt_parent in FORWARD INPUT; do
    _meqt_jumps=$(merv_ebtables_jump_count_exact "$_meqt_dump" "$_meqt_parent" "$MERV_QT_CHAIN")
    [ "$_meqt_jumps" = 0 ] && continue
    [ "$_meqt_jumps" = 1 ] || return 1
    ebtables -t filter -D "$_meqt_parent" -j "$MERV_QT_CHAIN" 2>/dev/null || return 1
    _meqt_dump=$(_merv_ebtables_get_dump) || return 1
    [ "$(merv_ebtables_jump_count_exact "$_meqt_dump" "$_meqt_parent" "$MERV_QT_CHAIN")" = 0 ] || return 1
  done
  ebtables -t filter -X "$MERV_QT_CHAIN" 2>/dev/null || return 1
  _meqt_dump=$(_merv_ebtables_get_dump) || return 1
  ! merv_ebtables_chain_declared_exact "$_meqt_dump" "$MERV_QT_CHAIN"
}

LIB_MERVQT_LOADED=1
