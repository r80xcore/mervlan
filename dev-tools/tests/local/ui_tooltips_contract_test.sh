#!/bin/sh
# Source contract for approved static action and status-legend titles.
# This test does not contact a router or AP.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'title="Save the current MerVLAN configuration."' "$UI_FILE" || fail 'Save title mismatch'
grep -Fq 'title="Run MerVLAN Manager and apply the current VLAN configuration."' "$UI_FILE" || fail 'Apply VLAN title mismatch'
grep -Fq 'title="Sync MerVLAN files and settings to configured nodes."' "$UI_FILE" || fail 'Sync Nodes title mismatch'
grep -Fq 'title="Show update and restore options."' "$UI_FILE" || fail 'Version title mismatch'

legend_items=$(grep -Fc 'class="legend__item" title=' "$UI_FILE")
[ "$legend_items" -eq 5 ] || fail "expected five titled legend items, found $legend_items"
grep -Fq 'title="Configured and matches the saved configuration."' "$UI_FILE" || fail 'Valid legend title mismatch'
grep -Fq 'title="No configuration is set for this row."' "$UI_FILE" || fail 'Unconfigured legend title mismatch'
grep -Fq 'title="Changed in the UI and not yet saved."' "$UI_FILE" || fail 'Pending legend title mismatch'
grep -Fq 'title="Configuration is incomplete or contains an invalid required value."' "$UI_FILE" || fail 'Missing legend title mismatch'
grep -Fq 'title="This VLAN ID is used more than once. This is allowed if intentional; MerVLAN supports multiple assignments to the same VLAN."' "$UI_FILE" || fail 'Duplicate legend title mismatch'

printf 'UI_TOOLTIPS_CONTRACT_OK\n'
