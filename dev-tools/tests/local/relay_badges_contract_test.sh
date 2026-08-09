#!/bin/sh
# Source contract for presentation-only relay client badges.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

block=$(sed -n '/^function renderClientMetaBadges(/,/^}/p' "$UI_FILE")
printf '%s\n' "$block" | grep -Fq "c.location_status === 'relay_only' || c.diagnostic" || fail 'relay-only predicate changed'
printf '%s\n' "$block" | grep -Fq '>R/O</span>' || fail 'relay-only badge is not R/O'
printf '%s\n' "$block" | grep -Fq 'Relay-only (R/O): The device was seen only through a trunk/backhaul and no direct active location could be resolved. Hidden from active clients by default.' || fail 'relay-only explanation missing'
printf '%s\n' "$block" | grep -Fq "c.location_status === 'relayed'" || fail 'relayed predicate changed'
printf '%s\n' "$block" | grep -Fq "Relayed (R): This is an indirect observation through a trunk/backhaul; MerVLAN resolved the device\\'s direct active location elsewhere." || fail 'relayed explanation missing'
! printf '%s\n' "$block" | grep -Fq '>Relay-only</span>' || fail 'legacy relay-only badge remains'

printf 'RELAY_BADGES_CONTRACT_OK\n'
