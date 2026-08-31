#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
UI="$ROOT/www/index.html"
CHANGELOG="$ROOT/changelog.txt"
ASP="$ROOT/mervlan.asp"
HANDLER="$ROOT/functions/service-event-handler.sh"
SELFTEST="$ROOT/dev-tools/tests/router/mervlan_selftest.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require() { grep -Fq "$2" "$1" || fail "$3"; }
require_re() { grep -Eq "$2" "$1" || fail "$3"; }

# The test is intentionally static/read-only.  Keep every temporary artifact
# in a unique task-scoped directory, and remove that directory on every exit.
TMP_PARENT="$ROOT/.tmp/DT-COR-TEST-1"
mkdir -p "$TMP_PARENT"
TMP_ROOT=$(mktemp -d "$TMP_PARENT/run.XXXXXX") || {
  rmdir "$TMP_PARENT" 2>/dev/null || :
  fail 'could not create task-scoped temporary directory'
}
cleanup() {
  rm -rf "$TMP_ROOT" 2>/dev/null || :
  rmdir "$TMP_PARENT" 2>/dev/null || :
  rmdir "$ROOT/.tmp" 2>/dev/null || :
}
trap cleanup EXIT HUP INT TERM

# Developer Tools is a strict development-build gate on both sides of the
# transport.  A stable/release marker must not expose or authorize the modal.
index_version=$(sed -n 's/^[[:space:]]*<!--[[:space:]]*index\.html version="\([^"]*\)"[[:space:]]*-->[[:space:]]*$/\1/p' "$UI" | head -n 1 | tr -d '\r\n')
[ "$index_version" = "0.53.28-dev" ] || fail "unexpected installed index marker: ${index_version:-missing}"
changelog_version=$(sed -n '1{s/^[[:space:]]*mervlan[[:space:]]*v\([^[:space:]]*\).*/\1/p;q;}' "$CHANGELOG" | tr -d '\r\n')
[ "$changelog_version" = "0.53.28-dev" ] || fail "unexpected changelog version: ${changelog_version:-missing}"
require "$ROOT/functions/update_mervlan.sh" 'update_html_version()' 'updater index-version source missing'
require "$ROOT/functions/update_mervlan.sh" 'update_changelog_version()' 'updater changelog-version source missing'
require "$UI" 'version.endsWith("-dev")' 'frontend dev gate missing'
require "$UI" 'function isDeveloperToolsBuild()' 'frontend build gate helper missing'
require "$UI" 'return typeof version === "string" && version.endsWith("-dev");' 'frontend gate is not an exact -dev suffix check'
require "$HANDLER" '_dt_index_file="${MERV_BASE%/}/www/index.html"' 'backend gate does not read the installed index marker'
require "$HANDLER" '_dt_version_marker="$(sed -n' 'backend gate marker extraction missing'
require "$HANDLER" 'Developer Tools refused without -dev index marker' 'backend dev gate missing'
require "$HANDLER" '  *-dev) ;;' 'backend gate does not require a -dev suffix'
require "$ASP" 'devtools_vlanmgr_' 'narrow dev transport missing'

# The browser receives a text result envelope whose output body contains the
# read-only status lines emitted by the handler.  Exercise the body parser's
# aliases, guard text, and generation/pending fields (and not only the header).
require "$UI" 'function parseDeveloperToolsResult(raw)' 'result envelope parser missing'
require "$UI" 'function parseDeveloperStatusBody(result)' 'status-body parser missing'
require "$UI" 'const lines = String(result.output).replace(/\r/g, "").split("\n");' 'status-body line parsing missing'
require "$UI" 'const tokenPattern = /(?:^|\s)([A-Za-z][A-Za-z0-9_.-]*)=([^\s]+)/g;' 'status-body key/value parsing missing'
require "$UI" 'const guard = /\blive_test_guard=(.+)$/i.exec(line);' 'status-body guard text parsing missing'
require "$UI" 'snapshot\s+requested=([^\s]+)' 'status-body snapshot generation parsing missing'
require "$UI" 'collection\s+requested=([^\s]+)' 'status-body collection generation parsing missing'
require "$UI" 'Math.max(0, snapshotRequested - snapshotCompleted)' 'snapshot pending inference missing'
require "$UI" 'Math.max(0, collectionRequested - collectionCompleted)' 'collection pending inference missing'
require "$UI" 'parseDeveloperStatusBody(result);' 'snapshot rendering does not parse status body first'

# A Developer Tools round-trip must preserve unsaved service-setting controls
# while keeping the persisted baseline unchanged until the user explicitly
# applies it.  The fresh load establishes the baseline before restoration.
require "$UI" 'function captureDeveloperSettingsDraft()' 'settings draft capture missing'
require "$UI" '_developerToolsSettingsDraft = captureDeveloperSettingsDraft();' 'settings draft is not captured before opening tools'
require "$UI" 'const baseline = typeof _svcSnapshot !== "undefined" && _svcSnapshot' 'settings draft does not retain the persisted baseline'
require "$UI" 'function restoreDeveloperSettingsDraft()' 'settings draft restore missing'
require "$UI" 'if (typeof markSvcSettingsDirty === "function") markSvcSettingsDirty();' 'restored settings are not marked dirty'
require "$UI" 'if (applyBtn) applyBtn.disabled = true;' 'settings apply reset guard missing'
require "$UI" 'restoreDeveloperSettingsDraft();' 'settings draft is not restored after fresh load'
require "$UI" 'Do not copy values into hidden controls or CURRENT_SETTINGS_CACHE here.' 'settings round-trip may overwrite persisted cache'
require "$UI" 'onclick="closeDeveloperToolsModal()"' 'Developer Tools close button does not discard draft by default'
require "$UI" 'onclick="backToSettingsFromDeveloperTools()"' 'Developer Tools Back button missing'
back_fn=$(sed -n '/^[[:space:]]*function backToSettingsFromDeveloperTools()/,/^[[:space:]]*function setDeveloperToolsStatus/p' "$UI")
printf '%s\n' "$back_fn" | grep -Fq 'closeDeveloperToolsModal(false, true)' || fail 'Back does not preserve the settings draft'
printf '%s\n' "$back_fn" | grep -Fq 'showServiceSettingsModal();' || fail 'Back does not return to Settings'
close_fn=$(sed -n '/^[[:space:]]*function closeDeveloperToolsModal(/,/^[[:space:]]*function backToSettingsFromDeveloperTools/p' "$UI")
printf '%s\n' "$close_fn" | grep -Fq 'if (!preserveDraft) _developerToolsSettingsDraft = null;' || fail 'close/X path does not discard the settings draft'

# Status probes must report observed installation/runtime state, including
# missing/custom/disabled cases; optimistic constants are not a probe.
require "$HANDLER" '_dt_loader=missing' 'loader probe has no unknown baseline'
require "$HANDLER" 'if [ -f /jffs/scripts/services-start ]; then' 'loader probe does not inspect services-start'
require "$HANDLER" 'grep -Fq "${MERV_BASE%/}/functions/mervlan_boot_wrap.sh install" /jffs/scripts/services-start' 'loader probe does not verify the installed loader entry'
require "$HANDLER" 'grep -Fq "${MERV_BASE%/}/install.sh" /jffs/scripts/services-start' 'loader probe misses the installer entry'
require "$HANDLER" '_dt_service_event=missing' 'service-event probe has no unknown baseline'
require "$HANDLER" 'if [ -f /jffs/scripts/service-event ]; then' 'service-event probe does not inspect the installed hook'
require "$HANDLER" 'grep -Fq "service-event disabled" /jffs/scripts/service-event' 'service-event disabled state is not observed'
require "$HANDLER" 'grep -Fq "${MERV_BASE%/}/functions/service-event-handler.sh" /jffs/scripts/service-event' 'service-event probe does not verify the installed handler'
require "$HANDLER" "printf 'observation_worker=not-installed\\n'" 'missing observation worker state is not explicit'
require "$HANDLER" "printf 'live_test_guard=Not installed\\n'" 'missing live-test guard state is not explicit'
require "$HANDLER" '_dt_mac_state=unknown' 'MAC probe has no unknown baseline'
require "$HANDLER" '_dt_mac_listing="$(ebtables -t filter -L MERV_MAC 2>/dev/null)"' 'MAC probe does not inspect the canonical chain'
require "$HANDLER" '_dt_mac_rc=$?' 'MAC probe does not preserve command status'
require "$HANDLER" '_dt_mac_rule_count="$(printf' 'MAC probe rule count is not derived from observed listing'
require "$HANDLER" "grep -c '^-s '" 'MAC probe does not count source rules'
require "$HANDLER" '_dt_mac_state=on' 'MAC probe has no active state'
require "$HANDLER" '_dt_mac_state=off' 'MAC probe has no empty state'
require "$HANDLER" '/bin/sh "${MERV_BASE%/}/functions/post_apply_worker.sh" status 2>&1' 'observation status probe missing'
require "$HANDLER" '/bin/sh "${MERV_BASE%/}/dev-tools/safety/mervlan_live_test_guard.sh" status 2>&1' 'live-test guard status probe missing'

require "$HANDLER" 'devtools_vlanmgr_selftest_*_rid_*' 'backend selftest grammar missing'
require "$HANDLER" '*[!a-z0-9-]*|all' 'backend selftest validation missing'
require "$HANDLER" '/bin/sh "${MERV_BASE%/}/dev-tools/tests/router/mervlan_selftest.sh" "$_dt_case"' 'selftest must be one quoted argument'

# The cron observer is intentionally shared by status and post-action
# verification. Keep the helper single-purpose and used; a stale duplicate or
# an unreferenced cron helper would make displayed state unverifiable.
cron_helper_defs=$(grep -c '^devtools_cron_state()' "$HANDLER" || true)
cron_helper_refs=$(grep -c 'devtools_cron_state' "$HANDLER" || true)
[ "$cron_helper_defs" = 1 ] || fail "expected one cron observation helper, found $cron_helper_defs"
[ "$cron_helper_refs" -ge 3 ] || fail 'cron observation helper is unused by status/verification paths'

# The fast path must precede normal pause/lock setup and may write only the
# public tmpfs result/capture files.  It must never invoke lifecycle APIs or
# write saved settings/state.
fast_line=$(grep -n '^# DEVELOPER TOOLS FAST PATH' "$HANDLER" | head -n 1 | cut -d: -f1)
pause_line=$(grep -n '^# PAUSE GUARD' "$HANDLER" | head -n 1 | cut -d: -f1)
lock_line=$(grep -n '^# DEBOUNCE & LOCK SETUP' "$HANDLER" | head -n 1 | cut -d: -f1)
app_event_line=$(grep -n '^APP_EVENT=0$' "$HANDLER" | head -n 1 | cut -d: -f1)
router_line=$(grep -n '^# EVENT ROUTER' "$HANDLER" | head -n 1 | cut -d: -f1)
apply_dispatch_line=$(grep -n '^  apply_vlanmgr)' "$HANDLER" | head -n 1 | cut -d: -f1)
[ -n "$app_event_line" ] && [ "$app_event_line" -lt "$fast_line" ] || fail 'APP_EVENT classification no longer precedes the isolated path'
[ -n "$fast_line" ] && [ -n "$pause_line" ] && [ "$fast_line" -lt "$pause_line" ] || fail 'fast path is not before pause handling'
[ -n "$lock_line" ] && [ "$fast_line" -lt "$lock_line" ] || fail 'fast path is not before lifecycle lock setup'
[ -n "$router_line" ] && [ "$lock_line" -lt "$router_line" ] && [ "$router_line" -lt "$apply_dispatch_line" ] || fail 'normal APP_EVENT/lock dispatch boundary moved'
require "$HANDLER" 'APP_EVENT=1' 'normal APP_EVENT classification missing'
require "$HANDLER" 'apply_vlanmgr|apply_vlanmgr_pgt_*' 'normal apply action left APP_EVENT classification'
require "$HANDLER" 'if [ "$APP_EVENT" = "0" ]' 'router-native pause gate missing'
require "$HANDLER" 'apply_vlanmgr)' 'normal apply dispatch case missing'
require "$HANDLER" 'dispatch_if_executable "/jffs/addons/mervlan/functions/mervlan_manager.sh"' 'normal apply dispatch no longer uses lock helper'
block=$(sed -n '/^# DEVELOPER TOOLS FAST PATH/,/^# PAUSE GUARD/p' "$HANDLER")
[ -n "$block" ] || fail 'isolated fast-path block missing'
for forbidden in dispatch_if_executable merv_action_ merv_owner_lock action_ack action_ack_ merv_progress_ mervlan_manager.sh save_settings.sh sync_nodes.sh execute_nodes.sh update_mervlan.sh mervlan_recover.sh settings_reconcile.sh CURRENT_SETTINGS_CACHE; do
  printf '%s\n' "$block" | grep -Fq "$forbidden" && fail "isolated block references $forbidden"
done
printf '%s\n' "$block" | grep -Eq '>[[:space:]]*"?\$?(SETTINGS_FILE|CUSTOM_SETTINGS_FILE|.*settings\.json)' && fail 'isolated block writes persistent settings/state'

ui_cases=$(sed -n '/id="devToolsSelftestSelect"/,/<\/select>/s/.*<option value="\([a-z0-9-]*\)".*/\1/p' "$UI" | tr -d '\r')
test_cases=$(sed -n '/^run_one()/,/^}/s/^[[:space:]]*\([a-z0-9-]*\)).*/\1/p' "$SELFTEST" | tr -d '\r')
[ -n "$ui_cases" ] || fail 'no frontend selftests found'
printf '%s\n' "$ui_cases" | grep -Fxq all && fail 'frontend exposes all'
printf '%s\n' "$test_cases" | grep -Fxq all && fail 'router dispatcher exposes all as a focused case'
ui_count=$(printf '%s\n' "$ui_cases" | sed '/^$/d' | wc -l | tr -d ' ')
ui_unique=$(printf '%s\n' "$ui_cases" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
test_count=$(printf '%s\n' "$test_cases" | sed '/^$/d' | wc -l | tr -d ' ')
test_unique=$(printf '%s\n' "$test_cases" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')
[ "$ui_count" = "$ui_unique" ] || fail 'frontend selftest dropdown contains duplicate cases'
[ "$test_count" = "$test_unique" ] || fail 'router selftest dispatcher contains duplicate cases'
for ui_case in $ui_cases; do
  printf '%s\n' "$test_cases" | grep -Fxq "$ui_case" || fail "frontend case absent from dispatcher: $ui_case"
done
for test_case in $test_cases; do
  printf '%s\n' "$ui_cases" | grep -Fxq "$test_case" || fail "dispatcher case absent from frontend: $test_case"
done

# If a JavaScript runtime is available, run a small behavior check against the
# actual parser.  The current supported runner may not provide Node; in that
# case retain an explicit, truthful skip in the gate output.
if command -v node >/dev/null 2>&1; then
  node - "$UI" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const file = process.argv[2];
const html = fs.readFileSync(file, 'utf8');
const start = html.indexOf('function developerResultField(');
const end = html.indexOf('function renderDeveloperSnapshot(', start);
if (start < 0 || end < 0) throw new Error('parser functions not found');
const context = {};
vm.createContext(context);
vm.runInContext(html.slice(start, end) +
  '\nthis.parseDeveloperStatusBody = parseDeveloperStatusBody;\n' +
  'this.developerResultField = developerResultField;', context);
  const result = {fields: {}, output:
    'MAIN hw=RT-AX86U boot=1 addon=active service-event=active cron=present mac_shield=on\n' +
    'snapshot requested=8 completed=6 pending=2\n' +
    'collection requested=5 completed=3 pending=2\n' +
    'observation_worker=not-installed\n' +
    'live_test_guard=Not installed\n'};
  context.parseDeveloperStatusBody(result);
  const expected = {
    hardware: 'RT-AX86U', addon_loader: 'active', service_event: 'active',
  periodic_recovery_cron: 'present', mac_shield: 'on',
  snapshot_requested_generation: '8', snapshot_completed_generation: '6',
    pending_snapshots: '2', collection_requested_generation: '5',
    collection_completed_generation: '3', pending_client_collections: '2',
    observation_worker: 'not-installed',
    live_test_guard: 'Not installed'
  };
for (const [key, value] of Object.entries(expected)) {
  if (result.fields[key] !== value) throw new Error(`${key}: ${result.fields[key]} !== ${value}`);
  }
  if (context.humanizeDeveloperObservationState(result.fields.observation_worker) !== 'Not installed') {
    throw new Error('not-installed observation state was not humanized');
  }
  console.log('NODE_STATUS_BODY_BEHAVIOR_OK');
NODE
  node - "$UI" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const file = process.argv[2];
const html = fs.readFileSync(file, 'utf8');
function extractFunction(name) {
  const start = html.indexOf('function ' + name + '(');
  if (start < 0) throw new Error(name + ' not found');
  const open = html.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < html.length; i++) {
    if (html[i] === '{') depth++;
    else if (html[i] === '}' && --depth === 0) return html.slice(start, i + 1);
  }
  throw new Error(name + ' has unbalanced braces');
}
const elements = {
  serviceSettingsModal: {style: {display: 'block'}},
  developerToolsModal: {style: {display: 'block'}}
};
let showSettingsCalls = 0;
let dirtyCalls = 0;
const writes = [];
const context = {
  document: {getElementById: id => elements[id] || null},
  setDeveloperToolsModalVisible: () => {},
  setDeveloperToolsStatus: () => {},
  showServiceSettingsModal: () => { showSettingsCalls++; },
  readServiceSettingsControls: () => ({BOOT_ENABLED: '1', PAUSE: 'on'}),
  writeServiceSettingControl: (definition, value) => writes.push([definition.key, value]),
  markSvcSettingsDirty: () => { dirtyCalls++; },
  SERVICE_SETTINGS_DEFINITIONS: [{key: 'BOOT_ENABLED'}, {key: 'PAUSE'}],
  _svcSnapshot: {BOOT_ENABLED: '0', PAUSE: 'off'}
};
vm.createContext(context);
vm.runInContext([
  'let _developerToolsOperation = null;',
  'let _developerToolsSettingsDraft = null;',
  extractFunction('captureDeveloperSettingsDraft'),
  extractFunction('restoreDeveloperSettingsDraft'),
  extractFunction('closeDeveloperToolsModal'),
  extractFunction('backToSettingsFromDeveloperTools'),
  'this.getDraft = () => _developerToolsSettingsDraft;',
  'this.setDraft = value => { _developerToolsSettingsDraft = value; };'
].join('\n'), context);

const captured = context.captureDeveloperSettingsDraft();
if (!captured || captured.values.BOOT_ENABLED !== '1' || captured.baseline.BOOT_ENABLED !== '0') {
  throw new Error('settings draft capture did not retain controls and persisted baseline');
}
context.setDraft(captured);
if (context.backToSettingsFromDeveloperTools() !== true || showSettingsCalls !== 1 || context.getDraft() !== captured) {
  throw new Error('Back did not preserve the draft while returning to Settings');
}
context.restoreDeveloperSettingsDraft();
if (context.getDraft() !== null || dirtyCalls !== 1 || writes.length !== 2 || writes[0][0] !== 'BOOT_ENABLED' || writes[0][1] !== '1') {
  throw new Error('Back draft was not restored and marked dirty');
}
context.setDraft({values: {BOOT_ENABLED: '1'}});
if (context.closeDeveloperToolsModal(false) !== true || context.getDraft() !== null) {
  throw new Error('X/close did not discard the unsaved draft');
}
console.log('NODE_SETTINGS_DRAFT_BACK_X_BEHAVIOR_OK');
NODE
else
  printf 'NODE_STATUS_BODY_BEHAVIOR_SKIPPED (no Node.js runtime)\n'
fi

printf 'DEVELOPER_TOOLS_CONTRACT_OK\n'
