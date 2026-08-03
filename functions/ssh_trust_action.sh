#!/bin/sh
# Main-router-owned SSH trust probe, enrollment, and one-use resume worker.
#
# The browser can submit only a correlation token, challenge IDs, and
# accept/reject decisions.  Endpoint, MAC, key, fingerprint, node scope, and
# the original retry intent are loaded or produced by this worker and are
# revalidated before the complete trust database is replaced.

: "${MERV_BASE:=/jffs/addons/mervlan}"
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh" || exit 1
[ -n "${LOG_SETTINGS_LOADED:-}" ] || [ ! -f "$MERV_BASE/settings/log_settings.sh" ] || . "$MERV_BASE/settings/log_settings.sh" 2>/dev/null || :
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_identity.sh" || exit 1
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh" || exit 1
[ -n "${LIB_SSH_TRUST_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh_trust.sh" || exit 1
[ -n "${LIB_ACTION_LOCK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_lock.sh" || exit 1
[ -n "${LIB_ACTION_ACK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_ack.sh" || exit 1
[ -n "${LIB_ACTION_PROGRESS_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :

type merv_action_progress_init >/dev/null 2>&1 || merv_action_progress_init() { :; }
type merv_action_progress_phase >/dev/null 2>&1 || merv_action_progress_phase() { :; }
type merv_action_progress_complete >/dev/null 2>&1 || merv_action_progress_complete() { :; }
type merv_action_progress_fail >/dev/null 2>&1 || merv_action_progress_fail() { :; }

SSH_TRUST_ACTION="${1:-}"
SSH_TRUST_TOKEN="${2:-${MERV_PROGRESS_TOKEN:-}}"
# A resumed action keeps its loading record authoritative while a nested
# collection rechecks SSH trust. The nested probe may publish progress to this
# separate token, while acknowledgements and pending-review ownership stay on
# SSH_TRUST_TOKEN so a newly discovered key still opens the active review UI.
SSH_TRUST_PROGRESS_TOKEN="${MERV_SSH_TRUST_PROGRESS_TOKEN:-$SSH_TRUST_TOKEN}"
# var_settings.sh owns CUSTOM_SETTINGS_FILE and declares it readonly.  Keep
# using that canonical path instead of assigning it again after the settings
# library has been loaded.
SSH_TRUST_ACTION_LOCKED=0
SSH_TRUST_STATE_LOCKED=0
SSH_TRUST_STATE_NONCE=""
SSH_TRUST_STATE_START=""
SSH_TRUST_ACTION_NONCE=""
SSH_TRUST_ACTION_START=""
MERV_ACTION_ACK_PUBLISHED=0
trust_probe_silent_on_verified() {
    case "$MERV_SSH_TRUST_SILENT_IF_VERIFIED" in
        1|yes|on|true) return 0 ;;
        *) return 1 ;;
    esac
}

trust_probe_decision_exit_requested() {
    case "$MERV_SSH_TRUST_DECISION_EXIT" in
        1|yes|on|true) return 0 ;;
        *) return 1 ;;
    esac
}

trust_probe_finish_decision() {
    _tpfd_rc="${1:-1}"
    if [ "$_tpfd_rc" -eq 0 ] && trust_probe_decision_exit_requested; then
        return 10
    fi
    return "$_tpfd_rc"
}

SSH_TRUST_ACK_ACTION="${MERV_SSH_TRUST_ACK_ACTION:-sshtrustprobe_vlanmgr}"

trust_uint() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

trust_token_valid() {
    case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#1}" -le 96 ]
}

trust_id_valid() {
    case "${1:-}" in p.[0-9]*.[0-9]*.[0-9]*|c.[0-9]*.[0-9]*.*|r.[0-9]*.[0-9]*.[0-9]*) ;; *) return 1 ;; esac
    case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#1}" -le 160 ]
}

trust_file_value_valid() {
    [ -n "${1:-}" ] || return 1
    printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null && return 1
    case "$1" in *[!A-Za-z0-9._:@/+,-]*) return 1 ;; esac
}

trust_now() {
    _sta_now=$(date +%s 2>/dev/null || printf '0')
    trust_uint "$_sta_now" || _sta_now=0
    printf '%s\n' "$_sta_now"
}

trust_write_field() {
    _stwf_dir="$1"
    _stwf_name="$2"
    _stwf_value="$3"
    case "$_stwf_name" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    trust_file_value_valid "$_stwf_value" || return 1
    [ -d "$_stwf_dir" ] || return 1
    _stwf_tmp="$_stwf_dir/.${_stwf_name}.tmp.$$"
    printf '%s\n' "$_stwf_value" > "$_stwf_tmp" 2>/dev/null || { rm -f "$_stwf_tmp"; return 1; }
    chmod 600 "$_stwf_tmp" 2>/dev/null || { rm -f "$_stwf_tmp"; return 1; }
    mv -f "$_stwf_tmp" "$_stwf_dir/$_stwf_name" 2>/dev/null || { rm -f "$_stwf_tmp"; return 1; }
}

trust_read_field() {
    _strf_dir="$1"
    _strf_name="$2"
    case "$_strf_name" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ -f "$_strf_dir/$_strf_name" ] || return 1
    _strf_value=$(cat "$_strf_dir/$_strf_name" 2>/dev/null) || return 1
    trust_file_value_valid "$_strf_value" || return 1
    printf '%s\n' "$_strf_value"
}

trust_digest_file() {
    _stdf_file="$1"
    [ -f "$_stdf_file" ] || return 1
    if merv_has sha256sum; then
        _stdf_hex=$(sha256sum "$_stdf_file" 2>/dev/null | awk '{print $1}')
        case "$_stdf_hex" in [0-9A-Fa-f][0-9A-Fa-f]*) printf 'sha256:%s\n' "$_stdf_hex"; return 0 ;; esac
    fi
    if merv_has cksum; then
        _stdf_ck=$(cksum "$_stdf_file" 2>/dev/null | awk '{print $1":"$2}')
        case "$_stdf_ck" in [0-9]*:[0-9]*) printf 'cksum:%s\n' "$_stdf_ck"; return 0 ;; esac
    fi
    # ASUSWRT may provide OpenSSL without either sha256sum or cksum.  The
    # request and node-set digests are integrity breadcrumbs, so keep the
    # cryptographic SHA-256 contract instead of falling back to a weaker hash.
    if merv_has openssl; then
        _stdf_hex=$(openssl dgst -sha256 "$_stdf_file" 2>/dev/null | sed 's/.*= //' | tr -d '\r\n')
        case "$_stdf_hex" in
            [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*) printf 'sha256:%s\n' "$_stdf_hex"; return 0 ;;
        esac
    fi
    return 1
}

trust_digest_string() {
    _stds_tmp="$MERV_SSH_TRUST_STAGING_ROOT/.digest.$$"
    printf '%s' "${1:-}" > "$_stds_tmp" 2>/dev/null || return 1
    _stds_digest=$(trust_digest_file "$_stds_tmp")
    _stds_rc=$?
    rm -f "$_stds_tmp" 2>/dev/null || _stds_rc=1
    [ "$_stds_rc" -eq 0 ] || return "$_stds_rc"
    printf '%s\n' "$_stds_digest"
}

trust_transport_value() {
    _sttv_field="$1"
    case "$_sttv_field" in pending_id)
        [ -n "${MERV_SSH_TRUST_PENDING_ID:-}" ] && { printf '%s\n' "$MERV_SSH_TRUST_PENDING_ID"; return 0; } ;;
    decisions)
        [ -n "${MERV_SSH_TRUST_DECISIONS:-}" ] && { printf '%s\n' "$MERV_SSH_TRUST_DECISIONS"; return 0; } ;;
    resume_id)
        [ -n "${MERV_SSH_TRUST_RESUME_ID:-}" ] && { printf '%s\n' "$MERV_SSH_TRUST_RESUME_ID"; return 0; } ;;
    node_id)
        [ -n "${MERV_SSH_TRUST_NODE_ID:-}" ] && { printf '%s\n' "$MERV_SSH_TRUST_NODE_ID"; return 0; } ;;
    esac
    case "$_sttv_field" in pending_id|decisions|resume_id|node_id) ;; *) return 1 ;; esac
    _sttv_key="vlanmgr_sshtrust_$_sttv_field"
    for _sttv_file in "${MERV_SSH_TRUST_TRANSPORT_FILE:-}" "$CUSTOM_SETTINGS_FILE"; do
        [ -n "$_sttv_file" ] && [ -f "$_sttv_file" ] || continue
        _sttv_value=$(grep "^${_sttv_key}[=[:space:]]" "$_sttv_file" 2>/dev/null | tail -n 1 | sed "s/^${_sttv_key}[=[:space:]]*//")
        [ -n "$_sttv_value" ] || continue
        printf '%s\n' "$_sttv_value"
        return 0
    done
    return 1
}

trust_action_allowlist() {
    case "${1:-}" in sync_vlanmgr|syncsettings_vlanmgr|apply_vlanmgr|executenodes_vlanmgr|executenodesonly_vlanmgr|collectclients_vlanmgr|none) return 0 ;; *) return 1 ;; esac
}

trust_state_lock() {
    merv_ssh_trust_init >/dev/null 2>&1 || return 1
    merv_action_lock_acquire "$MERV_SSH_TRUST_LOCK_PATH"
    _stsl_rc=$?
    [ "$_stsl_rc" -eq 0 ] || return "$_stsl_rc"
    SSH_TRUST_STATE_LOCKED=1
    SSH_TRUST_STATE_NONCE="$MERV_ACTION_LOCK_NONCE"
    SSH_TRUST_STATE_START="$MERV_ACTION_LOCK_START"
    return 0
}

trust_state_unlock() {
    [ "$SSH_TRUST_STATE_LOCKED" -eq 1 ] || return 0
    merv_action_lock_release "$MERV_SSH_TRUST_LOCK_PATH" "$SSH_TRUST_STATE_NONCE" "$SSH_TRUST_STATE_START" >/dev/null 2>&1 || return 1
    SSH_TRUST_STATE_LOCKED=0
    return 0
}

trust_action_unlock() {
    [ "$SSH_TRUST_ACTION_LOCKED" -eq 1 ] || return 0
    merv_action_lock_release "${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}" "$SSH_TRUST_ACTION_NONCE" "$SSH_TRUST_ACTION_START" >/dev/null 2>&1 || return 1
    SSH_TRUST_ACTION_LOCKED=0
    return 0
}

trust_release_all_locks() {
    _stral_rc=0
    if [ "${SSH_TRUST_STATE_LOCKED:-0}" -eq 1 ]; then
        trust_state_unlock || _stral_rc=1
    fi
    if [ "${SSH_TRUST_ACTION_LOCKED:-0}" -eq 1 ]; then
        trust_action_unlock || _stral_rc=1
    fi
    return "$_stral_rc"
}

trust_cancel_challenge() {
    _stcc_id="$1"
    trust_id_valid "$_stcc_id" || return 1
    _stcc_dir="$MERV_SSH_TRUST_PENDING_ROOT/$_stcc_id"
    [ -d "$_stcc_dir" ] || return 0
    _stcc_state=$(trust_read_field "$_stcc_dir" state 2>/dev/null || printf '')
    case "$_stcc_state" in
        pending) trust_write_field "$_stcc_dir" state canceled ;;
        expired|canceled|rejected|failed|verified) return 0 ;;
        *) return 1 ;;
    esac
}

trust_mark_request() {
    _stmr_dir="$1"
    _stmr_state="$2"
    [ -d "$_stmr_dir" ] || return 1
    trust_write_field "$_stmr_dir" state "$_stmr_state" || return 1
    case "$_stmr_state" in expired|canceled|failed|completed|consumed) trust_write_field "$_stmr_dir" resume_id none || return 1 ;; esac
}

trust_cleanup_files() {
    _stcf_rc=0
    for _stcf_file in "$@"; do
        [ -n "$_stcf_file" ] || continue
        [ -e "$_stcf_file" ] || continue
        rm -f "$_stcf_file" 2>/dev/null || {
            printf '%s\n' "[ERROR] SSH trust temporary cleanup failed: $_stcf_file" >&2
            _stcf_rc=1
        }
    done
    return "$_stcf_rc"
}

trust_cancel_challenge_list() {
    _stcl_rc=0
    while IFS= read -r _stcl_id || [ -n "$_stcl_id" ]; do
        [ -n "$_stcl_id" ] || continue
        trust_cancel_challenge "$_stcl_id" || {
            printf '%s\n' "[ERROR] SSH trust challenge cancellation failed: $_stcl_id" >&2
            _stcl_rc=1
        }
    done < "$1"
    return "$_stcl_rc"
}

trust_request_dir() {
    _strd_id="$1"
    trust_id_valid "$_strd_id" || return 1
    case "$_strd_id" in p.*) ;; *) return 1 ;; esac
    _strd_dir="$MERV_SSH_TRUST_REQUESTS_ROOT/$_strd_id"
    merv_ssh_trust_path_valid "$_strd_dir" || return 1
    [ -d "$_strd_dir" ] || return 1
    printf '%s\n' "$_strd_dir"
}

trust_request_expired() {
    _stre_dir="$1"
    _stre_expires=$(trust_read_field "$_stre_dir" expires_epoch 2>/dev/null) || return 1
    _stre_now=$(trust_now)
    trust_uint "$_stre_expires" && trust_uint "$_stre_now" || return 1
    [ "$_stre_now" -gt "$_stre_expires" ]
}

trust_request_result() {
    _strr_dir="$1"
    [ -f "$_strr_dir/result.json" ] || return 1
    cat "$_strr_dir/result.json" 2>/dev/null
}

trust_request_pending_count() {
    _strpc_dir="$1"
    [ -s "$_strpc_dir/challenge_ids" ] || return 1
    _strpc_count=0
    while IFS= read -r _strpc_id || [ -n "$_strpc_id" ]; do
        [ -n "$_strpc_id" ] || continue
        trust_id_valid "$_strpc_id" || return 1
        case "$_strpc_id" in c.*) ;; *) return 1 ;; esac
        _strpc_state=$(trust_read_field "$MERV_SSH_TRUST_PENDING_ROOT/$_strpc_id" state 2>/dev/null) || return 1
        case "$_strpc_state" in
            pending) _strpc_count=$((_strpc_count + 1)) ;;
            verified) ;;
            *) return 1 ;;
        esac
    done < "$_strpc_dir/challenge_ids"
    printf '%s\n' "$_strpc_count"
}

trust_request_pending_result() {
    _strpr_dir="$1"
    _strpr_pending="$2"
    trust_id_valid "$_strpr_pending" || return 1
    case "$_strpr_pending" in p.*) ;; *) return 1 ;; esac
    _strpr_action=$(trust_read_field "$_strpr_dir" original_action 2>/dev/null) || return 1
    _strpr_digest=$(trust_read_field "$_strpr_dir" node_set_digest 2>/dev/null) || return 1
    _strpr_expires=$(trust_read_field "$_strpr_dir" expires_epoch 2>/dev/null) || return 1
    _strpr_now=$(trust_now)
    trust_uint "$_strpr_expires" && trust_uint "$_strpr_now" || return 1
    _strpr_remaining=$((_strpr_expires - _strpr_now))
    [ "$_strpr_remaining" -ge 0 ] 2>/dev/null || _strpr_remaining=0
    [ -s "$_strpr_dir/challenge_ids" ] || return 1
    _strpr_result='{"pending_id":"'$(trust_json_escape "$_strpr_pending")'","action":"'$(trust_json_escape "$_strpr_action")'","nodes":['
    _strpr_first=1; _strpr_count=0
    while IFS= read -r _strpr_id || [ -n "$_strpr_id" ]; do
        [ -n "$_strpr_id" ] || continue
        trust_id_valid "$_strpr_id" || return 1
        case "$_strpr_id" in c.*) ;; *) return 1 ;; esac
        _strpr_cdir="$MERV_SSH_TRUST_PENDING_ROOT/$_strpr_id"
        _strpr_state=$(trust_read_field "$_strpr_cdir" state 2>/dev/null) || return 1
        case "$_strpr_state" in
            verified) continue ;;
            pending) ;;
            *) return 1 ;;
        esac
        merv_ssh_trust_validate_challenge "$_strpr_cdir" || return 1
        [ "$(trust_read_field "$_strpr_cdir" request_id 2>/dev/null)" = "$_strpr_pending" ] || return 1
        [ "$(trust_read_field "$_strpr_cdir" request_digest 2>/dev/null)" = "$_strpr_digest" ] || return 1
        _strpr_slot=$(trust_read_field "$_strpr_cdir" slot 2>/dev/null) || return 1
        _strpr_host=$(trust_read_field "$_strpr_cdir" host 2>/dev/null) || return 1
        _strpr_mac=$(trust_read_field "$_strpr_cdir" mac 2>/dev/null) || return 1
        _strpr_port=$(trust_read_field "$_strpr_cdir" port 2>/dev/null) || return 1
        _strpr_alg=$(trust_read_field "$_strpr_cdir" algorithm 2>/dev/null) || return 1
        _strpr_fp=$(trust_read_field "$_strpr_cdir" fingerprint_sha256 2>/dev/null) || return 1
        _strpr_status=$(trust_read_field "$_strpr_cdir" probe_status 2>/dev/null) || return 1
        _strpr_oldfp=$(cat "$_strpr_cdir/old_fingerprint_sha256" 2>/dev/null || printf '')
        [ -z "$_strpr_oldfp" ] || merv_ssh_trust_fingerprint_valid "$_strpr_oldfp" || return 1
        case "$_strpr_status" in 6) _strpr_label=unverified ;; 8) _strpr_label=mismatch ;; *) return 1 ;; esac
        _strpr_row=$(trust_json_node "$_strpr_slot" "$_strpr_host" "$_strpr_mac" "$_strpr_port" "$_strpr_label" "$_strpr_alg" "$_strpr_fp" "$_strpr_id" "$_strpr_oldfp") || return 1
        [ "$_strpr_first" -eq 1 ] || _strpr_result="$_strpr_result,"
        _strpr_result="$_strpr_result$_strpr_row"
        _strpr_first=0; _strpr_count=$((_strpr_count + 1))
    done < "$_strpr_dir/challenge_ids"
    _strpr_result="$_strpr_result],\"challenge_count\":$_strpr_count,\"node_set_digest\":\"$(trust_json_escape "$_strpr_digest")\",\"expires_epoch\":$_strpr_expires,\"expires_in_sec\":$_strpr_remaining}"
    printf '%s\n' "$_strpr_result"
}

trust_request_publish_pending_result() {
    _strpp_dir="$1"
    _strpp_pending="$2"
    _strpp_result=$(trust_request_pending_result "$_strpp_dir" "$_strpp_pending") || return 1
    _strpp_tmp="$_strpp_dir/.result.json.tmp.$$"
    ( umask 077; printf '%s\n' "$_strpp_result" > "$_strpp_tmp" ) 2>/dev/null || { rm -f "$_strpp_tmp" 2>/dev/null; return 1; }
    chmod 600 "$_strpp_tmp" 2>/dev/null || { rm -f "$_strpp_tmp" 2>/dev/null; return 1; }
    mv -f "$_strpp_tmp" "$_strpp_dir/result.json" 2>/dev/null || { rm -f "$_strpp_tmp" 2>/dev/null; return 1; }
}

trust_request_cancel() {
    _strc_dir="$1"
    [ -s "$_strc_dir/challenge_ids" ] || return 1
    _strc_ids="$MERV_SSH_TRUST_STAGING_ROOT/.cancel-challenges.$$"
    cp "$_strc_dir/challenge_ids" "$_strc_ids" 2>/dev/null || return 1
    _strc_rc=0
    while IFS= read -r _strc_id || [ -n "$_strc_id" ]; do
        [ -n "$_strc_id" ] || continue
        trust_id_valid "$_strc_id" || { _strc_rc=1; break; }
        case "$_strc_id" in c.*) ;; *) _strc_rc=1; break ;; esac
    done < "$_strc_ids"
    if [ "$_strc_rc" -eq 0 ]; then
        trust_cancel_challenge_list "$_strc_ids" || _strc_rc=1
    fi
    trust_mark_request "$_strc_dir" canceled || _strc_rc=1
    trust_cleanup_files "$_strc_ids" || _strc_rc=1
    return "$_strc_rc"
}

trust_find_existing_pending() {
    _stfe_token="$1"
    _stfe_action="$2"
    trust_token_valid "$_stfe_token" || return 1
    trust_action_allowlist "$_stfe_action" || return 1
    for _stfe_dir in "$MERV_SSH_TRUST_REQUESTS_ROOT"/p.*; do
        [ -d "$_stfe_dir" ] || continue
        _stfe_state=$(trust_read_field "$_stfe_dir" state 2>/dev/null) || continue
        [ "$_stfe_state" = pending ] || continue
        trust_request_expired "$_stfe_dir" && { trust_mark_request "$_stfe_dir" expired; continue; }
        _stfe_saved_token=$(trust_read_field "$_stfe_dir" request_token 2>/dev/null) || continue
        _stfe_saved_action=$(trust_read_field "$_stfe_dir" original_action 2>/dev/null) || continue
        [ "$_stfe_saved_token" = "$_stfe_token" ] && [ "$_stfe_saved_action" = "$_stfe_action" ] || continue
        printf '%s\n' "$_stfe_dir"
        return 0
    done
    return 1
}

trust_json_escape() {
    action_ack_json_escape "$1"
}

trust_json_node() {
    _stjn_slot="$1"; _stjn_host="$2"; _stjn_mac="$3"; _stjn_port="$4"; _stjn_status="$5"; _stjn_alg="$6"; _stjn_fp="$7"; _stjn_challenge="$8"; _stjn_oldfp="$9"
    _stjn_node=$(merv_ssh_trust_node_id "$_stjn_slot" "$_stjn_mac" "$_stjn_host" "$_stjn_port") || return 1
    _stjn_out="{\"slot\":$_stjn_slot,\"node_id\":\"$(trust_json_escape "$_stjn_node")\",\"mac\":\"$(trust_json_escape "$_stjn_mac")\",\"host\":\"$(trust_json_escape "$_stjn_host")\",\"port\":$_stjn_port,\"status\":\"$(trust_json_escape "$_stjn_status")\",\"algorithm\":\"$(trust_json_escape "$_stjn_alg")\",\"fingerprint\":\"$(trust_json_escape "$_stjn_fp")\",\"challenge_id\":\"$(trust_json_escape "$_stjn_challenge")\""
    [ -n "$_stjn_oldfp" ] && _stjn_out="$_stjn_out,\"old_fingerprint\":\"$(trust_json_escape "$_stjn_oldfp")\""
    printf '%s}\n' "$_stjn_out"
}

trust_json_blocker_node() {
    _stjb_slot="$1"; _stjb_host="$2"; _stjb_mac="$3"; _stjb_port="$4"; _stjb_status="$5"; _stjb_reason="$6"
    _stjb_node=$(merv_ssh_trust_node_id "$_stjb_slot" "$_stjb_mac" "$_stjb_host" "$_stjb_port") || return 1
    _stjb_out="{\"slot\":$_stjb_slot,\"node_id\":\"$(trust_json_escape "$_stjb_node")\",\"mac\":\"$(trust_json_escape "$_stjb_mac")\",\"host\":\"$(trust_json_escape "$_stjb_host")\",\"port\":$_stjb_port,\"status\":\"$(trust_json_escape "$_stjb_status")\",\"algorithm\":\"\",\"fingerprint\":\"\",\"challenge_id\":\"\",\"reason\":\"$(trust_json_escape "$_stjb_reason")\"}"
    printf '%s\n' "$_stjb_out"
}

trust_publish_existing_pending() {
    _stpep_dir="$1"
    _stpep_result=$(trust_request_result "$_stpep_dir") || return 1
    action_ack_write "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" ssh_trust_pending "$_stpep_result" "An SSH trust decision is already pending." '[]' ssh-trust-pending
    _stpep_ack_rc=$?
    trust_probe_finish_decision "$_stpep_ack_rc"
}

trust_probe_selected_slots_valid() {
    _stpsv_slots="${MERV_SSH_TRUST_NODE_SLOTS:-}"
    [ -n "$_stpsv_slots" ] || return 0
    case "$_stpsv_slots" in
        *[!0-9.]*|.*|*..*|*.) return 1 ;;
    esac
    _stpsv_max="${MERV_MAX_NODES:-10}"
    case "$_stpsv_max" in ''|*[!0-9]*) _stpsv_max=10 ;; esac
    _stpsv_seen=" "
    for _stpsv_slot in $(printf '%s' "$_stpsv_slots" | tr '.' ' '); do
        case "$_stpsv_slot" in
            ''|0|0[0-9]*) return 1 ;;
        esac
        [ "$_stpsv_slot" -ge 1 ] 2>/dev/null && [ "$_stpsv_slot" -le "$_stpsv_max" ] 2>/dev/null || return 1
        case "$_stpsv_seen" in *" $_stpsv_slot "*) return 1 ;; esac
        _stpsv_seen="${_stpsv_seen}${_stpsv_slot} "
    done
    return 0
}

trust_probe_apply_selected_slots() {
    _stpas_nodes="$1"
    _stpas_slots="${MERV_SSH_TRUST_NODE_SLOTS:-}"
    [ -n "$_stpas_slots" ] || return 0
    trust_probe_selected_slots_valid || return 1
    _stpas_stage="${_stpas_nodes}.selected.$$"
    : > "$_stpas_stage" 2>/dev/null || return 3
    for _stpas_slot in $(printf '%s' "$_stpas_slots" | tr '.' ' '); do
        awk -v wanted="$_stpas_slot" '$1 == wanted && NF == 2 { print; found=1 } END { exit found ? 0 : 1 }' "$_stpas_nodes" >> "$_stpas_stage" 2>/dev/null || {
            rm -f "$_stpas_stage"
            return 2
        }
    done
    [ -s "$_stpas_stage" ] || { rm -f "$_stpas_stage"; return 2; }
    mv -f "$_stpas_stage" "$_stpas_nodes" 2>/dev/null || { rm -f "$_stpas_stage"; return 3; }
    return 0
}

trust_probe() {
    _stp_original_action="${MERV_SSH_TRUST_ORIGINAL_ACTION:-none}"
    trust_action_allowlist "$_stp_original_action" || _stp_original_action=none
    [ "$_stp_original_action" != none ] && SSH_TRUST_ACK_ACTION="$_stp_original_action"
    merv_action_progress_init "$SSH_TRUST_PROGRESS_TOKEN" "$SSH_TRUST_ACK_ACTION" "SSH trust verification" "Checking SSH capability..."
    merv_action_progress_phase capability "Checking verified host-key capability..."
    trust_state_lock || return 75
    merv_ssh_trust_prune_pending >/dev/null 2>&1 || { trust_state_unlock; return 75; }

    if _stp_existing=$(trust_find_existing_pending "$SSH_TRUST_TOKEN" "$_stp_original_action" 2>/dev/null); then
        trust_state_unlock
        merv_action_progress_phase pending "Using the existing SSH trust decision..."
        trust_publish_existing_pending "$_stp_existing"
        return $?
    fi

    _stp_nodes="$MERV_SSH_TRUST_STAGING_ROOT/.probe-nodes.$$"
    _stp_rows="$MERV_SSH_TRUST_STAGING_ROOT/.probe-rows.$$"
    _stp_challenges="$MERV_SSH_TRUST_STAGING_ROOT/.probe-challenges.$$"
    _stp_blockers="$MERV_SSH_TRUST_STAGING_ROOT/.probe-blockers.$$"
    : > "$_stp_nodes" || { trust_state_unlock; return 75; }
    : > "$_stp_rows" || { trust_cleanup_files "$_stp_nodes"; trust_state_unlock; return 75; }
    : > "$_stp_challenges" || { trust_cleanup_files "$_stp_nodes" "$_stp_rows"; trust_state_unlock; return 75; }
    : > "$_stp_blockers" || { trust_cleanup_files "$_stp_nodes" "$_stp_rows" "$_stp_challenges"; trust_state_unlock; return 75; }
    if ! merv_node_list > "$_stp_nodes" 2>/dev/null; then
        trust_cleanup_files "$_stp_nodes" "$_stp_rows" "$_stp_challenges" "$_stp_blockers"
        trust_state_unlock
        merv_action_progress_fail "SSH trust probe could not enumerate configured nodes"
        action_ack_error "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" '{"reason":"node-enumeration-failed"}' "SSH trust probe could not enumerate configured nodes." '[]' ssh-trust-probe
        return 75
    fi
    trust_probe_apply_selected_slots "$_stp_nodes"
    _stp_selection_rc=$?
    if [ "$_stp_selection_rc" -ne 0 ]; then
        trust_cleanup_files "$_stp_nodes" "$_stp_rows" "$_stp_challenges" "$_stp_blockers"
        trust_state_unlock
        if [ "$_stp_selection_rc" -eq 2 ]; then
            _stp_selection_reason=selected-node-unavailable
            _stp_selection_message="One or more selected nodes are no longer configured. Refresh the trusted devices list and try again."
        else
            _stp_selection_reason=invalid-node-selection
            _stp_selection_message="The SSH trust probe rejected the selected node list."
        fi
        merv_action_progress_fail "$_stp_selection_message"
        action_ack_error "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" "{\"reason\":\"$_stp_selection_reason\"}" "$_stp_selection_message" '[]' ssh-trust-invalid
        return 2
    fi
    [ -s "$_stp_nodes" ] || {
        trust_cleanup_files "$_stp_nodes" "$_stp_rows" "$_stp_challenges" "$_stp_blockers" || {
            trust_state_unlock
            merv_action_progress_fail "SSH trust probe cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" '{"reason":"cleanup-failed"}' "SSH trust probe cleanup failed." '[]' ssh-trust-error
            return 75
        }
        trust_state_unlock || return 75
        if trust_probe_silent_on_verified; then
            # A normal silent probe shares the caller's progress token and
            # must not terminally complete that caller's loading action. A
            # resume probe instead uses an isolated child token; close it so
            # it cannot remain a false running host-key status indefinitely.
            if [ "$SSH_TRUST_PROGRESS_TOKEN" != "$SSH_TRUST_TOKEN" ]; then
                merv_action_progress_complete "No configured nodes require SSH trust"
            fi
            return 0
        fi
        merv_action_progress_complete "No configured nodes require SSH trust"
        action_ack_ok "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" '{"nodes":[]}' "No configured nodes require SSH trust." '[]'
        return $?
    }

    _stp_count=0; _stp_challenge_count=0; _stp_blocker_count=0; _stp_bad_reason=""; _stp_bad_code=""
    merv_action_progress_phase probe "Probing configured node host keys..."
    while IFS=' ' read -r _stp_slot _stp_host _stp_extra || [ -n "$_stp_slot" ]; do
        [ -z "$_stp_extra" ] || { _stp_bad_reason=malformed-node-set; _stp_bad_code=ssh-trust-invalid; break; }
        _stp_mac=$(json_get_flag "AUTO_NODE${_stp_slot}_MAC" "" "$SETTINGS_FILE" 2>/dev/null)
        _stp_mac=$(merv_ssh_trust_mac_or_none "$_stp_mac" 2>/dev/null) || { _stp_bad_reason=invalid-node-mac; _stp_bad_code=ssh-trust-invalid; break; }
        _stp_port=$(merv_ssh_trust_normalize_port "${MERV_NODE_SSH_PORT:-22}" 2>/dev/null) || { _stp_bad_reason=invalid-port; _stp_bad_code=ssh-trust-invalid; break; }
        _stp_count=$((_stp_count + 1))
        [ "$_stp_count" -le "${MERV_SSH_TRUST_MAX_PENDING:-64}" ] 2>/dev/null || { _stp_bad_reason=too-many-nodes; _stp_bad_code=ssh-trust-invalid; break; }
        SSH_TRUST_FINGERPRINT=""; SSH_TRUST_PUBLIC_KEY=""
        merv_ssh_hostkey_probe "$_stp_slot" "$_stp_host" "$_stp_port" "$_stp_mac"
        _stp_rc=$?
        case "$_stp_rc" in
            0)
                trust_json_node "$_stp_slot" "$SSH_PROBE_HOST" "$SSH_PROBE_MAC" "$SSH_PROBE_PORT" verified "$SSH_PROBE_ALGORITHM" "$SSH_PROBE_FINGERPRINT" "" "" >> "$_stp_rows" || { _stp_bad_reason=publication-failed; _stp_bad_code=ssh-trust-error; break; }
                ;;
            6|8)
                _stp_challenge=$(merv_ssh_trust_issue_challenge "$_stp_slot" "$_stp_host" "$_stp_port" "$_stp_mac" 2>/dev/null)
                _stp_challenge_rc=$?
                [ "$_stp_challenge_rc" -eq 0 ] || { _stp_bad_reason=challenge-failed; _stp_bad_code=ssh-trust-error; break; }
                printf '%s\n' "$_stp_challenge" >> "$_stp_challenges" || { _stp_bad_reason=publication-failed; _stp_bad_code=ssh-trust-error; break; }
                _stp_challenge_count=$((_stp_challenge_count + 1))
                _stp_oldfp=$(cat "$MERV_SSH_TRUST_PENDING_ROOT/$_stp_challenge/old_fingerprint_sha256" 2>/dev/null)
                _stp_status=unverified; [ "$_stp_rc" -eq 8 ] && _stp_status=mismatch
                trust_json_node "$_stp_slot" "$SSH_PROBE_HOST" "$SSH_PROBE_MAC" "$SSH_PROBE_PORT" "$_stp_status" "$SSH_PROBE_ALGORITHM" "$SSH_PROBE_FINGERPRINT" "$_stp_challenge" "$_stp_oldfp" >> "$_stp_rows" || { _stp_bad_reason=publication-failed; _stp_bad_code=ssh-trust-error; break; }
                ;;
            7)
                _stp_reason="${MERV_SSH_TRUST_LAST_REASON:-capability-unknown}"
                _stp_status=probe_failed
                case "$_stp_reason" in
                    capability-*|fingerprint-unavailable|probe-malformed) _stp_status=capability_unknown ;;
                esac
                trust_json_blocker_node "$_stp_slot" "$_stp_host" "$_stp_mac" "$_stp_port" "$_stp_status" "$_stp_reason" >> "$_stp_blockers" || { _stp_bad_reason=publication-failed; _stp_bad_code=ssh-trust-error; break; }
                _stp_blocker_count=$((_stp_blocker_count + 1))
                ;;
            2|3|9)
                _stp_reason="${MERV_SSH_TRUST_LAST_REASON:-probe-failed}"
                trust_json_blocker_node "$_stp_slot" "$_stp_host" "$_stp_mac" "$_stp_port" probe_failed "$_stp_reason" >> "$_stp_blockers" || { _stp_bad_reason=publication-failed; _stp_bad_code=ssh-trust-error; break; }
                _stp_blocker_count=$((_stp_blocker_count + 1))
                ;;
            *)
                _stp_reason=probe-failed
                trust_json_blocker_node "$_stp_slot" "$_stp_host" "$_stp_mac" "$_stp_port" probe_failed "$_stp_reason" >> "$_stp_blockers" || { _stp_bad_reason=publication-failed; _stp_bad_code=ssh-trust-error; break; }
                _stp_blocker_count=$((_stp_blocker_count + 1))
                ;;
        esac
    done < "$_stp_nodes"

    # A capability/transport blocker is not a safe first-use challenge.  Keep
    # all actionable challenges from this pass cancelled and publish the
    # complete blocker list as an explicit trust-gated result so the loading
    # flow can show the user which node(s) need setup or a fresh probe.
    if [ -z "$_stp_bad_reason" ] && [ "$_stp_blocker_count" -gt 0 ] 2>/dev/null; then
        _stp_cancel_rc=0
        trust_cancel_challenge_list "$_stp_challenges" || _stp_cancel_rc=1
        _stp_cleanup_rc=0
        trust_cleanup_files "$_stp_nodes" "$_stp_rows" "$_stp_challenges" || _stp_cleanup_rc=1
        _stp_result='{"reason":"ssh-trust-preflight-blocked","nodes":['
        _stp_first=1
        while IFS= read -r _stp_row || [ -n "$_stp_row" ]; do
            [ "$_stp_first" -eq 1 ] || _stp_result="$_stp_result,"
            _stp_result="$_stp_result$_stp_row"
            _stp_first=0
        done < "$_stp_blockers"
        _stp_result="$_stp_result]}"
        trust_cleanup_files "$_stp_blockers" || _stp_cleanup_rc=1
        trust_state_unlock || _stp_cleanup_rc=1
        if [ "$_stp_cancel_rc" -ne 0 ] || [ "$_stp_cleanup_rc" -ne 0 ]; then
            merv_action_progress_fail "SSH trust preflight was blocked and cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" '{"reason":"cleanup-failed"}' "SSH trust preflight was blocked and cleanup failed; no trust records were changed." '[]' ssh-trust-error
            return 75
        fi
        merv_action_progress_fail "SSH trust preflight requires node setup or a fresh probe"
        action_ack_ssh_trust_required "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" "$_stp_result" "SSH host-key preflight is blocked for one or more nodes. Resolve the listed issue(s) before node changes." '[]'
        _stp_ack_rc=$?
        trust_probe_finish_decision "$_stp_ack_rc"
    fi

    if [ -n "$_stp_bad_reason" ]; then
        _stp_cancel_rc=0
        trust_cancel_challenge_list "$_stp_challenges" || _stp_cancel_rc=1
        _stp_cleanup_rc=0
        trust_cleanup_files "$_stp_nodes" "$_stp_rows" "$_stp_challenges" "$_stp_blockers" || _stp_cleanup_rc=1
        trust_state_unlock || _stp_cleanup_rc=1
        if [ "$_stp_cancel_rc" -ne 0 ] || [ "$_stp_cleanup_rc" -ne 0 ]; then
            merv_action_progress_fail "SSH trust probe stopped and cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" '{"reason":"cleanup-failed"}' "SSH trust probe stopped and cleanup failed; no trust records were changed." '[]' ssh-trust-error
            return 75
        fi
        merv_action_progress_fail "SSH trust probe stopped: $_stp_bad_reason"
        action_ack_error "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" '{"reason":"ssh-trust-probe-failed"}' "SSH trust probe stopped: $_stp_bad_reason." '[]' "$_stp_bad_code"
        return 7
    fi

    if [ "$_stp_challenge_count" -eq 0 ]; then
        _stp_result='{"nodes":['
        _stp_first=1
        while IFS= read -r _stp_row || [ -n "$_stp_row" ]; do [ "$_stp_first" -eq 1 ] || _stp_result="$_stp_result,"; _stp_result="$_stp_result$_stp_row"; _stp_first=0; done < "$_stp_rows"
        _stp_result="$_stp_result]}"
        trust_cleanup_files "$_stp_nodes" "$_stp_rows" "$_stp_challenges" "$_stp_blockers" || {
            trust_state_unlock
            merv_action_progress_fail "SSH trust probe cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" '{"reason":"cleanup-failed"}' "SSH trust probe cleanup failed." '[]' ssh-trust-error
            return 75
        }
        trust_state_unlock || return 75
        if trust_probe_silent_on_verified; then
            if [ "$SSH_TRUST_PROGRESS_TOKEN" != "$SSH_TRUST_TOKEN" ]; then
                merv_action_progress_complete "All configured nodes already have verified SSH host keys"
            fi
            return 0
        fi
        merv_action_progress_complete "All configured nodes already have verified SSH host keys"
        action_ack_ok "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" "$_stp_result" "All configured nodes have verified SSH host keys." '[]'
        return $?
    fi

    _stp_now=$(trust_now); _stp_start=$(merv_identity_current_start 2>/dev/null || printf '0')
    _stp_request_id="p.$_stp_now.$$.$_stp_start"
    trust_id_valid "$_stp_request_id" || { trust_state_unlock; return 75; }
    _stp_tmp_dir="$MERV_SSH_TRUST_REQUESTS_ROOT/.$_stp_request_id.tmp.$$"
    _stp_dir="$MERV_SSH_TRUST_REQUESTS_ROOT/$_stp_request_id"
    mkdir "$_stp_tmp_dir" 2>/dev/null || { trust_state_unlock; return 75; }
    chmod 700 "$_stp_tmp_dir" 2>/dev/null || { rmdir "$_stp_tmp_dir"; trust_state_unlock; return 75; }
    cp "$_stp_nodes" "$_stp_tmp_dir/nodes.tsv" 2>/dev/null || { rmdir "$_stp_tmp_dir"; trust_state_unlock; return 75; }
    _stp_digest=$(trust_digest_file "$_stp_tmp_dir/nodes.tsv") || { rm -f "$_stp_tmp_dir/nodes.tsv"; rmdir "$_stp_tmp_dir"; trust_state_unlock; return 75; }
    _stp_ttl="${MERV_SSH_TRUST_PENDING_TTL_SEC:-300}"
    case "$_stp_ttl" in ''|*[!0-9]*) _stp_ttl=300 ;; esac
    [ "$_stp_ttl" -ge 1 ] 2>/dev/null && [ "$_stp_ttl" -le 300 ] 2>/dev/null || _stp_ttl=300
    _stp_expires=$(( _stp_now + _stp_ttl ))
    _stp_original_payload_digest=none
    [ -n "${MERV_SSH_TRUST_ORIGINAL_PAYLOAD:-}" ] && _stp_original_payload_digest=$(trust_digest_string "$MERV_SSH_TRUST_ORIGINAL_PAYLOAD" 2>/dev/null || printf none)
    for _stp_pair in \
        "pending_id=$_stp_request_id" "format_version=1" "request_token=$SSH_TRUST_TOKEN" \
        "original_action=$_stp_original_action" "original_payload_digest=$_stp_original_payload_digest" \
        "node_set_digest=$_stp_digest" "created_epoch=$_stp_now" "expires_epoch=$_stp_expires" \
        "attempts=0" "state=pending" "resume_id=none"; do
        _stp_key=${_stp_pair%%=*}; _stp_value=${_stp_pair#*=}
        trust_write_field "$_stp_tmp_dir" "$_stp_key" "$_stp_value" || { rm -f "$_stp_tmp_dir"/*; rmdir "$_stp_tmp_dir"; trust_state_unlock; return 75; }
    done
    _stp_result='{"pending_id":"'$(trust_json_escape "$_stp_request_id")'","action":"'$(trust_json_escape "$_stp_original_action")'","nodes":['
    _stp_first=1
    while IFS= read -r _stp_row || [ -n "$_stp_row" ]; do [ "$_stp_first" -eq 1 ] || _stp_result="$_stp_result,"; _stp_result="$_stp_result$_stp_row"; _stp_first=0; done < "$_stp_rows"
    _stp_result="$_stp_result],\"challenge_count\":$_stp_challenge_count,\"node_set_digest\":\"$(trust_json_escape "$_stp_digest")\",\"expires_epoch\":$_stp_expires,\"expires_in_sec\":$_stp_ttl}"
    printf '%s\n' "$_stp_result" > "$_stp_tmp_dir/result.json" 2>/dev/null || { rm -f "$_stp_tmp_dir"/*; rmdir "$_stp_tmp_dir"; trust_state_unlock; return 75; }
    cp "$_stp_challenges" "$_stp_tmp_dir/challenge_ids" 2>/dev/null || { rm -f "$_stp_tmp_dir"/*; rmdir "$_stp_tmp_dir"; trust_state_unlock; return 75; }
    chmod 600 "$_stp_tmp_dir"/* 2>/dev/null || { rm -f "$_stp_tmp_dir"/*; rmdir "$_stp_tmp_dir"; trust_state_unlock; return 75; }
    while IFS= read -r _stp_challenge || [ -n "$_stp_challenge" ]; do
        [ -n "$_stp_challenge" ] || continue
        _stp_challenge_dir="$MERV_SSH_TRUST_PENDING_ROOT/$_stp_challenge"
        trust_write_field "$_stp_challenge_dir" request_id "$_stp_request_id" || { trust_state_unlock; return 75; }
        trust_write_field "$_stp_challenge_dir" request_digest "$_stp_digest" || { trust_state_unlock; return 75; }
    done < "$_stp_challenges"
    mv "$_stp_tmp_dir" "$_stp_dir" 2>/dev/null || { trust_state_unlock; return 75; }
    rm -f "$_stp_nodes" "$_stp_rows" "$_stp_challenges" "$_stp_blockers"
    trust_state_unlock
    merv_action_progress_fail "SSH host-key verification requires an explicit decision"
    action_ack_ssh_trust_required "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" "$_stp_result" "SSH host-key verification is required before node changes." '[]'
    _stp_ack_rc=$?
    trust_probe_finish_decision "$_stp_ack_rc"
}

trust_json_registry_node() {
    _strn_slot="$1"; _strn_node="$2"; _strn_mac="$3"; _strn_host="$4"; _strn_port="$5"; _strn_status="$6"; _strn_alg="$7"; _strn_fp="$8"; _strn_updated="$9"; _strn_reason="${10:-}"
    _strn_out="{\"slot\":$_strn_slot,\"node_id\":\"$(trust_json_escape "$_strn_node")\",\"mac\":\"$(trust_json_escape "$_strn_mac")\",\"host\":\"$(trust_json_escape "$_strn_host")\",\"port\":$_strn_port,\"status\":\"$(trust_json_escape "$_strn_status")\",\"algorithm\":\"$(trust_json_escape "$_strn_alg")\",\"fingerprint\":\"$(trust_json_escape "$_strn_fp")\",\"updated_epoch\":$_strn_updated"
    [ -n "$_strn_reason" ] && _strn_out="$_strn_out,\"reason\":\"$(trust_json_escape "$_strn_reason")\""
    printf '%s}\n' "$_strn_out"
}

trust_status_port() {
    _stsp_port="${MERV_NODE_SSH_PORT:-}"
    case "$_stsp_port" in
        ''|*[!0-9]*) _stsp_port="$(json_get_flag NODE_SSH_PORT "" "$SETTINGS_FILE" 2>/dev/null)" ;;
    esac
    case "$_stsp_port" in
        ''|*[!0-9]*) _stsp_port="$(json_get_flag SSH_PORT "22" "$SETTINGS_FILE" 2>/dev/null)" ;;
    esac
    merv_ssh_trust_normalize_port "$_stsp_port"
}

trust_status() {
    merv_action_progress_init "$SSH_TRUST_TOKEN" sshtruststatus_vlanmgr "SSH trusted devices" "Reading the router-owned SSH trust store..."
    merv_action_progress_phase read "Reading trusted device records..."
    trust_state_lock || return 75
    merv_ssh_trust_prune_pending >/dev/null 2>&1 || { trust_state_unlock; return 75; }

    _stst_trusted="$MERV_SSH_TRUST_STAGING_ROOT/.status-trusted.$$"
    _stst_needs="$MERV_SSH_TRUST_STAGING_ROOT/.status-needs.$$"
    _stst_nodes="$MERV_SSH_TRUST_STAGING_ROOT/.status-nodes.$$"
    : > "$_stst_trusted" || { trust_state_unlock; return 75; }
    : > "$_stst_needs" || { trust_cleanup_files "$_stst_trusted"; trust_state_unlock; return 75; }
    : > "$_stst_nodes" || { trust_cleanup_files "$_stst_trusted" "$_stst_needs"; trust_state_unlock; return 75; }

    _stst_now=$(trust_now)
    _stst_ttl="${MERV_SSH_TRUST_TTL_SEC:-31536000}"
    case "$_stst_ttl" in ''|*[!0-9]*) _stst_ttl=31536000 ;; esac
    _stst_tab=$(printf '\t')
    while IFS= read -r _stst_line || [ -n "$_stst_line" ]; do
        case "$_stst_line" in MERV_SSH_TRUST_V1|version*) continue ;; esac
        OLDIFS=$IFS; IFS="$_stst_tab"; set -- $_stst_line; IFS=$OLDIFS
        [ "$#" -eq 11 ] || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; merv_action_progress_fail "The SSH trust database is malformed"; action_ack_error "$SSH_TRUST_TOKEN" sshtruststatus_vlanmgr '{"reason":"malformed-database"}' "The SSH trust database is malformed." '[]' ssh-trust-invalid; return 75; }
        _stst_node=$(merv_ssh_trust_unescape "$2") || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
        _stst_slot=$(merv_ssh_trust_unescape "$3") || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
        _stst_mac=$(merv_ssh_trust_unescape "$4") || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
        _stst_host=$(merv_ssh_trust_unescape "$5") || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
        _stst_port=$(merv_ssh_trust_unescape "$6") || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
        _stst_alg=$(merv_ssh_trust_unescape "$7") || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
        _stst_fp=$(merv_ssh_trust_unescape "$9") || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
        _stst_updated=$(merv_ssh_trust_unescape "${11}") || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
        _stst_record_status=verified
        if [ "$_stst_now" -gt "$_stst_updated" ] 2>/dev/null && [ "$((_stst_now - _stst_updated))" -gt "$_stst_ttl" ] 2>/dev/null; then
            _stst_record_status=expired
        fi
        trust_json_registry_node "$_stst_slot" "$_stst_node" "$_stst_mac" "$_stst_host" "$_stst_port" "$_stst_record_status" "$_stst_alg" "$_stst_fp" "$_stst_updated" >> "$_stst_trusted" || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
    done < "$MERV_SSH_TRUST_FILE"

    merv_action_progress_phase configured "Checking configured nodes for missing or stale trust..."
    if ! merv_node_list > "$_stst_nodes" 2>/dev/null; then
        trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"
        trust_state_unlock
        merv_action_progress_fail "Could not enumerate configured nodes"
        action_ack_error "$SSH_TRUST_TOKEN" sshtruststatus_vlanmgr '{"reason":"node-enumeration-failed"}' "Could not enumerate configured nodes." '[]' ssh-trust-status
        return 75
    fi
    _stst_port=$(trust_status_port 2>/dev/null) || {
        trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"
        trust_state_unlock
        merv_action_progress_fail "The configured node SSH port is invalid"
        action_ack_error "$SSH_TRUST_TOKEN" sshtruststatus_vlanmgr '{"reason":"invalid-port"}' "The configured node SSH port is invalid." '[]' ssh-trust-invalid
        return 2
    }
    while IFS=' ' read -r _stst_slot _stst_host _stst_extra || [ -n "$_stst_slot" ]; do
        [ -n "$_stst_slot" ] || continue
        [ -z "$_stst_extra" ] || continue
        _stst_mac=$(json_get_flag "AUTO_NODE${_stst_slot}_MAC" "" "$SETTINGS_FILE" 2>/dev/null)
        _stst_mac=$(merv_ssh_trust_mac_or_none "$_stst_mac" 2>/dev/null) || continue
        _stst_host=$(merv_ssh_trust_normalize_host "$_stst_host" 2>/dev/null) || continue
        _stst_node=$(merv_ssh_trust_node_id "$_stst_slot" "$_stst_mac" "$_stst_host" "$_stst_port" 2>/dev/null) || continue
        merv_ssh_trust_find "$_stst_node"
        _stst_find_rc=$?
        _stst_need_status=""
        _stst_need_reason=""
        _stst_need_alg=""
        _stst_need_fp=""
        _stst_need_updated=0
        case "$_stst_find_rc" in
            0)
                if [ "$SSH_TRUST_HOST" != "$_stst_host" ] || [ "$SSH_TRUST_PORT" != "$_stst_port" ]; then
                    _stst_need_status=endpoint_changed
                    _stst_need_reason=endpoint-changed
                    _stst_need_alg="$SSH_TRUST_ALGORITHM"
                    _stst_need_fp="$SSH_TRUST_FINGERPRINT"
                    _stst_need_updated="${SSH_TRUST_UPDATED:-0}"
                elif [ "${SSH_TRUST_EXPIRED:-0}" = 1 ]; then
                    _stst_need_status=expired
                    _stst_need_reason=trust-expired
                    _stst_need_alg="$SSH_TRUST_ALGORITHM"
                    _stst_need_fp="$SSH_TRUST_FINGERPRINT"
                    _stst_need_updated="${SSH_TRUST_UPDATED:-0}"
                fi
                ;;
            1)
                _stst_need_status=unverified
                _stst_need_reason=ssh-trust-required
                ;;
            3)
                _stst_need_status=expired
                _stst_need_reason=trust-expired
                _stst_need_alg="$SSH_TRUST_ALGORITHM"
                _stst_need_fp="$SSH_TRUST_FINGERPRINT"
                _stst_need_updated="${SSH_TRUST_UPDATED:-0}"
                ;;
            *)
                _stst_need_status=trust_store_error
                _stst_need_reason=trust-record-invalid
                ;;
        esac
        [ -n "$_stst_need_status" ] || continue
        trust_json_registry_node "$_stst_slot" "$_stst_node" "$_stst_mac" "$_stst_host" "$_stst_port" "$_stst_need_status" "$_stst_need_alg" "$_stst_need_fp" "$_stst_need_updated" "$_stst_need_reason" >> "$_stst_needs" || { trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes"; trust_state_unlock; return 75; }
    done < "$_stst_nodes"

    _stst_result='{"trusted":['
    _stst_first=1
    while IFS= read -r _stst_row || [ -n "$_stst_row" ]; do
        [ "$_stst_first" -eq 1 ] || _stst_result="$_stst_result,"
        _stst_result="$_stst_result$_stst_row"
        _stst_first=0
    done < "$_stst_trusted"
    _stst_result="$_stst_result],\"needs_verification\":["
    _stst_first=1
    while IFS= read -r _stst_row || [ -n "$_stst_row" ]; do
        [ "$_stst_first" -eq 1 ] || _stst_result="$_stst_result,"
        _stst_result="$_stst_result$_stst_row"
        _stst_first=0
    done < "$_stst_needs"
    _stst_result="$_stst_result]}"
    trust_cleanup_files "$_stst_trusted" "$_stst_needs" "$_stst_nodes" || {
        trust_state_unlock
        merv_action_progress_fail "SSH trust status cleanup failed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtruststatus_vlanmgr '{"reason":"cleanup-failed"}' "SSH trust status cleanup failed." '[]' ssh-trust-error
        return 75
    }
    trust_state_unlock || return 75
    merv_action_progress_complete "SSH trusted device status loaded"
    action_ack_ok "$SSH_TRUST_TOKEN" sshtruststatus_vlanmgr "$_stst_result" "SSH trusted device status loaded." '[]'
}

trust_revoke() {
    merv_action_progress_init "$SSH_TRUST_TOKEN" sshtrustrevoke_vlanmgr "Revoke SSH trust" "Validating the selected trusted device..."
    trust_state_lock || return 75
    merv_ssh_trust_prune_pending >/dev/null 2>&1 || { trust_state_unlock; return 75; }
    _strv_node=$(trust_transport_value node_id 2>/dev/null || printf '')
    printf '%s\n' "$_strv_node" | grep -Eq '^NODE[1-9][0-9]*@[A-Za-z0-9.:-]+$' || { trust_state_unlock; merv_action_progress_fail "The selected trusted device is invalid"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustrevoke_vlanmgr '{"reason":"invalid-node-id"}' "The selected trusted device is invalid." '[]' ssh-trust-invalid; return 2; }
    case "$_strv_node" in *[!A-Za-z0-9@.:-]*) trust_state_unlock; merv_action_progress_fail "The selected trusted device is invalid"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustrevoke_vlanmgr '{"reason":"invalid-node-id"}' "The selected trusted device is invalid." '[]' ssh-trust-invalid; return 2 ;; esac
    merv_action_progress_phase stage "Removing the selected pin atomically..."
    _strv_stage=$(merv_ssh_trust_stage_remove_node "$_strv_node" 2>/dev/null)
    _strv_rc=$?
    if [ "$_strv_rc" -ne 0 ]; then
        trust_state_unlock
        if [ "$_strv_rc" -eq 3 ]; then
            merv_action_progress_fail "The selected trusted device was not found"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustrevoke_vlanmgr '{"reason":"node-not-found"}' "The selected trusted device was not found." '[]' ssh-trust-not-found
        else
            merv_action_progress_fail "The SSH trust store could not be staged safely"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustrevoke_vlanmgr '{"reason":"stage-failed"}' "The SSH trust store could not be staged safely." '[]' ssh-trust-error
        fi
        return "$_strv_rc"
    fi
    if ! merv_ssh_trust_publish_stage "$_strv_stage" >/dev/null 2>&1; then
        merv_ssh_trust_cleanup_files "$_strv_stage" >/dev/null 2>&1
        trust_state_unlock
        merv_action_progress_fail "SSH trust revocation could not be published"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustrevoke_vlanmgr '{"reason":"publication-failed"}' "SSH trust revocation could not be published." '[]' ssh-trust-error
        return 75
    fi
    trust_state_unlock || return 75
    merv_action_progress_complete "SSH trust revoked for $_strv_node"
    action_ack_ok "$SSH_TRUST_TOKEN" sshtrustrevoke_vlanmgr "{\"node_id\":\"$(trust_json_escape "$_strv_node")\",\"revoked\":true}" "SSH trust revoked for the selected device." '[]'
}

trust_abort() {
    merv_action_progress_init "$SSH_TRUST_TOKEN" sshtrustabort_vlanmgr "Abort SSH trust action" "Validating the paused SSH trust request..."
    trust_state_lock || return 75
    merv_ssh_trust_prune_pending >/dev/null 2>&1 || { trust_state_unlock; return 75; }
    _sta_pending=$(trust_transport_value pending_id 2>/dev/null || printf '')
    trust_id_valid "$_sta_pending" || {
        trust_state_unlock
        merv_action_progress_fail "The SSH trust request is invalid or unavailable"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustabort_vlanmgr '{"reason":"invalid-pending-id"}' "The SSH trust request is invalid or unavailable." '[]' ssh-trust-invalid
        return 2
    }
    case "$_sta_pending" in p.*) ;; *)
        trust_state_unlock
        merv_action_progress_fail "The SSH trust request is invalid or unavailable"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustabort_vlanmgr '{"reason":"invalid-pending-id"}' "The SSH trust request is invalid or unavailable." '[]' ssh-trust-invalid
        return 2
        ;;
    esac
    _sta_dir=$(trust_request_dir "$_sta_pending" 2>/dev/null) || {
        trust_state_unlock
        merv_action_progress_fail "The SSH trust request is no longer available"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustabort_vlanmgr '{"reason":"missing-pending-request"}' "The SSH trust request is no longer available." '[]' ssh-trust-expired
        return 9
    }
    _sta_state=$(trust_read_field "$_sta_dir" state 2>/dev/null || printf invalid)
    if trust_request_expired "$_sta_dir" || [ "$_sta_state" = expired ]; then
        trust_mark_request "$_sta_dir" expired >/dev/null 2>&1 || :
        trust_state_unlock
        merv_action_progress_fail "The SSH trust request already expired"
        action_ack_write "$SSH_TRUST_TOKEN" sshtrustabort_vlanmgr expired '{"reason":"expired"}' "The SSH trust request already expired." '[]' ssh-trust-expired
        return 9
    fi
    [ "$_sta_state" = pending ] || {
        trust_state_unlock
        merv_action_progress_fail "The SSH trust request is no longer paused"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustabort_vlanmgr '{"reason":"not-pending"}' "The SSH trust request is no longer paused." '[]' ssh-trust-invalid
        return 9
    }
    merv_action_progress_phase cancel "Canceling the paused SSH trust request..."
    if ! trust_request_cancel "$_sta_dir"; then
        trust_state_unlock
        merv_action_progress_fail "The paused SSH trust request could not be canceled safely"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustabort_vlanmgr '{"reason":"cancel-failed"}' "The paused SSH trust request could not be canceled safely." '[]' ssh-trust-error
        return 75
    fi
    trust_state_unlock || return 75
    merv_action_progress_complete "Paused SSH trust request aborted"
    action_ack_ok "$SSH_TRUST_TOKEN" sshtrustabort_vlanmgr "{\"pending_id\":\"$(trust_json_escape "$_sta_pending")\",\"canceled\":true}" "The paused SSH trust action was aborted. Already trusted host keys were kept." '[]'
}

trust_decision_for() {
    _stdf_id="$1"; _stdf_decisions="$2"
    printf '%s\n' "$_stdf_decisions" | tr ',' '\n' | awk -F= -v id="$_stdf_id" '$1==id {print $2; exit}'
}

trust_decisions_validate() {
    _stdv_ids="$1"; _stdv_decisions="$2"
    case "$_stdv_decisions" in ''|*[!A-Za-z0-9._=,-]*) return 1 ;; esac
    _stdv_seen=" "; _stdv_count=0
    OLDIFS=$IFS; IFS=,
    for _stdv_entry in $_stdv_decisions; do
        _stdv_id=${_stdv_entry%%=*}; _stdv_decision=${_stdv_entry#*=}
        trust_id_valid "$_stdv_id" || { IFS=$OLDIFS; return 1; }
        case "$_stdv_id" in c.*) ;; *) IFS=$OLDIFS; return 1 ;; esac
        grep -Fqx "$_stdv_id" "$_stdv_ids" 2>/dev/null || { IFS=$OLDIFS; return 1; }
        case "$_stdv_decision" in accept|reject|yes|no) ;; *) IFS=$OLDIFS; return 1 ;; esac
        case "$_stdv_seen" in *" $_stdv_id "*) IFS=$OLDIFS; return 1 ;; esac
        _stdv_seen="$_stdv_seen$_stdv_id "
        _stdv_count=$((_stdv_count + 1))
    done
    IFS=$OLDIFS
    [ "$_stdv_count" -gt 0 ]
}

trust_selected_challenge_ids() {
    _stsc_ids="$1"; _stsc_decisions="$2"; _stsc_out="$3"
    : > "$_stsc_out" 2>/dev/null || return 1
    while IFS= read -r _stsc_id || [ -n "$_stsc_id" ]; do
        [ -n "$_stsc_id" ] || continue
        _stsc_decision=$(trust_decision_for "$_stsc_id" "$_stsc_decisions")
        case "$_stsc_decision" in
            accept|yes) printf '%s\n' "$_stsc_id" >> "$_stsc_out" || return 1 ;;
            reject|no|'') ;;
            *) return 1 ;;
        esac
    done < "$_stsc_ids"
    [ -s "$_stsc_out" ]
}

trust_enroll() {
    merv_action_progress_init "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr "SSH trust enrollment" "Validating trust decisions..."
    trust_state_lock || return 75
    merv_ssh_trust_prune_pending >/dev/null 2>&1 || { trust_state_unlock; return 75; }
    _ste_pending=$(trust_transport_value pending_id 2>/dev/null || printf '')
    _ste_decisions=$(trust_transport_value decisions 2>/dev/null || printf '')
    trust_id_valid "$_ste_pending" || { trust_state_unlock; merv_action_progress_fail "The SSH trust request is invalid or expired"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"invalid-pending-id"}' "The SSH trust request is invalid or expired." '[]' ssh-trust-invalid; return 2; }
    _ste_dir=$(trust_request_dir "$_ste_pending" 2>/dev/null) || { trust_state_unlock; merv_action_progress_fail "The SSH trust request is unavailable"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"missing-pending-request"}' "The SSH trust request is unavailable." '[]' ssh-trust-expired; return 2; }
    _ste_state=$(trust_read_field "$_ste_dir" state 2>/dev/null) || _ste_state=invalid
    if trust_request_expired "$_ste_dir"; then
        trust_mark_request "$_ste_dir" expired || {
            trust_state_unlock
            merv_action_progress_fail "The SSH trust request expired but its state could not be published"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"expiration-state-failed"}' "The SSH trust request expired but its state could not be published." '[]' ssh-trust-error
            return 75
        }
        trust_state_unlock || return 75
        merv_action_progress_fail "The SSH trust request expired; start a new probe"
        action_ack_write "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr expired '{"reason":"expired"}' "The SSH trust request expired; start a new probe." '[]' ssh-trust-expired
        return 9
    fi
    [ "$_ste_state" = pending ] || { trust_state_unlock; merv_action_progress_fail "The SSH trust request is no longer pending"; action_ack_write "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr ssh_trust_pending '{"reason":"not-pending"}' "The SSH trust request is no longer pending." '[]' ssh-trust-pending; return 9; }
    _ste_challenges="$MERV_SSH_TRUST_STAGING_ROOT/.enroll-challenges.$$"
    # The request stores the authoritative challenge list separately so a
    # browser cannot shrink the required set by changing result JSON.
    if [ ! -s "$_ste_dir/challenge_ids" ] || ! cp "$_ste_dir/challenge_ids" "$_ste_challenges" 2>/dev/null; then
        trust_cleanup_files "$_ste_challenges"
        trust_state_unlock
        merv_action_progress_fail "The SSH trust challenge set is unavailable"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"missing-challenge-set"}' "The SSH trust challenge set is unavailable." '[]' ssh-trust-invalid
        return 75
    fi
    while IFS= read -r _ste_id || [ -n "$_ste_id" ]; do
        [ -n "$_ste_id" ] || continue
        trust_id_valid "$_ste_id" || { rm -f "$_ste_challenges"; trust_state_unlock; merv_action_progress_fail "The SSH trust challenge set is malformed"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"malformed-challenge-set"}' "The SSH trust challenge set is malformed." '[]' ssh-trust-invalid; return 2; }
        case "$_ste_id" in c.*) ;; *) rm -f "$_ste_challenges"; trust_state_unlock; merv_action_progress_fail "The SSH trust challenge set is malformed"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"malformed-challenge-set"}' "The SSH trust challenge set is malformed." '[]' ssh-trust-invalid; return 2 ;; esac
    done < "$_ste_challenges"
    [ -s "$_ste_challenges" ] || { rm -f "$_ste_challenges"; trust_state_unlock; merv_action_progress_fail "The SSH trust challenge set is malformed"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"malformed-challenge-set"}' "The SSH trust challenge set is malformed." '[]' ssh-trust-invalid; return 2; }
    trust_decisions_validate "$_ste_challenges" "$_ste_decisions" || {
        trust_cleanup_files "$_ste_challenges"
        trust_state_unlock
        merv_action_progress_fail "The selected SSH trust decision is invalid"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"invalid-decisions"}' "The selected SSH trust decision is invalid; the action remains paused." '[]' ssh-trust-invalid
        return 2
    }

    # A reject is a deliberate cancellation.  No candidate database is built.
    _ste_rejected=0
    while IFS= read -r _ste_id || [ -n "$_ste_id" ]; do
        _ste_decision=$(trust_decision_for "$_ste_id" "$_ste_decisions")
        case "$_ste_decision" in reject|no) _ste_rejected=1 ;; esac
    done < "$_ste_challenges"
    if [ "$_ste_rejected" -eq 1 ]; then
        _ste_cleanup_rc=0
        trust_cancel_challenge_list "$_ste_challenges" || _ste_cleanup_rc=1
        trust_mark_request "$_ste_dir" canceled || _ste_cleanup_rc=1
        trust_cleanup_files "$_ste_challenges" || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        if [ "$_ste_cleanup_rc" -ne 0 ]; then
            merv_action_progress_fail "SSH trust rejection cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"cleanup-failed"}' "SSH trust rejection cleanup failed; no trust records were changed." '[]' ssh-trust-error
            return 75
        fi
        merv_action_progress_fail "SSH trust was not accepted; no trust records were changed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"user-rejected"}' "SSH trust was not accepted; no trust records were changed." '[]' ssh-trust-rejected
        return 10
    fi

    _ste_selected="$MERV_SSH_TRUST_STAGING_ROOT/.enroll-selected.$$"
    if ! trust_selected_challenge_ids "$_ste_challenges" "$_ste_decisions" "$_ste_selected"; then
        trust_cleanup_files "$_ste_challenges" "$_ste_selected"
        trust_state_unlock
        merv_action_progress_fail "Select at least one pending SSH host key"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"no-selected-challenges"}' "Select at least one pending SSH host key; the action remains paused." '[]' ssh-trust-invalid
        return 2
    fi
    while IFS= read -r _ste_id || [ -n "$_ste_id" ]; do
        [ -n "$_ste_id" ] || continue
        [ "$(trust_read_field "$MERV_SSH_TRUST_PENDING_ROOT/$_ste_id" state 2>/dev/null || printf '')" = pending ] || {
            trust_cleanup_files "$_ste_challenges" "$_ste_selected"
            trust_state_unlock
            merv_action_progress_fail "The selected SSH host key is no longer pending"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"stale-selected-challenge"}' "The selected SSH host key is no longer pending; refresh the decision." '[]' ssh-trust-invalid
            return 9
        }
    done < "$_ste_selected"
    trust_write_field "$_ste_dir" state enrolling || { trust_cleanup_files "$_ste_challenges" "$_ste_selected"; trust_state_unlock; return 75; }
    merv_action_progress_phase revalidate "Re-probing every presented host key..."
    _ste_accepted="$MERV_SSH_TRUST_STAGING_ROOT/.accepted.$$"; : > "$_ste_accepted" || { trust_cleanup_files "$_ste_challenges" "$_ste_selected"; trust_state_unlock; return 75; }
    _ste_fail=""
    while IFS= read -r _ste_id || [ -n "$_ste_id" ]; do
        _ste_cdir="$MERV_SSH_TRUST_PENDING_ROOT/$_ste_id"
        merv_ssh_trust_validate_challenge "$_ste_cdir" || { _ste_fail=challenge-invalid; break; }
        _ste_req=$(trust_read_field "$_ste_cdir" request_id 2>/dev/null || printf '')
        _ste_digest=$(trust_read_field "$_ste_cdir" request_digest 2>/dev/null || printf '')
        [ "$_ste_req" = "$_ste_pending" ] && [ "$_ste_digest" = "$(trust_read_field "$_ste_dir" node_set_digest 2>/dev/null)" ] || { _ste_fail=challenge-binding; break; }
        _ste_slot=$(trust_read_field "$_ste_cdir" slot 2>/dev/null || printf '')
        _ste_host=$(trust_read_field "$_ste_cdir" host 2>/dev/null || printf '')
        _ste_port=$(trust_read_field "$_ste_cdir" port 2>/dev/null || printf '')
        _ste_mac=$(trust_read_field "$_ste_cdir" mac 2>/dev/null || printf '')
        _ste_alg=$(trust_read_field "$_ste_cdir" algorithm 2>/dev/null || printf '')
        _ste_key=$(trust_read_field "$_ste_cdir" public_key_b64 2>/dev/null || printf '')
        _ste_fp=$(trust_read_field "$_ste_cdir" fingerprint_sha256 2>/dev/null || printf '')
        _ste_expected_status=$(trust_read_field "$_ste_cdir" probe_status 2>/dev/null || printf 6)
        merv_ssh_hostkey_probe "$_ste_slot" "$_ste_host" "$_ste_port" "$_ste_mac"
        _ste_probe_rc=$?
        [ "$_ste_probe_rc" = "$_ste_expected_status" ] || { _ste_fail=host-key-changed; break; }
        [ "$SSH_PROBE_NODE" = "$(merv_ssh_trust_node_id "$_ste_slot" "$_ste_mac" "$_ste_host" "$_ste_port")" ] || { _ste_fail=node-identity-changed; break; }
        [ "$SSH_PROBE_HOST" = "$_ste_host" ] && [ "$SSH_PROBE_PORT" = "$_ste_port" ] && [ "$SSH_PROBE_ALGORITHM" = "$_ste_alg" ] && [ "$SSH_PROBE_PUBLIC_KEY" = "$_ste_key" ] && [ "$SSH_PROBE_FINGERPRINT" = "$_ste_fp" ] || { _ste_fail=presented-key-changed; break; }
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_ste_slot" "$_ste_mac" "$_ste_host" "$_ste_port" "$_ste_alg" "$_ste_key" "$_ste_fp" >> "$_ste_accepted" || { _ste_fail=staging-failed; break; }
    done < "$_ste_selected"
    if [ -n "$_ste_fail" ]; then
        _ste_cleanup_rc=0
        trust_mark_request "$_ste_dir" canceled || _ste_cleanup_rc=1
        trust_cancel_challenge_list "$_ste_challenges" || _ste_cleanup_rc=1
        trust_cleanup_files "$_ste_challenges" "$_ste_selected" "$_ste_accepted" || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        if [ "$_ste_cleanup_rc" -ne 0 ]; then
            merv_action_progress_fail "SSH trust enrollment stopped and cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"cleanup-failed"}' "SSH trust enrollment stopped and cleanup failed; no trust records were changed." '[]' ssh-trust-error
            return 75
        fi
        merv_action_progress_fail "SSH trust enrollment stopped: $_ste_fail; no trust records were changed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"reprobe-failed"}' "SSH trust enrollment stopped: $_ste_fail; no trust records were changed." '[]' ssh-trust-reprobe-failed
        return 8
    fi

    # Never commit a key after the five-minute review window has elapsed,
    # including an unusually slow re-probe.
    if trust_request_expired "$_ste_dir"; then
        _ste_cleanup_rc=0
        trust_cancel_challenge_list "$_ste_challenges" || _ste_cleanup_rc=1
        trust_mark_request "$_ste_dir" expired || _ste_cleanup_rc=1
        trust_cleanup_files "$_ste_challenges" "$_ste_selected" "$_ste_accepted" || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        if [ "$_ste_cleanup_rc" -ne 0 ]; then
            merv_action_progress_fail "The SSH trust request expired and cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"expiration-cleanup-failed"}' "The SSH trust request expired and cleanup failed; no trust records were changed." '[]' ssh-trust-error
            return 75
        fi
        merv_action_progress_fail "The SSH trust request expired; start a new probe"
        action_ack_write "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr expired '{"reason":"expired"}' "The SSH trust request expired; start a new probe." '[]' ssh-trust-expired
        return 9
    fi

    merv_action_progress_phase commit "Committing the selected SSH host keys atomically..."
    _ste_candidate="$MERV_SSH_TRUST_STAGING_ROOT/.candidate.$$"
    _ste_backup="$MERV_SSH_TRUST_STAGING_ROOT/.database-backup.$$"
    cp "$MERV_SSH_TRUST_FILE" "$_ste_candidate" 2>/dev/null || {
        _ste_cleanup_rc=0
        trust_cleanup_files "$_ste_challenges" "$_ste_selected" "$_ste_accepted" || _ste_cleanup_rc=1
        trust_mark_request "$_ste_dir" failed || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        [ "$_ste_cleanup_rc" -eq 0 ] || printf '%s\n' "[ERROR] SSH trust candidate cleanup failed" >&2
        return 75
    }
    cp "$MERV_SSH_TRUST_FILE" "$_ste_backup" 2>/dev/null || {
        _ste_cleanup_rc=0
        trust_cleanup_files "$_ste_candidate" "$_ste_challenges" "$_ste_selected" "$_ste_accepted" || _ste_cleanup_rc=1
        trust_mark_request "$_ste_dir" failed || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        [ "$_ste_cleanup_rc" -eq 0 ] || printf '%s\n' "[ERROR] SSH trust backup cleanup failed" >&2
        return 75
    }
    if ! chmod 600 "$_ste_candidate" "$_ste_backup" 2>/dev/null; then
        _ste_cleanup_rc=0
        trust_cleanup_files "$_ste_candidate" "$_ste_backup" "$_ste_challenges" "$_ste_selected" "$_ste_accepted" || _ste_cleanup_rc=1
        trust_mark_request "$_ste_dir" failed || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        [ "$_ste_cleanup_rc" -eq 0 ] || printf '%s\n' "[ERROR] SSH trust candidate permission cleanup failed" >&2
        return 75
    fi
    _ste_saved_db="$MERV_SSH_TRUST_FILE"; MERV_SSH_TRUST_FILE="$_ste_candidate"
    _ste_stage_rc=0
    _ste_tab=$(printf '\t')
    while IFS="$_ste_tab" read -r _ste_slot _ste_mac _ste_host _ste_port _ste_alg _ste_key _ste_fp || [ -n "$_ste_slot" ]; do
        [ -n "$_ste_slot" ] || continue
        _ste_stage=$(merv_ssh_trust_stage_record "$_ste_slot" "$_ste_mac" "$_ste_host" "$_ste_port" "$_ste_alg" "$_ste_key" "$_ste_fp" 2>/dev/null) || { _ste_stage_rc=1; break; }
        merv_ssh_trust_publish_stage "$_ste_stage" >/dev/null 2>&1 || { _ste_stage_rc=1; break; }
    done < "$_ste_accepted"
    MERV_SSH_TRUST_FILE="$_ste_saved_db"
    if [ "$_ste_stage_rc" -ne 0 ] || ! merv_ssh_trust_validate_file "$_ste_candidate"; then
        _ste_cleanup_rc=0
        trust_cleanup_files "$_ste_candidate" "$_ste_backup" "$_ste_challenges" "$_ste_selected" "$_ste_accepted" || _ste_cleanup_rc=1
        trust_mark_request "$_ste_dir" failed || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        if [ "$_ste_cleanup_rc" -ne 0 ]; then
            merv_action_progress_fail "SSH trust database staging failed and cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"cleanup-failed"}' "SSH trust database staging failed and cleanup failed; no trust records were changed." '[]' ssh-trust-error
            return 75
        fi
        merv_action_progress_fail "SSH trust database staging failed; no trust records were changed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"commit-staging-failed"}' "SSH trust database staging failed; no trust records were changed." '[]' ssh-trust-commit-failed
        return 75
    fi
    mv -f "$_ste_candidate" "$MERV_SSH_TRUST_FILE" 2>/dev/null || {
        _ste_restore_rc=0
        mv -f "$_ste_backup" "$MERV_SSH_TRUST_FILE" 2>/dev/null || _ste_restore_rc=1
        _ste_cleanup_rc=0
        trust_cleanup_files "$_ste_candidate" "$_ste_backup" "$_ste_challenges" "$_ste_selected" "$_ste_accepted" || _ste_cleanup_rc=1
        trust_mark_request "$_ste_dir" failed || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        if [ "$_ste_restore_rc" -ne 0 ] || [ "$_ste_cleanup_rc" -ne 0 ]; then
            merv_action_progress_fail "SSH trust database publication failed and rollback/reconciliation failed"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"commit-rollback-failed"}' "SSH trust database publication failed and rollback/reconciliation failed; manual recovery is required." '[]' ssh-trust-error
            return 75
        fi
        merv_action_progress_fail "SSH trust database publication failed; no trust records were changed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"commit-publication-failed"}' "SSH trust database publication failed; no trust records were changed." '[]' ssh-trust-commit-failed
        return 75
    }
    _ste_cleanup_rc=0
    trust_cleanup_files "$_ste_backup" "$_ste_accepted" || _ste_cleanup_rc=1
    _ste_challenge_state_rc=0
    while IFS= read -r _ste_id || [ -n "$_ste_id" ]; do
        [ -n "$_ste_id" ] || continue
        trust_write_field "$MERV_SSH_TRUST_PENDING_ROOT/$_ste_id" state verified || _ste_challenge_state_rc=1
    done < "$_ste_selected"
    if [ "$_ste_challenge_state_rc" -ne 0 ]; then
        trust_cleanup_files "$_ste_challenges" "$_ste_selected" || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        merv_action_progress_fail "SSH trust records committed, but challenge finalization failed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"challenge-finalization-failed"}' "SSH trust records committed, but challenge finalization failed; reconciliation is required." '[]' ssh-trust-finalization-failed
        return 75
    fi

    if [ "$_ste_cleanup_rc" -ne 0 ]; then
        trust_mark_request "$_ste_dir" failed >/dev/null 2>&1 || :
        trust_cleanup_files "$_ste_challenges" "$_ste_selected" >/dev/null 2>&1 || :
        trust_state_unlock >/dev/null 2>&1 || :
        merv_action_progress_fail "SSH trust records committed, but temporary cleanup failed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"cleanup-failed"}' "SSH trust records were committed, but cleanup failed; reconciliation is required." '[]' ssh-trust-error
        return 75
    fi

    _ste_remaining=$(trust_request_pending_count "$_ste_dir" 2>/dev/null) || {
        trust_mark_request "$_ste_dir" failed >/dev/null 2>&1 || :
        trust_cleanup_files "$_ste_challenges" "$_ste_selected" >/dev/null 2>&1 || :
        trust_state_unlock >/dev/null 2>&1 || :
        merv_action_progress_fail "SSH trust records committed, but pending-state reconciliation failed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"pending-reconciliation-failed"}' "SSH trust records were committed, but pending-state reconciliation failed; manual review is required." '[]' ssh-trust-error
        return 75
    }
    if [ "$_ste_remaining" -gt 0 ] 2>/dev/null; then
        _ste_pending_result=$(trust_request_pending_result "$_ste_dir" "$_ste_pending" 2>/dev/null) || {
            trust_mark_request "$_ste_dir" failed >/dev/null 2>&1 || :
            trust_cleanup_files "$_ste_challenges" "$_ste_selected" >/dev/null 2>&1 || :
            trust_state_unlock >/dev/null 2>&1 || :
            merv_action_progress_fail "SSH trust records committed, but the remaining decision could not be prepared"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"pending-result-failed"}' "SSH trust records were committed, but the remaining decision could not be prepared; manual review is required." '[]' ssh-trust-error
            return 75
        }
        trust_write_field "$_ste_dir" state pending || {
            trust_mark_request "$_ste_dir" failed >/dev/null 2>&1 || :
            trust_cleanup_files "$_ste_challenges" "$_ste_selected" >/dev/null 2>&1 || :
            trust_state_unlock >/dev/null 2>&1 || :
            merv_action_progress_fail "SSH trust records committed, but the pause state could not be restored"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"pending-state-failed"}' "SSH trust records were committed, but the remaining decision could not be restored; manual review is required." '[]' ssh-trust-error
            return 75
        }
        _ste_cleanup_rc=0
        trust_cleanup_files "$_ste_challenges" "$_ste_selected" || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        if [ "$_ste_cleanup_rc" -ne 0 ]; then
            merv_action_progress_fail "Selected SSH trust records were committed, but pause cleanup failed"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"cleanup-failed"}' "Selected SSH trust records were committed, but pause cleanup failed; manual review is required." '[]' ssh-trust-error
            return 75
        fi
        merv_action_progress_complete "Selected SSH trust records committed; $_ste_remaining node(s) still need review"
        action_ack_ssh_trust_required "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr "$_ste_pending_result" "Selected host keys were trusted. $_ste_remaining node(s) still need review; the original action remains paused." '[]'
        return $?
    fi

    _ste_original_action=$(trust_read_field "$_ste_dir" original_action 2>/dev/null || printf none)
    _ste_resume=none
    if [ "$_ste_original_action" != none ]; then
        _ste_now=$(trust_now); _ste_start=$(merv_identity_current_start 2>/dev/null || printf 0)
        _ste_resume="r.$_ste_now.$$.$_ste_start"
        trust_write_field "$_ste_dir" resume_id "$_ste_resume" || {
            trust_cleanup_files "$_ste_challenges" "$_ste_selected" || _ste_cleanup_rc=1
            trust_state_unlock || _ste_cleanup_rc=1
            [ "$_ste_cleanup_rc" -eq 0 ] || printf '%s\n' "[ERROR] SSH trust resume-state cleanup failed" >&2
            return 75
        }
    fi
    trust_write_field "$_ste_dir" state committed || {
        trust_cleanup_files "$_ste_challenges" "$_ste_selected" || _ste_cleanup_rc=1
        trust_state_unlock || _ste_cleanup_rc=1
        [ "$_ste_cleanup_rc" -eq 0 ] || printf '%s\n' "[ERROR] SSH trust committed-state cleanup failed" >&2
        return 75
    }
    trust_cleanup_files "$_ste_challenges" "$_ste_selected" || _ste_cleanup_rc=1
    _ste_result='{"pending_id":"'$(trust_json_escape "$_ste_pending")'","resume_id":"'$(trust_json_escape "$_ste_resume")'","status":"committed"}'
    trust_state_unlock || _ste_cleanup_rc=1
    if [ "$_ste_cleanup_rc" -ne 0 ]; then
        merv_action_progress_fail "SSH trust records committed, but cleanup/reconciliation failed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr '{"reason":"cleanup-failed"}' "SSH trust records committed, but cleanup/reconciliation failed; manual recovery is required." '[]' ssh-trust-error
        return 75
    fi
    merv_action_progress_complete "SSH trust records committed"
    action_ack_ok "$SSH_TRUST_TOKEN" sshtrustenroll_vlanmgr "$_ste_result" "SSH trust records committed." '[]'
}

trust_resume() {
    merv_action_progress_init "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr "Resuming MerVLAN action" "Validating the one-use resume request..."
    trust_state_lock || return 75
    merv_ssh_trust_prune_pending >/dev/null 2>&1 || { trust_state_unlock; return 75; }
    _str_resume=$(trust_transport_value resume_id 2>/dev/null || printf '')
    trust_id_valid "$_str_resume" || { trust_state_unlock; merv_action_progress_fail "The SSH resume request is invalid"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"invalid-resume-id"}' "The SSH resume request is invalid." '[]' ssh-trust-invalid; return 2; }
    case "$_str_resume" in r.*) ;; *) trust_state_unlock; merv_action_progress_fail "The SSH resume request is invalid"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"invalid-resume-id"}' "The SSH resume request is invalid." '[]' ssh-trust-invalid; return 2 ;; esac
    _str_dir=""
    for _str_candidate in "$MERV_SSH_TRUST_REQUESTS_ROOT"/p.*; do
        [ -d "$_str_candidate" ] || continue
        [ "$(trust_read_field "$_str_candidate" resume_id 2>/dev/null)" = "$_str_resume" ] && { _str_dir="$_str_candidate"; break; }
    done
    [ -n "$_str_dir" ] || { trust_state_unlock; merv_action_progress_fail "The SSH resume request is unavailable"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"missing-resume-request"}' "The SSH resume request is unavailable." '[]' ssh-trust-expired; return 9; }
    _str_original_token=$(trust_read_field "$_str_dir" request_token 2>/dev/null || printf '')
    trust_token_valid "$_str_original_token" || { trust_state_unlock; merv_action_progress_fail "The SSH resume request is invalid"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"invalid-original-token"}' "The SSH resume request is invalid." '[]' ssh-trust-invalid; return 2; }
    [ "$_str_original_token" != "$SSH_TRUST_TOKEN" ] || { trust_state_unlock; merv_action_progress_fail "The SSH resume request requires a fresh action token"; action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"reused-action-token"}' "The SSH resume request requires a fresh action token." '[]' ssh-trust-invalid; return 2; }
    trust_request_expired "$_str_dir" && {
        trust_mark_request "$_str_dir" expired || {
            trust_state_unlock
            merv_action_progress_fail "The SSH resume request expired but its state could not be published"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"expiration-state-failed"}' "The SSH resume request expired but its state could not be published." '[]' ssh-trust-error
            return 75
        }
        trust_state_unlock || return 75
        merv_action_progress_fail "The SSH resume request expired"
        action_ack_write "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr expired '{"reason":"expired"}' "The SSH resume request expired; start a new probe." '[]' ssh-trust-expired
        return 9
    }
    [ "$(trust_read_field "$_str_dir" state 2>/dev/null)" = committed ] || { trust_state_unlock; merv_action_progress_fail "The SSH resume request was already used"; action_ack_write "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr ssh_trust_pending '{"reason":"already-used"}' "The SSH resume request was already used." '[]' ssh-trust-pending; return 9; }
    [ "$(trust_read_field "$_str_dir" attempts 2>/dev/null)" = 0 ] || { trust_state_unlock; merv_action_progress_fail "The SSH resume request was already used"; action_ack_write "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr ssh_trust_pending '{"reason":"attempt-limit"}' "The SSH resume request was already used." '[]' ssh-trust-pending; return 9; }
    _str_action=$(trust_read_field "$_str_dir" original_action 2>/dev/null || printf none)
    trust_action_allowlist "$_str_action" || {
        trust_mark_request "$_str_dir" failed || {
            trust_state_unlock
            merv_action_progress_fail "The stored action is invalid and its state could not be published"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"invalid-action-state-failed"}' "The stored action is invalid and its state could not be published." '[]' ssh-trust-error
            return 75
        }
        trust_state_unlock || return 75
        merv_action_progress_fail "The stored action is not resumable"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"invalid-original-action"}' "The stored action is not resumable." '[]' ssh-trust-invalid
        return 2
    }
    trust_write_field "$_str_dir" attempts 1 || { trust_state_unlock; return 75; }
    trust_write_field "$_str_dir" state running || { trust_state_unlock; return 75; }
    _str_now=$(trust_now); _str_start=$(merv_identity_current_start 2>/dev/null || printf 0); _str_fresh="retry.$_str_now.$$.$_str_start"
    trust_state_unlock
    merv_action_progress_phase dispatch "Rechecking pinned nodes and resuming the stored action..."
    MERV_PROGRESS_TOKEN="$_str_fresh"; export MERV_PROGRESS_TOKEN
    MERV_ACTION_LOCK_PARENT_HELD=1; export MERV_ACTION_LOCK_PARENT_HELD
    case "$_str_action" in
        sync_vlanmgr) sh "$MERV_BASE/functions/sync_nodes.sh" ;;
        syncsettings_vlanmgr) sh "$MERV_BASE/functions/sync_nodes.sh" --settings-only ;;
        apply_vlanmgr) sh "$MERV_BASE/functions/mervlan_manager.sh" ;;
        executenodes_vlanmgr) EXECUTE_PROGRESS_ACTION=executenodes_vlanmgr sh "$MERV_BASE/functions/execute_nodes.sh" ;;
        executenodesonly_vlanmgr) EXECUTE_PROGRESS_ACTION=executenodesonly_vlanmgr sh "$MERV_BASE/functions/execute_nodes.sh" nodesonly ;;
        collectclients_vlanmgr)
            # Keep the visible resume task authoritative. The nested
            # verified-only probe receives an isolated child progress token,
            # while any unexpected fresh trust decision is acknowledged on
            # the resume token that the browser is actually polling.
            MERV_PROGRESS_TOKEN="$SSH_TRUST_TOKEN"
            MERV_SSH_TRUST_PROGRESS_TOKEN="$_str_fresh"
            MERV_OBS_RESUME_PROGRESS_TOKEN="$SSH_TRUST_TOKEN"
            _str_wait="${MERV_SSH_TRUST_RESUME_WAIT_SEC:-300}"
            case "$_str_wait" in ''|*[!0-9]*) _str_wait=300 ;; esac
            [ "$_str_wait" -ge 30 ] 2>/dev/null && [ "$_str_wait" -le 600 ] 2>/dev/null || _str_wait=300
            export MERV_PROGRESS_TOKEN MERV_SSH_TRUST_PROGRESS_TOKEN MERV_OBS_RESUME_PROGRESS_TOKEN
            merv_action_progress_phase queue "Checking trusted node keys and queuing the client refresh..."
            MERV_OBS_NO_AUTOSTART=1 sh "$MERV_BASE/functions/post_apply_worker.sh" request collect >/dev/null 2>&1 && {
              merv_action_progress_phase waiting "Waiting for queued observation work before refreshing clients..."
              sh "$MERV_BASE/functions/post_apply_worker.sh" run-wait "$_str_wait"
            }
            ;;
        *) return 2 ;;
    esac
    _str_rc=$?
    case "$_str_rc" in
        10)
            # The collection recheck found a newly untrusted key and already
            # published a correlated ssh_trust_required acknowledgement on
            # this resume token. Retire the consumed resume request without
            # replacing that acknowledgement with a generic failure, so the
            # browser can open the next trust review immediately.
            if trust_state_lock; then
                trust_mark_request "$_str_dir" failed >/dev/null 2>&1 || :
                trust_state_unlock >/dev/null 2>&1 || :
            fi
            MERV_ACTION_ACK_PUBLISHED=1
            return 10
            ;;
    esac
    trust_state_lock || {
        merv_action_progress_fail "Stored action completed, but trust-state reconciliation failed"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"trust-state-relock-failed"}' "Stored action completed, but trust-state reconciliation failed." '[]' ssh-trust-state-failed
        return 75
    }
    if [ "$_str_rc" -eq 0 ]; then
        trust_mark_request "$_str_dir" completed || {
            trust_state_unlock
            merv_action_progress_fail "Stored action completed, but completion state could not be published"
            action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"completion-state-failed"}' "Stored action completed, but completion state could not be published." '[]' ssh-trust-state-failed
            return 75
        }
        trust_state_unlock
        merv_action_progress_complete "Stored action completed"
        action_ack_ok "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr "{\"resumed\":true,\"request_token\":\"$(trust_json_escape "$_str_fresh")\"}" "Stored action completed." '[]'
        return $?
    fi
    trust_mark_request "$_str_dir" failed || {
        trust_state_unlock
        merv_action_progress_fail "Stored action failed and reconciliation state could not be published"
        action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"failure-state-failed"}' "Stored action failed and reconciliation state could not be published." '[]' ssh-trust-state-failed
        return 75
    }
    trust_state_unlock
    merv_action_progress_fail "Stored action failed after SSH trust enrollment"
    action_ack_error "$SSH_TRUST_TOKEN" sshtrustresume_vlanmgr '{"reason":"resumed-action-failed"}' "Stored action failed after SSH trust enrollment." '[]' ssh-resumed-action-failed
    return "$_str_rc"
}

trust_main() {
    case "$SSH_TRUST_ACTION" in probe|enroll|resume|status|revoke|abort) ;; *) exit 2 ;; esac
    trust_token_valid "$SSH_TRUST_TOKEN" || exit 2
    trust_token_valid "$SSH_TRUST_PROGRESS_TOKEN" || exit 2
    case "$SSH_TRUST_ACTION" in
        enroll) SSH_TRUST_ACK_ACTION=sshtrustenroll_vlanmgr ;;
        resume) SSH_TRUST_ACK_ACTION=sshtrustresume_vlanmgr ;;
        status) SSH_TRUST_ACK_ACTION=sshtruststatus_vlanmgr ;;
        revoke) SSH_TRUST_ACK_ACTION=sshtrustrevoke_vlanmgr ;;
        abort) SSH_TRUST_ACK_ACTION=sshtrustabort_vlanmgr ;;
    esac
    if [ "${MERV_ACTION_LOCK_PARENT_HELD:-0}" != 1 ]; then
        merv_action_lock_acquire "${MERV_ACTION_LOCK_PATH:-$LOCKDIR/mervlan_action.lock}"
        _stam_rc=$?
        if [ "$_stam_rc" -ne 0 ]; then
            if ! action_ack_busy "$SSH_TRUST_TOKEN" "$SSH_TRUST_ACK_ACTION" '{"lock":"global"}' "Another configuration action is already running." '[]' >/dev/null 2>&1; then
                printf '%s\n' "[ERROR] SSH trust busy acknowledgement could not be published" >&2
            fi
            exit 75
        fi
        SSH_TRUST_ACTION_LOCKED=1
        SSH_TRUST_ACTION_NONCE="$MERV_ACTION_LOCK_NONCE"
        SSH_TRUST_ACTION_START="$MERV_ACTION_LOCK_START"
    fi
    trap 'trust_release_all_locks >/dev/null 2>&1 || logger -t VLANMgr "ssh trust cleanup could not prove/release ownership"' EXIT INT TERM
    case "$SSH_TRUST_ACTION" in
        probe) trust_probe ;;
        enroll) trust_enroll ;;
        resume) trust_resume ;;
        status) trust_status ;;
        revoke) trust_revoke ;;
        abort) trust_abort ;;
    esac
    _stam_result=$?
    if [ "$_stam_result" -ne 0 ] && [ "${MERV_ACTION_ACK_PUBLISHED:-0}" -ne 1 ]; then
        _stam_ack_action="sshtrust${SSH_TRUST_ACTION}_vlanmgr"
        action_ack_error "$SSH_TRUST_TOKEN" "$_stam_ack_action" \
            "{\"reason\":\"backend-failed\",\"exit_code\":$_stam_result}" \
            "The SSH trust action could not complete." '[]' ssh-trust-error >/dev/null 2>&1 || \
            logger -t VLANMgr "ssh trust fallback acknowledgement could not be published"
    fi
    trust_release_all_locks >/dev/null 2>&1
    _stam_cleanup_rc=$?
    if [ "$_stam_cleanup_rc" -ne 0 ] && [ "$_stam_result" -eq 0 ]; then
        _stam_result=75
    fi
    trap - EXIT INT TERM
    return "$_stam_result"
}

trust_main
