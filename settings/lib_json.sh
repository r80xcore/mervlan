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
#                - File: lib_json.sh || version="0.49"                         #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Provide shared JSON helpers for MerVLAN settings files.        #
#               Only touch values, never key names or other structure.         #
# ──────────────────────────────────────────────────────────────────────────── #

[ -n "${LIB_JSON_LOADED:-}" ] && return 0 2>/dev/null

: "${MERV_BASE:=/jffs/addons/mervlan}"
: "${SETTINGSDIR:=$MERV_BASE/settings}"
[ -n "${SETTINGS_FILE:-}" ] || SETTINGS_FILE="$MERV_BASE/settings/settings.json"

ensure_json_store() {
    # ensure_json_store [file] [defaults]
    # Create the containing directory and seed the JSON file if missing/empty.
    local file="${1:-$SETTINGS_FILE}" defaults="${2:-}" dir

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

json_escape_string() {
    # json_escape_string <value>
    # Emit the input with JSON string-appropriate escaping for quotes and backslashes.
    # Caller captures stdout; no trailing newline is emitted.
    local value="$1"
    printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

json_set_flag() {
    # json_set_flag <key> <value> [file] [defaults]
    # Only change the value of "key": "value".
    # If key exists: in-place sed replacement of the value.
    # If key does not exist: append a new row before the closing '}'.
    local key="$1"
    local value="$2"
    local file="${3:-$SETTINGS_FILE}"
    local defaults="${4:-}"
    local json_value sed_value script tmp

    [ -n "$key" ] || return 1

    ensure_json_store "$file" "$defaults" || return 1

    json_value=$(json_escape_string "$value")
    sed_value=$(printf '%s' "$json_value" | sed 's/\\/\\\\/g; s/&/\\&/g')

    if grep -q "\"$key\""[[:space:]]*: "$file" 2>/dev/null; then
        script="${file}.sed.$$"
        printf 's/"%s"[[:space:]]*:[[:space:]]*"[^"]*"/"%s": "%s"/\n' "$key" "$key" "$sed_value" > "$script" || {
            rm -f "$script"
            return 1
        }
        if ! sed -i -f "$script" "$file" 2>/dev/null; then
            rm -f "$script"
            return 1
        fi
        rm -f "$script"
        return 0
    fi

    if grep -q '"[^"]\+"' "$file" 2>/dev/null; then
        tmp="${file}.tmp.$$"
        JSON_SET_FLAG_VALUE="$json_value" \
        awk -v key="$key" '
            BEGIN {
                value = ENVIRON["JSON_SET_FLAG_VALUE"]
                last_prop = -1
            }
            {
                lines[NR] = $0
                if ($0 ~ /"[^"]+"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*(,)?[[:space:]]*$/) {
                    last_prop = NR
                }
            }
            END {
                if (last_prop == -1) {
                    printf "{\n  \"%s\": \"%s\"\n}\n", key, value
                    exit
                }

                for (i = 1; i < last_prop; i++) {
                    print lines[i]
                }

                line = lines[last_prop]
                sub(/[[:space:]]*$/, "", line)
                if (line !~ /,$/) {
                    line = line ","
                }
                print line

                printf "  \"%s\": \"%s\"\n", key, value

                for (i = last_prop + 1; i <= NR; i++) {
                    print lines[i]
                }
            }
        ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

        mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
        return 0
    fi

    printf '{\n  "%s": "%s"\n}\n' "$key" "$json_value" > "$file" || return 1
    return 0
}

json_get_flag() {
    # json_get_flag <key> [default] [file]
    local key="$1"
    local default_value="${2:-}"
    local file="${3:-$SETTINGS_FILE}"

    [ -n "$key" ] || { printf '%s\n' "$default_value"; return 1; }

    if [ ! -s "$file" ]; then
        printf '%s\n' "$default_value"
        return 0
    fi

    # Extract "VALUE" from a line like:  "KEY": "VALUE",
    # - ignores leading spaces
    # - allows spaces around colon
    # - ignores trailing comma and spaces
    local value
    value="$(sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\\1/p" "$file")"

    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$default_value"
    fi
}



json_get_int() {
    # json_get_int <key> <default> [file]
    # Returns: sanitized integer or <default> if missing/invalid.
    local key="$1"
    local default_value="$2"
    local file="${3:-$SETTINGS_FILE}"
    local raw num

    # Reuse json_get_flag to extract the raw string
    raw="$(json_get_flag "$key" "$default_value" "$file")"

    # Strip whitespace and quotes (handles "1", " 1 ", etc.)
    num="$(printf '%s' "$raw" | tr -d '[:space:]"')"

    case "$num" in
        ''|*[!0-9]*)
            printf '%s\n' "$default_value"
            return 1
            ;;
        *)
            printf '%s\n' "$num"
            return 0
            ;;
    esac
}


json_ensure_flag() {
    # json_ensure_flag <key> <default> [file]
    local key="$1"
    local default_value="$2"
    local file="${3:-$SETTINGS_FILE}"

    if [ "$(json_get_flag "$key" "__MISSING__" "$file")" != "__MISSING__" ]; then
        return 0
    fi

    json_set_flag "$key" "$default_value" "$file"
}

json_apply_kv_file() {
    # json_apply_kv_file <kv_file> [json_file] [defaults]
    # Merge key\tvalue lines into the target JSON file without disturbing other keys.
    local kv_file="$1"
    local file="${2:-$SETTINGS_FILE}"
    local defaults="${3:-}"

    [ -n "$kv_file" ] || return 0
    [ -f "$kv_file" ] || return 0

    ensure_json_store "$file" "$defaults" || return 1

    # shellcheck disable=SC2162
    while IFS="$(printf '\t')" read -r key value || [ -n "$key" ]; do
        [ -n "$key" ] || continue
        json_set_flag "$key" "${value:-}" "$file" "$defaults" || return 1
    done < "$kv_file"

    return 0
}

json_escape_key() {
    # json_escape_key <key>
    # Escape special regex characters in a JSON key so it can be used safely
    # inside sed/awk patterns.
    printf '%s' "$1" | sed 's/[][\\.^$*]/\\&/g'
}


json_get_scalar() {
    # json_get_scalar <key> <file>
    # Read a scalar value for "KEY" from a JSON file. Handles quoted
    # strings and bare numeric/boolean tokens and trims whitespace.
    local key="$1" file="$2" key_re
    [ -n "$key" ] || return 1
    [ -f "$file" ] || return 1

    key_re=$(json_escape_key "$key")

    # 1) Try quoted string
    sed -n "s/.*\"$key_re\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' && return 0

    # 2) Fallback to unquoted token (numbers, true, false, null)
    sed -n "s/.*\"$key_re\"[[:space:]]*:[[:space:]]*\([^,}[:space:]]*\).*/\1/p" "$file" | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}


json_get_section_value() {
    # json_get_section_value <section> <key> <file>
    # Extract string value from a nested JSON object: "Section": { "KEY": "VALUE" }
    local section="$1" key="$2" file="$3"
    [ -n "$section" ] || return 1
    [ -n "$key" ] || return 1
    [ -f "$file" ] || return 1

    awk -v sec="$section" -v key="$key" '
        BEGIN { in_section=0; depth=0 }
            {
                if (!in_section) {
                    if ($0 ~ ("\""sec"\"[[:space:]]*:[[:space:]]*{")) {
                        in_section=1
                        gsub(/[^{}]/, "", $0)
                        depth += gsub(/\{/, "&") - gsub(/\}/, "&")
                    }
                } else {
                    gsub(/[^{}]/, "", $0); depth += gsub(/\{/, "&") - gsub(/\}/, "&");
                    if ($0 ~ ("\""key"\"[[:space:]]*:[[:space:]]*\"")) {
                        if (match($0, "\""key"\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"", arr)) { print arr[1]; exit }
                    }
                    if (depth <= 0) exit
                }
            }
    ' "$file" | head -1
}


json_get_section_int() {
    # json_get_section_int <section> <key> <file>
    # Returns digits-only numeric extraction from a nested section value.
    local val
    val=$(json_get_section_value "$1" "$2" "$3") || return 1
    echo "$val" | grep -o '^[0-9]\+' || :
}


json_get_array() {
    # json_get_array <key> <file>
    # Extract a top-level JSON array and return elements as space-separated list
    local key="$1" file="$2"
    [ -n "$key" ] || return 1
    [ -f "$file" ] || return 1

    awk -v key="$key" '
        BEGIN { in_section=0; content="" }
        {
            if (!in_section) {
                # Look for the key and then ensure the line actually contains an array start
                if ($0 ~ ("\""key"\"[[:space:]]*:[[:space:]]*")) {
                    if (index($0, "[") == 0) {
                        next
                    }
                    in_section=1
                    sub(/.*\[/, "")
                    content = $0
                    if (index(content, "]") > 0) {
                        sub(/\].*/, "", content)
                        print content
                        exit
                    }
                    next
                }
            } else {
                if (index($0, "]") > 0) {
                    sub(/\].*/, "", $0)
                    content = content " " $0
                    print content
                    exit
                }
                content = content " " $0
            }
        }
    ' "$file" | head -1 | sed 's/[[:space:]]//g; s/"//g; s/,/ /g'
}


json_get_section_array() {
    # json_get_section_array <section> <key> <file>
    # Extract a nested array Section.KEY as space-separated list (quotes removed)
    local section="$1" key="$2" file="$3"
    [ -n "$section" ] || return 1
    [ -n "$key" ] || return 1
    [ -f "$file" ] || return 1

    awk -v sec="$section" -v key="$key" '
        BEGIN { in_section=0; depth=0 }
        {
            if (!in_section) {
                # Look for the section start and begin tracking brace depth
                if ($0 ~ ("\""sec"\"[[:space:]]*:[[:space:]]*{")) {
                    in_section=1
                    tmp=$0
                    gsub(/[^{}]/, "", tmp)
                    depth += gsub(/\{/, "&", tmp) - gsub(/\}/, "&", tmp)
                }
            } else {
                line=$0
                # Use tmp copy for brace 
                tmp=line
                gsub(/[^{}]/, "", tmp)
                depth += gsub(/\{/, "&", tmp) - gsub(/\}/, "&", tmp)

                # Search the original line for the key and then ensure the array start is present
                if (line ~ ("\""key"\"[[:space:]]*:[[:space:]]*")) {
                    if (index(line, "[") == 0) {
                        if (depth <= 0) exit
                        next
                    }

                    sub(/.*\[/, "", line)
                    content = line
                    if (index(content, "]") > 0) {
                        sub(/\].*/, "", content)
                        print content
                        exit
                    }
                    # Continue reading subsequent lines until the closing bracket
                    while (getline) {
                        line=$0
                        if (index(line, "]") > 0) {
                            sub(/\].*/, "", line)
                            content = content " " line
                            print content
                            exit
                        }
                        content = content " " line
                    }
                }

                if (depth <= 0) exit
            }
        }
    ' "$file" | head -1 | sed 's/[[:space:]]//g; s/"//g; s/,/ /g'
}

_json_build_array_literal() {
    # _json_build_array_literal <items...>
    # Emit a JSON array literal ["a","b",...] with proper escaping.
    local first=1 out="[" v esc
    for v in "$@"; do
        esc=$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if [ "$first" -eq 1 ]; then
            out="$out\"$esc\""
            first=0
        else
            out="$out, \"$esc\""
        fi
    done
    out="$out]"
    printf '%s' "$out"
}


json_set_array() {
    # json_set_array <key> <space-separated-values> [file] [defaults]
    # Write "KEY": [ "v1", "v2", ... ] non-destructively.
    local key="$1"
    local vals="$2"
    local file="${3:-$SETTINGS_FILE}"
    local defaults="${4:-}"
    local array_json script tmp

    [ -n "$key" ] || return 1

    ensure_json_store "$file" "$defaults" || return 1

    # Build array literal from whitespace-separated values.
    # shellcheck disable=SC2086
    array_json=$(_json_build_array_literal $vals)

    # If key exists in any form (string/number/array/object), replace its value
    if grep -q "\"$key\"" "$file" 2>/dev/null; then
        script="${file}.sed.$$"
        # Replace any value after the colon for this key (covers arrays, strings, numbers)
        # Pattern matches: [ ... ] or "..." or unquoted token until comma or closing brace
        printf 's@"%s"[[:space:]]*:[[:space:]]*\(\[[^]]*\]\|"[^"]*"\|[^,}]*\)@"%s": %s@g\n' "$key" "$key" "$array_json" >"$script" || { rm -f "$script"; return 1; }
        if ! sed -i -f "$script" "$file" 2>/dev/null; then
            rm -f "$script"
            return 1
        fi
        rm -f "$script"
        return 0
    fi

    # Fallback: append a new "key": [ ... ] property near the end of the file.
    tmp="${file}.tmp.$$"
    awk -v k="$key" -v v="$array_json" '
        BEGIN { inserted = 0 }
        /\}/ {
            if (!inserted) {
                print "  \"" k "\": " v
                inserted = 1
            }
        }
        { print }
    ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }

    mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

LIB_JSON_LOADED=1