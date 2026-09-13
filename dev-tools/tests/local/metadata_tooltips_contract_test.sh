#!/bin/sh
# Source contract for native metadata-editor titles.
# This test does not contact a router or AP.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"
PARENT_FILE="$MERV_BASE/mervlan.asp"
WORKER_FILE="$MERV_BASE/functions/mac_client_meta.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'title="Set an optional friendly name for this client in MerVLAN. This does not change the device hostname or DNS name."' "$UI_FILE" || fail 'client-name title mismatch'
grep -Fq 'title="Unlock: Exclude this MAC from MAC shield locking across the cluster so the device can roam between bridges without being blocked by MAC shield. Example: a trusted admin device that needs to move between the native LAN and VLAN networks. Normal VLAN and firewall policy still applies."' "$UI_FILE" || fail 'Unlock title mismatch'
grep -Fq 'title="Enter a MAC address to add an Unlock override, even if the device is not currently detected. Example: aa:bb:cc:dd:ee:ff."' "$UI_FILE" || fail 'Add MAC input title mismatch'
grep -Fq 'title="Add the entered MAC to the metadata editor and enable Unlock for it."' "$UI_FILE" || fail 'Add button title mismatch'
grep -Fq 'title="Save client names and Unlock selections. If MAC Shield has an active database, apply them immediately and refresh client information; otherwise Unlock selections are staged for the next MAC Shield rebuild."' "$UI_FILE" || fail 'Save Client Metadata title mismatch'
grep -Fq 'title="Discard unsaved metadata changes and return to the client overview."' "$UI_FILE" || fail 'Cancel title mismatch'
grep -Fq "btn.title = CLIENT_META_EDIT" "$UI_FILE" || fail 'footer title is not updated with editor state'
grep -Fq "'Close the metadata editor without saving unsaved changes.'" "$UI_FILE" || fail 'open-editor footer title mismatch'
grep -Fq "'Edit friendly client names and configure MAC shield Unlock overrides.'" "$UI_FILE" || fail 'closed-editor footer title mismatch'

# The embedded client-metadata flow owns the MerVLAN progress panel.  The
# parent wrapper must never also show ASUS's generic loading overlay.
no_loading_block=$(sed -n '/const MVM_NO_LOADING = new Set(\[/,/^\]);/p' "$PARENT_FILE")
printf '%s\n' "$no_loading_block" | grep -Fq '"macclientmeta_vlanmgr"' || fail 'metadata action is missing from parent no-loading policy'
! grep -Fq '"macclientmeta_vlanmgr": 8000' "$PARENT_FILE" || fail 'metadata action still has a parent minimum-loader hold'
grep -Fq 'function MVM_macClientMeta(opts) {' "$PARENT_FILE" || fail 'metadata action wrapper is not explicit'
grep -Fq 'actionOpts.loading = false;' "$PARENT_FILE" || fail 'metadata wrapper can re-enable parent loading'
grep -Fq 'actionOpts.minLoadingMs = 0;' "$PARENT_FILE" || fail 'metadata wrapper can retain a parent loader hold'
quiet_save_block=$(sed -n '/function MVM_save_quiet(settingsObj)/,/^}/p' "$PARENT_FILE")
printf '%s\n' "$quiet_save_block" | grep -Fq 'minLoadingMs: 0' || fail 'quiet metadata save can retain the save loader hold'
metadata_save_block=$(sed -n '/const saveResult = (typeof window.parent.MVM_save_quiet/,/if (saveResult === false)/p' "$UI_FILE")
printf '%s\n' "$metadata_save_block" | grep -Fq 'minLoadingMs:0' || fail 'metadata save fallback can retain the save loader hold'
grep -Fq 'minLoadingMs: 0' "$UI_FILE" || fail 'metadata caller does not explicitly suppress parent loader hold'
! sed -n '/"macclientmeta_vlanmgr": {/,/^[[:space:]]*},/p' "$MERV_BASE/www/settings/loading_actions.json" | grep -Fq '"frontend_owned": true' || fail 'metadata action suppresses backend progress updates'
grep -Fq "MerVLANLoading.start('macclientmeta_vlanmgr', 'Saving Client Metadata'" "$UI_FILE" || fail 'metadata loading header does not identify the save phase'
grep -Fq "metadataLoadingTask.setLabel('Applying Client Metadata');" "$UI_FILE" || fail 'metadata loading header does not identify the apply phase'
grep -Fq "metadataLoadingTask.phase('Starting client metadata apply...', 58);" "$UI_FILE" || fail 'metadata apply phase does not begin after settings persistence'
! grep -Fq "metadataLoadingTask.phase('Refreshing client inventory...', 84);" "$UI_FILE" || fail 'metadata loading regresses before the worker begins'
grep -Fq 'setLabel: label => setTaskLabel(token, label),' "$UI_FILE" || fail 'loading task cannot update its phase label'
grep -Fq '"macclientmeta_vlanmgr" "Applying Client Metadata"' "$WORKER_FILE" || fail 'metadata worker overwrites the apply-phase loading header'

printf 'METADATA_TOOLTIPS_CONTRACT_OK\n'
