#!/bin/sh
# Focused self-check for js_source_helpers.sh. It must tolerate indentation,
# nested blocks, strings, comments, and an async declaration while failing
# closed for missing or unterminated functions.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TMP_ROOT="/tmp/mervlan-js-source-helper.$$"
umask 077
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

. "$TEST_DIR/js_source_helpers.sh"

FIXTURE="$TMP_ROOT/fixture.js"
printf '%s\n' \
    '  async function nestedExample(value) {' \
    '    const text = "}"' \
    '    /* { this brace is a comment */' \
    '    if (value) {' \
    '      return { value };' \
    '    }' \
    '    return "template";' \
    '  }' \
    '  function afterExample() {' \
    '    return true;' \
    '  }' > "$FIXTURE"

body=$(extract_js_function nestedExample "$FIXTURE") || fail 'async function extraction failed'
printf '%s\n' "$body" | grep -Fq 'return { value };' || fail 'nested function body was truncated'
! printf '%s\n' "$body" | grep -Fq 'function afterExample' || fail 'extraction consumed the next function'

if extract_js_function missingExample "$FIXTURE" >/dev/null 2>&1; then
    fail 'missing function did not fail closed'
fi

printf '%s\n' 'function brokenExample() {' > "$TMP_ROOT/broken.js"
if extract_js_function brokenExample "$TMP_ROOT/broken.js" >/dev/null 2>&1; then
    fail 'unterminated function did not fail closed'
fi

printf 'JS_SOURCE_HELPERS_CONTRACT_OK\n'
