#!/bin/sh
# Focused contract test for durable SSH trust in restorable backup state.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.backup-trust.$$"
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
. "$BASE_DIR/settings/var_settings.sh" || fail var-settings
. "$BASE_DIR/settings/lib_json.sh" || fail json-library
. "$BASE_DIR/settings/lib_ssh.sh" || fail ssh-library
. "$BASE_DIR/settings/lib_backup_state.sh" || fail backup-state-library

merv_ssh_trust_init >/dev/null 2>&1 || fail trust-init
cp -p "$MERV_SSH_TRUST_FILE" "$TEST_ROOT/header-only-trust" || fail header-trust-snapshot
command -v ssh-keygen >/dev/null 2>&1 || fail ssh-keygen-unavailable
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key1" >/dev/null 2>&1 || fail key1-generation
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key2" >/dev/null 2>&1 || fail key2-generation
KEY1=$(cut -d ' ' -f 2 "$TEST_ROOT/key1.pub") || fail key1-read
KEY2=$(cut -d ' ' -f 2 "$TEST_ROOT/key2.pub") || fail key2-read
MAC1=AA:BB:CC:DD:EE:01
NODE1=$(merv_ssh_trust_node_id 1 "$MAC1" 192.168.1.2 22) || fail node-id
FP1=$(merv_ssh_trust_derive_fingerprint ssh-ed25519 "$KEY1") || fail key1-fingerprint
FP2=$(merv_ssh_trust_derive_fingerprint ssh-ed25519 "$KEY2") || fail key2-fingerprint

TRUST_STAGE=$(merv_ssh_trust_stage_record 1 "$MAC1" 192.168.1.2 22 ssh-ed25519 "$KEY1" "$FP1") || fail trust-stage
merv_ssh_trust_publish_stage "$TRUST_STAGE" >/dev/null 2>&1 || fail trust-publish

NODE_SETTINGS="$TEST_ROOT/node-settings.json"
cp -p "$BASE_DIR/settings/settings.json" "$NODE_SETTINGS" || fail node-settings-copy
json_set_flag NODE1 192.168.1.2 "$NODE_SETTINGS" >/dev/null || fail node-setting-node
json_set_flag AUTO_NODE1_MAC "$MAC1" "$NODE_SETTINGS" >/dev/null || fail node-setting-mac

SOURCE="$TEST_ROOT/source"
mkdir -p "$SOURCE/settings" "$SOURCE/functions" "$SOURCE/www" || fail source-mkdir
cp -p "$NODE_SETTINGS" "$SOURCE/settings/settings.json" || fail source-settings
for _required in \
  settings/var_settings.sh settings/lib_selftest_context.sh settings/lib_json.sh settings/lib_ssh.sh \
  settings/lib_ssh_trust.sh settings/lib_backup_state.sh; do
  mkdir -p "$SOURCE/$(dirname "$_required")" || fail source-required-dir
  cp -p "$BASE_DIR/$_required" "$SOURCE/$_required" || fail source-required-copy
done
for _required in install.sh uninstall.sh changelog.txt mervlan.asp \
  functions/update_mervlan.sh functions/mervlan_boot.sh www/index.html; do
  mkdir -p "$SOURCE/$(dirname "$_required")" || fail source-runtime-dir
  printf 'fixture\n' > "$SOURCE/$_required" || fail source-runtime-file
done
cp -p "$BASE_DIR/functions/mervlan_recover.sh" "$SOURCE/functions/mervlan_recover.sh" || fail source-recovery-copy
chmod 755 "$SOURCE/functions/mervlan_recover.sh" || fail source-recovery-mode
printf 'source\n' > "$SOURCE/payload.txt" || fail source-payload

MODERN_PARENT="$TEST_ROOT/modern-parent"
MODERN_TREE="$MODERN_PARENT/mervlan"
mkdir -p "$MODERN_PARENT" || fail modern-parent
merv_backup_state_prepare_tree "$SOURCE" "$MODERN_TREE" \
  "$SOURCE/settings/settings.json" "$MERV_SSH_TRUST_FILE" "$TEST_ROOT" || fail modern-prepare
[ ! -e "$SOURCE/.backup_state" ] || fail source-mutated
[ -f "$MODERN_TREE/.backup_state/format" ] || fail modern-marker
[ -f "$MODERN_TREE/.backup_state/ssh_trust/known_hosts.v1" ] || fail modern-trust-file
grep -qx 'format=1' "$MODERN_TREE/.backup_state/format" || fail modern-format
grep -qx 'trust=present' "$MODERN_TREE/.backup_state/format" || fail modern-trust-marker
merv_backup_state_validate_tree "$MODERN_TREE" "$MODERN_TREE/settings/settings.json" "$TEST_ROOT" || fail modern-validation
[ "$MERV_BACKUP_STATE_FORMAT" = modern ] || fail modern-format-result
[ "$MERV_BACKUP_STATE_TRUST_PRESENT" = 1 ] || fail modern-trust-result
(
  cp() { return 61; }
  if merv_backup_state_prepare_tree "$SOURCE" "$TEST_ROOT/source-copy-failure/mervlan" \
      "$SOURCE/settings/settings.json" "$MERV_SSH_TRUST_FILE" "$TEST_ROOT"; then
    exit 1
  else
    _mbt_rc=$?
  fi
  [ "$_mbt_rc" -eq 61 ] && [ "$MERV_BACKUP_STATE_LAST_ERROR" = source-copy-failed ]
) || fail source-copy-diagnostic
pass backup-state-source-copy-reason
mkdir -p "$TEST_ROOT/node-parse-failure" || fail configured-node-parse-fixture
(
  merv_backup_state_configured_nodes() { return 62; }
  if merv_backup_state_prepare_tree "$SOURCE" "$TEST_ROOT/node-parse-failure/mervlan" \
      "$SOURCE/settings/settings.json" "$MERV_SSH_TRUST_FILE" "$TEST_ROOT"; then
    exit 1
  else
    _mbt_rc=$?
  fi
  [ "$_mbt_rc" -eq 62 ] && [ "$MERV_BACKUP_STATE_LAST_ERROR" = configured-nodes-invalid ]
) || fail configured-node-parse-diagnostic
pass backup-state-configured-node-reason
(
  mkdir -p "$TEST_ROOT/payload-failure"
  chmod() {
    case "$2" in */.backup_state) return 63 ;; esac
    command chmod "$@"
  }
  if merv_backup_state_prepare_tree "$SOURCE" "$TEST_ROOT/payload-failure/mervlan" \
      "$SOURCE/settings/settings.json" "$MERV_SSH_TRUST_FILE" "$TEST_ROOT"; then
    exit 1
  else
    _mbt_rc=$?
  fi
  [ "$_mbt_rc" -eq 63 ] && [ "$MERV_BACKUP_STATE_LAST_ERROR" = backup-state-payload-failed ]
) || fail backup-state-payload-diagnostic
pass backup-state-payload-reason
mkdir -p "$TEST_ROOT/workspace-conflict/mervlan" || fail workspace-conflict-fixture
if merv_backup_state_prepare_tree "$SOURCE" "$TEST_ROOT/workspace-conflict/mervlan" \
    "$SOURCE/settings/settings.json" "$MERV_SSH_TRUST_FILE" "$TEST_ROOT"; then
  fail private-workspace-conflict-accepted
else
  [ "$MERV_BACKUP_STATE_LAST_ERROR" = private-workspace-conflict ] || fail private-workspace-conflict-reason
fi
pass backup-state-private-workspace-reason
MODERN_ARCHIVE="$TEST_ROOT/modern.tar.gz"
tar -czf "$MODERN_ARCHIVE" -C "$MODERN_PARENT" mervlan || fail modern-archive
tar -tzf "$MODERN_ARCHIVE" > "$TEST_ROOT/modern.list" || fail modern-list
grep -Fq 'mervlan/.backup_state/ssh_trust/known_hosts.v1' "$TEST_ROOT/modern.list" || fail archive-trust-payload
if grep -Eq '/(pending|requests|staging|quarantine)(/|$)|/state\.lock$' "$TEST_ROOT/modern.list"; then
  fail transient-trust-state-archived
fi
pass modern-manual-backup-payload

# Target-side preflight uses the private backed-up trust context. The
# canonical test trust database is not used for this check.
printf '%s\tssh-ed25519\t%s\t%s\n' "$NODE1" "$KEY1" "$FP1" > "$TEST_ROOT/probe.tsv" || fail probe-fixture
export MERV_SSH_TEST_PROBE_FILE="$TEST_ROOT/probe.tsv"
cp -p "$TEST_ROOT/header-only-trust" "$MERV_SSH_TRUST_FILE" || fail canonical-empty-setup
cp -p "$MERV_SSH_TRUST_FILE" "$TEST_ROOT/canonical-before" || fail canonical-snapshot
mkdir -p "$TEST_ROOT/preflight" || fail preflight-workspace
merv_backup_state_preflight_with_trust \
  "$MODERN_TREE/settings/settings.json" \
  "$MODERN_TREE/.backup_state/ssh_trust/known_hosts.v1" \
  "$TEST_ROOT/preflight" || fail backed-up-trust-preflight
cmp -s "$TEST_ROOT/canonical-before" "$MERV_SSH_TRUST_FILE" || fail preflight-mutated-canonical-trust
pass target-preflight-uses-backed-up-trust

printf '%s\tssh-ed25519\t%s\t%s\n' "$NODE1" "$KEY2" "$FP2" > "$TEST_ROOT/probe.tsv" || fail mismatch-probe
mkdir -p "$TEST_ROOT/preflight-mismatch" || fail mismatch-workspace
expect_fail merv_backup_state_preflight_with_trust \
  "$MODERN_TREE/settings/settings.json" \
  "$MODERN_TREE/.backup_state/ssh_trust/known_hosts.v1" \
  "$TEST_ROOT/preflight-mismatch"
cmp -s "$TEST_ROOT/canonical-before" "$MERV_SSH_TRUST_FILE" || fail mismatch-mutated-canonical-trust
pass saved-host-key-mismatch-fails-closed

# The reserved tree is removed from the private candidate before activation.
RESTORE_TREE="$TEST_ROOT/restore-tree"
cp -pR "$MODERN_TREE" "$RESTORE_TREE" || fail restore-copy
rm -rf "$RESTORE_TREE/.backup_state" || fail restore-strip
[ ! -e "$RESTORE_TREE/.backup_state" ] || fail backup-state-retained
pass backup-only-payload-stripped

# Configured clusters must not produce a modern archive without trust, while a
# no-node installation remains valid with an explicit absent marker.
MISSING_PARENT="$TEST_ROOT/missing-parent"
MISSING_TREE="$MISSING_PARENT/mervlan"
mkdir -p "$MISSING_PARENT" || fail missing-parent
expect_fail merv_backup_state_prepare_tree "$SOURCE" "$MISSING_TREE" \
  "$SOURCE/settings/settings.json" "$TEST_ROOT/no-such-trust" "$TEST_ROOT/missing-work"
[ "$MERV_BACKUP_STATE_LAST_ERROR" = trust-file-invalid ] || fail missing-trust-diagnostic
[ ! -e "$MISSING_TREE" ] || fail missing-trust-left-stage
pass configured-nodes-missing-trust-fails

BAD_TRUST="$TEST_ROOT/malformed-trust"
printf 'not-a-trust-db\n' > "$BAD_TRUST" || fail malformed-trust-fixture
mkdir -p "$TEST_ROOT/malformed-work" || fail malformed-work
expect_fail merv_backup_state_validate_trust_file "$BAD_TRUST" "$TEST_ROOT/malformed-work"
[ "$MERV_BACKUP_STATE_LAST_ERROR" = trust-validation-failed ] || fail malformed-trust-diagnostic
pass malformed-trust-fails

# Preserve the primary trust-validation result independently from context
# cleanup.  The same cases are exercised through the public tree-preparation
# caller below, which must retain both values while rejecting the candidate.
assert_trust_validation_case() {
  _atv_name="$1"
  _atv_validation_rc="$2"
  _atv_cleanup_rc="$3"
  _atv_expected_rc="$4"
  _atv_expected_reason="$5"
  _atv_expected_cleanup="$6"
  (
    TRUST_VALIDATION_RC="$_atv_validation_rc"
    TRUST_CONTEXT_CLEANUP_RC="$_atv_cleanup_rc"
    merv_backup_state_context_begin() {
      MERV_SSH_TRUST_FILE="$2"
      return 0
    }
    merv_ssh_trust_validate_file() { return "$TRUST_VALIDATION_RC"; }
    merv_backup_state_context_end() { return "$TRUST_CONTEXT_CLEANUP_RC"; }
    if merv_backup_state_validate_trust_file "$MERV_SSH_TRUST_FILE" "$TEST_ROOT/trust-matrix-work"; then
      _atv_actual_rc=0
    else
      _atv_actual_rc=$?
    fi
    [ "$_atv_actual_rc" -eq "$_atv_expected_rc" ] || exit 1
    [ "$MERV_BACKUP_STATE_LAST_ERROR" = "$_atv_expected_reason" ] || exit 1
    [ "${MERV_BACKUP_STATE_CLEANUP_ERROR:-}" = "$_atv_expected_cleanup" ] || exit 1
  ) || fail "trust-validation-matrix-$_atv_name"
}
assert_trust_validation_case fail54-fail55 54 55 54 trust-validation-failed 55
assert_trust_validation_case pass-pass 0 0 0 '' 0
assert_trust_validation_case fail54-pass 54 0 54 trust-validation-failed 0
assert_trust_validation_case pass-fail55 0 55 55 private-workspace-cleanup-failed 55
assert_trust_validation_case fail54-fail55 54 55 54 trust-validation-failed 55
pass trust-validation-cleanup-status-matrix

TRUST_CANONICAL_SNAPSHOT="$TEST_ROOT/trust-canonical-before-cleanup-matrix"
cp -p "$MERV_SSH_TRUST_FILE" "$TRUST_CANONICAL_SNAPSHOT" || fail trust-cleanup-canonical-snapshot
assert_prepare_trust_case() {
  _aptc_name="$1"
  _aptc_validation_rc="$2"
  _aptc_cleanup_rc="$3"
  _aptc_expected_rc="$4"
  _aptc_expected_reason="$5"
  _aptc_expected_cleanup="$6"
  _aptc_parent="$TEST_ROOT/trust-prepare-$_aptc_name"
  _aptc_stage="$_aptc_parent/mervlan"
  mkdir -p "$_aptc_parent" || fail "trust-prepare-fixture-$_aptc_name"
  (
    TRUST_VALIDATION_RC="$_aptc_validation_rc"
    TRUST_CONTEXT_CLEANUP_RC="$_aptc_cleanup_rc"
    merv_backup_state_context_begin() {
      MERV_SSH_TRUST_FILE="$2"
      return 0
    }
    merv_ssh_trust_validate_file() { return "$TRUST_VALIDATION_RC"; }
    merv_backup_state_context_end() { return "$TRUST_CONTEXT_CLEANUP_RC"; }
    if merv_backup_state_prepare_tree "$SOURCE" "$_aptc_stage" \
        "$SOURCE/settings/settings.json" "$MERV_SSH_TRUST_FILE" "$TEST_ROOT/trust-prepare-work"; then
      _aptc_actual_rc=0
    else
      _aptc_actual_rc=$?
    fi
    [ "$_aptc_actual_rc" -eq "$_aptc_expected_rc" ] || exit 1
    [ "$MERV_BACKUP_STATE_LAST_ERROR" = "$_aptc_expected_reason" ] || exit 1
    [ "$MERV_BACKUP_STATE_CLEANUP_ERROR" = "$_aptc_expected_cleanup" ] || exit 1
    if [ "$_aptc_expected_rc" -eq 0 ]; then
      [ -f "$_aptc_stage/.backup_state/format" ] || exit 1
    else
      [ ! -e "$_aptc_stage" ] && [ ! -L "$_aptc_stage" ] || exit 1
    fi
  ) || fail "trust-prepare-caller-$_aptc_name"
  cmp -s "$TRUST_CANONICAL_SNAPSHOT" "$MERV_SSH_TRUST_FILE" || fail "trust-prepare-canonical-mutated-$_aptc_name"
}
assert_prepare_trust_case pass-pass 0 0 0 '' 0
assert_prepare_trust_case fail54-pass 54 0 54 trust-validation-failed 0
assert_prepare_trust_case pass-fail55 0 55 55 private-workspace-cleanup-failed 55
assert_prepare_trust_case fail54-fail55 54 55 54 trust-validation-failed 55
pass backup-state-public-trust-cleanup-propagation

NO_NODE_SOURCE="$TEST_ROOT/no-node-source"
mkdir -p "$NO_NODE_SOURCE/settings" || fail no-node-mkdir
cp -p "$BASE_DIR/settings/settings.json" "$NO_NODE_SOURCE/settings/settings.json" || fail no-node-settings
NO_NODE_PARENT="$TEST_ROOT/no-node-parent"
NO_NODE_TREE="$NO_NODE_PARENT/mervlan"
mkdir -p "$NO_NODE_PARENT" || fail no-node-parent
merv_backup_state_prepare_tree "$NO_NODE_SOURCE" "$NO_NODE_TREE" \
  "$NO_NODE_SOURCE/settings/settings.json" "$TEST_ROOT/no-trust" "$TEST_ROOT/no-node-work" || fail no-node-prepare
grep -qx 'trust=absent' "$NO_NODE_TREE/.backup_state/format" || fail no-node-marker
pass no-node-backup-allowed

# Legacy behavior remains fail-closed without current trust, then succeeds only
# after the operator has already established matching canonical trust.
LEGACY_TREE="$TEST_ROOT/legacy"
mkdir -p "$LEGACY_TREE/settings" || fail legacy-mkdir
cp -p "$NODE_SETTINGS" "$LEGACY_TREE/settings/settings.json" || fail legacy-settings
printf '%s\tssh-ed25519\t%s\t%s\n' "$NODE1" "$KEY1" "$FP1" > "$TEST_ROOT/probe.tsv" || fail legacy-probe
expect_fail merv_ssh_preflight_settings_file "$LEGACY_TREE/settings/settings.json"
cp -p "$MODERN_TREE/.backup_state/ssh_trust/known_hosts.v1" "$MERV_SSH_TRUST_FILE" || fail legacy-trust-setup
merv_ssh_preflight_settings_file "$LEGACY_TREE/settings/settings.json" || fail legacy-matching-trust
pass legacy-backup-compatibility

# Archive integrity metadata remains authoritative if the payload is changed.
TAMPERED="$TEST_ROOT/tampered.tar.gz"
cp -p "$MODERN_ARCHIVE" "$TAMPERED" || fail tampered-copy
printf 'tamper\n' >> "$TAMPERED" || fail tampered-write
[ "$(md5sum "$MODERN_ARCHIVE" | awk '{print $1}')" != "$(md5sum "$TAMPERED" | awk '{print $1}')" ] || fail tamper-undetected
pass archive-tampering-changes-integrity

# Standalone emergency Recovery accepts the modern archive and strips the
# backup-only payload before its private candidate is considered active.
RECOVERY_ROOT="$TEST_ROOT/recovery-backups"
RECOVERY_TMP="$TEST_ROOT/recovery-tmp"
RECOVERY_ID=mervlan.manual.backup.20260924-000000.trust_dr_test.tar.gz
mkdir -p "$RECOVERY_ROOT" || fail recovery-root
cp -p "$BASE_DIR/settings/lib_json.sh" "$RECOVERY_ROOT/lib_json.sh" || fail recovery-json-helper
cp -p "$BASE_DIR/settings/lib_boot_integrity.sh" "$RECOVERY_ROOT/lib_boot_integrity.sh" || fail recovery-integrity-helper
chmod 600 "$RECOVERY_ROOT/lib_json.sh" "$RECOVERY_ROOT/lib_boot_integrity.sh" || fail recovery-helper-mode
cp -p "$MODERN_ARCHIVE" "$RECOVERY_ROOT/$RECOVERY_ID" || fail recovery-archive-copy
RECOVERY_MD5=$(md5sum "$RECOVERY_ROOT/$RECOVERY_ID" | awk '{print $1}') || fail recovery-md5
{
  printf 'format=1\narchive=%s\nalgorithm=md5\nchecksum=%s\n' "$RECOVERY_ID" "$RECOVERY_MD5"
} > "$RECOVERY_ROOT/$RECOVERY_ID.meta" || fail recovery-meta
MERVLAN_RECOVERY_BACKUP_ROOT="$RECOVERY_ROOT" \
MERVLAN_RECOVERY_TMP_ROOT="$RECOVERY_TMP" \
MERVLAN_RECOVERY_ACTIVE_ROOT="$TEST_ROOT/recovery-active" \
MERVLAN_RECOVERY_STATE_ROOT="$TEST_ROOT/recovery-state" \
  sh "$BASE_DIR/functions/mervlan_recover.sh" check "$RECOVERY_ID" >"$TEST_ROOT/recovery-check.out" 2>&1 || {
    cat "$TEST_ROOT/recovery-check.out" >&2
    fail recovery-modern-check
  }
pass recover-check-modern-payload

# Exercise the production wrapper used by manual backups and the production
# automatic pre-update creator, rather than only testing the shared helper.
extract_function() {
  _brt_src="$1" _brt_name="$2" _brt_out="$3"
  awk -v name="$_brt_name" '
    !inside && $0 ~ "^[[:space:]]*" name "[[:space:]]*\\(\\)[[:space:]]*\\{" { inside=1 }
    inside {
      line=$0
      gsub(/\$\{[^}]*\}/, "", line)
      opens=gsub(/\{/, "{", line)
      closes=gsub(/\}/, "}", line)
      depth += opens - closes
      print
      if (depth == 0) exit
    }
  ' "$_brt_src" >"$_brt_out" || return 1
  [ -s "$_brt_out" ]
}

extract_function "$BASE_DIR/functions/mervlan_backup.sh" \
  mb_prepare_trust_transaction "$TEST_ROOT/trust-prepare.sh" || fail trust-prepare-extract
extract_function "$BASE_DIR/functions/mervlan_backup.sh" \
  mb_publish_target_trust "$TEST_ROOT/trust-publish.sh" || fail trust-publish-extract
extract_function "$BASE_DIR/functions/mervlan_backup.sh" \
  mb_restore_original_trust "$TEST_ROOT/trust-restore.sh" || fail trust-restore-extract
. "$TEST_ROOT/trust-prepare.sh" || fail trust-prepare-load
. "$TEST_ROOT/trust-publish.sh" || fail trust-publish-load
. "$TEST_ROOT/trust-restore.sh" || fail trust-restore-load
TRUST_A="$TEST_ROOT/trust-a.v1"
cp -p "$MERV_SSH_TRUST_FILE" "$TRUST_A" || fail trust-a-copy
TRUST_B_ROOT="$TEST_ROOT/trust-b"
MERV_SSH_TRUST_ROOT="$TRUST_B_ROOT"
MERV_SSH_TRUST_FILE="$TRUST_B_ROOT/known_hosts.v1"
MERV_SSH_TRUST_PENDING_ROOT="$TRUST_B_ROOT/pending"
MERV_SSH_TRUST_REQUESTS_ROOT="$TRUST_B_ROOT/requests"
MERV_SSH_TRUST_STAGING_ROOT="$TRUST_B_ROOT/staging"
MERV_SSH_TRUST_QUARANTINE_ROOT="$TRUST_B_ROOT/quarantine"
MERV_SSH_TRUST_LOCK_PATH="$TRUST_B_ROOT/state.lock"
merv_ssh_trust_init >/dev/null 2>&1 || fail trust-b-init
TRUST_B_STAGE=$(merv_ssh_trust_stage_record 1 "$MAC1" 192.168.1.2 22 ssh-ed25519 "$KEY2" "$FP2") || fail trust-b-stage
merv_ssh_trust_publish_stage "$TRUST_B_STAGE" >/dev/null 2>&1 || fail trust-b-publish
TRUST_B="$TEST_ROOT/trust-b.v1"
cp -p "$MERV_SSH_TRUST_FILE" "$TRUST_B" || fail trust-b-copy
MERV_SSH_TRUST_ROOT="$TEST_ROOT/ssh_trust"
MERV_SSH_TRUST_FILE="$MERV_SSH_TRUST_ROOT/known_hosts.v1"
MERV_SSH_TRUST_PENDING_ROOT="$MERV_SSH_TRUST_ROOT/pending"
MERV_SSH_TRUST_REQUESTS_ROOT="$MERV_SSH_TRUST_ROOT/requests"
MERV_SSH_TRUST_STAGING_ROOT="$MERV_SSH_TRUST_ROOT/staging"
MERV_SSH_TRUST_QUARANTINE_ROOT="$MERV_SSH_TRUST_ROOT/quarantine"
MERV_SSH_TRUST_LOCK_PATH="$MERV_SSH_TRUST_ROOT/state.lock"
cp -p "$TRUST_A" "$MERV_SSH_TRUST_FILE" || fail trust-a-restore
merv_ssh_trust_find_cache_clear
unset MERV_SSH_TRUST_VALIDATED_FILE MERV_SSH_TRUST_VALIDATED_DIGEST MERV_SSH_TRUST_VALIDATION_DIGEST
MB_WORK_ROOT="$TEST_ROOT/trust-transaction-work"
mkdir -p "$MB_WORK_ROOT" || fail trust-transaction-work
MB_TRUST_TRANSACTION_ACTIVE=0
MB_TRUST_ORIGINAL_PRESENT=0
MB_TRUST_ORIGINAL_FILE=""
mb_prepare_trust_transaction || fail trust-transaction-prepare
MB_TRUST_TARGET_MODE=modern
MB_TRUST_TARGET_PRESENT=1
MB_TRUST_TARGET_FILE="$TRUST_B"
mb_publish_target_trust || fail trust-b-activation
cmp -s "$TRUST_B" "$MERV_SSH_TRUST_FILE" || fail trust-b-not-published
mb_restore_original_trust || fail trust-a-rollback
cmp -s "$TRUST_A" "$MERV_SSH_TRUST_FILE" || fail trust-a-not-restored
pass restore-rollback-restores-old-trust

rm -f "$MERV_SSH_TRUST_FILE" || fail trust-absent-setup
MB_TRUST_TRANSACTION_ACTIVE=0
MB_TRUST_ORIGINAL_PRESENT=0
MB_TRUST_ORIGINAL_FILE=""
mb_prepare_trust_transaction || fail absent-transaction-prepare
MB_TRUST_TARGET_MODE=modern
MB_TRUST_TARGET_PRESENT=1
MB_TRUST_TARGET_FILE="$TRUST_B"
mb_publish_target_trust || fail absent-target-publish
mb_restore_original_trust || fail absent-trust-rollback
[ ! -e "$MERV_SSH_TRUST_FILE" ] || fail absent-trust-not-restored
pass rollback-restores-original-trust-absence
cp -p "$TRUST_A" "$MERV_SSH_TRUST_FILE" || fail trust-a-final-restore
extract_function "$BASE_DIR/functions/mervlan_backup.sh" \
  mb_publish_restore_undo "$TEST_ROOT/undo-helper.sh" || fail undo-extract
grep -Fq 'MB_TRUST_ORIGINAL_FILE' "$TEST_ROOT/undo-helper.sh" || fail undo-trust-source
pass undo-restore-captures-prior-trust

extract_function "$BASE_DIR/functions/mervlan_backup.sh" \
  mb_create_archive_from_tree "$TEST_ROOT/manual-wrapper.sh" || fail manual-wrapper-extract
. "$TEST_ROOT/manual-wrapper.sh" || fail manual-wrapper-load
MANUAL_WRAPPER_WORK="$TEST_ROOT/manual-wrapper-work"
mkdir -p "$MANUAL_WRAPPER_WORK" || fail manual-wrapper-work
MANUAL_WRAPPER_ARCHIVE="$TEST_ROOT/manual-wrapper.tar.gz"
MB_PRESERVE_WORK=0
mb_create_archive_from_tree "$SOURCE" "$MANUAL_WRAPPER_ARCHIVE" \
  "$SOURCE/settings/settings.json" "$MERV_SSH_TRUST_FILE" "$MANUAL_WRAPPER_WORK" || fail manual-wrapper-create
tar -tzf "$MANUAL_WRAPPER_ARCHIVE" > "$TEST_ROOT/manual-wrapper.list" || fail manual-wrapper-list
grep -Fq 'source/.backup_state/ssh_trust/known_hosts.v1' "$TEST_ROOT/manual-wrapper.list" || fail manual-wrapper-payload
pass production-manual-archive-wrapper

extract_function "$BASE_DIR/functions/update_mervlan.sh" \
  update_backup_file_size_bytes "$TEST_ROOT/preupdate-size-helper.sh" || fail preupdate-size-helper-extract
extract_function "$BASE_DIR/functions/update_mervlan.sh" \
  update_checksum_value "$TEST_ROOT/preupdate-checksum-helper.sh" || fail preupdate-checksum-helper-extract
extract_function "$BASE_DIR/functions/update_mervlan.sh" \
  update_prepare_archive_metadata "$TEST_ROOT/preupdate-metadata-helper.sh" || fail preupdate-metadata-helper-extract
extract_function "$BASE_DIR/functions/update_mervlan.sh" \
  update_backup_diagnostic "$TEST_ROOT/preupdate-diagnostic-helper.sh" || fail preupdate-diagnostic-helper-extract
extract_function "$BASE_DIR/functions/update_mervlan.sh" \
  create_durable_preupdate_backup "$TEST_ROOT/preupdate-helper.sh" || fail preupdate-helper-extract
. "$TEST_ROOT/preupdate-size-helper.sh" || fail preupdate-size-helper-load
. "$TEST_ROOT/preupdate-checksum-helper.sh" || fail preupdate-checksum-helper-load
. "$TEST_ROOT/preupdate-metadata-helper.sh" || fail preupdate-metadata-helper-load
. "$TEST_ROOT/preupdate-diagnostic-helper.sh" || fail preupdate-diagnostic-helper-load
. "$TEST_ROOT/preupdate-helper.sh" || fail preupdate-helper-load
MERV_BASE="$SOURCE"
TMP_BASE="$TEST_ROOT/update-work"
MERVLAN_BACKUP_DIR="$TEST_ROOT/update-backups"
MERV_STATE_ROOT="$TEST_ROOT/update-state"
UPDATE_PRESERVE_TMP="0"
mkdir -p "$TMP_BASE" "$MERVLAN_BACKUP_DIR" || fail preupdate-work
cp -p "$BASE_DIR/settings/lib_json.sh" "$MERVLAN_BACKUP_DIR/lib_json.sh" || fail preupdate-json-helper
cp -p "$BASE_DIR/settings/lib_boot_integrity.sh" "$MERVLAN_BACKUP_DIR/lib_boot_integrity.sh" || fail preupdate-integrity-helper
chmod 600 "$MERVLAN_BACKUP_DIR/lib_json.sh" "$MERVLAN_BACKUP_DIR/lib_boot_integrity.sh" || fail preupdate-helper-mode
merv_maintenance_recovery_root_prepare() { mkdir -p "$MERVLAN_BACKUP_DIR"; }
update_cleanup_files() { for _brt_file in "$@"; do rm -f "$_brt_file"; done; }
update_cleanup_tree() { [ -e "$1" ] || return 0; rm -rf "$1"; }
update_path_absent_authoritative() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
printf 'metadata input\n' > "$TEST_ROOT/metadata-input.archive" || fail metadata-input
update_prepare_archive_metadata "$TEST_ROOT/metadata-input.archive" \
  mervlan.backup.20261015-130509.tar.gz "$TEST_ROOT/metadata-output" || fail production-metadata-create
grep -qx 'algorithm=md5' "$TEST_ROOT/metadata-output" || fail production-metadata-format
(
  md5sum() { return 72; }
  if update_prepare_archive_metadata "$TEST_ROOT/metadata-input.archive" \
      mervlan.backup.20261015-130509.tar.gz "$TEST_ROOT/metadata-failure-output"; then
    exit 1
  else
    _meta_rc=$?
  fi
  [ "$_meta_rc" -eq 72 ]
) || fail metadata-original-status
update_prepare_archive_metadata() {
  _brt_checksum=$(md5sum "$1" | awk '{print $1}') || return 1
  printf 'format=1\narchive=%s\nalgorithm=md5\nchecksum=%s\n' "$2" "$_brt_checksum" > "$3"
}
info() { :; }
warn() { :; }
create_durable_preupdate_backup "$SOURCE" || fail production-preupdate-archive
[ "$UPDATE_BACKUP_ARCHIVE_OK" = 1 ] || fail production-preupdate-archive-result
[ -f "$UPDATE_BACKUP_FINAL" ] || fail preupdate-archive-missing
[ ! -e "$TMP_BASE/preupdate-archive-source" ] || fail preupdate-stage-not-cleaned
[ ! -e "$UPDATE_BACKUP_PARTIAL" ] || fail preupdate-partial-not-cleaned
[ ! -e "$UPDATE_BACKUP_META_PARTIAL" ] || fail preupdate-meta-partial-not-cleaned
tar -tzf "$UPDATE_BACKUP_FINAL" > "$TEST_ROOT/preupdate.list" || fail preupdate-archive-list
grep -Fq 'source/.backup_state/ssh_trust/known_hosts.v1' "$TEST_ROOT/preupdate.list" || fail preupdate-trust-payload
pass production-preupdate-archive-wrapper

# The extracted production size helper must silence shell input-open errors as
# well as wc diagnostics when tar failed before creating its partial archive.
_size_expected=$(ls -ln "$UPDATE_BACKUP_FINAL" | awk '{print $5}')
case "$_size_expected" in ''|*[!0-9]*) fail archive-size-fixture ;; esac
_size_actual=$(update_backup_file_size_bytes "$UPDATE_BACKUP_FINAL" 2> "$TEST_ROOT/size-existing.stderr")
[ "$_size_actual" = "$_size_expected" ] || fail archive-size-numeric
[ ! -s "$TEST_ROOT/size-existing.stderr" ] || fail archive-size-existing-stderr
_size_actual=$(update_backup_file_size_bytes "$TEST_ROOT/ABSENT_PARTIAL_FILENAME_SENTINEL" 2> "$TEST_ROOT/size-absent.stderr")
[ "$_size_actual" = unknown ] || fail archive-size-absent-unknown
[ ! -s "$TEST_ROOT/size-absent.stderr" ] || fail archive-size-absent-stderr
pass preupdate-archive-size-stderr-hygiene

# Exercise every durable pre-update diagnostic boundary through the extracted
# production creator. These wrappers inject deterministic failures in a private
# fixture and keep the production cleanup decisions observable.
BACKUP_FAULT=none
BACKUP_DATE_MODE=normal
BACKUP_DIAG_LOG="$TEST_ROOT/preupdate-diagnostics.log"
BACKUP_CLEANUP_FILES_CALLS=0
BACKUP_CLEANUP_TREE_CALLS=0
BACKUP_ROOT_PREPARE_CALLS=0
error() { printf '%s\n' "$*" >> "$BACKUP_DIAG_LOG"; }
date() {
  if [ "$BACKUP_FAULT" = backup-timestamp-create ]; then
    return 73
  fi
  case "$BACKUP_DATE_MODE" in
    rc73-empty) return 73 ;;
    rc73-output)
      printf '20261015-130509\n'
      printf 'UNTRUSTED_DATE_DIAGNOSTIC\n' >&2
      return 73
      ;;
    empty-success) return 0 ;;
    valid) printf '20261015-130509\n' ;;
    normalize) printf '20261015-\n130509\n' ;;
    *) printf '20261015-130509\n' ;;
  esac
}
merv_maintenance_recovery_root_prepare() {
  BACKUP_ROOT_PREPARE_CALLS=$((BACKUP_ROOT_PREPARE_CALLS + 1))
  case "$BACKUP_DATE_MODE" in valid|normalize) return 97 ;; esac
  [ "$BACKUP_FAULT" = backup-root-prepare ] && return 31
  mkdir -p "$MERVLAN_BACKUP_DIR"
}
chmod() {
  if [ "$BACKUP_FAULT" = backup-root-mode ] &&
     [ "$1" = 700 ] && [ "$2" = "$MERVLAN_BACKUP_DIR" ]; then
    return 32
  fi
  command chmod "$@"
}
update_cleanup_files() {
  BACKUP_CLEANUP_FILES_CALLS=$((BACKUP_CLEANUP_FILES_CALLS + 1))
  if [ "$BACKUP_FAULT" = backup-partial-cleanup ] &&
     [ "$BACKUP_CLEANUP_FILES_CALLS" -eq 1 ]; then
    return 33
  fi
  for _bfc_file in "$@"; do
    rm -f "$_bfc_file" 2>/dev/null || return $?
  done
}
update_cleanup_tree() {
  BACKUP_CLEANUP_TREE_CALLS=$((BACKUP_CLEANUP_TREE_CALLS + 1))
  if [ "$BACKUP_FAULT" = backup-stage-cleanup ] &&
     [ "$BACKUP_CLEANUP_TREE_CALLS" -eq 1 ]; then
    return 34
  fi
  if [ "$BACKUP_FAULT" = backup-stage-final-cleanup ] &&
     [ "$BACKUP_CLEANUP_TREE_CALLS" -eq 2 ]; then
    return 39
  fi
  [ -e "$1" ] || return 0
  rm -rf "$1"
}
update_path_absent_authoritative() {
  [ "$BACKUP_FAULT" = backup-name-collision ] && return 35
  [ ! -e "$1" ] && [ ! -L "$1" ]
}
mkdir() {
  if [ "$BACKUP_FAULT" = backup-stage-create ] && [ "$#" -eq 1 ] &&
     [ "$1" = "$TMP_BASE/preupdate-archive-source" ]; then
    return 36
  fi
  command mkdir "$@"
}
merv_backup_state_prepare_tree() {
  case "$BACKUP_FAULT" in
    backup-state-prepare)
      MERV_BACKUP_STATE_LAST_ERROR=source-copy-failed
      return 37
      ;;
    backup-state-sensitive)
      MERV_BACKUP_STATE_LAST_ERROR='PRIVATE_KEY_SECRET_SENTINEL SSH_TRUST_SECRET_SENTINEL PASSWORD_SECRET_SENTINEL TOKEN_SECRET_SENTINEL NODE_SECRET_SENTINEL SETTINGS_JSON_SECRET_SENTINEL'
      return 45
      ;;
    backup-state-trust-dual)
      MERV_BACKUP_STATE_LAST_ERROR=trust-validation-failed
      MERV_BACKUP_STATE_CLEANUP_ERROR=55
      return 54
      ;;
    backup-state-trust-cleanup)
      MERV_BACKUP_STATE_LAST_ERROR=private-workspace-cleanup-failed
      MERV_BACKUP_STATE_CLEANUP_ERROR=55
      return 55
      ;;
  esac
  mkdir -p "$2" || return $?
  command cp -pR "$1/." "$2/" || return $?
  MERV_BACKUP_STATE_LAST_ERROR=
  MERV_BACKUP_STATE_CLEANUP_ERROR=0
}
tar() {
  if [ "$BACKUP_FAULT" = backup-archive-create-absent ] && [ "$1" = -czf ]; then
    printf '%s\n' 'PRIVATE_KEY_SECRET_SENTINEL tar failed before archive creation' >&2
    return 46
  fi
  if [ "$BACKUP_FAULT" = backup-archive-create ] && [ "$1" = -czf ]; then
    printf 'partial' > "$2"
    return 38
  fi
  if [ "$BACKUP_FAULT" = backup-archive-integrity ] && [ "$1" = -tzf ]; then
    return 40
  fi
  command tar "$@"
}
update_prepare_archive_metadata() {
  [ "$BACKUP_FAULT" = backup-metadata-create ] && return 41
  _bfc_checksum=$(md5sum "$1" | awk '{print $1}') || return 1
  printf 'format=1\narchive=%s\nalgorithm=md5\nchecksum=%s\n' "$2" "$_bfc_checksum" > "$3"
}
mv() {
  if [ "$BACKUP_FAULT" = backup-metadata-publish ] &&
     [ "$3" = "$UPDATE_BACKUP_META_FINAL" ]; then
    return 42
  fi
  if [ "$BACKUP_FAULT" = backup-archive-publish ] &&
     [ "$3" = "$UPDATE_BACKUP_FINAL" ]; then
    return 43
  fi
  command mv "$@"
}

prepare_backup_case() {
  BACKUP_FAULT="$1"
  BACKUP_CASE_ROOT="$TEST_ROOT/preupdate-case-$1"
  TMP_BASE="$BACKUP_CASE_ROOT/tmp"
  MERVLAN_BACKUP_DIR="$BACKUP_CASE_ROOT/backups"
  BACKUP_DIAG_LOG="$BACKUP_CASE_ROOT/diagnostics"
  mkdir -p "$TMP_BASE" "$MERVLAN_BACKUP_DIR" || fail "fixture-$1"
  : > "$BACKUP_DIAG_LOG" || fail "diagnostics-$1"
  BACKUP_CLEANUP_FILES_CALLS=0
  BACKUP_CLEANUP_TREE_CALLS=0
  BACKUP_ROOT_PREPARE_CALLS=0
  UPDATE_PRESERVE_TMP=0
  UPDATE_BACKUP_ARCHIVE_OK=0
  UPDATE_BACKUP_ID=
  MERV_BACKUP_STATE_CLEANUP_ERROR=0
  case "$BACKUP_FAULT" in
    backup-partial-cleanup)
      printf stale > "$MERVLAN_BACKUP_DIR/.mervlan.backup.20261015-130509.tar.gz.partial.$$"
      ;;
    backup-stage-cleanup) mkdir -p "$TMP_BASE/preupdate-archive-source" ;;
    backup-name-collision)
      printf collision > "$MERVLAN_BACKUP_DIR/mervlan.backup.20261015-130509.tar.gz"
      ;;
  esac
}

assert_backup_fault() {
  _abf_fault="$1"
  _abf_id="$2"
  _abf_rc="$3"
  prepare_backup_case "$_abf_fault"
  if [ "$_abf_fault" = backup-source-invalid ]; then
    if create_durable_preupdate_backup "$TEST_ROOT/RAW_EXTERNAL_PATH_SENTINEL" 2> "$BACKUP_CASE_ROOT/stderr"; then
      _abf_actual_rc=0
    else
      _abf_actual_rc=$?
    fi
  else
    if create_durable_preupdate_backup "$SOURCE" 2> "$BACKUP_CASE_ROOT/stderr"; then
      _abf_actual_rc=0
    else
      _abf_actual_rc=$?
    fi
  fi
  [ "$_abf_actual_rc" -eq "$_abf_rc" ] || fail "diagnostic-status-$_abf_fault"
  grep -Fq "diagnostic=$_abf_id " "$BACKUP_DIAG_LOG" || fail "diagnostic-id-$_abf_fault"
  [ "$UPDATE_BACKUP_ARCHIVE_OK" = 0 ] || fail "failure-marked-backup-complete-$_abf_fault"
  if grep -E 'PRIVATE_KEY_SECRET_SENTINEL|SSH_TRUST_SECRET_SENTINEL|PASSWORD_SECRET_SENTINEL|TOKEN_SECRET_SENTINEL|NODE_SECRET_SENTINEL|SETTINGS_JSON_SECRET_SENTINEL|RECOVERY_OUTPUT_SENTINEL|RAW_EXTERNAL_PATH_SENTINEL' \
      "$BACKUP_DIAG_LOG" >/dev/null 2>&1; then
    fail "sensitive-diagnostic-output-$_abf_fault"
  fi
}

assert_timestamp_case() {
  _atc_mode="$1"
  _atc_expected_rc="$2"
  _atc_expected_backup_id="$3"
  _atc_expected_diag_rc="$4"
  _atc_expected_diag_id="$5"
  prepare_backup_case "timestamp-$_atc_mode"
  BACKUP_FAULT=none
  BACKUP_DATE_MODE="$_atc_mode"
  if create_durable_preupdate_backup "$SOURCE" > "$BACKUP_CASE_ROOT/stdout" 2> "$BACKUP_CASE_ROOT/stderr"; then
    _atc_actual_rc=0
  else
    _atc_actual_rc=$?
  fi
  if [ "$_atc_actual_rc" -ne "$_atc_expected_rc" ]; then
    cat "$BACKUP_DIAG_LOG" >&2
    fail "timestamp-status-$_atc_mode-actual-${_atc_actual_rc}-expected-${_atc_expected_rc}-root-calls-${BACKUP_ROOT_PREPARE_CALLS}"
  fi
  [ ! -s "$BACKUP_CASE_ROOT/stderr" ] || fail "timestamp-stderr-$_atc_mode"
  [ ! -s "$BACKUP_CASE_ROOT/stdout" ] || fail "timestamp-stdout-$_atc_mode"
  if [ "$_atc_expected_diag_id" = backup-timestamp-create ]; then
    grep -Fq "diagnostic=backup-timestamp-create rc=$_atc_expected_diag_rc" "$BACKUP_DIAG_LOG" ||
      fail "timestamp-diagnostic-$_atc_mode"
    [ "$BACKUP_ROOT_PREPARE_CALLS" -eq 0 ] || fail "timestamp-root-prepared-$_atc_mode"
    [ "$BACKUP_CLEANUP_FILES_CALLS" -eq 0 ] && [ "$BACKUP_CLEANUP_TREE_CALLS" -eq 0 ] ||
      fail "timestamp-backup-work-started-$_atc_mode"
    [ -z "$UPDATE_BACKUP_ID" ] || fail "timestamp-backup-id-published-$_atc_mode"
    [ ! -e "$TMP_BASE/preupdate-archive-source" ] || fail "timestamp-stage-created-$_atc_mode"
    if [ "$_atc_mode" = rc73-output ]; then
      if grep -E '20261015-130509|UNTRUSTED_DATE_DIAGNOSTIC' "$BACKUP_DIAG_LOG" >/dev/null 2>&1; then
        fail timestamp-failed-date-output-logged
      fi
    fi
  else
    grep -Fq "diagnostic=$_atc_expected_diag_id rc=$_atc_expected_diag_rc" "$BACKUP_DIAG_LOG" ||
      fail "timestamp-success-boundary-$_atc_mode"
    [ "$BACKUP_ROOT_PREPARE_CALLS" -eq 1 ] || fail "timestamp-root-not-prepared-$_atc_mode"
    [ "$UPDATE_BACKUP_ID" = "$_atc_expected_backup_id" ] || fail "timestamp-normalization-$_atc_mode"
  fi
}

assert_backup_fault backup-source-invalid backup-source-invalid 1
grep -Fq 'reason=source-invalid' "$BACKUP_DIAG_LOG" || fail external-source-safe-reason
assert_timestamp_case rc73-empty 73 '' 73 backup-timestamp-create
assert_timestamp_case rc73-output 73 '' 73 backup-timestamp-create
assert_timestamp_case empty-success 1 '' 1 backup-timestamp-create
assert_timestamp_case valid 97 mervlan.backup.20261015-130509.tar.gz 97 backup-root-prepare
assert_timestamp_case normalize 97 mervlan.backup.20261015-130509.tar.gz 97 backup-root-prepare
pass preupdate-timestamp-exit-status-matrix
BACKUP_DATE_MODE=normal
assert_backup_fault backup-root-prepare backup-root-prepare 31
assert_backup_fault backup-root-mode backup-root-mode 32
assert_backup_fault backup-partial-cleanup backup-partial-cleanup 33
[ -f "$MERVLAN_BACKUP_DIR/.mervlan.backup.20261015-130509.tar.gz.partial.$$" ] ||
  fail backup-partial-cleanup-preserves-stale-file
assert_backup_fault backup-stage-cleanup backup-stage-cleanup 34
[ -d "$TMP_BASE/preupdate-archive-source" ] || fail backup-stage-cleanup-preserves-stage
assert_backup_fault backup-name-collision backup-name-collision 35
assert_backup_fault backup-stage-create backup-stage-create 36
assert_backup_fault backup-state-prepare backup-state-prepare 37
grep -Fq 'reason=source-copy-failed' "$BACKUP_DIAG_LOG" || fail backup-state-safe-reason
[ ! -e "$TMP_BASE/preupdate-archive-source" ] || fail backup-state-failure-stage-cleanup
assert_backup_fault backup-state-sensitive backup-state-prepare 45
grep -Fq 'reason=unknown' "$BACKUP_DIAG_LOG" || fail backup-state-sensitive-reason-redacted
assert_backup_fault backup-state-trust-dual backup-state-prepare 54
grep -Fq 'diagnostic=backup-state-prepare rc=54 reason=trust-validation-failed cleanup_rc=55' \
  "$BACKUP_DIAG_LOG" || fail backup-state-trust-dual-diagnostic
assert_backup_fault backup-state-trust-cleanup backup-state-prepare 55
grep -Fq 'diagnostic=backup-state-prepare rc=55 reason=private-workspace-cleanup-failed cleanup_rc=55' \
  "$BACKUP_DIAG_LOG" || fail backup-state-trust-cleanup-diagnostic
assert_backup_fault backup-archive-create backup-archive-create 38
grep -Fq 'partial_bytes=7' "$BACKUP_DIAG_LOG" || fail archive-create-partial-size
[ ! -e "$TMP_BASE/preupdate-archive-source" ] || fail archive-create-stage-cleanup
[ ! -e "$UPDATE_BACKUP_PARTIAL" ] || fail archive-create-partial-cleanup
assert_backup_fault backup-archive-create-absent backup-archive-create 46
grep -Fq 'diagnostic=backup-archive-create rc=46 partial_bytes=unknown' "$BACKUP_DIAG_LOG" ||
  fail archive-create-absent-diagnostic
[ ! -s "$BACKUP_CASE_ROOT/stderr" ] || fail archive-create-absent-stderr
[ ! -e "$TMP_BASE/preupdate-archive-source" ] || fail archive-create-absent-stage-cleanup
[ ! -e "$UPDATE_BACKUP_PARTIAL" ] || fail archive-create-absent-partial-cleanup
[ "$UPDATE_PRESERVE_TMP" = 0 ] || fail archive-create-absent-preserve-flag
pass preupdate-archive-create-absent-stderr-hygiene
assert_backup_fault backup-stage-final-cleanup backup-stage-final-cleanup 39
[ "$UPDATE_PRESERVE_TMP" = 1 ] || fail final-stage-cleanup-preserve-flag
[ -d "$TMP_BASE/preupdate-archive-source" ] || fail final-stage-cleanup-preserves-evidence
assert_backup_fault backup-archive-integrity backup-archive-integrity 40
[ ! -e "$UPDATE_BACKUP_PARTIAL" ] || fail archive-integrity-partial-cleanup
assert_backup_fault backup-metadata-create backup-metadata-create 41
[ ! -e "$UPDATE_BACKUP_PARTIAL" ] && [ ! -e "$UPDATE_BACKUP_META_PARTIAL" ] ||
  fail metadata-create-partial-cleanup
assert_backup_fault backup-metadata-publish backup-metadata-publish 42
[ ! -e "$UPDATE_BACKUP_PARTIAL" ] && [ ! -e "$UPDATE_BACKUP_META_PARTIAL" ] ||
  fail metadata-publish-partial-cleanup
assert_backup_fault backup-archive-publish backup-archive-publish 43
[ ! -e "$UPDATE_BACKUP_PARTIAL" ] && [ ! -e "$UPDATE_BACKUP_META_FINAL" ] ||
  fail archive-publish-partial-cleanup

RECOVERY_CHECKER="$SOURCE/functions/mervlan_recover.sh"
RECOVERY_CHECKER_SNAPSHOT="$TEST_ROOT/mervlan_recover.real.sh"
cp -p "$RECOVERY_CHECKER" "$RECOVERY_CHECKER_SNAPSHOT" || fail recovery-checker-snapshot
cat > "$RECOVERY_CHECKER" <<'EOF'
#!/bin/sh
printf '%s\n' 'RECOVERY_OUTPUT_SENTINEL PRIVATE_KEY_SECRET_SENTINEL SSH_TRUST_SECRET_SENTINEL PASSWORD_SECRET_SENTINEL TOKEN_SECRET_SENTINEL NODE_SECRET_SENTINEL SETTINGS_JSON_SECRET_SENTINEL' >&2
printf '%s\n' 'RECOVERY_OUTPUT_SENTINEL'
exit 44
EOF
chmod 755 "$RECOVERY_CHECKER" || fail recovery-checker-fault-mode
assert_backup_fault backup-recovery-check-failed backup-recovery-check-failed 44
[ ! -e "$UPDATE_BACKUP_FINAL" ] && [ ! -e "$UPDATE_BACKUP_META_FINAL" ] ||
  fail recovery-check-failure-final-cleanup
cp -p "$RECOVERY_CHECKER_SNAPSHOT" "$RECOVERY_CHECKER" || fail recovery-checker-restore
RECOVERY_CHECKER_MISSING="$TEST_ROOT/mervlan_recover.missing.sh"
mv "$RECOVERY_CHECKER" "$RECOVERY_CHECKER_MISSING" || fail recovery-checker-missing-setup
assert_backup_fault backup-recovery-check-missing backup-recovery-check-missing 1
[ ! -e "$UPDATE_BACKUP_FINAL" ] && [ ! -e "$UPDATE_BACKUP_META_FINAL" ] ||
  fail recovery-check-missing-final-cleanup
mv "$RECOVERY_CHECKER_MISSING" "$RECOVERY_CHECKER" || fail recovery-checker-missing-restore
pass durable-preupdate-diagnostic-boundaries

# Keep backup failure before activation and in the existing backing_up journal
# classification.
grep -Fq 'if ! create_durable_preupdate_backup "$UPDATE_BACKUP_SOURCE_DIR"; then' \
  "$BASE_DIR/functions/update_mervlan.sh" || fail backup-failure-before-activation-call
grep -Fq 'fail_update backing_up "Failed to create and validate the durable pre-update backup"' \
  "$BASE_DIR/functions/update_mervlan.sh" || fail backup-failure-journal-classification
_backup_call_line=$(grep -nF 'if ! create_durable_preupdate_backup "$UPDATE_BACKUP_SOURCE_DIR"; then' \
  "$BASE_DIR/functions/update_mervlan.sh" | cut -d: -f1)
_activation_line=$(grep -nF 'update_record_phase activation-started' \
  "$BASE_DIR/functions/update_mervlan.sh" | cut -d: -f1)
case "$_backup_call_line:$_activation_line" in *[!0-9:]*|:|*:) fail backup-activation-order-numeric ;; esac
[ "$_backup_call_line" -lt "$_activation_line" ] || fail backup-failure-activation-order
pass durable-preupdate-failure-before-activation

# Both production archive producers must use the shared implementation; this
# prevents manual and automatic pre-update backups from drifting apart.
grep -Fq 'merv_backup_state_prepare_tree' "$BASE_DIR/functions/update_mervlan.sh" || fail automatic-backup-shared-helper
grep -Fq 'mb_create_archive_from_tree' "$BASE_DIR/functions/mervlan_backup.sh" || fail manual-backup-shared-helper
pass automatic-and-undo-backup-shared-format

printf 'PASS: backup/restore trust contract\n'
