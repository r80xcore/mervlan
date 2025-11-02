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




###############################################################################
# HELPERS
###############################################################################

ensure_custom_settings_header() {
    HEADER_LINE="$(sed -n 's/^Addon:[[:space:]]*//p;q' "${MERV_BASE}/changelog.txt")"

    # Fallback if changelog didn't parse
    [ -z "${HEADER_LINE}" ] && HEADER_LINE="mervlan v.unknown"

    if [ -f "${CUSTOM_SETTINGS_FILE}" ]; then
        CURRENT_FIRST_LINE="$(head -n1 "${CUSTOM_SETTINGS_FILE}" 2>/dev/null)"

        # Only touch the file if it's not already exactly correct
        if [ "${CURRENT_FIRST_LINE}" != "${HEADER_LINE}" ]; then

            # Case 1: file already had SOME header like "mervlan v.old"
            if echo "${CURRENT_FIRST_LINE}" | grep -q '^mervlan[[:space:]]'; then
                {
                    echo "${HEADER_LINE}"
                    tail -n +2 "${CUSTOM_SETTINGS_FILE}"
                } > "${CUSTOM_SETTINGS_FILE}.tmp" && mv "${CUSTOM_SETTINGS_FILE}.tmp" "${CUSTOM_SETTINGS_FILE}"

            # Case 2: file had no header at all (first line is vlanmgr_node1 ...)
            else
                {
                    echo "${HEADER_LINE}"
                    cat "${CUSTOM_SETTINGS_FILE}"
                } > "${CUSTOM_SETTINGS_FILE}.tmp" && mv "${CUSTOM_SETTINGS_FILE}.tmp" "${CUSTOM_SETTINGS_FILE}"
            fi

            chmod 600 "${CUSTOM_SETTINGS_FILE}"
        fi
    else
        # No file: create new with just the header
        echo "${HEADER_LINE}" > "${CUSTOM_SETTINGS_FILE}"
        chmod 600 "${CUSTOM_SETTINGS_FILE}"
    fi
}


###############################################################################
# PREP
###############################################################################

info -c vlan "save_settings.sh: start"

mkdir -p "${SETTINGSDIR}" || {
    error -c vlan "save_settings.sh: ERROR can't mkdir ${SETTINGSDIR}"
    exit 1
}

mkdir -p "${RESULTDIR}" || {
    error -c vlan "save_settings.sh: ERROR can't mkdir ${RESULTDIR}"
    exit 1
}

TMP_KV="${RESULTDIR}/vlanmgr_kv.$$"
TMP_SORTED="${RESULTDIR}/vlanmgr_sorted.$$"
TMP_JSON="${RESULTDIR}/vlanmgr_json.$$"

> "${TMP_KV}"
> "${TMP_SORTED}"
> "${TMP_JSON}"

ensure_custom_settings_header

if [ ! -f "${CUSTOM_SETTINGS_FILE}" ]; then
    error -c vlan "save_settings.sh: ${CUSTOM_SETTINGS_FILE} not found even after ensure_custom_settings_header, abort"
    exit 1
fi

###############################################################################
# STEP 1: pull vlanmgr_* lines into key<tab>val (without the vlanmgr_ prefix)
###############################################################################

while IFS= read -r LINE; do
    case "${LINE}" in
        vlanmgr_*)
            KEY="${LINE%% *}"
            VAL="${LINE#* }"
            if [ "${VAL}" = "${KEY}" ]; then
                VAL=""
            fi

            SHORT_KEY="${KEY#vlanmgr_}"

            printf '%s\t%s\n' "${SHORT_KEY}" "${VAL}" >> "${TMP_KV}"
        ;;
    esac
done < "${CUSTOM_SETTINGS_FILE}"

###############################################################################
# STEP 2: sort keys alpha
###############################################################################

sort -k1,1 "${TMP_KV}" > "${TMP_SORTED}"

###############################################################################
# STEP 3: build pretty JSON
###############################################################################

echo "{" > "${TMP_JSON}"

LINECOUNT=$(wc -l < "${TMP_SORTED}")
COUNT=0

while IFS=$'\t' read -r OUTKEY OUTVAL; do
    COUNT=$((COUNT + 1))

    ESCAPED_VAL=$(echo "${OUTVAL}" | sed 's/\\/\\\\/g; s/"/\\"/g')

    if [ "${COUNT}" -lt "${LINECOUNT}" ]; then
        printf '  "%s": "%s",\n' "${OUTKEY}" "${ESCAPED_VAL}" >> "${TMP_JSON}"
    else
        printf '  "%s": "%s"\n' "${OUTKEY}" "${ESCAPED_VAL}" >> "${TMP_JSON}"
    fi
done < "${TMP_SORTED}"

echo "}" >> "${TMP_JSON}"

###############################################################################
# STEP 4: install persistent copy
###############################################################################

cp "${TMP_JSON}" "${SETTINGS_FILE}"
chmod 600 "${SETTINGS_FILE}"
info -c vlan "save_settings.sh: wrote ${SETTINGS_FILE}"

###############################################################################
# STEP 5: install public (UI-fetchable) copy
#
# We want:
#   <PUBLIC_MERV_BASE>/settings/settings.json
# so the iframe can fetch "settings/settings.json".
###############################################################################

if [ -n "${PUBLIC_MERV_BASE}" ]; then
    if mkdir -p "${PUBLIC_SETTINGS_DIR}" 2>/dev/null; then
        cp "${TMP_JSON}" "${PUBLIC_SETTINGS_FILE}"
        chmod 644 "${PUBLIC_SETTINGS_FILE}"
        info -c vlan,cli "Settings saved!"
    else
        warn -c vlan "save_settings.sh: WARN can't mkdir ${PUBLIC_SETTINGS_DIR}"
    fi
else
    error -c vlan "save_settings.sh: WARN no public base dir available, skipping web copy"
fi

###############################################################################
# CLEANUP
###############################################################################

rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}"

exit 0
