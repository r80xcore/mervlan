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
for general_key in BOOT_ENABLED PAUSE ENABLE_STP DRY_RUN EXPERIMENTAL ENABLE_NATIVE_SSID AUTO_SYNC_SETTINGS HTML_CLIENT_REFRESH_MINUTES; do
    grep -Fq "$general_key" "$SAVE_FILE" || fail "General settings migration omits $general_key"
done

# Exercise the production structured-General writer with a scoped Settings
# payload.  This prevents a modal control from being accepted by the browser
# yet silently remaining at its old value in settings.json.
GENERAL_SEED_BLOCK=$(sed -n '/^save_candidate_is_empty_object() {/,/^# WAN Native values are normal-scope settings/p' "$SAVE_FILE")
[ -n "$GENERAL_SEED_BLOCK" ] || fail 'could not extract General settings writer'
GENERAL_SEED_ROOT="${TMPDIR:-/tmp}/mervlan-service-general.$$"
trap 'rm -rf "$GENERAL_SEED_ROOT"' 0 1 2 3 15
mkdir -p "$GENERAL_SEED_ROOT"
TMP_SORTED="$GENERAL_SEED_ROOT/settings.kv"
_save_candidate="$GENERAL_SEED_ROOT/settings.json"
MERV_IDENTITY_NONCE=service-general
SAVE_SCOPE=normal
printf '%s\n' \
    '{' \
    '  "General": {' \
    '    "_description": "Global addon flags and behavior toggles",' \
    '    "BOOT_ENABLED": "0",' \
    '    "PAUSE": "off",' \
    '    "ENABLE_STP": "0",' \
    '    "DRY_RUN": "yes",' \
    '    "EXPERIMENTAL": "0",' \
    '    "ENABLE_NATIVE_SSID": "0",' \
    '    "AUTO_SYNC_SETTINGS": "1",' \
    '    "HTML_CLIENT_REFRESH_MINUTES": "30"' \
    '  }' \
    '}' > "$_save_candidate"
{
    printf '%s\t%s\n' AUTO_SYNC_SETTINGS 0
    printf '%s\t%s\n' BOOT_ENABLED 1
    printf '%s\t%s\n' DRY_RUN no
    printf '%s\t%s\n' ENABLE_NATIVE_SSID 1
    printf '%s\t%s\n' ENABLE_STP 1
    printf '%s\t%s\n' EXPERIMENTAL 1
    printf '%s\t%s\n' HTML_CLIENT_REFRESH_MINUTES 15
    printf '%s\t%s\n' PAUSE on
} > "$TMP_SORTED"
. "$MERV_BASE/settings/lib_json.sh"
eval "$GENERAL_SEED_BLOCK"
for general_expectation in \
    'AUTO_SYNC_SETTINGS 0' 'BOOT_ENABLED 1' 'DRY_RUN no' \
    'ENABLE_NATIVE_SSID 1' 'ENABLE_STP 1' 'EXPERIMENTAL 1' \
    'HTML_CLIENT_REFRESH_MINUTES 15' 'PAUSE on'; do
    set -- $general_expectation
    [ "$(json_get_section_value General "$1" "$_save_candidate")" = "$2" ] || \
        fail "scoped General Save did not persist $1"
done
grep -q 'json_get_section_value "Nodes" "NODE\${_n_idx}"' "$SAVE_FILE" || fail 'backend structured node discovery missing'
grep -q '\[ -n "\$_nodes_configured" \]' "$SAVE_FILE" || fail 'backend no-node auto-sync guard missing'
grep -q 'merv_settings_node_sync_digest' "$JSON_FILE" || fail 'node-relevant settings digest helper missing'
grep -q 'only main-router/WebUI-local settings changed' "$SAVE_FILE" || fail 'local-only save skip path missing'
grep -q '_save_node_sync_required' "$SAVE_FILE" || fail 'save path does not gate node sync on node-relevant changes'
grep -q 'Node settings auto-sync queued after local save' "$SAVE_FILE" || fail 'token-backed Save does not defer node sync'
grep -Fq '\"node_sync\":\"$_save_node_sync_status\"' "$SAVE_FILE" || fail 'Save result does not serialize authoritative node-sync status'
grep -Fq '_save_node_sync_status" = "pending"' "$SAVE_FILE" || fail 'pending durable state is not explicit'
grep -Fq '_save_node_sync_status" = "paused"' "$SAVE_FILE" || fail 'paused durable state is not explicit'
grep -Fq '_save_node_sync_status" = "deferred"' "$SAVE_FILE" || fail 'deferred durable state is not explicit'
grep -q 'queueAutomaticNodeSettingsSync' "$UI_FILE" || fail 'Save/APMO shared node-sync queue helper missing'
grep -q 'loadingTask.completion' "$UI_FILE" || fail 'automatic node sync does not wait for explicit loading completion'
grep -q 'MerVLANLoading.close();' "$UI_FILE" || fail 'Save loader is not released before automatic node sync'
! grep -q 'waitForMerVLANLoadingIdle' "$UI_FILE" || fail 'automatic node sync still relies on mutable loading active state'
grep -q 'syncsettings_vlanmgr: {' "$UI_FILE" || fail 'settings-only loading fallback missing'
grep -q 'Auto-sync Settings to Node(s)' "$UI_FILE" || fail 'automatic settings-sync UI label missing'
grep -q 'Auto-sync Settings to Node(s)' "$MERV_BASE/www/settings/loading_actions.json" || fail 'automatic settings-sync loading action label missing'
grep -Fq "Auto-sync settings to node(s) complete." "$UI_FILE" || fail 'automatic settings-sync completion message missing'
grep -Fq 'automatic: true,' "$UI_FILE" || fail 'Save does not identify automatic settings-only synchronization'
grep -Fq 'announce: false,' "$UI_FILE" || fail 'automatic settings-only synchronization does not suppress duplicate CLI announcements'
grep -Fq 'checkNodes: false,' "$UI_FILE" || fail 'Save follow-up can be suppressed by stale node cache'
! grep -q 'window.setTimeout(() => { scheduleSshTrustProbe().catch(() => {}); }, 650);' "$UI_FILE" || fail 'unconditional post-save SSH probe still present'

# Settings-modal changes are one scoped MAIN save. All changed pure settings
# are serialized in that one payload, and its proven post-save path submits a
# single settings-only accelerator when the durable result is pending.
grep -q "const out = { vlanmgr_SAVE_SCOPE: 'normal' };" "$UI_FILE" || fail 'service settings payload is not a single normal-scope Save'
grep -q "if (nodeSyncStatus === 'pending')" "$UI_FILE" || fail 'Save does not start the pending settings-only accelerator'
grep -Fq 'SETTINGS_RECONCILE_STATUS: "tmp/results/settings_reconcile.json"' "$UI_FILE" || fail 'Settings modal has no backend reconciliation status path'
grep -Fq 'function observeServiceConvergence(generation = 0, options = {})' "$UI_FILE" || fail 'Settings modal has no convergence observer'
grep -Fq 'function adoptServiceConvergenceGeneration(expectedGeneration, status)' "$UI_FILE" || fail 'observer cannot adopt a live convergence generation on reopen'
grep -Fq 'function describeServiceSyncProgress(status)' "$UI_FILE" || fail 'Settings modal cannot mirror real loader progress'
grep -Fq 'function setServiceConvergenceStatus(message, state = ' "$UI_FILE" || fail 'Settings modal has no two-row convergence renderer'
grep -Fq 'id="svcTransactionSettings"' "$UI_FILE" || fail 'Settings transaction row missing'
grep -Fq 'id="svcTransactionAutoSync"' "$UI_FILE" || fail 'Auto-sync transaction row missing'
grep -Fq '.svc-transaction-row.is-info' "$UI_FILE" || fail 'neutral in-progress Settings styling missing'
grep -Fq "case 'pending':" "$UI_FILE" || fail 'pending convergence state missing'
grep -Fq "return { terminal: false, state: 'info', message: 'Synchronization is pending…' };" "$UI_FILE" || fail 'pending convergence is still presented as a warning'
grep -Fq "return { terminal: false, state: 'info', message: 'Synchronizing settings…' };" "$UI_FILE" || fail 'running convergence is still presented as a warning'
grep -Fq "return { terminal: true, state: 'success', message: 'Settings synchronized ✓' };" "$UI_FILE" || fail 'verified convergence lacks explicit green completion'
grep -Fq 'function normalizeSettingsSaveAcknowledgement(verifiedAck)' "$UI_FILE" || fail 'Save acknowledgement does not preserve structured partial results'
grep -Fq 'function unwrapVerifiedActionAcknowledgement(verifiedAck)' "$UI_FILE" || fail 'Save acknowledgement does not define the verified-wrapper boundary'
grep -Fq 'const result = acknowledgement ? acknowledgement.result : {};' "$UI_FILE" || fail 'Save acknowledgement does not unwrap the action payload explicitly'
grep -Fq 'wrapperStatus !== acknowledgementStatus' "$UI_FILE" || fail 'Save acknowledgement accepts mismatched verified-wrapper state'
grep -Fq "label: 'Status'" "$UI_FILE" || fail 'generic Settings transaction row is not labeled Status'
grep -Fq "label: 'MAIN'" "$UI_FILE" || fail 'confirmed persistence row is not labeled MAIN'
grep -Fq 'node_sync_generation' "$SAVE_FILE" || fail 'Save acknowledgement does not expose a bounded convergence generation'
grep -Fq 'Browser auto-sync accelerator did not start; observing backend convergence.' "$UI_FILE" || fail 'browser/backend convergence race can still be reported as failure'

# This VM test invokes production pure transaction/result/observer helpers;
# static source presence alone cannot prove the Settings modal preserves the
# distinction between MAIN persistence and background node convergence.
if command -v "${NODE_BIN:-node}" >/dev/null 2>&1; then
    "${NODE_BIN:-node}" "$MERV_BASE/dev-tools/tests/local/service_settings_behavior_test.mjs" || fail 'behavioral Settings transaction/convergence test failed'
else
    # The browser-behavior harness needs Node. Keep this an explicit capability
    # skip so router/POSIX-only installations do not turn an unavailable local
    # runtime into a false product failure.
    printf 'SKIP: Node runtime unavailable; run service_settings_behavior_test.mjs with NODE_BIN when validating browser behavior\n'
fi
! grep -q 'deferNodeSync' "$UI_FILE" || fail 'service settings uses an unproven deferred node-sync path'
grep -Fq 'return Promise.resolve(false);' "$UI_FILE" || fail 'duplicate UI actions do not report an explicit refusal'
grep -Fq "const syncAction = 'syncsettings_vlanmgr';" "$UI_FILE" || fail 'settings-only sync action identity is not explicit'
grep -Fq 'Recovering a stale local settings-sync action lock.' "$UI_FILE" || fail 'settings-only sync does not recover a stale local lock'
grep -Fq 'if (queued !== true)' "$UI_FILE" || fail 'Save treats a non-submitted settings-only sync as queued'
grep -Fq 'onProgress: mirrorProgress' "$UI_FILE" || fail 'automatic settings sync does not subscribe to real loader progress'
grep -Fq 'embedded: options.embedded === true' "$UI_FILE" || fail 'MerVLANLoading has no embedded-task mode'
grep -Fq 'loadingOptions: { progressBacked: true, embedded: automatic, onProgress: mirrorProgress }' "$UI_FILE" || fail 'automatic Settings sync is not embedded in the Settings modal'
grep -Fq 'subscribeProgress: listener => subscribeTaskProgress(token, listener)' "$UI_FILE" || fail 'MerVLANLoading exposes no reusable progress subscriber surface'
grep -Fq 'observeServiceConvergence(convergenceGeneration);' "$UI_FILE" || fail 'loader terminal does not wake the durable convergence observer'
grep -Fq 'function describeServiceConvergenceSettings(publicFailure = false)' "$UI_FILE" || fail 'Settings row does not retain public publication warning semantics'
grep -Fq "publicFailure: publicSettings === 'failed'" "$UI_FILE" || fail 'automatic node sync does not retain the public publication outcome'
grep -Fq 'publicFailure: saveSummary.publicFailure' "$UI_FILE" || fail 'durable observer does not retain the public publication outcome'

# A regular settings-only convergence is a real control-plane transfer when
# the saved configuration enables Dry Run. An explicit CLI --dry-run remains
# the simulation request.
SYNC_FILE="$MERV_BASE/functions/sync_nodes.sh"
EVENT_HANDLER_FILE="$MERV_BASE/functions/service-event-handler.sh"
grep -q 'SETTINGS_CONTROL_PLANE=0' "$SYNC_FILE" || fail 'settings control-plane state missing'
grep -Fq '[ "$SETTINGS_ONLY" -eq 1 ] && [ "$DRY_RUN_FORCED" -eq 0 ] && [ "$DRY_RUN" = "yes" ]' "$SYNC_FILE" || fail 'settings-only Dry Run convergence gate missing'
grep -q 'SETTINGS_CONTROL_PLANE=1' "$SYNC_FILE" || fail 'settings-only control-plane activation missing'
grep -q 'Settings-only control-plane mode: synchronizing settings despite configured Dry Run' "$SYNC_FILE" || fail 'control-plane synchronization log missing'

# A browser is only an accelerator. After a successful Save has released its
# authenticated dispatcher ownership, the existing backend due worker must be
# kicked with no inherited parent lock/progress context. This keeps automatic
# convergence live even when an ASUS/mobile hidden-frame transport is delayed.
grep -Fq 'handler: settings reconciliation kick scheduled after save' "$EVENT_HANDLER_FILE" || fail 'post-Save backend reconciliation kick missing'
KICK_BLOCK=$(sed -n '/# A successful WebUI Save may have published a durable node-settings/,/return "\$_se_script_rc"/p' "$EVENT_HANDLER_FILE")
printf '%s\n' "$KICK_BLOCK" | grep -Fq 'save_vlanmgr|save_vlanmgr_pgt_*) _se_successful_save=1' || fail 'backend reconciliation kick does not recognize tokenized WebUI Save'
printf '%s\n' "$KICK_BLOCK" | grep -Fq '[ "$_se_successful_save" -eq 1 ]' || fail 'backend reconciliation kick is not restricted to successful Save'
printf '%s\n' "$KICK_BLOCK" | grep -Fq '[ "$_se_script_rc" -eq 0 ]' || fail 'backend reconciliation kick can follow a failed Save'
printf '%s\n' "$KICK_BLOCK" | grep -Fq '[ "$_se_release_rc" -eq 0 ]' || fail 'backend reconciliation kick can bypass failed lock cleanup'
printf '%s\n' "$KICK_BLOCK" | grep -Fq 'unset MERV_ACTION_LOCK_PARENT_HELD' || fail 'backend reconciliation kick inherits stale parent owner context'
printf '%s\n' "$KICK_BLOCK" | grep -Fq 'MERV_PROGRESS_TOKEN MERV_ACTION_ACK_STAGE' || fail 'backend reconciliation kick inherits Save progress context'
printf '%s\n' "$KICK_BLOCK" | grep -Fq 'settings_reconcile.sh" due' || fail 'backend reconciliation kick does not use the due gate'

# Tokenized dispatcher names are internal transport spellings.  A refused
# browser request must still publish its terminal acknowledgement under the
# public base action the browser verifies, otherwise an action-lock refusal is
# incorrectly reported as a later settings-value timeout.
grep -Fq '*_pgt_*) _se_ack_action="${_se_key%%_pgt_*}"' "$EVENT_HANDLER_FILE" || fail 'tokenized dispatcher action is not normalized for acknowledgements'
grep -Fq 'action_ack_lock_failure "$MERV_PROGRESS_TOKEN" "$_se_ack_action"' "$EVENT_HANDLER_FILE" || fail 'lock refusal acknowledgement uses tokenized internal action name'

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
sync_line=$(line_of 'const queued = await queueAutomaticNodeSettingsSync({')
[ -z "$(printf '%s\n' "$SAVE_BLOCK" | grep -F "await settleCorrelatedTransport(saveSubmission, 'Settings save');")" ] || fail 'settings-only sync is still blocked on hidden-frame transport completion'
transport_observe_line=$(line_of "void settleCorrelatedTransport(saveSubmission, 'Settings save').catch(error => {")
[ -n "$complete_line" ] && [ -n "$await_line" ] && [ -n "$close_line" ] && [ -n "$pending_guard_line" ] && [ -n "$sync_line" ] || fail 'Save-to-node-sync lifecycle markers missing'
printf '%s\n' "$SAVE_BLOCK" | grep -Fq 'convergenceGeneration: nodeSyncGeneration' || fail 'Save does not correlate loader progress with its durable generation'
[ -n "$transport_observe_line" ] && [ "$transport_observe_line" -lt "$sync_line" ] || fail 'settings transport is not observed without blocking node sync'
[ "$complete_line" -lt "$await_line" ] && [ "$await_line" -lt "$close_line" ] && [ "$close_line" -lt "$pending_guard_line" ] && [ "$pending_guard_line" -lt "$sync_line" ] || fail 'Save loader is not released before pending node sync'
ack_wait_line=$(line_of 'const saveAck = await waitForVerifiedActionResult(')
settings_match_line=$(line_of 'const ok = await waitForSettingsToMatch(expectedManaged, {')
[ -n "$ack_wait_line" ] && [ -n "$settings_match_line" ] && [ "$ack_wait_line" -lt "$settings_match_line" ] || fail 'Save can poll public settings before receiving a terminal router acknowledgement'
grep -Fq '? { loading: false, skipRefresh: true, waitSec: 0, minLoadingMs: 0 }' "$UI_FILE" || fail 'MerVLAN-owned Save omits minLoadingMs zero'
# The no-loader branch is formatted as a nested ternary.  Assert the branch
# semantics instead of relying on the colon sharing the object-literal line.
NO_LOADING_BLOCK=$(sed -n '/loadingOverride === false/,/: { skipRefresh: true, waitSec: 0 }/p' "$UI_FILE")
printf '%s\n' "$NO_LOADING_BLOCK" | grep -Fq 'loading: false, skipRefresh: true, waitSec: 0, minLoadingMs: 0' || fail 'loading:false Save path omits minLoadingMs zero'

printf 'SERVICE_SETTINGS_CONTRACT_OK\n'
