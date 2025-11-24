# ──────────────────────────────────────────────────────────────────────────── #
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
# ──────────────────────────────────────────────────────────────────────────── #
#               - File: lib_debug.sh || version="0.46"                        #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Shared debug helpers for MerVLAN scripts. Provides uniform     #
#               toggles, JSON-driven initialization, and formatted output via  #
#               the existing info/warn/error logging commands.                 #
# ──────────────────────────────────────────────────────────────────────────── #

[ -n "${LIB_DEBUG_LOADED:-}" ] && return 0 2>/dev/null

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

    if command -v info >/dev/null 2>&1; then
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

    if command -v json_get_flag >/dev/null 2>&1; then
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

LIB_DEBUG_LOADED=1
