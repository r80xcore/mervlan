#!/bin/sh
# Process-boundary durable maintenance-recovery contract.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.durable-maintenance.$$"
umask 077
mkdir -p "$TEST_ROOT/extracted" "$TEST_ROOT/active/functions" "$TEST_ROOT/active/settings" "$TEST_ROOT/active/www" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_function() {
  _mdr_src="$1" _mdr_name="$2" _mdr_out="$3"
  awk -v name="$_mdr_name" '
    function delta(line, i,c,n) { gsub(/\$\{[^}]*\}/, "", line); for (i=1; i<=length(line); i++) { c=substr(line,i,1); if(c=="{")n++; else if(c=="}")n-- } return n }
    !inside && $0 ~ "^[[:space:]]*" name "[[:space:]]*\\(\\)[[:space:]]*\\{" { inside=1 }
    inside { print; depth += delta($0); if (depth == 0) exit }
  ' "$_mdr_src" > "$_mdr_out" || return 1
  [ -s "$_mdr_out" ]
}

for _mdr_file in install.sh uninstall.sh changelog.txt mervlan.asp \
  functions/update_mervlan.sh functions/mervlan_boot.sh settings/settings.json www/index.html; do
  : > "$TEST_ROOT/active/$_mdr_file"
done

extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_reconcile_stale_stages \
  "$TEST_ROOT/extracted/mb_reconcile.sh" || fail 'backup reconciler extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_install_recovery_helper \
  "$TEST_ROOT/extracted/mb_install_recovery_helper.sh" || fail 'Recovery helper publisher extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_reconcile_stale_stages \
  "$TEST_ROOT/extracted/recovery_reconcile.sh" || fail 'Recovery reconciler extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_update_recovery_status \
  "$TEST_ROOT/extracted/recovery_update_state.sh" || fail 'Recovery Update-state extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_drop_update_recorded_stages \
  "$TEST_ROOT/extracted/recovery_drop_update_stages.sh" || fail 'Recovery Update-stage cleanup extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_restore \
  "$TEST_ROOT/extracted/recovery_restore.sh" || fail 'Recovery restore extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_archive_id_valid \
  "$TEST_ROOT/extracted/recovery_archive_id_valid.sh" || fail 'Recovery archive-id extraction'
extract_function "$BASE_DIR/functions/update_mervlan.sh" update_reconcile_stale_stages \
  "$TEST_ROOT/extracted/update_reconcile.sh" || fail 'Update reconciler extraction'

MERV_MAINTENANCE_RECOVERY_ROOT="$TEST_ROOT/backups"
MERV_MAINTENANCE_RECOVERY_MARKER="$TEST_ROOT/backups/.mervlan.recovery"
MERV_STATE_ROOT="$TEST_ROOT/state"
MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
MERV_BASE="$TEST_ROOT/active"
MB_BACKUP_ROOT="$TEST_ROOT/backups"
MB_RECOVERY_SCRIPT="$TEST_ROOT/backups/recover.sh"
MERVLAN_RECOVERY_BACKUP_ROOT="$TEST_ROOT/backups"
MERVLAN_RECOVERY_ACTIVE_ROOT="$TEST_ROOT/active"
MERVLAN_BACKUP_DIR="$TEST_ROOT/backups"
mkdir -p "$MERV_MAINTENANCE_RECOVERY_ROOT" "$MERV_STATE_ROOT" || exit 1

. "$BASE_DIR/settings/lib_maintenance_recovery.sh" || fail 'durable-state library load'
. "$BASE_DIR/settings/lib_update_state.sh" || fail 'Update-state library load'
. "$BASE_DIR/settings/lib_identity.sh" || fail 'identity library load'
. "$BASE_DIR/settings/lib_owner_lock.sh" || fail 'owner-lock library load'

warn() { :; }
error() { :; }
recovery_log() { :; }
recovery_error() { :; }
mb_remove_jffs_stage() { rm -rf "$1"; }
recovery_tree_valid() {
  [ -d "$1" ] || return 1
  for _mdr_need in install.sh uninstall.sh changelog.txt mervlan.asp \
    functions/update_mervlan.sh functions/mervlan_boot.sh settings/settings.json www/index.html; do
    [ -f "$1/$_mdr_need" ] || return 1
  done
}
update_tree_valid() { recovery_tree_valid "$1"; }
update_remove_jffs_stage() { rm -rf "$1"; }

. "$TEST_ROOT/extracted/mb_reconcile.sh" || fail 'backup reconciler load'
. "$TEST_ROOT/extracted/mb_install_recovery_helper.sh" || fail 'Recovery helper publisher load'
. "$TEST_ROOT/extracted/recovery_update_state.sh" || fail 'Recovery Update-state load'
. "$TEST_ROOT/extracted/recovery_drop_update_stages.sh" || fail 'Recovery Update-stage cleanup load'
. "$TEST_ROOT/extracted/recovery_reconcile.sh" || fail 'Recovery reconciler load'
. "$TEST_ROOT/extracted/update_reconcile.sh" || fail 'Update reconciler load'
. "$TEST_ROOT/extracted/recovery_archive_id_valid.sh" || fail 'Recovery archive-id load'

owner_lock="$TEST_ROOT/maintenance.lock"
mkdir -p "$owner_lock" || exit 1
merv_owner_v2_write_atomic "$owner_lock" 999999 1 dead-maintenance 1 1 || fail 'dead owner fixture'
merv_owner_lock_acquire "$owner_lock" 0 0 durable-successor || fail 'dead owner reclaim'
owner_nonce="$MERV_LOCK_NONCE"
merv_owner_lock_release "$owner_lock" "$owner_nonce" || fail 'dead owner successor release'
pass 'dead maintenance owner remains reclaimable without durable state'

MB_RECOVERY_SOURCE="$BASE_DIR/functions/mervlan_recover.sh"
MB_RECOVERY_STATE_SOURCE="$BASE_DIR/settings/lib_maintenance_recovery.sh"
MB_UPDATE_STATE_SOURCE="$BASE_DIR/settings/lib_update_state.sh"
MB_RECOVERY_SCRIPT="$TEST_ROOT/published/recover.sh"
MB_RECOVERY_STATE_SCRIPT="$TEST_ROOT/published/recovery_state.sh"
MB_UPDATE_STATE_SCRIPT="$TEST_ROOT/published/update_state.sh"
MB_BACKUP_ROOT="$TEST_ROOT/published"
mb_install_recovery_helper || fail 'Recovery helper publication'
[ -x "$MB_RECOVERY_SCRIPT" ] && [ -r "$MB_RECOVERY_STATE_SCRIPT" ] && [ -r "$MB_UPDATE_STATE_SCRIPT" ] || fail 'Recovery helper publication omitted durable parser'
pass 'standalone Recovery publishes both durable-state parsers'
MB_BACKUP_ROOT="$TEST_ROOT/backups"
MB_RECOVERY_SCRIPT="$TEST_ROOT/backups/recover.sh"

old="$TEST_ROOT/backups/.mervlan.old.4242"
stage="$TEST_ROOT/backups/.mervlan.new.4242"
mkdir -p "$old" "$stage" || exit 1
: > "$old/sentinel"
: > "$stage/sentinel"
merv_maintenance_recovery_write restore displaced "$old" "$stage" || fail 'durable marker write'

if mb_reconcile_stale_stages; then fail 'Backup admitted unresolved durable transaction'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] || fail 'Backup deleted protected durable stages'
pass 'dead-owner successor Backup admission preserves exact protected stages'

if ! recovery_reconcile_stale_stages; then fail 'explicit Recovery rejected valid durable transaction'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] || fail 'Recovery admission deleted protected durable stages before archive validation'
pass 'explicit Recovery admission preserves protected prior transaction'

merv_update_journal_write previous activated refs/heads/dev 0 1 1 1 0 interrupted \
  "$TEST_ROOT/work" none none none "$stage" "$old" old new || fail 'previous Update journal write'
merv_update_quiesce_begin previous || fail 'previous Update quiesce write'
merv_update_journal_state
[ "${MERV_UPDATE_JOURNAL_STATE:-}" = active ] || fail 'valid Update journal was not classified active'
if update_reconcile_stale_stages; then fail 'successor Update admitted active prior journal'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] || fail 'Update deleted prior rollback source'
[ -e "$MERV_UPDATE_JOURNAL" ] && [ -e "$MERV_UPDATE_QUIESCE_FILE" ] || fail 'Update overwrote prior durable state'
pass 'successor Update preserves journal quiesce and rollback source'

merv_update_quiesce_clear || fail 'quiesce cleanup'
merv_update_journal_clear || fail 'journal cleanup'
merv_maintenance_recovery_drop_recorded_stages || fail 'successful explicit recovery exact cleanup'
[ ! -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] && [ ! -e "$old" ] && [ ! -e "$stage" ] || fail 'successful explicit recovery did not clear durable state'
pass 'successful explicit recovery clears only exact recorded stages'

mkdir -p "$old" "$stage" "$TEST_ROOT/backups/.mervlan.old.unrelated" || exit 1
: > "$old/sentinel"
: > "$stage/sentinel"
: > "$TEST_ROOT/backups/.mervlan.old.unrelated/sentinel"
merv_update_journal_write previous activated refs/heads/dev 0 1 1 1 0 interrupted \
  "$TEST_ROOT/work" none none none "$stage" "$old" old new || fail 'Update explicit-recovery journal write'
recovery_drop_update_recorded_stages || fail 'explicit Recovery exact Update-stage cleanup'
[ ! -e "$old" ] && [ ! -e "$stage" ] || fail 'explicit Recovery retained recorded Update stages'
[ -e "$TEST_ROOT/backups/.mervlan.old.unrelated/sentinel" ] || fail 'explicit Recovery removed unrelated Update stage'
merv_update_journal_clear || fail 'explicit Recovery Update journal cleanup'
rm -rf "$TEST_ROOT/backups/.mervlan.old.unrelated"
pass 'explicit Recovery clears only journal-bound Update stages'

mkdir -p "$old" "$stage" || exit 1
: > "$old/sentinel"
: > "$stage/sentinel"
merv_update_journal_write previous activated refs/heads/dev 0 1 1 1 0 interrupted \
  "$TEST_ROOT/work" none none none "$stage" "$old" old new || fail 'Backup Update journal write'
merv_update_quiesce_begin previous || fail 'Backup Update quiesce write'
if mb_reconcile_stale_stages; then fail 'Backup admitted unresolved Update recovery'; fi
if ! recovery_reconcile_stale_stages; then fail 'explicit Recovery rejected unresolved Update recovery'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] || fail 'Update recovery state did not protect Backup/Recovery stages'
merv_update_quiesce_clear || fail 'Backup Update quiesce cleanup'
merv_update_journal_clear || fail 'Backup Update journal cleanup'
rm -rf "$old" "$stage"
pass 'Backup and Recovery preserve stages protected by prior Update state'

mkdir -p "$old" "$stage" || exit 1
: > "$old/sentinel"
: > "$stage/sentinel"
merv_maintenance_recovery_write restore prepared "$old" "$stage" || fail 'prepared marker write'
rm -rf "$old"
mb_reconcile_stale_stages || fail 'known abandoned pre-activation stage was not reconciled'
[ ! -e "$stage" ] && [ ! -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'prepared abandoned stage cleanup incomplete'
pass 'normal dead-owner pre-activation cleanup remains reclaimable'

mkdir -p "$old" "$stage" || exit 1
: > "$old/sentinel"
: > "$stage/sentinel"
printf 'format=1\nkind=restore\nphase=displaced\nold=../../outside\nstage=.mervlan.new.4242\n' > "$MERV_MAINTENANCE_RECOVERY_MARKER"
if mb_reconcile_stale_stages; then fail 'malformed durable marker admitted Backup'; fi
if recovery_reconcile_stale_stages; then fail 'malformed durable marker admitted Recovery cleanup'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] || fail 'malformed marker deleted ambiguous stage'
pass 'malformed durable metadata fails closed without arbitrary deletion'

printf 'format=1\nrun_id=bad\n' > "$MERV_UPDATE_JOURNAL"
if ! merv_update_journal_requires_safe_boot; then fail 'malformed Update journal did not block'; fi
if merv_update_journal_active; then fail 'malformed Update journal was classified as a valid active transaction'; fi
if update_reconcile_stale_stages; then fail 'malformed Update journal admitted stale cleanup'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] || fail 'malformed Update journal deleted stage'
pass 'malformed Update durable state blocks destructive successor'

# Archive validation must happen before the real Recovery flow reaches stale
# reconciliation; a later invalid request cannot consume a prior transaction.
RECOVERY_STATE_HELPER="$TEST_ROOT/backups/recovery_state.sh"
RECOVERY_UPDATE_STATE_HELPER="$TEST_ROOT/backups/update_state.sh"
RECOVERY_WORK="$TEST_ROOT/recovery-work"
RECOVERY_JFFS_STAGE="$TEST_ROOT/backups/.mervlan.new.7777"
RECOVERY_JFFS_OLD="$TEST_ROOT/backups/.mervlan.old.7777"
RECOVERY_LOCK_OWNED=0
recovery_load_durable_state() { return 0; }
recovery_load_update_state() { return 0; }
recovery_update_recovery_status() { return 1; }
merv_maintenance_recovery_read() { MERV_MAINTENANCE_RECOVERY_STATUS=absent; return 1; }
recovery_acquire_lock() { RECOVERY_LOCK_OWNED=1; return 0; }
recovery_log() { :; }
recovery_validate_archive() { return 1; }
recovery_reconcile_stale_stages() { : > "$TEST_ROOT/reconcile-was-called"; return 0; }
. "$TEST_ROOT/extracted/recovery_restore.sh" || fail 'Recovery restore flow load'
rm -f "$TEST_ROOT/reconcile-was-called"
if recovery_restore mervlan.backup.invalid.tar.gz yes; then fail 'invalid Recovery archive unexpectedly succeeded'; fi
[ ! -e "$TEST_ROOT/reconcile-was-called" ] || fail 'invalid Recovery archive reached stale cleanup'
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] || fail 'invalid Recovery archive deleted protected prior stages'
pass 'invalid Recovery request cannot reach stale cleanup before validation'

printf 'MAINTENANCE_DURABLE_RECOVERY_CONTRACT_OK\n'
