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
#                - File: lib_json.sh || version="0.55"                         #
# ============================================================================ #
# - Purpose:    Provide shared JSON helpers for MerVLAN settings files.        #
#               Only touch values, never key names or other structure.         #
# ============================================================================ #

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
            line = $0
            if (!in_section) {
                if (line ~ ("\""sec"\"[[:space:]]*:[[:space:]]*\\{")) {
                    in_section=1
                    t = line; gsub(/[^{}]/, "", t)
                    depth += gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
                }
            } else {
                # Update depth using temp variable (preserve original line)
                t = line; gsub(/[^{}]/, "", t)
                depth += gsub(/\{/, "&", t) - gsub(/\}/, "&", t)

                # Match the key and extract value using dynamic pattern
                key_pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
                if (line ~ key_pattern) {
                    # Build dynamic sub patterns (variables not interpolated in /regex/)
                    sub_pattern = ".*\"" key "\"[[:space:]]*:[[:space:]]*\""
                    sub(sub_pattern, "", line)
                    sub(/".*/, "", line)
                    print line
                    exit
                }
                if (depth <= 0) exit
            }
        }
    ' "$file" | head -1
}


json_set_section_value() {
    # json_set_section_value <section> <key> <value> [file]
    # Update or insert a key inside a one-level nested section (upsert behavior).
    section="$1"
    key="$2"
    value="$3"
    file="${4:-$SETTINGS_FILE}"
    tmp="${file}.tmp.$$"
    esc_value=""

    [ -n "$section" ] || return 1
    [ -n "$key" ] || return 1
    ensure_json_store "$file" || return 1

    esc_value=$(json_escape_string "$value")

    awk -v sec="$section" -v key="$key" -v val="$esc_value" '
        function count_braces(s,   t){
            t=s
            gsub(/[^{}]/, "", t)
            return gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
        }
        BEGIN { in_sec=0; depth=0; sec_depth=0; replaced=0; pending_line=""; has_content=0 }
        {
            line=$0

            if (!in_sec && line ~ ("\""sec"\"[[:space:]]*:[[:space:]]*\\{")) {
                in_sec=1
                sec_depth=depth + count_braces(line)
                print line
                depth = depth + count_braces(line)
                next
            }

            if (in_sec && !replaced) {
                # Match string values: "KEY": "VALUE"
                if (line ~ ("\""key"\"[[:space:]]*:[[:space:]]*\"")) {
                    gsub("\""key"\"[[:space:]]*:[[:space:]]*\"[^\"]*\"", "\""key"\": \""val"\"", line)
                    replaced=1
                }
                # Also match numeric values: "KEY": 123
                else if (line ~ ("\""key"\"[[:space:]]*:[[:space:]]*[0-9]")) {
                    gsub("\""key"\"[[:space:]]*:[[:space:]]*[0-9]+", "\""key"\": \""val"\"", line)
                    replaced=1
                }
            }

            # Detect section closing: depth drops below sec_depth
            new_depth = depth + count_braces(line)
            if (in_sec && new_depth < sec_depth) {
                # Insert key before the closing brace if not replaced
                if (!replaced) {
                    # Print pending line with comma added if it has content
                    if (pending_line != "") {
                        # Add comma if the pending line doesnt already end with one
                        if (pending_line !~ /,[[:space:]]*$/) {
                            sub(/[[:space:]]*$/, ",", pending_line)
                        }
                        print pending_line
                    }
                    # Insert new key-value (no trailing comma as its the last entry)
                    printf "    \"%s\": \"%s\"\n", key, val
                    replaced=1
                    pending_line=""
                } else if (pending_line != "") {
                    print pending_line
                    pending_line=""
                }
                in_sec=0
                print line
                depth = new_depth
                next
            }

            # Buffer lines within section to handle comma insertion
            if (in_sec) {
                if (pending_line != "") {
                    print pending_line
                }
                # Track if this line has actual key-value content
                if (line ~ /"[^"]+":/) {
                    has_content=1
                }
                pending_line=line
            } else {
                if (pending_line != "") {
                    print pending_line
                    pending_line=""
                }
                print line
            }

            depth = new_depth
        }
        END {
            if (pending_line != "") print pending_line
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}


json_get_section_int() {
    # json_get_section_int <section> <key> <file>
    # Returns digits-only numeric extraction from a nested section value.
    local val
    val=$(json_get_section_value "$1" "$2" "$3") || return 1
    echo "$val" | grep -o '^[0-9]\+' || :
}


json_get_section2_value() {
    # json_get_section2_value <section1> <section2> <key> <file>
    # Extract string value from a 2-level nested object: "Section1": { "Section2": { "KEY": "VALUE" } }
    local section1="$1" section2="$2" key="$3" file="$4"
    [ -n "$section1" ] || return 1
    [ -n "$section2" ] || return 1
    [ -n "$key" ] || return 1
    [ -f "$file" ] || return 1

    awk -v sec1="$section1" -v sec2="$section2" -v key="$key" '
        BEGIN { in1=0; in2=0; depth1=0; depth2=0 }
        {
            line=$0
            if (!in1) {
                if (line ~ ("\""sec1"\"[[:space:]]*:[[:space:]]*{")) {
                    in1=1
                    tmp=line
                    gsub(/[^{}]/, "", tmp)
                    depth1 += gsub(/\{/, "&", tmp) - gsub(/\}/, "&", tmp)
                }
                next
            }

            if (in1 && !in2) {
                tmp=line
                gsub(/[^{}]/, "", tmp)
                depth1 += gsub(/\{/, "&", tmp) - gsub(/\}/, "&", tmp)

                if (line ~ ("\""sec2"\"[[:space:]]*:[[:space:]]*{")) {
                    in2=1
                    tmp2=line
                    gsub(/[^{}]/, "", tmp2)
                    depth2 += gsub(/\{/, "&", tmp2) - gsub(/\}/, "&", tmp2)
                }

                if (depth1 <= 0) exit
                next
            }

            if (in2) {
                tmp=line
                gsub(/[^{}]/, "", tmp)
                depth2 += gsub(/\{/, "&", tmp) - gsub(/\}/, "&", tmp)

                if (line ~ ("\""key"\"[[:space:]]*:[[:space:]]*\"")) {
                    # BusyBox awk implements the POSIX two-argument match()
                    # form but not the gawk third capture-array argument. Keep
                    # the match portable, then strip the JSON key/punctuation
                    # from the matched token using POSIX substr()/sub().
                    if (match(line, "\""key"\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) {
                        value=substr(line, RSTART, RLENGTH)
                        sub(/^[^:]*:[[:space:]]*"/, "", value)
                        sub(/"[[:space:]]*$/, "", value)
                        print value
                        exit
                    }
                }

                if (depth2 <= 0) exit
            }
        }
    ' "$file" | head -1
}


json_set_section2_value() {
    # json_set_section2_value <section1> <section2> <key> <value> [file]
    # Update a key inside a two-level nested section without touching other keys.
    section1="$1"
    section2="$2"
    key="$3"
    value="$4"
    file="${5:-$SETTINGS_FILE}"
    tmp="${file}.tmp.$$"
    esc_value=""

    [ -n "$section1" ] || return 1
    [ -n "$section2" ] || return 1
    [ -n "$key" ] || return 1
    ensure_json_store "$file" || return 1

    esc_value=$(json_escape_string "$value")

    awk -v sec1="$section1" -v sec2="$section2" -v key="$key" -v val="$esc_value" '
        function count_braces(s,   t){
            t=s
            gsub(/[^{}]/, "", t)
            return gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
        }
        BEGIN { in1=0; in2=0; depth=0; depth1=0; depth2=0; replaced=0 }
        {
            line=$0

            if (!in1 && line ~ ("\""sec1"\"[[:space:]]*:[[:space:]]*\{")) {
                in1=1
                depth1=depth + count_braces(line)
            }

            if (in1 && !in2 && line ~ ("\""sec2"\"[[:space:]]*:[[:space:]]*\{")) {
                in2=1
                depth2=depth + count_braces(line)
            }

            if (in2 && !replaced) {
                if (line ~ ("\""key"\"[[:space:]]*:[[:space:]]*\"")) {
                    gsub("\""key"\"[[:space:]]*:[[:space:]]*\"[^\"]*\"", "\""key"\": \""val"\"", line)
                    replaced=1
                }
            }

            print line

            depth += count_braces($0)
            if (in2 && depth < depth2) {
                in2=0
            }
            if (in1 && depth < depth1) {
                in1=0
            }
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}


json_get_section2_int() {
    # json_get_section2_int <section1> <section2> <key> <file>
    # Returns digits-only numeric extraction from a 2-level nested section value.
    local val
    val=$(json_get_section2_value "$1" "$2" "$3" "$4") || return 1
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


# ============================================================================ #
#                      HARDWARE SECTION EXTRACTION                             #
# Extract and inject the Hardware section for node sync (preserve node HW)     #
# ============================================================================ #

# json_extract_hardware_section — Extract the entire "Hardware": {...} block
# Args: $1=json_file
# Outputs: The Hardware section JSON block (including "Hardware": { ... })
# Returns: 0 on success, 1 if not found
json_extract_hardware_section() {
    _jeh_file="$1"
    [ -f "$_jeh_file" ] || return 1

    awk '
        BEGIN { in_hw=0; depth=0; hw_depth=0; started=0 }
        {
            line = $0

            # Detect start of Hardware section
            if (!in_hw && line ~ /"Hardware"[[:space:]]*:[[:space:]]*\{/) {
                in_hw = 1
                started = 1
                # Count braces on this line
                t = line; gsub(/[^{}]/, "", t)
                hw_depth = gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
                depth = hw_depth
                print line
                next
            }

            if (in_hw) {
                print line
                # Update depth
                t = line; gsub(/[^{}]/, "", t)
                depth += gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
                # Exit when depth returns to 0
                if (depth <= 0) {
                    exit 0
                }
            }
        }
        END { if (!started) exit 1 }
    ' "$_jeh_file"
}

# json_replace_hardware_section — Replace Hardware section in target with source's
# Args: $1=source_file (with Hardware to keep), $2=target_file (to update)
# Returns: 0 on success, 1 on failure
json_replace_hardware_section() {
    _jrh_src="$1"
    _jrh_tgt="$2"
    _jrh_tmp="${_jrh_tgt}.hw_merge.$$"

    [ -f "$_jrh_src" ] || return 1
    [ -f "$_jrh_tgt" ] || return 1

    # Extract Hardware section from source
    _jrh_hw_block=$(json_extract_hardware_section "$_jrh_src") || return 1
    [ -n "$_jrh_hw_block" ] || return 1

    # Replace Hardware section in target
    awk -v hw_block="$_jrh_hw_block" '
        BEGIN { in_hw=0; depth=0; hw_depth=0; printed_hw=0 }
        {
            line = $0

            # Detect start of Hardware section in target
            if (!in_hw && line ~ /"Hardware"[[:space:]]*:[[:space:]]*\{/) {
                in_hw = 1
                t = line; gsub(/[^{}]/, "", t)
                hw_depth = gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
                depth = hw_depth
                # Print the new Hardware block instead
                if (!printed_hw) {
                    print hw_block
                    printed_hw = 1
                }
                next
            }

            if (in_hw) {
                # Update depth
                t = line; gsub(/[^{}]/, "", t)
                depth += gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
                # Skip lines until we exit Hardware section
                if (depth <= 0) {
                    in_hw = 0
                }
                next
            }

            # Print all non-Hardware lines
            print line
        }
    ' "$_jrh_tgt" > "$_jrh_tmp" || { rm -f "$_jrh_tmp"; return 1; }

    mv "$_jrh_tmp" "$_jrh_tgt" 2>/dev/null || { rm -f "$_jrh_tmp"; return 1; }
    return 0
}

# ============================================================================ #
# json_get_hw_value — Get a value from the Hardware section                    #
# Args: $1=key, $2=default, $3=file (optional, defaults to SETTINGS_FILE)      #
# Outputs: The value if found, otherwise the default                           #
# ============================================================================ #
json_get_hw_value() {
    _jghv_key="$1"
    _jghv_default="${2:-}"
    _jghv_file="${3:-$SETTINGS_FILE}"

    [ -n "$_jghv_key" ] || { printf '%s\n' "$_jghv_default"; return 1; }
    [ -f "$_jghv_file" ] || { printf '%s\n' "$_jghv_default"; return 1; }

    # Extract Hardware section, then parse the key within it
    _jghv_hw_block=$(json_extract_hardware_section "$_jghv_file" 2>/dev/null)
    if [ -z "$_jghv_hw_block" ]; then
        printf '%s\n' "$_jghv_default"
        return 1
    fi

    # Parse the key from within the Hardware block
    _jghv_value=$(printf '%s\n' "$_jghv_hw_block" | \
        sed -n "s/^[[:space:]]*\"$_jghv_key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\"[[:space:]]*,\\{0,1\\}[[:space:]]*$/\\1/p")

    if [ -n "$_jghv_value" ]; then
        printf '%s\n' "$_jghv_value"
    else
        printf '%s\n' "$_jghv_default"
    fi
}

# json_get_hw_int — Get an integer value from the Hardware section
# Args: $1=key, $2=default, $3=file (optional)
# Outputs: The sanitized integer or default
json_get_hw_int() {
    _jghi_key="$1"
    _jghi_default="$2"
    _jghi_file="${3:-$SETTINGS_FILE}"

    _jghi_raw=$(json_get_hw_value "$_jghi_key" "$_jghi_default" "$_jghi_file")

    # Strip whitespace and quotes
    _jghi_num=$(printf '%s' "$_jghi_raw" | tr -d '[:space:]"')

    case "$_jghi_num" in
        ''|*[!0-9]*)
            printf '%s\n' "$_jghi_default"
            return 1
            ;;
        *)
            printf '%s\n' "$_jghi_num"
            return 0
            ;;
    esac
}

# ============================================================================ #
# json_reset_trunks_section — Reset Trunks to default values for nodes        #
# Args: $1=file to modify                                                      #
# Returns: 0 on success, 1 on failure                                          #
# Purpose: Prevents trunk configurations from being applied on nodes.          #
#          Only the main router should have trunk capability.                  #
# ============================================================================ #
json_reset_trunks_section() {
    _jrt_file="$1"
    _jrt_tmp="${_jrt_file}.trunk_reset.$$"

    [ -f "$_jrt_file" ] || return 1

    # Generate default Trunks section
    _jrt_default_trunks='    "Trunks": {
      "_description": "Per-port trunk enable plus tagged/untagged membership",
      "TRUNK1": "0",
      "TRUNK2": "0",
      "TRUNK3": "0",
      "TRUNK4": "0",
      "TRUNK5": "0",
      "TRUNK6": "0",
      "TRUNK7": "0",
      "TRUNK8": "0",

      "TAGGED_TRUNK1": "none",
      "TAGGED_TRUNK2": "none",
      "TAGGED_TRUNK3": "none",
      "TAGGED_TRUNK4": "none",
      "TAGGED_TRUNK5": "none",
      "TAGGED_TRUNK6": "none",
      "TAGGED_TRUNK7": "none",
      "TAGGED_TRUNK8": "none",

      "UNTAGGED_TRUNK1": "none",
      "UNTAGGED_TRUNK2": "none",
      "UNTAGGED_TRUNK3": "none",
      "UNTAGGED_TRUNK4": "none",
      "UNTAGGED_TRUNK5": "none",
      "UNTAGGED_TRUNK6": "none",
      "UNTAGGED_TRUNK7": "none",
      "UNTAGGED_TRUNK8": "none"
    }'

    # Replace Trunks section in file
    awk -v trunks_block="$_jrt_default_trunks" '
        BEGIN { in_trunks=0; depth=0; printed_trunks=0 }
        {
            line = $0

            # Detect start of Trunks section
            if (!in_trunks && line ~ /"Trunks"[[:space:]]*:[[:space:]]*\{/) {
                in_trunks = 1
                t = line; gsub(/[^{}]/, "", t)
                depth = gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
                # Print the default Trunks block instead
                if (!printed_trunks) {
                    print trunks_block
                    printed_trunks = 1
                }
                next
            }

            if (in_trunks) {
                # Update depth
                t = line; gsub(/[^{}]/, "", t)
                depth += gsub(/\{/, "&", t) - gsub(/\}/, "&", t)
                # Skip lines until we exit Trunks section
                if (depth <= 0) {
                    in_trunks = 0
                }
                next
            }

            # Print all non-Trunks lines
            print line
        }
    ' "$_jrt_file" > "$_jrt_tmp" || { rm -f "$_jrt_tmp"; return 1; }

    mv "$_jrt_tmp" "$_jrt_file" 2>/dev/null || { rm -f "$_jrt_tmp"; return 1; }
    return 0
}

# merv_node_list : Emit "<n> <ip>" lines for every node with a valid configured
# IPv4. Self-contained: inline IPv4 validation + local MERV_MAX_NODES default so
# it works even when var_settings.sh has not been sourced. Reads the structured
# Nodes section first, then falls back to a flat top-level "NODEn" key for
# pre-structured installs. An optional settings-file argument avoids changing
# the read-only SETTINGS_FILE runtime path during staged maintenance checks.
merv_node_list() {
    _mnl_file="${1:-${SETTINGS_FILE:-}}"
    _mnl_max="${MERV_MAX_NODES:-10}"
    _mnl_i=1
    while [ "$_mnl_i" -le "$_mnl_max" ]; do
        _mnl_val=$(json_get_section_value "Nodes" "NODE${_mnl_i}" "$_mnl_file" 2>/dev/null)
        [ -n "$_mnl_val" ] || _mnl_val=$(json_get_flag "NODE${_mnl_i}" "" "$_mnl_file" 2>/dev/null)
        if [ -n "$_mnl_val" ] && [ "$_mnl_val" != "none" ]; then
            case "$_mnl_val" in
                *.*.*.*)
                    if printf '%s\n' "$_mnl_val" | awk -F. 'NF==4 { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1; exit 0 } { exit 1 }'; then
                        printf '%s %s\n' "$_mnl_i" "$_mnl_val"
                    fi
                    ;;
            esac
        fi
        _mnl_i=$((_mnl_i + 1))
    done
}

# Return a stable, labelled digest for the canonical configured-node list.
# BusyBox builds vary: some omit cksum while retaining md5sum or OpenSSL, so
# callers must not make a security decision depend on one optional applet.
merv_node_list_digest() {
    _mnld_nodes=$(merv_node_list 2>/dev/null) || return 1

    if type cksum >/dev/null 2>&1; then
        _mnld_digest=$(printf '%s\n' "$_mnld_nodes" | cksum 2>/dev/null | awk '{print $1 "." $2}')
        case "$_mnld_digest" in
            [0-9]*.[0-9]*) printf 'cksum:%s\n' "$_mnld_digest"; return 0 ;;
        esac
    fi
    if type md5sum >/dev/null 2>&1; then
        _mnld_digest=$(printf '%s\n' "$_mnld_nodes" | md5sum 2>/dev/null | awk '{print $1}')
        case "$_mnld_digest" in
            [0-9A-Fa-f][0-9A-Fa-f]*) printf 'md5:%s\n' "$_mnld_digest"; return 0 ;;
        esac
    fi
    if type openssl >/dev/null 2>&1; then
        _mnld_digest=$(printf '%s\n' "$_mnld_nodes" | openssl dgst -md5 2>/dev/null | awk '{print $NF}')
        case "$_mnld_digest" in
            [0-9A-Fa-f][0-9A-Fa-f]*) printf 'md5:%s\n' "$_mnld_digest"; return 0 ;;
        esac
    fi
    return 1
}

# Produce a stable digest of the persisted settings that can affect nodes.
# The local-only keys are removed line-by-line before hashing. This is a
# change-detection aid, not a security digest; prefer md5sum when available and
# fall back to cksum on minimal BusyBox builds.
merv_settings_node_sync_digest() {
    _msnsd_file="${1:-${SETTINGS_FILE:-}}"
    [ -f "$_msnsd_file" ] || return 1

    if type md5sum >/dev/null 2>&1; then
        _msnsd_hash=$(awk '
            $0 !~ /"AUTO_SYNC_SETTINGS"[[:space:]]*:/ &&
            $0 !~ /"HTML_CLIENT_REFRESH_MINUTES"[[:space:]]*:/ &&
            $0 !~ /"EXPERIMENTAL"[[:space:]]*:/ { print }
        ' "$_msnsd_file" | md5sum 2>/dev/null | awk '{print $1}')
        case "$_msnsd_hash" in
            [0-9A-Fa-f][0-9A-Fa-f]*) printf 'md5:%s\n' "$_msnsd_hash"; return 0 ;;
        esac
    fi

    if type cksum >/dev/null 2>&1; then
        _msnsd_hash=$(awk '
            $0 !~ /"AUTO_SYNC_SETTINGS"[[:space:]]*:/ &&
            $0 !~ /"HTML_CLIENT_REFRESH_MINUTES"[[:space:]]*:/ &&
            $0 !~ /"EXPERIMENTAL"[[:space:]]*:/ { print }
        ' "$_msnsd_file" | cksum 2>/dev/null | awk '{print $1 ":" $2}')
        case "$_msnsd_hash" in
            [0-9]*:[0-9]*) printf 'cksum:%s\n' "$_msnsd_hash"; return 0 ;;
        esac
    fi

    return 1
}

# ============================================================================
# Explicit JSON contracts
# ============================================================================
# The legacy helpers predate concurrent action handling and often use a
# default-value/zero-output convention.  Security-sensitive callers use these
# wrappers instead: getters distinguish missing data from an empty value and
# setters render to a private sibling before a single rename commits the file.

_json_contract_key_valid() {
    case "${1:-}" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
}

_json_contract_value_valid() {
    [ "${#1}" -le 4096 ] 2>/dev/null || return 1
    printf '%s' "${1:-}" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null && return 1
    return 0
}

_json_contract_validate_file() {
    _jcv_file="$1"
    [ -f "$_jcv_file" ] && [ -s "$_jcv_file" ] || return 1
    awk '
        function add(t, v) { tok[++nt]=t; val[nt]=v }
        function parse_value( t ) {
            t=tok[pos]
            if (t=="{") return parse_object()
            if (t=="[") return parse_array()
            if (t=="S") { pos++; return 1 }
            if (t=="W") {
                if (val[pos] ~ /^(true|false|null)$/ || val[pos] ~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) { pos++; return 1 }
            }
            bad=1; return 0
        }
        function parse_object( ok ) {
            if (tok[pos]!="{") { bad=1; return 0 }
            pos++
            if (tok[pos]=="}") { pos++; return 1 }
            while (1) {
                if (tok[pos]!="S") { bad=1; return 0 }
                pos++
                if (tok[pos] != ":") { bad=1; return 0 }
                pos++
                if (!parse_value()) return 0
                if (tok[pos]==",") {
                    pos++
                    if (tok[pos]=="}") { bad=1; return 0 }
                    continue
                }
                if (tok[pos]=="}") { pos++; return 1 }
                bad=1; return 0
            }
        }
        function parse_array() {
            if (tok[pos]!="[") { bad=1; return 0 }
            pos++
            if (tok[pos]=="]") { pos++; return 1 }
            while (1) {
                if (!parse_value()) return 0
                if (tok[pos]==",") {
                    pos++
                    if (tok[pos]=="]") { bad=1; return 0 }
                    continue
                }
                if (tok[pos]=="]") { pos++; return 1 }
                bad=1; return 0
            }
        }
        {
            i=1
            while (i<=length($0)) {
                c=substr($0,i,1)
                if (in_string) {
                    if (unicode_left>0) {
                        if (c !~ /^[0-9A-Fa-f]$/) bad=1
                        unicode_left--
                    } else if (escaped) {
                        if (c=="u") unicode_left=4
                        else if (c !~ /["\\\/bfnrt]/) bad=1
                        escaped=0
                    } else if (c=="\\") escaped=1
                    else if (c=="\"") { in_string=0; add("S", "") }
                    else if (c ~ /[[:cntrl:]]/) bad=1
                    i++; continue
                }
                if (c ~ /[[:space:]]/) { i++; continue }
                if (c=="\"") { in_string=1; i++; continue }
                if (c ~ /^[{}\[\],:]$/) { add(c, c); i++; continue }
                if (c ~ /[[:cntrl:]]/) { bad=1; i++; continue }
                j=i
                while (j<=length($0)) {
                    d=substr($0,j,1)
                    if (d ~ /[[:space:]]/ || d ~ /^[{}\[\],:"]$/) break
                    if (d ~ /[[:cntrl:]]/) bad=1
                    j++
                }
                if (j==i) { bad=1; i++; continue }
                add("W", substr($0,i,j-i)); i=j
            }
        }
        END {
            if (in_string || escaped || unicode_left>0 || bad || nt<1 || tok[1]!="{") exit 1
            pos=1
            if (!parse_value() || bad || pos!=nt+1) exit 1
            exit 0
        }
    ' "$_jcv_file" >/dev/null 2>&1
}

_json_contract_section_key_present() {
    _jcsp_section="$1"; _jcsp_key="$2"; _jcsp_file="$3"
    awk -v sec="$_jcsp_section" -v key="$_jcsp_key" '
        function delta(s, t) { t=s; gsub(/[^{}]/,"",t); return gsub(/\{/ ,"&",t)-gsub(/\}/,"&",t) }
        { line=$0
          if (!inside && line ~ ("\"" sec "\"[[:space:]]*:[[:space:]]*\\{")) { inside=1; depth+=delta(line) }
          else if (inside) { if (line ~ ("\"" key "\"[[:space:]]*:")) found=1; depth+=delta(line) }
          if (inside && depth<=0) inside=0
        }
        END { exit !found }
    ' "$_jcsp_file" >/dev/null 2>&1
}

_json_contract_section2_key_present() {
    _jc2p_section="$1"; _jc2p_subsection="$2"; _jc2p_key="$3"; _jc2p_file="$4"
    awk -v sec="$_jc2p_section" -v subsec="$_jc2p_subsection" -v key="$_jc2p_key" '
        function delta(s, t) { t=s; gsub(/[^{}]/,"",t); return gsub(/\{/ ,"&",t)-gsub(/\}/,"&",t) }
        { line=$0
          if (!in1 && line ~ ("\"" sec "\"[[:space:]]*:[[:space:]]*\\{")) { in1=1; d1+=delta(line) }
          else if (in1 && !in2) {
              if (line ~ ("\"" subsec "\"[[:space:]]*:[[:space:]]*\\{")) { in2=1; d2+=delta(line) }
              d1+=delta(line)
          } else if (in2) {
              if (line ~ ("\"" key "\"[[:space:]]*:")) found=1
              d2+=delta(line)
          }
          if (in2 && d2<=0) in2=0
          if (in1 && d1<=0) in1=0
        }
        END { exit !found }
    ' "$_jc2p_file" >/dev/null 2>&1
}

_json_contract_prepare() {
    _jcp_file="$1"; _jcp_defaults="${2:-}"
    case "$_jcp_file" in ''|*..*|*[!A-Za-z0-9_./-]*) return 2 ;; esac
    _jcp_dir=${_jcp_file%/*}; [ "$_jcp_dir" = "$_jcp_file" ] && _jcp_dir=.
    mkdir -p "$_jcp_dir" 2>/dev/null || return 3
    _jcp_tmp="$_jcp_file.contract.$$"
    rm -f "$_jcp_tmp" 2>/dev/null || return 3
    if [ -e "$_jcp_file" ]; then
        [ -f "$_jcp_file" ] || return 3
        _json_contract_validate_file "$_jcp_file" || { _jcp_rc=$?; return 2; }
        cp -p "$_jcp_file" "$_jcp_tmp" 2>/dev/null || return 3
    else
        : > "$_jcp_tmp" || return 3
    fi
    ensure_json_store "$_jcp_tmp" "$_jcp_defaults" || { rm -f "$_jcp_tmp"; return 3; }
    _json_contract_validate_file "$_jcp_tmp" || { rm -f "$_jcp_tmp"; return 3; }
    return 0
}

_json_contract_commit() {
    _jcc_file="$1"; _jcc_tmp="$2"
    [ -s "$_jcc_tmp" ] || { rm -f "$_jcc_tmp"; return 3; }
    _json_contract_validate_file "$_jcc_tmp" || { rm -f "$_jcc_tmp"; return 3; }
    chmod 644 "$_jcc_tmp" 2>/dev/null || { rm -f "$_jcc_tmp"; return 3; }
    mv -f "$_jcc_tmp" "$_jcc_file" 2>/dev/null || { rm -f "$_jcc_tmp"; return 3; }
    _json_contract_validate_file "$_jcc_file" || return 3
    return 0
}

json_get_scalar_ext() {
    _jge_key="$1"; _jge_file="$2"
    _json_contract_key_valid "$_jge_key" || return 2
    [ -f "$_jge_file" ] || return 1
    _json_contract_validate_file "$_jge_file" || return 2
    grep -Eq "\"$_jge_key\"[[:space:]]*:" "$_jge_file" 2>/dev/null || return 1
    json_get_scalar "$_jge_key" "$_jge_file"
    return 0
}

json_get_section_value_ext() {
    _jgse_section="$1"; _jgse_key="$2"; _jgse_file="$3"
    _json_contract_key_valid "$_jgse_section" || return 2
    _json_contract_key_valid "$_jgse_key" || return 2
    [ -f "$_jgse_file" ] || return 1
    _json_contract_validate_file "$_jgse_file" || return 2
    _json_contract_section_key_present "$_jgse_section" "$_jgse_key" "$_jgse_file" || return 1
    _jgse_value=$(json_get_section_value "$_jgse_section" "$_jgse_key" "$_jgse_file" 2>/dev/null) || return 3
    printf '%s\n' "$_jgse_value"
}

json_get_section2_value_ext() {
    _jg2_section="$1"; _jg2_subsection="$2"; _jg2_key="$3"; _jg2_file="$4"
    _json_contract_key_valid "$_jg2_section" || return 2
    _json_contract_key_valid "$_jg2_subsection" || return 2
    _json_contract_key_valid "$_jg2_key" || return 2
    [ -f "$_jg2_file" ] || return 1
    _json_contract_validate_file "$_jg2_file" || return 2
    _json_contract_section2_key_present "$_jg2_section" "$_jg2_subsection" "$_jg2_key" "$_jg2_file" || return 1
    _jg2_value=$(json_get_section2_value "$_jg2_section" "$_jg2_subsection" "$_jg2_key" "$_jg2_file" 2>/dev/null) || return 3
    printf '%s\n' "$_jg2_value"
}

json_set_flag_ext() {
    _jsfe_key="$1"; _jsfe_value="$2"; _jsfe_file="${3:-$SETTINGS_FILE}"; _jsfe_defaults="${4:-}"
    _json_contract_key_valid "$_jsfe_key" || return 2
    _json_contract_value_valid "$_jsfe_value" || return 2
    _json_contract_prepare "$_jsfe_file" "$_jsfe_defaults" || return $?
    json_set_flag "$_jsfe_key" "$_jsfe_value" "$_jcp_tmp" "$_jsfe_defaults" || { rm -f "$_jcp_tmp"; return 3; }
    grep -Eq "\"$_jsfe_key\"[[:space:]]*:" "$_jcp_tmp" 2>/dev/null || { rm -f "$_jcp_tmp"; return 3; }
    _jsfe_observed=$(json_get_scalar "$_jsfe_key" "$_jcp_tmp" 2>/dev/null) || { rm -f "$_jcp_tmp"; return 3; }
    [ "$_jsfe_observed" = "$_jsfe_value" ] || { rm -f "$_jcp_tmp"; return 3; }
    _json_contract_commit "$_jsfe_file" "$_jcp_tmp"
}

json_set_section_value_ext() {
    _jsse_section="$1"; _jsse_key="$2"; _jsse_value="$3"; _jsse_file="${4:-$SETTINGS_FILE}"
    _json_contract_key_valid "$_jsse_section" || return 2
    _json_contract_key_valid "$_jsse_key" || return 2
    _json_contract_value_valid "$_jsse_value" || return 2
    [ -f "$_jsse_file" ] || return 1
    _json_contract_validate_file "$_jsse_file" || return 2
    _json_contract_section_key_present "$_jsse_section" "$_jsse_key" "$_jsse_file" || return 1
    _json_contract_prepare "$_jsse_file" || return $?
    json_set_section_value "$_jsse_section" "$_jsse_key" "$_jsse_value" "$_jcp_tmp" || { rm -f "$_jcp_tmp"; return 3; }
    _json_contract_section_key_present "$_jsse_section" "$_jsse_key" "$_jcp_tmp" || { rm -f "$_jcp_tmp"; return 3; }
    _jsse_observed=$(json_get_section_value "$_jsse_section" "$_jsse_key" "$_jcp_tmp" 2>/dev/null) || { rm -f "$_jcp_tmp"; return 3; }
    [ "$_jsse_observed" = "$_jsse_value" ] || { rm -f "$_jcp_tmp"; return 3; }
    _json_contract_commit "$_jsse_file" "$_jcp_tmp"
}

json_set_section2_value_ext() {
    _js2_section="$1"; _js2_subsection="$2"; _js2_key="$3"; _js2_value="$4"; _js2_file="${5:-$SETTINGS_FILE}"
    _json_contract_key_valid "$_js2_section" || return 2
    _json_contract_key_valid "$_js2_subsection" || return 2
    _json_contract_key_valid "$_js2_key" || return 2
    _json_contract_value_valid "$_js2_value" || return 2
    [ -f "$_js2_file" ] || return 1
    _json_contract_validate_file "$_js2_file" || return 2
    _json_contract_section2_key_present "$_js2_section" "$_js2_subsection" "$_js2_key" "$_js2_file" || return 1
    _json_contract_prepare "$_js2_file" || return $?
    json_set_section2_value "$_js2_section" "$_js2_subsection" "$_js2_key" "$_js2_value" "$_jcp_tmp" || { rm -f "$_jcp_tmp"; return 3; }
    _json_contract_section2_key_present "$_js2_section" "$_js2_subsection" "$_js2_key" "$_jcp_tmp" || { rm -f "$_jcp_tmp"; return 3; }
    _js2_observed=$(json_get_section2_value "$_js2_section" "$_js2_subsection" "$_js2_key" "$_jcp_tmp" 2>/dev/null) || { rm -f "$_jcp_tmp"; return 3; }
    [ "$_js2_observed" = "$_js2_value" ] || { rm -f "$_jcp_tmp"; return 3; }
    _json_contract_commit "$_js2_file" "$_jcp_tmp"
}

# Strict aliases used by new code and by local contract tests.
json_get_scalar_strict() { json_get_scalar_ext "$@"; }
json_get_section_value_strict() { json_get_section_value_ext "$@"; }
json_get_section2_value_strict() { json_get_section2_value_ext "$@"; }
json_set_flag_strict() { json_set_flag_ext "$@"; }
json_set_section_value_strict() { json_set_section_value_ext "$@"; }
json_set_section2_value_strict() { json_set_section2_value_ext "$@"; }

LIB_JSON_LOADED=1
