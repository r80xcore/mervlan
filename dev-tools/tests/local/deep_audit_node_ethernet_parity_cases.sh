#!/bin/sh
# Round 3 audit fixture: compare current manager node-aware Ethernet reads
# with heal's MAIN Ethernet expectation for parity cases A/B/C.
# Production functions are extracted into temporary state; no runtime source
# or router/device state is changed.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.deep-audit-node-eth-parity.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

extract_function() {
    _name="$1"; _source="$2"; _destination="$3"; _occurrence="${4:-1}"
    awk -v function_name="$_name" -v wanted="$_occurrence" '
        { sub(/\r$/, "") }
        $0 ~ ("^" function_name "\\()[[:space:]]*\\{") {
            candidate++
            if (candidate == wanted) active=1
        }
        active { print }
        active && $0 == "}" { exit }
    ' "$_source" > "$_destination" || return 1
    [ -s "$_destination" ]
}

SETTINGS_FILE="$TEST_ROOT/settings.json"
export SETTINGS_FILE
MERV_BASE="$BASE_DIR"
export MERV_BASE
LIB_JSON_LOADED=
. "$BASE_DIR/settings/lib_json.sh" || fail 'could not load JSON fixture helpers'

MANAGER_FUNCTION="$TEST_ROOT/manager_read_json.sh"
HEAL_FUNCTION="$TEST_ROOT/heal_expected_vlans.sh"
extract_function read_json "$BASE_DIR/functions/mervlan_manager.sh" \
    "$MANAGER_FUNCTION" 2 || fail 'could not extract node-aware manager read_json'
extract_function expected_vlans_from_settings "$BASE_DIR/functions/heal_event.sh" \
    "$HEAL_FUNCTION" || fail 'could not extract heal expected_vlans_from_settings'

read_json_raw() { json_get_scalar "$1" "$2"; }
merv_is_valid_node_id() {
    case "$1" in
        1|2|3|4|5) return 0 ;;
        *) return 1 ;;
    esac
}
NODE_ID=1
export NODE_ID
. "$MANAGER_FUNCTION" || fail 'could not load manager resolver fixture'

MAX_SSIDS=1
ETH_PORTS='eth1'
SSID_FILTER_FATAL=0
get_vlan_slot_value() { printf '%s\n' none; }
trim_spaces() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
is_number() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}
error() { :; }
export MAX_SSIDS ETH_PORTS SSID_FILTER_FATAL
. "$HEAL_FUNCTION" || fail 'could not load heal resolver fixture'

run_case() {
    _case="$1"
    _main="$2"
    _override="$3"
    if [ "$_override" = absent ]; then
        printf '%s\n' \
            '{' \
            '  "ETH1_VLAN": "100",' \
            '  "VLAN": {' \
            '    "Ethernet_ports": {"ETH1_VLAN": "100"},' \
            '    "Pool": {"VLAN_01": "none"},' \
            '    "Trunks": {}' \
            '  }' \
            '}' > "$SETTINGS_FILE" || return 1
    else
        printf '%s\n' \
            '{' \
            "  \"ETH1_VLAN\": \"$_main\"," \
            "  \"NODE1_ETH1_VLAN\": \"$_override\"," \
            '  "VLAN": {' \
            '    "Ethernet_ports": {"ETH1_VLAN": "100"},' \
            '    "Pool": {"VLAN_01": "none"},' \
            '    "Trunks": {}' \
            '  }' \
            '}' > "$SETTINGS_FILE" || return 1
    fi

    MANAGER_VALUE=$(read_json ETH1_VLAN "$SETTINGS_FILE")
    set +u
    HEAL_VALUE=$(expected_vlans_from_settings)
    _heal_rc=$?
    set -u
    [ "$_heal_rc" -eq 0 ] || fail "case $_case heal resolver failed (rc=$_heal_rc)"
    printf 'CASE %s: manager=%s heal=%s\n' "$_case" "$MANAGER_VALUE" "$HEAL_VALUE"
    case "$_case" in
        A)
            [ "$MANAGER_VALUE" = 100 ] || fail 'case A manager parity mismatch'
            printf '%s\n' "$HEAL_VALUE" | grep -qx 100 || fail 'case A heal parity mismatch'
            ;;
        B)
            [ "$MANAGER_VALUE" = 200 ] || fail 'case B manager did not use node override'
            printf '%s\n' "$HEAL_VALUE" | grep -qx 100 || fail 'case B heal did not use MAIN Ethernet VLAN'
            ;;
        C)
            [ "$MANAGER_VALUE" = none ] || fail 'case C manager unexpectedly fell back to MAIN'
            printf '%s\n' "$HEAL_VALUE" | grep -qx 100 || fail 'case C heal MAIN VLAN missing'
            ;;
    esac
}

# A: matching MAIN and NODE1 values preserve parity.
run_case A 100 100 || exit 1
# B: differing values diverge: manager uses NODE1 override; heal uses MAIN.
run_case B 100 200 || exit 1
# C: absent NODE1 override is strict "none" in manager, while heal still sees MAIN.
run_case C 100 absent || exit 1

printf 'VERDICT: A=parity; B=divergence; C=divergence\n'
printf 'EVIDENCE: manager strict node override has no MAIN fallback; heal Ethernet expectation remains MAIN-scoped\n'
printf 'DEEP_AUDIT_NODE_ETHERNET_PARITY_CASES_OK\n'
