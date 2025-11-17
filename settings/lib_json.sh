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
#                - File: lib_json.sh || version="0.47"                         #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Provide shared JSON helpers for MerVLAN settings files.        #
#               Only touch values, never key names or other structure.         #
# ──────────────────────────────────────────────────────────────────────────── #

[ -n "${LIB_JSON_LOADED:-}" ] && return 0 2>/dev/null

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${SETTINGSDIR:=$MERV_BASE/settings}"
: "${GENERAL_SETTINGS_FILE:=$SETTINGSDIR/general.json}"

# Default template for the general settings store; keeps initial keys portable.
DEFAULT_GENERAL_SETTINGS_CONTENT='{
    "SSH_KEYS_INSTALLED": "0",
    "BOOT_ENABLED": "0",
    "NODE_SSH_PORT": "22",
    "NODE_SSH_USER": "admin"
}'

ensure_json_store() {
    # ensure_json_store [file] [defaults]
    # Create the containing directory and seed the JSON file if missing/empty.
    local file="${1:-$GENERAL_SETTINGS_FILE}" defaults="${2:-}" dir

    dir=$(dirname "$file")
    mkdir -p "$dir" 2>/dev/null || return 1

    if [ ! -s "$file" ]; then
        if [ -n "$defaults" ]; then
            printf '%s\n' "$defaults" > "$file" || return 1
        else
            printf '{\n}\n' > "$file" || return 1
        fi
    fi

    return 0
}

json_set_flag() {
    # json_set_flag <key> <value> [file] [defaults]
    # Only change the value of "key": "value".
    # If key exists: in-place sed replacement of the value.
    # If key does not exist: append a new row before the closing '}'.
    local key="$1"
    local value="$2"
    local file="${3:-$GENERAL_SETTINGS_FILE}"
    local defaults="${4:-}"

    [ -n "$key" ] || return 1

    # Seed file if missing/empty
    ensure_json_store "$file" "$defaults" || return 1

    # 1) If the key already exists, replace ONLY the value portion.
    #    Pattern: "KEY" : "anything" → "KEY": "value"
    if grep -q "\"$key\""[[:space:]]*: "$file" 2>/dev/null; then
        sed -i \
            -e "s/\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"$key\": \"$value\"/" \
            "$file" || return 1
        return 0
    fi

    # 2) Key does not exist – append a new key/value row before final '}'.
    #
    # We do this in a line-oriented way:
    # - Find the last property line before the closing brace.
    # - Ensure that last property line ends with a comma.
    # - Insert new '  "KEY": "VALUE"' row before the closing brace.
    #
    # This keeps all other rows intact and avoids re-serializing the object.

    # Is there at least one existing key?
    if grep -q '"[^"]\+"' "$file" 2>/dev/null; then
        # Non-empty object: patch last property + insert new row.
        local tmp="${file}.tmp.$$"

        awk -v key="$key" -v value="$value" '
            BEGIN {
                last_prop = -1
            }
            {
                lines[NR] = $0
                # Track candidate "  \"KEY\": \"VAL\"" style rows
                if ($0 ~ /"[^\"]+"[[:space:]]*:[[:space:]]*"[^\"]*"[[:space:]]*(,)?[[:space:]]*$/) {
                    last_prop = NR
                }
            }
            END {
                if (last_prop == -1) {
                    # Fallback: weird content; rewrite minimal but valid object
                    printf "{\n  \"%s\": \"%s\"\n}\n", key, value
                    exit
                }

                # Print all rows up to the last property-1 unchanged
                for (i = 1; i < last_prop; i++) {
                    print lines[i]
                }

                # Ensure last property has a trailing comma
                line = lines[last_prop]
                sub(/[[:space:]]*$/, "", line)
                if (line !~ /,$/) {
                    line = line ","
                }
                print line

                # Insert new property row
                printf "  \"%s\": \"%s\"\n", key, value

                # Print the remaining rows (typically the closing brace)
                for (i = last_prop + 1; i <= NR; i++) {
                    print lines[i]
                }
            }
        ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

        mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
        return 0
    fi

    # 3) Object is effectively empty: replace content with a minimal object.
    printf '{\n  "%s": "%s"\n}\n' "$key" "$value" > "$file" || return 1
    return 0
}

json_get_flag() {
    # json_get_flag <key> [default] [file]
    local key="$1"
    local default_value="${2:-}"
    local file="${3:-$GENERAL_SETTINGS_FILE}"

    [ -n "$key" ] || { printf '%s\n' "$default_value"; return 1; }

    if [ ! -s "$file" ]; then
        printf '%s\n' "$default_value"
        return 0
    fi

    awk -v target="$key" -v fallback="$default_value" '
        BEGIN { found = 0 }
        {
            line = $0
            # Scan all "KEY": "VAL" pairs on each row
            while (match(line, /"([^\"]+)"[[:space:]]*:[[:space:]]*"([^\"]*)"/, m)) {
                if (m[1] == target) {
                    print m[2]
                    found = 1
                    exit
                }
                line = substr(line, RSTART + RLENGTH)
            }
        }
        END {
            if (!found) {
                print fallback
            }
        }
    ' "$file"
}

json_ensure_flag() {
    # json_ensure_flag <key> <default> [file]
    local key="$1"
    local default_value="$2"
    local file="${3:-$GENERAL_SETTINGS_FILE}"

    # If key already exists, do nothing.
    if [ "$(json_get_flag "$key" "__MISSING__" "$file")" != "__MISSING__" ]; then
        return 0
    fi

    json_set_flag "$key" "$default_value" "$file"
}

LIB_JSON_LOADED=1
