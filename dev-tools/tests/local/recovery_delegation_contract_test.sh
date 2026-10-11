#!/bin/sh
# Standalone Recovery authenticated-child delegation contract.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.recovery-delegation.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || fail 'self-test helper load'
merv_test_context_enable "$BASE_DIR" "$TEST_ROOT" || fail 'private self-test context'

MERV_BASE="$BASE_DIR"
MERV_STATE_ROOT="$TEST_ROOT/state"
MERVLAN_RECOVERY_BACKUP_ROOT="$TEST_ROOT/backups"
MERVLAN_RECOVERY_ACTIVE_ROOT="$TEST_ROOT/active"
MERVLAN_RECOVERY_TMP_ROOT="$TEST_ROOT/tmp"
MERVLAN_RECOVERY_STATE_ROOT="$TEST_ROOT/state"
MERVLAN_RECOVERY_LOCK_OVERRIDE="$TEST_ROOT/locks/mervlan_maintenance.lock"
MERVLAN_RECOVERY_SOURCE_ONLY=1
export MERV_BASE MERV_STATE_ROOT MERVLAN_RECOVERY_BACKUP_ROOT \
  MERVLAN_RECOVERY_ACTIVE_ROOT MERVLAN_RECOVERY_TMP_ROOT \
  MERVLAN_RECOVERY_STATE_ROOT MERVLAN_RECOVERY_LOCK_OVERRIDE \
  MERVLAN_RECOVERY_SOURCE_ONLY
mkdir -p "$MERV_STATE_ROOT" "$MERVLAN_RECOVERY_BACKUP_ROOT" \
  "$MERVLAN_RECOVERY_ACTIVE_ROOT" "$MERVLAN_RECOVERY_TMP_ROOT" \
  "${MERVLAN_RECOVERY_LOCK_OVERRIDE%/*}" || exit 1
cp "$BASE_DIR/settings/lib_json.sh" "$MERVLAN_RECOVERY_BACKUP_ROOT/lib_json.sh" || exit 1
cp "$BASE_DIR/settings/lib_boot_integrity.sh" "$MERVLAN_RECOVERY_BACKUP_ROOT/lib_boot_integrity.sh" || exit 1
chmod 600 "$MERVLAN_RECOVERY_BACKUP_ROOT/lib_json.sh" \
  "$MERVLAN_RECOVERY_BACKUP_ROOT/lib_boot_integrity.sh" || exit 1

. "$BASE_DIR/settings/lib_owner_lock.sh" || fail 'owner library load'
. "$BASE_DIR/settings/lib_update_state.sh" || fail 'Update-state library load'
. "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery source-only load'

# Recovery must strictly read both its current target and selected backup
# preference before stale-stage reconciliation or hook teardown.
for recovery_boot_root in "$TEST_ROOT/recovery-current" "$TEST_ROOT/recovery-target"; do
  mkdir -p "$recovery_boot_root/settings" || fail 'Recovery boot-state fixture directory'
  cp "$BASE_DIR/settings/lib_json.sh" "$recovery_boot_root/settings/lib_json.sh" || fail 'Recovery JSON fixture library'
  cp "$BASE_DIR/settings/lib_boot_integrity.sh" "$recovery_boot_root/settings/lib_boot_integrity.sh" || fail 'Recovery integrity fixture library'
  printf '%s\n' '{' '  "General": {' '    "BOOT_ENABLED": "0"' '  }' '}' > "$recovery_boot_root/settings/settings.json" || fail 'Recovery valid preference fixture'
  [ "$(recovery_boot_state "$recovery_boot_root")" = 0 ] || fail 'Recovery rejected valid disabled preference'
  for recovery_bad_json in \
    '{"General":{"IS_NODE":"0"}}' \
    '{"General":{"BOOT_ENABLED":"true"}}' \
    '{"General":{"BOOT_ENABLED":"0","BOOT_ENABLED":"1"}}' \
    '{"Other":{"BOOT_ENABLED":"1"}}' \
    '{"General":{"BOOT_ENABLED":"1"'; do
    printf '%s\n' "$recovery_bad_json" > "$recovery_boot_root/settings/settings.json"
    cp "$recovery_boot_root/settings/settings.json" "$TEST_ROOT/recovery-settings.before" || fail 'Recovery preference snapshot'
    if recovery_boot_state "$recovery_boot_root" >/dev/null 2>&1; then fail 'Recovery accepted unknown or corrupt preference'; fi
    cmp -s "$TEST_ROOT/recovery-settings.before" "$recovery_boot_root/settings/settings.json" || fail 'Recovery preference preflight modified its input'
  done
done
if recovery_boot_state "$MERVLAN_RECOVERY_ACTIVE_ROOT" >/dev/null 2>&1; then
  fail 'Recovery unexpectedly read a boot preference from the empty active tree'
fi
recovery_boot_integrity_load || fail 'protected Recovery verifier depended on active-tree settings'
printf '%s\n' 'active-tree-sentinel' > "$MERVLAN_RECOVERY_ACTIVE_ROOT/sentinel"
_recovery_current_preflight=$(grep -nF 'RECOVERY_PRE_BOOT_ENABLED=$(recovery_boot_state' "$BASE_DIR/functions/mervlan_recover.sh" | head -n 1 | cut -d: -f1)
_recovery_target_preflight=$(grep -nF 'recovery_target_boot=$(recovery_boot_state' "$BASE_DIR/functions/mervlan_recover.sh" | head -n 1 | cut -d: -f1)
_recovery_stale_stage=$(grep -nF 'if ! recovery_reconcile_stale_stages; then' "$BASE_DIR/functions/mervlan_recover.sh" | head -n 1 | cut -d: -f1)
_recovery_disable=$(grep -nF 'MERV_SKIP_NODE_SYNC=1 sh "$MERVLAN_RECOVERY_ACTIVE_ROOT/functions/mervlan_boot.sh" disable' "$BASE_DIR/functions/mervlan_recover.sh" | head -n 1 | cut -d: -f1)
[ -n "$_recovery_current_preflight" ] && [ -n "$_recovery_target_preflight" ] && \
  [ -n "$_recovery_stale_stage" ] && [ -n "$_recovery_disable" ] && \
  [ "$_recovery_current_preflight" -lt "$_recovery_target_preflight" ] && \
  [ "$_recovery_target_preflight" -lt "$_recovery_stale_stage" ] && \
  [ "$_recovery_target_preflight" -lt "$_recovery_disable" ] || fail 'Recovery strict preference capture is not before teardown/stage reconciliation'
grep -Fq '|| RECOVERY_PRE_BOOT_ENABLED=""' "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery refuses standalone restore when the active tree has no readable boot preference'
[ "$(cat "$MERVLAN_RECOVERY_ACTIVE_ROOT/sentinel")" = active-tree-sentinel ] || fail 'Recovery boot-state preflight changed the active tree'
pass 'Recovery refuses unknown boot preferences before stage reconciliation or teardown'

RECOVERY_LOCK_OWNED=0
unset MERV_MAINTENANCE_DELEGATED MERV_MAINTENANCE_DELEGATION_KIND \
  MERV_RECOVERY_DELEGATION MERV_MAINTENANCE_OWNER_PID \
  MERV_MAINTENANCE_OWNER_START MERV_MAINTENANCE_OWNER_NONCE
if recovery_export_maintenance_context; then
  fail 'Recovery exported context before owning the lock'
fi
pass 'Recovery context export requires ownership first'

recovery_acquire_lock || fail 'Recovery owner acquisition'
recovery_owner_pid="$$"
recovery_owner_start="$RECOVERY_LOCK_START"
recovery_owner_nonce="$RECOVERY_LOCK_NONCE"
recovery_export_maintenance_context || fail 'Recovery context export'
[ "$MERV_MAINTENANCE_DELEGATED" = 1 ] || fail 'delegation flag'
[ "$MERV_MAINTENANCE_DELEGATION_KIND" = recovery ] || fail 'delegation kind'
[ "$MERV_RECOVERY_DELEGATION" = 1 ] || fail 'Recovery delegation flag'
[ "$MERV_MAINTENANCE_OWNER_PID" = "$recovery_owner_pid" ] || fail 'delegated PID'
[ "$MERV_MAINTENANCE_OWNER_START" = "$recovery_owner_start" ] || fail 'delegated start identity'
[ "$MERV_MAINTENANCE_OWNER_NONCE" = "$recovery_owner_nonce" ] || fail 'delegated nonce'
[ "$MERVLAN_RECOVERY_LOCK_OVERRIDE" = "$RECOVERY_LOCK" ] || fail 'delegated lock override'
merv_maintenance_delegation_valid || fail 'exact Recovery child context rejected'
pass 'Recovery exports the exact authenticated owner context'

recovery_expect_rejected() {
  recovery_reject_name="$1"
  if merv_maintenance_delegation_valid; then
    fail "wrong $recovery_reject_name accepted"
  fi
  pass "wrong $recovery_reject_name rejected"
}

MERV_MAINTENANCE_OWNER_PID=1
recovery_expect_rejected PID
MERV_MAINTENANCE_OWNER_PID="$recovery_owner_pid"
MERV_MAINTENANCE_OWNER_START=1
recovery_expect_rejected start-identity
MERV_MAINTENANCE_OWNER_START="$recovery_owner_start"
MERV_MAINTENANCE_OWNER_NONCE=wrong
recovery_expect_rejected nonce
MERV_MAINTENANCE_OWNER_NONCE="$recovery_owner_nonce"
MERV_MAINTENANCE_DELEGATION_KIND=install
recovery_expect_rejected kind
MERV_MAINTENANCE_DELEGATION_KIND=recovery
MERV_RECOVERY_DELEGATION=0
recovery_expect_rejected Recovery-flag
MERV_RECOVERY_DELEGATION=1
MERVLAN_RECOVERY_LOCK_OVERRIDE="$TEST_ROOT/locks/other.lock"
recovery_expect_rejected lock-override
MERVLAN_RECOVERY_LOCK_OVERRIDE="$RECOVERY_LOCK"
recovery_export_maintenance_context || fail 'Recovery context re-export'

# The same child admission gate used by mutating disable/setupdisable actions
# accepts the authenticated Recovery context and rejects an unauthenticated
# live owner. The production source also keeps both pre-activation calls under
# this gate.
for recovery_action in disable setupdisable; do
  if merv_update_mutation_blocked; then
    fail "pre-activation $recovery_action blocked under Recovery delegation"
  fi
  pass "pre-activation $recovery_action accepts Recovery delegation"
done
grep -Fq 'MERV_SKIP_NODE_SYNC=1 sh "$MERVLAN_RECOVERY_ACTIVE_ROOT/functions/mervlan_boot.sh" disable' \
  "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery disable call missing'
grep -Fq 'MERV_SKIP_NODE_SYNC=1 sh "$MERVLAN_RECOVERY_ACTIVE_ROOT/functions/mervlan_boot.sh" setupdisable' \
  "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery setupdisable call missing'

# Exercise recovery_reconcile() with real child-boundary validation. Each
# fixture child validates the exact context and records its tuple; all four
# children must receive the same owner identity and lock override.
target="$TEST_ROOT/target"
context_log="$TEST_ROOT/context.log"
mkdir -p "$target/functions" "$target/settings" "$target/www" || exit 1
cp "$BASE_DIR/settings/lib_json.sh" "$target/settings/lib_json.sh" || fail recovery-target-json
cp "$BASE_DIR/settings/lib_boot_integrity.sh" "$target/settings/lib_boot_integrity.sh" || fail recovery-target-integrity
for child in uninstall.sh install.sh functions/mervlan_boot.sh; do
  child_path="$target/$child"
  cat > "$child_path" <<'CHILD'
#!/bin/sh
set -u
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 41
. "$MERV_BASE/settings/lib_update_state.sh" || exit 42
merv_maintenance_delegation_valid || exit 43
printf '%s|%s|%s|%s|%s\n' "$1" "$MERV_MAINTENANCE_OWNER_PID" \
  "$MERV_MAINTENANCE_OWNER_START" "$MERV_MAINTENANCE_OWNER_NONCE" \
  "$MERVLAN_RECOVERY_LOCK_OVERRIDE" >> "$MERV_TEST_CONTEXT_LOG" || exit 44
CHILD
  chmod 755 "$child_path" || exit 1
done
printf '# fixture\n' > "$target/settings/fixture.sh"
printf '/* fixture */\n' > "$target/www/fixture.css"
printf '<!-- fixture -->\n' > "$target/www/fixture.html"
SCRIPTS_DIR="$TEST_ROOT/recovery-router-scripts"
RECOVERY_CRU="$TEST_ROOT/recovery-cru"
RECOVERY_CRON="$TEST_ROOT/recovery-cron"
mkdir -p "$SCRIPTS_DIR" || fail recovery-script-dir
cat > "$RECOVERY_CRU" <<'CRU'
#!/bin/sh
[ "${1:-}" = l ] || exit 2
cat "$RECOVERY_CRON"
CRU
export SCRIPTS_DIR RECOVERY_CRON
CRU_BIN="$RECOVERY_CRU"
export CRU_BIN
chmod 755 "$RECOVERY_CRU" || fail recovery-cru-mode
write_recovery_settings() {
  cat > "$target/settings/settings.json" <<EOF
{
  "General": {
    "BOOT_ENABLED": "$1",
    "IS_NODE": "0"
  }
}
EOF
}
write_recovery_hooks() {
  _manager="$1"
  {
    printf '%s\n' '#!/bin/sh'
    if [ "$_manager" = present ]; then
      cat <<HOOK
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
if $target/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  $target/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 10
$target/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
    fi
    cat <<HOOK
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
$target/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
  } > "$SCRIPTS_DIR/services-start"
  chmod 755 "$SCRIPTS_DIR/services-start"
  cat > "$SCRIPTS_DIR/service-event" <<HOOK
#!/bin/sh
### >>> MERVLAN START: service-event [tpl=service-event.v2.tpl md5=0123456789abcdef0123456789abcdef]
$target/functions/service-event-handler.sh "\$@"
### <<< MERVLAN END: service-event [tpl=service-event.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
  chmod 755 "$SCRIPTS_DIR/service-event"
}

# A selected tree may contain arbitrary shell libraries. They are data, never
# controller code: Recovery loads only the protected helper cohort beside
# recover.sh for both JSON parsing and hook verification.
cat > "$target/settings/lib_json.sh" <<'FAKEJSON'
printf '%s\n' sourced > "$TEST_ROOT/selected-json-sourced"
LIB_JSON_LOADED=1
json_validate_file() { return 0; }
json_get_section_value_strict() { printf '1\n'; }
FAKEJSON
cat > "$target/settings/lib_boot_integrity.sh" <<'FAKEINTEGRITY'
printf '%s\n' sourced > "$TEST_ROOT/selected-integrity-sourced"
LIB_BOOT_INTEGRITY_LOADED=1
merv_boot_verify_local() { MERV_BOOT_VERIFY_REASON=verified; return 0; }
FAKEINTEGRITY
RECOVERY_BOOT_LIBS_LOADED=0
unset LIB_JSON_LOADED LIB_BOOT_INTEGRITY_LOADED
recovery_boot_integrity_load || fail 'Recovery could not load protected verification libraries'
[ ! -e "$TEST_ROOT/selected-json-sourced" ] || fail 'Recovery sourced selected-tree lib_json.sh'
[ ! -e "$TEST_ROOT/selected-integrity-sourced" ] || fail 'Recovery sourced selected-tree lib_boot_integrity.sh'
write_recovery_settings 1
cat > "$SCRIPTS_DIR/services-start" <<HOOK
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
$target/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
sleep 10
$target/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
$target/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
$target/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
chmod 755 "$SCRIPTS_DIR/services-start" || fail 'Recovery malformed hook fixture mode'
cat > "$SCRIPTS_DIR/service-event" <<HOOK
#!/bin/sh
### >>> MERVLAN START: service-event [tpl=service-event.v2.tpl md5=0123456789abcdef0123456789abcdef]
$target/functions/service-event-handler.sh "\$@"
### <<< MERVLAN END: service-event [tpl=service-event.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
chmod 755 "$SCRIPTS_DIR/service-event" || fail 'Recovery event fixture mode'
printf '%s\n' "$target/functions/heal_event.sh cron" > "$RECOVERY_CRON"
if recovery_verify_boot_state "$target" 1; then fail 'protected Recovery verifier accepted malformed selected manager hook'; fi
[ "${MERV_BOOT_VERIFY_REASON:-}" != verified ] || fail 'selected fake verifier accepted malformed manager hook'
[ ! -e "$TEST_ROOT/selected-json-sourced" ] || fail 'Recovery sourced selected-tree lib_json.sh during verification'
[ ! -e "$TEST_ROOT/selected-integrity-sourced" ] || fail 'Recovery sourced selected-tree lib_boot_integrity.sh during verification'
printf '%s\n' '{"General":{"BOOT_ENABLED":"1"' > "$target/settings/settings.json"
if recovery_boot_state "$target" >/dev/null 2>&1; then fail 'protected JSON parser accepted malformed selected settings'; fi
[ ! -e "$TEST_ROOT/selected-json-sourced" ] || fail 'Recovery sourced selected-tree lib_json.sh during settings parsing'
pass 'Recovery uses only protected JSON and hook-verification libraries for selected trees'

# The protected helper directory is private; libraries must be regular,
# readable, non-symlink files. Unsafe cohorts never trigger a fallback.
recovery_expect_bad_helper() {
  _helper_path="$1" _helper_label="$2"
  if ( RECOVERY_BOOT_LIBS_LOADED=0; unset LIB_JSON_LOADED LIB_BOOT_INTEGRITY_LOADED; \
       MERVLAN_RECOVERY_BACKUP_ROOT="$_helper_path"; recovery_boot_integrity_load ); then
    fail "Recovery accepted unsafe protected helper cohort: $_helper_label"
  fi
}
mkdir -p "$TEST_ROOT/helper-open" "$TEST_ROOT/helper-file-link" \
  "$TEST_ROOT/helper-missing" "$TEST_ROOT/helper-dir" "$TEST_ROOT/helper-unreadable"
chmod 755 "$TEST_ROOT/helper-open"
cp "$BASE_DIR/settings/lib_json.sh" "$TEST_ROOT/helper-open/lib_json.sh"
cp "$BASE_DIR/settings/lib_boot_integrity.sh" "$TEST_ROOT/helper-open/lib_boot_integrity.sh"
recovery_expect_bad_helper "$TEST_ROOT/helper-open" 'group/world-accessible helper directory'
cp "$BASE_DIR/settings/lib_json.sh" "$TEST_ROOT/helper-file-link/lib_json.sh"
ln -s "$MERVLAN_RECOVERY_BACKUP_ROOT/lib_boot_integrity.sh" "$TEST_ROOT/helper-file-link/lib_boot_integrity.sh"
recovery_expect_bad_helper "$TEST_ROOT/helper-file-link" 'symlink integrity library'
cp "$BASE_DIR/settings/lib_json.sh" "$TEST_ROOT/helper-missing/lib_json.sh"
recovery_expect_bad_helper "$TEST_ROOT/helper-missing" 'missing integrity library'
cp "$BASE_DIR/settings/lib_json.sh" "$TEST_ROOT/helper-dir/lib_json.sh"
mkdir "$TEST_ROOT/helper-dir/lib_boot_integrity.sh"
recovery_expect_bad_helper "$TEST_ROOT/helper-dir" 'directory at integrity library path'
cp "$BASE_DIR/settings/lib_json.sh" "$TEST_ROOT/helper-unreadable/lib_json.sh"
cp "$BASE_DIR/settings/lib_boot_integrity.sh" "$TEST_ROOT/helper-unreadable/lib_boot_integrity.sh"
chmod 000 "$TEST_ROOT/helper-unreadable/lib_boot_integrity.sh"
recovery_expect_bad_helper "$TEST_ROOT/helper-unreadable" 'integrity library with no read permission bits'
ln -s "$MERVLAN_RECOVERY_BACKUP_ROOT" "$TEST_ROOT/helper-root-link"
recovery_expect_bad_helper "$TEST_ROOT/helper-root-link" 'symlink helper directory'
pass 'Recovery fails closed when its protected helper cohort is missing or unsafe'
grep -Fq 'merv_boot_rollback_legacy_mode "$RECOVERY_TREE"' "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery target does not use the shared strict tree classifier'
grep -Fq 'merv_boot_rollback_legacy_mode "$MERVLAN_RECOVERY_ACTIVE_ROOT"' "$BASE_DIR/functions/mervlan_recover.sh" || fail 'Recovery rollback does not use the shared strict tree classifier'
if grep -Fq '. "$RECOVERY_TREE/settings/lib_json.sh"' "$BASE_DIR/functions/mervlan_recover.sh" || \
   grep -Fq '. "$RECOVERY_TREE/settings/lib_boot_integrity.sh"' "$BASE_DIR/functions/mervlan_recover.sh"; then
  fail 'Recovery sources selected-tree verification libraries'
fi
pass 'Recovery target and rollback share strict tree classification without target library sourcing'

write_recovery_settings 1
write_recovery_hooks absent
printf '%s\n' "$target/functions/heal_event.sh cron" > "$RECOVERY_CRON"
if recovery_verify_boot_state "$target" 1; then fail 'Recovery accepted enabled preference with manager absent'; fi
[ "${MERV_BOOT_VERIFY_REASON:-}" = manager_mismatch ] || fail recovery-on-mismatch-reason
write_recovery_settings 0
write_recovery_hooks present
if recovery_verify_boot_state "$target" 0; then fail 'Recovery accepted disabled preference with manager present'; fi
[ "${MERV_BOOT_VERIFY_REASON:-}" = manager_mismatch ] || fail recovery-off-mismatch-reason
write_recovery_hooks absent
: > "$RECOVERY_CRON"
recovery_verify_boot_state "$target" 0 || fail recovery-healthy-off-verification
write_recovery_settings 1
cat > "$SCRIPTS_DIR/services-start" <<HOOK
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
$target/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
sleep 10
$target/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
$target/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
sleep 5
$target/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
chmod 755 "$SCRIPTS_DIR/services-start" || fail recovery-legacy-services-mode
printf '%s\n' "$target/functions/heal_event.sh cron" > "$RECOVERY_CRON"
if recovery_verify_boot_state "$target" 1; then fail 'ordinary Recovery verification accepted a legacy manager'; fi
recovery_verify_boot_state "$target" 1 1 || fail 'Recovery rollback/legacy restore rejected a known old manager block'
write_recovery_settings 0
write_recovery_hooks absent
: > "$RECOVERY_CRON"
pass 'Recovery legacy restore accepts a known manager only through its explicit rollback path'
pass 'Recovery direct hook verification rejects both preference/manager mismatches'
MERV_TEST_CONTEXT_LOG="$context_log"
export MERV_TEST_CONTEXT_LOG
MERVLAN_RECOVERY_TEST_MODE=0
recovery_reconcile "$target" 0 || fail 'Recovery reconcile child delegation'
[ "$(wc -l < "$context_log")" -eq 4 ] || fail 'unexpected child delegation count'
while IFS='|' read -r recovery_child recovery_pid recovery_start recovery_nonce recovery_override; do
  [ "$recovery_pid" = "$recovery_owner_pid" ] || fail 'child PID changed during reconcile'
  [ "$recovery_start" = "$recovery_owner_start" ] || fail 'child start identity changed during reconcile'
  [ "$recovery_nonce" = "$recovery_owner_nonce" ] || fail 'child nonce changed during reconcile'
  [ "$recovery_override" = "$RECOVERY_LOCK" ] || fail 'child lock override changed during reconcile'
done < "$context_log"
pass 'recovery_reconcile reuses one authenticated owner tuple'

# Remove delegation while the owner is still live: an unrelated child must be
# blocked by the existing fail-closed maintenance gate.
MERV_MAINTENANCE_DELEGATED=0
MERV_RECOVERY_DELEGATION=0
MERVLAN_MAINTENANCE_LOCK_OVERRIDE="$RECOVERY_LOCK"
export MERVLAN_MAINTENANCE_LOCK_OVERRIDE
if ! merv_update_mutation_blocked; then
  fail 'unrelated live maintenance owner was not blocked'
fi
pass 'unrelated live maintenance owner remains fail-closed'
unset MERVLAN_MAINTENANCE_LOCK_OVERRIDE
recovery_export_maintenance_context || fail 'Recovery context restoration'
recovery_release_lock || fail 'Recovery owner release'
[ ! -e "$RECOVERY_LOCK" ] || fail 'Recovery owner lock remained after release'

# A pre-activation Recovery failure must release its owner and preserve the
# untouched active installation and exact recovery root without guessing any
# transaction state away.
printf 'active-sentinel\n' > "$MERVLAN_RECOVERY_ACTIVE_ROOT/sentinel"
cp -p "$BASE_DIR/settings/lib_maintenance_recovery.sh" \
  "$MERVLAN_RECOVERY_BACKUP_ROOT/recovery_state.sh" || exit 1
cp -p "$BASE_DIR/settings/lib_update_state.sh" \
  "$MERVLAN_RECOVERY_BACKUP_ROOT/update_state.sh" || exit 1
RECOVERY_LOCK_OWNED=0
RECOVERY_LOCK_NONCE=""
RECOVERY_LOCK_START=""
MERVLAN_RECOVERY_TEST_MODE=0
(
  trap recovery_cleanup EXIT
  recovery_restore mervlan.backup.missing.tar.gz yes >/dev/null 2>&1
)
recovery_failure_rc=$?
[ "$recovery_failure_rc" -ne 0 ] || fail 'pre-activation Recovery failure unexpectedly succeeded'
[ -f "$MERVLAN_RECOVERY_ACTIVE_ROOT/sentinel" ] || fail 'active installation changed on pre-activation failure'
[ ! -e "$RECOVERY_LOCK" ] || fail 'pre-activation failure retained owner lock'
[ ! -e "$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.recovery" ] || fail 'pre-activation failure created durable marker'
[ ! -e "$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.old.$$" ] || fail 'pre-activation failure left old tree'
[ ! -e "$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.new.$$" ] || fail 'pre-activation failure left new tree'
pass 'pre-activation Recovery failure releases owner and preserves active state'

printf 'RECOVERY_DELEGATION_CONTRACT_OK\n'
