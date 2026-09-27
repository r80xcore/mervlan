#!/bin/sh
# Contract test for normal Restore's current-code plus persistent-state
# candidate.  The fixture deliberately gives the backup different executable
# markers and state values; the production candidate helper must keep the
# current markers while importing only the audited state overlay.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.restore-cohort.$$"
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
. "$BASE_DIR/settings/lib_json.sh" || fail json-library
. "$BASE_DIR/settings/lib_ssh.sh" || fail ssh-library
. "$BASE_DIR/settings/lib_backup_state.sh" || fail backup-state-library

HELPERS="$TEST_ROOT/restore-helpers.sh"
awk '
  /^mb_settings_file_valid\(\) \{/ { emit=1 }
  /^mb_validate_archive_tree\(\) \{/ { exit }
  emit { print }
' "$BASE_DIR/functions/mervlan_backup.sh" > "$HELPERS" || fail helper-extraction
. "$HELPERS" || fail helper-load

DROPBEARKEY="$TEST_ROOT/fake-dropbearkey"
export DROPBEARKEY
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$FAKE_DROPBEAR_MATERIAL"' > "$DROPBEARKEY" || fail dropbear-fixture
chmod 700 "$DROPBEARKEY" || fail dropbear-mode
command -v ssh-keygen >/dev/null 2>&1 || fail ssh-keygen-unavailable
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key-current" >/dev/null 2>&1 || fail current-key-generation
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key-old" >/dev/null 2>&1 || fail old-key-generation
CURRENT_KEY_MATERIAL="ssh-ed25519 $(awk '{print $2; exit}' "$TEST_ROOT/key-current.pub")"
OLD_KEY_MATERIAL="ssh-ed25519 $(awk '{print $2; exit}' "$TEST_ROOT/key-old.pub")"

CURRENT="$TEST_ROOT/current"
BACKUP="$TEST_ROOT/backup"
CANDIDATE="$TEST_ROOT/candidate"
mkdir -p "$CURRENT/settings" "$CURRENT/functions" "$CURRENT/templates" "$CURRENT/www" \
  "$CURRENT/.ssh" "$CURRENT/tmp" "$BACKUP/settings" "$BACKUP/functions" \
  "$BACKUP/templates" "$BACKUP/www" "$BACKUP/.ssh" "$BACKUP/tmp" || fail fixture-directories

cp -p "$BASE_DIR/settings/settings.json" "$CURRENT/settings/settings.json" || fail current-settings
cp -p "$BASE_DIR/settings/settings.json" "$BACKUP/settings/settings.json" || fail backup-settings
json_set_flag BOOT_ENABLED 0 "$CURRENT/settings/settings.json" >/dev/null || fail current-boot
json_set_flag NODE1 none "$CURRENT/settings/settings.json" >/dev/null || fail current-node
json_set_flag SSH_KEYS_INSTALLED 0 "$CURRENT/settings/settings.json" >/dev/null || fail current-keys
json_set_flag AUTO_SYNC_SETTINGS current-default "$CURRENT/settings/settings.json" >/dev/null || fail current-default
json_set_flag BOOT_ENABLED 1 "$BACKUP/settings/settings.json" >/dev/null || fail backup-boot
json_set_flag NODE1 192.168.186.201 "$BACKUP/settings/settings.json" >/dev/null || fail backup-node
json_set_flag SSH_KEYS_INSTALLED 1 "$BACKUP/settings/settings.json" >/dev/null || fail backup-keys
json_set_flag AUTO_SYNC_SETTINGS old-state "$BACKUP/settings/settings.json" >/dev/null || fail backup-state

printf '%s\n' 'mervlan vCURRENT' > "$CURRENT/changelog.txt" || fail current-changelog
printf '%s\n' 'mervlan vOLD' > "$BACKUP/changelog.txt" || fail backup-changelog
for _file in functions/service-event-handler.sh functions/sync_nodes.sh \
  settings/lib_ssh.sh settings/lib_ssh_trust.sh templates/mervlan_templates.sh \
  www/index.html functions/current-only.sh; do
  mkdir -p "$CURRENT/$(dirname "$_file")" || fail current-marker-dir
  printf 'CURRENT-CODE\n' > "$CURRENT/$_file" || fail current-marker
done
printf 'OLD-CODE\n' > "$BACKUP/functions/service-event-handler.sh" || fail old-handler
printf 'OLD-CODE\n' > "$BACKUP/functions/sync_nodes.sh" || fail old-sync
printf 'OLD-CODE\n' > "$BACKUP/settings/lib_ssh.sh" || fail old-ssh
printf 'OLD-CODE\n' > "$BACKUP/templates/mervlan_templates.sh" || fail old-template
printf 'OLD-CODE\n' > "$BACKUP/www/index.html" || fail old-www
printf 'OLD-CODE\n' > "$BACKUP/functions/old-only.sh" || fail old-only

printf 'current key\n' > "$CURRENT/.ssh/vlan_manager" || fail current-private
awk '{print $1, $2, "current"}' "$TEST_ROOT/key-current.pub" > "$CURRENT/.ssh/vlan_manager.pub" || fail current-public
chmod 600 "$CURRENT/.ssh/vlan_manager" || fail current-private-mode
chmod 644 "$CURRENT/.ssh/vlan_manager.pub" || fail current-public-mode
printf 'old key\n' > "$BACKUP/.ssh/vlan_manager" || fail backup-private
awk '{print $1, $2, "old"}' "$TEST_ROOT/key-old.pub" > "$BACKUP/.ssh/vlan_manager.pub" || fail backup-public
chmod 600 "$BACKUP/.ssh/vlan_manager" || fail backup-private-mode
chmod 644 "$BACKUP/.ssh/vlan_manager.pub" || fail backup-public-mode

printf 'CURRENT-DB\n' > "$CURRENT/tmp/mac_shield.db" || fail current-db
printf 'CURRENT-OVERRIDE\n' > "$CURRENT/tmp/mac_shield_override.db" || fail current-override
printf 'CURRENT-NAMES\n' > "$CURRENT/tmp/client_name_override.db" || fail current-names
printf 'OLD-DB\n' > "$BACKUP/tmp/mac_shield.db" || fail backup-db
printf 'OLD-OVERRIDE\n' > "$BACKUP/tmp/mac_shield_override.db" || fail backup-override
printf 'OLD-NAMES\n' > "$BACKUP/tmp/client_name_override.db" || fail backup-names

FAKE_DROPBEAR_MATERIAL="$OLD_KEY_MATERIAL"
export FAKE_DROPBEAR_MATERIAL
mb_prepare_restore_candidate "$CURRENT" "$BACKUP" "$CANDIDATE" "$TEST_ROOT" || fail candidate-preparation

for _file in functions/service-event-handler.sh functions/sync_nodes.sh \
  settings/lib_ssh.sh settings/lib_ssh_trust.sh templates/mervlan_templates.sh \
  www/index.html functions/current-only.sh; do
  grep -qx 'CURRENT-CODE' "$CANDIDATE/$_file" || fail "current-code-lost: $_file"
done
[ ! -e "$CANDIDATE/functions/old-only.sh" ] || fail old-executable-imported
[ "$(sed -n '1p' "$CANDIDATE/changelog.txt")" = 'mervlan vCURRENT' ] || fail old-version-imported
[ "$(json_get_flag BOOT_ENABLED '' "$CANDIDATE/settings/settings.json")" = 1 ] || fail migrated-boot
[ "$(json_get_flag NODE1 '' "$CANDIDATE/settings/settings.json")" = 192.168.186.201 ] || fail migrated-node
[ "$(json_get_flag SSH_KEYS_INSTALLED '' "$CANDIDATE/settings/settings.json")" = 1 ] || fail migrated-key-flag
[ "$(json_get_flag AUTO_SYNC_SETTINGS '' "$CANDIDATE/settings/settings.json")" = old-state ] || fail settings-merge
[ "${MERV_SETTINGS_MERGE_EXTRACTED:-0}" -gt 0 ] || fail settings-merge-count
cmp -s "$BACKUP/.ssh/vlan_manager" "$CANDIDATE/.ssh/vlan_manager" || fail backup-private-not-overlaid
cmp -s "$BACKUP/.ssh/vlan_manager.pub" "$CANDIDATE/.ssh/vlan_manager.pub" || fail backup-public-not-overlaid
for _db in mac_shield.db mac_shield_override.db client_name_override.db; do
  cmp -s "$BACKUP/tmp/$_db" "$CANDIDATE/tmp/$_db" || fail "backup-db-not-overlaid: $_db"
done
[ ! -e "$CANDIDATE/.backup_state" ] && [ ! -L "$CANDIDATE/.backup_state" ] || fail backup-state-activated
pass current-code-plus-old-state

rm -rf "$TEST_ROOT/negative-mismatch" || fail negative-cleanup
cp -pR "$BACKUP" "$TEST_ROOT/negative-mismatch" || fail negative-copy
printf '%s\n' 'ssh-ed25519 invalid-public-key' > \
  "$TEST_ROOT/negative-mismatch/.ssh/vlan_manager.pub" || fail mismatch-write
chmod 644 "$TEST_ROOT/negative-mismatch/.ssh/vlan_manager.pub" || fail mismatch-mode
expect_fail mb_prepare_restore_candidate "$CURRENT" "$TEST_ROOT/negative-mismatch" \
  "$TEST_ROOT/mismatch-candidate" "$TEST_ROOT"
pass mismatched-keypair-rejected

rm -rf "$TEST_ROOT/negative-mode" || fail negative-mode-cleanup
cp -pR "$BACKUP" "$TEST_ROOT/negative-mode" || fail negative-mode-copy
chmod 644 "$TEST_ROOT/negative-mode/.ssh/vlan_manager" || fail unsafe-mode-write
expect_fail mb_prepare_restore_candidate "$CURRENT" "$TEST_ROOT/negative-mode" \
  "$TEST_ROOT/mode-candidate" "$TEST_ROOT"
pass unsafe-private-mode-rejected

rm -rf "$TEST_ROOT/negative-symlink" || fail negative-symlink-cleanup
cp -pR "$BACKUP" "$TEST_ROOT/negative-symlink" || fail negative-symlink-copy
mv "$TEST_ROOT/negative-symlink/tmp/mac_shield.db" \
  "$TEST_ROOT/negative-symlink/tmp/mac_shield.real" || fail symlink-source-move
ln -s mac_shield.real "$TEST_ROOT/negative-symlink/tmp/mac_shield.db" || fail symlink-source
expect_fail mb_prepare_restore_candidate "$CURRENT" "$TEST_ROOT/negative-symlink" \
  "$TEST_ROOT/symlink-candidate" "$TEST_ROOT"
pass state-symlink-rejected

BAD_SETTINGS="$TEST_ROOT/bad-settings.json"
printf '%s\n' '{ "General": {' > "$BAD_SETTINGS" || fail malformed-settings
expect_fail mb_settings_file_valid "$BAD_SETTINGS"
pass malformed-settings-rejected

grep -Fq 'mb_prepare_restore_candidate "$MERV_BASE" "$MB_RESTORE_TREE"' \
  "$BASE_DIR/functions/mervlan_backup.sh" || fail normal-restore-candidate-source
grep -Fq '_mb_activation_source="$_mb_state_candidate"' \
  "$BASE_DIR/functions/mervlan_backup.sh" || fail normal-restore-activation-source
grep -Fq 'mb_publish_restore_undo "$_mb_old"' \
  "$BASE_DIR/functions/mervlan_backup.sh" || fail undo-restore-boundary
pass normal-undo-semantic-boundary

printf 'PASS restore current cohort contract\n'
