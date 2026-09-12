#!/bin/sh
# Durable backend reconciliation for successful MAIN Save node settings.
# `due` performs no SSH and hands a due generation to an independently owned
# `run` action.  `run` uses the normal action lock through sync_nodes.sh.

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh" || exit 75
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh" || exit 75
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh" || exit 75
[ -n "${LIB_SETTINGS_RECONCILE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_settings_reconcile.sh" || exit 75
[ -n "${LIB_OWNER_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_owner_lock.sh" 2>/dev/null || exit 75
[ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || exit 75

reconcile_due() {
    case "$(json_get_flag AUTO_SYNC_SETTINGS 0 "$SETTINGS_FILE" 2>/dev/null)" in
        1|true|yes) ;;
        *) return 0 ;;
    esac
    _sr_malformed=0
    if merv_settings_reconcile_read; then
        # Trust/identity intervention is explicitly manual. Its epoch is 0
        # only as a non-schedule sentinel, never an immediately due retry.
        case "$MERV_SETTINGS_RECONCILE_STATUS" in blocked|paused) return 0 ;; esac
    elif [ ! -e "$MERV_SETTINGS_RECONCILE_FILE" ]; then
        return 0
    else
        # The marker exists but failed strict parsing.  Do not inspect any
        # untrusted fields; let the normally serialized worker quarantine and
        # rebuild it from current authoritative settings/topology.
        _sr_malformed=1
    fi
    _sr_now=$(date +%s 2>/dev/null || printf '0')
    case "$_sr_now" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_sr_malformed" -eq 1 ] || \
        [ "$_sr_now" -ge "$MERV_SETTINGS_RECONCILE_NEXT_EPOCH" ] 2>/dev/null || return 0
    if merv_update_mutation_blocked; then
        return 0
    fi
    _sr_action_lock="${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}"
    case "$(merv_owner_lock_state "$_sr_action_lock" 2>/dev/null || printf unknown)" in
        absent|dead|reused) ;;
        *) return 0 ;;
    esac
    ( exec </dev/null; exec >/dev/null 2>&1; sh "$0" run ) &
    return 0
}

reconcile_run() {
    # Re-read AUTO_SYNC_SETTINGS here because it can change after `due` forks.
    case "$(json_get_flag AUTO_SYNC_SETTINGS 0 "$SETTINGS_FILE" 2>/dev/null)" in
        1|true|yes) ;;
        *) return 0 ;;
    esac
    if merv_update_mutation_blocked; then
        return 0
    fi
    exec sh "$MERV_BASE/functions/sync_nodes.sh" --settings-only
}

case "${1:-due}" in
    due) reconcile_due ;;
    run) reconcile_run ;;
    *) exit 2 ;;
esac
