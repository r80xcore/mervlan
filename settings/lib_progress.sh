#!/bin/sh
#
# ============================================================================ #
# MerVLAN transient web progress publication                                 #
# ============================================================================ #
#
# This library publishes machine-readable task state for the MerVLAN web UI.
# It is intentionally independent of the human-readable CLI/VLAN logs.
#
# Contract:
#   - status files are JSON and are never sourced as shell code;
#   - tokens are path-safe and bounded;
#   - writes are atomic within one directory;
#   - publication is best-effort and must not change an action's result;
#   - status files live under the transient TMPDIR tree, never settings.json.
#
[ -n "${LIB_PROGRESS_LOADED:-}" ] && return 0 2>/dev/null
LIB_PROGRESS_LOADED=1

: "${TMPDIR:=/tmp/mervlan_tmp}"
: "${MERV_PROGRESS_ROOT:=$TMPDIR/progress}"
: "${MERV_PROGRESS_RETENTION_SEC:=3600}"
: "${MERV_PROGRESS_STALE_SEC:=900}"

_MERV_PROGRESS_SEQ=0

# Only permit the production progress directory or an explicitly test-scoped
# directory below /tmp/mervlan_tmp. This prevents an environment override from
# turning the helper into an arbitrary filesystem writer.
merv_progress_root_valid() {
    case "${MERV_PROGRESS_ROOT:-}" in
        "$TMPDIR/progress"|"$TMPDIR/progress"/*)
            return 0
            ;;
        /tmp/mervlan_tmp/selftest.*|/tmp/mervlan_tmp/selftest.*/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

merv_progress_token_valid() {
    _merv_progress_token="${1:-}"
    [ -n "$_merv_progress_token" ] || return 1
    [ "${#_merv_progress_token}" -le 96 ] || return 1
    case "$_merv_progress_token" in
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

merv_progress_action_valid() {
    _merv_progress_action="${1:-}"
    [ -n "$_merv_progress_action" ] || return 1
    [ "${#_merv_progress_action}" -le 128 ] || return 1
    case "$_merv_progress_action" in
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

merv_progress_state_valid() {
    case "${1:-}" in
        starting|running|complete|failed|stale) return 0 ;;
        *) return 1 ;;
    esac
}

merv_progress_mode_valid() {
    case "${1:-}" in
        determinate|indeterminate|phase) return 0 ;;
        *) return 1 ;;
    esac
}

merv_progress_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# JSON strings used by the progress contract are single-line user-facing
# messages. Remove control characters first, then escape backslashes/quotes.
merv_progress_json_escape() {
    printf '%s' "${1:-}" |
        tr -d '\000-\010\013\014\016-\037' |
        sed 's/\\/\\\\/g; s/"/\\"/g'
}

merv_progress_now() {
    date +%s 2>/dev/null || printf '0\n'
}

merv_progress_path() {
    merv_progress_root_valid || return 1
    merv_progress_token_valid "${1:-}" || return 1
    printf '%s/%s.json\n' "$MERV_PROGRESS_ROOT" "$1"
}

merv_progress_clamp_percent() {
    _merv_progress_percent="${1:-}"
    merv_progress_uint "$_merv_progress_percent" || {
        printf 'null\n'
        return 0
    }
    [ "$_merv_progress_percent" -le 100 ] 2>/dev/null || _merv_progress_percent=100
    printf '%s\n' "$_merv_progress_percent"
}

# Internal writer. Arguments:
#   token action label state mode phase current total percent message error
merv_progress_write() {
    _mpw_token="${1:-}"
    _mpw_action="${2:-}"
    _mpw_label="${3:-MerVLAN Loading}"
    _mpw_state="${4:-running}"
    _mpw_mode="${5:-indeterminate}"
    _mpw_phase="${6:-working}"
    _mpw_current="${7:-0}"
    _mpw_total="${8:-0}"
    _mpw_percent="${9:-}"
    _mpw_message="${10:-Working…}"
    _mpw_error="${11:-}"

    merv_progress_token_valid "$_mpw_token" || return 2
    merv_progress_action_valid "$_mpw_action" || return 2
    merv_progress_state_valid "$_mpw_state" || return 2
    merv_progress_mode_valid "$_mpw_mode" || return 2
    merv_progress_uint "$_mpw_current" || _mpw_current=0
    merv_progress_uint "$_mpw_total" || _mpw_total=0
    _mpw_percent="$(merv_progress_clamp_percent "$_mpw_percent")"
    merv_progress_root_valid || return 2
    mkdir -p "$MERV_PROGRESS_ROOT" 2>/dev/null || return 1

    _mpw_path="$(merv_progress_path "$_mpw_token")" || return 2
    _MERV_PROGRESS_SEQ=$((_MERV_PROGRESS_SEQ + 1))
    _mpw_tmp="${_mpw_path}.tmp.$$.$_MERV_PROGRESS_SEQ"
    _mpw_now="$(merv_progress_now)"
    _mpw_token_json="$(merv_progress_json_escape "$_mpw_token")"
    _mpw_action_json="$(merv_progress_json_escape "$_mpw_action")"
    _mpw_label_json="$(merv_progress_json_escape "$_mpw_label")"
    _mpw_phase_json="$(merv_progress_json_escape "$_mpw_phase")"
    _mpw_message_json="$(merv_progress_json_escape "$_mpw_message")"
    _mpw_error_json="$(merv_progress_json_escape "$_mpw_error")"
    _mpw_error_field=null
    [ -n "$_mpw_error_json" ] && _mpw_error_field="\"$_mpw_error_json\""

    {
        printf '{"format_version":1'
        printf ',"token":"%s"' "$_mpw_token_json"
        printf ',"action":"%s"' "$_mpw_action_json"
        printf ',"label":"%s"' "$_mpw_label_json"
        printf ',"state":"%s"' "$_mpw_state"
        printf ',"mode":"%s"' "$_mpw_mode"
        printf ',"phase":"%s"' "$_mpw_phase_json"
        printf ',"current":%s' "$_mpw_current"
        printf ',"total":%s' "$_mpw_total"
        printf ',"percent":%s' "$_mpw_percent"
        printf ',"message":"%s"' "$_mpw_message_json"
        printf ',"error":%s' "$_mpw_error_field"
        printf ',"updated_at":%s}\n' "$_mpw_now"
    } > "$_mpw_tmp" 2>/dev/null || {
        rm -f "$_mpw_tmp" 2>/dev/null || :
        return 1
    }

    mv -f "$_mpw_tmp" "$_mpw_path" 2>/dev/null || {
        rm -f "$_mpw_tmp" 2>/dev/null || :
        return 1
    }
    return 0
}

merv_progress_start() {
    merv_progress_write "${1:-}" "${2:-}" "${3:-MerVLAN Loading}" \
        starting "${4:-indeterminate}" starting 0 0 '' "${5:-Starting…}" ''
}

merv_progress_update() {
    merv_progress_write "${1:-}" "${2:-}" "${3:-MerVLAN Loading}" \
        "${4:-running}" "${5:-indeterminate}" "${6:-working}" \
        "${7:-0}" "${8:-0}" "${9:-}" "${10:-Working…}" "${11:-}"
}

merv_progress_phase() {
    merv_progress_update "${1:-}" "${2:-}" "${3:-MerVLAN Loading}" \
        running phase "${4:-working}" 0 0 '' "${5:-Working…}" ''
}

# Arguments: token action label phase current total message
merv_progress_item() {
    _mpi_current="${5:-0}"
    _mpi_total="${6:-0}"
    _mpi_percent=""
    if merv_progress_uint "$_mpi_current" && merv_progress_uint "$_mpi_total" &&
        [ "$_mpi_total" -gt 0 ] 2>/dev/null; then
        _mpi_percent=$((100 * _mpi_current / _mpi_total))
    fi
    merv_progress_update "${1:-}" "${2:-}" "${3:-MerVLAN Loading}" \
        running determinate "${4:-items}" "$_mpi_current" "$_mpi_total" \
        "$_mpi_percent" "${7:-Working…}" ''
}

merv_progress_complete() {
    merv_progress_write "${1:-}" "${2:-}" "${3:-MerVLAN Loading}" \
        complete determinate complete 1 1 100 "${4:-Complete}" ''
}

merv_progress_fail() {
    merv_progress_write "${1:-}" "${2:-}" "${3:-MerVLAN Loading}" \
        failed "${4:-indeterminate}" failed 0 0 '' "${5:-Action failed}" "${6:-Action failed}"
}

merv_progress_remove() {
    _mpr_path="$(merv_progress_path "${1:-}")" || return 2
    rm -f "$_mpr_path" 2>/dev/null || return 1
    return 0
}

# Prune only JSON files directly beneath the validated dedicated root. The
# directory is never recursive and no caller-supplied glob is accepted.
merv_progress_prune() {
    merv_progress_root_valid || return 2
    merv_progress_uint "${MERV_PROGRESS_RETENTION_SEC:-}" || return 2
    _mpp_minutes=$((MERV_PROGRESS_RETENTION_SEC / 60))
    [ "$_mpp_minutes" -gt 0 ] || _mpp_minutes=1
    find "$MERV_PROGRESS_ROOT" -maxdepth 1 -type f -name '*.json' \
        -mmin "+$_mpp_minutes" -exec rm -f {} \; 2>/dev/null || :
    return 0
}

