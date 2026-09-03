#!/bin/sh
# Contract coverage for resolver status propagation in heal VLAN checks.
#
# The check callers are extracted from production so this test catches the
# command-substitution status loss.  The resolver failure cases use the real
# expected_vlans_from_settings implementation with isolated dependency
# fixtures; no router, bridge, or live healing action is invoked.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.heal-vlan-status.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

extract_function() {
    _name="$1"
    _source="$2"
    _destination="$3"
    awk -v function_name="$_name" '
        function brace_delta(line,    opens, closes) {
            opens = line
            gsub(/[^\{]/, "", opens)
            closes = line
            gsub(/[^\}]/, "", closes)
            return length(opens) - length(closes)
        }
        { sub(/\r$/, "") }
        !active && $0 ~ ("^" function_name "\\()[[:space:]]*\\{") {
            active=1
        }
        active {
            print
            depth += brace_delta($0)
            if (depth == 0) exit
        }
    ' "$_source" > "$_destination" || return 1
    [ -s "$_destination" ]
}

EXPECTED_FUNCTION="$TEST_ROOT/expected_vlans_from_settings.sh"
CHECK_FUNCTION="$TEST_ROOT/check_vlan_config.sh"
FAST_FUNCTION="$TEST_ROOT/check_vlan_config_fast.sh"
extract_function expected_vlans_from_settings \
    "$BASE_DIR/functions/heal_event.sh" "$EXPECTED_FUNCTION" || \
    fail 'could not extract production expected_vlans_from_settings'
extract_function check_vlan_config \
    "$BASE_DIR/functions/heal_event.sh" "$CHECK_FUNCTION" || \
    fail 'could not extract production check_vlan_config'
extract_function check_vlan_config_fast \
    "$BASE_DIR/functions/heal_event.sh" "$FAST_FUNCTION" || \
    fail 'could not extract production check_vlan_config_fast'

# Resolver dependencies: all settings are supplied by these isolated
# functions, so expected_vlans_from_settings never reads live configuration.
SETTINGS_FILE="$TEST_ROOT/settings.json"
MAX_SSIDS=0
ETH_PORTS=''
SSID_FILTER_FATAL=0
MERV_NODE_ID=none
TICKS_PER_SEC=0
TICK_CMD=:
export SETTINGS_FILE MAX_SSIDS ETH_PORTS SSID_FILTER_FATAL MERV_NODE_ID
export TICKS_PER_SEC TICK_CMD

trim_spaces() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}
error() { :; }
get_vlan_slot_value() { printf '%s\n' none; }
merv_effective_eth_vlan() { printf '%s\n' none; }
json_get_section2_value() { printf '%s\n' ''; }
json_get_flag() { printf '%s\n' ''; }

. "$EXPECTED_FUNCTION" || fail 'could not load production resolver fixture'
. "$CHECK_FUNCTION" || fail 'could not load production VLAN checker fixture'
. "$FAST_FUNCTION" || fail 'could not load production fast VLAN checker fixture'

# The complete checker performs a monitoring window.  Keep it deterministic
# and immediate while retaining the real production control flow.
check_wan_native_health() { return 0; }
check_managed_eth_placements() { return 0; }
merv_qt_ensure_expected_rules() { :; }
actual_vlans_from_kernel() { printf '%s\n' "$ACTUAL_VLANS"; }

assert_nonzero() {
    _label="$1"
    _rc="$2"
    if [ "$_rc" -eq 0 ]; then
        printf 'FAILURE %s: returned zero for resolver failure\n' "$_label"
        FAILURES=$((FAILURES + 1))
    else
        printf 'PASS %s: returned nonzero (rc=%s)\n' "$_label" "$_rc"
    fi
}

assert_zero() {
    _label="$1"
    _rc="$2"
    if [ "$_rc" -ne 0 ]; then
        printf 'FAILURE %s: returned rc=%s\n' "$_label" "$_rc"
        FAILURES=$((FAILURES + 1))
    else
        printf 'PASS %s: returned zero\n' "$_label"
    fi
}

run_checker() {
    _label="$1"
    _checker="$2"
    set +u
    "$_checker" >"$TEST_ROOT/${_label}.out" 2>&1
    _rc=$?
    set -u
    printf '%s\n' "$_rc"
}

run_resolver() {
    _label="$1"
    set +u
    expected_vlans_from_settings >"$TEST_ROOT/${_label}.out" 2>&1
    _rc=$?
    set -u
    printf '%s\n' "$_rc"
}

assert_output_contains() {
    _label="$1"
    _file="$2"
    _value="$3"
    if ! grep -Fxq "$_value" "$_file"; then
        printf 'FAILURE %s: output did not contain %s\n' "$_label" "$_value"
        FAILURES=$((FAILURES + 1))
    else
        printf 'PASS %s: output contained %s\n' "$_label" "$_value"
    fi
}

assert_output_empty() {
    _label="$1"
    _file="$2"
    if [ -s "$_file" ]; then
        printf 'FAILURE %s: output was not empty\n' "$_label"
        FAILURES=$((FAILURES + 1))
    else
        printf 'PASS %s: output was empty\n' "$_label"
    fi
}

FAILURES=0

# A resolver failure must never become the legitimate successful-empty path.
# Ethernet policy failure is a real expected_vlans_from_settings failure.
MAX_SSIDS=0
ETH_PORTS='eth1'
SSID_FILTER_FATAL=0
merv_effective_eth_vlan() { return 1; }
ACTUAL_VLANS=''
_rc=$(run_resolver ethernet-resolver-failure)
assert_nonzero 'real expected_vlans_from_settings Ethernet failure' "$_rc"
for _checker in check_vlan_config check_vlan_config_fast; do
    _rc=$(run_checker "ethernet-failure-$_checker" "$_checker")
    assert_nonzero "Ethernet resolver failure -> $_checker" "$_rc"
done

# SSID filter fatal is a separate real resolver failure path.
MAX_SSIDS=1
ETH_PORTS=''
SSID_FILTER_FATAL=1
get_vlan_slot_value() { printf '%s\n' none; }
_rc=$(run_resolver ssid-filter-fatal-resolver-failure)
assert_nonzero 'real expected_vlans_from_settings SSID_FILTER_FATAL failure' "$_rc"
for _checker in check_vlan_config check_vlan_config_fast; do
    _rc=$(run_checker "ssid-filter-fatal-$_checker" "$_checker")
    assert_nonzero "SSID_FILTER_FATAL -> $_checker" "$_rc"
done

# Empty expected VLAN output is still a legitimate success when the resolver
# itself succeeds.
MAX_SSIDS=0
ETH_PORTS=''
SSID_FILTER_FATAL=0
_rc=$(run_resolver empty-resolver-success)
assert_zero 'real expected_vlans_from_settings successful empty' "$_rc"
assert_output_empty 'successful empty resolver output' \
    "$TEST_ROOT/empty-resolver-success.out"
_rc=$(run_checker empty-success check_vlan_config)
assert_zero 'successful empty resolver -> check_vlan_config' "$_rc"
_rc=$(run_checker empty-success-fast check_vlan_config_fast)
assert_zero 'successful empty resolver -> check_vlan_config_fast' "$_rc"

# A normal configured VLAN set must pass both real checker control flows.
MAX_SSIDS=1
ETH_PORTS=''
SSID_FILTER_FATAL=0
get_vlan_slot_value() { printf '%s\n' 100; }
ACTUAL_VLANS=100
_rc=$(run_resolver normal-set-resolver-success)
assert_zero 'real expected_vlans_from_settings normal set' "$_rc"
assert_output_contains 'normal resolver output' \
    "$TEST_ROOT/normal-set-resolver-success.out" 100
_rc=$(run_checker normal-set check_vlan_config)
assert_zero 'normal VLAN set -> check_vlan_config' "$_rc"
_rc=$(run_checker normal-set-fast check_vlan_config_fast)
assert_zero 'normal VLAN set -> check_vlan_config_fast' "$_rc"

if [ "$FAILURES" -ne 0 ]; then
    fail "$FAILURES resolver status contract case(s) failed"
fi

printf 'HEAL_VLAN_CONFIG_STATUS_CONTRACT_OK\n'
