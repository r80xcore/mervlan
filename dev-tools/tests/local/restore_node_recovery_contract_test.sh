#!/bin/sh
# Behavioral contract for Restore's SSH readiness gate and canonical NODE
# follow-up ownership.  The orchestration fixture is extracted from the
# production Restore block so the ordering/skip assertions exercise the actual
# implementation rather than a parallel test-only reimplementation.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.restore-node.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15
. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || exit 1
merv_test_context_enable "$BASE_DIR" "$TEST_ROOT" || exit 1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
expect_fail() {
  "$@" >/dev/null 2>&1 && fail "accepted: $*"
  return 0
}
count_event() { awk -v event="$1" '$0 == event { n++ } END { print n + 0 }' "$EVENT_LOG"; }

export MERV_BASE="$BASE_DIR"
export MERV_SSH_TRUST_TEST_MODE=1
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_SSH_TRUST_ROOT="$TEST_ROOT/ssh_trust"
export MERV_SSH_TRUST_FILE="$MERV_SSH_TRUST_ROOT/known_hosts.v1"
export MERV_SSH_TRUST_PENDING_ROOT="$MERV_SSH_TRUST_ROOT/pending"
export MERV_SSH_TRUST_REQUESTS_ROOT="$MERV_SSH_TRUST_ROOT/requests"
export MERV_SSH_TRUST_STAGING_ROOT="$MERV_SSH_TRUST_ROOT/staging"
export MERV_SSH_TRUST_QUARANTINE_ROOT="$MERV_SSH_TRUST_ROOT/quarantine"
export MERV_SSH_TRUST_LOCK_PATH="$MERV_SSH_TRUST_ROOT/state.lock"
. "$BASE_DIR/settings/lib_json.sh" || fail json-library
. "$BASE_DIR/settings/lib_boot_integrity.sh" || fail boot-integrity-library
. "$BASE_DIR/settings/lib_ssh.sh" || fail ssh-library

HELPERS="$TEST_ROOT/restore-helpers.sh"
awk '
  /^mb_regular_file_mode\(\) \{/ { emit=1 }
  /^mb_validate_archive_tree\(\) \{/ { exit }
  emit { print }
' "$BASE_DIR/functions/mervlan_backup.sh" > "$HELPERS" || fail helper-extraction

SETTINGS_FILE="$TEST_ROOT/settings.json"
SSH_KEY="$TEST_ROOT/vlan_manager"
SSH_PUBKEY="$TEST_ROOT/vlan_manager.pub"
DROPBEARKEY="$TEST_ROOT/fake-dropbearkey"
export SETTINGS_FILE SSH_KEY SSH_PUBKEY DROPBEARKEY
printf '%s\n' '{' '  "SSH_KEYS_INSTALLED": "1",' '  "SSH_USER": "admin",' '  "SSH_PORT": "22"' '}' > "$SETTINGS_FILE" || fail settings-fixture

ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key1" >/dev/null 2>&1 || fail key1-generation
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key2" >/dev/null 2>&1 || fail key2-generation
KEY1=$(awk '{print $2; exit}' "$TEST_ROOT/key1.pub") || fail key1-read
KEY2=$(awk '{print $2; exit}' "$TEST_ROOT/key2.pub") || fail key2-read
MATERIAL1="ssh-ed25519 $KEY1"
MATERIAL2="ssh-ed25519 $KEY2"
export MATERIAL1 MATERIAL2
printf '%s\n' '#!/bin/sh' \
  '[ "${FAKE_DROPBEAR_MODE:-}" = fail ] && exit 1' \
  'printf "%s\\n" "${FAKE_DROPBEAR_MATERIAL:-$MATERIAL1}"' > "$DROPBEARKEY" || fail dropbear-fixture
chmod 700 "$DROPBEARKEY" || fail dropbear-mode
printf 'private fixture\n' > "$SSH_KEY" || fail private-fixture
printf '%s comment\n' "$MATERIAL1" > "$SSH_PUBKEY" || fail public-fixture
chmod 600 "$SSH_KEY" || fail private-mode
chmod 644 "$SSH_PUBKEY" || fail public-mode

merv_ssh_trust_init >/dev/null 2>&1 || fail trust-init
FP1=$(merv_ssh_trust_derive_fingerprint ssh-ed25519 "$KEY1") || fail key-fingerprint
NODE1=$(merv_ssh_trust_node_id 1 none 192.168.186.201 22) || fail node-id
TRUST_STAGE=$(merv_ssh_trust_stage_record 1 none 192.168.186.201 22 ssh-ed25519 "$KEY1" "$FP1") || fail trust-stage
merv_ssh_trust_publish_stage "$TRUST_STAGE" >/dev/null 2>&1 || fail trust-publish
MB_TARGET_KEY_FINGERPRINT="$FP1"
export MB_TARGET_KEY_FINGERPRINT

. "$HELPERS" || fail helper-load

BOOT_STATE_HELPER="$TEST_ROOT/restore-boot-state.sh"
sed -n '/^mb_read_boot_state() {/,/^}/p' "$BASE_DIR/functions/mervlan_backup.sh" > "$BOOT_STATE_HELPER" || fail boot-state-extraction
. "$BOOT_STATE_HELPER" || fail boot-state-load
for _state_root in "$TEST_ROOT/current-state" "$TEST_ROOT/backup-state"; do
  mkdir -p "$_state_root/settings" || fail "boot-state fixture: $_state_root"
  printf '%s\n' '{' '  "General": {' '    "BOOT_ENABLED": "1"' '  }' '}' > "$_state_root/settings/settings.json" || fail boot-state-valid-write
  [ "$(mb_read_boot_state "$_state_root")" = 1 ] || fail "valid boot-state rejected: $_state_root"
  for _bad in \
    '{"General":{"IS_NODE":"0"}}' \
    '{"General":{"BOOT_ENABLED":"true"}}' \
    '{"General":{"BOOT_ENABLED":"1","BOOT_ENABLED":"0"}}' \
    '{"Other":{"BOOT_ENABLED":"0"}}' \
    '{"General":{"BOOT_ENABLED":"0"'; do
    printf '%s\n' "$_bad" > "$_state_root/settings/settings.json"
    cp "$_state_root/settings/settings.json" "$TEST_ROOT/restore-settings.before" || fail boot-state-snapshot
    if mb_read_boot_state "$_state_root" >/dev/null 2>&1; then fail "invalid current/backup boot state accepted: $_state_root"; fi
    cmp -s "$TEST_ROOT/restore-settings.before" "$_state_root/settings/settings.json" || fail 'Restore boot-state preflight changed settings'
  done
done
grep -Fq 'Restore refused: current General.BOOT_ENABLED is missing' "$BASE_DIR/functions/mervlan_backup.sh" || fail 'current Restore preference preflight missing'
grep -Fq 'Restore refused: selected backup General.BOOT_ENABLED is missing' "$BASE_DIR/functions/mervlan_backup.sh" || fail 'backup Restore preference preflight missing'
pass strict-current-and-selected-backup-boot-preflight

FAKE_DROPBEAR_MODE=fail
export FAKE_DROPBEAR_MODE
expect_fail mb_validate_restored_ssh_readiness '1 192.168.186.201' && pass broken-private-key
FAKE_DROPBEAR_MODE=ok
export FAKE_DROPBEAR_MODE

mb_validate_restored_ssh_readiness '1 192.168.186.201' || fail valid-readiness
pass valid-keypair-and-trust-readiness

FAKE_DROPBEAR_MATERIAL="$MATERIAL2"
export FAKE_DROPBEAR_MATERIAL
expect_fail mb_validate_restored_ssh_readiness '1 192.168.186.201' && pass mismatched-keypair
FAKE_DROPBEAR_MATERIAL="$MATERIAL1"
export FAKE_DROPBEAR_MATERIAL

chmod 644 "$SSH_KEY" || fail unsafe-private-mode
expect_fail mb_validate_restored_ssh_readiness '1 192.168.186.201' && pass unsafe-private-mode-rejected
chmod 600 "$SSH_KEY" || fail restore-private-mode

cp -p "$MERV_SSH_TRUST_FILE" "$TEST_ROOT/trust.snapshot" || fail trust-snapshot
rm -f "$MERV_SSH_TRUST_FILE" || fail trust-remove
expect_fail mb_validate_restored_ssh_readiness '1 192.168.186.201' && pass missing-trust-rejected
cp -p "$TEST_ROOT/trust.snapshot" "$MERV_SSH_TRUST_FILE" || fail trust-restore
chmod 600 "$MERV_SSH_TRUST_FILE" || fail trust-restore-mode

ORCHESTRATION="$TEST_ROOT/restore-followups.sh"
{
  printf '%s\n' 'run_restore_followups() {'
  awk '
    /^  _mb_node_sync_ok=1$/ { emit=1 }
    /^  mb_write_result running verifying_runtime/ { exit }
    emit { sub(/^  /, ""); print }
  ' "$BASE_DIR/functions/mervlan_backup.sh"
  printf '%s\n' '}'
} > "$ORCHESTRATION" || fail orchestration-extraction

FAKE_BASE="$TEST_ROOT/fakebase"
mkdir -p "$FAKE_BASE/functions" || fail fakebase
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" sync >> "$EVENT_LOG"' 'exit "${SYNC_RC:-0}"' > "$FAKE_BASE/functions/sync_nodes.sh" || fail sync-fixture
chmod 700 "$FAKE_BASE/functions/sync_nodes.sh" || fail sync-mode
. "$ORCHESTRATION" || fail orchestration-load

warn() { printf 'warn:%s\n' "$*" >> "$EVENT_LOG"; }
mb_write_result() { printf 'result:%s\n' "$2" >> "$EVENT_LOG"; }
mb_validate_restored_ssh_readiness() { printf '%s\n' readiness >> "$EVENT_LOG"; return "${READINESS_RC:-0}"; }
mb_push_restored_mac_db() { printf '%s\n' mac >> "$EVENT_LOG"; return 0; }

MERV_BASE="$FAKE_BASE"
MB_TEST_MODE=0
_mb_restored_nodes='1 192.168.186.201'
_mb_target_boot=1
EVENT_LOG="$TEST_ROOT/events-pass"
export MERV_BASE MB_TEST_MODE _mb_restored_nodes _mb_target_boot EVENT_LOG
: > "$EVENT_LOG"
SYNC_RC=0 READINESS_RC=0
export SYNC_RC READINESS_RC
_mb_partial=0
run_restore_followups || fail successful-followups
[ "$_mb_node_sync_ok" = 1 ] || fail successful-sync-state
[ "$(count_event readiness)" = 1 ] || fail readiness-before-sync
[ "$(count_event sync)" = 1 ] || fail one-sync
[ "$(count_event mac)" = 1 ] || fail mac-after-sync
grep -Fq 'nodeenable' "$EVENT_LOG" && fail restore-issued-node-boot
pass canonical-sync-order-and-single-node-build

EVENT_LOG="$TEST_ROOT/events-fail"
: > "$EVENT_LOG"
SYNC_RC=1 READINESS_RC=0
export EVENT_LOG SYNC_RC READINESS_RC
_mb_partial=0
run_restore_followups || fail failed-followups-fixture
[ "$_mb_node_sync_ok" = 0 ] || fail failed-sync-state
[ "$(count_event sync)" = 1 ] || fail failed-sync-count
[ "$(count_event mac)" = 0 ] || fail mac-after-failed-sync
grep -Fq 'Skipping Restore-specific NODE follow-up actions' "$EVENT_LOG" || fail failed-sync-skip-message
pass failed-sync-skips-dependent-followups

EVENT_LOG="$TEST_ROOT/events-readiness"
: > "$EVENT_LOG"
SYNC_RC=0 READINESS_RC=1
export EVENT_LOG SYNC_RC READINESS_RC
_mb_partial=0
run_restore_followups || fail failed-readiness-fixture
[ "$(count_event sync)" = 0 ] || fail sync-after-failed-readiness
[ "$(count_event mac)" = 0 ] || fail mac-after-failed-readiness
pass failed-readiness-skips-sync

RUNTIME="$TEST_ROOT/runtime-functions.sh"
awk '
  /^mb_runtime_report_matches\(\) \{/ { emit=1 }
  /^mb_rollback_restore\(\) \{/ { exit }
  emit { print }
' "$BASE_DIR/functions/mervlan_backup.sh" > "$RUNTIME" || fail runtime-extraction
. "$RUNTIME" || fail runtime-load
RUNTIME_BASE="$TEST_ROOT/runtime"
RUNTIME_SCRIPTS="$TEST_ROOT/router-scripts"
SERVICES_START="$RUNTIME_SCRIPTS/services-start"
SERVICE_EVENT_WRAPPER="$RUNTIME_SCRIPTS/service-event"
CRU_BIN="$TEST_ROOT/cru"
mkdir -p "$RUNTIME_BASE/settings" "$RUNTIME_BASE/functions" "$RUNTIME_SCRIPTS" || fail main-report-dir
cp "$BASE_DIR/settings/lib_json.sh" "$RUNTIME_BASE/settings/lib_json.sh" || fail runtime-json
cp "$BASE_DIR/settings/lib_boot_integrity.sh" "$RUNTIME_BASE/settings/lib_boot_integrity.sh" || fail runtime-integrity
cat > "$RUNTIME_BASE/settings/settings.json" <<'JSON'
{
  "General": {
    "BOOT_ENABLED": "1",
    "IS_NODE": "0"
  }
}
JSON
cat > "$CRU_BIN" <<'CRU'
#!/bin/sh
[ "${1:-}" = l ] || exit 2
cat "$RUNTIME_CRON"
CRU
RUNTIME_CRON="$TEST_ROOT/runtime.cron"
export RUNTIME_CRON
chmod 755 "$CRU_BIN" || fail runtime-cru-mode
export SERVICES_START SERVICE_EVENT_WRAPPER CRU_BIN
write_runtime_hooks() {
  _manager="$1"
  {
    printf '%s\n' '#!/bin/sh'
    if [ "$_manager" = present ]; then
      cat <<HOOK
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
if $RUNTIME_BASE/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  $RUNTIME_BASE/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 10
$RUNTIME_BASE/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
    fi
    cat <<HOOK
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
$RUNTIME_BASE/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
  } > "$SERVICES_START"
  chmod 755 "$SERVICES_START"
  cat > "$SERVICE_EVENT_WRAPPER" <<HOOK
#!/bin/sh
### >>> MERVLAN START: service-event [tpl=service-event.v2.tpl md5=0123456789abcdef0123456789abcdef]
$RUNTIME_BASE/functions/service-event-handler.sh "\$@"
### <<< MERVLAN END: service-event [tpl=service-event.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
  chmod 755 "$SERVICE_EVENT_WRAPPER"
}
write_runtime_hooks present
printf '%s\n' "$RUNTIME_BASE/functions/heal_event.sh cron" > "$RUNTIME_CRON"
cat > "$RUNTIME_BASE/functions/mervlan_boot.sh" <<'BOOT'
#!/bin/sh
. "$MERV_BASE/settings/lib_json.sh"
. "$MERV_BASE/settings/lib_boot_integrity.sh"
preference=$(merv_boot_read_preference "$MERV_BASE/settings/settings.json") || exit 3
manager=$(merv_boot_hook_state "$SERVICES_START" services-start)
addon=$(merv_boot_hook_state "$SERVICES_START" services-start-addon)
event=$(merv_boot_hook_state "$SERVICE_EVENT_WRAPPER" service-event)
merv_boot_cron_state "$CRU_BIN" "$MERV_BASE" >/dev/null
cron=$MERV_BOOT_CRON_STATE
[ "$addon" = present ] && addon=active
[ "$event" = present ] && event=active
if [ "${LEGACY_REPORT:-0}" = 1 ]; then
  printf 'REPORT hw=RT boot=%s addon=%s event=%s cron=%s is_node=no\n' "$preference" "$addon" "$event" "$cron"
else
  printf 'REPORT hw=RT boot=%s addon=%s event=%s cron=%s is_node=no manager_hook=%s\n' "$preference" "$addon" "$event" "$cron" "$manager"
fi
BOOT
chmod 700 "$RUNTIME_BASE/functions/mervlan_boot.sh" || fail main-report-mode
info() { :; }
error() { :; }
NODE_REPORT_MODE=good
NODE_CALL_LOG="$TEST_ROOT/node-calls"
: > "$NODE_CALL_LOG"
merv_ssh_exec() {
  printf '%s\n' call >> "$NODE_CALL_LOG"
  if [ "$NODE_REPORT_MODE" = good ]; then
    printf '%s\n' 'REPORT hw=RT boot=1 addon=node-on event=active cron=present is_node=yes manager_hook=present'
  else
    printf '%s\n' 'not-a-report'
  fi
}
MERV_BASE="$RUNTIME_BASE"
export MERV_BASE
MB_TEST_MODE=0
mb_verify_restored_runtime '1 192.168.186.201' 1 1 || fail runtime-success
[ "$(wc -l < "$NODE_CALL_LOG" | tr -d '[:space:]')" -eq 1 ] || fail runtime-success-single-read
[ "$MB_VERIFY_PARTIAL" -eq 0 ] || fail runtime-success-partial

# An older selected archive may have a known pre-current manager payload and
# emit a report without manager_hook. The retained controller verifier checks
# the actual files and permits only this explicit legacy-restore path.
cat > "$SERVICES_START" <<HOOK
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
$RUNTIME_BASE/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
sleep 10
$RUNTIME_BASE/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
$RUNTIME_BASE/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
sleep 5
$RUNTIME_BASE/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
chmod 755 "$SERVICES_START" || fail legacy-services-mode
LEGACY_REPORT=1
export LEGACY_REPORT
mb_verify_restored_runtime '' 1 0 1 || fail 'known legacy archive/report was not verified directly'
LEGACY_REPORT=0
export LEGACY_REPORT
pass 'legacy Restore report without manager_hook is verified against the real hook files'

write_runtime_hooks absent
if mb_verify_restored_runtime '' 1 0; then fail 'Restore accepted BOOT_ENABLED=1 with manager absent'; fi
 [ "${MERV_BOOT_VERIFY_REASON:-}" = manager_mismatch ] || fail 'Restore ON mismatch reason was not precise'
merv_boot_hook_state "$SERVICES_START" services-start >/dev/null
[ "$MERV_BOOT_HOOK_STATE" = absent ] || fail 'Restore ON mismatch fixture manager was not absent'
[ "$(merv_boot_read_preference "$RUNTIME_BASE/settings/settings.json")" = 1 ] || fail 'Restore ON mismatch rewrote the configured preference'
printf '%s\n' "$RUNTIME_BASE/functions/heal_event.sh cron" > "$RUNTIME_CRON"
sed 's/"BOOT_ENABLED": "1"/"BOOT_ENABLED": "0"/' "$RUNTIME_BASE/settings/settings.json" > "$TEST_ROOT/settings.off"
mv "$TEST_ROOT/settings.off" "$RUNTIME_BASE/settings/settings.json"
write_runtime_hooks present
if mb_verify_restored_runtime '' 0 0; then fail 'Restore accepted BOOT_ENABLED=0 with manager present'; fi
[ "${MERV_BOOT_VERIFY_REASON:-}" = manager_mismatch ] || fail 'Restore OFF mismatch reason was not precise'
[ "$(merv_boot_read_preference "$RUNTIME_BASE/settings/settings.json")" = 0 ] || fail 'Restore OFF mismatch rewrote the configured preference'
write_runtime_hooks absent
: > "$RUNTIME_CRON"
mb_verify_restored_runtime '' 0 0 || fail 'healthy disabled Restore hook state failed'
pass 'Restore effective-state verifier rejects both preference/manager mismatches'
sed 's/"BOOT_ENABLED": "0"/"BOOT_ENABLED": "1"/' "$RUNTIME_BASE/settings/settings.json" > "$TEST_ROOT/settings.on"
mv "$TEST_ROOT/settings.on" "$RUNTIME_BASE/settings/settings.json"
write_runtime_hooks present
printf '%s\n' "$RUNTIME_BASE/functions/heal_event.sh cron" > "$RUNTIME_CRON"
NODE_REPORT_MODE=bad
: > "$NODE_CALL_LOG"
mb_verify_restored_runtime '1 192.168.186.201' 1 1 || fail runtime-mismatch-return
[ "$(wc -l < "$NODE_CALL_LOG" | tr -d '[:space:]')" -eq 1 ] || fail runtime-mismatch-retry
[ "$MB_VERIFY_PARTIAL" -eq 1 ] || fail runtime-mismatch-partial
pass read-only-runtime-verification-no-retry

grep -Fq 'mb_apply_restored_node_boot_state' "$BASE_DIR/functions/mervlan_backup.sh" && fail restore-boot-helper-remains
grep -Fq '_mb_success_message="Restore completed with warnings."' "$BASE_DIR/functions/mervlan_backup.sh" || fail partial-wording
grep -Fq 'mb_write_result partial complete "$_mb_success_message"' "$BASE_DIR/functions/mervlan_backup.sh" || fail partial-result-message
pass partial-result-wording

printf 'PASS restore node recovery contract\n'
