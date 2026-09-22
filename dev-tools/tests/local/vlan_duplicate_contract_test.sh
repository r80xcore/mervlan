#!/bin/sh
# Source contract for duplicate VLAN presentation in the browser UI.
# This test is static and does not contact a router or AP.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'const DUPLICATE_VLAN_TOOLTIP = "This VLAN ID is already in use. No action is needed if that is intentional.";' "$UI_FILE" || fail 'approved intentional-duplicate explanation missing'
grep -Fq 'function duplicateVlanTooltip(field)' "$UI_FILE" || fail 'duplicate field tooltip helper missing'
grep -Fq 'f.title = TOOLTIP.VLAN;' "$UI_FILE" || fail 'VLAN fields are not reset to the standard title before validation'
grep -Fq 'f.title = duplicateVlanTooltip(f);' "$UI_FILE" || fail 'duplicate fields do not receive the intentional-reuse tooltip'
grep -Fq 'This duplicate VLAN ID is already saved.' "$UI_FILE" || fail 'saved duplicate tooltip detail missing'
grep -Fq 'This duplicate VLAN ID has not been saved yet.' "$UI_FILE" || fail 'unsaved duplicate tooltip detail missing'
grep -Fq '/^(?:NODE\d+_)?ETH\d+_VLAN$/.test(cacheKey)' "$UI_FILE" || fail 'cached VLAN candidates are not restricted to LAN VLAN keys'
! grep -Fq 'STATUS_DUP:' "$UI_FILE" || fail 'duplicate remains a row-status state'
! grep -Fq 'STATUS_SYMBOLS.duplicate' "$UI_FILE" || fail 'duplicate status symbol remains in use'
! grep -Fq 'setDuplicateStatusSymbol(' "$UI_FILE" || fail 'duplicate row-status helper remains'
grep -Fq 'Yellow dot in a VLAN input:' "$UI_FILE" || fail 'legend does not explain the field-level duplicate marker'

printf 'VLAN_DUPLICATE_CONTRACT_OK\n'
