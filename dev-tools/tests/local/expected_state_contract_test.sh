#!/bin/sh
# Round 1 permanent contract: a single strict Ethernet resolver supplies all
# consumers, unknown state fails closed, and bridge proof is exact.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/expected-state-contract.$$"
umask 077
mkdir -p "$TEST_ROOT/sys/class/net" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$2" = "$3" ] || fail "$1 (got '$2', expected '$3')"; }
assert_rc() {
  _arc_label="$1"; _arc_expected="$2"; shift 2
  if "$@" >/dev/null 2>&1; then _arc_actual=0; else _arc_actual=$?; fi
  [ "$_arc_actual" -eq "$_arc_expected" ] || fail "$_arc_label rc=$_arc_actual expected=$_arc_expected"
}

SETTINGS_FILE="$TEST_ROOT/settings.json"
export SETTINGS_FILE
printf '%s\n' \
  '{' \
  '  "VLAN": {' \
  '    "Ethernet_ports": {' \
  '      "ETH1_VLAN": "100", "ETH2_VLAN": "trunk", "ETH3_VLAN": "none", "ETH4_VLAN": "bad"' \
  '    },' \
  '    "Node_overrides": {' \
  '      "NODE1": {"NODE1_Ethernet_ports": {' \
  '        "NODE1_ETH1_VLAN": "200", "NODE1_ETH2_VLAN": "trunk", "NODE1_ETH3_VLAN": "none", "NODE1_ETH4_VLAN": "oops"' \
  '      }}' \
  '    }' \
  '  }' \
  '}' > "$SETTINGS_FILE" || exit 1

MERV_BASE="$BASE_DIR"
export MERV_BASE
LIB_JSON_LOADED=
. "$BASE_DIR/settings/lib_json.sh" || fail 'could not load lib_json'
. "$BASE_DIR/settings/lib_br0_guard.sh" || fail 'could not load lib_br0_guard'

assert_eq 'MAIN numeric policy' "$(merv_effective_eth_vlan 1 "$SETTINGS_FILE" none)" 100
assert_eq 'MAIN trunk policy' "$(merv_effective_eth_vlan 2 "$SETTINGS_FILE" main)" trunk
assert_eq 'NODE numeric override' "$(merv_effective_eth_vlan 1 "$SETTINGS_FILE" 1)" 200
assert_eq 'NODE trunk override' "$(merv_effective_eth_vlan 2 "$SETTINGS_FILE" 1)" trunk
assert_eq 'NODE missing override is native' "$(merv_effective_eth_vlan 8 "$SETTINGS_FILE" 1)" none
assert_rc 'malformed MAIN policy' 1 merv_effective_eth_vlan 4 "$SETTINGS_FILE" none
assert_rc 'malformed NODE policy' 1 merv_effective_eth_vlan 4 "$SETTINGS_FILE" 1
assert_rc 'invalid node identity' 1 merv_effective_eth_vlan 1 "$SETTINGS_FILE" 11

ETH_PORTS='lan_a lan_b lan_c lan_d'
export ETH_PORTS
assert_eq 'NODE managed Ethernet mapping' "$(merv_managed_eth_iface_vid_list "$SETTINGS_FILE" 1)" 'lan_a 200'
assert_rc 'managed Ethernet resolver error propagates' 1 merv_managed_eth_iface_vid_list "$SETTINGS_FILE" none

MERV_SYS_CLASS_NET_ROOT="$TEST_ROOT/sys/class/net"
export MERV_SYS_CLASS_NET_ROOT
mkdir -p "$MERV_SYS_CLASS_NET_ROOT/lan_a" \
  "$MERV_SYS_CLASS_NET_ROOT/br0/brif" \
  "$MERV_SYS_CLASS_NET_ROOT/br100/brif" \
  "$MERV_SYS_CLASS_NET_ROOT/br200/brif" || exit 1
reset_membership() {
  rm -f "$MERV_SYS_CLASS_NET_ROOT/br0/brif/lan_a" \
    "$MERV_SYS_CLASS_NET_ROOT/br100/brif/lan_a" \
    "$MERV_SYS_CLASS_NET_ROOT/br200/brif/lan_a"
}
reset_membership
: > "$MERV_SYS_CLASS_NET_ROOT/br200/brif/lan_a"
assert_rc 'correct bridge exact membership' 0 merv_exact_bridge_membership lan_a 200
reset_membership
: > "$MERV_SYS_CLASS_NET_ROOT/br0/brif/lan_a"
assert_rc 'br0 is not a managed VLAN bridge' 1 merv_exact_bridge_membership lan_a 200
reset_membership
: > "$MERV_SYS_CLASS_NET_ROOT/br100/brif/lan_a"
assert_rc 'wrong VLAN bridge is rejected' 1 merv_exact_bridge_membership lan_a 200
reset_membership
: > "$MERV_SYS_CLASS_NET_ROOT/br0/brif/lan_a"
: > "$MERV_SYS_CLASS_NET_ROOT/br200/brif/lan_a"
assert_rc 'multi-bridge membership is rejected' 1 merv_exact_bridge_membership lan_a 200
reset_membership
assert_rc 'absent bridge membership is rejected' 1 merv_exact_bridge_membership lan_a 200

. "$BASE_DIR/settings/mac_shield_snapshot.sh" || fail 'could not load MAC snapshot helpers'
CACHE_TRACE="$TEST_ROOT/cache.trace"
CACHE_MODE=error
warn() { :; }
merv_mac_build_expected_iface_vid() {
  printf '%s\n' "$CACHE_MODE" >> "$CACHE_TRACE"
  [ "$CACHE_MODE" = valid ] || return 1
  return 0
}
merv_iface_vid_cache_enable
assert_rc 'first cache error' 1 merv_iface_vid_list
assert_rc 'cached error stays an error' 1 merv_iface_vid_list
assert_eq 'error state calls builder once' "$(wc -l < "$CACHE_TRACE" | tr -d '[:space:]')" 1
merv_iface_vid_cache_invalidate
CACHE_MODE=valid
assert_rc 'valid known-empty state' 0 merv_iface_vid_list
assert_rc 'cached known-empty state' 0 merv_iface_vid_list
assert_eq 'valid empty state calls builder once after invalidation' "$(wc -l < "$CACHE_TRACE" | tr -d '[:space:]')" 2
CACHE_MODE=error
merv_iface_vid_cache_invalidate
assert_rc 'snapshot precondition rejects unknown expected state' 1 merv_mac_snapshot_preconditions_ok

printf 'EXPECTED_STATE_CONTRACT_OK\n'
