#!/bin/sh
# Source contract for the browser-owned managed VLAN validator.
# This test does not contact a router or AP.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'const MANAGED_VLAN_MIN = 2;' "$UI_FILE" || fail 'managed VLAN minimum constant missing'
grep -Fq 'const MANAGED_VLAN_MAX = 4094;' "$UI_FILE" || fail 'managed VLAN maximum constant missing'
grep -Fq 'function isManagedVlan(value)' "$UI_FILE" || fail 'strict managed VLAN helper missing'
grep -Fq 'if (!/^\d+$/.test(text)) return false;' "$UI_FILE" || fail 'managed VLAN helper is not digits-only'
grep -Fq 'Number.isInteger(number) && number >= MANAGED_VLAN_MIN && number <= MANAGED_VLAN_MAX' "$UI_FILE" || fail 'managed VLAN helper bounds are not canonical'
grep -Fq 'function managedVlanNumber(value)' "$UI_FILE" || fail 'managed VLAN number adapter missing'

# Tooltip/range text must derive from the same constants.
grep -Fq 'VLAN: `Enter VLAN ID (${MANAGED_VLAN_MIN}' "$UI_FILE" || fail 'VLAN tooltip does not use canonical minimum'
grep -Fq '${MANAGED_VLAN_MAX}).`' "$UI_FILE" || fail 'VLAN tooltip does not use canonical maximum'

# Required UI paths must route through the strict helper/adapter.
grep -Fq 'return isManagedVlan(part) ? String(Number(part)) : null;' "$UI_FILE" || fail 'custom trunk parsing bypasses strict helper'
[ "$(grep -Fc 'const vlanNum = managedVlanNumber(vlanValue);' "$UI_FILE")" -ge 2 ] || fail 'AP Isolation/SSID assignment do not use managed helper'
[ "$(grep -Fc 'const num = managedVlanNumber(raw);' "$UI_FILE")" -ge 2 ] || fail 'live/cache duplicate collection does not use managed helper'
grep -Fq 'const num = managedVlanNumber(opt.value);' "$UI_FILE" || fail 'tagged trunk duplicate collection bypasses managed helper'
grep -Fq 'const num = managedVlanNumber(val);' "$UI_FILE" || fail 'untagged trunk duplicate collection bypasses managed helper'
[ "$(grep -Fc 'const n = managedVlanNumber(value);' "$UI_FILE")" -ge 2 ] || fail 'extracted settings do not use managed helper'

! grep -Fq '4096' "$UI_FILE" || fail 'legacy 4096 VLAN bound remains'
! grep -Eq 'vlanNum[[:space:]]*>=[[:space:]]*1|vlanNum[[:space:]]*<=[[:space:]]*4094' "$UI_FILE" || fail 'divergent SSID/AP Isolation VLAN bound remains'

printf 'VLAN_VALIDATION_CONTRACT_OK\n'
