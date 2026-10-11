#!/bin/sh
# Exercise updater boot predicates and its bounded local retry with the real
# boot-integrity library and isolated startup scripts/cron state.

set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
UPDATE_SOURCE="$BASE_DIR/functions/update_mervlan.sh"
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-update-boot.$(date +%s).$$"
MERV_BASE="$TEST_ROOT/tree"
SCRIPTS_DIR="$TEST_ROOT/scripts"
SERVICES_START="$SCRIPTS_DIR/services-start"
SERVICE_EVENT_WRAPPER="$SCRIPTS_DIR/service-event"
SETTINGS_FILE="$MERV_BASE/settings/settings.json"
CRU_BIN="$TEST_ROOT/cru"
BOOT_SCRIPT="$TEST_ROOT/boot-fixture.sh"
EXTRACT="$TEST_ROOT/update-functions.sh"
export MERV_BASE SCRIPTS_DIR SERVICES_START SERVICE_EVENT_WRAPPER SETTINGS_FILE CRU_BIN BOOT_SCRIPT

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup 0 1 2 3 15
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }

mkdir -p "$MERV_BASE/settings" "$MERV_BASE/functions" "$SCRIPTS_DIR"
cp "$BASE_DIR/settings/lib_json.sh" "$MERV_BASE/settings/lib_json.sh"
cp "$BASE_DIR/settings/lib_boot_integrity.sh" "$MERV_BASE/settings/lib_boot_integrity.sh"
. "$MERV_BASE/settings/lib_json.sh"
. "$MERV_BASE/settings/lib_boot_integrity.sh"

cat > "$CRU_BIN" <<'CRU'
#!/bin/sh
case "${1:-}" in
  l) [ ! -f "$TEST_CRON_FILE" ] || cat "$TEST_CRON_FILE" ;;
  a) printf '%s\n' "$MERV_BASE/functions/heal_event.sh cron" > "$TEST_CRON_FILE" ;;
  d) rm -f "$TEST_CRON_FILE" ;;
  *) exit 2 ;;
esac
CRU
chmod 755 "$CRU_BIN"
TEST_CRON_FILE="$TEST_ROOT/cron.list"
export TEST_CRON_FILE

write_settings() {
  cat > "$SETTINGS_FILE" <<EOF
{
  "General": {
    "BOOT_ENABLED": "$1",
    "IS_NODE": "0"
  }
}
EOF
}

write_hooks() {
  _manager="$1"
  {
    printf '%s\n' '#!/bin/sh'
    if [ "$_manager" = present ]; then
      cat <<HOOK
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
if $MERV_BASE/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  $MERV_BASE/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 10
$MERV_BASE/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
    fi
    cat <<HOOK
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
$MERV_BASE/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
  } > "$SERVICES_START"
  chmod 755 "$SERVICES_START"
  cat > "$SERVICE_EVENT_WRAPPER" <<HOOK
#!/bin/sh
### >>> MERVLAN START: service-event [tpl=service-event.v2.tpl md5=0123456789abcdef0123456789abcdef]
$MERV_BASE/functions/service-event-handler.sh "\$@"
### <<< MERVLAN END: service-event [tpl=service-event.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
  chmod 755 "$SERVICE_EVENT_WRAPPER"
}

cat > "$BOOT_SCRIPT" <<'BOOT'
#!/bin/sh
. "$MERV_BASE/settings/lib_json.sh"
. "$MERV_BASE/settings/lib_boot_integrity.sh"
case "${1:-}" in
  setupenable) exit 0 ;;
  enable)
    printf '%s\n' enable >> "$MERV_BASE/actions.log"
    if [ "${FAIL_RECONCILE:-0}" != 1 ]; then
      { printf '%s\n' '#!/bin/sh'; cat <<HOOK
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
if $MERV_BASE/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  $MERV_BASE/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 10
$MERV_BASE/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
        sed '1d' "$SERVICES_START"; } > "$SERVICES_START.new"
      mv "$SERVICES_START.new" "$SERVICES_START"
      chmod 755 "$SERVICES_START"
      "$CRU_BIN" a mervlan_health "*/5 * * * * $MERV_BASE/functions/heal_event.sh cron"
    fi
    ;;
  disable)
    printf '%s\n' disable >> "$MERV_BASE/actions.log"
    if [ "${FAIL_RECONCILE:-0}" != 1 ]; then
      { printf '%s\n' '#!/bin/sh'; sed '1d' "$SERVICES_START" | awk '
        /^### >>> MERVLAN START: services-start \[tpl=services-start[.]v[12][.]tpl/ { skip=1; next }
        /^### <<< MERVLAN END: services-start \[tpl=services-start[.]v[12][.]tpl/ { skip=0; next }
        !skip { print }
      '; } > "$SERVICES_START.new"
      mv "$SERVICES_START.new" "$SERVICES_START"
      chmod 755 "$SERVICES_START"
      "$CRU_BIN" d mervlan_health
    fi
    ;;
  report)
    preference=$(merv_boot_read_preference "$SETTINGS_FILE") || exit 3
    manager=$(merv_boot_hook_state "$SERVICES_START" services-start)
    addon=$(merv_boot_hook_state "$SERVICES_START" services-start-addon)
    event=$(merv_boot_hook_state "$SERVICE_EVENT_WRAPPER" service-event)
    cron=absent
    if "$CRU_BIN" l | grep -Fq "$MERV_BASE/functions/heal_event.sh cron"; then cron=present; fi
    [ "$addon" = present ] && addon=active
    [ "$event" = present ] && event=active
    printf 'REPORT hw=test boot=%s boot_preference=%s addon=%s event=%s cron=%s is_node=no mac_shield=off manager_hook=%s\n' \
      "$preference" "$preference" "$addon" "$event" "$cron" "$manager"
    ;;
  *) exit 2 ;;
esac
BOOT
chmod 755 "$BOOT_SCRIPT"

# Load only the production updater functions under test, not its CLI dispatch.
: > "$EXTRACT"
for _fn in update_capture_boot_preference runtime_report_matches update_local_runtime_matches verify_updated_runtime_state; do
  sed -n "/^${_fn}() {/,/^}/p" "$UPDATE_SOURCE" >> "$EXTRACT"
done
. "$EXTRACT"

info() { :; }
warn() { :; }
error() { :; }
run_update_step() {
  _step_name="$1"
  shift
  case "$_step_name" in
    'runtime verification setupenable') SETUP_RETRY_COUNT=$((SETUP_RETRY_COUNT + 1)) ;;
    'runtime verification boot state') BOOT_RETRY_COUNT=$((BOOT_RETRY_COUNT + 1)) ;;
  esac
  "$@"
}
assert_manager() {
  _expected="$1"
  merv_boot_hook_state "$SERVICES_START" services-start >/dev/null
  assert_eq "$_expected" "$MERV_BOOT_HOOK_STATE" 'observed manager state'
}
reset_retries() { SETUP_RETRY_COUNT=0; BOOT_RETRY_COUNT=0; }

# Healthy ON/OFF states are accepted, and report predicates require the actual
# manager observation rather than BOOT_ENABLED alone.
write_settings 1
write_hooks present
printf '%s\n' "$MERV_BASE/functions/heal_event.sh cron" > "$TEST_CRON_FILE"
PRE_BOOT_ENABLED=1
update_local_runtime_matches main || fail 'healthy ON fixture failed direct verifier'
_report=$(sh "$BOOT_SCRIPT" report)
runtime_report_matches "$_report" main || fail 'healthy ON report was rejected'
reset_retries
verify_updated_runtime_state main || fail 'healthy ON verification failed'
assert_eq 0 "$BOOT_RETRY_COUNT" 'healthy ON retry count'
assert_eq 1 "$(merv_boot_read_preference "$SETTINGS_FILE")" 'healthy ON preference preserved'
pass 'healthy ON requires and accepts one valid manager hook'

write_settings 0
write_hooks absent
rm -f "$TEST_CRON_FILE"
PRE_BOOT_ENABLED=0
update_local_runtime_matches main || fail 'healthy OFF fixture failed direct verifier'
_report=$(sh "$BOOT_SCRIPT" report)
runtime_report_matches "$_report" main || fail 'healthy OFF report was rejected'
verify_updated_runtime_state main || fail 'healthy OFF verification failed'
assert_eq 0 "$(merv_boot_read_preference "$SETTINGS_FILE")" 'healthy OFF preference preserved'
pass 'healthy OFF requires and accepts manager and cron absence'

# Historical false-green: desired ON but manager block missing. The updater
# detects it on disk, runs exactly one controlled local retry, then rechecks.
write_settings 1
write_hooks absent
printf '%s\n' "$MERV_BASE/functions/heal_event.sh cron" > "$TEST_CRON_FILE"
PRE_BOOT_ENABLED=1
reset_retries
verify_updated_runtime_state main || fail 'ON missing-manager fixture did not recover on bounded retry'
assert_manager present
assert_eq 1 "$BOOT_RETRY_COUNT" 'ON mismatch boot retry count'
assert_eq 1 "$SETUP_RETRY_COUNT" 'ON mismatch setup retry count'
assert_eq 1 "$(merv_boot_read_preference "$SETTINGS_FILE")" 'ON retry changed configured preference'
assert_eq 1 "$(grep -c '^enable$' "$MERV_BASE/actions.log")" 'single ON reconcile action'
pass 'ON missing-manager false green is rejected then repaired by one retry'

# Inverse false-green: desired OFF but an extra manager hook and cron remain.
write_settings 0
write_hooks present
printf '%s\n' "$MERV_BASE/functions/heal_event.sh cron" > "$TEST_CRON_FILE"
PRE_BOOT_ENABLED=0
reset_retries
verify_updated_runtime_state main || fail 'OFF extra-manager fixture did not recover on bounded retry'
assert_manager absent
[ ! -f "$TEST_CRON_FILE" ] || fail 'OFF retry left cron present'
assert_eq 1 "$BOOT_RETRY_COUNT" 'OFF mismatch boot retry count'
assert_eq 0 "$(merv_boot_read_preference "$SETTINGS_FILE")" 'OFF retry changed configured preference'
assert_eq 1 "$(grep -c '^disable$' "$MERV_BASE/actions.log")" 'single OFF reconcile action'
pass 'OFF extra-manager false green is rejected then repaired without changing preference'

# A failed reconcile stays a hard MAIN failure after one bounded attempt.
write_settings 1
write_hooks absent
printf '%s\n' "$MERV_BASE/functions/heal_event.sh cron" > "$TEST_CRON_FILE"
PRE_BOOT_ENABLED=1
reset_retries
FAIL_RECONCILE=1
export FAIL_RECONCILE
if verify_updated_runtime_state main; then fail 'persistent local mismatch was accepted'; fi
unset FAIL_RECONCILE
assert_eq 1 "$BOOT_RETRY_COUNT" 'persistent mismatch retry count'
assert_manager absent
assert_eq 1 "$(merv_boot_read_preference "$SETTINGS_FILE")" 'failed retry changed configured preference'
pass 'persistent local mismatch remains a hard updater failure after one retry'

for _bad in \
  '{"General":{"IS_NODE":"0"}}' \
  '{"General":{"BOOT_ENABLED":"true","IS_NODE":"0"}}' \
  '{"General":{"BOOT_ENABLED":"1","BOOT_ENABLED":"0","IS_NODE":"0"}}' \
  '{"General":{"IS_NODE":"0"},"Other":{"BOOT_ENABLED":"1"}}' \
  '{"General":{"BOOT_ENABLED":"1","IS_NODE":"0"' \
  ''; do
  printf '%s\n' "$_bad" > "$SETTINGS_FILE"
  cp "$SETTINGS_FILE" "$TEST_ROOT/settings.before"
  PRE_BOOT_ENABLED=stale
  if update_capture_boot_preference; then fail "invalid preflight setting accepted: $_bad"; fi
  assert_eq '' "$PRE_BOOT_ENABLED" 'failed strict capture did not clear stale preference'
  cmp -s "$TEST_ROOT/settings.before" "$SETTINGS_FILE" || fail 'strict preflight modified settings'
done
pass 'missing, duplicate, unsupported, malformed, and misplaced preference stop strict capture unchanged'

# The strict capture is source-ordered ahead of the first destructive hook
# teardown in the production updater.
_capture_line=$(grep -n 'if ! update_capture_boot_preference' "$UPDATE_SOURCE" | head -n 1 | cut -d: -f1)
_teardown_line=$(grep -n 'pre-update main disable' "$UPDATE_SOURCE" | head -n 1 | cut -d: -f1)
[ -n "$_capture_line" ] && [ -n "$_teardown_line" ] && [ "$_capture_line" -lt "$_teardown_line" ] || \
  fail 'strict preference capture is not visibly before teardown'
pass 'strict desired-state capture precedes updater hook teardown'

# New-format target nodes need an explicit matching manager field; legacy or
# incomplete reports are not accepted as current target-version nodes.
PRE_BOOT_ENABLED=1
runtime_report_matches 'REPORT hw=node boot=1 addon=node-on event=active cron=present is_node=yes mac_shield=off' node && \
  fail 'node report lacking manager_hook was accepted'
runtime_report_matches 'REPORT hw=node boot=1 manager_hook=absent addon=node-on event=active cron=present is_node=yes mac_shield=off' node && \
  fail 'ON node with manager absent was accepted'
PRE_BOOT_ENABLED=0
runtime_report_matches 'REPORT hw=node boot=0 manager_hook=present addon=node-on event=active cron=absent is_node=yes mac_shield=off' node && \
  fail 'OFF node with manager present was accepted'
runtime_report_matches 'REPORT hw=node boot=0 manager_hook=unknown addon=node-on event=active cron=absent is_node=yes mac_shield=off' node && \
  fail 'OFF node with unknown manager observation was accepted'
runtime_report_matches 'REPORT hw=node boot=0 manager_hook=invalid addon=node-on event=active cron=absent is_node=yes mac_shield=off' node && \
  fail 'OFF node with invalid manager observation was accepted'
runtime_report_matches 'REPORT hw=node boot=0 manager_hook=absent addon=node-on event=active cron=absent is_node=yes mac_shield=off' node || \
  fail 'healthy OFF target node was rejected'
pass 'target node reports reject missing, unknown, and mismatched manager observations'

ROLLBACK_PRE="$TEST_ROOT/rollback-pre-integrity"
ROLLBACK_CURRENT="$TEST_ROOT/rollback-current"
ROLLBACK_SYMLINK="$TEST_ROOT/rollback-symlink"
ROLLBACK_UNSAFE="$TEST_ROOT/rollback-unsafe"
ROLLBACK_UNREADABLE="$TEST_ROOT/rollback-unreadable"
mkdir -p "$ROLLBACK_PRE/settings" "$ROLLBACK_CURRENT/settings" \
  "$ROLLBACK_SYMLINK/settings" "$ROLLBACK_UNSAFE/settings" \
  "$ROLLBACK_UNREADABLE/settings"
cp "$MERV_BASE/settings/lib_boot_integrity.sh" "$ROLLBACK_CURRENT/settings/lib_boot_integrity.sh"
ln -s "$MERV_BASE/settings/lib_boot_integrity.sh" "$ROLLBACK_SYMLINK/settings/lib_boot_integrity.sh"
mkdir "$ROLLBACK_UNSAFE/settings/lib_boot_integrity.sh"
cp "$MERV_BASE/settings/lib_boot_integrity.sh" "$ROLLBACK_UNREADABLE/settings/lib_boot_integrity.sh"
chmod 000 "$ROLLBACK_UNREADABLE/settings/lib_boot_integrity.sh"
merv_boot_rollback_legacy_mode "$ROLLBACK_PRE" || fail 'pre-integrity restored tree classification failed'
assert_eq 1 "$MERV_BOOT_ROLLBACK_ALLOW_LEGACY" 'pre-integrity restored tree allows known legacy verification'
merv_boot_rollback_legacy_mode "$ROLLBACK_CURRENT" || fail 'current restored tree classification failed'
assert_eq 0 "$MERV_BOOT_ROLLBACK_ALLOW_LEGACY" 'current restored tree requires current verification'
if merv_boot_rollback_legacy_mode "$ROLLBACK_SYMLINK"; then fail 'symlink integrity library was accepted for rollback'; fi
assert_eq integrity_library_symlink "$MERV_BOOT_ROLLBACK_REASON" 'symlink integrity library fails closed'
if merv_boot_rollback_legacy_mode "$ROLLBACK_UNSAFE"; then fail 'non-file integrity library was accepted for rollback'; fi
assert_eq integrity_library_unsafe "$MERV_BOOT_ROLLBACK_REASON" 'unsafe integrity library object fails closed'
if merv_boot_rollback_legacy_mode "$ROLLBACK_UNREADABLE"; then fail 'unreadable integrity library was accepted for rollback'; fi
assert_eq integrity_library_unreadable "$MERV_BOOT_ROLLBACK_REASON" 'unreadable integrity library fails closed'
pass 'rollback legacy mode is selected from the restored tree and unsafe library states fail closed'

_update_restore_fn=$(sed -n '/^restore_update_original_tree() {/,/^}/p' "$UPDATE_SOURCE")
_update_fail_fn=$(sed -n '/^fail_update() {/,/^}/p' "$UPDATE_SOURCE")
_backup_rollback_fn=$(sed -n '/^mb_rollback_restore() {/,/^}/p' "$BASE_DIR/functions/mervlan_backup.sh")
_backup_restore_fn=$(sed -n '/^mb_restore() {/,/^}/p' "$BASE_DIR/functions/mervlan_backup.sh")
[ "$(printf '%s\n' "$_update_restore_fn" | grep -Fc 'merv_boot_rollback_legacy_mode "$MERV_BASE"')" = 1 ] || fail 'restored-tree Update rollback does not classify its actual tree'
[ "$(printf '%s\n' "$_update_fail_fn" | grep -Fc 'merv_boot_rollback_legacy_mode "$MERV_BASE"')" = 1 ] || fail 'teardown rollback does not classify its actual tree'
[ "$(printf '%s\n' "$_backup_rollback_fn" | grep -Fc 'merv_boot_rollback_legacy_mode "$MERV_BASE"')" = 1 ] || fail 'Backup rollback does not classify its actual tree'
[ "$(printf '%s\n' "$_update_restore_fn" | grep -Fc '"$_update_rollback_allow_legacy"; then')" = 1 ] || fail 'restored-tree Update rollback does not pass its derived mode'
[ "$(printf '%s\n' "$_update_fail_fn" | grep -Fc '"$_update_rollback_allow_legacy"; then')" = 1 ] || fail 'teardown Update rollback does not pass its derived mode'
[ "$(printf '%s\n' "$_backup_rollback_fn" | grep -Fc '"$MERV_BOOT_ROLLBACK_ALLOW_LEGACY"; then')" = 1 ] || fail 'Backup rollback does not pass its derived mode'
[ "$(printf '%s\n' "$_backup_restore_fn" | grep -Fc 'merv_boot_rollback_legacy_mode "$_mb_activation_source"')" = 1 ] || fail 'Backup target activation does not classify the selected tree with the shared helper'
pass 'Update and Backup call sites pass only modes derived from the actual restored tree'

printf '%s\n' UPDATE_BOOT_INTEGRITY_CONTRACT_OK
