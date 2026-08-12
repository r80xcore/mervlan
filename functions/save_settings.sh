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
#               - File: save_settings.sh || version="0.54"                     #
# ============================================================================ #
# - Purpose:    Save current vlanmgr_* settings from custom_settings.txt into  #
#               settings.json (persistent storage) and public settings.json.   #
#               Also ensures custom_settings.txt has correct header line.      #
# ============================================================================ #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${MERV_STATE_ROOT:=/jffs/addons/mervlan_state}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED LIB_JSON_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
[ -n "${LIB_IDENTITY_LOADED:-}" ] || . "$MERV_BASE/settings/lib_identity.sh" 2>/dev/null || exit 1
[ -n "${LIB_SSH_LOADED:-}" ] || . "$MERV_BASE/settings/lib_ssh.sh" 2>/dev/null || :
[ -n "${LIB_ACTION_ACK_LOADED:-}" ] || . "$MERV_BASE/settings/lib_action_ack.sh" 2>/dev/null || :
[ -n "${LIB_MERVQT_LOADED:-}" ] || . "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || :
if [ -f "$MERV_BASE/settings/lib_update_state.sh" ]; then
    . "$MERV_BASE/settings/lib_update_state.sh" 2>/dev/null || exit 75
fi
if type merv_update_mutation_blocked >/dev/null 2>&1 && merv_update_mutation_blocked; then
    error -c vlan "save_settings.sh: Update maintenance is active; refusing a concurrent settings mutation"
    exit 75
fi
merv_action_progress_init() { :; }
merv_action_progress_complete() { :; }
if [ -f "$MERV_BASE/settings/lib_action_progress.sh" ]; then
    . "$MERV_BASE/settings/lib_action_progress.sh" 2>/dev/null || :
fi
merv_action_progress_init "${MERV_PROGRESS_TOKEN:-}" "save_vlanmgr" "Save Settings" \
    "Saving settings..."
_save_candidate_dir=""
_save_candidate=""
_save_cleanup_candidate() {
    [ -n "${_save_candidate:-}" ] && rm -f "${_save_candidate}" 2>/dev/null || :
    [ -n "${_save_candidate_dir:-}" ] && rmdir "${_save_candidate_dir}" 2>/dev/null || :
}
_save_signal_handling=0
_save_handle_signal() {
    _save_signal_status="$1"
    [ "${_save_signal_handling:-0}" -eq 0 ] || exit "$_save_signal_status"
    _save_signal_handling=1
    trap - INT TERM
    if type merv_action_progress_fail >/dev/null 2>&1; then
        merv_action_progress_fail "Settings save interrupted; no success result was published"
    fi
    printf '%s\n' "[WARN] save-settings interrupted (rc=$_save_signal_status); stopping before normal completion" >&2
    exit "$_save_signal_status"
}
trap '_save_handle_signal 130' INT
trap '_save_handle_signal 143' TERM
if [ -f "$MERV_BASE/settings/lib_action_lock.sh" ]; then
    . "$MERV_BASE/settings/lib_action_lock.sh" 2>/dev/null || exit 1
    _save_action_lock_path="${MERV_ACTION_LOCK_PATH:-${LOCKDIR:-/tmp/mervlan_tmp/locks}/mervlan_action.lock}"
    merv_action_lock_enter "$_save_action_lock_path"
    _save_action_lock_rc=$?
    if [ "$_save_action_lock_rc" -ne 0 ]; then
        _save_lock_message="The settings save could not start because its action lock could not be acquired."
        if [ "$_save_action_lock_rc" -eq 3 ]; then
            _save_lock_message="Another configuration action is already running; the settings save was not started."
        fi
        merv_action_progress_fail "$_save_lock_message"
        if [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_lock_failure >/dev/null 2>&1; then
            action_ack_lock_failure "$MERV_PROGRESS_TOKEN" save_vlanmgr "$_save_action_lock_rc" global >/dev/null 2>&1 || :
        fi
        exit 75
    fi
    _save_action_lock_mode="${MERV_ACTION_LOCK_MODE:-none}"
    _save_action_lock_nonce="$MERV_ACTION_LOCK_NONCE"; _save_action_lock_start="$MERV_ACTION_LOCK_START"
    merv_action_lock_export_child_context || exit 75
    _save_release_lock() {
        _save_exit_rc=$?
        if ! merv_action_lock_leave "$_save_action_lock_path" "$_save_action_lock_nonce" "$_save_action_lock_start" "$_save_action_lock_mode" >/dev/null 2>&1; then
            printf '%s\n' "[ERROR] save-settings action-lock cleanup failed; lock retained for recovery" >&2
            merv_action_progress_fail "Settings were saved, but action-lock cleanup failed; recovery is required."
            if [ "${MERV_ACTION_ACK_STAGE:-0}" != "1" ] &&
               [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_error >/dev/null 2>&1; then
                action_ack_error "$MERV_PROGRESS_TOKEN" save_vlanmgr \
                    '{"local_saved":"1","node_sync":"unknown"}' \
                    "Settings were saved, but backend action-lock cleanup failed; recovery is required." \
                    '["action-lock-cleanup-failed"]' action-lock-cleanup-failed >/dev/null 2>&1 || :
            fi
            [ "$_save_exit_rc" -eq 0 ] && _save_exit_rc=75
        fi
        _save_cleanup_candidate
        return "$_save_exit_rc"
    }
    trap '_save_release_lock' EXIT
fi
# =========================================== End of MerVLAN environment setup #
# ============================================================================ #
#                                    HELPERS                                   #
# Utility functions for managing custom_settings.txt and ensuring correct      #
# header lines before JSON conversion. These helpers ensure the file is in     #
# a consistent state before we begin extracting and converting settings.       #
# ============================================================================ #

# ============================================================================ #
# ensure_custom_settings_header                                                #
# Verify and update the first line of custom_settings_file with the version    #
# from changelog. Creates file if missing, replaces old header if present.     #
# ============================================================================ #
ensure_custom_settings_header() {
    # custom_settings.txt is an external Merlin-owned transport file.  It is
    # never rewritten by MerVLAN; the locked ledger capture below is the only
    # durable fallback copy.
    [ -f "${CUSTOM_SETTINGS_FILE}" ] || return 1
    return 0
}

# ============================================================================ #
# sort_vlanmgr_block_in_custom_settings                                        #
# Sort only lines starting with "vlanmgr_" alphabetically, directly in        #
# custom_settings.txt.                                                        #
#                                                                             #
# Guarantees:                                                                 #
# - First line (header) preserved as-is (already ensured by                   #
#   ensure_custom_settings_header).                                           #
# - Only lines that START with "vlanmgr_" are reordered.                      #
# - All other lines are kept byte-for-byte and in their original order.       #
# - No third-party or user lines are modified or deleted.                     #
# ============================================================================ #
sort_vlanmgr_block_in_custom_settings() {
    # If file doesn't exist, nothing to do
    [ -f "${CUSTOM_SETTINGS_FILE}" ] || return 0
    return 0

    : <<'MERV_LEGACY_NOOP'
        tail -n +2 "${CUSTOM_SETTINGS_FILE}" 2>/dev/null | while IFS= read -r line; do
            case "${line}" in
                vlanmgr_*) : ;;          # our keys → already re-emitted sorted above
                *) printf '%s\n' "$line" ;;
            esac
        done
    :

    :
MERV_LEGACY_NOOP
}

# ============================================================================ #
#                               INITIALIZATION                                 #
# Create required directories, prepare temporary files, and validate the       #
# custom_settings_file before processing. This ensures all paths are ready     #
# and the file structure is correct for the conversion pipeline.               #
# ============================================================================ #

info -c vlan "save_settings.sh: start"

# Detect ETH port capacity from Hardware section if not already set
if [ -z "${MAX_ETH_PORTS:-}" ]; then
    if [ -f "$HW_SETTINGS_FILE" ]; then
        MAX_ETH_PORTS="$(json_get_hw_int "MAX_ETH_PORTS" "" "$HW_SETTINGS_FILE" 2>/dev/null)"
    fi
fi

# Detect TRUNK port capacity (mirrors ETH/LAN unless overridden)
if [ -z "${MAX_TRUNK_PORTS:-}" ]; then
    if [ -n "${MAX_ETH_PORTS:-}" ]; then
        MAX_TRUNK_PORTS="$MAX_ETH_PORTS"
    else
        MAX_TRUNK_PORTS=8
    fi
fi

# Clamp to supported range (1-8)
case "$MAX_TRUNK_PORTS" in
    ''|*[!0-9]*) MAX_TRUNK_PORTS=8 ;;
esac
[ "$MAX_TRUNK_PORTS" -lt 1 ] && MAX_TRUNK_PORTS=1
[ "$MAX_TRUNK_PORTS" -gt 8 ] && MAX_TRUNK_PORTS=8

info -c vlan "save_settings.sh: MAX_ETH_PORTS=${MAX_ETH_PORTS:-unset}, MAX_TRUNK_PORTS=$MAX_TRUNK_PORTS"

# Create settings directory; abort if it fails
mkdir -p "${SETTINGSDIR}" || {
    error -c vlan "save_settings.sh: ERROR can't mkdir ${SETTINGSDIR}"
    exit 1
}

# Create results directory for temporary files; abort if it fails
mkdir -p "${RESULTDIR}" || {
    error -c vlan "save_settings.sh: ERROR can't mkdir ${RESULTDIR}"
    exit 1
}

# Initialize temporary file paths with PID suffix to avoid collisions on concurrent runs
TMP_KV="${RESULTDIR}/vlanmgr_kv.$$"
TMP_SORTED="${RESULTDIR}/vlanmgr_sorted.$$"
TMP_JSON="${RESULTDIR}/vlanmgr_json.$$"

# Claim a nonce-bearing same-directory staging namespace atomically.  The
# process nonce is required; PID alone is not sufficient for collision safety
# after a fast restart or PID reuse.
if ! merv_identity_nonce_next 2>/dev/null || [ -z "${MERV_IDENTITY_NONCE:-}" ]; then
    error -c vlan "save_settings.sh: could not create a unique settings transaction identity"
    exit 1
fi
_save_candidate_dir="${SETTINGSDIR}/.settings.json.save.${MERV_IDENTITY_NONCE}"
if ! ( umask 077; mkdir "${_save_candidate_dir}" 2>/dev/null ); then
    error -c vlan "save_settings.sh: settings transaction namespace is already claimed"
    exit 1
fi
_save_candidate="${_save_candidate_dir}/candidate.json"

# Truncate temporary files to empty state
> "${TMP_KV}"
> "${TMP_SORTED}"
> "${TMP_JSON}"

# Every setter below targets this same-filesystem candidate.  The
# authoritative settings file is not touched until the single final rename
# after all setters and validation have succeeded.
if [ -e "${SETTINGS_FILE}" ]; then
    [ -f "${SETTINGS_FILE}" ] || {
        error -c vlan "save_settings.sh: authoritative settings path is not a regular file"
        exit 1
    }
    cp -p "${SETTINGS_FILE}" "${_save_candidate}" 2>/dev/null || {
        error -c vlan "save_settings.sh: failed to stage authoritative settings"
        rm -f "${_save_candidate}"
        exit 1
    }
else
    printf '{\n}\n' > "${_save_candidate}" || {
        error -c vlan "save_settings.sh: failed to create staged settings"
        rm -f "${_save_candidate}"
        exit 1
    }
fi
chmod 600 "${_save_candidate}" 2>/dev/null || {
    error -c vlan "save_settings.sh: failed to set staged settings mode"
    rm -f "${_save_candidate}"
    exit 1
}
json_validate_file "${_save_candidate}" 2>/dev/null || {
    error -c vlan "save_settings.sh: authoritative settings are invalid; refusing mutation"
    rm -f "${_save_candidate}"
    exit 1
}

# Locked legacy fallback ledger.  Capture the external transport exactly once
# before parsing it; no MerVLAN code rewrites or sorts the Merlin-owned file.
if [ ! -f "${CUSTOM_SETTINGS_FILE}" ]; then
    error -c vlan "save_settings.sh: external custom settings transport is unavailable"
    rm -f "${_save_candidate}" 2>/dev/null
    exit 1
fi
mkdir -p "${MERV_STATE_ROOT}/ledgers" 2>/dev/null || { rm -f "${_save_candidate}" 2>/dev/null; exit 1; }
_save_ledger_tmp="${MERV_STATE_ROOT}/ledgers/custom_settings.$$"
( umask 077; cp "${CUSTOM_SETTINGS_FILE}" "$_save_ledger_tmp" ) 2>/dev/null || { rm -f "$_save_ledger_tmp" "${_save_candidate}" 2>/dev/null; exit 1; }
chmod 600 "$_save_ledger_tmp" 2>/dev/null || { rm -f "$_save_ledger_tmp" "${_save_candidate}" 2>/dev/null; exit 1; }
mv -f "$_save_ledger_tmp" "${MERV_STATE_ROOT}/ledgers/custom_settings.latest" 2>/dev/null || { rm -f "$_save_ledger_tmp" "${_save_candidate}" 2>/dev/null; exit 1; }

# Ensure custom_settings_file has correct version header
ensure_custom_settings_header

# Sort only our vlanmgr_* block inside custom_settings.txt
sort_vlanmgr_block_in_custom_settings

# Abort if custom_settings_file still doesn't exist after header ensure
if [ ! -f "${CUSTOM_SETTINGS_FILE}" ]; then
    error -c vlan "save_settings.sh: ${CUSTOM_SETTINGS_FILE} not found even after ensure_custom_settings_header, abort"
    rm -f "${_save_candidate}" 2>/dev/null
    exit 1
fi

# ============================================================================ #
# STEP 1: Extract vlanmgr_* keys and values                                    #
# Parse custom_settings_file and extract all lines matching vlanmgr_* prefix.  #
# Store as key-value pairs (tab-separated) with prefix removed for JSON keys.  #
# ============================================================================ #

while IFS= read -r LINE; do
    case "${LINE}" in
        vlanmgr_*)
            # Extract key part (everything before first space)
            KEY="${LINE%% *}"
            # Extract value part (everything after first space)
            VAL="${LINE#* }"
            # If no value found, key and value are same; set value to empty string
            if [ "${VAL}" = "${KEY}" ]; then
                VAL=""
            fi

            # Remove "vlanmgr_" prefix from key for JSON output
            SHORT_KEY="${KEY#vlanmgr_}"

            # Write tab-separated key-value pair to temporary file
            printf '%s\t%s\n' "${SHORT_KEY}" "${VAL}" >> "${TMP_KV}"
        ;;
    esac
done < "${CUSTOM_SETTINGS_FILE}"

# ============================================================================ #
# STEP 2: Sort keys alphabetically                                             #
# Sort the extracted key-value pairs by key name to create a predictable       #
# ordering in the JSON output. This makes diffs and manual inspection easier.  #
# ============================================================================ #

# Sort by first column (key name) to ensure consistent ordering across runs
sort -k1,1 "${TMP_KV}" > "${TMP_SORTED}"

# ============================================================================ #
# STEP 1.5: Extract and remove SAVE_SCOPE                                      #
# The UI sends vlanmgr_SAVE_SCOPE to indicate which subset of keys are present  #
# in this payload (normal/override/clientmeta/full). It must not be written    #
# into settings.json. Remove it here before any further processing.            #
# ============================================================================ #

SAVE_SCOPE="$(awk -F'\t' '$1=="SAVE_SCOPE"{print $2; exit}' "${TMP_KV}")"
case "$SAVE_SCOPE" in
    normal|override|clientmeta|full) :;;
    *) SAVE_SCOPE="full" ;; # backward-compatible: old UI sends no SAVE_SCOPE
esac
info -c vlan "save_settings.sh: SAVE_SCOPE=$SAVE_SCOPE"

# Strip SAVE_SCOPE key from TMP_KV — must never reach settings.json
_tmp_kv_scoped="${TMP_KV}.scoped.$$"
grep -v '^SAVE_SCOPE	' "${TMP_KV}" > "${_tmp_kv_scoped}" && mv "${_tmp_kv_scoped}" "${TMP_KV}" || rm -f "${_tmp_kv_scoped}"

# Re-sort after stripping SAVE_SCOPE
sort -k1,1 "${TMP_KV}" > "${TMP_SORTED}"

# Request-correlation fields are transport metadata for one action. They must
# never become persistent MerVLAN settings when a progress-enabled save later
# uses the shared MVM_exec path.
_tmp_kv_transport="${TMP_KV}.transport.$$"
grep -v '^\(progress_token\|action_request_token\|sshtrust_[A-Za-z0-9_]*\)[[:space:]]' "${TMP_KV}" > "${_tmp_kv_transport}" || :
if [ -f "${_tmp_kv_transport}" ]; then
    mv "${_tmp_kv_transport}" "${TMP_KV}"
else
    rm -f "${_tmp_kv_transport}"
fi
sort -k1,1 "${TMP_KV}" > "${TMP_SORTED}"

# ============================================================================ #
# STEP 1.6: Scope filter                                                       #
# Keep only the keys relevant to this save scope. This prevents stale          #
# vlanmgr_* lines already present in custom_settings.txt from bleeding into   #
# the wrong section when a scoped (override/clientmeta) save runs.             #
# ============================================================================ #
_tmp_kv_filtered="${TMP_KV}.filtered.$$"
case "$SAVE_SCOPE" in
    normal)
        # Keep VLAN/node/SSID/trunk/general keys; drop OVERRIDE_* and ClientMeta.
        awk -F'\t' '
            $1 !~ /^OVERRIDE_/ &&
            $1 != "MAC_SHIELD_OVERRIDES" &&
            $1 != "CLIENT_NAME_OVERRIDES" { print }
        ' "${TMP_KV}" > "${_tmp_kv_filtered}" && mv "${_tmp_kv_filtered}" "${TMP_KV}" || rm -f "${_tmp_kv_filtered}"
        ;;
    override)
        # Keep only OVERRIDE_* keys.
        awk -F'\t' '$1 ~ /^OVERRIDE_/ { print }' "${TMP_KV}" > "${_tmp_kv_filtered}" && \
            mv "${_tmp_kv_filtered}" "${TMP_KV}" || rm -f "${_tmp_kv_filtered}"
        ;;
    clientmeta)
        # Keep only ClientMeta keys.
        awk -F'\t' '$1 == "MAC_SHIELD_OVERRIDES" || $1 == "CLIENT_NAME_OVERRIDES" { print }' \
            "${TMP_KV}" > "${_tmp_kv_filtered}" && \
            mv "${_tmp_kv_filtered}" "${TMP_KV}" || rm -f "${_tmp_kv_filtered}"
        ;;
    full)
        : # keep everything already in TMP_KV
        ;;
esac

# Re-sort after scope filter
sort -k1,1 "${TMP_KV}" > "${TMP_SORTED}"

# Capture the node-relevant settings state before this save mutates the
# persistent file. The digest deliberately ignores main-router/WebUI-only
# settings so changing only those values does not cause an unnecessary node
# settings transfer. Missing/unavailable state remains conservative: it will
# require synchronization after the save.
_save_node_sync_before_digest=""
case "$SAVE_SCOPE" in
    normal|full)
        if [ -f "${SETTINGS_FILE}" ]; then
            _save_node_sync_before_digest=$(merv_settings_node_sync_digest "${SETTINGS_FILE}" 2>/dev/null) ||
                _save_node_sync_before_digest="unavailable"
        else
            _save_node_sync_before_digest="missing"
        fi
        ;;
esac

# ============================================================================ #
# STEP 2.5: Enforce ETHn_VLAN / trunkn safety                                  #
# Prevents a port from being both an access VLAN and a trunk simultaneously.    #
# ============================================================================ #
enforce_trunk_eth_exclusivity() {
    local TMP_FINAL idx val tmp_idx CONFIG_MAX_TRUNK_PORTS
    local TRUNK1 TRUNK2 TRUNK3 TRUNK4 TRUNK5 TRUNK6 TRUNK7 TRUNK8
    local ETH1 ETH2 ETH3 ETH4 ETH5 ETH6 ETH7 ETH8
    local TRUNK1_FINAL TRUNK2_FINAL TRUNK3_FINAL TRUNK4_FINAL TRUNK5_FINAL TRUNK6_FINAL TRUNK7_FINAL TRUNK8_FINAL
    local ETH1_FINAL ETH2_FINAL ETH3_FINAL ETH4_FINAL ETH5_FINAL ETH6_FINAL ETH7_FINAL ETH8_FINAL
    local FORCE_ETH1 FORCE_ETH2 FORCE_ETH3 FORCE_ETH4 FORCE_ETH5 FORCE_ETH6 FORCE_ETH7 FORCE_ETH8
    local FORCE_TRUNK1 FORCE_TRUNK2 FORCE_TRUNK3 FORCE_TRUNK4 FORCE_TRUNK5 FORCE_TRUNK6 FORCE_TRUNK7 FORCE_TRUNK8

    TMP_FINAL="${RESULTDIR}/vlanmgr_final.$$"
    CONFIG_MAX_TRUNK_PORTS=0

    TRUNK1=0; TRUNK2=0; TRUNK3=0; TRUNK4=0
    TRUNK5=0; TRUNK6=0; TRUNK7=0; TRUNK8=0
    ETH1=""; ETH2=""; ETH3=""; ETH4=""
    ETH5=""; ETH6=""; ETH7=""; ETH8=""

    _save_tab=$(printf '\t')
    while IFS="$_save_tab" read -r key val; do
        case "$key" in
            TRUNK1|trunk1) TRUNK1="$val" ;;
            TRUNK2|trunk2) TRUNK2="$val" ;;
            TRUNK3|trunk3) TRUNK3="$val" ;;
            TRUNK4|trunk4) TRUNK4="$val" ;;
            TRUNK5|trunk5) TRUNK5="$val" ;;
            TRUNK6|trunk6) TRUNK6="$val" ;;
            TRUNK7|trunk7) TRUNK7="$val" ;;
            TRUNK8|trunk8) TRUNK8="$val" ;;
            TAGGED_TRUNK[1-8])
                tmp_idx="${key#TAGGED_TRUNK}"
                case "$tmp_idx" in
                    ''|*[!0-9]*) : ;;
                    *)
                        if [ "$tmp_idx" -gt "$CONFIG_MAX_TRUNK_PORTS" ]; then
                            CONFIG_MAX_TRUNK_PORTS="$tmp_idx"
                        fi
                        ;;
                esac
                ;;
            UNTAGGED_TRUNK[1-8])
                tmp_idx="${key#UNTAGGED_TRUNK}"
                case "$tmp_idx" in
                    ''|*[!0-9]*) : ;;
                    *)
                        if [ "$tmp_idx" -gt "$CONFIG_MAX_TRUNK_PORTS" ]; then
                            CONFIG_MAX_TRUNK_PORTS="$tmp_idx"
                        fi
                        ;;
                esac
                ;;
            ETH1_VLAN) ETH1="$val" ;;
            ETH2_VLAN) ETH2="$val" ;;
            ETH3_VLAN) ETH3="$val" ;;
            ETH4_VLAN) ETH4="$val" ;;
            ETH5_VLAN) ETH5="$val" ;;
            ETH6_VLAN) ETH6="$val" ;;
            ETH7_VLAN) ETH7="$val" ;;
            ETH8_VLAN) ETH8="$val" ;;
        esac
    done < "${TMP_SORTED}"

    if [ "$CONFIG_MAX_TRUNK_PORTS" -gt 0 ] && [ "$CONFIG_MAX_TRUNK_PORTS" -lt "$MAX_TRUNK_PORTS" ]; then
        info -c vlan "save_settings.sh: configured trunk keys cap MAX_TRUNK_PORTS to $CONFIG_MAX_TRUNK_PORTS"
        MAX_TRUNK_PORTS="$CONFIG_MAX_TRUNK_PORTS"
    fi

    TRUNK1_FINAL="$TRUNK1"; TRUNK2_FINAL="$TRUNK2"; TRUNK3_FINAL="$TRUNK3"; TRUNK4_FINAL="$TRUNK4"
    TRUNK5_FINAL="$TRUNK5"; TRUNK6_FINAL="$TRUNK6"; TRUNK7_FINAL="$TRUNK7"; TRUNK8_FINAL="$TRUNK8"
    ETH1_FINAL="$ETH1"; ETH2_FINAL="$ETH2"; ETH3_FINAL="$ETH3"; ETH4_FINAL="$ETH4"
    ETH5_FINAL="$ETH5"; ETH6_FINAL="$ETH6"; ETH7_FINAL="$ETH7"; ETH8_FINAL="$ETH8"

    FORCE_ETH1=0; FORCE_ETH2=0; FORCE_ETH3=0; FORCE_ETH4=0
    FORCE_ETH5=0; FORCE_ETH6=0; FORCE_ETH7=0; FORCE_ETH8=0
    FORCE_TRUNK1=0; FORCE_TRUNK2=0; FORCE_TRUNK3=0; FORCE_TRUNK4=0
    FORCE_TRUNK5=0; FORCE_TRUNK6=0; FORCE_TRUNK7=0; FORCE_TRUNK8=0

    if [ "$TRUNK1" = "1" ]; then
        if [ -n "$ETH1" ] && [ "$ETH1" != "none" ]; then
            ETH1_FINAL="none"
            FORCE_ETH1=1
        fi
    else
        if [ -n "$ETH1" ] && [ "$ETH1" != "none" ]; then
            if [ "$TRUNK1" != "0" ]; then
                FORCE_TRUNK1=1
            fi
            TRUNK1_FINAL="0"
        fi
    fi

    if [ "$TRUNK2" = "1" ]; then
        if [ -n "$ETH2" ] && [ "$ETH2" != "none" ]; then
            ETH2_FINAL="none"
            FORCE_ETH2=1
        fi
    else
        if [ -n "$ETH2" ] && [ "$ETH2" != "none" ]; then
            if [ "$TRUNK2" != "0" ]; then
                FORCE_TRUNK2=1
            fi
            TRUNK2_FINAL="0"
        fi
    fi

    if [ "$TRUNK3" = "1" ]; then
        if [ -n "$ETH3" ] && [ "$ETH3" != "none" ]; then
            ETH3_FINAL="none"
            FORCE_ETH3=1
        fi
    else
        if [ -n "$ETH3" ] && [ "$ETH3" != "none" ]; then
            if [ "$TRUNK3" != "0" ]; then
                FORCE_TRUNK3=1
            fi
            TRUNK3_FINAL="0"
        fi
    fi

    if [ "$TRUNK4" = "1" ]; then
        if [ -n "$ETH4" ] && [ "$ETH4" != "none" ]; then
            ETH4_FINAL="none"
            FORCE_ETH4=1
        fi
    else
        if [ -n "$ETH4" ] && [ "$ETH4" != "none" ]; then
            if [ "$TRUNK4" != "0" ]; then
                FORCE_TRUNK4=1
            fi
            TRUNK4_FINAL="0"
        fi
    fi

    if [ "$TRUNK5" = "1" ]; then
        if [ -n "$ETH5" ] && [ "$ETH5" != "none" ]; then
            ETH5_FINAL="none"
            FORCE_ETH5=1
        fi
    else
        if [ -n "$ETH5" ] && [ "$ETH5" != "none" ]; then
            if [ "$TRUNK5" != "0" ]; then
                FORCE_TRUNK5=1
            fi
            TRUNK5_FINAL="0"
        fi
    fi

    if [ "$TRUNK6" = "1" ]; then
        if [ -n "$ETH6" ] && [ "$ETH6" != "none" ]; then
            ETH6_FINAL="none"
            FORCE_ETH6=1
        fi
    else
        if [ -n "$ETH6" ] && [ "$ETH6" != "none" ]; then
            if [ "$TRUNK6" != "0" ]; then
                FORCE_TRUNK6=1
            fi
            TRUNK6_FINAL="0"
        fi
    fi

    if [ "$TRUNK7" = "1" ]; then
        if [ -n "$ETH7" ] && [ "$ETH7" != "none" ]; then
            ETH7_FINAL="none"
            FORCE_ETH7=1
        fi
    else
        if [ -n "$ETH7" ] && [ "$ETH7" != "none" ]; then
            if [ "$TRUNK7" != "0" ]; then
                FORCE_TRUNK7=1
            fi
            TRUNK7_FINAL="0"
        fi
    fi

    if [ "$TRUNK8" = "1" ]; then
        if [ -n "$ETH8" ] && [ "$ETH8" != "none" ]; then
            ETH8_FINAL="none"
            FORCE_ETH8=1
        fi
    else
        if [ -n "$ETH8" ] && [ "$ETH8" != "none" ]; then
            if [ "$TRUNK8" != "0" ]; then
                FORCE_TRUNK8=1
            fi
            TRUNK8_FINAL="0"
        fi
    fi

    if [ "$FORCE_ETH1" -eq 1 ]; then
        info -c vlan "save_settings.sh: trunk1=1, forcing ETH1_VLAN=none"
    fi
    if [ "$FORCE_ETH2" -eq 1 ]; then
        info -c vlan "save_settings.sh: trunk2=1, forcing ETH2_VLAN=none"
    fi
    if [ "$FORCE_ETH3" -eq 1 ]; then
        info -c vlan "save_settings.sh: trunk3=1, forcing ETH3_VLAN=none"
    fi
    if [ "$FORCE_ETH4" -eq 1 ]; then
        info -c vlan "save_settings.sh: trunk4=1, forcing ETH4_VLAN=none"
    fi
    if [ "$FORCE_ETH5" -eq 1 ]; then
        info -c vlan "save_settings.sh: trunk5=1, forcing ETH5_VLAN=none"
    fi
    if [ "$FORCE_ETH6" -eq 1 ]; then
        info -c vlan "save_settings.sh: trunk6=1, forcing ETH6_VLAN=none"
    fi
    if [ "$FORCE_ETH7" -eq 1 ]; then
        info -c vlan "save_settings.sh: trunk7=1, forcing ETH7_VLAN=none"
    fi
    if [ "$FORCE_ETH8" -eq 1 ]; then
        info -c vlan "save_settings.sh: trunk8=1, forcing ETH8_VLAN=none"
    fi

    if [ "$FORCE_TRUNK1" -eq 1 ]; then
        info -c vlan "save_settings.sh: ETH1_VLAN!=none, forcing trunk1=0"
    fi
    if [ "$FORCE_TRUNK2" -eq 1 ]; then
        info -c vlan "save_settings.sh: ETH2_VLAN!=none, forcing trunk2=0"
    fi
    if [ "$FORCE_TRUNK3" -eq 1 ]; then
        info -c vlan "save_settings.sh: ETH3_VLAN!=none, forcing trunk3=0"
    fi
    if [ "$FORCE_TRUNK4" -eq 1 ]; then
        info -c vlan "save_settings.sh: ETH4_VLAN!=none, forcing trunk4=0"
    fi
    if [ "$FORCE_TRUNK5" -eq 1 ]; then
        info -c vlan "save_settings.sh: ETH5_VLAN!=none, forcing trunk5=0"
    fi
    if [ "$FORCE_TRUNK6" -eq 1 ]; then
        info -c vlan "save_settings.sh: ETH6_VLAN!=none, forcing trunk6=0"
    fi
    if [ "$FORCE_TRUNK7" -eq 1 ]; then
        info -c vlan "save_settings.sh: ETH7_VLAN!=none, forcing trunk7=0"
    fi
    if [ "$FORCE_TRUNK8" -eq 1 ]; then
        info -c vlan "save_settings.sh: ETH8_VLAN!=none, forcing trunk8=0"
    fi

    > "$TMP_FINAL"

    _save_tab=$(printf '\t')
    while IFS="$_save_tab" read -r key val; do
        case "$key" in
            ETH1_VLAN) val="$ETH1_FINAL" ;;
            ETH2_VLAN) val="$ETH2_FINAL" ;;
            ETH3_VLAN) val="$ETH3_FINAL" ;;
            ETH4_VLAN) val="$ETH4_FINAL" ;;
            ETH5_VLAN) val="$ETH5_FINAL" ;;
            ETH6_VLAN) val="$ETH6_FINAL" ;;
            ETH7_VLAN) val="$ETH7_FINAL" ;;
            ETH8_VLAN) val="$ETH8_FINAL" ;;
            TRUNK1|trunk1) continue ;;
            TRUNK2|trunk2) continue ;;
            TRUNK3|trunk3) continue ;;
            TRUNK4|trunk4) continue ;;
            TRUNK5|trunk5) continue ;;
            TRUNK6|trunk6) continue ;;
            TRUNK7|trunk7) continue ;;
            TRUNK8|trunk8) continue ;;
        esac
        printf '%s\t%s\n' "$key" "$val" >> "$TMP_FINAL"
    done < "${TMP_SORTED}"

    idx=1
    while [ "$idx" -le "$MAX_TRUNK_PORTS" ]; do
        case "$idx" in
            1) val="$TRUNK1_FINAL" ;;
            2) val="$TRUNK2_FINAL" ;;
            3) val="$TRUNK3_FINAL" ;;
            4) val="$TRUNK4_FINAL" ;;
            5) val="$TRUNK5_FINAL" ;;
            6) val="$TRUNK6_FINAL" ;;
            7) val="$TRUNK7_FINAL" ;;
            8) val="$TRUNK8_FINAL" ;;
            *) val="0" ;;
        esac
        printf 'TRUNK%s\t%s\n' "$idx" "$val" >> "$TMP_FINAL"
        idx=$((idx + 1))
    done

    sort -k1,1 "$TMP_FINAL" > "${TMP_SORTED}"
    rm -f "$TMP_FINAL"
}

# Only meaningful for normal/full saves; override and clientmeta payloads
# contain no ETH*/TRUNK* keys so the enforcer would be a no-op and could
# synthesise unwanted defaults on a metadata-only save.
case "$SAVE_SCOPE" in
    normal|full) enforce_trunk_eth_exclusivity ;;
    *) : ;; # skip for override / clientmeta
esac

# ============================================================================ #
# STEP 2.8: Separate Hardware_Override keys from normal flat keys              #
# Override keys use the flat convention OVERRIDE_<TARGET>_<FIELD> and must be  #
# written into the nested Hardware_Override section via json_set_section2_value#
# instead of flat json_set_flag. Split them into a separate file here.         #
#                                                                             #
# ClientMeta keys (MAC_SHIELD_OVERRIDES, CLIENT_NAME_OVERRIDES) are likewise  #
# routed into the nested "ClientMeta" section via json_set_section_value. This #
# avoids json_set_flag's flat-append path landing the key inside an unrelated #
# nested object on installs where the section is missing.                      #
# ============================================================================ #

TMP_OVERRIDE="${RESULTDIR}/vlanmgr_override.$$"
TMP_CLIENTMETA="${RESULTDIR}/vlanmgr_clientmeta.$$"
TMP_NORMAL="${RESULTDIR}/vlanmgr_normal.$$"
> "${TMP_OVERRIDE}"
> "${TMP_CLIENTMETA}"
> "${TMP_NORMAL}"

while IFS="$(printf '\t')" read -r key value; do
    case "$key" in
        OVERRIDE_*) printf '%s\t%s\n' "$key" "$value" >> "${TMP_OVERRIDE}" ;;
        MAC_SHIELD_OVERRIDES|CLIENT_NAME_OVERRIDES)
                    printf '%s\t%s\n' "$key" "$value" >> "${TMP_CLIENTMETA}" ;;
        *)          printf '%s\t%s\n' "$key" "$value" >> "${TMP_NORMAL}" ;;
    esac
done < "${TMP_SORTED}"

# Replace TMP_SORTED with normal-only keys for json_apply_kv_file
cp "${TMP_NORMAL}" "${TMP_SORTED}"

# Structured settings keep General-owned keys inside the General object.  The
# generic flat merge can update an existing nested key, but would append a
# missing key at the document root.  Seed these newer General settings in the
# correct section first so older installations migrate without losing shape.
save_candidate_is_empty_object() {
    awk '
        {
            line=$0
            gsub(/[[:space:]]/, "", line)
            if (line == "{") open_seen=1
            else if (line == "}") close_seen=1
            else if (line == "{}") { open_seen=1; close_seen=1 }
            else if (line != "") invalid=1
        }
        END { exit !(open_seen && close_seen && !invalid) }
    ' "${_save_candidate}" 2>/dev/null
}

seed_general_section_if_missing() {
    if grep -q '"General"[[:space:]]*:' "${_save_candidate}" 2>/dev/null; then
        return 0
    fi
    _sg_seed_tmp="${_save_candidate}.generalseed.${MERV_IDENTITY_NONCE}"
    if save_candidate_is_empty_object; then
        if printf '%s\n' \
            '{' \
            '  "General": {' \
            '    "_description": "Global addon flags and behavior toggles",' \
            '    "AUTO_SYNC_SETTINGS": "1",' \
            '    "HTML_CLIENT_REFRESH_MINUTES": "30"' \
            '  }' \
            '}' > "${_sg_seed_tmp}" 2>/dev/null &&
           mv "${_sg_seed_tmp}" "${_save_candidate}" 2>/dev/null; then
            return 0
        fi
        rm -f "${_sg_seed_tmp}" 2>/dev/null
        return 1
    fi
    if awk '
            BEGIN { seeded=0 }
            {
                if (!seeded && $0 ~ /^[[:space:]]*[{][[:space:]]*[}][[:space:]]*$/) {
                    print "{"
                    print "  \"General\": {"
                    print "    \"_description\": \"Global addon flags and behavior toggles\","
                    print "    \"AUTO_SYNC_SETTINGS\": \"1\","
                    print "    \"HTML_CLIENT_REFRESH_MINUTES\": \"30\""
                    print "  }"
                    print "}"
                    seeded=1
                    next
                }
                print
                if (!seeded && $0 ~ /^[[:space:]]*[{][[:space:]]*$/) {
                    print "  \"General\": {"
                    print "    \"_description\": \"Global addon flags and behavior toggles\","
                    print "    \"AUTO_SYNC_SETTINGS\": \"1\","
                    print "    \"HTML_CLIENT_REFRESH_MINUTES\": \"30\""
                    print "  },"
                    seeded=1
                }
            }
            END { if (!seeded) exit 1 }
        ' "${_save_candidate}" > "${_sg_seed_tmp}" 2>/dev/null && [ -s "${_sg_seed_tmp}" ] &&
        mv "${_sg_seed_tmp}" "${_save_candidate}" 2>/dev/null; then
        return 0
    fi
    rm -f "${_sg_seed_tmp}" 2>/dev/null
    return 1
}

seed_general_setting_from_normal_kv() {
    local _sg_key="$1" _sg_value
    _sg_value=$(awk -F '\t' -v key="$_sg_key" '$1 == key { print $2; found=1; exit } END { if (!found) exit 1 }' "${TMP_SORTED}") || return 0
    seed_general_section_if_missing || return 1
    json_set_section_value "General" "$_sg_key" "$_sg_value" "${_save_candidate}" || return 1
    _sg_observed=$(json_get_section_value "General" "$_sg_key" "${_save_candidate}" 2>/dev/null) || return 1
    [ "$_sg_observed" = "$_sg_value" ] || return 1
}

if [ "${SAVE_SCOPE:-full}" = "normal" ] || [ "${SAVE_SCOPE:-full}" = "full" ]; then
    if ! seed_general_setting_from_normal_kv "AUTO_SYNC_SETTINGS" || \
       ! seed_general_setting_from_normal_kv "HTML_CLIENT_REFRESH_MINUTES"; then
        error -c vlan "save_settings.sh: failed to seed General settings"
        rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}"
        exit 1
    fi
fi

# ============================================================================ #
# STEP 3: Merge into persistent settings.json                                   #
# Update the stored configuration in-place without overwriting unrelated keys. #
# ============================================================================ #

if ! json_apply_kv_file "${TMP_SORTED}" "${_save_candidate}"; then
    error -c vlan "save_settings.sh: failed to stage settings update"
    rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}" "${_save_candidate}"
    exit 1
fi

# ============================================================================ #
# STEP 3.5: Apply Hardware_Override keys into nested section                   #
# Map flat keys like OVERRIDE_MAIN_MAP_OVERRIDE → Hardware_Override.MAIN.MAP_OVERRIDE #
# ============================================================================ #

seed_hardware_override_if_missing() {
    _sho_target="$1"
    _sho_key="$2"
    if grep -q '"Hardware_Override"[[:space:]]*:' "${_save_candidate}" 2>/dev/null; then
        # An existing section may still lack this target.  The legacy setter
        # no-ops in that case, so only claim success after the exact target/key
        # is observable below.
        return 0
    fi
    _sho_seed_tmp="${_save_candidate}.hwseed.${MERV_IDENTITY_NONCE}"
    if save_candidate_is_empty_object; then
        if printf '%s\n' \
            '{' \
            '  "Hardware_Override": {' \
            '    "_description": "Optional manual WAN/LAN eth mapping override per device (MAIN and NODE1-NODE10)",' \
            "    \"${_sho_target}\": {" \
            '      "MAP_OVERRIDE": "0",' \
            '      "OVERRIDE_WAN": "eth0",' \
            '      "OVERRIDE_MAX_ETH_PORTS": "0",' \
            '      "OVERRIDE_LAN1": "none",' \
            '      "OVERRIDE_LAN2": "none",' \
            '      "OVERRIDE_LAN3": "none",' \
            '      "OVERRIDE_LAN4": "none",' \
            '      "OVERRIDE_LAN5": "none",' \
            '      "OVERRIDE_LAN6": "none",' \
            '      "OVERRIDE_LAN7": "none",' \
            '      "OVERRIDE_LAN8": "none"' \
            '    }' \
            '  }' \
            '}' > "${_sho_seed_tmp}" 2>/dev/null &&
           mv "${_sho_seed_tmp}" "${_save_candidate}" 2>/dev/null; then
            return 0
        fi
        rm -f "${_sho_seed_tmp}" 2>/dev/null
        return 1
    fi
    if awk -v target="$_sho_target" '
            BEGIN { seeded=0 }
            {
                if (!seeded && $0 ~ /^[[:space:]]*[{][[:space:]]*[}][[:space:]]*$/) {
                    print "{"
                    print "  \"Hardware_Override\": {"
                    print "    \"_description\": \"Optional manual WAN/LAN eth mapping override per device (MAIN and NODE1-NODE10)\","
                    print "    \"" target "\": {"
                    print "      \"MAP_OVERRIDE\": \"0\","
                    print "      \"OVERRIDE_WAN\": \"eth0\","
                    print "      \"OVERRIDE_MAX_ETH_PORTS\": \"0\","
                    print "      \"OVERRIDE_LAN1\": \"none\","
                    print "      \"OVERRIDE_LAN2\": \"none\","
                    print "      \"OVERRIDE_LAN3\": \"none\","
                    print "      \"OVERRIDE_LAN4\": \"none\","
                    print "      \"OVERRIDE_LAN5\": \"none\","
                    print "      \"OVERRIDE_LAN6\": \"none\","
                    print "      \"OVERRIDE_LAN7\": \"none\","
                    print "      \"OVERRIDE_LAN8\": \"none\""
                    print "    }"
                    print "  }"
                    print "}"
                    seeded=1
                    next
                }
                print
                if (!seeded && $0 ~ /^[[:space:]]*[{][[:space:]]*$/) {
                    print "  \"Hardware_Override\": {"
                    print "    \"_description\": \"Optional manual WAN/LAN eth mapping override per device (MAIN and NODE1-NODE10)\","
                    print "    \"" target "\": {"
                    print "      \"MAP_OVERRIDE\": \"0\","
                    print "      \"OVERRIDE_WAN\": \"eth0\","
                    print "      \"OVERRIDE_MAX_ETH_PORTS\": \"0\","
                    print "      \"OVERRIDE_LAN1\": \"none\","
                    print "      \"OVERRIDE_LAN2\": \"none\","
                    print "      \"OVERRIDE_LAN3\": \"none\","
                    print "      \"OVERRIDE_LAN4\": \"none\","
                    print "      \"OVERRIDE_LAN5\": \"none\","
                    print "      \"OVERRIDE_LAN6\": \"none\","
                    print "      \"OVERRIDE_LAN7\": \"none\","
                    print "      \"OVERRIDE_LAN8\": \"none\""
                    print "    }"
                    print "  },"
                    seeded=1
                }
            }
            END { if (!seeded) exit 1 }
        ' "${_save_candidate}" > "${_sho_seed_tmp}" 2>/dev/null && [ -s "${_sho_seed_tmp}" ] &&
        mv "${_sho_seed_tmp}" "${_save_candidate}" 2>/dev/null; then
        return 0
    fi
    rm -f "${_sho_seed_tmp}" 2>/dev/null
    return 1
}

if [ -s "${TMP_OVERRIDE}" ]; then
    _ovr_fail=0
    while IFS="$(printf '\t')" read -r okey oval; do
        # Parse: OVERRIDE_<TARGET>_<FIELD>
        # TARGET is MAIN or NODE<n> (1..MERV_MAX_NODES); FIELD is MAP_OVERRIDE, WAN, MAX_ETH_PORTS, LAN1..LAN8
        _ovr_rest="${okey#OVERRIDE_}"
        case "$_ovr_rest" in
            MAIN_*)
                _ovr_target="MAIN"; _ovr_field="${_ovr_rest#MAIN_}"
                ;;
            NODE[0-9]*_*)
                # Extract the numeric node id and the remaining field name.
                _ovr_num="${_ovr_rest#NODE}"
                _ovr_num="${_ovr_num%%_*}"
                _ovr_field="${_ovr_rest#NODE${_ovr_num}_}"
                case "$_ovr_num" in
                    ''|*[!0-9]*)
                        warn -c vlan "save_settings.sh: unrecognised override key: $okey"; _ovr_fail=1; continue ;;
                esac
                if [ "$_ovr_num" -lt 1 ] || [ "$_ovr_num" -gt "${MERV_MAX_NODES:-10}" ]; then
                    warn -c vlan "save_settings.sh: override node out of range: $okey"; _ovr_fail=1; continue
                fi
                _ovr_target="NODE${_ovr_num}"
                ;;
            *) warn -c vlan "save_settings.sh: unrecognised override key: $okey"; _ovr_fail=1; continue ;;
        esac
        # Re-prefix FIELD to match JSON key names (OVERRIDE_WAN, OVERRIDE_LAN1, etc.)
        # MAP_OVERRIDE stays as-is; WAN→OVERRIDE_WAN, MAX_ETH_PORTS→OVERRIDE_MAX_ETH_PORTS, LAN*→OVERRIDE_LAN*
        case "$_ovr_field" in
            MAP_OVERRIDE) _ovr_json_key="MAP_OVERRIDE" ;;
            *)            _ovr_json_key="OVERRIDE_${_ovr_field}" ;;
        esac
        if ! seed_hardware_override_if_missing "$_ovr_target" "$_ovr_json_key" ||
           ! json_set_section2_value "Hardware_Override" "$_ovr_target" "$_ovr_json_key" "$oval" "${_save_candidate}"; then
            warn -c vlan "save_settings.sh: failed to set Hardware_Override.$_ovr_target.$_ovr_json_key"
            _ovr_fail=1
        elif ! _ovr_observed=$(json_get_section2_value "Hardware_Override" "$_ovr_target" "$_ovr_json_key" "${_save_candidate}" 2>/dev/null) ||
             [ "$_ovr_observed" != "$oval" ]; then
            warn -c vlan "save_settings.sh: Hardware_Override.$_ovr_target.$_ovr_json_key verification failed"
            _ovr_fail=1
        fi
    done < "${TMP_OVERRIDE}"
    if [ "$_ovr_fail" = "0" ]; then
        info -c vlan "save_settings.sh: Hardware_Override keys applied"
    else
        error -c vlan "save_settings.sh: Hardware_Override setter failed; authoritative settings unchanged"
        rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}" "${_save_candidate}"
        exit 1
    fi
fi

# ============================================================================ #
# STEP 3.6: Apply ClientMeta keys into nested section                          #
# MAC_SHIELD_OVERRIDES / CLIENT_NAME_OVERRIDES are upserted into the           #
# "ClientMeta" section. json_set_section_value safely inserts the key inside   #
# that object even if the section exists without the key, and creates nothing  #
# unsafe if the section is missing (it simply no-ops the insert). The default  #
# settings.json ships the section so normal installs/updates always have it.   #
# ============================================================================ #

if [ -s "${TMP_CLIENTMETA}" ]; then
    # Defensive: the default/updated settings.json always ships a "ClientMeta"
    # section, but json_set_section_value silently no-ops (and still returns 0)
    # when the section is absent. So if it is somehow missing, seed an empty
    # section first — and log it — so the keys below actually persist instead of
    # vanishing without a trace.
    if ! grep -q '"ClientMeta"[[:space:]]*:' "${_save_candidate}" 2>/dev/null; then
        warn -c vlan "save_settings.sh: ClientMeta section missing — seeding it before write"
        _cm_seed_tmp="${_save_candidate}.cmseed.${MERV_IDENTITY_NONCE}"
        if save_candidate_is_empty_object; then
            if printf '%s\n' \
                '{' \
                '  "ClientMeta": {' \
                '    "_description": "MAC shield override and client display name configuration",' \
                '    "MAC_SHIELD_OVERRIDES": "",' \
                '    "CLIENT_NAME_OVERRIDES": ""' \
                '  }' \
                '}' > "${_cm_seed_tmp}" 2>/dev/null &&
               mv "${_cm_seed_tmp}" "${_save_candidate}" 2>/dev/null; then
                :
            else
                rm -f "${_cm_seed_tmp}" 2>/dev/null
                error -c vlan "save_settings.sh: failed to seed ClientMeta section"
                rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}" "${_save_candidate}"
                exit 1
            fi
        elif awk '
                BEGIN { seeded=0 }
                {
                    print
                    if (!seeded && $0 ~ /^[[:space:]]*[{][[:space:]]*$/) {
                        print "  \"ClientMeta\": {"
                        print "    \"_description\": \"MAC shield override and client display name configuration\","
                        print "    \"MAC_SHIELD_OVERRIDES\": \"\","
                        print "    \"CLIENT_NAME_OVERRIDES\": \"\""
                        print "  },"
                        seeded=1
                    }
                }
            ' "${_save_candidate}" > "${_cm_seed_tmp}" 2>/dev/null && [ -s "${_cm_seed_tmp}" ]; then
            mv "${_cm_seed_tmp}" "${_save_candidate}" 2>/dev/null || {
                rm -f "${_cm_seed_tmp}" 2>/dev/null
                error -c vlan "save_settings.sh: failed to seed ClientMeta section"
                rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}" "${_save_candidate}"
                exit 1
            }
        else
            rm -f "${_cm_seed_tmp}" 2>/dev/null
            error -c vlan "save_settings.sh: failed to seed ClientMeta section"
            rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}" "${_save_candidate}"
            exit 1
        fi
    fi
    _cm_fail=0
    while IFS="$(printf '\t')" read -r cmkey cmval; do
        [ -n "$cmkey" ] || continue
        if ! json_set_section_value "ClientMeta" "$cmkey" "$cmval" "${_save_candidate}"; then
            warn -c vlan "save_settings.sh: failed to set ClientMeta.$cmkey"
            _cm_fail=1
        elif ! _cm_observed=$(json_get_section_value "ClientMeta" "$cmkey" "${_save_candidate}" 2>/dev/null) ||
             [ "$_cm_observed" != "$cmval" ]; then
            warn -c vlan "save_settings.sh: ClientMeta.$cmkey verification failed"
            _cm_fail=1
        fi
    done < "${TMP_CLIENTMETA}"
    if [ "$_cm_fail" = "0" ]; then
        info -c vlan "save_settings.sh: ClientMeta keys applied"
    else
        error -c vlan "save_settings.sh: ClientMeta setter failed; authoritative settings unchanged"
        rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}" "${_save_candidate}"
        exit 1
    fi
fi

rm -f "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}"

chmod 600 "${_save_candidate}" 2>/dev/null || {
    error -c vlan "save_settings.sh: failed to set staged settings mode"
    rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}" "${_save_candidate}"
    exit 1
}
json_validate_file "${_save_candidate}" 2>/dev/null || {
    error -c vlan "save_settings.sh: staged settings failed JSON validation"
    rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}" "${_save_candidate}"
    exit 1
}

_save_node_sync_required="yes"
if [ -n "${_save_node_sync_before_digest}" ] && [ -f "${_save_candidate}" ]; then
    _save_node_sync_after_digest=$(merv_settings_node_sync_digest "${_save_candidate}" 2>/dev/null) ||
        _save_node_sync_after_digest="unavailable"
    if [ "${_save_node_sync_before_digest}" != "missing" ] &&
       [ "${_save_node_sync_before_digest}" != "unavailable" ] &&
       [ "${_save_node_sync_after_digest}" != "unavailable" ] &&
       [ "${_save_node_sync_before_digest}" = "${_save_node_sync_after_digest}" ]; then
        _save_node_sync_required="no"
        info -c vlan "save_settings.sh: only main-router/WebUI-local settings changed"
    fi
fi

# ============================================================================ #
# STEP 4: Convert to pretty JSON format                                        #
# Build a properly formatted JSON object from sorted key-value pairs. Escape   #
# special characters (backslashes, quotes) and add comma separators between    #
# entries. The last entry has no trailing comma (valid JSON).                  #
# If the settings file is structured, preserve that structure in the public    #
# JSON by copying the updated settings.json instead of flattening.             #
# ============================================================================ #

if ! cp "${_save_candidate}" "${TMP_JSON}" 2>/dev/null; then
    error -c vlan "save_settings.sh: failed to prepare public settings artifact"
    rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${_save_candidate}"
    exit 1
fi
json_validate_file "${TMP_JSON}" 2>/dev/null || {
    error -c vlan "save_settings.sh: public settings artifact failed JSON validation"
    rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${_save_candidate}"
    exit 1
}

# One authoritative commit for this logical Save.  All failures above leave
# the previous settings bytes untouched.
if ! mv -f "${_save_candidate}" "${SETTINGS_FILE}" 2>/dev/null; then
    error -c vlan "save_settings.sh: authoritative settings commit failed"
    rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}" "${_save_candidate}"
    exit 1
fi
info -c vlan "save_settings.sh: updated ${SETTINGS_FILE}"

# ============================================================================ #
# ============================================================================ #
# STEP 5: Install public (UI-fetchable) copy                                   #
# Copy the JSON to the web-accessible public directory so the iframe can       #
# fetch settings/settings.json. World-readable (644) permissions allow the UI  #
# to load settings without special access. Warns if the public dir is missing  #
# ============================================================================ #

_save_public_status="ok"
_save_public_reason=""
if [ -n "${PUBLIC_MERV_BASE}" ]; then
    if ! mkdir -p "${PUBLIC_SETTINGS_DIR}" 2>/dev/null; then
        _save_public_status="failed"
        _save_public_reason="public settings directory could not be created"
    elif [ -L "${PUBLIC_SETTINGS_FILE}" ]; then
        # Installer deployments use a symlink to the authoritative file.  Do
        # not cp through it: the single authoritative mv above is the commit.
        if ! cmp -s "${TMP_JSON}" "${PUBLIC_SETTINGS_FILE}" 2>/dev/null; then
            _save_public_status="failed"
            _save_public_reason="public settings symlink does not expose the committed bytes"
        elif ! chmod 644 "${PUBLIC_SETTINGS_FILE}" 2>/dev/null; then
            _save_public_status="failed"
            _save_public_reason="public settings permissions could not be published"
        fi
    elif ! cp "${TMP_JSON}" "${PUBLIC_SETTINGS_FILE}" 2>/dev/null; then
        _save_public_status="failed"
        _save_public_reason="public settings copy failed"
    elif ! chmod 644 "${PUBLIC_SETTINGS_FILE}" 2>/dev/null; then
        _save_public_status="failed"
        _save_public_reason="public settings permissions could not be published"
    fi
else
    _save_public_status="failed"
    _save_public_reason="no public settings directory is configured"
fi

if [ "$_save_public_status" = "ok" ]; then
    info -c vlan,cli "Settings saved!"
else
    warn -c vlan,cli "save_settings.sh: local settings committed, but $_save_public_reason"
fi

# ============================================================================ #
# STEP 6: Auto-sync settings to configured nodes (if enabled)                 #
# Defer auto-sync if SAVE_SCOPE is override (APMO handles sync after probe)   #
# or clientmeta.                                                               #
# ============================================================================ #

_save_node_sync_status="skipped"
if [ "$_save_public_status" != "ok" ]; then
    _save_node_sync_status="skipped-public-failure"
fi
if [ "$_save_public_status" = "ok" ] && [ "${SAVE_SCOPE:-full}" != "override" ] && [ "${SAVE_SCOPE:-full}" != "clientmeta" ]; then
    _auto_sync_flag=$(json_get_flag "AUTO_SYNC_SETTINGS" "" "${SETTINGS_FILE}" 2>/dev/null)
    _nodes_configured=""
    for _n_idx in 1 2 3 4 5 6 7 8 9 10; do
        _nip=$(json_get_section_value "Nodes" "NODE${_n_idx}" "${SETTINGS_FILE}" 2>/dev/null)
        [ -n "$_nip" ] || _nip=$(json_get_flag "NODE${_n_idx}" "" "${SETTINGS_FILE}" 2>/dev/null)
        [ -n "$_nip" ] || _nip=$(json_get_flag "NODE${_n_idx}_IP" "" "${SETTINGS_FILE}" 2>/dev/null)
        if [ -n "$_nip" ] && [ "$_nip" != "none" ]; then
            _nodes_configured="$_nip"
            break
        fi
    done

    _should_auto_sync="no"
    if [ -n "$_nodes_configured" ] && \
       { [ "$_auto_sync_flag" = "1" ] || [ "$_auto_sync_flag" = "true" ] || [ "$_auto_sync_flag" = "yes" ]; }; then
        _should_auto_sync="yes"
    elif [ -z "$_auto_sync_flag" ] && [ -n "$_nodes_configured" ]; then
        if type ssh_keys_effectively_installed >/dev/null 2>&1 && ssh_keys_effectively_installed 2>/dev/null; then
            _should_auto_sync="yes"
        fi
    fi

    if [ "$_should_auto_sync" = "yes" ] && [ "${_save_node_sync_required:-yes}" = "yes" ]; then
        if [ -n "${MERV_PROGRESS_TOKEN:-}" ]; then
            # The WebUI Save action must finish its local persistence phase
            # before a node-mutating operation starts.  The browser queues the
            # settings-only action separately so it can own preflight,
            # trust-review pause/resume, and terminal progress reporting.
            _save_node_sync_status="pending"
            info -c vlan,cli "Node settings auto-sync queued after local save"
        else
            info -c vlan,cli "Auto-syncing settings to nodes..."
        # The nested sync is owned by this Save transaction. Do not reuse the
        # Save progress token for the child action, otherwise the child could
        # overwrite the Save progress/ack record.
        if ! MERV_ACTION_LOCK_PARENT_HELD=1 MERV_PROGRESS_TOKEN="" \
           sh "$MERV_BASE/functions/sync_nodes.sh" --settings-only; then
            _save_node_sync_status="failed"
            warn -c vlan,cli "⚠️ Node settings auto-sync completed with warnings; local settings saved"
        else
            _save_node_sync_status="ok"
            info -c vlan,cli "✓ Node settings auto-sync complete"
        fi
        fi
    elif [ "$_should_auto_sync" = "yes" ]; then
        _save_node_sync_status="skipped-local-only"
        info -c vlan,cli "Skipping node settings auto-sync; only main-router/WebUI-local settings changed"
    fi
fi

if [ "${SAVE_SCOPE:-full}" = "override" ]; then
    # APMO owns the ordered follow-up (probe, reload, optional node sync).
    _save_node_sync_status="deferred-apmo"
fi

# Publish a correlated terminal result when the browser supplied a save token.
# A node-sync failure is partial: the local settings file is still valid and
# must not be reported as a failed local save.
if [ -n "${MERV_PROGRESS_TOKEN:-}" ] && type action_ack_partial >/dev/null 2>&1 && type action_ack_ok >/dev/null 2>&1; then
    _save_ack_partial=action_ack_partial
    _save_ack_ok=action_ack_ok
    if [ "${MERV_ACTION_ACK_STAGE:-0}" = "1" ] && type action_ack_stage_partial >/dev/null 2>&1 && type action_ack_stage_ok >/dev/null 2>&1; then
        _save_ack_partial=action_ack_stage_partial
        _save_ack_ok=action_ack_stage_ok
    fi
    if [ "$_save_public_status" != "ok" ]; then
        "$_save_ack_partial" "$MERV_PROGRESS_TOKEN" "save_vlanmgr" \
            '{"local_saved":"1","public_settings":"failed","node_sync":"skipped"}' \
            "Settings saved locally, but public settings publication failed: $_save_public_reason" \
            '["public-settings-publication-failed"]' >/dev/null 2>&1 || :
    elif [ "$_save_node_sync_status" = "failed" ]; then
        "$_save_ack_partial" "$MERV_PROGRESS_TOKEN" "save_vlanmgr" \
            '{"local_saved":"1","node_sync":"failed"}' \
            "Settings saved locally; node settings synchronization failed." \
            '["node-settings-sync-failed"]' >/dev/null 2>&1 || :
    elif [ "$_save_node_sync_status" = "pending" ]; then
        "$_save_ack_ok" "$MERV_PROGRESS_TOKEN" "save_vlanmgr" \
            '{"local_saved":"1","node_sync":"pending"}' \
            "Settings saved successfully; node settings synchronization is queued." '[]' >/dev/null 2>&1 || :
    else
        "$_save_ack_ok" "$MERV_PROGRESS_TOKEN" "save_vlanmgr" \
            "{\"local_saved\":\"1\",\"node_sync\":\"$_save_node_sync_status\"}" \
            "Settings saved successfully." '[]' >/dev/null 2>&1 || :
    fi
    if [ "$_save_public_status" != "ok" ]; then
        merv_action_progress_fail "Settings saved locally, but public settings publication failed."
    elif [ "$_save_node_sync_status" = "failed" ]; then
        merv_action_progress_complete "Settings saved locally; node sync failed."
    else
        merv_action_progress_complete "Settings save complete."
    fi
fi

# ============================================================================ #
# CLEANUP                                                                      #
# Remove all temporary files used during the conversion process. These files   #
# contain intermediate key-value and JSON data and are no longer needed after  #
# the persistent and public copies have been installed successfully.           #
# ============================================================================ #

# Delete temporary work files (no longer needed after installation)
rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}"

# Signal successful completion to parent script
exit 0
