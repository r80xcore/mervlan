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
#               - File: lib_debug.sh || version="0.48"                         #
# ============================================================================ #
# - Purpose:    Shared debug helpers for MerVLAN scripts. Provides uniform     #
#               toggles, JSON-driven initialization, and formatted output via  #
#               the existing info/warn/error logging commands.                 #
#               It also provides an explicitly opt-in, bounded persistent      #
#               diagnostic stream for high-value WAN Native lifecycle events.  #
# ============================================================================ #

[ -n "${LIB_DEBUG_LOADED:-}" ] && return 0 2>/dev/null

# ---- merv: portable `command -v` replacement ----
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

: "${DBG_CHANNEL:=vlan}"
: "${DBG_PREFIX:=[DEBUG]}"

_debug_to_lower() {
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

_debug_is_truthy() {
    case "$(_debug_to_lower "$1")" in
        1|true|yes|on|enabled)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

debug_is_enabled() {
    _debug_is_truthy "${DEBUG:-0}"
}

debug_enable() {
    DEBUG=1
}

debug_disable() {
    DEBUG=0
}

debug_set_channel() {
    [ -n "$1" ] || return 1
    DBG_CHANNEL="$1"
}

debug_set_prefix() {
    [ -n "$1" ] || return 1
    DBG_PREFIX="$1"
}

_dbg_emit() {
    local message="$1" channel

    if merv_has info; then
        channel="${DBG_CHANNEL:-}"
        if [ -n "$channel" ]; then
            info -c "$channel" "$message"
        else
            info "$message"
        fi
        return 0
    fi

    printf '%s\n' "$message"
}

dbg_log() {
    debug_is_enabled || return 0

    if [ "$#" -eq 0 ]; then
        return 0
    fi

    _dbg_emit "$DBG_PREFIX $*"
}

dbg_var() {
    debug_is_enabled || return 0

    [ "$#" -gt 0 ] || return 0

    local var value sanitized value_set

    for var in "$@"; do
        [ -n "$var" ] || continue
        value_set=""
        eval "value_set=\${$var+1}"
        if [ -n "$value_set" ]; then
            eval "value=\${$var}"
            sanitized=$(printf '%s' "${value}" | tr '\015' ' ' | tr '\012' ' ')
            _dbg_emit "$DBG_PREFIX $var=$sanitized"
        else
            _dbg_emit "$DBG_PREFIX $var=<unset>"
        fi
    done
}

_debug_init_from_value() {
    local raw="$1"

    if _debug_is_truthy "$raw"; then
        debug_enable
        dbg_log "Debug logging enabled (raw=$raw)"
    else
        debug_disable
    fi
}

debug_init_from_json() {
    # debug_init_from_json <key> [default] [file]
    local key="$1" default_value="${2:-0}" file="${3:-${SETTINGS_FILE:-}}" raw

    [ -n "$key" ] || return 1

    if merv_has json_get_flag; then
        if [ -n "$file" ]; then
            raw="$(json_get_flag "$key" "$default_value" "$file" 2>/dev/null)"
        else
            raw="$(json_get_flag "$key" "$default_value" 2>/dev/null)"
        fi
    else
        raw="$default_value"
    fi

    _debug_init_from_value "$raw"
    return 0
}

# --------------------------------------------------------------------------- #
# Opt-in persistent diagnostic breadcrumbs                                     #
# --------------------------------------------------------------------------- #
# Persistent logging is separate from normal DEBUG output. It is disabled
# unless VLAN.WAN_Native.PERSISTENT_DEBUG_LOGGING is explicitly true and is
# intended for short qualification/debug sessions only. Every helper is
# best-effort: a flash/filesystem failure must never change a network result.
: "${MERV_PERSISTENT_DEBUG_DIR:=${MERV_BASE:-/jffs/addons/mervlan}/logs/debug}"
: "${MERV_PERSISTENT_DEBUG_MAX_FILES:=3}"
: "${MERV_PERSISTENT_DEBUG_MAX_BYTES:=32768}"
MERV_PERSISTENT_DEBUG_ENABLED="${MERV_PERSISTENT_DEBUG_ENABLED:-0}"
MERV_PERSISTENT_DEBUG_RUN_ID="${MERV_PERSISTENT_DEBUG_RUN_ID:-}"
MERV_PERSISTENT_DEBUG_RUN_LOG="${MERV_PERSISTENT_DEBUG_RUN_LOG:-}"
MERV_PERSISTENT_DEBUG_BREADCRUMB="${MERV_PERSISTENT_DEBUG_BREADCRUMB:-}"

persistent_debug_init_from_settings() {
    _pdis_file="${1:-${SETTINGS_FILE:-}}"
    _pdis_raw=""
    if merv_has json_get_section2_value && [ -n "$_pdis_file" ]; then
        _pdis_raw="$(json_get_section2_value VLAN WAN_Native PERSISTENT_DEBUG_LOGGING "$_pdis_file" 2>/dev/null || printf '')"
    fi
    # Flat lookup is only a compatibility read for older settings files. New
    # saves always place this key in VLAN.WAN_Native.
    [ -n "$_pdis_raw" ] || {
        if merv_has json_get_flag; then
            if [ -n "$_pdis_file" ]; then
                _pdis_raw="$(json_get_flag PERSISTENT_DEBUG_LOGGING 0 "$_pdis_file" 2>/dev/null || printf '')"
            else
                _pdis_raw="$(json_get_flag PERSISTENT_DEBUG_LOGGING 0 2>/dev/null || printf '')"
            fi
        fi
    }
    case "$(_debug_to_lower "$_pdis_raw")" in
        1|true|yes|on|enabled) MERV_PERSISTENT_DEBUG_ENABLED=1 ;;
        *) MERV_PERSISTENT_DEBUG_ENABLED=0 ;;
    esac
    MERV_PERSISTENT_DEBUG_RUN_ID=""
    MERV_PERSISTENT_DEBUG_RUN_LOG=""
    MERV_PERSISTENT_DEBUG_BREADCRUMB=""
    return 0
}

persistent_debug_is_enabled() {
    [ "${MERV_PERSISTENT_DEBUG_ENABLED:-0}" = 1 ]
}

persistent_debug_now() {
    date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || printf 'unknown'
}

persistent_debug_trim() {
    persistent_debug_is_enabled || return 0
    _pdt_file="${1:-$MERV_PERSISTENT_DEBUG_RUN_LOG}"
    [ -n "$_pdt_file" ] || return 0
    # Keep the active stream bounded even when a qualification is left running.
    if [ -f "$_pdt_file" ] && [ "${MERV_PERSISTENT_DEBUG_MAX_BYTES:-0}" -gt 0 ] 2>/dev/null; then
        _pdt_bytes="$(wc -c < "$_pdt_file" 2>/dev/null || printf 0)"
        case "$_pdt_bytes" in ''|*[!0-9]*) _pdt_bytes=0 ;; esac
        if [ "$_pdt_bytes" -gt "$MERV_PERSISTENT_DEBUG_MAX_BYTES" ] 2>/dev/null; then
            _pdt_tmp="${_pdt_file}.${MERV_PERSISTENT_DEBUG_RUN_ID:-$$}.trim"
            tail -c "$MERV_PERSISTENT_DEBUG_MAX_BYTES" "$_pdt_file" > "$_pdt_tmp" 2>/dev/null &&
                mv "$_pdt_tmp" "$_pdt_file" 2>/dev/null || rm -f "$_pdt_tmp" 2>/dev/null
        fi
    fi
    # Retain only the newest few run files. Filenames contain no whitespace.
    _pdt_paths="$(ls -1t "${MERV_PERSISTENT_DEBUG_DIR}"/wan-native-main-*.log 2>/dev/null || printf '')"
    _pdt_count=0
    for _pdt_path in $_pdt_paths; do
        [ -f "$_pdt_path" ] || continue
        _pdt_count=$((_pdt_count + 1))
        [ "$_pdt_count" -le "${MERV_PERSISTENT_DEBUG_MAX_FILES:-3}" ] || rm -f "$_pdt_path" 2>/dev/null || :
    done
    return 0
}

persistent_debug_run_start() {
    persistent_debug_is_enabled || return 0
    _pdrs_prefix="${1:-WANMAIN}"
    _pdrs_stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'unknown-%s' "$$")"
    mkdir -p "$MERV_PERSISTENT_DEBUG_DIR" 2>/dev/null || return 0
    MERV_PERSISTENT_DEBUG_RUN_ID="${_pdrs_prefix}-${_pdrs_stamp}-$$"
    MERV_PERSISTENT_DEBUG_RUN_LOG="$MERV_PERSISTENT_DEBUG_DIR/wan-native-main-${_pdrs_stamp}-$$.log"
    MERV_PERSISTENT_DEBUG_BREADCRUMB="$MERV_PERSISTENT_DEBUG_DIR/current-wan-native-test"
    : > "$MERV_PERSISTENT_DEBUG_RUN_LOG" 2>/dev/null || {
        MERV_PERSISTENT_DEBUG_RUN_ID=""
        MERV_PERSISTENT_DEBUG_RUN_LOG=""
        MERV_PERSISTENT_DEBUG_BREADCRUMB=""
        return 0
    }
    persistent_debug_event transaction-start ""
    persistent_debug_breadcrumb transaction-start
    return 0
}

persistent_debug_event() {
    persistent_debug_is_enabled || return 0
    [ -n "${MERV_PERSISTENT_DEBUG_RUN_ID:-}" ] || return 0
    [ -n "${MERV_PERSISTENT_DEBUG_RUN_LOG:-}" ] || return 0
    _pde_stage="$1"
    shift 2>/dev/null || :
    _pde_details="$*"
    _pde_details="$(printf '%s' "$_pde_details" | tr '\r\n' '  ' 2>/dev/null || printf '%s' "$_pde_details")"
    printf '%s RUN=%s stage=%s%s%s\n' "$(persistent_debug_now)" "$MERV_PERSISTENT_DEBUG_RUN_ID" "$_pde_stage" \
        "${_pde_details:+ }" "$_pde_details" >> "$MERV_PERSISTENT_DEBUG_RUN_LOG" 2>/dev/null || :
    persistent_debug_trim "$MERV_PERSISTENT_DEBUG_RUN_LOG"
    return 0
}

persistent_debug_breadcrumb() {
    persistent_debug_is_enabled || return 0
    [ -n "${MERV_PERSISTENT_DEBUG_BREADCRUMB:-}" ] || return 0
    _pdb_stage="$1"
    shift 2>/dev/null || :
    _pdb_details="$*"
    _pdb_details="$(printf '%s' "$_pdb_details" | tr '\r\n' '  ' 2>/dev/null || printf '%s' "$_pdb_details")"
    _pdb_tmp="${MERV_PERSISTENT_DEBUG_BREADCRUMB}.${MERV_PERSISTENT_DEBUG_RUN_ID:-$$}.tmp"
    if {
        printf 'run_id=%s\n' "$MERV_PERSISTENT_DEBUG_RUN_ID"
        printf 'updated=%s\n' "$(persistent_debug_now)"
        printf 'stage=%s\n' "$_pdb_stage"
        [ -z "$_pdb_details" ] || printf '%s\n' "$_pdb_details"
    } > "$_pdb_tmp" 2>/dev/null; then
        mv "$_pdb_tmp" "$MERV_PERSISTENT_DEBUG_BREADCRUMB" 2>/dev/null || rm -f "$_pdb_tmp" 2>/dev/null
    else
        rm -f "$_pdb_tmp" 2>/dev/null || :
    fi
    return 0
}

persistent_debug_complete() {
    persistent_debug_is_enabled || return 0
    _pdc_result="${1:-failed}"
    persistent_debug_event transaction-complete "result=$_pdc_result"
    case "$_pdc_result" in
        ok|rollback-ok) rm -f "${MERV_PERSISTENT_DEBUG_BREADCRUMB:-}" 2>/dev/null || : ;;
        *) persistent_debug_breadcrumb failed "result=$_pdc_result" ;;
    esac
    persistent_debug_trim "${MERV_PERSISTENT_DEBUG_RUN_LOG:-}"
    return 0
}

LIB_DEBUG_LOADED=1
