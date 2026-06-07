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
#               - File: mac_shield_snapshot.sh || version="0.32"                #
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
#   lib_ssh.sh             — merv_ssh_exec, merv_ssh_precheck, ssh_keys_effectively_installed,
#                            _merv_timeout_run, merv_has, MERV_SSH_TIMEOUT
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

[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh"

# ============================================================================
# Snapshot behaviour flags (caller-overridable via env)
# ----------------------------------------------------------------------------
# Back-compat: MAC_SHIELD_VERBOSE was the prior verbose knob; honor it as the
# fallback default so existing callers that set it keep verbose behaviour.
# ============================================================================
: "${MERV_MAC_SNAPSHOT_VERBOSE:=${MAC_SHIELD_VERBOSE:-0}}"
: "${MERV_MAC_SNAPSHOT_LOG_CHANNELS:=vlan}"
: "${MERV_MAC_SNAPSHOT_LOG_UNCHANGED:=0}"
: "${MERV_MAC_SNAPSHOT_RESET:=0}"
: "${MERV_MAC_SNAPSHOT_FORCE_RELOAD:=0}"
: "${MERV_MAC_SNAPSHOT_ALLOW_EMPTY:=0}"

# ============================================================================
# Snapshot status output globals
# ----------------------------------------------------------------------------
# Set as side effects by merv_mac_snapshot. Readable by INLINE callers ONLY
# (e.g. mac_refresh.sh). They are NOT propagated through subshells: callers
# that wrap snapshot in ( merv_mac_snapshot ) & (heal_event.sh cron tick,
# mervlan_manager.sh post-apply) will see only the zero-initialized values
# below — never read these from such callers.
# ============================================================================
MERV_MAC_LAST_STATUS=""
MERV_MAC_LAST_REASON=""
MERV_MAC_LAST_LOCAL_COUNT=0
MERV_MAC_LAST_NODE_COUNT=0
MERV_MAC_LAST_TOTAL_COUNT=0
MERV_MAC_LAST_DB_COUNT=0
MERV_MAC_LAST_CHANGED=0
MERV_MAC_LAST_NODES_TOTAL=0
MERV_MAC_LAST_NODES_OK=0
MERV_MAC_LAST_NODES_FAILED=0
MERV_MAC_LAST_PUSH_TOTAL=0
MERV_MAC_LAST_PUSH_OK=0
MERV_MAC_LAST_PUSH_FAILED=0

# ============================================================================
# _merv_mac_log <level> <message>
# Route a log line to the caller-configured channel set so manual refresh hits
# cli,vlan while cron/manager stay on vlan only. level: info | warn
# ============================================================================
_merv_mac_log() {
  local _lvl="$1"; shift
  case "$_lvl" in
    warn) warn -c "${MERV_MAC_SNAPSHOT_LOG_CHANNELS:-vlan}" "$@" ;;
    *)    info -c "${MERV_MAC_SNAPSHOT_LOG_CHANNELS:-vlan}" "$@" ;;
  esac
}

# ============================================================================
# _merv_mac_logv <level> <message>
# Verbose-only variant: logs only when MERV_MAC_SNAPSHOT_VERBOSE=1 (manual
# refresh step trace). Stays silent for cron/manager default runs.
# ============================================================================
_merv_mac_logv() {
  [ "${MERV_MAC_SNAPSHOT_VERBOSE:-0}" = "1" ] || return 0
  _merv_mac_log "$@"
}

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

  # Use merv_cap_ssids to get a safe, cap-bounded slot count.
  # Falls back to 12 if MAX_SSIDS is 0/unset, and never exceeds Limits.MAX_SSID_CAP.
  if type merv_cap_ssids >/dev/null 2>&1; then
    max_ssids=$(merv_cap_ssids "${MAX_SSIDS:-0}" "${SETTINGS_FILE:-}")
  else
    max_ssids="${MAX_SSIDS:-12}"
    [ "$max_ssids" -gt 16 ] 2>/dev/null && max_ssids=16
  fi

  # Single cached NVRAM read across all slot iterations
  nvram_ssids=$(nvram show 2>/dev/null | grep -E '^wl[0-9][0-9]*(\.([0-9]+))?_ssid=')

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

      # Only process wl subinterface NVRAM keys (wl0.1_ssid, wl10.1_ssid etc.) — skip base radios.
      # Use merv_is_wl_vap_iface for strict validation (rejects trailing garbage like wl0.1abc).
      if type merv_is_wl_vap_iface >/dev/null 2>&1; then
        merv_is_wl_vap_iface "$base" || continue
      else
        case "$base" in
          wl[0-9].[0-9]*|wl[0-9][0-9].[0-9]*) ;;
          *) continue ;;
        esac
      fi

      # Resolve ifname from NVRAM; fall back to base key name if empty
      iface=$(nvram get "${base}_ifname" 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$iface" ] || iface="$base"

      # Emit only wl subinterfaces (strict check)
      if type merv_is_wl_vap_iface >/dev/null 2>&1; then
        merv_is_wl_vap_iface "$iface" && printf '%s %s\n' "$iface" "$vlan"
      else
        case "$iface" in
          wl[0-9].*|wl[0-9][0-9].*) printf '%s %s\n' "$iface" "$vlan" ;;
        esac
      fi

    done <<_NVRAM_
$nvram_ssids
_NVRAM_

  done | awk '!seen[$1]++'
}

# ============================================================================
# merv_iface_vid_list — cached wrapper for merv_mac_build_expected_iface_vid
#
# Returns the same output as the underlying builder. When the cache is enabled
# (merv_iface_vid_cache_enable) the result is computed once and reused until
# either the cache is invalidated (merv_iface_vid_cache_invalidate) or
# disabled (merv_iface_vid_cache_disable).
#
# Cache scope: in-memory shell variable. Process-local. Subshells (pipelines)
# do NOT mutate the parent's cache, so callers that consume output via a pipe
# still benefit because the parent shell populates the cache before the pipe.
#
# Callers that MUST see fresh state (final security check, snapshot
# preconditions) should call merv_mac_build_expected_iface_vid directly and
# bypass this wrapper.
# ============================================================================
_MERV_IFACE_VID_CACHE=""
_MERV_IFACE_VID_CACHE_ON=0

merv_iface_vid_cache_enable() {
  _MERV_IFACE_VID_CACHE_ON=1
  _MERV_IFACE_VID_CACHE=""
}

merv_iface_vid_cache_invalidate() {
  _MERV_IFACE_VID_CACHE=""
}

merv_iface_vid_cache_disable() {
  _MERV_IFACE_VID_CACHE_ON=0
  _MERV_IFACE_VID_CACHE=""
}

merv_iface_vid_list() {
  if [ "${_MERV_IFACE_VID_CACHE_ON:-0}" = "1" ]; then
    if [ -z "$_MERV_IFACE_VID_CACHE" ]; then
      _MERV_IFACE_VID_CACHE=$(merv_mac_build_expected_iface_vid 2>/dev/null)
    fi
    [ -n "$_MERV_IFACE_VID_CACHE" ] && printf '%s\n' "$_MERV_IFACE_VID_CACHE"
    return 0
  fi
  merv_mac_build_expected_iface_vid 2>/dev/null
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
  local br_path br_name vid iface_path iface mac now rep_iface

  now=$(date +%s)
  : > "$tmpfile" || return 1

  for br_path in /sys/class/net/br[1-9]*/brif; do
    [ -d "$br_path" ] || continue
    br_name="${br_path%/brif}"
    br_name="${br_name##*/}"
    vid="${br_name#br}"
    mervqt_valid_vid "$vid" || continue

    rep_iface=""
    for iface_path in "$br_path"/wl*.* "$br_path"/ra*.* "$br_path"/ath*.*; do
      [ -e "$iface_path" ] || continue
      iface="${iface_path##*/}"
      mervqt_valid_wl_subif "$iface" || continue
      [ -n "$rep_iface" ] || rep_iface="$iface"

      wl -i "$iface" assoclist 2>/dev/null | while IFS=' ' read -r _kw mac; do
        [ "$_kw" = "assoclist" ] || continue
        [ -n "$mac" ] || continue
        mac=$(mervqt_mac_lower "$mac")
        mervqt_valid_mac "$mac" || continue
        printf '%s %s %s %s\n' "$now" "$mac" "$iface" "$vid"
      done
    done

    # Supplement assoclist with the bridge forwarding database. `brctl showmacs`
    # reports every MAC the bridge has forwarded, so it captures clients that
    # have momentarily aged out of `wl assoclist` (power-save / sleeping
    # devices) or very recently disassociated — closing the protection gap for
    # those MACs. Only non-local entries (is local? = no) are clients; local
    # entries are the router's own port MACs and are excluded. Records are
    # attributed to the bridge's representative wireless subinterface (metadata
    # only — the ebtables rule keys on MAC + --logical-in br0, never on iface)
    # and only when the bridge has at least one wireless member, keeping
    # wired-only VLANs out of this version's wireless snapshot scope.
    if [ -n "$rep_iface" ] && command -v brctl >/dev/null 2>&1; then
      brctl showmacs "$br_name" 2>/dev/null | while read -r _pno mac _islocal _rest; do
        case "$mac" in
          [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:*) ;;
          *) continue ;;
        esac
        [ "$_islocal" = "no" ] || continue
        mac=$(mervqt_mac_lower "$mac")
        mervqt_valid_mac "$mac" || continue
        printf '%s %s %s %s\n' "$now" "$mac" "$rep_iface" "$vid"
      done
    fi
  done >> "$tmpfile"

  wc -l < "$tmpfile" 2>/dev/null | tr -d ' '
}

# ============================================================================
# merv_mac_is_main
# Returns 0 when this unit is the main router (safe to drive cluster sync),
# 1 when running as a node or in node context. Mirrors the guard used by
# mac_refresh.sh so node-side runs never attempt outbound SSH.
# ============================================================================
merv_mac_is_main() {
  [ "${MERV_NODE_CONTEXT:-0}" != "1" ] || return 1
  [ ! -f "$MERV_BASE/.is_node" ] || return 1
  if type json_get_flag >/dev/null 2>&1; then
    [ "$(json_get_flag "IS_NODE" "0" "$SETTINGS_FILE" 2>/dev/null)" != "1" ] || return 1
  fi
  return 0
}

# ============================================================================
# merv_mac_node_list
# Emit "<node_id> <node_ip>" for each configured, valid node from settings.json.
# Standalone parser (this script does NOT source lib_json): NODE1..NODE<max>,
# skipping "none" and any non-IPv4 value. Empty output when no nodes configured.
# ============================================================================
merv_mac_node_list() {
  [ -n "$SETTINGS_FILE" ] && [ -f "$SETTINGS_FILE" ] || return 0
  grep -o '"NODE[0-9][0-9]*"[[:space:]]*:[[:space:]]*"[^"]*"' "$SETTINGS_FILE" 2>/dev/null | \
    sed -n 's/"NODE\([0-9][0-9]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1 \2/p' | \
    awk -v max="${MERV_MAX_NODES:-10}" \
      '$1>=1 && $1<=max && $2 != "none" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1, $2 }'
}

# ============================================================================
# merv_mac_collect_from_node <node_id> <node_ip>
# Run a self-contained remote collector over one SSH connection and emit
# normalized "<now> <mac> <iface> <vid>" records on stdout (one per known
# client on the node's VLAN bridges). Uses the same assoclist + brctl FDB
# sources as the local snapshot. The remote script is passed verbatim (the
# here-doc is single-quoted so all $ expansion happens on the node), and all
# returned fields are re-validated locally before being trusted.
# Returns non-zero only on SSH failure; empty (clean) output is success.
# ============================================================================
merv_mac_collect_from_node() {
  local nid="$1" nip="$2" out now rcmd m i v
  now=$(date +%s)

  rcmd=$(cat <<'REMOTE'
for b in /sys/class/net/br[1-9]*/brif; do
  [ -d "$b" ] || continue
  n=${b%/brif}; n=${n##*/}; v=${n#br}
  case "$v" in ''|*[!0-9]*) continue ;; esac
  rep=""
  for p in "$b"/wl*.* "$b"/ra*.* "$b"/ath*.*; do
    [ -e "$p" ] || continue
    i=${p##*/}
    [ -n "$rep" ] || rep="$i"
    wl -i "$i" assoclist 2>/dev/null | while read -r k m; do
      [ "$k" = assoclist ] || continue
      [ -n "$m" ] || continue
      echo "$m $i $v"
    done
  done
  [ -n "$rep" ] || continue
  command -v brctl >/dev/null 2>&1 || continue
  brctl showmacs "$n" 2>/dev/null | while read -r po m loc rest; do
    case "$m" in [0-9a-fA-F][0-9a-fA-F]:*) ;; *) continue ;; esac
    [ "$loc" = no ] || continue
    echo "$m $rep $v"
  done
done
REMOTE
)

  out=$(merv_ssh_exec "$nid" "$nip" "$rcmd" 2>/dev/null) || return 1
  [ -n "$out" ] || return 0

  printf '%s\n' "$out" | while read -r m i v; do
    [ -n "$m" ] && [ -n "$i" ] && [ -n "$v" ] || continue
    m=$(mervqt_mac_lower "$m")
    mervqt_valid_mac "$m"       || continue
    mervqt_valid_wl_subif "$i"  || continue
    mervqt_valid_vid "$v"       || continue
    printf '%s %s %s %s\n' "$now" "$m" "$i" "$v"
  done
}

# ============================================================================
# merv_mac_push_db_to_nodes "<node_id node_ip\n...>"
# Stream the merged active db to each node (atomic tmp+mv over one SSH stream)
# and reload that node's MERV_MAC ebtables chain from the pushed db. Called only
# after the merged db's structural fingerprint changes, so stable networks
# generate no pushes. Fully guarded: silently no-ops when the SSH toolchain,
# keys, or db file are unavailable.
#
# Push-outcome counters: this function mutates the MERV_MAC_LAST_PUSH_* status
# globals directly. The caller (merv_mac_snapshot) MUST initialize them to zero
# before invoking. The node loop is here-doc fed (not pipe fed) so the counter
# increments run in the current shell and survive — a pipe-fed `while read`
# would lose them to a subshell.
# ============================================================================
merv_mac_push_db_to_nodes() {
  local nodes="$1"
  local nid nip port user _ovr_src

  ssh_keys_effectively_installed                   || return 0
  [ -n "${SSH_KEY:-}" ] && [ -f "${SSH_KEY}" ]       || return 0
  merv_has dbclient                                 || return 0
  [ -f "$MERV_MAC_DB_ACTIVE" ] || return 0

  while read -r nid nip; do
    [ -n "$nip" ] || continue
    MERV_MAC_LAST_PUSH_TOTAL=$(( MERV_MAC_LAST_PUSH_TOTAL + 1 ))

    if ! merv_ssh_precheck "$nid" "$nip" >/dev/null 2>&1; then
      _merv_mac_log warn "MERV_MAC: node ${nip} precheck failed — db not pushed"
      MERV_MAC_LAST_PUSH_FAILED=$(( MERV_MAC_LAST_PUSH_FAILED + 1 ))
      continue
    fi

    port=$(get_node_ssh_port); [ -n "$port" ] || port=22
    user=$(get_node_ssh_user); [ -n "$user" ] || user=admin

    # Stream the db to the node and install it atomically (tmp + mv). The remote
    # command is single-quoted past the MERV_MAC_DB_ACTIVE interpolation so $d,
    # ${d%/*} and $$ all expand on the node.
    if _merv_timeout_run "$MERV_SSH_TIMEOUT" dbclient -p "$port" -y -i "$SSH_KEY" \
         "$user@$nip" \
         "d='$MERV_MAC_DB_ACTIVE'; "'mkdir -p "${d%/*}" 2>/dev/null; cat > "$d.tmp.$$" && mv "$d.tmp.$$" "$d"' \
         < "$MERV_MAC_DB_ACTIVE" 2>/dev/null; then

      # Push the override DB BEFORE the reload so the node enforces with the
      # current override set. The override DB is cluster-wide: an empty file is
      # meaningful (it clears any stale overrides left on the node). Stream
      # /dev/null when no override DB exists locally. Best-effort: a failed
      # override push is logged but does not abort the reload.
      _ovr_src="$MERV_MAC_OVERRIDE_DB"
      [ -f "$_ovr_src" ] || _ovr_src="/dev/null"
      if ! _merv_timeout_run "$MERV_SSH_TIMEOUT" dbclient -p "$port" -y -i "$SSH_KEY" \
             "$user@$nip" \
             "d='$MERV_MAC_OVERRIDE_DB'; "'mkdir -p "${d%/*}" 2>/dev/null; cat > "$d.tmp.$$" && mv "$d.tmp.$$" "$d"' \
             < "$_ovr_src" 2>/dev/null; then
        _merv_mac_log warn "MERV_MAC: override db push failed to node ${nip} (reloading anyway)"
      fi

      # Reload the node's shield from the freshly pushed db (no remote snapshot).
      # init_and_apply (flush → init → apply) so a node whose chain was lost to a
      # reboot/teardown is repaired rather than silently no-op'd.
      if merv_ssh_exec "$nid" "$nip" \
           "MERV_BASE='$MERV_BASE'; MERV_NODE_CONTEXT=1; "'. "$MERV_BASE/settings/var_settings.sh" 2>/dev/null; . "$MERV_BASE/settings/log_settings.sh" 2>/dev/null; . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null; ebt_mac_shield_init_and_apply "$MERV_MAC_DB_ACTIVE"' \
           >/dev/null 2>&1; then
        _merv_mac_logv info "MERV_MAC: ✓ db pushed + shield reloaded on node ${nip}"
        MERV_MAC_LAST_PUSH_OK=$(( MERV_MAC_LAST_PUSH_OK + 1 ))
      else
        _merv_mac_log warn "MERV_MAC: db pushed but shield reload failed on node ${nip}"
        MERV_MAC_LAST_PUSH_FAILED=$(( MERV_MAC_LAST_PUSH_FAILED + 1 ))
      fi
    else
      _merv_mac_log warn "MERV_MAC: ✗ db push failed to node ${nip}"
      MERV_MAC_LAST_PUSH_FAILED=$(( MERV_MAC_LAST_PUSH_FAILED + 1 ))
    fi
  done <<_PUSH_
$nodes
_PUSH_
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
  local reset="${2:-0}"
  local work_tmp="${MERV_MAC_DB_ACTIVE}.merge.$$"
  local jffs_tmp="${MERV_MAC_DB_JFFS}.tmp.$$"
  local entry_count cksum_new cksum_old

  mkdir -p "$(dirname "$MERV_MAC_DB_ACTIVE")" 2>/dev/null || true

  {
    # Reset mode: snapshot only → new db. Normal mode: old db + snapshot → merge.
    [ "$reset" != "1" ] && [ -f "$MERV_MAC_DB_ACTIVE" ] && cat "$MERV_MAC_DB_ACTIVE" 2>/dev/null
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

  [ "${MERV_MAC_SNAPSHOT_VERBOSE:-0}" = "1" ] && _merv_mac_logv info "MERV_MAC: db merged — ${entry_count} entries"

  # JFFS checkpoint: compare structural fingerprint (mac+iface+vid) only.
  # Timestamps are refreshed on every snapshot, so a raw md5 would always
  # differ even when the same clients are on the same VLANs. We write to
  # JFFS only when the MAC set or their iface/VID assignments actually change.
  mkdir -p "$(dirname "$MERV_MAC_DB_JFFS")" 2>/dev/null || true
  cksum_new=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  cksum_old=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_JFFS"   2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  if [ "$cksum_new" != "$cksum_old" ]; then
    if cp "$MERV_MAC_DB_ACTIVE" "$jffs_tmp" 2>/dev/null && \
       mv "$jffs_tmp" "$MERV_MAC_DB_JFFS" 2>/dev/null; then
      _merv_mac_log info "MERV_MAC: JFFS checkpoint updated (${entry_count} entries)"
    else
      rm -f "$jffs_tmp" 2>/dev/null
      _merv_mac_log warn "MERV_MAC: JFFS checkpoint update failed; active db remains valid but reboot may restore an older checkpoint"
    fi
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

  # Don't pile on a running apply — but never let a CRASHED manager (stale lock
  # directory with a dead/absent PID) suppress MERV_MAC-triggered recovery
  # forever. Use the shared lock-state helper; fall back to the blunt check if
  # lib_mervqt is somehow not loaded in this context.
  if type merv_lock_state >/dev/null 2>&1; then
    case "$(merv_lock_state "$LOCKDIR/mervlan_manager.lock")" in
      active|unknown_recent)
        info -c vlan "MERV_MAC: precondition fail — heal not queued (mervlan_manager active)"
        return 0
        ;;
      stale)
        warn -c vlan "MERV_MAC: mervlan_manager.lock stale — ignoring for heal trigger"
        ;;
    esac
  elif [ -d "$LOCKDIR/mervlan_manager.lock" ]; then
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
# _merv_mac_set_counts
# Stamp all count-style status globals from the current merv_mac_snapshot
# locals. MUST be called only from within merv_mac_snapshot (it reads that
# function's locals via POSIX dynamic scope) and immediately before any return
# that occurs AFTER the local/node counts are known, so inline callers
# (mac_refresh.sh) always read a coherent snapshot of what happened.
# Not meaningful from any other caller.
# ============================================================================
_merv_mac_set_counts() {
  MERV_MAC_LAST_LOCAL_COUNT=${client_count:-0}
  MERV_MAC_LAST_NODE_COUNT=${_node_total:-0}
  MERV_MAC_LAST_TOTAL_COUNT=${total_count:-0}
  MERV_MAC_LAST_NODES_TOTAL=${_nodes_total:-0}
  MERV_MAC_LAST_NODES_OK=${_nodes_ok:-0}
  MERV_MAC_LAST_NODES_FAILED=${_nodes_failed:-0}
  MERV_MAC_LAST_DB_COUNT=$(wc -l < "$MERV_MAC_DB_ACTIVE" 2>/dev/null | tr -d ' ')
  MERV_MAC_LAST_DB_COUNT=${MERV_MAC_LAST_DB_COUNT:-0}
}

# ============================================================================
# merv_mac_snapshot
# Full snapshot orchestration. Called from an async subshell after the
# post_rc_watchdog correction window closes (cron/manager), or inline from the
# manual MAC Refresh (mac_refresh.sh) which reads the MERV_MAC_LAST_* globals.
#
# Behaviour flags (env, normalized once at entry):
#   MERV_MAC_SNAPSHOT_RESET        — rebuild db from snapshot only (no old fold-in)
#   MERV_MAC_SNAPSHOT_ALLOW_EMPTY  — allow committing an intentionally empty db
#   MERV_MAC_SNAPSHOT_FORCE_RELOAD — reapply shield even when MAC set unchanged
#                                    (implied by RESET)
#   MERV_MAC_SNAPSHOT_VERBOSE      — step-trace logging
#   MERV_MAC_SNAPSHOT_LOG_CHANNELS — log channel set (default vlan; manual cli,vlan)
#   MERV_MAC_SNAPSHOT_LOG_UNCHANGED— log even on unchanged cron ticks
#
# Safety: destructive reset (snapshot-only rebuild / intentional empty clear)
# happens ONLY on a complete cluster observation — all configured nodes
# collected, SSH toolchain present, zero collection failures. Any incompleteness
# downgrades to a non-destructive merge while still honouring the reload intent.
#
# Steps:
#   1. Lock + precondition check
#   2. Build local snapshot
#   3. Cluster collect (track ok/failed/incomplete)
#   4. Derive effective reset (downgrade to merge if observation incomplete)
#   5. Empty handling (intentional clear vs preserve)
#   6. Merge (reset or fold-in) + fingerprint diff
#   7. Reload local shield on change OR force-reload; push to nodes
#   8. Set MERV_MAC_LAST_* status globals + summary log
# ============================================================================
merv_mac_snapshot() {
  [ "${DRY_RUN:-no}" = "yes" ] && return 0

  # --- Snapshot mutual-exclusion (unified lock primitives) -----------------
  # A single mac_snapshot.lock serializes every MAC snapshot path: the cron
  # tick (heal_event.sh), the post-apply async snapshot (mervlan_manager.sh)
  # and the manual MAC Refresh (mac_refresh.sh). This function now owns the
  # entire destructive critical section (reset/empty clear happen here), so
  # callers no longer pre-acquire this lock — we take it non-blocking and skip
  # the tick on contention. Best-effort: if the lock primitives are unavailable
  # we proceed unguarded rather than block a security-relevant rebuild.
  local _snap_lock="${LOCKDIR:-/tmp/mervlan_tmp/locks}/mac_snapshot.lock"
  local _snap_owned=0
  if type merv_lock_acquire >/dev/null 2>&1; then
    if merv_lock_acquire "$_snap_lock" "${MERV_MAC_SNAPSHOT_LOCK_STALE_SEC:-60}" 0 "mac_snapshot"; then
      _snap_owned=1
    else
      # Pre-build return: counts legitimately stay at their zero-init values —
      # nothing was observed. Do NOT call _merv_mac_set_counts here.
      MERV_MAC_LAST_STATUS="busy"
      _merv_mac_logv info "MERV_MAC: snapshot skipped — another snapshot/refresh in progress"
      return 0
    fi
  fi

  # --- Reset per-run status globals ----------------------------------------
  MERV_MAC_LAST_STATUS="";  MERV_MAC_LAST_REASON=""
  MERV_MAC_LAST_LOCAL_COUNT=0; MERV_MAC_LAST_NODE_COUNT=0
  MERV_MAC_LAST_TOTAL_COUNT=0; MERV_MAC_LAST_DB_COUNT=0
  MERV_MAC_LAST_CHANGED=0
  MERV_MAC_LAST_NODES_TOTAL=0; MERV_MAC_LAST_NODES_OK=0; MERV_MAC_LAST_NODES_FAILED=0
  MERV_MAC_LAST_PUSH_TOTAL=0;  MERV_MAC_LAST_PUSH_OK=0;  MERV_MAC_LAST_PUSH_FAILED=0

  # --- Normalize boolean flags once (use _snap_* locals throughout) --------
  local _snap_reset _snap_allow_empty _snap_verbose _snap_log_unchanged _snap_force_reload
  case "${MERV_MAC_SNAPSHOT_RESET:-0}"         in 1|yes|true|on) _snap_reset=1         ;; *) _snap_reset=0         ;; esac
  case "${MERV_MAC_SNAPSHOT_ALLOW_EMPTY:-0}"   in 1|yes|true|on) _snap_allow_empty=1   ;; *) _snap_allow_empty=0   ;; esac
  case "${MERV_MAC_SNAPSHOT_VERBOSE:-0}"       in 1|yes|true|on) _snap_verbose=1       ;; *) _snap_verbose=0       ;; esac
  case "${MERV_MAC_SNAPSHOT_LOG_UNCHANGED:-0}" in 1|yes|true|on) _snap_log_unchanged=1 ;; *) _snap_log_unchanged=0 ;; esac
  # RESET implies FORCE_RELOAD (user clicked refresh → reapply regardless of
  # whether the rebuilt MAC set differs). Otherwise honour the explicit flag.
  if [ "$_snap_reset" = "1" ]; then
    _snap_force_reload=1
  else
    case "${MERV_MAC_SNAPSHOT_FORCE_RELOAD:-0}" in 1|yes|true|on) _snap_force_reload=1 ;; *) _snap_force_reload=0 ;; esac
  fi

  if ! merv_mac_snapshot_preconditions_ok; then
    # Pre-build return: counts stay zero-init (no observation occurred).
    MERV_MAC_LAST_STATUS="precondition_failed"
    MERV_MAC_LAST_REASON="interfaces_not_settled"
    _merv_mac_log warn "MERV_MAC: snapshot skipped — interfaces not fully settled (db unchanged)"
    merv_mac_maybe_trigger_heal_on_precondition_fail
    [ "$_snap_owned" = 1 ] && merv_lock_release "$_snap_lock"
    return 0
  fi

  local snap_tmp="${MERV_MAC_DB_ACTIVE}.snap.$$"
  local client_count
  client_count=$(merv_mac_build_snapshot "$snap_tmp")
  _merv_mac_logv info "MERV_MAC: local snapshot captured ${client_count:-0} record(s)"

  # --- Cluster collection --------------------------------------------------
  # When running on the main with node sync enabled, gather client MACs from
  # every configured node and fold them into this snapshot. Node failures are
  # non-fatal for protection but DO mark the observation incomplete, which
  # blocks any destructive reset below.
  local _nodes="" _nodes_total=0 _nodes_ok=0 _nodes_failed=0 _node_total=0
  local _node_collect_incomplete=0
  if [ "${MERV_MAC_NODE_SYNC:-1}" = "1" ] && merv_mac_is_main; then
    _nodes=$(merv_mac_node_list)
    if [ -n "$_nodes" ]; then
      # Nodes are configured (read from settings.json, no SSH needed). If the
      # SSH toolchain is unavailable we cannot observe them at all — treat that
      # as an incomplete cluster observation, NOT as "zero failures".
      if ! ssh_keys_effectively_installed || [ -z "${SSH_KEY:-}" ] || [ ! -f "${SSH_KEY:-}" ]; then
        _node_collect_incomplete=1
        _merv_mac_log warn "MERV_MAC: node sync on with configured node(s) but SSH keys unavailable — cluster observation incomplete"
      else
        local _nid _nip _node_recs _rc
        while read -r _nid _nip; do
          [ -n "$_nip" ] || continue
          _nodes_total=$(( _nodes_total + 1 ))
          if _node_recs=$(merv_mac_collect_from_node "$_nid" "$_nip"); then
            _nodes_ok=$(( _nodes_ok + 1 ))
            if [ -n "$_node_recs" ]; then
              printf '%s\n' "$_node_recs" >> "$snap_tmp"
              _rc=$(printf '%s\n' "$_node_recs" | wc -l | tr -d ' ')
              _node_total=$(( _node_total + _rc ))
              _merv_mac_logv info "MERV_MAC: node ${_nip} — ${_rc} record(s)"
            else
              _merv_mac_logv info "MERV_MAC: node ${_nip} — 0 records"
            fi
          else
            _nodes_failed=$(( _nodes_failed + 1 ))
            _merv_mac_logv warn "MERV_MAC: node ${_nip} — SSH/collector failed"
          fi
        done <<_NODES_
$_nodes
_NODES_
      fi
    fi
  fi

  # --- Derive effective reset ----------------------------------------------
  # User intent is _snap_reset, but destructive (snapshot-only) behaviour only
  # executes on a COMPLETE cluster observation. Any node collection failure or
  # an unobservable cluster downgrades to merge mode so older cluster MACs from
  # the existing db are preserved. _snap_force_reload stays tied to _snap_reset
  # so the shield is still reapplied at the user's request.
  local _effective_reset=0
  if [ "$_snap_reset" = "1" ]; then
    if [ "${_nodes_failed:-0}" -gt 0 ] || [ "${_node_collect_incomplete:-0}" -eq 1 ]; then
      _effective_reset=0
      MERV_MAC_LAST_REASON="incomplete_node_observation"
      _merv_mac_log warn "MERV_MAC: reset requested but cluster observation incomplete — falling back to merge mode to preserve cluster MACs"
    else
      _effective_reset=1
    fi
  fi

  local total_count
  total_count=$(wc -l < "$snap_tmp" 2>/dev/null | tr -d ' ')

  # --- Empty snapshot handling ---------------------------------------------
  if [ "${total_count:-0}" -eq 0 ]; then
    if [ "$_effective_reset" = "1" ] && [ "$_snap_allow_empty" = "1" ]; then
      # Complete observation (effective reset survived the completeness gate),
      # zero clients found, and the caller permits an empty commit. Clear both
      # active db and JFFS checkpoint so a reboot does not resurrect old MACs.
      # Active-db clear is enforcement-critical → hard failure path. JFFS clear
      # is reboot persistence only → warning on failure.
      local _ae_act _ae_jffs _jffs_clear_ok
      _ae_act="${MERV_MAC_DB_ACTIVE}.empty.$$"
      mkdir -p "$(dirname "$MERV_MAC_DB_ACTIVE")" 2>/dev/null || true
      if : > "$_ae_act" && mv "$_ae_act" "$MERV_MAC_DB_ACTIVE" 2>/dev/null; then
        mkdir -p "$(dirname "$MERV_MAC_DB_JFFS")" 2>/dev/null || true
        _ae_jffs="${MERV_MAC_DB_JFFS}.empty.$$"
        _jffs_clear_ok=0
        if : > "$_ae_jffs" && mv "$_ae_jffs" "$MERV_MAC_DB_JFFS" 2>/dev/null; then
          _jffs_clear_ok=1
        else
          rm -f "$_ae_jffs" 2>/dev/null
          _merv_mac_log warn "MERV_MAC: reset — JFFS checkpoint clear failed; active db remains valid but reboot may restore an older checkpoint"
        fi
        ebt_mac_shield_init_and_apply "$MERV_MAC_DB_ACTIVE"
        MERV_MAC_LAST_STATUS="empty"; MERV_MAC_LAST_REASON="reset_no_clients"
        _merv_mac_set_counts
        MERV_MAC_LAST_DB_COUNT=0
        if [ "$_jffs_clear_ok" = "1" ]; then
          _merv_mac_log info "MERV_MAC: reset — no clients present; active db and JFFS checkpoint cleared"
        else
          _merv_mac_log info "MERV_MAC: reset — no clients present; active db cleared; JFFS checkpoint not updated"
        fi
      else
        rm -f "$_ae_act" 2>/dev/null
        MERV_MAC_LAST_STATUS="clear_failed"; MERV_MAC_LAST_REASON="active_db_write_error"
        _merv_mac_set_counts
        _merv_mac_log warn "MERV_MAC: reset — failed to clear active db; existing db preserved"
      fi
    elif [ "$_snap_reset" = "1" ] && [ "$_snap_allow_empty" = "1" ]; then
      # Reset+allow-empty requested but observation incomplete (effective reset
      # was downgraded): zero records is not proof the cluster is empty. Preserve.
      MERV_MAC_LAST_STATUS="empty"; MERV_MAC_LAST_REASON="incomplete_node_observation"
      _merv_mac_set_counts
      _merv_mac_log warn "MERV_MAC: reset — zero records but cluster observation incomplete; db preserved"
    else
      # Cron/normal: zero records may be sleeping/roaming clients. Preserve db.
      MERV_MAC_LAST_STATUS="empty"; MERV_MAC_LAST_REASON="preserved_db"
      _merv_mac_set_counts
      _merv_mac_log info "MERV_MAC: snapshot empty — preserving existing db (entries age out naturally)"
    fi
    rm -f "$snap_tmp" 2>/dev/null
    [ "$_snap_owned" = 1 ] && merv_lock_release "$_snap_lock"
    return 0
  fi

  # --- Merge + fingerprint diff --------------------------------------------
  # Compare structural fingerprint (mac+iface+vid only, timestamps excluded).
  # Raw md5 would always differ because timestamps refresh on every snapshot.
  local _pre_fp _post_fp
  _pre_fp=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)
  merv_mac_merge_db "$snap_tmp" "$_effective_reset" || {
    MERV_MAC_LAST_STATUS="merge_failed"
    _merv_mac_set_counts
    rm -f "$snap_tmp" 2>/dev/null
    [ "$_snap_owned" = 1 ] && merv_lock_release "$_snap_lock"
    return 1
  }
  rm -f "$snap_tmp" 2>/dev/null
  _post_fp=$(awk '{print $2, $3, $4}' "$MERV_MAC_DB_ACTIVE" 2>/dev/null | sort | md5sum 2>/dev/null | cut -d' ' -f1)

  # --- Status: honest distinction between changed / reloaded / unchanged ----
  if [ "$_pre_fp" != "$_post_fp" ]; then
    MERV_MAC_LAST_CHANGED=1
    MERV_MAC_LAST_STATUS="changed"
  elif [ "$_snap_force_reload" = "1" ]; then
    MERV_MAC_LAST_CHANGED=0
    MERV_MAC_LAST_STATUS="reloaded"   # shield reapplied, MAC set identical
  else
    MERV_MAC_LAST_CHANGED=0
    MERV_MAC_LAST_STATUS="unchanged"
  fi

  # Reload fires for a real change OR an explicit force-reload. Push to nodes
  # whenever we reload, so every unit's shield is reapplied/repaired.
  if [ "$MERV_MAC_LAST_CHANGED" = "1" ] || [ "$_snap_force_reload" = "1" ]; then
    ebt_mac_shield_init_and_apply "$MERV_MAC_DB_ACTIVE"
    if [ -n "$_nodes" ]; then
      MERV_MAC_LAST_PUSH_TOTAL=0; MERV_MAC_LAST_PUSH_OK=0; MERV_MAC_LAST_PUSH_FAILED=0
      merv_mac_push_db_to_nodes "$_nodes"
    fi
  else
    _merv_mac_logv info "MERV_MAC: MAC set unchanged — ebtables rules not rebuilt"
  fi

  _merv_mac_set_counts

  # --- Summary log: meaningful events only ---------------------------------
  # Log on change, any node collection failure, or when explicitly requested
  # (LOG_UNCHANGED / verbose). Keeps stable cron ticks silent.
  if [ "${MERV_MAC_LAST_CHANGED:-0}" = "1" ] || \
     [ "${MERV_MAC_LAST_NODES_FAILED:-0}" -gt 0 ] || \
     [ "$_snap_log_unchanged" = "1" ] || \
     [ "$_snap_verbose" = "1" ]; then
    _merv_mac_log info "MERV_MAC: snapshot ${MERV_MAC_LAST_STATUS} — local=${MERV_MAC_LAST_LOCAL_COUNT} node=${MERV_MAC_LAST_NODE_COUNT} total=${MERV_MAC_LAST_TOTAL_COUNT} db=${MERV_MAC_LAST_DB_COUNT} nodes=${MERV_MAC_LAST_NODES_OK}/${MERV_MAC_LAST_NODES_TOTAL} push=${MERV_MAC_LAST_PUSH_OK}/${MERV_MAC_LAST_PUSH_TOTAL}"
  fi

  [ "$_snap_owned" = 1 ] && merv_lock_release "$_snap_lock"
}

LIB_MAC_SHIELD_SNAPSHOT_LOADED=1
