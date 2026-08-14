#!/bin/sh
#
# Focused service-settings and page-load client-refresh contract test.
#
# This is a source contract test for browser-owned settings serialization and
# the structured General migration used by save_settings.sh.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
export MERV_BASE

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

SETTINGS_FILE="$MERV_BASE/settings/settings.json"
UI_FILE="$MERV_BASE/www/index.html"
SAVE_FILE="$MERV_BASE/functions/save_settings.sh"
JSON_FILE="$MERV_BASE/settings/lib_json.sh"

grep -q '"AUTO_SYNC_SETTINGS": "1"' "$SETTINGS_FILE" || fail 'settings.json AUTO_SYNC_SETTINGS default missing'
grep -q '"HTML_CLIENT_REFRESH_MINUTES": "30"' "$SETTINGS_FILE" || fail 'settings.json refresh default missing'

grep -q "key: 'AUTO_SYNC_SETTINGS'" "$UI_FILE" || fail 'AUTO_SYNC_SETTINGS modal definition missing'
grep -q "key: 'HTML_CLIENT_REFRESH_MINUTES'" "$UI_FILE" || fail 'HTML_CLIENT_REFRESH_MINUTES modal definition missing'
grep -q 'id="svcClientRefreshSelect"' "$UI_FILE" || fail 'client refresh modal control missing'
grep -q '<option value="0">OFF</option>' "$UI_FILE" || fail 'OFF refresh option missing'
grep -q '<option value="30">30m</option>' "$UI_FILE" || fail '30m refresh option missing'
grep -q 'CLIENTS_AUTO_REFRESH_DEFAULT_MINUTES = 30' "$UI_FILE" || fail 'page-load refresh default is not 30'
grep -q 'CLIENTS_AUTO_REFRESH_MINUTES_MIN = 0' "$UI_FILE" || fail 'page-load refresh does not permit zero'
grep -q 'if (cooldownMs <= 0) return false;' "$UI_FILE" || fail 'OFF refresh gate missing'
grep -q 'clientGeneratedMs(snapshot)' "$UI_FILE" || fail 'router cache freshness gate missing'
grep -q 'canAutoRefreshClients(cached)' "$UI_FILE" || fail 'page-load does not use shared client cache freshness'
! grep -q 'sessionStorage.getItem(CLIENTS_AUTO_REFRESH_KEY)' "$UI_FILE" || fail 'page-load refresh still uses per-tab session storage'
grep -q 'AUTO_SYNC_SETTINGS|HTML_CLIENT_REFRESH_MINUTES' "$UI_FILE" || fail 'service setting allowlist missing new keys'
grep -q 'source\[`NODE\${i}`\] ?? source\[`NODE\${i}_IP`\]' "$UI_FILE" || fail 'structured node prerequisite detection missing'
grep -q 'flat.SSH_KEYS_INSTALLED = stringOrDefault(ssh.SSH_KEYS_INSTALLED, "0")' "$UI_FILE" || fail 'structured SSH prerequisite mapping missing'

grep -q 'seed_general_setting_from_normal_kv' "$SAVE_FILE" || fail 'General settings migration helper missing'
grep -q 'json_set_section_value "General"' "$SAVE_FILE" || fail 'General settings are not migrated into the General section'
grep -q 'json_get_section_value "Nodes" "NODE\${_n_idx}"' "$SAVE_FILE" || fail 'backend structured node discovery missing'
grep -q '\[ -n "\$_nodes_configured" \]' "$SAVE_FILE" || fail 'backend no-node auto-sync guard missing'
grep -q 'merv_settings_node_sync_digest' "$JSON_FILE" || fail 'node-relevant settings digest helper missing'
grep -q 'only main-router/WebUI-local settings changed' "$SAVE_FILE" || fail 'local-only save skip path missing'
grep -q '_save_node_sync_required' "$SAVE_FILE" || fail 'save path does not gate node sync on node-relevant changes'
grep -q 'Node settings auto-sync queued after local save' "$SAVE_FILE" || fail 'token-backed Save does not defer node sync'
grep -q 'node_sync":"pending"' "$SAVE_FILE" || fail 'deferred node-sync acknowledgement missing'
grep -q 'queueAutomaticNodeSettingsSync' "$UI_FILE" || fail 'Save/APMO shared node-sync queue helper missing'
grep -q 'loadingTask.completion' "$UI_FILE" || fail 'automatic node sync does not wait for explicit loading completion'
grep -q 'MerVLANLoading.close();' "$UI_FILE" || fail 'Save loader is not released before automatic node sync'
! grep -q 'waitForMerVLANLoadingIdle' "$UI_FILE" || fail 'automatic node sync still relies on mutable loading active state'
grep -q 'syncsettings_vlanmgr: {' "$UI_FILE" || fail 'settings-only loading fallback missing'
grep -q 'Syncing settings to node(s)...' "$UI_FILE" || fail 'settings-only UI transition label missing'
grep -q 'Syncing settings to node(s)...' "$MERV_BASE/www/settings/loading_actions.json" || fail 'settings-only loading action label missing'
grep -q 'checkNodes: false' "$UI_FILE" || fail 'Save follow-up can be suppressed by stale node cache'
! grep -q 'window.setTimeout(() => { scheduleSshTrustProbe().catch(() => {}); }, 650);' "$UI_FILE" || fail 'unconditional post-save SSH probe still present'

# Save must release its terminal loading task before starting the distinct
# settings-only node-sync action. The parent must never show ASUS loading while
# MerVLAN owns Save loading.
SAVE_BLOCK=$(sed -n '/async function uploadSettingsAndSave/,/^[[:space:]]*return result;[[:space:]]*$/p' "$UI_FILE")
line_of() { printf '%s\n' "$SAVE_BLOCK" | grep -n -F -- "$1" | head -n 1 | cut -d: -f1; }
line_of_last() { printf '%s\n' "$SAVE_BLOCK" | grep -n -F -- "$1" | tail -n 1 | cut -d: -f1; }
complete_line=$(line_of 'loadingTask.complete(saveCompletionMessage);')
await_line=$(line_of 'if (loadingTask.completion) await loadingTask.completion;')
close_line=$(line_of "if (typeof MerVLANLoading !== 'undefined') MerVLANLoading.close();")
pending_guard_line=$(line_of_last "if (nodeSyncStatus === 'pending') {")
sync_line=$(line_of 'const queued = await queueAutomaticNodeSettingsSync({ announce: false, checkNodes: false });')
[ -n "$complete_line" ] && [ -n "$await_line" ] && [ -n "$close_line" ] && [ -n "$pending_guard_line" ] && [ -n "$sync_line" ] || fail 'Save-to-node-sync lifecycle markers missing'
[ "$complete_line" -lt "$await_line" ] && [ "$await_line" -lt "$close_line" ] && [ "$close_line" -lt "$pending_guard_line" ] && [ "$pending_guard_line" -lt "$sync_line" ] || fail 'Save loader is not released before pending node sync'
grep -Fq '? { loading: false, skipRefresh: true, waitSec: 0, minLoadingMs: 0 }' "$UI_FILE" || fail 'MerVLAN-owned Save omits minLoadingMs zero'
grep -Fq ': { loading: false, skipRefresh: true, waitSec: 0, minLoadingMs: 0 }' "$UI_FILE" || fail 'loading:false Save path omits minLoadingMs zero'

printf 'SERVICE_SETTINGS_CONTRACT_OK\n'
