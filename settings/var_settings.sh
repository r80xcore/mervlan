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
#                - File: var_settings.sh || version="0.52"                     #
# ============================================================================ #
# - Purpose:    Define folder paths and environment variables used             #
#               throughout the MerVLAN addon.                                  #
# ============================================================================ #
[ -n "${VAR_SETTINGS_LOADED:-}" ] && return 0 2>/dev/null
# Only set if not already set (allows override for testing)
: "${MERV_BASE:?MERV_BASE must be set before sourcing folder_settings.sh}"

# ---- merv: portable `command -v` replacement ----
# merv_has <name> : true if <name> exists as function/builtin/external
# merv_cmd <name> : prints PATH-resolved executable (external only); fails if not found
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

# Folders
readonly SCRIPTS_DIR="/jffs/scripts"
readonly TMPDIR="/tmp/mervlan_tmp"
readonly LOGDIR="$TMPDIR/logs"
readonly FUNCDIR="$MERV_BASE/functions"
readonly SETTINGSDIR="$MERV_BASE/settings"
readonly FLAGDIR="$MERV_BASE/flags"
readonly PUBLIC_MERV_BASE="/www/user/mervlan"
readonly PUBLIC_SETTINGS_DIR="${PUBLIC_MERV_BASE}/settings"
readonly PUBLIC_SETTINGS_FILE="${PUBLIC_SETTINGS_DIR}/settings.json"
readonly LOCKDIR="$TMPDIR/locks"
readonly RESULTDIR="$TMPDIR/results"
readonly CHANGES="$TMPDIR/results/vlan_changes"
readonly COLLECTDIR="$TMPDIR/client_collection"

# ============================================================================
# MERV_MAC — per-client L2 secondary shield
# ============================================================================
: "${MERV_MAC_CHAIN:=MERV_MAC}"
: "${MERV_MAC_DB_ACTIVE:=$TMPDIR/mac_shield.db}"
: "${MERV_MAC_DB_JFFS:=$MERV_BASE/tmp/mac_shield.db}"
: "${MERV_MAC_MAX_AGE_SEC:=$((48 * 3600))}"
: "${MAC_SHIELD_VERBOSE:=0}"  # 0 = silent on stable ticks; 1 = log every tick
# Cross-node MAC shield sync. When 1 (default) the main collects client MACs
# from every configured node during each snapshot, merges them into one db, and
# pushes the merged db back to the nodes so a device known to ANY unit is
# blocked on br0 across the whole mesh. Set 0 to keep each unit's shield local
# (e.g. when SSH keys are not installed or isolated per-node dbs are desired).
: "${MERV_MAC_NODE_SYNC:=1}"

# Override DB: suppresses the MERV_MAC DROP rule for listed MACs.
# Applies cluster-wide: pushed to nodes wherever the MAC shield DB is enforced.
# MACs remain in mac_shield.db; removing an override re-locks on next reload.
: "${MERV_MAC_OVERRIDE_DB:=$MERV_BASE/tmp/mac_shield_override.db}"

# Client name DB: tab-separated "mac<TAB>name". Display-only, main-router only.
# Not pushed to nodes (annotation happens after merged client collection).
: "${MERV_CLIENT_NAME_DB:=$MERV_BASE/tmp/client_name_override.db}"

# ============================================================================
# L2 guard chains — canonical names shared by manager, heal, snapshot, lib
# Defined here (not per-script) so every consumer of lib_mervqt.sh resolves the
# same chain names without divergence. Use ':=' so an explicit env override
# (e.g. for testing) still wins.
# ============================================================================
: "${MERV_QT_CHAIN:=MERV_QT}"                 # L2 quarantine chain (VLAN VAPs in br0)
: "${MERV_DHCP_HOLD_CHAIN:=MERV_DHCP_HOLD}"   # critical-section DHCP kill switch

# Stale-lock reclaim threshold for mervlan_manager.lock. A crashed/killed
# manager leaves its lock directory behind; without age-based reclaim every
# subsequent heal and MERV_MAC recovery would skip forever. 420s (7 min) is
# safely past the longest possible live apply (~3 min incl. node execution)
# while not leaving crashed-manager locks blocking new runs for too long.
: "${MERV_MANAGER_LOCK_STALE_SEC:=420}"

# Stale-lock reclaim threshold for heal_event.sh's vlan_event.lock. Heal fires
# the manager in the background and exits, so it only holds this lock for its
# own pre-checks (wait_for_rc_quiet up to ~120s + checks), never for the full
# manager run. 180s (3 min) safely covers the worst-case heal pass while
# reclaiming a crashed heal's lock quickly. (NOTE: the service-event-handler
# keeps its own local lock timers on purpose — it must stay dependency-free in
# the DHCP-sensitive hot path and is not driven by this value.)
: "${MERV_HEAL_LOCK_STALE_SEC:=180}"

# Stale-lock reclaim threshold for sync_nodes.sh and mac_refresh.sh self-locks.
# Both are non-blocking (skip-on-contention) so this only governs how long a
# CRASHED run's lock blocks the next legitimate run. sync_nodes uses tar-batch
# SSH so a full multi-node push completes in ~10s; 60s gives 2× headroom while
# recovering from crashes quickly.
: "${MERV_SYNC_LOCK_STALE_SEC:=60}"
: "${MERV_MAC_REFRESH_LOCK_STALE_SEC:=60}"

# Stale-lock reclaim threshold for the unified mac_snapshot.lock. This single
# lock serializes every MAC snapshot path — the cron tick (heal_event.sh), the
# post-apply async snapshot (mervlan_manager.sh) and the manual MAC Refresh
# (mac_refresh.sh) — so the destructive refresh rebuild can never interleave
# with a concurrent snapshot. All holders are non-blocking (skip / retry on
# contention), so this only governs how long a CRASHED holder's lock blocks the
# next run. A full cross-node collect+push over SSH can reach ~60s worst case
# (3 retries × 10s timeout × collect+push per node); 120s gives headroom for
# slow nodes while still reclaiming crashed holders within 2 minutes.
: "${MERV_MAC_SNAPSHOT_LOCK_STALE_SEC:=120}"

# Maximum lifetime of the boot-time DHCP shield watchdog spawned by
# mervlan_boot_wrap.sh shield. Hard ceiling — when this elapses the shield
# tears down even if the manager never cleared its marker. Start conservative
# (120s) so a failed boot apply doesn't keep DHCP blocked for 10 minutes while
# debugging; raise once the boot path is proven stable.
: "${MERV_BOOT_SHIELD_MAX_SEC:=120}"

# Scripts & Configs
readonly BOOT_SCRIPT="$FUNCDIR/mervlan_boot.sh"
readonly HW_PROBE="$FUNCDIR/hw_probe.sh"
readonly LOG_SETTINGS="$SETTINGSDIR/log_settings.sh"
readonly SSH_KEY="$MERV_BASE/.ssh/vlan_manager"
readonly SSH_PUBKEY="$MERV_BASE/.ssh/vlan_manager.pub"
readonly DROPBEARKEY="/usr/bin/dropbearkey"
readonly SETTINGS_FILE="$SETTINGSDIR/settings.json"
## Hardware settings are now stored in the consolidated settings.json under
## the "Hardware" block. Keep `HW_SETTINGS_FILE` as a compatibility alias
## so existing callers (that expect a path) continue to resolve to a file
## path while the new storage remains a sub-block inside the same JSON.
readonly HW_SETTINGS_FILE="$SETTINGSDIR/settings.json"
readonly OUT_FINAL="$RESULTDIR/vlan_clients.json"
readonly VLAN_MANAGER="$FUNCDIR/mervlan_manager.sh"
readonly SERVICE_EVENT="$FUNCDIR/heal_event.sh"
readonly SYNC_NODES="$FUNCDIR/sync_nodes.sh"
readonly CUSTOM_SETTINGS_FILE="/jffs/addons/custom_settings.txt"
readonly SERVICE_EVENT_HANDLER="$FUNCDIR/service-event-handler.sh"
readonly TEMPLATE_LIB="$MERV_BASE/templates/mervlan_templates.sh"
readonly TEMPLATE_SERVICES="services-start"
readonly TEMPLATE_SERVICE_EVENT="service-event"
readonly TEMPLATE_SERVICE_EVENT_NODES="service-event-nodes"
readonly TEMPLATE_SERVICES_ADDON="services-start-addon"
readonly SERVICES_START="$SCRIPTS_DIR/services-start"
readonly SERVICE_EVENT_WRAPPER="$SCRIPTS_DIR/service-event"

# Logs
readonly LOGFILE="$LOGDIR/mervlan.log"
readonly CLI_LOG="$LOGDIR/cli_output.log"

# Maximum number of supported satellite nodes (NODE1..NODE<MERV_MAX_NODES>).
: "${MERV_MAX_NODES:=10}"

# merv_is_valid_node_id <id> : true if <id> is an integer in 1..MERV_MAX_NODES.
merv_is_valid_node_id() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le "$MERV_MAX_NODES" ] 2>/dev/null
}


# Flag: settings loaded
VAR_SETTINGS_LOADED=1
