#!/bin/sh
# Source contract for native metadata-editor titles.
# This test does not contact a router or AP.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'title="Set an optional friendly name for this client in MerVLAN. This does not change the device hostname or DNS name."' "$UI_FILE" || fail 'client-name title mismatch'
grep -Fq 'title="Unlock: Exclude this MAC from MAC shield locking across the cluster so the device can roam between bridges without being blocked by MAC shield. Example: a trusted admin device that needs to move between the native LAN and VLAN networks. Normal VLAN and firewall policy still applies."' "$UI_FILE" || fail 'Unlock title mismatch'
grep -Fq 'title="Enter a MAC address to add an Unlock override, even if the device is not currently detected. Example: aa:bb:cc:dd:ee:ff."' "$UI_FILE" || fail 'Add MAC input title mismatch'
grep -Fq 'title="Add the entered MAC to the metadata editor and enable Unlock for it."' "$UI_FILE" || fail 'Add button title mismatch'
grep -Fq 'title="Save client names and Unlock selections, apply the MAC shield changes, and refresh client information."' "$UI_FILE" || fail 'Save Client Metadata title mismatch'
grep -Fq 'title="Discard unsaved metadata changes and return to the client overview."' "$UI_FILE" || fail 'Cancel title mismatch'
grep -Fq "btn.title = CLIENT_META_EDIT" "$UI_FILE" || fail 'footer title is not updated with editor state'
grep -Fq "'Close the metadata editor without saving unsaved changes.'" "$UI_FILE" || fail 'open-editor footer title mismatch'
grep -Fq "'Edit friendly client names and configure MAC shield Unlock overrides.'" "$UI_FILE" || fail 'closed-editor footer title mismatch'

printf 'METADATA_TOOLTIPS_CONTRACT_OK\n'
