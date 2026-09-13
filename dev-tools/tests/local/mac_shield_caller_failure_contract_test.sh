#!/bin/sh
# Required MAC Shield callers must expose strict local-enforcement failure
# truthfully.  This test uses fixture libraries and extracted production
# functions only; it never invokes ebtables, SSH, or router state.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-shield-callers.$$"
umask 077
mkdir -p "$TEST_ROOT/meta/settings" "$TEST_ROOT/meta/functions" "$TEST_ROOT/meta/db" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Metadata: run the real entry point against minimal fixture libraries.  The
# override DB write succeeds, while strict shield reload fails.
META_ROOT="$TEST_ROOT/meta"
export MERV_TEST_ROOT="$META_ROOT"
printf '%s\n' \
  'VAR_SETTINGS_LOADED=1; LOG_SETTINGS_LOADED=1; LIB_JSON_LOADED=1; LIB_MERVQT_LOADED=1' \
  'LIB_MAC_SHIELD_SNAPSHOT_LOADED=1; LIB_SSH_LOADED=1; LIB_ACTION_LOCK_LOADED=1' \
  'LIB_UPDATE_STATE_LOADED=1; LIB_ACTION_PROGRESS_LOADED=1' \
  'TMPDIR="$MERV_TEST_ROOT/tmp"; LOCKDIR="$MERV_TEST_ROOT/locks"; SETTINGS_FILE="$MERV_TEST_ROOT/settings.json"' \
  'MERV_MAC_OVERRIDE_DB="$MERV_TEST_ROOT/db/override.db"; MERV_CLIENT_NAME_DB="$MERV_TEST_ROOT/db/names.db"' \
  'MERV_MAC_DB_ACTIVE="$MERV_TEST_ROOT/db/active.db"; MERV_MAC_NODE_SYNC=1' \
  'info() { :; }; warn() { :; }; error() { :; }' \
  'json_get_section_value() { printf "\n"; }' \
  'mervqt_mac_lower() { printf "%s\n" "$1"; }; mervqt_valid_mac() { return 0; }' \
  'merv_mac_is_main() { return 0; }; merv_mac_best_db() { printf "%s\n" "$MERV_MAC_DB_ACTIVE"; }' \
  'ebt_mac_shield_init_and_apply() { return 1; }' \
  'merv_mac_node_list() { printf "%s\n" "1 192.0.2.1"; }' \
  'merv_mac_push_db_to_nodes() { : > "$MERV_TEST_ROOT/node-push"; return 0; }' \
  'merv_lock_acquire() { MERV_LOCK_NONCE=meta-test-nonce; return 0; }; merv_lock_release() { return 0; }' \
  'merv_action_lock_enter() { MERV_ACTION_LOCK_MODE=self; MERV_ACTION_LOCK_NONCE=action-test; MERV_ACTION_LOCK_START=1; return 0; }' \
  'merv_action_lock_export_child_context() { return 0; }; merv_action_lock_leave() { return 0; }' \
  'merv_update_mutation_blocked() { return 1; }' \
  'merv_action_progress_init() { :; }; merv_action_progress_phase() { :; }; merv_action_progress_update() { printf "%s\\n" "$*" >> "$MERV_TEST_ROOT/progress-updates"; }' \
  'merv_action_progress_complete() { : > "$MERV_TEST_ROOT/progress-complete"; }' \
  'merv_action_progress_fail() { : > "$MERV_TEST_ROOT/progress-fail"; }' \
  > "$META_ROOT/settings/common.sh" || exit 1
for _lib in var_settings.sh log_settings.sh lib_json.sh lib_mervqt.sh mac_shield_snapshot.sh lib_ssh.sh lib_action_lock.sh lib_update_state.sh lib_action_progress.sh; do
  printf '%s\n' '. "$MERV_BASE/settings/common.sh"' > "$META_ROOT/settings/$_lib" || exit 1
done
printf '%s\n' '#!/bin/sh' ': > "$MERV_TEST_ROOT/inventory-run"' > "$META_ROOT/functions/post_apply_worker.sh" || exit 1
chmod 700 "$META_ROOT/functions/post_apply_worker.sh" || exit 1
: > "$META_ROOT/db/active.db"
if MERV_BASE="$META_ROOT" sh "$BASE_DIR/functions/mac_client_meta.sh"; then
  fail 'metadata returned success after strict local shield failure'
else
  _meta_rc=$?
fi
[ "$_meta_rc" -ne 0 ] || fail 'metadata failure returned zero'
[ -f "$META_ROOT/db/override.db" ] || fail 'metadata persistence did not complete before shield failure'
[ -f "$META_ROOT/progress-fail" ] || fail 'metadata did not publish terminal partial/failure'
[ ! -f "$META_ROOT/progress-complete" ] || fail 'metadata published complete after shield failure'
[ ! -f "$META_ROOT/node-push" ] || fail 'metadata pushed nodes after local shield failure'
[ ! -f "$META_ROOT/inventory-run" ] || fail 'metadata ran inventory follow-up after local shield failure'

# Metadata-only saves must remain usable before the first explicit MAC Shield
# rebuild.  There is no shield database to reload in that state, so the real
# action stages overrides, refreshes display names, and completes successfully
# without manufacturing a baseline or pushing incomplete shield state to nodes.
STAGED_ROOT="$TEST_ROOT/meta-staged"
mkdir -p "$STAGED_ROOT/settings" "$STAGED_ROOT/functions" "$STAGED_ROOT/db" || exit 1
export MERV_TEST_ROOT="$STAGED_ROOT"
printf '%s\n' \
  'VAR_SETTINGS_LOADED=1; LOG_SETTINGS_LOADED=1; LIB_JSON_LOADED=1; LIB_MERVQT_LOADED=1' \
  'LIB_MAC_SHIELD_SNAPSHOT_LOADED=1; LIB_SSH_LOADED=1; LIB_ACTION_LOCK_LOADED=1' \
  'LIB_UPDATE_STATE_LOADED=1; LIB_ACTION_PROGRESS_LOADED=1' \
  'TMPDIR="$MERV_TEST_ROOT/tmp"; LOCKDIR="$MERV_TEST_ROOT/locks"; SETTINGS_FILE="$MERV_TEST_ROOT/settings.json"' \
  'MERV_MAC_OVERRIDE_DB="$MERV_TEST_ROOT/db/override.db"; MERV_CLIENT_NAME_DB="$MERV_TEST_ROOT/db/names.db"' \
  'MERV_MAC_DB_ACTIVE="$MERV_TEST_ROOT/db/active.db"; MERV_MAC_NODE_SYNC=1' \
  'info() { :; }; warn() { :; }; error() { :; }' \
  'json_get_section_value() { case "$2" in MAC_SHIELD_OVERRIDES) printf "%s\\n" "aa:bb:cc:dd:ee:ff" ;; CLIENT_NAME_OVERRIDES) printf "%s\\n" "aa:bb:cc:dd:ee:ff=Staged Client" ;; esac; }' \
  'mervqt_mac_lower() { printf "%s\\n" "$1"; }; mervqt_valid_mac() { return 0; }' \
  'merv_mac_is_main() { return 0; }; merv_mac_best_db() { return 1; }' \
  'ebt_mac_shield_init_and_apply() { : > "$MERV_TEST_ROOT/unexpected-shield-reload"; return 1; }' \
  'merv_mac_node_list() { printf "%s\\n" "1 192.0.2.1"; }' \
  'merv_mac_push_db_to_nodes() { : > "$MERV_TEST_ROOT/node-push"; return 0; }' \
  'merv_lock_acquire() { MERV_LOCK_NONCE=staged-meta-test-nonce; return 0; }; merv_lock_release() { return 0; }' \
  'merv_action_lock_enter() { MERV_ACTION_LOCK_MODE=self; MERV_ACTION_LOCK_NONCE=staged-action-test; MERV_ACTION_LOCK_START=1; return 0; }' \
  'merv_action_lock_export_child_context() { return 0; }; merv_action_lock_leave() { return 0; }' \
  'merv_update_mutation_blocked() { return 1; }' \
  'merv_action_progress_init() { :; }; merv_action_progress_phase() { :; }; merv_action_progress_update() { printf "%s\\n" "$*" >> "$MERV_TEST_ROOT/progress-updates"; }' \
  'merv_action_progress_complete() { : > "$MERV_TEST_ROOT/progress-complete"; }' \
  'merv_action_progress_fail() { : > "$MERV_TEST_ROOT/progress-fail"; }' \
  > "$STAGED_ROOT/settings/common.sh" || exit 1
for _lib in var_settings.sh log_settings.sh lib_json.sh lib_mervqt.sh mac_shield_snapshot.sh lib_ssh.sh lib_action_lock.sh lib_update_state.sh lib_action_progress.sh; do
  printf '%s\n' '. "$MERV_BASE/settings/common.sh"' > "$STAGED_ROOT/settings/$_lib" || exit 1
done
printf '%s\n' '#!/bin/sh' ': > "$MERV_TEST_ROOT/inventory-run"' > "$STAGED_ROOT/functions/post_apply_worker.sh" || exit 1
chmod 700 "$STAGED_ROOT/functions/post_apply_worker.sh" || exit 1
if ! MERV_BASE="$STAGED_ROOT" sh "$BASE_DIR/functions/mac_client_meta.sh"; then
  fail 'metadata failed before the first MAC Shield rebuild'
fi
[ "$(awk 'NF { n++ } END { print n+0 }' "$STAGED_ROOT/db/override.db")" = 1 ] || fail 'staged metadata did not materialize override DB'
[ "$(awk 'NF { n++ } END { print n+0 }' "$STAGED_ROOT/db/names.db")" = 1 ] || fail 'staged metadata did not materialize client-name DB'
[ -f "$STAGED_ROOT/progress-complete" ] || fail 'staged metadata did not publish completion'
[ ! -f "$STAGED_ROOT/progress-fail" ] || fail 'staged metadata published a failure'
[ -f "$STAGED_ROOT/inventory-run" ] || fail 'staged metadata did not refresh client inventory'
[ ! -f "$STAGED_ROOT/unexpected-shield-reload" ] || fail 'staged metadata attempted an absent shield reload'
[ ! -f "$STAGED_ROOT/node-push" ] || fail 'staged metadata pushed overrides without a shield database'
grep -Fq 'prepare 0 4 60 Preparing client metadata...' "$STAGED_ROOT/progress-updates" || fail 'staged metadata lacks post-save preparation percentage'
grep -Fq 'persist 1 4 68 Writing MAC override database...' "$STAGED_ROOT/progress-updates" || fail 'staged metadata lacks post-save persistence percentage'
grep -Fq 'shield 3 4 88 MAC Shield has no active database; staging overrides...' "$STAGED_ROOT/progress-updates" || fail 'staged metadata lacks post-save shield staging percentage'
grep -Fq 'collect 4 4 94 Refreshing client inventory...' "$STAGED_ROOT/progress-updates" || fail 'staged metadata lacks post-save collection percentage'
grep -Fq 'complete 1 1 98 Finalizing client metadata...' "$STAGED_ROOT/progress-updates" || fail 'staged metadata lacks post-save finalization percentage'

# Manager: execute the real cleanup function.  A failed initial MAC arm must
# return before any destructive cleanup helper is reached.
MANAGER_ROOT="$TEST_ROOT/manager"
mkdir -p "$MANAGER_ROOT" || exit 1
DRY_RUN=no
info() { :; }; error() { :; }
ebt_quarantine_ensure_expected_rules() { :; }
merv_iface_vid_list() { :; }
merv_mac_best_db() { printf '%s\n' "$MANAGER_ROOT/active.db"; }
ebt_mac_shield_init_and_apply() { : > "$MANAGER_ROOT/apply-attempted"; return 1; }
ebt_cleanup_all_trunk_rules() { : > "$MANAGER_ROOT/destructive-cleanup"; }
# Extract the complete named cleanup function through its stable following
# section marker.  Fixed line slicing previously truncated nested control flow
# as production evolved and tested a syntactically incomplete fragment.
_manager_cleanup="$MANAGER_ROOT/cleanup_existing_config.sh"
sed -n '/^cleanup_existing_config()[[:space:]]*{/,/^# --- rc\/queue helpers/p' \
  "$BASE_DIR/functions/mervlan_manager.sh" | sed '$d' > "$_manager_cleanup"
[ -s "$_manager_cleanup" ] || fail 'manager cleanup extraction failed'
. "$_manager_cleanup"
if cleanup_existing_config; then
  fail 'manager cleanup returned success after strict shield failure'
fi
[ -f "$MANAGER_ROOT/apply-attempted" ] || fail 'manager did not attempt local shield arm'
[ ! -f "$MANAGER_ROOT/destructive-cleanup" ] || fail 'manager reached destructive cleanup after shield failure'

# Boot enable: fixture the real entry point.  It must record a partial action
# and not invoke node propagation when strict local shield application fails.
BOOT_ROOT="$TEST_ROOT/boot"
mkdir -p "$BOOT_ROOT/settings" "$BOOT_ROOT/scripts" "$BOOT_ROOT/db" "$BOOT_ROOT/tmp" || exit 1
export MERV_TEST_ROOT="$BOOT_ROOT"
printf '%s\n' \
  'VAR_SETTINGS_LOADED=1; LOG_SETTINGS_LOADED=1; LIB_JSON_LOADED=1; LIB_SSH_LOADED=1; LIB_OWNER_LOCK_LOADED=1; LIB_MERVQT_LOADED=1' \
  'TMPDIR="$MERV_TEST_ROOT/tmp"; LOCKDIR="$MERV_TEST_ROOT/locks"; SCRIPTS_DIR="$MERV_TEST_ROOT/scripts"' \
  'SETTINGS_FILE="$MERV_TEST_ROOT/settings.json"; TEMPLATE_LIB="$MERV_BASE/settings/template.sh"; TEMPLATE_SERVICES="$MERV_TEST_ROOT/template"; SERVICES_START="$MERV_TEST_ROOT/services-start"; MERV_DISABLE_LOCKS=1' \
  'MERV_MAC_DB_ACTIVE="$MERV_TEST_ROOT/db/active.db"; MERV_NODE_CONTEXT=0; MERV_SKIP_NODE_SYNC=0' \
  'info() { :; }; warn() { :; }; error() { :; }; merv_has() { return 1; }' \
  'get_node_ssh_user() { printf "%s\n" admin; }; get_node_ssh_port() { printf "%s\n" 22; }' \
  'merv_update_mutation_blocked() { return 1; }; merv_ssh_preflight_configured_nodes() { return 0; }' \
  'json_set_flag() { return 0; }; inject_template() { return 0; }; merv_mac_best_db() { printf "%s\n" "$MERV_MAC_DB_ACTIVE"; }' \
  'ebt_mac_shield_init_and_apply() { : > "$MERV_TEST_ROOT/shield-failed"; return 1; }' \
  'merv_node_list() { : > "$MERV_TEST_ROOT/node-propagation"; printf "%s\n" "1 192.0.2.1"; }' \
  'action_ack_partial() { printf "%s\n" "$*" > "$MERV_TEST_ROOT/boot-partial"; return 0; }' \
  'action_ack_ok() { : > "$MERV_TEST_ROOT/boot-ok"; return 0; }' \
  > "$BOOT_ROOT/settings/common.sh" || exit 1
for _lib in var_settings.sh log_settings.sh lib_json.sh lib_ssh.sh lib_owner_lock.sh lib_mervqt.sh lib_update_state.sh lib_node_reconcile.sh lib_action_ack.sh; do
  printf '%s\n' '. "$MERV_BASE/settings/common.sh"' > "$BOOT_ROOT/settings/$_lib" || exit 1
done
printf '%s\n' \
  'tpl_path() { cp "$TEMPLATE_SERVICES" "$MERV_TEST_ROOT/rendered-template" || return 1; printf "%s\n" "$MERV_TEST_ROOT/rendered-template"; }' \
  > "$BOOT_ROOT/settings/template.sh" || exit 1
: > "$BOOT_ROOT/template"
: > "$BOOT_ROOT/db/active.db"
if ! MERV_BASE="$BOOT_ROOT" sh "$BASE_DIR/functions/mervlan_boot.sh" enable test-token > "$BOOT_ROOT/trace" 2>&1; then
  cat "$BOOT_ROOT/trace" >&2
  fail 'boot fixture entry point failed before partial acknowledgement'
fi
[ -f "$BOOT_ROOT/shield-failed" ] || fail 'boot did not attempt strict local shield arm'
[ -f "$BOOT_ROOT/boot-partial" ] || fail 'boot did not record partial recovery after shield failure'
[ ! -f "$BOOT_ROOT/boot-ok" ] || fail 'boot recorded complete success after shield failure'
[ ! -f "$BOOT_ROOT/node-propagation" ] || fail 'boot propagated nodes after local shield failure'

# The boot wrapper's legacy pre-arm is best-effort, but DHCP protection is
# armed first and remains the safety path when that pre-arm fails.
LEGACY_ROOT="$TEST_ROOT/legacy"
mkdir -p "$LEGACY_ROOT/locks" "$LEGACY_ROOT/db" || exit 1
LOCKDIR="$LEGACY_ROOT/locks"; MERV_MAC_DB_ACTIVE="$LEGACY_ROOT/db/active.db"; MERV_MAC_DB_JFFS=''
SETTINGS_FILE="$LEGACY_ROOT/settings.json"
MERV_BOOT_SHIELD_MAX_SEC=1; DRY_RUN=no
printf '%s\n' '1 aa:bb:cc:dd:ee:ff wl0.2 10' > "$MERV_MAC_DB_ACTIVE"
info() { :; }; warn() { :; }; ebtables() { :; }
merv_dhcp_hold_arm() { : > "$LEGACY_ROOT/dhcp-hold-armed"; return 0; }
merv_dhcp_hold_release() { : > "$LEGACY_ROOT/dhcp-hold-release"; return 0; }
merv_boot_shield_lan_configured() { return 0; }
ebt_mac_shield_init_and_apply() { : > "$LEGACY_ROOT/prearm-failed"; return 1; }
# The wrapper function is delimited by the next named watchdog section, not
# source line numbers, so this remains a behavior fixture as comments move.
_legacy_shield="$LEGACY_ROOT/mode_shield_legacy.sh"
sed -n '/^_mode_shield_legacy()[[:space:]]*{/,/^# Token-owned boot watchdog/p' \
  "$BASE_DIR/functions/mervlan_boot_wrap.sh" | sed '$d' > "$_legacy_shield"
[ -s "$_legacy_shield" ] || fail 'legacy shield extraction failed'
. "$_legacy_shield"
_mode_shield_legacy || fail 'legacy boot shield wrapper unexpectedly failed'
[ -f "$LEGACY_ROOT/dhcp-hold-armed" ] || fail 'boot wrapper did not arm DHCP hold before failed MAC pre-arm'
[ -f "$LEGACY_ROOT/prearm-failed" ] || fail 'boot wrapper did not attempt persistent MAC pre-arm'
sleep 2

printf 'MAC_SHIELD_CALLER_FAILURE_CONTRACT_OK\n'
