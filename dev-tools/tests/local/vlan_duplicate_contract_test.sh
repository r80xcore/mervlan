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

grep -Fq 'const DUPLICATE_VLAN_TOOLTIP = "Duplicate VLAN ID; reuse is allowed when intentional.";' "$UI_FILE" || fail 'approved intentional-duplicate explanation missing'
grep -Fq 'STATUS_DUP: "🟡 Duplicate VLAN ID; reuse is allowed when intentional"' "$UI_FILE" || fail 'duplicate status wording was not softened'
grep -Fq 'function duplicateVlanTooltip(field)' "$UI_FILE" || fail 'duplicate field tooltip helper missing'
grep -Fq 'f.title = TOOLTIP.VLAN;' "$UI_FILE" || fail 'VLAN fields are not reset to the standard title before validation'
grep -Fq 'f.title = duplicateVlanTooltip(f);' "$UI_FILE" || fail 'duplicate fields do not receive the intentional-reuse tooltip'
grep -Fq 'This value matches the saved configuration.' "$UI_FILE" || fail 'saved duplicate tooltip detail missing'
grep -Fq 'This is an unsaved current value.' "$UI_FILE" || fail 'unsaved duplicate tooltip detail missing'
grep -Fq 'setDuplicateStatusSymbol(`status${index}`, vlanInput);' "$UI_FILE" || fail 'SSID duplicate status precedence missing'
grep -Fq 'setDuplicateStatusSymbol(`statusLAN${index}`, vlanInput);' "$UI_FILE" || fail 'LAN duplicate status precedence missing'
grep -Fq 'if(el.dataset.statusTooltip)' "$UI_FILE" || fail 'duplicate row tooltip override is not honored'

printf 'VLAN_DUPLICATE_CONTRACT_OK\n'
