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
#          - File: service-event-handler.sh || version="0.62"                  #
# ============================================================================ #
# - Purpose:    Event handler for http and service events                      #
# ============================================================================ #

# ========================================================================== #
# BASIC INITIALIZATION                                                       #
# ========================================================================== #

: "${MERV_BASE:=/jffs/addons/mervlan}"

# ========================================================================== #
# HANDLER TUNABLES (self-contained)                                          #
# ========================================================================== #
# All timing knobs for this handler live here so they can be found and tuned
# in one place. These are deliberately NOT sourced from settings/var_settings.sh:
# the handler runs in the DHCP-sensitive hot path and must stay dependency-free
# and lightweight. Each uses ${VAR:-default} so an env override still wins for
# testing.
#
#   LOCKDIR              — shared lock/stamp directory (matches var_settings.sh)
#   DEBOUNCE_SECONDS     — reject the same event re-firing within this window
#   STALE_LOCK_SECONDS   — reclaim a held .lock left behind by a crashed script.
#                          Must exceed the longest script this handler launches.
#   MERV_HEAL_EVENT_DEBOUNCE — handler-level debounce for heal storms (rc floods)
#   MERV_HEAL_DELAY      — fire-and-forget delay before launching heal_event.sh
#                          for non-wireless system events
LOCKDIR="${LOCKDIR:-/tmp/mervlan_tmp/locks}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-3}"
STALE_LOCK_SECONDS="${STALE_LOCK_SECONDS:-300}"
MERV_HEAL_EVENT_DEBOUNCE="${MERV_HEAL_EVENT_DEBOUNCE:-5}"
MERV_HEAL_DELAY="${MERV_HEAL_DELAY:-3}"

# ========================================================================== #
# PARAMETER EXTRACTION & VALIDATION — Parse event action from arguments      #
# ========================================================================== #

# Extract primary action name from arguments ($1 preferred, $2 fallback)
# Example: "save_vlanmgr" from first argument, or from second if first empty
RAW="$1"
SECOND="$2"

# Fallback logic: if RAW is empty but SECOND is provided, use SECOND as action
# Handles cases where first arg is empty/missing but second contains the event
if [ -z "${RAW}" ] && [ -n "${SECOND}" ]; then
  RAW="${SECOND}"
fi

# Exit early if no action was provided in any argument position
# Log the missing action for diagnostic purposes before exit
if [ -z "${RAW}" ]; then
  logger -t "VLANMgr" "handler: no action provided (args: '$1' '$2' '$3')"
  exit 0
fi

# Normalize action format: convert dashes to underscores for case matching
# Example: "save-vlanmgr" becomes "save_vlanmgr" (case statement uses underscores)
RAW_NORM="$(printf '%s' "$RAW" | tr '-' '_')"

# ========================================================================== #
# EVENT PARSING — Extract TYPE and EVENT components from action string       #
# ========================================================================== #

# Parse TYPE and EVENT from RAW action using pattern: TYPE_EVENT
# Two formats supported:
#   1. ACTION already contains underscore: TYPE_EVENT (e.g., "save_vlanmgr")
#   2. ACTION is single word: use TYPE=$1, EVENT=$2 (e.g., "restart" + "$2")
# After parsing, reconstruct RAW as TYPE_EVENT for consistency
case "${RAW}" in
  *_*)
    # Format 1: action already contains underscore (TYPE_EVENT pattern)
    # Extract TYPE as everything before first underscore (${RAW%%_*})
    # Extract EVENT as everything after first underscore (${RAW#*_})
    TYPE="${RAW%%_*}"
    EVENT="${RAW#*_}"
    ;;
  *)
    # Format 2: single-word action, EVENT is separate argument
    # Set TYPE to the action, EVENT to second argument, reconstruct RAW
    TYPE="${RAW}"
    EVENT="${SECOND}"
    RAW="${TYPE}_${EVENT}"
    ;;
esac

# Build combined normalized name for downstream heal handlers
TYPE_NORM=$(printf '%s' "$TYPE" | tr 'A-Z' 'a-z' | tr '-' '_')
EVENT_NORM=$(printf '%s' "$EVENT" | tr 'A-Z' 'a-z' | tr '-' '_')
if [ -n "$EVENT_NORM" ]; then
  COMBINED_NORM="${TYPE_NORM}_${EVENT_NORM}"
else
  COMBINED_NORM="$TYPE_NORM"
fi
COMBINED_NORM=$(printf '%s' "$COMBINED_NORM" | tr -s '_' '_' | sed 's/^_//; s/_$//')

# Log parsed event details for audit trail (helps with debugging)
logger -t "VLANMgr" "handler: RAW='${RAW}' TYPE='${TYPE}' EVENT='${EVENT}' (args: '$1' '$2' '$3')"

# ========================================================================== #
# NODE GUARD — Block MerVLAN UI/API events on nodes                          #
# ========================================================================== #

SETTINGS_FILE="/jffs/addons/mervlan/settings/settings.json"
CUSTOM_SETTINGS_FILE="/jffs/addons/custom_settings.txt"

get_action_request_token() {
  grep '^vlanmgr_action_request_token=' "$CUSTOM_SETTINGS_FILE" 2>/dev/null | \
    tail -n1 | cut -d'=' -f2- | \
    tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-'
}

decode_hex_ascii() {
  _dha_hex="$1"
  case "$_dha_hex" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ $(( ${#_dha_hex} % 2 )) -eq 0 ] || return 1
  _dha_escaped=""
  while [ -n "$_dha_hex" ]; do
    _dha_pair="${_dha_hex%${_dha_hex#??}}"
    _dha_hex="${_dha_hex#??}"
    _dha_oct=$(printf '%03o' "$((0x$_dha_pair))") || return 1
    _dha_escaped="${_dha_escaped}\\${_dha_oct}"
  done
  printf '%b' "$_dha_escaped"
}

get_verified_action_token() {
  _vat_action="$1"
  _vat_base="$2"
  _vat_hex="${_vat_action#${_vat_base}_vrt_}"
  [ "$_vat_hex" != "$_vat_action" ] || return 1
  _vat_token=$(decode_hex_ascii "$_vat_hex") || return 1
  _vat_clean=$(printf '%s' "$_vat_token" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
  [ -n "$_vat_token" ] && [ "$_vat_clean" = "$_vat_token" ] || return 1
  printf '%s\n' "$_vat_token"
}

decode_update_ref_action() {
  _ura_encoded="${1#updateref_vlanmgr_}"
  _ura_policy=keep
  _ura_kind="${_ura_encoded%%_*}"
  _ura_hex="${_ura_encoded#*_}"
  [ "$_ura_hex" != "$_ura_encoded" ] || return 1
  case "$_ura_kind" in
    k|c)
      [ "$_ura_kind" = "c" ] && _ura_policy=clear
      _ura_encoded="$_ura_hex"
      _ura_kind="${_ura_encoded%%_*}"
      _ura_hex="${_ura_encoded#*_}"
      [ "$_ura_hex" != "$_ura_encoded" ] || return 1
      ;;
  esac
  case "$_ura_kind" in h|t) ;; *) return 1 ;; esac
  _ura_name=$(decode_hex_ascii "$_ura_hex") || return 1
  _ura_clean=$(printf '%s' "$_ura_name" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-')
  [ -n "$_ura_name" ] && [ "$_ura_clean" = "$_ura_name" ] || return 1
  case "$_ura_name" in *..*|*//*|/*|*/|.*|*.lock) return 1 ;; esac

  case "$_ura_kind" in
    h) printf 'refs/heads/%s|%s\n' "$_ura_name" "$_ura_policy" ;;
    t) case "$_ura_name" in v[0-9]*) printf 'refs/tags/%s|%s\n' "$_ura_name" "$_ura_policy" ;; *) return 1 ;; esac ;;
  esac
}

decode_maintenance_action() {
  _dma_action="$1"
  _dma_base="$2"
  _dma_payload_required="$3"
  _dma_encoded="${_dma_action#${_dma_base}_}"
  [ "$_dma_encoded" != "$_dma_action" ] || return 1
  _dma_token_hex="${_dma_encoded%%_*}"
  if [ "$_dma_encoded" = "$_dma_token_hex" ]; then
    _dma_payload_hex=""
  else
    _dma_payload_hex="${_dma_encoded#*_}"
  fi
  [ -n "$_dma_token_hex" ] && [ "${#_dma_token_hex}" -le 64 ] || return 1
  _dma_token=$(decode_hex_ascii "$_dma_token_hex") || return 1
  _dma_token_clean=$(printf '%s' "$_dma_token" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
  [ -n "$_dma_token" ] && [ "$_dma_token" = "$_dma_token_clean" ] || return 1
  if [ "$_dma_payload_required" = "1" ]; then
    [ -n "$_dma_payload_hex" ] && [ "${#_dma_payload_hex}" -le 320 ] || return 1
    _dma_payload=$(decode_hex_ascii "$_dma_payload_hex") || return 1
  else
    [ -z "$_dma_payload_hex" ] || return 1
    _dma_payload=""
  fi
  printf '%s|%s\n' "$_dma_token" "$_dma_payload"
}

decode_maintenance_archive_action() {
  _dmaa_action="$1"
  _dmaa_base="$2"
  _dmaa_encoded="${_dmaa_action#${_dmaa_base}_}"
  [ "$_dmaa_encoded" != "$_dmaa_action" ] || return 1
  _dmaa_token_hex="${_dmaa_encoded%%_*}"
  _dmaa_archive_key="${_dmaa_encoded#*_}"
  [ "$_dmaa_archive_key" != "$_dmaa_encoded" ] || return 1
  [ -n "$_dmaa_token_hex" ] && [ "${#_dmaa_token_hex}" -le 64 ] || return 1
  _dmaa_token=$(decode_hex_ascii "$_dmaa_token_hex") || return 1
  _dmaa_token_clean=$(printf '%s' "$_dmaa_token" | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
  [ -n "$_dmaa_token" ] && [ "$_dmaa_token" = "$_dmaa_token_clean" ] || return 1

  case "$_dmaa_archive_key" in
    a.*)
      _dmaa_archive_tail=${_dmaa_archive_key#a.}
      printf '%s\n' "$_dmaa_archive_tail" | grep -Eq '^[0-9]{8}-[0-9]{6}(-[0-9]+)?$' || return 1
      _dmaa_archive_id="mervlan.backup.${_dmaa_archive_tail}.tar.gz"
      ;;
    m.*)
      printf '%s\n' "$_dmaa_archive_key" | grep -Eq '^m\.[0-9]{8}-[0-9]{6}\.[A-Za-z0-9][A-Za-z0-9_-]{0,23}$' || return 1
      _dmaa_archive_tail=${_dmaa_archive_key#m.}
      _dmaa_timestamp=${_dmaa_archive_tail%%.*}
      _dmaa_tag=${_dmaa_archive_tail#*.}
      _dmaa_archive_id="mervlan.manual.backup.${_dmaa_timestamp}.${_dmaa_tag}.tar.gz"
      ;;
    *) return 1 ;;
  esac
  maintenance_archive_valid "$_dmaa_archive_id" || return 1
  printf '%s|%s\n' "$_dmaa_token" "$_dmaa_archive_id"
}

maintenance_tag_valid() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,23}$'
}

maintenance_archive_valid() {
  _mav_id="$1"
  [ "${_mav_id##*/}" = "$_mav_id" ] || return 1
  case "$_mav_id" in *..*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*) return 1 ;; esac
  printf '%s\n' "$_mav_id" | grep -Eq '^mervlan\.backup\.[A-Za-z0-9_-]+\.tar\.gz$|^mervlan\.manual\.backup\.[0-9]{8}-[0-9]{6}\.[A-Za-z0-9][A-Za-z0-9_-]{0,23}\.tar\.gz$'
}

json_get_flag() {
    key="$1"
    def="$2"
    file="${3:-$SETTINGS_FILE}"

    [ -n "$key" ] || { printf '%s\n' "$def"; return 0; }
    [ -s "$file" ] || { printf '%s\n' "$def"; return 0; }

    # Very simple: grab VALUE from "KEY": "VALUE"
    val="$(sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1)"

    [ -n "$val" ] || val="$def"
    printf '%s\n' "$val"
}

IS_NODE_FLAG=0
if [ -s "$SETTINGS_FILE" ]; then
  case "$(json_get_flag IS_NODE 0 "$SETTINGS_FILE" 2>/dev/null)" in
    1|yes|on|true)
      IS_NODE_FLAG=1
      ;;
  esac
fi

APP_EVENT=0
case "${TYPE}_${EVENT}" in
  save_vlanmgr|apply_vlanmgr|sync_vlanmgr|executenodes_vlanmgr|\
  executenodesonly_vlanmgr|genkey_vlanmgr|enableservice_vlanmgr|\
  disableservice_vlanmgr|enableservice_vlanmgr_vrt_*|disableservice_vlanmgr_vrt_*|checkservice_vlanmgr|collectclients_vlanmgr|\
  clearclilog_vlanmgr|update_vlanmgr|updatedev_vlanmgr|updaterelease_vlanmgr|updateref_vlanmgr_*|\
  backupinventory_vlanmgr_*|manualbackup_vlanmgr_*|deletebackup_vlanmgr_*|deleteallbackups_vlanmgr_*|restorebackup_vlanmgr_*|\
  undorestore_vlanmgr_*|undoupdate_vlanmgr_*|\
  hwprobe_vlanmgr|macrefresh_vlanmgr|\
  macclientmeta_vlanmgr)
    APP_EVENT=1
    ;;
esac

if [ "$IS_NODE_FLAG" -eq 1 ] && [ "$APP_EVENT" -eq 1 ]; then
  logger -t "VLANMgr" "handler: ignoring ${TYPE}_${EVENT} on node (IS_NODE=1)"
  exit 0
fi

# ========================================================================== #
# PAUSE GUARD — Suppress router-triggered events when PAUSE is active        #
# ========================================================================== #
# APP_EVENT=1 (UI buttons) always pass through so the UI remains responsive.
# APP_EVENT=0 (router-native events like wifi/eth changes) are suppressed.
if [ "$APP_EVENT" = "0" ] && [ -s "$SETTINGS_FILE" ]; then
  _pause_flag=$(json_get_flag PAUSE off "$SETTINGS_FILE" 2>/dev/null)
  if [ "$_pause_flag" = "on" ]; then
    logger -t "VLANMgr" "handler: PAUSED — suppressed router event '${RAW}'"
    exit 0
  fi
fi

# ========================================================================== #
# DEBOUNCE & LOCK SETUP — Initialize locking for concurrent execution        #
# ========================================================================== #

# Lightweight debounce/lock mechanism prevents concurrent execution of same event
# Uses directory creation as atomic lock (mkdir fails if dir exists = already locked)
# Lockdir stores both lock dirs (.lock) and timestamp files (.last) for debounce.
# Timing knobs (LOCKDIR, DEBOUNCE_SECONDS, STALE_LOCK_SECONDS) are defined in the
# HANDLER TUNABLES block at the top of this file.
# Create lock directory structure (ignore errors if it already exists)
mkdir -p "$LOCKDIR" 2>/dev/null || :

# ========================================================================== #
# LOCK METADATA HELPERS (self-contained — no lib_mervqt.sh dependency)        #
# ========================================================================== #
# These give each mkdir-based event lock the same pid+created robustness the
# central locks have, WITHOUT sourcing the shared lock library (this handler
# runs in the DHCP-sensitive hot path and must stay dependency-free). The
# metadata closes the "no-stamp orphan" gap: if a handler dies after mkdir but
# before the .last stamp is written (DEBOUNCE_SECONDS=0, SIGKILL, or /tmp full),
# later events can still tell whether the holder is alive or the lock is stale.

# _se_write_lock_meta <lock_dir>
# Record pid + created stamp in an already-acquired lock dir. Called right after
# every successful mkdir so metadata exists before anything can interrupt us.
_se_write_lock_meta() {
  echo "$$"   > "$1/pid"     2>/dev/null || :
  date +%s    > "$1/created" 2>/dev/null || :
}

# _se_cleanup_lock_dir <lock_dir>
# Remove ONLY the known metadata files, then rmdir. Never recursively deletes:
# if the dir still has unexpected contents, rmdir fails and we leave it for a
# human to inspect rather than blindly wiping it (key is event-derived input).
_se_cleanup_lock_dir() {
  rm -f "$1/pid" "$1/created" 2>/dev/null || :
  rmdir "$1" 2>/dev/null || :
}

# _se_lock_age <lock_dir>
# Seconds since the lock was created. Prefers the created stamp; falls back to
# directory mtime. Returns 0 when age is unknown OR when the clock appears to
# have moved backward (NTP step at boot), so a negative age never masks a stale
# lock as fresh.
_se_lock_age() {
  local _now _created _mtime _age
  _now=$(date +%s 2>/dev/null || echo 0)
  case "$_now" in ''|*[!0-9]*) _now=0 ;; esac

  _created=$(cat "$1/created" 2>/dev/null || echo "")
  case "$_created" in ''|*[!0-9]*) _created="" ;; esac
  if [ -n "$_created" ] && [ "$_now" -gt 0 ]; then
    _age=$(( _now - _created ))
    [ "$_age" -lt 0 ] 2>/dev/null && _age=0
    printf '%s' "$_age"
    return 0
  fi

  _mtime=$(stat -c %Y "$1" 2>/dev/null || echo 0)
  case "$_mtime" in ''|*[!0-9]*) _mtime=0 ;; esac
  if [ "$_mtime" -gt 0 ] && [ "$_now" -gt 0 ]; then
    _age=$(( _now - _mtime ))
    [ "$_age" -lt 0 ] 2>/dev/null && _age=0
    printf '%s' "$_age"
  else
    printf '0'
  fi
}

# _se_reclaim_lock_dir <lock_dir> <key>
# Clean known metadata, then re-acquire. Prints nothing; returns:
#   0 = reclaimed (caller may proceed, meta must be (re)written by caller)
#   1 = could not reclaim (foreign contents or lost race) — caller must skip
_se_reclaim_lock_dir() {
  _se_cleanup_lock_dir "$1"
  if [ -d "$1" ]; then
    logger -t "VLANMgr" "handler: ${2} lock dir not empty after cleanup — skipping"
    return 1
  fi
  if ! mkdir "$1" 2>/dev/null; then
    logger -t "VLANMgr" "handler: ${2} already running (lost reclaim race); skipping"
    return 1
  fi
  return 0
}

# ========================================================================== #
# DISPATCH HELPER FUNCTION — Execute scripts with debounce and locking       #
# ========================================================================== #

# dispatch_if_executable — Execute script with atomic locking and debounce
# Args: $1=script_path, $@=remaining_args (passed to script)
# Returns: 0 on successful execution or skip, 1+ from script execution errors
# Explanation: Uses mkdir atomic lock to prevent concurrent execution. Debounce
#   window (3s by default) prevents rapid re-execution of same event. Cleans up
#   locks on exit or signal (EXIT, INT, TERM). Logs all actions for audit.
dispatch_if_executable() {
  local SCRIPT_PATH="$1"
  shift

  # Initialize lock and timestamp tracking variables
  # key: unique identifier for this event (action name or script name)
  # lock_dir/lock_root: where filesystem locks are stored
  # stamp: where last execution timestamp is recorded (for debounce window)
  # window: debounce interval in seconds (skip re-execution within this time)
  # stale: seconds after which a held lock is considered orphaned (crashed script)
  local key lock_root lock_dir stamp now last window stale elapsed
  local _se_pid _se_age
  key="${RAW:-${SCRIPT_PATH##*/}}"
  lock_root="${LOCKDIR%/}"
  lock_dir="${lock_root}/${key}.lock"
  stamp="${lock_root}/${key}.last"
  window="${DEBOUNCE_SECONDS:-0}"
  stale="${STALE_LOCK_SECONDS:-300}"

  # Attempt to acquire lock by creating lock directory (atomic operation)
  # If mkdir fails, lock already exists (concurrent execution or recent invocation)
  if ! mkdir "$lock_dir" 2>/dev/null; then
    # Lock acquisition failed: determine whether to skip or reclaim a stale lock.
    # Two independent checks with different thresholds:
    #   DEBOUNCE (window): reject rapid re-fires (e.g. firmware double-calling hook)
    #   STALE   (stale):  reclaim locks abandoned by crashed scripts
    if [ -f "$stamp" ]; then
      now="$(date +%s 2>/dev/null || echo 0)"
      last="$(cat "$stamp" 2>/dev/null || echo 0)"
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      elapsed=$((now - last))
      if [ "$window" -gt 0 ] 2>/dev/null && [ "$elapsed" -lt "$window" ]; then
        # Still within debounce window — rapid re-fire; skip
        logger -t "VLANMgr" "handler: ${key} debounced (${elapsed}s < ${window}s); skipping"
        return 0
      elif [ "$elapsed" -lt "$stale" ]; then
        # Outside debounce but within stale threshold — script is still running; skip
        logger -t "VLANMgr" "handler: ${key} already running (${elapsed}s < stale ${stale}s); skipping"
        return 0
      else
        # Older than stale threshold — lock was abandoned by a crashed script; reclaim
        logger -t "VLANMgr" "handler: ${key} lock stale (${elapsed}s >= ${stale}s); reclaiming"
        _se_reclaim_lock_dir "$lock_dir" "$key" || return 0
      fi
    else
      # No stamp file — fall back to pid + created metadata written at acquire
      # time. This covers DEBOUNCE_SECONDS=0 (stamp never written by design), a
      # SIGKILL between mkdir and stamp write, and stamp write failures.
      _se_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
      case "$_se_pid" in ''|*[!0-9]*) _se_pid="" ;; esac
      _se_age=$(_se_lock_age "$lock_dir")
      case "$_se_age" in ''|*[!0-9]*) _se_age=0 ;; esac
      if [ -n "$_se_pid" ] && kill -0 "$_se_pid" 2>/dev/null; then
        # Holder PID is alive. Honour it UNLESS the lock has aged past the stale
        # window — on a busy router a crashed holder's PID is quickly recycled
        # by an unrelated process, so an aged live-PID lock is likely a reuse.
        if [ "$_se_age" -ge "$stale" ]; then
          logger -t "VLANMgr" "handler: ${key} live PID ${_se_pid} but age=${_se_age}s >= stale=${stale}s (likely reused); reclaiming"
          _se_reclaim_lock_dir "$lock_dir" "$key" || return 0
        else
          logger -t "VLANMgr" "handler: ${key} already running (pid=${_se_pid} live, age=${_se_age}s); skipping"
          return 0
        fi
      else
        # PID dead or absent — decide purely on lock age.
        if [ "$_se_age" -ge "$stale" ]; then
          logger -t "VLANMgr" "handler: ${key} orphaned lock (no live pid, age=${_se_age}s >= stale=${stale}s); reclaiming"
          _se_reclaim_lock_dir "$lock_dir" "$key" || return 0
        else
          logger -t "VLANMgr" "handler: ${key} young orphan lock (age=${_se_age}s < stale=${stale}s); skipping"
          return 0
        fi
      fi
    fi
  fi

  # Lock acquired (fresh, or reclaimed above) — record ownership metadata before
  # anything can interrupt us, then register the cleanup trap.
  _se_write_lock_meta "$lock_dir"

  # Lock acquired: register cleanup trap to remove lock on exit
  trap 'logger -t "VLANMgr" "handler: ${key} lock released (trap)"; _se_cleanup_lock_dir "$lock_dir"' EXIT INT TERM

  # Debounce check: if within window, skip execution (prevent rapid re-invocation)
  if [ "$window" -gt 0 ] 2>/dev/null; then
    # Get current timestamp
    now="$(date +%s 2>/dev/null || echo 0)"
    # Get last execution timestamp from file (or 0 if missing)
    if [ -f "$stamp" ]; then
      last="$(cat "$stamp" 2>/dev/null || echo 0)"
    else
      last=0
    fi
    # Validate last timestamp is numeric
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    # If within debounce window, skip execution
    if [ $((now - last)) -lt "$window" ]; then
      logger -t "VLANMgr" "handler: debounced ${key} (window=${window}s); skipping"
      _se_cleanup_lock_dir "$lock_dir"
      trap - EXIT INT TERM
      return 0
    fi
    # Update timestamp to current time (record this execution)
    printf '%s' "$now" >"$stamp" 2>/dev/null || :
  fi

  logger -t "VLANMgr" "handler: ${key} lock acquired; launching ${SCRIPT_PATH##*/}"

  # Execute script: try direct execution first (if +x bit set), fallback to sh
  if [ -x "$SCRIPT_PATH" ]; then
    "$SCRIPT_PATH" "$@"
  elif [ -f "$SCRIPT_PATH" ]; then
    sh "$SCRIPT_PATH" "$@"
  else
    logger -t "VLANMgr" "handler: missing script ${SCRIPT_PATH}"
  fi

  # Cleanup: remove lock directory and trap handlers
  logger -t "VLANMgr" "handler: ${key} lock released"
  _se_cleanup_lock_dir "$lock_dir"
  trap - EXIT INT TERM
}

# ========================================================================== #
# EVENT ROUTER — Dispatch events to appropriate handler functions            #
# ========================================================================== #

# Main event dispatch table: maps TYPE_EVENT patterns to handler scripts
# Each case calls dispatch_if_executable with script path and optional args
# Patterns support wildcards (*) for pattern matching on TYPE or EVENT
case "${TYPE}_${EVENT}" in
  # MerVLAN application handlers (explicit handlers for UI/API calls)
  save_vlanmgr) 
    # Save VLAN settings to JSON file (triggered by web form submission)
    dispatch_if_executable "/jffs/addons/mervlan/functions/save_settings.sh"
    ;;
  apply_vlanmgr)
    # Apply configured VLAN settings to system (triggered by "Apply" button)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_manager.sh"
    ;;
  sync_vlanmgr)
    # Sync VLAN configuration to remote nodes (triggered manually)
    dispatch_if_executable "/jffs/addons/mervlan/functions/sync_nodes.sh"
    ;;
  executenodes_vlanmgr)
    # Execute VLAN Manager workflow on configured nodes (runs execute_nodes.sh)
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh"
    ;;
  executenodesonly_vlanmgr)
    # Execute VLAN Manager workflow on configured nodes (runs execute_nodes.sh)
    dispatch_if_executable "/jffs/addons/mervlan/functions/execute_nodes.sh" nodesonly
    ;;
  genkey_vlanmgr)
    # Generate SSH keys for node communication (triggered during setup)
    dispatch_if_executable "/jffs/addons/mervlan/functions/dropbear_sshkey_gen.sh"
    ;;
  enableservice_vlanmgr)
    # Enable MerVLAN auto-start on boot (triggered by service toggle)
    _action_token="$(get_action_request_token)"
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" enable "$_action_token"
    ;;
  enableservice_vlanmgr_vrt_*)
    _action_token="$(get_verified_action_token "${TYPE}_${EVENT}" enableservice_vlanmgr)"
    if [ -n "$_action_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" enable "$_action_token"
    else
      logger -t "VLANMgr" "handler: rejected enable action with invalid verification token"
    fi
    ;;
  disableservice_vlanmgr)
    # Disable MerVLAN auto-start on boot (triggered by service toggle)
    _action_token="$(get_action_request_token)"
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" disable "$_action_token"
    ;;
  disableservice_vlanmgr_vrt_*)
    _action_token="$(get_verified_action_token "${TYPE}_${EVENT}" disableservice_vlanmgr)"
    if [ -n "$_action_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" disable "$_action_token"
    else
      logger -t "VLANMgr" "handler: rejected disable action with invalid verification token"
    fi
    ;;
  checkservice_vlanmgr)
    # Check MerVLAN service status (triggered by status query)
    dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_boot.sh" status
    ;;
  collectclients_vlanmgr)
    # Collect client list from router and nodes (triggered by refresh request)
    dispatch_if_executable "/jffs/addons/mervlan/functions/collect_clients.sh"
    ;;
  clearclilog_vlanmgr)
    # Clear CLI output log file (triggered by Clear button in UI)
    # Uses : to truncate file in place; no script needed
    : > /tmp/mervlan_tmp/logs/cli_output.log 2>/dev/null || :
    logger -t "VLANMgr" "handler: clearclilog_vlanmgr - CLI log truncated"
    ;;
  update_vlanmgr)
    # Update MerVLAN addon from stable channel (triggered by update request)
    dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" update main
    ;;
  updatedev_vlanmgr)
    # Update MerVLAN addon from development channel (triggered by update request)
    dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" update dev
    ;;
  updateref_vlanmgr_*)
    _encoded_update_request="$(decode_update_ref_action "${TYPE}_${EVENT}")"
    _encoded_update_ref=${_encoded_update_request%%|*}
    _encoded_update_policy=${_encoded_update_request#*|}
    case "$_encoded_update_ref|$_encoded_update_policy" in
      refs/heads/?*'|'keep|refs/heads/?*'|'clear|refs/tags/v[0-9]*'|'keep|refs/tags/v[0-9]*'|'clear)
        logger -t "VLANMgr" "handler: decoded explicit update ref '$_encoded_update_ref' (logs=$_encoded_update_policy)"
        dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" update "$_encoded_update_ref" "--logs=$_encoded_update_policy"
        ;;
      *)
        logger -t "VLANMgr" "handler: rejected invalid encoded update ref from '${TYPE}_${EVENT}'"
        ;;
    esac
    ;;
  updaterelease_vlanmgr)
    # Update MerVLAN addon to a specific tagged release or custom branch
    # Ref is written to custom_settings.txt by Merlin (not nvram) via vlanmgr_update_ref key
    _upd_ref="$(grep '^vlanmgr_update_ref=' "$CUSTOM_SETTINGS_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -cd 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-')"
    case "$_upd_ref" in
        refs/tags/v[0-9]*|refs/heads/?*)
            dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" update "$_upd_ref"
            ;;
        *)
            logger -t "VLANMgr" "handler: updaterelease_vlanmgr - invalid or missing ref '$_upd_ref'"
            ;;
    esac
    ;;
  backupinventory_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" backupinventory_vlanmgr 0)
    _maint_token=${_maint_decoded%%|*}
    if [ -n "$_maint_decoded" ] && [ -n "$_maint_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" inventory "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed backup inventory action"
    fi
    ;;
  manualbackup_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" manualbackup_vlanmgr 1)
    _maint_token=${_maint_decoded%%|*}
    _maint_payload=${_maint_decoded#*|}
    if [ -n "$_maint_decoded" ] && maintenance_tag_valid "$_maint_payload"; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" backup create "$_maint_payload" yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed manual backup action"
    fi
    ;;
  deletebackup_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_archive_action "${TYPE}_${EVENT}" deletebackup_vlanmgr)
    _maint_token=${_maint_decoded%%|*}
    _maint_payload=${_maint_decoded#*|}
    if [ -n "$_maint_decoded" ] && maintenance_archive_valid "$_maint_payload"; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" backup delete "$_maint_payload" yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed backup deletion action"
    fi
    ;;
  deleteallbackups_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" deleteallbackups_vlanmgr 0)
    _maint_token=${_maint_decoded%%|*}
    if [ -n "$_maint_decoded" ] && [ -n "$_maint_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" backup delete-all yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed delete-all action"
    fi
    ;;
  restorebackup_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_archive_action "${TYPE}_${EVENT}" restorebackup_vlanmgr)
    _maint_token=${_maint_decoded%%|*}
    _maint_payload=${_maint_decoded#*|}
    if [ -n "$_maint_decoded" ] && maintenance_archive_valid "$_maint_payload"; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" restore "$_maint_payload" yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed restore action"
    fi
    ;;
  undorestore_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" undorestore_vlanmgr 0)
    _maint_token=${_maint_decoded%%|*}
    if [ -n "$_maint_decoded" ] && [ -n "$_maint_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" undo restore yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed Undo Restore action"
    fi
    ;;
  undoupdate_vlanmgr_*)
    _maint_decoded=$(decode_maintenance_action "${TYPE}_${EVENT}" undoupdate_vlanmgr 0)
    _maint_token=${_maint_decoded%%|*}
    if [ -n "$_maint_decoded" ] && [ -n "$_maint_token" ]; then
      dispatch_if_executable "/jffs/addons/mervlan/functions/update_mervlan.sh" undo update yes "$_maint_token"
    else
      logger -t "VLANMgr" "handler: rejected malformed Undo Update action"
    fi
    ;;
  hwprobe_vlanmgr)
    # Re-run hardware probe to refresh the Hardware profile in settings.json
    dispatch_if_executable "/jffs/addons/mervlan/functions/hw_probe.sh"
    ;;
  macrefresh_vlanmgr)
    # Clear and rebuild the MERV_MAC per-client shield db from a fresh snapshot
    dispatch_if_executable "/jffs/addons/mervlan/functions/mac_refresh.sh"
    ;;
  macclientmeta_vlanmgr)
    # Materialize MAC override + client name DBs, re-enforce shield, refresh inventory
    dispatch_if_executable "/jffs/addons/mervlan/functions/mac_client_meta.sh"
    ;;
  # System event handlers (triggered by Asuswrt-Merlin events)
  # Wildcard patterns catch restart_* and service events (wireless, WAN, LAN, NET, FW, NAT, DNS)
  # NOTE: httpd intentionally excluded — httpd restarts don't affect VLANs and cause event floods
  *restart*|*wireless*|*wan*|*lan*|*net*|*firewall*|*nat*|*reload*|*dnsmasq*)
    # Skip httpd events that slip through via *restart* pattern
    case "$COMBINED_NORM" in
      *httpd*) 
        logger -t "VLANMgr" "handler: skipping httpd event ${COMBINED_NORM} (excluded)"
        exit 0
        ;;
    esac

    # Handler-level debounce for system events (prevents heal storms from rc event floods)
    HEAL_STAMP="$LOCKDIR/heal_event.last"
    HEAL_WINDOW="$MERV_HEAL_EVENT_DEBOUNCE"
    now="$(date +%s 2>/dev/null || echo 0)"
    last="$(cat "$HEAL_STAMP" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt "$HEAL_WINDOW" ]; then
      logger -t "VLANMgr" "handler: heal_event debounced (window=${HEAL_WINDOW}s) for ${COMBINED_NORM}"
      exit 0
    fi
    printf '%s\n' "$now" >"$HEAL_STAMP" 2>/dev/null || :

    # Inline shield re-link: runs synchronously in the event handler (~50ms)
    # BEFORE the fire-and-forget sleep delay. Closes the ~3-8s unprotected
    # window between rc flushing ebtables and heal_event.sh's first tick.
    # Only re-links jump rules for existing chains — never creates chains
    # (chain creation and DROP rule rebuild remain heal_event.sh's job).
    # BusyBox-safe: chain name patterns don't start with '-', no grep flag clash.
    if type ebtables >/dev/null 2>&1; then
      # Proactive DHCP gate: block DHCP DISCOVER/REQUEST in br0 while
      # re-linking MERV_QT/MERV_MAC jump rules. Closes the ~2ms re-link
      # window where FORWARD has no chain jump but per-interface DROP rules
      # are intact (orphan state). Transient — removed after re-link.
      # Remove any stale gate first so duplicate rules never accumulate.
      ebtables -t filter -D FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      ebtables -t filter -D INPUT -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      ebtables -t filter -I FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      ebtables -t filter -I INPUT -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      for _se_chain in MERV_QT MERV_MAC; do
        if ebtables -t filter -L "$_se_chain" >/dev/null 2>&1; then
          ebtables -t filter -L FORWARD 2>/dev/null | grep -qF "$_se_chain" || \
            ebtables -t filter -I FORWARD -j "$_se_chain" 2>/dev/null || true
          ebtables -t filter -L INPUT 2>/dev/null | grep -qF "$_se_chain" || \
            ebtables -t filter -I INPUT -j "$_se_chain" 2>/dev/null || true
        fi
      done
      ebtables -t filter -D FORWARD -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
      ebtables -t filter -D INPUT -p IPv4 --ip-proto udp --ip-dport 67 \
        --logical-in br0 -j DROP 2>/dev/null || true
    fi

    # Fire-and-forget heal so rc can continue applying its own changes.
    # Wireless events use delay=0: heal_event.sh has a pre-entry wait loop
    # that actively polls for restart activity instead of a blind sleep.
    # All other system events keep the default delay so they fire after the
    # relevant service has had time to begin its work.
    case "$COMBINED_NORM" in
      *wireless*|*restart_wl*|*wl_restart*|*wl_start*|*wl_stop*)
        _se_heal_delay=0
        ;;
      *)
        _se_heal_delay="$MERV_HEAL_DELAY"
        ;;
    esac
    logger -t "VLANMgr" "handler: queued heal_event ${COMBINED_NORM} (async, delay=${_se_heal_delay}s)"
    (
      sleep "$_se_heal_delay"
      /jffs/addons/mervlan/functions/heal_event.sh "$COMBINED_NORM"
    ) >/dev/null 2>&1 &
    ;;
  *)
    # Unknown event: no matching handler found
    logger -t "VLANMgr" "handler: no match for ${TYPE}_${EVENT}, ignoring"
    ;;
esac
