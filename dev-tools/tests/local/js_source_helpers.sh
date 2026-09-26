#!/bin/sh
# Small helper.

extract_js_function() {
    [ "$#" -eq 2 ] || return 2
    _js_extract_name=$1
    _js_extract_file=$2
    awk -v target="$_js_extract_name" '
        function brace_delta(line,    i, ch, nxt, delta) {
            for (i = 1; i <= length(line); i++) {
                ch = substr(line, i, 1)
                nxt = substr(line, i + 1, 1)
                if (js_block_comment) {
                    if (ch == "*" && nxt == "/") {
                        js_block_comment = 0
                        i++
                    }
                    continue
                }
                if (js_quote != "") {
                    if (ch == "\\") {
                        i++
                    } else if (ch == js_quote) {
                        js_quote = ""
                    }
                    continue
                }
                if (ch == "/" && nxt == "/") break
                if (ch == "/" && nxt == "*") {
                    js_block_comment = 1
                    i++
                    continue
                }
                if (ch == "\"" || ch == sprintf("%c", 39) || ch == sprintf("%c", 96)) {
                    js_quote = ch
                    continue
                }
                if (ch == "{") {
                    delta++
                    js_seen_open = 1
                } else if (ch == "}") {
                    delta--
                }
            }
            return delta
        }
        function is_target(line) {
            return line ~ ("^[[:space:]]*(async[[:space:]]+)?function[[:space:]]+" target "[[:space:]]*\\(")
        }
        {
            if (!found && is_target($0)) found = 1
            if (found && !done) {
                print
                depth += brace_delta($0)
                if (js_seen_open && depth == 0) {
                    done = 1
                    exit
                }
            }
        }
        END {
            if (!found || !done) exit 1
        }
    ' "$_js_extract_file"
}
