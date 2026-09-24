#!/bin/sh
# Focused contract test for durable SSH trust in restorable backup state.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.backup-trust.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

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
  settings/var_settings.sh settings/lib_json.sh settings/lib_ssh.sh \
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
[ ! -e "$MISSING_TREE" ] || fail missing-trust-left-stage
pass configured-nodes-missing-trust-fails

BAD_TRUST="$TEST_ROOT/malformed-trust"
printf 'not-a-trust-db\n' > "$BAD_TRUST" || fail malformed-trust-fixture
mkdir -p "$TEST_ROOT/malformed-work" || fail malformed-work
expect_fail merv_backup_state_validate_trust_file "$BAD_TRUST" "$TEST_ROOT/malformed-work"
pass malformed-trust-fails

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
cp -p "$MODERN_ARCHIVE" "$RECOVERY_ROOT/$RECOVERY_ID" || fail recovery-archive-copy
RECOVERY_MD5=$(md5sum "$RECOVERY_ROOT/$RECOVERY_ID" | awk '{print $1}') || fail recovery-md5
{
  printf 'format=1\narchive=%s\nalgorithm=md5\nchecksum=%s\n' "$RECOVERY_ID" "$RECOVERY_MD5"
} > "$RECOVERY_ROOT/$RECOVERY_ID.meta" || fail recovery-meta
MERVLAN_RECOVERY_BACKUP_ROOT="$RECOVERY_ROOT" \
MERVLAN_RECOVERY_TMP_ROOT="$RECOVERY_TMP" \
MERVLAN_RECOVERY_ACTIVE_ROOT="$TEST_ROOT/recovery-active" \
MERVLAN_RECOVERY_STATE_ROOT="$TEST_ROOT/recovery-state" \
  sh "$BASE_DIR/functions/mervlan_recover.sh" check "$RECOVERY_ID" >/dev/null 2>&1 || fail recovery-modern-check
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
  create_durable_preupdate_backup "$TEST_ROOT/preupdate-helper.sh" || fail preupdate-helper-extract
. "$TEST_ROOT/preupdate-helper.sh" || fail preupdate-helper-load
MERV_BASE="$SOURCE"
TMP_BASE="$TEST_ROOT/update-work"
MERVLAN_BACKUP_DIR="$TEST_ROOT/update-backups"
MERV_STATE_ROOT="$TEST_ROOT/update-state"
UPDATE_PRESERVE_TMP="0"
mkdir -p "$TMP_BASE" "$MERVLAN_BACKUP_DIR" || fail preupdate-work
merv_maintenance_recovery_root_prepare() { mkdir -p "$MERVLAN_BACKUP_DIR"; }
update_cleanup_files() { for _brt_file in "$@"; do rm -f "$_brt_file"; done; }
update_cleanup_tree() { [ -e "$1" ] || return 0; rm -rf "$1"; }
update_path_absent_authoritative() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
update_prepare_archive_metadata() {
  _brt_checksum=$(md5sum "$1" | awk '{print $1}') || return 1
  printf 'format=1\narchive=%s\nalgorithm=md5\nchecksum=%s\n' "$2" "$_brt_checksum" > "$3"
}
info() { :; }
warn() { :; }
create_durable_preupdate_backup "$SOURCE" || fail production-preupdate-archive
[ -f "$UPDATE_BACKUP_FINAL" ] || fail preupdate-archive-missing
tar -tzf "$UPDATE_BACKUP_FINAL" > "$TEST_ROOT/preupdate.list" || fail preupdate-archive-list
grep -Fq 'source/.backup_state/ssh_trust/known_hosts.v1' "$TEST_ROOT/preupdate.list" || fail preupdate-trust-payload
pass production-preupdate-archive-wrapper

# Both production archive producers must use the shared implementation; this
# prevents manual and automatic pre-update backups from drifting apart.
grep -Fq 'merv_backup_state_prepare_tree' "$BASE_DIR/functions/update_mervlan.sh" || fail automatic-backup-shared-helper
grep -Fq 'mb_create_archive_from_tree' "$BASE_DIR/functions/mervlan_backup.sh" || fail manual-backup-shared-helper
pass automatic-and-undo-backup-shared-format

printf 'PASS: backup/restore trust contract\n'
