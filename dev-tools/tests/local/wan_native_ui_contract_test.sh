#!/bin/sh
# Static browser contract for optional MAIN ASUS recovery and live trunk drafts.
# This test does not contact a router or AP.
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Fresh defaults serialize an unconfigured optional endpoint as "none".  That
# sentinel must be accepted and must not block unrelated settings saves.
grep -Fq 'function wanNativeOptionalIpIsValid(value)' "$UI_FILE" || fail 'optional MAIN ASUS helper missing'
grep -Fq 'raw.toLowerCase() === "none"' "$UI_FILE" || fail 'optional MAIN ASUS helper does not accept none'
grep -Fq 'mainNative && mainNative.toLowerCase() !== "none" && !statusNodeIpIsValid(mainEndpoint)' "$UI_FILE" || fail 'numeric MAIN does not require the WAN Native endpoint'
! grep -Fq 'requires both DHCP reservations' "$UI_FILE" || fail 'legacy two-endpoint requirement remains'
grep -Fq 'MAIN ASUS/default IP must be a valid IPv4 address or left unconfigured.' "$UI_FILE" || fail 'optional ASUS validation message missing'

# The target-aware popup must require only the target-domain endpoint for a
# numeric MAIN VLAN and retain an optional recovery field for ASUS/default.
grep -Fq "target === 'main' && numeric && !statusNodeIpIsValid(nativeIp)" "$UI_FILE" || fail 'numeric MAIN popup does not require target endpoint'
grep -Fq "target === 'main' && !wanNativeOptionalIpIsValid(asusIp)" "$UI_FILE" || fail 'optional ASUS popup validation missing'
grep -Fq "const returningMainToAsus = target === 'main' && vlan === 'none' && managedVlanNumber(String(WAN_NATIVE_POPUP_STATE.vlan || '')) !== null;" "$UI_FILE" || fail 'tagged-to-ASUS popup transition guard missing'
grep -Fq 'Configure a valid ASUS/default DHCP reservation before switching MAIN back to ASUS/default.' "$UI_FILE" || fail 'tagged-to-ASUS recovery message missing'
grep -Fq 'ASUS/default DHCP reservation (optional)' "$UI_FILE" || fail 'optional recovery label missing'

# Newly typed access/SSID VLANs must feed trunk choices without waiting for a
# persistence round trip.
grep -Fq 'function trunkVlanDraftSettings(flat)' "$UI_FILE" || fail 'live trunk draft helper missing'
grep -Fq 'extractVlansFromFlatSettings(trunkVlanDraftSettings(flat))' "$UI_FILE" || fail 'trunk options do not consume live draft'
grep -Fq 'rebuildTrunkVlanOptionsFromSettings(CURRENT_SETTINGS_CACHE || {});' "$UI_FILE" || fail 'VLAN edits do not refresh trunk choices'

printf 'WAN_NATIVE_UI_CONTRACT_OK\n'
