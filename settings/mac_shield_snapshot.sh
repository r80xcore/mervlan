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
#               - File: mac_shield_snapshot.sh || version="0.2"                #
# ============================================================================ #
# Purpose: MERV_MAC persistent db management.
#   Builds a post-apply snapshot of known client MAC→iface→VID state,
#   merges into a persistent db (latest-per-MAC semantics), and checkpoints
#   to JFFS only when content changes.
#
# Load contract (in callers):
#   [ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ] || \
#     . "$MERV_BASE/settings/mac_shield_snapshot.sh"
#
# Dependencies:
#   lib_mervqt.sh          — ebt_mac_shield_* functions, mervqt_valid_* validators,
#                            mervqt_mac_lower, merv_mac_best_db
#   lib_ssid_filter.sh     — get_ssid_slot_value, get_vlan_slot_value
#   var_settings.sh        — MERV_MAC_DB_ACTIVE, MERV_MAC_DB_JFFS,
#                            MERV_MAC_MAX_AGE_SEC, SETTINGS_FILE, MAX_SSIDS
#   log_settings.sh        — info, warn
#
# Subinterface scope (this version):
#   merv_mac_build_expected_iface_vid resolves wl*.* (Broadcom) only.
#   ra*.* and ath*.* support requires separate NVRAM key extension and is
#   deferred. Validators in lib_mervqt.sh already accept those prefixes in
#   db/rule handling for forward compatibility.
# ============================================================================ #
if [ -n "${LIB_MAC_SHIELD_SNAPSHOT_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# ============================================================================
# merv_mac_boot_init
# Called once in boot mode before first manager apply.
#   - If /tmp db is missing and JFFS checkpoint exists: copy to /tmp
#   - Arm MERV_MAC chain from /tmp db
# Ensures clients known from the last reboot are protected during the boot gap
# before any clients re-associate.
# ============================================================================
merv_mac_boot_init() {
  mkdir -p "$(dirname "$MERV_MAC_DB_ACTIVE")" 2>/dev/null || true

  if [ ! -f "$MERV_MAC_DB_ACTIVE" ] && [ -f "$MERV_MAC_DB_JFFS" ]; then
    cp "$MERV_MAC_DB_JFFS" "$MERV_MAC_DB_ACTIVE" 2>/dev/null || true
    local n
    n=$(wc -l < "$MERV_MAC_DB_ACTIVE" 2>/dev/null | tr -d ' ')
    info -c vlan "MERV_MAC: restored ${n:-0} entries from JFFS checkpoint to active db"
  fi

  ebt_mac_shield_init_and_apply "$MERV_MAC_DB_ACTIVE"
}

# ============================================================================
# merv_mac_build_expected_iface_vid
# Derive expected wl subinterface → VID map from settings + NVRAM.
# This is the single canonical implementation shared by both manager and heal.
# Do NOT duplicate this logic elsewhere.
#
# Source of truth:
#   - SSID slots via get_ssid_slot_value / get_vlan_slot_value
#     (respects node assignment and SSID filter)
#   - NVRAM wl*_ssid / wl*_ifname for interface resolution
#
# Output: lines of "<iface> <vid>" (one per resolved wl subinterface per slot)
#
# Rules:
#   - Skips unconfigured/placeholder SSID slots
#   - Skips VLAN = none, trunk, or out of valid range
#   - Only emits wl*.* subinterfaces (not base radios wl0/wl1, not eth*)
#   - Uses a single cached `nvram show` to avoid repeated NVRAM calls
#   - Output is deduplicated: same iface appearing in multiple slots emitted once
# ============================================================================
merv_mac_build_expected_iface_vid() {
  local max_ssids i ssid vlan nvram_ssids key rawval val base iface

  max_ssids="${MAX_SSIDS:-12}"

  # Single cached NVRAM read across all slot iterations
  nvram_ssids=$(nvram show 2>/dev/null | grep -E '^wl[0-9](\.[0-9]+)?_ssid=')

  i=1
  while [ "$i" -le "$max_ssids" ]; do
    ssid=$(get_ssid_slot_value "$i" "$SETTINGS_FILE")
    vlan=$(get_vlan_slot_value "$i" "$SETTINGS_FILE")
    i=$((i + 1))

    # Skip unconfigured or placeholder slots
    [ -z "$ssid" ] || [ "$ssid" = "unused-placeholder" ] && continue

    # Skip non-VLAN assignments
    case "$vlan" in ''|none|trunk) continue ;; esac
    mervqt_valid_vid "$vlan" || continue

    # Scan cached NVRAM for wl subinterfaces matching this SSID
    while IFS='=' read -r key rawval; do
      # Strip quotes and surrounding whitespace from NVRAM value
      val=$(printf '%s' "$rawval" \
        | sed "s/^[[:space:]]*['\"]//;s/['\"][[:space:]]*\$//;s/^[[:space:]]*//;s/[[:space:]]*\$//")
      [ "$val" = "$ssid" ] || continue

      base="${key%_ssid}"

      # Only process wl subinterface NVRAM keys (wl0.1_ssid etc.) — skip base radios
      case "$base" in
        wl[0-9].[0-9]*) ;;
        *) continue ;;
      esac

      # Resolve ifname from NVRAM; fall back to base key name if empty
      iface=$(nvram get "${base}_ifname" 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$iface" ] || iface="$base"

      # Emit only wl subinterfaces
      case "$iface" in
        wl[0-9].*) printf '%s %s\n' "$iface" "$vlan" ;;
      esac

    done <<_NVRAM_
$nvram_ssids
_NVRAM_

  done | awk '!seen[$1]++'
}

# ============================================================================
# merv_mac_snapshot_preconditions_ok
# Returns 0 only if ALL config-expected wl subinterfaces are:
#   - present in sysfs
#   - members of their expected bridge br<vid>
#   - NOT simultaneously members of br0
#
# If any expected interface is absent from sysfs: treated as "not yet settled"
# → precondition FAILS. Do not snapshot a partially-up wireless stack.
#
# If no VLAN-bearing SSID interfaces are configured: returns 0 (vacuous pass).
# ============================================================================
merv_mac_snapshot_preconditions_ok() {
  local pairs iface vid ok=1 checked=0

  pairs=$(merv_mac_build_expected_iface_vid)
  [ -n "$pairs" ] || return 0

  while IFS=' ' read -r iface vid; do
    [ -n "$iface" ] && [ -n "$vid" ] || continue

    if [ ! -d "/sys/class/net/$iface" ]; then
      warn -c vlan "MAC precondition: $iface not in sysfs — wireless not yet settled"
      ok=0
      continue
    fi

    checked=$((checked + 1))

    if [ -e "/sys/class/net/br${vid}/brif/$iface" ]; then
      if [ -e "/sys/class/net/br0/brif/$iface" ]; then
        warn -c vlan "MAC precondition: $iface is in both br${vid} and br0 — inconsistent state"
        ok=0
      fi
      continue
    fi

    if [ -e "/sys/class/net/br0/brif/$iface" ]; then
      warn -c vlan "MAC precondition: $iface expected br${vid} but found in br0"
    else
      warn -c vlan "MAC precondition: $iface expected br${vid} but found in neither bridge"
    fi
    ok=0
  done <<_PAIRS_
$pairs
_PAIRS_

  [ "$checked" -eq 0 ] && [ "$ok" -eq 1 ] && return 0
  [ "$ok" -eq 1 ]
}

# ============================================================================
# merv_mac_build_snapshot <tmpfile>
# Scan all VLAN bridges (br<VID>) for wl*.* members, run wl assoclist on
# each, write client records to <tmpfile>.
# Format: <epoch_ts> <mac_lowercase> <wl_iface> <vid>
# Prints the number of client records written to stdout (may be 0).
# ============================================================================
merv_mac_build_snapshot() {
  local tmpfile="$1"
  local br_path br_name vid iface_path iface mac now

  now=$(date +%s)
  : > "$tmpfile" || return 1

  for br_path in /sys/class/net/br[1-9]*/brif; do
    [ -d "$br_path" ] || continue
    br_name="${br_path%/brif}"
    br_name="${br_name##*/}"
    vid="${br_name#br}"
    mervqt_valid_vid "$vid" || continue

    for iface_path in "$br_path"/wl*.* "$br_path"/ra*.* "$br_path"/ath*.*; do
      [ -e "$iface_path" ] || continue
      iface="${iface_path##*/}"
      mervqt_valid_wl_subif "$iface" || continue

      wl -i "$iface" assoclist 2>/dev/null | while IFS=' ' read -r _kw mac; do
        [ "$_kw" = "assoclist" ] || continue
        [ -n "$mac" ] || continue
        mac=$(mervqt_mac_lower "$mac")
        mervqt_valid_mac "$mac" || continue
        printf '%s %s %s %s\n' "$now" "$mac" "$iface" "$vid"
      done
    done
  done >> "$tmpfile"

  wc -l < "$tmpfile" 2>/dev/null | tr -d ' '
}

# ============================================================================
# merv_mac_merge_db <snapshot_tmpfile>
# Merge new snapshot into the existing active db.
#
# Semantics:
#   - Validates all 4 fields during merge
#   - One entry per MAC: latest timestamp wins
#   - Prunes entries older than MERV_MAC_MAX_AGE_SEC
#   - Atomic write to MERV_MAC_DB_ACTIVE (tmp + mv)
#   - Updates JFFS checkpoint only when content differs (md5 comparison)
#   - If merged result is empty: JFFS is also updated to empty so stale
#     checkpoints do not repopulate after reboot when all entries expired.
# ============================================================================
merv_mac_merge_db() {
  local snapshot="$1"
  local work_tmp="${MERV_MAC_DB_ACTIVE}.merge.$$"
  local jffs_tmp="${MERV_MAC_DB_JFFS}.tmp.$$"
  local entry_count cksum_new cksum_old

  mkdir -p "$(dirname "$MERV_MAC_DB_ACTIVE")" 2>/dev/null || true

  {
    [ -f "$MERV_MAC_DB_ACTIVE" ] && cat "$MERV_MAC_DB_ACTIVE" 2>/dev/null
    cat "$snapshot" 2>/dev/null
  } | awk \
      -v now="$(date +%s)" \
      -v max_age="$MERV_MAC_MAX_AGE_SEC" '
    NF == 4 {
      ts=$1; mac=$2; iface=$3; vid=$4

      if (ts !~ /^[0-9]+$/)          next
      if ((now - ts+0) > max_age+0)  next
      if (mac !~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) next
      if (iface !~ /^(wl|ra|ath)[0-9]+\.[0-9]/) next
      if (vid !~ /^[0-9]+$/)         next
      if (vid+0 < 2 || vid+0 > 4094) next

      if (!(mac in best_ts) || ts+0 > best_ts[mac]+0) {
        best_ts[mac]  = ts
        best_rec[mac] = ts " " mac " " iface " " vid
      }
    }
    END { for (mac in best_rec) print best_rec[mac] }
  ' | sort -n > "$work_tmp" 2>/dev/null

  entry_count=$(wc -l < "$work_tmp" 2>/dev/null | tr -d ' ')

  mv "$work_tmp" "$MERV_MAC_DB_ACTIVE" 2>/dev/null || {
    rm -f "$work_tmp" 2>/dev/null
    warn -c vlan "MERV_MAC: merge failed — could not write active db"
    return 1
  }

  [ "${MAC_SHIELD_VERBOSE:-0}" = "1" ] && info -c vlan "MERV_MAC: db merged — ${entry_count} entries"

  # JFFS checkpoint: compare structural fingerprint (mac+iface+vid) only.
  # Timestamps are refreshed on every snapshot, so a raw md5 would always
  # differ even when the same clients are on the same VLANs. We write to
  # JFFS only when the MAC set or their iface/VID assignments actually change.
  mkdir -p "$(dirname "$MERV_MAC_DB_JFFS")" 2>/dev/null || true
  cksum_new=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  cksum_old=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_JFFS"   2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  if [ "$cksum_new" != "$cksum_old" ]; then
    cp "$MERV_MAC_DB_ACTIVE" "$jffs_tmp" 2>/dev/null && \
      mv "$jffs_tmp" "$MERV_MAC_DB_JFFS" 2>/dev/null || \
      rm -f "$jffs_tmp" 2>/dev/null
    info -c vlan "MERV_MAC: JFFS checkpoint updated (${entry_count} entries)"
  fi
}

# ============================================================================
# merv_mac_maybe_trigger_heal_on_precondition_fail
# Self-recovery hook called when snapshot preconditions fail (an expected VAP
# is missing from its bridge, in the wrong bridge, or detached entirely).
#
# Without this, periodic snapshot ticks would only log the precondition
# warning and clients on the detached VAP stayed unreachable until a manual
# reboot or another service event. We now queue a heal — strictly gated to
# avoid recursion or storms:
#   - Skip if mervlan_manager is currently applying config
#   - Skip if a heal is already in flight (vlan_event.lock present)
#   - Per-(LOCKDIR) debounce: at most one trigger per MERV_MAC_HEAL_TRIGGER_DEBOUNCE
#     seconds (default 60s) regardless of how many snapshot ticks fire
# Heal is launched fire-and-forget so the snapshot caller is never blocked.
# ============================================================================
merv_mac_maybe_trigger_heal_on_precondition_fail() {
  local now last age debounce stamp

  # Honour explicit opt-out for users who want logs only.
  [ "${MERV_MAC_HEAL_TRIGGER:-1}" = "0" ] && return 0

  # Required directories / binaries
  [ -n "$LOCKDIR" ] || return 0
  [ -n "$MERV_BASE" ] || return 0
  [ -x "$MERV_BASE/functions/heal_event.sh" ] || return 0

  # Don't pile on a running apply.
  if [ -d "$LOCKDIR/mervlan_manager.lock" ]; then
    info -c vlan "MERV_MAC: precondition fail — heal not queued (mervlan_manager active)"
    return 0
  fi

  # Don't pile on an in-flight heal — its own pre-entry checks will catch it.
  if [ -d "$LOCKDIR/vlan_event.lock" ]; then
    info -c vlan "MERV_MAC: precondition fail — heal not queued (heal already running)"
    return 0
  fi

  debounce="${MERV_MAC_HEAL_TRIGGER_DEBOUNCE:-60}"
  case "$debounce" in ''|*[!0-9]*) debounce=60 ;; esac
  stamp="$LOCKDIR/mac_precondition_heal.last"
  now=$(date +%s 2>/dev/null || echo 0)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  age=$(( now - last ))
  if [ "$last" -gt 0 ] && [ "$age" -lt "$debounce" ]; then
    info -c vlan "MERV_MAC: precondition fail — heal trigger debounced (last=${age}s ago, window=${debounce}s)"
    return 0
  fi

  printf '%s\n' "$now" > "$stamp" 2>/dev/null || :
  info -c vlan "MERV_MAC: precondition fail — queueing heal_event [mac_precondition_orphan]"
  ( "$MERV_BASE/functions/heal_event.sh" "mac_precondition_orphan" ) >/dev/null 2>&1 &
  return 0
}

# ============================================================================
# merv_mac_snapshot
# Full snapshot orchestration. Called from an async subshell after the
# post_rc_watchdog correction window closes.
#
# Steps:
#   1. Precondition check — config-derived, all expected ifaces on correct bridges
#   2. Build snapshot — wl assoclist from all VLAN bridge members
#   3. Empty snapshot protection — zero clients → preserve existing db
#   4. Merge db — latest-MAC-wins, age prune, JFFS checkpoint
#   5. Rebuild MERV_MAC rules from updated active db
# ============================================================================
merv_mac_snapshot() {
  [ "${DRY_RUN:-no}" = "yes" ] && return 0

  if ! merv_mac_snapshot_preconditions_ok; then
    warn -c vlan "MERV_MAC: snapshot skipped — interfaces not fully settled (db unchanged)"
    merv_mac_maybe_trigger_heal_on_precondition_fail
    return 0
  fi

  local snap_tmp="${MERV_MAC_DB_ACTIVE}.snap.$$"
  local client_count
  client_count=$(merv_mac_build_snapshot "$snap_tmp")
  [ "${MAC_SHIELD_VERBOSE:-0}" = "1" ] && info -c vlan "MERV_MAC: snapshot captured ${client_count:-0} client(s)"

  if [ "${client_count:-0}" -eq 0 ]; then
    warn -c vlan "MERV_MAC: snapshot empty — preserving existing db (entries age out naturally)"
    rm -f "$snap_tmp" 2>/dev/null
    return 0
  fi

  # Compare structural fingerprint (mac+iface+vid only, timestamps excluded).
  # Raw md5 would always differ because timestamps refresh on every snapshot.
  local _pre_fp _post_fp
  _pre_fp=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  merv_mac_merge_db "$snap_tmp"
  rm -f "$snap_tmp" 2>/dev/null
  _post_fp=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)

  if [ "$_pre_fp" != "$_post_fp" ]; then
    ebt_mac_shield_flush
    ebt_mac_shield_apply "$MERV_MAC_DB_ACTIVE"
  else
    [ "${MAC_SHIELD_VERBOSE:-0}" = "1" ] && info -c vlan "MERV_MAC: MAC set unchanged — ebtables rules not rebuilt"
  fi
}

LIB_MAC_SHIELD_SNAPSHOT_LOADED=1
