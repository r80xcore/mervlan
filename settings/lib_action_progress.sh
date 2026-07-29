#!/bin/sh
#
# ============================================================================ #
# MerVLAN shared action-level progress helpers                              #
# ============================================================================ #
#
# This library keeps action scripts focused on their real milestones while
# settings/lib_progress.sh owns the JSON publication contract.  Publication is
# deliberately best-effort: a missing token, helper, or writable status path
# never changes the action's result.
#
[ -n "${LIB_ACTION_PROGRESS_LOADED:-}" ] && return 0 2>/dev/null
LIB_ACTION_PROGRESS_LOADED=1

: "${MERV_BASE:=/jffs/addons/mervlan}"

merv_action_progress_init() {
    MERV_ACTION_PROGRESS_TOKEN="${1:-}"
    MERV_ACTION_PROGRESS_ACTION="${2:-}"
    MERV_ACTION_PROGRESS_LABEL="${3:-MerVLAN Loading}"
    MERV_ACTION_PROGRESS_ENABLED=0
    MERV_ACTION_PROGRESS_FINAL=0

    [ -n "$MERV_ACTION_PROGRESS_TOKEN" ] || return 0
    if [ -z "${LIB_PROGRESS_LOADED:-}" ] && [ -f "$MERV_BASE/settings/lib_progress.sh" ]; then
        . "$MERV_BASE/settings/lib_progress.sh" 2>/dev/null || :
    fi
    type merv_progress_start >/dev/null 2>&1 || return 0
    merv_progress_prune 2>/dev/null || :
    if merv_progress_start "$MERV_ACTION_PROGRESS_TOKEN" \
        "$MERV_ACTION_PROGRESS_ACTION" "$MERV_ACTION_PROGRESS_LABEL" phase \
        "${4:-Preparing...}" >/dev/null 2>&1; then
        MERV_ACTION_PROGRESS_ENABLED=1
    fi
}

merv_action_progress_phase() {
    [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] || return 0
    merv_progress_phase "$MERV_ACTION_PROGRESS_TOKEN" \
        "$MERV_ACTION_PROGRESS_ACTION" "$MERV_ACTION_PROGRESS_LABEL" \
        "${1:-working}" "${2:-Working...}" >/dev/null 2>&1 || :
}

# Arguments: phase current total percent message
merv_action_progress_update() {
    [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] || return 0
    merv_progress_update "$MERV_ACTION_PROGRESS_TOKEN" \
        "$MERV_ACTION_PROGRESS_ACTION" "$MERV_ACTION_PROGRESS_LABEL" \
        running determinate "${1:-working}" "${2:-0}" "${3:-0}" \
        "${4:-}" "${5:-Working...}" "" >/dev/null 2>&1 || :
}

merv_action_progress_complete() {
    [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] || return 0
    MERV_ACTION_PROGRESS_FINAL=1
    merv_progress_complete "$MERV_ACTION_PROGRESS_TOKEN" \
        "$MERV_ACTION_PROGRESS_ACTION" "$MERV_ACTION_PROGRESS_LABEL" \
        "${1:-Complete}" >/dev/null 2>&1 || :
}

merv_action_progress_fail() {
    [ "${MERV_ACTION_PROGRESS_ENABLED:-0}" -eq 1 ] || return 0
    MERV_ACTION_PROGRESS_FINAL=1
    merv_progress_fail "$MERV_ACTION_PROGRESS_TOKEN" \
        "$MERV_ACTION_PROGRESS_ACTION" "$MERV_ACTION_PROGRESS_LABEL" \
        phase "${1:-Action failed}" "${1:-Action failed}" >/dev/null 2>&1 || :
}
