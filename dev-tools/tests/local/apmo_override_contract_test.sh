#!/bin/sh
#
# Focused APMO / Hardware_Override contract test.
#
# Verifies the nested JSON reader with both the host awk and BusyBox awk when
# available. The fixture deliberately enables distinct MAIN and NODE1 maps so
# a target-selection regression cannot pass by reading the wrong subsection.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
export MERV_BASE

TEST_ROOT="${TMPDIR:-/tmp}/mervlan-apmo-override.$(date +%s).$$"
FIXTURE="$TEST_ROOT/settings.json"
SET_FIXTURE="$TEST_ROOT/settings-set.json"
BB_BIN="$TEST_ROOT/busybox-bin"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    _expected="$1"
    _actual="$2"
    _label="$3"
    [ "$_actual" = "$_expected" ] || fail "$_label: expected '$_expected', got '$_actual'"
}

mkdir -p "$TEST_ROOT"
printf '%s\n' \
    '{' \
    '  "General": {' \
    '    "IS_NODE": "0",' \
    '    "NODE_ID": "none"' \
    '  },' \
    '  "Hardware_Override": {' \
    '    "MAIN": {' \
    '      "MAP_OVERRIDE": "1",' \
    '      "OVERRIDE_WAN": "eth5",' \
    '      "OVERRIDE_MAX_ETH_PORTS": "6",' \
    '      "OVERRIDE_LAN1": "eth1",' \
    '      "OVERRIDE_LAN2": "eth2",' \
    '      "OVERRIDE_LAN3": "eth3",' \
    '      "OVERRIDE_LAN4": "eth4",' \
    '      "OVERRIDE_LAN5": "eth0",' \
    '      "OVERRIDE_LAN6": "eth6"' \
    '    },' \
    '    "NODE1": {' \
    '      "MAP_OVERRIDE": "1",' \
    '      "OVERRIDE_WAN": "eth6",' \
    '      "OVERRIDE_MAX_ETH_PORTS": "2",' \
    '      "OVERRIDE_LAN1": "eth1",' \
    '      "OVERRIDE_LAN2": "eth2"' \
    '    }' \
    '  }' \
    '}' > "$FIXTURE"

LIB_JSON_LOADED=
. "$MERV_BASE/settings/lib_json.sh"

assert_eq "1" "$(json_get_section2_value Hardware_Override MAIN MAP_OVERRIDE "$FIXTURE")" \
    "host awk MAIN MAP_OVERRIDE"
assert_eq "eth5" "$(json_get_section2_value Hardware_Override MAIN OVERRIDE_WAN "$FIXTURE")" \
    "host awk MAIN WAN"
assert_eq "1" "$(json_get_section2_value Hardware_Override NODE1 MAP_OVERRIDE "$FIXTURE")" \
    "host awk NODE1 MAP_OVERRIDE"
assert_eq "eth6" "$(json_get_section2_value Hardware_Override NODE1 OVERRIDE_WAN "$FIXTURE")" \
    "host awk NODE1 WAN"

BUSYBOX=$(command -v busybox 2>/dev/null || true)
if [ -n "$BUSYBOX" ]; then
    mkdir -p "$BB_BIN"
    ln -s "$BUSYBOX" "$BB_BIN/awk" || fail "cannot create BusyBox awk shim"

    assert_eq "1" "$(PATH="$BB_BIN:$PATH" json_get_section2_value Hardware_Override MAIN MAP_OVERRIDE "$FIXTURE")" \
        "BusyBox awk MAIN MAP_OVERRIDE"
    assert_eq "eth5" "$(PATH="$BB_BIN:$PATH" json_get_section2_value Hardware_Override MAIN OVERRIDE_WAN "$FIXTURE")" \
        "BusyBox awk MAIN WAN"
    assert_eq "1" "$(PATH="$BB_BIN:$PATH" json_get_section2_value Hardware_Override NODE1 MAP_OVERRIDE "$FIXTURE")" \
        "BusyBox awk NODE1 MAP_OVERRIDE"

    cp "$FIXTURE" "$SET_FIXTURE"
    PATH="$BB_BIN:$PATH" json_set_section2_value Hardware_Override NODE1 MAP_OVERRIDE 0 "$SET_FIXTURE" || \
        fail "BusyBox awk nested setter"
    assert_eq "0" "$(PATH="$BB_BIN:$PATH" json_get_section2_value Hardware_Override NODE1 MAP_OVERRIDE "$SET_FIXTURE")" \
        "BusyBox awk setter/getter round trip"
else
    printf 'WARN: BusyBox awk unavailable; router-side compatibility portion skipped\n'
fi

# The modal must serialize per-device targets and reject duplicate interfaces
# before saving. These are source contracts for the browser-only validation.
grep -q 'function validateAdvancedOverrideDuplicates' "$MERV_BASE/www/index.html" || \
    fail "APMO duplicate validator missing"
grep -q 'Duplicate interface:' "$MERV_BASE/www/index.html" || \
    fail "APMO duplicate error missing"
grep -q 'if (!validateAdvancedOverrideDuplicates()) return;' "$MERV_BASE/www/index.html" || \
    fail "APMO apply does not enforce duplicate validation"
grep -q 'vlanmgr_OVERRIDE_${t}_MAP_OVERRIDE' "$MERV_BASE/www/index.html" || \
    fail "APMO per-device target serialization missing"

printf 'APMO_OVERRIDE_CONTRACT_OK\n'
