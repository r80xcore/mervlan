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
#               - File: save_settings.sh || version="0.45"                     #
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
    # Extract version from changelog, parse "Addon: mervlan v.X.Y" format
    HEADER_LINE="$(sed -n 's/^Addon:[[:space:]]*//p;q' "${MERV_BASE}/changelog.txt")"

    # Use fallback version if changelog is missing or unparseable
    [ -z "${HEADER_LINE}" ] && HEADER_LINE="mervlan v.unknown"

    if [ -f "${CUSTOM_SETTINGS_FILE}" ]; then
        # Read current first line to check if update needed
        CURRENT_FIRST_LINE="$(head -n1 "${CUSTOM_SETTINGS_FILE}" 2>/dev/null)"

        # Only rewrite file if header is outdated; idempotent on second run
        if [ "${CURRENT_FIRST_LINE}" != "${HEADER_LINE}" ]; then

            # File has old header (starts with "mervlan"): replace first line only
            if echo "${CURRENT_FIRST_LINE}" | grep -q '^mervlan[[:space:]]'; then
                {
                    echo "${HEADER_LINE}"
                    tail -n +2 "${CUSTOM_SETTINGS_FILE}"
                } > "${CUSTOM_SETTINGS_FILE}.tmp" && mv "${CUSTOM_SETTINGS_FILE}.tmp" "${CUSTOM_SETTINGS_FILE}"

            # File has no mervlan header: prepend new header to existing content
            else
                {
                    echo "${HEADER_LINE}"
                    cat "${CUSTOM_SETTINGS_FILE}"
                } > "${CUSTOM_SETTINGS_FILE}.tmp" && mv "${CUSTOM_SETTINGS_FILE}.tmp" "${CUSTOM_SETTINGS_FILE}"
            fi

            # Secure permissions: owner read/write only (no world access)
            chmod 600 "${CUSTOM_SETTINGS_FILE}"
        fi
    else
        # File doesn't exist: create new with header only
        echo "${HEADER_LINE}" > "${CUSTOM_SETTINGS_FILE}"
        chmod 600 "${CUSTOM_SETTINGS_FILE}"
    fi
}

# ============================================================================ #
#                               INITIALIZATION                                 #
# Create required directories, prepare temporary files, and validate the       #
# custom_settings_file before processing. This ensures all paths are ready     #
# and the file structure is correct for the conversion pipeline.               #
# ============================================================================ #

info -c vlan "save_settings.sh: start"

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
# STEP 3: Convert to pretty JSON format                                        #
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
    ESCAPED_VAL=$(echo "${OUTVAL}" | sed 's/\\/\\\\/g; s/"/\\"/g')

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
# STEP 4: Install persistent copy                                              #
# Copy the JSON to the persistent settings file with restricted permissions    #
# (600) so only the admin user can read/modify. This is the source of truth    #
# for all VLAN Manager configuration on the router.                            #
# ============================================================================ #

cp "${TMP_JSON}" "${SETTINGS_FILE}"
# Set restrictive permissions (owner read/write only) for security
chmod 600 "${SETTINGS_FILE}"
info -c vlan "save_settings.sh: wrote ${SETTINGS_FILE}"

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
