#!/bin/sh
#
# save_settings.sh
#
# 1. Read vlanmgr_* keys from /jffs/addons/custom_settings.txt
# 2. Build sorted JSON
# 3. Write:
#    - persistent copy in JFFS
#    - public copy alongside the web UI so the iframe JS can fetch it
#

###############################################################################
# CONFIG
###############################################################################

ADDON_BASE="/jffs/addons/mervlan"
CUSTOM_SETTINGS_FILE="/jffs/addons/custom_settings.txt"

# persistent (always exists on JFFS)
SETTINGS_DIR="${ADDON_BASE}/settings"
SETTINGS_JSON="${SETTINGS_DIR}/settings.json"

# where the UI is served from (first existing wins)
PUBLIC_CANDIDATES="
/www/user/mervlan
/tmp/var/wwwext/mervlan
"

RESULT_DIR="/tmp/mervlan/results"

###############################################################################
# HELPERS
###############################################################################

ensure_custom_settings_header() {
    HEADER_LINE="$(sed -n 's/^Addon:[[:space:]]*//p;q' "${ADDON_BASE}/changelog.txt")"

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


pick_public_base() {
    for CAND in ${PUBLIC_CANDIDATES}; do
        [ -z "$CAND" ] && continue
        if [ -d "$CAND" ] || mkdir -p "$CAND" 2>/dev/null; then
            echo "$CAND"
            return 0
        fi
    done
    return 1
}

###############################################################################
# PREP
###############################################################################

logger -t "VLANMgr" "save_settings.sh: start"

mkdir -p "${SETTINGS_DIR}" || {
    logger -t "VLANMgr" "save_settings.sh: ERROR can't mkdir ${SETTINGS_DIR}"
    exit 1
}

mkdir -p "${RESULT_DIR}" || {
    logger -t "VLANMgr" "save_settings.sh: ERROR can't mkdir ${RESULT_DIR}"
    exit 1
}

TMP_KV="${RESULT_DIR}/vlanmgr_kv.$$"
TMP_SORTED="${RESULT_DIR}/vlanmgr_sorted.$$"
TMP_JSON="${RESULT_DIR}/vlanmgr_json.$$"

> "${TMP_KV}"
> "${TMP_SORTED}"
> "${TMP_JSON}"

ensure_custom_settings_header

if [ ! -f "${CUSTOM_SETTINGS_FILE}" ]; then
    logger -t "VLANMgr" "save_settings.sh: ${CUSTOM_SETTINGS_FILE} not found even after ensure_custom_settings_header, abort"
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

cp "${TMP_JSON}" "${SETTINGS_JSON}"
chmod 600 "${SETTINGS_JSON}"
logger -t "VLANMgr" "save_settings.sh: wrote ${SETTINGS_JSON}"

###############################################################################
# STEP 5: install public (UI-fetchable) copy
#
# We want:
#   <PUBLIC_BASE>/settings/settings.json
# so the iframe can fetch "settings/settings.json".
###############################################################################

PUBLIC_BASE="$(pick_public_base)"
if [ -n "${PUBLIC_BASE}" ]; then
    PUBLIC_SETTINGS_DIR="${PUBLIC_BASE}/settings"
    PUBLIC_JSON="${PUBLIC_SETTINGS_DIR}/settings.json"

    if mkdir -p "${PUBLIC_SETTINGS_DIR}" 2>/dev/null; then
        cp "${TMP_JSON}" "${PUBLIC_JSON}"
        chmod 644 "${PUBLIC_JSON}"
        logger -t "VLANMgr" "save_settings.sh: mirrored to ${PUBLIC_JSON}"
    else
        logger -t "VLANMgr" "save_settings.sh: WARN can't mkdir ${PUBLIC_SETTINGS_DIR}"
    fi
else
    logger -t "VLANMgr" "save_settings.sh: WARN no public base dir available, skipping web copy"
fi

###############################################################################
# CLEANUP
###############################################################################

rm -f "${TMP_KV}" "${TMP_SORTED}" "${TMP_JSON}"

exit 0
