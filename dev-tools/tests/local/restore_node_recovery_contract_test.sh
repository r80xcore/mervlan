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
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "REPORT hw=RT boot=1 addon=active event=active cron=present is_node=no"' > "$TEST_ROOT/mervlan_boot.sh" || fail main-report-fixture
mkdir -p "$TEST_ROOT/functions" || fail main-report-dir
mv "$TEST_ROOT/mervlan_boot.sh" "$TEST_ROOT/functions/mervlan_boot.sh" || fail main-report-place
chmod 700 "$TEST_ROOT/functions/mervlan_boot.sh" || fail main-report-mode
info() { :; }
error() { :; }
NODE_REPORT_MODE=good
NODE_CALL_LOG="$TEST_ROOT/node-calls"
: > "$NODE_CALL_LOG"
merv_ssh_exec() {
  printf '%s\n' call >> "$NODE_CALL_LOG"
  if [ "$NODE_REPORT_MODE" = good ]; then
    printf '%s\n' 'REPORT hw=RT boot=1 addon=node-on event=active cron=present is_node=yes'
  else
    printf '%s\n' 'not-a-report'
  fi
}
MERV_BASE="$TEST_ROOT"
MB_TEST_MODE=0
mb_verify_restored_runtime '1 192.168.186.201' 1 1 || fail runtime-success
[ "$(wc -l < "$NODE_CALL_LOG" | tr -d '[:space:]')" -eq 1 ] || fail runtime-success-single-read
[ "$MB_VERIFY_PARTIAL" -eq 0 ] || fail runtime-success-partial
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
