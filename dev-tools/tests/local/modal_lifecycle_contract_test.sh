#!/bin/sh
# Browser-owned modal lifecycle source contract. This does not contact devices.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

function_block() {
  sed -n "/^function $1(/,/^}/p" "$UI_FILE"
}

ssh_open=$(function_block showSSHKeyModal)
ssh_close=$(function_block closeSSHKeyModal)
ssh_load=$(function_block loadSshKeyIntoModal)
trust_refresh=$(function_block refreshSshTrustRegistry)
trust_enroll_ack=$(sed -n "/if (active.action === 'sshtrustenroll_vlanmgr'/,/if (status === 'ssh_trust_required')/p" "$UI_FILE")
trust_revoke=$(function_block revokeSshTrustNode)

printf '%s\n' "$ssh_open" | grep -Fq "modal.style.display = 'flex';" || fail 'SSH modal is not opened synchronously'
printf '%s\n' "$ssh_open" | grep -Fq 'loadSshKeyIntoModal();' || fail 'SSH modal does not start its asynchronous key load'
! printf '%s\n' "$ssh_open" | grep -Fq 'refreshSshTrustRegistry' || fail 'SSH key modal still requests trust status on open'
printf '%s\n' "$ssh_load" | grep -Fq "setSshKeyLoadState('loading', 'Loading SSH key...')" || fail 'SSH key loading state missing'
printf '%s\n' "$ssh_load" | grep -Fq 'if (sshKeyLoadPromise) return sshKeyLoadPromise;' || fail 'SSH key load is not single-flight'
printf '%s\n' "$ssh_load" | grep -Fq 'if (token !== sshKeyLoadSequence) return false;' || fail 'SSH key stale-result guard missing'
! printf '%s\n' "$ssh_close" | grep -Fq 'sshKeyLoadPromise = null' || fail 'SSH close clears in-flight key work'
! printf '%s\n' "$ssh_close" | grep -Fq 'sshKeyLoadSequence++' || fail 'SSH close invalidates reusable key result'
grep -Fq 'return loadSshKeyIntoModal({ force: true });' "$UI_FILE" || fail 'explicit SSH Load does not force refresh'

printf '%s\n' "$trust_refresh" | grep -Fq 'if (sshTrustRegistryRequestPromise) return sshTrustRegistryRequestPromise;' || fail 'trust status is not single-flight'
printf '%s\n' "$trust_refresh" | grep -Fq "setSshTrustRegistryMessage('Loading router-owned SSH trust status" || fail 'trust loading message missing'
printf '%s\n' "$trust_refresh" | grep -Fq 'setSshTrustRegistryMessage' || fail 'trust terminal messages missing'
[ "$(printf '%s\n' "$trust_refresh" | grep -Fc "MVM_trigger('sshtruststatus_vlanmgr'")" -eq 1 ] || fail 'trust refresh submits an unexpected number of backend actions'
grep -Fq "if (trustTab) refreshSshTrustRegistry();" "$UI_FILE" || fail 'Trusted Devices tab does not own its status load'
grep -Fq "['sshTrustRefreshBtn', 'sshTrustSelectAllBtn', 'sshTrustClearSelectionBtn', 'sshTrustProbeBtn']" "$UI_FILE" || fail 'trust loading controls are not guarded'
printf '%s\n' "$trust_enroll_ack" | grep -Fq 'window.setTimeout(() => submitSshTrustResume(resumeId), 550);' || fail 'stored trust actions no longer resume'
printf '%s\n' "$trust_enroll_ack" | grep -Fq 'clearSshTrustDecision();' || fail 'direct trust enrollment does not clear its decision UI'
printf '%s\n' "$trust_enroll_ack" | grep -Fq "if (typeof refreshSshTrustRegistry === 'function') refreshSshTrustRegistry();" || fail 'direct trust enrollment does not refresh the authoritative registry'
grep -Fq 'return `Decision expires in ${minutes}:${remainder}`;' "$UI_FILE" || fail 'trust decision expiry is still labelled as a cooldown'
printf '%s\n' "$trust_revoke" | grep -Fq "node_id: node && typeof node === 'object' ? node.nodeId : ''" || fail 'trusted-row revoke loses the normalized node identifier'
printf '%s\n' "$trust_revoke" | grep -Fq "MVM_triggerVerified('sshtrustrevoke_vlanmgr'" || fail 'trusted-row revoke no longer dispatches through the verified parent action'

settings_open=$(sed -n '/^    async function showServiceSettingsModal()/,/^    function closeServiceSettingsModal()/p' "$UI_FILE")
settings_loader=$(sed -n '/^    async function loadSettings(opts = {}){/,/^    function toNone/p' "$UI_FILE")
printf '%s\n' "$settings_open" | grep -Fq "modal.style.display = 'block';" || fail 'Settings modal is not opened synchronously'
printf '%s\n' "$settings_open" | grep -Fq "setServiceSettingsLoadState('loading', 'Loading settings...')" || fail 'Settings loading state missing'
printf '%s\n' "$settings_open" | grep -Fq "if (_svcSettingsLoadState === 'loading' && _svcSettingsLoadPromise) return _svcSettingsLoadPromise;" || fail 'Settings modal load is not single-flight'
printf '%s\n' "$settings_open" | grep -Fq 'if (loadToken !== _svcSettingsLoadSequence || modal.style.display ===' || fail 'Settings stale-result guard missing'
printf '%s\n' "$settings_open" | grep -Fq "shouldCommit: () => loadToken === _svcSettingsLoadSequence && modal.style.display !== 'none'" || fail 'Settings loader can publish a stale modal request'
printf '%s\n' "$settings_loader" | grep -Fq 'const { deferFill = false, shouldCommit = null } = opts;' || fail 'settings loader has no publication guard'
[ "$(printf '%s\n' "$settings_loader" | grep -Fc 'if (!mayCommit()) return false;')" -ge 3 ] || fail 'settings loader does not guard stale success and failure results'
[ "$(printf '%s\n' "$settings_open" | grep -Fc "const overlay = document.getElementById('leftPanelOverlay');")" -eq 1 ] || fail 'Settings modal redeclares its overlay binding'
! grep -Fq 'settingsLoadInFlight' "$UI_FILE" || fail 'modal settings request leaks into normal settings loads'
grep -Fq "_svcSettingsLoadState !== 'ready'" "$UI_FILE" || fail 'Settings controls are not gated on load completion'
grep -Fq 'serviceSettingsAutoSyncPrerequisites(CURRENT_SETTINGS_CACHE).ready' "$UI_FILE" || fail 'Settings busy state can overwrite Auto-sync prerequisites'
grep -Fq 'stopServiceConvergenceObservation();' "$UI_FILE" || fail 'Settings modal close does not stop its read-only convergence observer'
grep -Fq 'observeServiceConvergence();' "$UI_FILE" || fail 'Settings modal open does not rehydrate convergence observation'

printf 'MODAL_LIFECYCLE_CONTRACT_OK\n'
