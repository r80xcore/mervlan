#!/bin/sh
#
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
#               - File: save_settings.sh || version="0.46"                     #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Save current vlanmgr_* settings from custom_settings.txt into  #
#               settings.json (persistent storage) and public settings.json.   #
#               Also ensures custom_settings.txt has correct header line.      #
# ──────────────────────────────────────────────────────────────────────────── #
#                                                                              #
# ================================================== MerVLAN environment setup #
: "${MERV_BASE:=/jffs/addons/mervlan}"
if { [ -n "${VAR_SETTINGS_LOADED:-}" ] && [ -z "${LOG_SETTINGS_LOADED:-}" ]; } || \
   { [ -z "${VAR_SETTINGS_LOADED:-}" ] && [ -n "${LOG_SETTINGS_LOADED:-}" ]; }; then
  unset VAR_SETTINGS_LOADED LOG_SETTINGS_LOADED
fi
[ -n "${VAR_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/var_settings.sh"
[ -n "${LOG_SETTINGS_LOADED:-}" ] || . "$MERV_BASE/settings/log_settings.sh"
[ -n "${LIB_JSON_LOADED:-}" ] || . "$MERV_BASE/settings/lib_json.sh"
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
    local raw first_line version HEADER_LINE

    # Try to read the first line of changelog.txt (if present)
    if [ -f "${MERV_BASE}/changelog.txt" ]; then
        # Strip CR if present (Windows-style line endings safety)
        raw="$(head -n1 "${MERV_BASE}/changelog.txt" 2>/dev/null | tr -d '\r')"
        first_line="$raw"

        # Extract a token that looks like v0.48, v1.0, v1.02, etc.
        version="$(printf '%s\n' "$first_line" | sed -n 's/.*\(v[0-9][0-9.]*\).*/\1/p')"
    fi

    if [ -n "$version" ]; then
        # Final header format you asked for
        HEADER_LINE="MerVLAN Manager ${version}"
    else
        # Fallback if changelog missing or no vX.Y pattern found
        HEADER_LINE="MerVLAN Manager v.unknown"
    fi

    if [ -f "${CUSTOM_SETTINGS_FILE}" ]; then
        # Read current first line to check if update needed
        CURRENT_FIRST_LINE="$(head -n1 "${CUSTOM_SETTINGS_FILE}" 2>/dev/null)"

        # Only rewrite file if header is outdated; idempotent on second run
        if [ "${CURRENT_FIRST_LINE}" != "${HEADER_LINE}" ]; then

            # File has an old MerVLAN header: replace first line only
            if echo "${CURRENT_FIRST_LINE}" | grep -qiE '^mervlan[[:space:]]|^MerVLAN Manager[[:space:]]'; then
                {
                    echo "${HEADER_LINE}"
                    tail -n +2 "${CUSTOM_SETTINGS_FILE}"
                } > "${CUSTOM_SETTINGS_FILE}.tmp" && mv "${CUSTOM_SETTINGS_FILE}.tmp" "${CUSTOM_SETTINGS_FILE}"

            # File has no MerVLAN header: prepend new header to existing content
            else
                {
                    echo "${HEADER_LINE}"
                    cat "${CUSTOM_SETTINGS_FILE}"
                } > "${CUSTOM_SETTINGS_FILE}.tmp" && mv "${CUSTOM_SETTINGS_FILE}.tmp" "${CUSTOM_SETTINGS_FILE}"
            fi

            chmod 600 "${CUSTOM_SETTINGS_FILE}"
        fi
    else
        # File doesn't exist: create new with header only
        echo "${HEADER_LINE}" > "${CUSTOM_SETTINGS_FILE}"
        chmod 600 "${CUSTOM_SETTINGS_FILE}"
    fi
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

    # Capture header (first line) as-is
    HEADER_LINE="$(head -n1 "${CUSTOM_SETTINGS_FILE}" 2>/dev/null)"

    # Collect and sort ONLY our keys (lines starting with "vlanmgr_")
    VLANMGR_SORTED="$(grep '^vlanmgr_' "${CUSTOM_SETTINGS_FILE}" 2>/dev/null | sort)"

    # If there are no vlanmgr_ lines, don't touch the file
    [ -z "${VLANMGR_SORTED}" ] && return 0

    TMP_FILE="${CUSTOM_SETTINGS_FILE}.sorted.$$"

    {
        # 1) Write header line first (unchanged)
        [ -n "${HEADER_LINE}" ] && printf '%s\n' "${HEADER_LINE}"

        # 2) Then our vlanmgr_* block, sorted
        printf '%s\n' "${VLANMGR_SORTED}"

        # 3) Replay all other lines (except header + vlanmgr_ lines) as-is,
        #    preserving their original order and content.
        #
        #    - tail -n +2 skips the header we already printed
        #    - we skip only lines starting with "vlanmgr_"
        tail -n +2 "${CUSTOM_SETTINGS_FILE}" 2>/dev/null | while IFS= read -r line; do
            case "${line}" in
                vlanmgr_*) : ;;          # our keys → already re-emitted sorted above
                *) printf '%s\n' "$line" ;;
            esac
        done
    } > "${TMP_FILE}" && mv "${TMP_FILE}" "${CUSTOM_SETTINGS_FILE}"

    chmod 600 "${CUSTOM_SETTINGS_FILE}" 2>/dev/null || :
}

# ============================================================================ #
#                               INITIALIZATION                                 #
# Create required directories, prepare temporary files, and validate the       #
# custom_settings_file before processing. This ensures all paths are ready     #
# and the file structure is correct for the conversion pipeline.               #
# ============================================================================ #

info -c vlan "save_settings.sh: start"

# Detect TRUNK port capacity (mirrors ETH/LAN unless overridden)
if [ -z "${MAX_TRUNK_PORTS:-}" ]; then
    if [ -n "${MAX_ETH_PORTS:-}" ]; then
        MAX_TRUNK_PORTS="$MAX_ETH_PORTS"
    else
        if [ -f "$HW_SETTINGS_FILE" ]; then
            MAX_TRUNK_PORTS="$(json_get_int "MAX_ETH_PORTS" 8 "$HW_SETTINGS_FILE" 2>/dev/null)"
        fi
        [ -n "$MAX_TRUNK_PORTS" ] || MAX_TRUNK_PORTS=8
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

# Truncate temporary files to empty state
> "${TMP_KV}"
> "${TMP_SORTED}"
> "${TMP_JSON}"

# Ensure custom_settings_file has correct version header
ensure_custom_settings_header

# Sort only our vlanmgr_* block inside custom_settings.txt
sort_vlanmgr_block_in_custom_settings

# Abort if custom_settings_file still doesn't exist after header ensure
if [ ! -f "${CUSTOM_SETTINGS_FILE}" ]; then
    error -c vlan "save_settings.sh: ${CUSTOM_SETTINGS_FILE} not found even after ensure_custom_settings_header, abort"
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

    while IFS=$'\t' read -r key val; do
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

    while IFS=$'\t' read -r key val; do
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

enforce_trunk_eth_exclusivity

# ============================================================================ #
# STEP 3: Merge into persistent settings.json                                   #
# Update the stored configuration in-place without overwriting unrelated keys. #
# ============================================================================ #

if ! json_apply_kv_file "${TMP_SORTED}" "${SETTINGS_FILE}"; then
    error -c vlan "save_settings.sh: failed to update ${SETTINGS_FILE}"
    rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}"
    exit 1
fi

chmod 600 "${SETTINGS_FILE}"
info -c vlan "save_settings.sh: updated ${SETTINGS_FILE}"

# ============================================================================ #
# STEP 4: Convert to pretty JSON format                                        #
# Build a properly formatted JSON object from sorted key-value pairs. Escape   #
# special characters (backslashes, quotes) and add comma separators between    #
# entries. The last entry has no trailing comma (valid JSON).                  #
# ============================================================================ #

echo "{" > "${TMP_JSON}"

# Count total lines to know when we've reached the last entry (no trailing comma)
LINECOUNT=$(wc -l < "${TMP_SORTED}")
COUNT=0

while IFS=$'\t' read -r OUTKEY OUTVAL; do
    COUNT=$((COUNT + 1))

    # Escape backslashes and quotes in value to make valid JSON string literals
    ESCAPED_VAL=$(json_escape_string "${OUTVAL}")

    # Add comma after entries except the last one (valid JSON format)
    if [ "${COUNT}" -lt "${LINECOUNT}" ]; then
        printf '  "%s": "%s",\n' "${OUTKEY}" "${ESCAPED_VAL}" >> "${TMP_JSON}"
    else
        printf '  "%s": "%s"\n' "${OUTKEY}" "${ESCAPED_VAL}" >> "${TMP_JSON}"
    fi
done < "${TMP_SORTED}"

# Close JSON object
echo "}" >> "${TMP_JSON}"

# ============================================================================ #
# ============================================================================ #
# STEP 5: Install public (UI-fetchable) copy                                   #
# Copy the JSON to the web-accessible public directory so the iframe can       #
# fetch settings/settings.json. World-readable (644) permissions allow the UI  #
# to load settings without special access. Warns if the public dir is missing  #
# ============================================================================ #

if [ -n "${PUBLIC_MERV_BASE}" ]; then
    # Attempt to create the public settings directory for web access
    if mkdir -p "${PUBLIC_SETTINGS_DIR}" 2>/dev/null; then
        # Copy JSON to public path where iframe can fetch it via HTTP
        cp "${TMP_JSON}" "${PUBLIC_SETTINGS_FILE}"
        # Set world-readable permissions so the web UI can access it
        chmod 644 "${PUBLIC_SETTINGS_FILE}"
        info -c vlan,cli "Settings saved!"
    else
        # Directory creation failed; warn but don't abort (persistent copy already installed)
        warn -c vlan "save_settings.sh: WARN can't mkdir ${PUBLIC_SETTINGS_DIR}"
    fi
else
    # No public base directory configured; persistent copy installed but web UI won't see it
    error -c vlan "save_settings.sh: WARN no public base dir available, skipping web copy"
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
