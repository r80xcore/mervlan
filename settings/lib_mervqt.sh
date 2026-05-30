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
#                  - File: lib_mervqt.sh || version="0.5"                      #
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

# merv_dhcp_hold_arm [quiet]
merv_dhcp_hold_arm() {
  local _hold_rules _changed _quiet
  _quiet="${1:-0}"
  _changed=0

  type ebtables >/dev/null 2>&1 || return 0

  ebtables -t filter -N "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null && _changed=1

  _hold_rules=$(ebtables -t filter -L "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null)
  if ! printf '%s\n' "$_hold_rules" | grep -qF 'DROP'; then
    ebtables -t filter -A "$MERV_DHCP_HOLD_CHAIN" -p IPv4 --ip-proto udp --ip-dport 67 -j DROP 2>/dev/null || true
    _changed=1
  fi

  if ! ebtables -t filter -L FORWARD 2>/dev/null | grep -qF "$MERV_DHCP_HOLD_CHAIN"; then
    ebtables -t filter -I FORWARD -j "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || true
    _changed=1
  fi

  if ! ebtables -t filter -L INPUT 2>/dev/null | grep -qF "$MERV_DHCP_HOLD_CHAIN"; then
    ebtables -t filter -I INPUT -j "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || true
    _changed=1
  fi

  echo "$(date +%s)" > "$LOCKDIR/merv_dhcp_hold.active" 2>/dev/null || true
  [ "$_changed" -eq 1 ] && [ "$_quiet" != "quiet" ] && \
    info -c vlan "DHCP hold: armed for br0 critical section"
}

merv_dhcp_hold_release() {
  type ebtables >/dev/null 2>&1 || return 0

  while ebtables -t filter -D FORWARD -j "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null; do :; done
  while ebtables -t filter -D INPUT -j "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null; do :; done

  ebtables -t filter -F "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || true
  ebtables -t filter -X "$MERV_DHCP_HOLD_CHAIN" 2>/dev/null || true

  rm -f "$LOCKDIR/merv_dhcp_hold.active" 2>/dev/null || true
  info -c vlan "DHCP hold: released"
}

merv_dhcp_hold_restore_if_active() {
  [ -f "$LOCKDIR/merv_dhcp_hold.active" ] || return 0
  merv_dhcp_hold_arm quiet
}

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

# merv_lock_age <lock_dir> — seconds since the lock was created.
# Prefers the lock's own `created` stamp (BusyBox-safe); falls back to the
# directory mtime via `stat -c %Y`. Prints 0 when age cannot be determined.
merv_lock_age() {
  local _path="$1" _now _created _mtime
  [ -n "$_path" ] || { printf '0'; return 0; }

  _now=$(merv_lock_now)

  _created=$(cat "$_path/created" 2>/dev/null || echo "")
  case "$_created" in ''|*[!0-9]*) _created="" ;; esac
  if [ -n "$_created" ] && [ "$_now" -gt 0 ]; then
    printf '%s' $(( _now - _created ))
    return 0
  fi

  _mtime=$(stat -c %Y "$_path" 2>/dev/null || echo 0)
  case "$_mtime" in ''|*[!0-9]*) _mtime=0 ;; esac
  if [ "$_mtime" -gt 0 ] && [ "$_now" -gt 0 ]; then
    printf '%s' $(( _now - _mtime ))
  else
    printf '0'
  fi
}

# merv_lock_state [lock_dir]
# Generic lock-state observer. Despite the historical name, this works on ANY
# directory lock created by merv_lock_acquire (manager, heal/vlan_event, sync,
# mac_refresh, …) — pass the lock path as $1. Defaults to the manager lock for
# backward compatibility.
# Prints one of: active | stale | unknown_recent | absent
#   active         — pid file present and process alive
#   stale          — old enough to reclaim (dead pid, or pidless and aged)
#   unknown_recent — held but cannot yet be confirmed stale (skip briefly)
#   absent         — no lock directory
merv_lock_state() {
  local _lock _stale _pid _age
  _lock="${1:-$LOCKDIR/mervlan_manager.lock}"
  _stale="${MERV_MANAGER_LOCK_STALE_SEC:-900}"
  case "$_stale" in ''|*[!0-9]*) _stale=900 ;; esac

  [ -d "$_lock" ] || { printf 'absent'; return 0; }

  _pid=$(cat "$_lock/pid" 2>/dev/null || echo "")
  case "$_pid" in *[!0-9]*) _pid="" ;; esac
  if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    printf 'active'
    return 0
  fi

  _age=$(merv_lock_age "$_lock")
  case "$_age" in ''|*[!0-9]*) _age=0 ;; esac

  # Dead/missing owner past the stale window -> reclaimable.
  if [ "$_age" -ge "$_stale" ]; then
    printf 'stale'
    return 0
  fi
  # Pidless and older than a short grace -> reclaimable (covers a manager that
  # made the dir but died before writing its pid). The grace avoids racing a
  # manager in the microsecond gap between mkdir and the pid write.
  if [ -z "$_pid" ] && [ "$_age" -ge 10 ]; then
    printf 'stale'
    return 0
  fi

  printf 'unknown_recent'
  return 0
}

# merv_manager_lock_state — backward-compatible alias for merv_lock_state.
# Retained so any caller (or synced node still running an older copy) that
# references the original name keeps working unchanged.
merv_manager_lock_state() {
  merv_lock_state "$@"
}

# ============================================================================
# Centralized directory-lock primitives
# ----------------------------------------------------------------------------
# One implementation shared by mervlan_manager.sh, heal_event.sh and any other
# script that needs a robust mutex. Uses mkdir as the atomic acquire primitive
# plus a `pid` file (liveness via kill -0) and a `created` epoch stamp (age via
# merv_lock_age — never `stat -c %Y`, which is unreliable on BusyBox and used
# to yield nonsense ages of ~1.7e9 seconds). Crashed owners are reclaimed once
# the stale window elapses; live owners are honoured up to a bounded wait.
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

# merv_lock_acquire <lock_dir> [stale_sec] [max_wait_iters] [label]
# Acquire <lock_dir> atomically, writing this process's PID and a creation
# stamp inside it. On contention:
#   * live owner   -> wait (2s per iteration) up to max_wait_iters, then fail
#   * dead/aged    -> reclaim once the stale window elapses, then retry
# Pass max_wait_iters=0 for non-blocking (skip-on-contention) callers like heal.
# Returns 0 on success (caller MUST call merv_lock_release on the same dir),
# 1 if the lock could not be acquired.
merv_lock_acquire() {
  local _lock="$1" _stale="$2" _maxiters="${3:-30}" _label="$4"
  local _attempts=0 _oldpid _age
  [ -n "$_lock" ] || return 1
  [ -n "$_label" ] || _label="${_lock##*/}"

  case "$_stale" in ''|*[!0-9]*) _stale="${MERV_MANAGER_LOCK_STALE_SEC:-900}" ;; esac
  case "$_stale" in ''|*[!0-9]*) _stale=900 ;; esac
  case "$_maxiters" in ''|*[!0-9]*) _maxiters=30 ;; esac

  while ! mkdir "$_lock" 2>/dev/null; do
    _oldpid=$(cat "$_lock/pid" 2>/dev/null || echo "")
    case "$_oldpid" in *[!0-9]*) _oldpid="" ;; esac

    # Owner alive — honour it within the bounded wait budget.
    if [ -n "$_oldpid" ] && kill -0 "$_oldpid" 2>/dev/null; then
      if [ "$_attempts" -ge "$_maxiters" ]; then
        _merv_lock_log warn "lock ${_label} held by live PID ${_oldpid}; giving up"
        return 1
      fi
      sleep 2
      _attempts=$((_attempts + 1))
      continue
    fi

    # No live owner. Reclaim if clearly stale (dead pid past the window, or
    # pidless past a short grace that covers the mkdir->pid-write race).
    _age=$(merv_lock_age "$_lock")
    case "$_age" in ''|*[!0-9]*) _age=0 ;; esac
    if [ "$_age" -ge "$_stale" ] || { [ -z "$_oldpid" ] && [ "$_age" -ge 10 ]; }; then
      _merv_lock_log warn "lock ${_label} stale (age=${_age}s, pid='${_oldpid}'); reclaiming"
      rm -rf "$_lock" 2>/dev/null || :
      if [ "$_attempts" -ge $((_maxiters + 10)) ]; then
        _merv_lock_log error "lock ${_label} unreclaimable after retries; giving up"
        return 1
      fi
      _attempts=$((_attempts + 1))
      continue
    fi

    # Owner gone but lock still young — wait for the grace to elapse, unless
    # the caller is non-blocking.
    if [ "$_attempts" -ge "$_maxiters" ]; then
      _merv_lock_log warn "lock ${_label} owner gone (pid='${_oldpid}') but young (age=${_age}s); giving up"
      return 1
    fi
    sleep 2
    _attempts=$((_attempts + 1))
  done

  # Acquired — record ownership for stale detection by ourselves and others.
  echo "$$" > "$_lock/pid" 2>/dev/null || :
  merv_lock_now > "$_lock/created" 2>/dev/null || :
  return 0
}

# merv_lock_release <lock_dir>
# Release a lock previously taken with merv_lock_acquire. Safe to call from an
# EXIT/INT/TERM trap.
merv_lock_release() {
  local _lock="$1"
  [ -n "$_lock" ] || return 0
  rm -f "$_lock/pid" "$_lock/created" 2>/dev/null || :
  rmdir "$_lock" 2>/dev/null || rm -rf "$_lock" 2>/dev/null || :
  return 0
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
  local _file="${1:-$SETTINGS_FILE}" _i _slot _val
  [ -s "$_file" ] || return 1
  type json_get_flag >/dev/null 2>&1 || return 1

  _i=1
  while [ "$_i" -le 12 ]; do
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

LIB_MERVQT_LOADED=1
