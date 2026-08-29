#!/bin/sh
# ============================================================================ #
# MerVLAN durable MAIN-to-node settings convergence state                   #
# ============================================================================ #
#
# This library stores only bounded, non-secret convergence metadata.  The
# state is data (never shell code), is published with a same-directory rename,
# and remains valid across reboot and loss of the WebUI transport.

[ -n "${LIB_SETTINGS_RECONCILE_LOADED:-}" ] && return 0 2>/dev/null

: "${MERV_STATE_ROOT:=/jffs/addons/mervlan_state}"
: "${MERV_SETTINGS_RECONCILE_FILE:=$MERV_STATE_ROOT/settings_reconcile.state}"
: "${PUBLIC_MERV_BASE:=/www/user/mervlan}"
: "${MERV_SETTINGS_RECONCILE_PUBLIC_ROOT:=$PUBLIC_MERV_BASE}"
: "${MERV_SETTINGS_RECONCILE_PUBLIC_FILE:=$MERV_SETTINGS_RECONCILE_PUBLIC_ROOT/tmp/results/settings_reconcile.json}"

# Keep the record deliberately small.  Digests are labels emitted by the
# existing settings/node digest helpers (for example md5:<hex> or
# cksum:<number>:<number>), not secrets or user-provided shell fragments.
MERV_SETTINGS_RECONCILE_MAX_DIGEST=256
MERV_SETTINGS_RECONCILE_MAX_GENERATION=2147483647
MERV_SETTINGS_RECONCILE_MAX_ATTEMPT=100000
MERV_SETTINGS_RECONCILE_MAX_EPOCH=2147483647

merv_settings_reconcile_path_valid() {
    _msr_path="${1:-}"
    _msr_root="${MERV_STATE_ROOT:-}"
    [ -n "$_msr_root" ] || return 1
    [ -n "$_msr_path" ] || return 1
    case "$_msr_path" in
        "$_msr_root"/*) ;;
        *) return 1 ;;
    esac
    _msr_name=${_msr_path#"$_msr_root"/}
    # The state file is one controlled leaf below the protected root.  Reject
    # traversal, nested paths, and shell/control punctuation before any mkdir,
    # temporary file, or rename operation uses it.
    case "$_msr_name" in
        ''|.|..|*/*|*..*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

merv_settings_reconcile_token_valid() {
    _msr_token="${1:-}"
    [ -n "$_msr_token" ] || return 1
    [ "${#_msr_token}" -le "$MERV_SETTINGS_RECONCILE_MAX_DIGEST" ] 2>/dev/null || return 1
    case "$_msr_token" in
        *[!A-Za-z0-9._:/-]*) return 1 ;;
    esac
    return 0
}

merv_settings_reconcile_uint_valid() {
    _msr_uint="${1:-}"
    _msr_max="${2:-$MERV_SETTINGS_RECONCILE_MAX_EPOCH}"
    case "$_msr_uint" in
        0|[1-9]|[1-9][0-9]*) ;;
        *) return 1 ;;
    esac
    [ "${#_msr_uint}" -le 10 ] 2>/dev/null || return 1
    [ "$_msr_uint" -le "$_msr_max" ] 2>/dev/null || return 1
    return 0
}

merv_settings_reconcile_generation_valid() {
    merv_settings_reconcile_uint_valid "${1:-}" "$MERV_SETTINGS_RECONCILE_MAX_GENERATION" || return 1
    [ "${1:-0}" -ge 1 ] 2>/dev/null
}

merv_settings_reconcile_status_valid() {
    case "${1:-}" in
        pending|queued|running|blocked|retry|paused|verified) return 0 ;;
        *) return 1 ;;
    esac
}

# The browser-facing file is a deliberately narrow, non-authoritative
# projection of the protected marker.  Its default location is fixed below
# the public MerVLAN root; tests may provide a private absolute path with the
# same controlled suffix.  No caller reads this file to make a reconciliation
# decision and no digest is ever emitted here.
merv_settings_reconcile_public_path_valid() {
    _msrpp_path="${1:-${MERV_SETTINGS_RECONCILE_PUBLIC_FILE:-}}"
    _msrpp_root="${MERV_SETTINGS_RECONCILE_PUBLIC_ROOT:-}"
    [ -n "$_msrpp_path" ] || return 1
    [ -n "$_msrpp_root" ] || return 1
    case "$_msrpp_path" in
        "$_msrpp_root"/tmp/results/settings_reconcile.json) ;;
        *) return 1 ;;
    esac
    case "$_msrpp_path" in
        *..*|*//*|*[!A-Za-z0-9._/-]*) return 1 ;;
    esac
    return 0
}

# Publish only bounded display state.  This helper intentionally reports
# failure to its callers so they can ignore it: a public projection outage
# must never turn a protected marker operation into a failed convergence
# operation.
merv_settings_reconcile_public_write() {
    _msrpp_generation="${1:-}"
    _msrpp_status="${2:-}"
    _msrpp_attempt="${3:-}"
    _msrpp_next_epoch="${4:-}"
    _msrpp_updated_epoch="${5:-}"
    _msrpp_path="${MERV_SETTINGS_RECONCILE_PUBLIC_FILE:-}"

    merv_settings_reconcile_public_path_valid "$_msrpp_path" || return 1
    merv_settings_reconcile_generation_valid "$_msrpp_generation" || return 1
    merv_settings_reconcile_status_valid "$_msrpp_status" || return 1
    merv_settings_reconcile_uint_valid "$_msrpp_attempt" "$MERV_SETTINGS_RECONCILE_MAX_ATTEMPT" || return 1
    merv_settings_reconcile_uint_valid "$_msrpp_next_epoch" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || return 1
    merv_settings_reconcile_uint_valid "$_msrpp_updated_epoch" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || return 1

    case "$_msrpp_status" in
        pending|queued|running|blocked|retry|paused) _msrpp_active=true ;;
        verified) _msrpp_active=false ;;
        *) return 1 ;;
    esac
    _msrpp_dir=${_msrpp_path%/settings_reconcile.json}
    [ "$_msrpp_dir" != "$_msrpp_path" ] || return 1
    mkdir -p "$_msrpp_dir" 2>/dev/null || return 1
    : "${MERV_SETTINGS_RECONCILE_SEQ:=0}"
    MERV_SETTINGS_RECONCILE_SEQ=$((MERV_SETTINGS_RECONCILE_SEQ + 1))
    _msrpp_tmp="$_msrpp_path.tmp.$$.$MERV_SETTINGS_RECONCILE_SEQ"
    ( umask 022
        printf '{"format":1,"active":%s,"generation":%s,"status":"%s","attempt":%s,"next_epoch":%s,"updated_epoch":%s}\n' \
            "$_msrpp_active" "$_msrpp_generation" "$_msrpp_status" \
            "$_msrpp_attempt" "$_msrpp_next_epoch" "$_msrpp_updated_epoch"
    ) > "$_msrpp_tmp" 2>/dev/null || { rm -f "$_msrpp_tmp" 2>/dev/null || :; return 1; }
    chmod 644 "$_msrpp_tmp" 2>/dev/null || { rm -f "$_msrpp_tmp" 2>/dev/null || :; return 1; }
    mv -f "$_msrpp_tmp" "$_msrpp_path" 2>/dev/null || {
        rm -f "$_msrpp_tmp" 2>/dev/null || :
        return 1
    }
    return 0
}

merv_settings_reconcile_public_remove() {
    _msrppr_path="${MERV_SETTINGS_RECONCILE_PUBLIC_FILE:-}"
    merv_settings_reconcile_public_path_valid "$_msrppr_path" || return 1
    rm -f "$_msrppr_path" 2>/dev/null
}

# Validate the complete record and load its values into shell variables.  The
# file is never sourced.  Every key must occur exactly once and no unknown key
# is accepted, so a malformed or truncated record fails closed.
merv_settings_reconcile_read() {
    merv_settings_reconcile_path_valid "$MERV_SETTINGS_RECONCILE_FILE" || return 1
    [ -f "$MERV_SETTINGS_RECONCILE_FILE" ] || return 1

    awk -F= '
        BEGIN {
            expected["format"] = 1
            expected["generation"] = 1
            expected["settings_digest"] = 1
            expected["node_list_digest"] = 1
            expected["status"] = 1
            expected["attempt"] = 1
            expected["next_epoch"] = 1
            expected["updated_epoch"] = 1
            wanted = 8
        }
        NF != 2 { exit 2 }
        !($1 in expected) { exit 2 }
        seen[$1]++
        seen[$1] > 1 { exit 2 }
        count++
        END {
            if (count != wanted) exit 2
            for (key in expected) if (seen[key] != 1) exit 2
        }
    ' "$MERV_SETTINGS_RECONCILE_FILE" >/dev/null 2>&1 || return 1

    _msr_format=$(sed -n 's/^format=//p' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)
    _msr_generation=$(sed -n 's/^generation=//p' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)
    _msr_settings_digest=$(sed -n 's/^settings_digest=//p' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)
    _msr_node_list_digest=$(sed -n 's/^node_list_digest=//p' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)
    _msr_status=$(sed -n 's/^status=//p' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)
    _msr_attempt=$(sed -n 's/^attempt=//p' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)
    _msr_next_epoch=$(sed -n 's/^next_epoch=//p' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)
    _msr_updated_epoch=$(sed -n 's/^updated_epoch=//p' "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null)

    [ "$_msr_format" = 1 ] || return 1
    merv_settings_reconcile_generation_valid "$_msr_generation" || return 1
    merv_settings_reconcile_token_valid "$_msr_settings_digest" || return 1
    merv_settings_reconcile_token_valid "$_msr_node_list_digest" || return 1
    merv_settings_reconcile_status_valid "$_msr_status" || return 1
    merv_settings_reconcile_uint_valid "$_msr_attempt" "$MERV_SETTINGS_RECONCILE_MAX_ATTEMPT" || return 1
    merv_settings_reconcile_uint_valid "$_msr_next_epoch" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || return 1
    merv_settings_reconcile_uint_valid "$_msr_updated_epoch" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || return 1

    MERV_SETTINGS_RECONCILE_FORMAT="$_msr_format"
    MERV_SETTINGS_RECONCILE_GENERATION="$_msr_generation"
    MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST="$_msr_settings_digest"
    MERV_SETTINGS_RECONCILE_NODE_LIST_DIGEST="$_msr_node_list_digest"
    MERV_SETTINGS_RECONCILE_STATUS="$_msr_status"
    MERV_SETTINGS_RECONCILE_ATTEMPT="$_msr_attempt"
    MERV_SETTINGS_RECONCILE_NEXT_EPOCH="$_msr_next_epoch"
    MERV_SETTINGS_RECONCILE_UPDATED_EPOCH="$_msr_updated_epoch"
    return 0
}

merv_settings_reconcile_get() {
    _msrg_key="${1:-}"
    _msrg_default="${2:-}"
    merv_settings_reconcile_read || { printf '%s' "$_msrg_default"; return 1; }
    case "$_msrg_key" in
        format) printf '%s' "$MERV_SETTINGS_RECONCILE_FORMAT" ;;
        generation) printf '%s' "$MERV_SETTINGS_RECONCILE_GENERATION" ;;
        settings_digest) printf '%s' "$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST" ;;
        node_list_digest) printf '%s' "$MERV_SETTINGS_RECONCILE_NODE_LIST_DIGEST" ;;
        status) printf '%s' "$MERV_SETTINGS_RECONCILE_STATUS" ;;
        attempt) printf '%s' "$MERV_SETTINGS_RECONCILE_ATTEMPT" ;;
        next_epoch) printf '%s' "$MERV_SETTINGS_RECONCILE_NEXT_EPOCH" ;;
        updated_epoch) printf '%s' "$MERV_SETTINGS_RECONCILE_UPDATED_EPOCH" ;;
        *) printf '%s' "$_msrg_default"; return 1 ;;
    esac
    return 0
}

merv_settings_reconcile_active() {
    merv_settings_reconcile_read
}

# Publish a new desired generation.  The first five arguments are the public
# contract: settings digest, node-list digest, status, attempt, and next epoch.
# An optional sixth generation is accepted for callers that already allocated
# a durable generation; without it, each publish advances the current valid
# generation.  A supplied generation must be strictly newer than the current
# valid generation, preventing stale writers from superseding newer intent.
merv_settings_reconcile_publish() {
    _msrp_settings_digest="${1:-}"
    _msrp_node_list_digest="${2:-}"
    _msrp_status="${3:-pending}"
    _msrp_attempt="${4:-0}"
    _msrp_next_epoch="${5:-0}"
    _msrp_generation="${6:-}"
    _msrp_current_generation=0

    merv_settings_reconcile_path_valid "$MERV_SETTINGS_RECONCILE_FILE" || return 1
    merv_settings_reconcile_token_valid "$_msrp_settings_digest" || return 1
    merv_settings_reconcile_token_valid "$_msrp_node_list_digest" || return 1
    merv_settings_reconcile_status_valid "$_msrp_status" || return 1
    merv_settings_reconcile_uint_valid "$_msrp_attempt" "$MERV_SETTINGS_RECONCILE_MAX_ATTEMPT" || return 1
    merv_settings_reconcile_uint_valid "$_msrp_next_epoch" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || return 1

    if merv_settings_reconcile_read; then
        _msrp_current_generation="$MERV_SETTINGS_RECONCILE_GENERATION"
    fi
    if [ -n "$_msrp_generation" ]; then
        merv_settings_reconcile_generation_valid "$_msrp_generation" || return 1
        [ "$_msrp_generation" -gt "$_msrp_current_generation" ] 2>/dev/null || return 1
    else
        _msrp_generation=$((_msrp_current_generation + 1))
        merv_settings_reconcile_generation_valid "$_msrp_generation" || return 1
    fi

    mkdir -p "$MERV_STATE_ROOT" 2>/dev/null || return 1
    chmod 700 "$MERV_STATE_ROOT" 2>/dev/null || return 1
    : "${MERV_SETTINGS_RECONCILE_SEQ:=0}"
    MERV_SETTINGS_RECONCILE_SEQ=$((MERV_SETTINGS_RECONCILE_SEQ + 1))
    _msrp_tmp="$MERV_SETTINGS_RECONCILE_FILE.tmp.$$.$MERV_SETTINGS_RECONCILE_SEQ"
    _msrp_now=$(date +%s 2>/dev/null || printf '0')
    merv_settings_reconcile_uint_valid "$_msrp_now" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || _msrp_now=0
    ( umask 077
        {
            printf 'format=1\n'
            printf 'generation=%s\n' "$_msrp_generation"
            printf 'settings_digest=%s\n' "$_msrp_settings_digest"
            printf 'node_list_digest=%s\n' "$_msrp_node_list_digest"
            printf 'status=%s\n' "$_msrp_status"
            printf 'attempt=%s\n' "$_msrp_attempt"
            printf 'next_epoch=%s\n' "$_msrp_next_epoch"
            printf 'updated_epoch=%s\n' "$_msrp_now"
        } > "$_msrp_tmp"
    ) 2>/dev/null || { rm -f "$_msrp_tmp" 2>/dev/null || :; return 1; }
    chmod 600 "$_msrp_tmp" 2>/dev/null || { rm -f "$_msrp_tmp" 2>/dev/null || :; return 1; }
    mv -f "$_msrp_tmp" "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null || {
        rm -f "$_msrp_tmp" 2>/dev/null || :
        return 1
    }
    MERV_SETTINGS_RECONCILE_GENERATION="$_msrp_generation"
    merv_settings_reconcile_public_write "$_msrp_generation" "$_msrp_status" \
        "$_msrp_attempt" "$_msrp_next_epoch" "$_msrp_now" || :
    return 0
}

# Replace metadata for one generation only while the caller owns the normal
# configuration action.  This is deliberately not a general overwrite: a
# worker that observed generation N can never change a newer Save's intent.
merv_settings_reconcile_update() {
    _msru_generation="${1:-}"
    _msru_settings_digest="${2:-}"
    _msru_node_list_digest="${3:-}"
    _msru_status="${4:-retry}"
    _msru_attempt="${5:-0}"
    _msru_next_epoch="${6:-0}"

    merv_settings_reconcile_path_valid "$MERV_SETTINGS_RECONCILE_FILE" || return 1
    merv_settings_reconcile_generation_valid "$_msru_generation" || return 1
    merv_settings_reconcile_token_valid "$_msru_settings_digest" || return 1
    merv_settings_reconcile_token_valid "$_msru_node_list_digest" || return 1
    merv_settings_reconcile_status_valid "$_msru_status" || return 1
    merv_settings_reconcile_uint_valid "$_msru_attempt" "$MERV_SETTINGS_RECONCILE_MAX_ATTEMPT" || return 1
    merv_settings_reconcile_uint_valid "$_msru_next_epoch" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || return 1
    merv_settings_reconcile_read || return 1
    [ "$MERV_SETTINGS_RECONCILE_GENERATION" = "$_msru_generation" ] || return 1

    mkdir -p "$MERV_STATE_ROOT" 2>/dev/null || return 1
    chmod 700 "$MERV_STATE_ROOT" 2>/dev/null || return 1
    : "${MERV_SETTINGS_RECONCILE_SEQ:=0}"
    MERV_SETTINGS_RECONCILE_SEQ=$((MERV_SETTINGS_RECONCILE_SEQ + 1))
    _msru_tmp="$MERV_SETTINGS_RECONCILE_FILE.tmp.$$.$MERV_SETTINGS_RECONCILE_SEQ"
    _msru_now=$(date +%s 2>/dev/null || printf '0')
    merv_settings_reconcile_uint_valid "$_msru_now" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || _msru_now=0
    ( umask 077
        {
            printf 'format=1\n'
            printf 'generation=%s\n' "$_msru_generation"
            printf 'settings_digest=%s\n' "$_msru_settings_digest"
            printf 'node_list_digest=%s\n' "$_msru_node_list_digest"
            printf 'status=%s\n' "$_msru_status"
            printf 'attempt=%s\n' "$_msru_attempt"
            printf 'next_epoch=%s\n' "$_msru_next_epoch"
            printf 'updated_epoch=%s\n' "$_msru_now"
        } > "$_msru_tmp"
    ) 2>/dev/null || { rm -f "$_msru_tmp" 2>/dev/null || :; return 1; }
    chmod 600 "$_msru_tmp" 2>/dev/null || { rm -f "$_msru_tmp" 2>/dev/null || :; return 1; }
    mv -f "$_msru_tmp" "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null || {
        rm -f "$_msru_tmp" 2>/dev/null || :
        return 1
    }
    MERV_SETTINGS_RECONCILE_STATUS="$_msru_status"
    MERV_SETTINGS_RECONCILE_ATTEMPT="$_msru_attempt"
    MERV_SETTINGS_RECONCILE_NEXT_EPOCH="$_msru_next_epoch"
    merv_settings_reconcile_public_write "$_msru_generation" "$_msru_status" \
        "$_msru_attempt" "$_msru_next_epoch" "$_msru_now" || :
    return 0
}

# Clear only the currently published generation.  Callers should serialize
# this operation with their normal configuration/action owner; a generation
# mismatch is always treated as a no-op failure so a newer Save remains
# pending rather than being accidentally acknowledged by an older worker.
merv_settings_reconcile_clear() {
    _msrc_generation="${1:-}"
    merv_settings_reconcile_generation_valid "$_msrc_generation" || return 1
    merv_settings_reconcile_read || return 1
    [ "$_msrc_generation" = "$MERV_SETTINGS_RECONCILE_GENERATION" ] || return 1
    merv_settings_reconcile_path_valid "$MERV_SETTINGS_RECONCILE_FILE" || return 1
    rm -f "$MERV_SETTINGS_RECONCILE_FILE" 2>/dev/null || return 1
    # The protected marker is gone first; this terminal projection is only a
    # read-only observer result and cannot make the durable clear fail.
    _msrc_now=$(date +%s 2>/dev/null || printf '0')
    merv_settings_reconcile_uint_valid "$_msrc_now" "$MERV_SETTINGS_RECONCILE_MAX_EPOCH" || _msrc_now=0
    merv_settings_reconcile_public_write "$_msrc_generation" verified 0 0 \
        "$_msrc_now" || :
    return 0
}

# Return the current authoritative values needed to decide whether MAIN must
# converge settings to configured nodes.  This is deliberately derived from
# settings.json on every call; the marker is never an authority for topology.
merv_settings_reconcile_current_values() {
    _msrcv_settings=$(merv_settings_node_sync_digest "${SETTINGS_FILE:-}" 2>/dev/null) || return 1
    _msrcv_nodes=$(merv_node_list_digest 2>/dev/null) || return 1
    _msrcv_list=$(merv_node_list 2>/dev/null) || return 1
    case "$(json_get_flag AUTO_SYNC_SETTINGS 0 "${SETTINGS_FILE:-}" 2>/dev/null)" in
        1|true|yes) _msrcv_auto=1 ;;
        *) _msrcv_auto=0 ;;
    esac
    MERV_SETTINGS_RECONCILE_CURRENT_SETTINGS="$_msrcv_settings"
    MERV_SETTINGS_RECONCILE_CURRENT_NODES="$_msrcv_nodes"
    MERV_SETTINGS_RECONCILE_CURRENT_NODE_LIST="$_msrcv_list"
    MERV_SETTINGS_RECONCILE_CURRENT_AUTO="$_msrcv_auto"
    return 0
}

# Preserve malformed metadata for diagnostics without interpreting any of its
# fields.  A later publication is rebuilt solely from validated current
# settings and current configured nodes while the caller holds action ownership.
merv_settings_reconcile_quarantine_invalid() {
    merv_settings_reconcile_path_valid "$MERV_SETTINGS_RECONCILE_FILE" || return 1
    [ -e "$MERV_SETTINGS_RECONCILE_FILE" ] || return 1
    : "${MERV_SETTINGS_RECONCILE_SEQ:=0}"
    MERV_SETTINGS_RECONCILE_SEQ=$((MERV_SETTINGS_RECONCILE_SEQ + 1))
    _msrqi_now=$(date +%s 2>/dev/null || printf '0')
    case "$_msrqi_now" in ''|*[!0-9]*) _msrqi_now=0 ;; esac
    _msrqi_target="${MERV_SETTINGS_RECONCILE_FILE}.invalid.${_msrqi_now}.$$.${MERV_SETTINGS_RECONCILE_SEQ}"
    mv "$MERV_SETTINGS_RECONCILE_FILE" "$_msrqi_target" 2>/dev/null || return 1
    MERV_SETTINGS_RECONCILE_QUARANTINED="$_msrqi_target"
    # A malformed protected marker has no trustworthy generation.  Remove any
    # old observer projection so a no-node recovery cannot display stale work.
    merv_settings_reconcile_public_remove || :
    return 0
}

# Normalize a durable obligation to CURRENT validated settings and CURRENT
# configured nodes.  The optional `publish` request is used by an authoritative
# mutation; without it an absent marker remains absent.  Callers must hold the
# normal action serialization before invoking this helper.
merv_settings_reconcile_normalize_current() {
    _msrnc_mode="${1:-existing}"
    _msrnc_had_invalid=0
    case "$_msrnc_mode" in existing|publish) ;; *) return 1 ;; esac
    merv_settings_reconcile_current_values || return 1

    if ! merv_settings_reconcile_read; then
        if [ -e "$MERV_SETTINGS_RECONCILE_FILE" ]; then
            merv_settings_reconcile_quarantine_invalid || return 1
            _msrnc_had_invalid=1
        fi
        if [ -z "$MERV_SETTINGS_RECONCILE_CURRENT_NODE_LIST" ]; then
            return 0
        fi
        [ "$_msrnc_mode" = publish ] || [ "$_msrnc_had_invalid" -eq 1 ] || return 2
        if [ "$MERV_SETTINGS_RECONCILE_CURRENT_AUTO" = 1 ]; then _msrnc_status=pending; else _msrnc_status=paused; fi
        merv_settings_reconcile_publish "$MERV_SETTINGS_RECONCILE_CURRENT_SETTINGS" \
            "$MERV_SETTINGS_RECONCILE_CURRENT_NODES" "$_msrnc_status" 0 0
        return $?
    fi

    if [ -z "$MERV_SETTINGS_RECONCILE_CURRENT_NODE_LIST" ]; then
        merv_settings_reconcile_clear "$MERV_SETTINGS_RECONCILE_GENERATION"
        return $?
    fi

    if [ "$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST" != "$MERV_SETTINGS_RECONCILE_CURRENT_SETTINGS" ] || \
       [ "$MERV_SETTINGS_RECONCILE_NODE_LIST_DIGEST" != "$MERV_SETTINGS_RECONCILE_CURRENT_NODES" ]; then
        if [ "$MERV_SETTINGS_RECONCILE_CURRENT_AUTO" = 1 ]; then _msrnc_status=pending; else _msrnc_status=paused; fi
        merv_settings_reconcile_publish "$MERV_SETTINGS_RECONCILE_CURRENT_SETTINGS" \
            "$MERV_SETTINGS_RECONCILE_CURRENT_NODES" "$_msrnc_status" 0 0
        return $?
    fi

    if [ "$MERV_SETTINGS_RECONCILE_CURRENT_AUTO" != 1 ]; then
        [ "$MERV_SETTINGS_RECONCILE_STATUS" = paused ] && return 0
        merv_settings_reconcile_update "$MERV_SETTINGS_RECONCILE_GENERATION" \
            "$MERV_SETTINGS_RECONCILE_CURRENT_SETTINGS" "$MERV_SETTINGS_RECONCILE_CURRENT_NODES" \
            paused "$MERV_SETTINGS_RECONCILE_ATTEMPT" 0
        return $?
    fi
    if [ "$MERV_SETTINGS_RECONCILE_STATUS" = paused ]; then
        merv_settings_reconcile_update "$MERV_SETTINGS_RECONCILE_GENERATION" \
            "$MERV_SETTINGS_RECONCILE_CURRENT_SETTINGS" "$MERV_SETTINGS_RECONCILE_CURRENT_NODES" pending 0 0
    fi
    return $?
}

LIB_SETTINGS_RECONCILE_LOADED=1
