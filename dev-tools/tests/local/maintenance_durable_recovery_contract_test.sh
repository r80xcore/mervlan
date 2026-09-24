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
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_begin_durable_recovery \
  "$TEST_ROOT/extracted/mb_begin_recovery.sh" || fail 'Backup recovery begin extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_mark_durable_recovery_displaced \
  "$TEST_ROOT/extracted/mb_mark_displaced.sh" || fail 'Backup recovery transition extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_clear_durable_recovery \
  "$TEST_ROOT/extracted/mb_clear_recovery.sh" || fail 'Backup recovery clear extraction'
extract_function "$BASE_DIR/functions/mervlan_backup.sh" mb_install_recovery_helper \
  "$TEST_ROOT/extracted/mb_install_recovery_helper.sh" || fail 'Recovery helper publisher extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_begin_durable_recovery \
  "$TEST_ROOT/extracted/recovery_begin.sh" || fail 'standalone Recovery begin extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_mark_durable_recovery_displaced \
  "$TEST_ROOT/extracted/recovery_mark_displaced.sh" || fail 'standalone Recovery transition extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_clear_durable_recovery \
  "$TEST_ROOT/extracted/recovery_clear.sh" || fail 'standalone Recovery clear extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_reconcile_stale_stages \
  "$TEST_ROOT/extracted/recovery_reconcile.sh" || fail 'Recovery reconciler extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_path_present \
  "$TEST_ROOT/extracted/recovery_path_present.sh" || fail 'Recovery path probe extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_path_chain_safe \
  "$TEST_ROOT/extracted/recovery_path_chain_safe.sh" || fail 'Recovery path-chain extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_path_parent_prepare \
  "$TEST_ROOT/extracted/recovery_path_parent_prepare.sh" || fail 'Recovery parent preparation extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_path_absent_authoritative \
  "$TEST_ROOT/extracted/recovery_path_absent_authoritative.sh" || fail 'Recovery absence probe extraction'
extract_function "$BASE_DIR/functions/mervlan_recover.sh" recovery_workspace_prepare \
  "$TEST_ROOT/extracted/recovery_workspace_prepare.sh" || fail 'Recovery workspace extraction'
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
MERVLAN_RECOVERY_TMP_ROOT="$TEST_ROOT/recovery-tmp"
MERVLAN_RECOVERY_STATE_ROOT="$TEST_ROOT/state"
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
. "$TEST_ROOT/extracted/mb_begin_recovery.sh" || fail 'Backup recovery begin load'
. "$TEST_ROOT/extracted/mb_mark_displaced.sh" || fail 'Backup recovery transition load'
. "$TEST_ROOT/extracted/mb_clear_recovery.sh" || fail 'Backup recovery clear load'
. "$TEST_ROOT/extracted/mb_install_recovery_helper.sh" || fail 'Recovery helper publisher load'
. "$TEST_ROOT/extracted/recovery_begin.sh" || fail 'standalone Recovery begin load'
. "$TEST_ROOT/extracted/recovery_mark_displaced.sh" || fail 'standalone Recovery transition load'
. "$TEST_ROOT/extracted/recovery_clear.sh" || fail 'standalone Recovery clear load'
. "$TEST_ROOT/extracted/recovery_update_state.sh" || fail 'Recovery Update-state load'
. "$TEST_ROOT/extracted/recovery_drop_update_stages.sh" || fail 'Recovery Update-stage cleanup load'
. "$TEST_ROOT/extracted/recovery_reconcile.sh" || fail 'Recovery reconciler load'
. "$TEST_ROOT/extracted/recovery_path_present.sh" || fail 'Recovery path probe load'
. "$TEST_ROOT/extracted/recovery_path_chain_safe.sh" || fail 'Recovery path-chain load'
. "$TEST_ROOT/extracted/recovery_path_parent_prepare.sh" || fail 'Recovery parent preparation load'
. "$TEST_ROOT/extracted/recovery_path_absent_authoritative.sh" || fail 'Recovery absence probe load'
. "$TEST_ROOT/extracted/recovery_workspace_prepare.sh" || fail 'Recovery workspace load'
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

reset_recovery_fixture() {
  rm -rf "$old" "$stage" "$MERV_MAINTENANCE_RECOVERY_MARKER" || exit 1
  mkdir -p "$old" "$stage" || exit 1
  : > "$old/sentinel"
  : > "$stage/sentinel"
}

assert_marker() {
  _mdr_kind="$1" _mdr_phase="$2"
  merv_maintenance_recovery_read || fail "marker read $_mdr_kind/$_mdr_phase"
  [ "$MERV_MAINTENANCE_RECOVERY_KIND" = "$_mdr_kind" ] || fail "marker kind $_mdr_kind/$_mdr_phase"
  [ "$MERV_MAINTENANCE_RECOVERY_PHASE" = "$_mdr_phase" ] || fail "marker phase $_mdr_kind/$_mdr_phase"
  [ "$MERV_MAINTENANCE_RECOVERY_OLD" = "$old" ] || fail "marker old $_mdr_kind/$_mdr_phase"
  [ "$MERV_MAINTENANCE_RECOVERY_STAGE" = "$stage" ] || fail "marker stage $_mdr_kind/$_mdr_phase"
}

# Exercise the real Restore and standalone Recovery begin/transition/clear
# callers.  Directly writing a displaced marker would not catch the original
# create-only writer bug.
reset_recovery_fixture
MB_JFFS_OLD="$old"; MB_JFFS_STAGE="$stage"; MB_DURABLE_RECOVERY_OWNED=0
mb_begin_durable_recovery || fail 'Backup recovery begin'
assert_marker restore prepared
mb_mark_durable_recovery_displaced || fail 'Backup recovery prepared-to-displaced transition'
assert_marker restore displaced
mb_clear_durable_recovery || fail 'Backup recovery clear'
[ ! -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'Backup recovery marker remained after clear'
pass 'Backup Restore durable recovery transitions prepared to displaced'

reset_recovery_fixture
RECOVERY_JFFS_OLD="$old"; RECOVERY_JFFS_STAGE="$stage"; RECOVERY_DURABLE_RECOVERY_OWNED=0
recovery_begin_durable_recovery || fail 'standalone Recovery begin'
assert_marker recovery prepared
recovery_mark_durable_recovery_displaced || fail 'standalone Recovery prepared-to-displaced transition'
assert_marker recovery displaced
recovery_clear_durable_recovery || fail 'standalone Recovery clear'
[ ! -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'standalone Recovery marker remained after clear'
pass 'standalone Recovery durable recovery transitions prepared to displaced'

# Creation remains create-only, and only the authenticated prepared-to-
# displaced transition is allowed.
reset_recovery_fixture
merv_maintenance_recovery_write restore prepared "$old" "$stage" || fail 'prepared marker creation'
if merv_maintenance_recovery_write recovery prepared "$old" "$stage"; then fail 'creation overwrote existing marker'; fi
assert_marker restore prepared
if merv_maintenance_recovery_transition recovery prepared displaced "$old" "$stage"; then fail 'wrong kind transition'; fi
assert_marker restore prepared
if merv_maintenance_recovery_transition restore prepared displaced "$old.bad" "$stage"; then fail 'wrong old-path transition'; fi
assert_marker restore prepared
if merv_maintenance_recovery_transition restore prepared displaced "$old" "$stage.bad"; then fail 'wrong stage-path transition'; fi
assert_marker restore prepared
if merv_maintenance_recovery_transition restore displaced displaced "$old" "$stage"; then fail 'wrong expected phase transition'; fi
assert_marker restore prepared
if merv_maintenance_recovery_transition restore prepared prepared "$old" "$stage"; then fail 'unsupported transition'; fi
assert_marker restore prepared
printf 'format=1\nkind=restore\nphase=prepared\nold=../../outside\nstage=.mervlan.new.4242\n' > "$TEST_ROOT/malformed-marker" || exit 1
cp -p "$TEST_ROOT/malformed-marker" "$MERV_MAINTENANCE_RECOVERY_MARKER" || exit 1
if merv_maintenance_recovery_transition restore prepared displaced "$old" "$stage"; then fail 'malformed marker transition'; fi
cmp -s "$TEST_ROOT/malformed-marker" "$MERV_MAINTENANCE_RECOVERY_MARKER" || fail 'malformed marker changed'
rm -f "$MERV_MAINTENANCE_RECOVERY_MARKER"
merv_maintenance_recovery_write restore prepared "$old" "$stage" || fail 'symlink fixture marker creation'
rm -f "$MERV_MAINTENANCE_RECOVERY_MARKER"
ln -s "$old/sentinel" "$MERV_MAINTENANCE_RECOVERY_MARKER" || exit 1
if merv_maintenance_recovery_transition restore prepared displaced "$old" "$stage"; then fail 'symlink marker transition'; fi
[ -L "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'symlink marker was replaced'
rm -f "$MERV_MAINTENANCE_RECOVERY_MARKER"
merv_maintenance_recovery_write restore displaced "$old" "$stage" || fail 'displaced marker fixture creation'
if merv_maintenance_recovery_transition restore displaced displaced "$old" "$stage"; then fail 'displaced-to-displaced transition'; fi
assert_marker restore displaced
merv_maintenance_recovery_clear || fail 'transition rejection fixture cleanup'
pass 'durable recovery transition rejects foreign, malformed, symlink, and unsupported state'

reset_recovery_fixture
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

# A successor Update has no authority to consume an interrupted Restore or
# standalone Recovery. These cases intentionally have no Update journal or
# quiesce marker, so only the foreign durable marker can protect the trees.
if update_reconcile_stale_stages; then fail 'Update admitted unresolved Restore durable transaction'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] && [ -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'Update deleted Restore-protected stages'
pass 'successor Update preserves Restore-protected stages without Update state'

# Reset the fixture's prior Restore marker before representing a separate
# authenticated Recovery transaction. Production code never overwrites an
# active marker; each scenario must model its predecessor as already consumed.
merv_maintenance_recovery_clear || fail 'prior durable marker fixture cleanup'
merv_maintenance_recovery_write recovery displaced "$old" "$stage" || fail 'Recovery durable marker write'
if update_reconcile_stale_stages; then fail 'Update admitted unresolved standalone Recovery transaction'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] && [ -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'Update deleted Recovery-protected stages'
pass 'successor Update preserves Recovery-protected stages without Update state'

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

# A fully rolled-back prepared transaction has no exact old or stage tree left.
# With a complete active tree this is safe to retire, but only this exact state
# is reclaimable; malformed or displaced state remains protected below.
reset_recovery_fixture
rm -rf "$old" "$stage"
merv_maintenance_recovery_write restore prepared "$old" "$stage" || fail 'fully rolled-back prepared marker write'
mb_reconcile_stale_stages || fail 'Backup did not retire fully rolled-back prepared state'
[ ! -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'Backup retained fully rolled-back prepared marker'
pass 'Backup retires prepared state when active tree and exact recorded trees are reconciled'

reset_recovery_fixture
rm -rf "$old" "$stage"
merv_maintenance_recovery_write recovery prepared "$old" "$stage" || fail 'Recovery fully rolled-back prepared marker write'
recovery_reconcile_stale_stages || fail 'Recovery did not retire fully rolled-back prepared state'
[ ! -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'Recovery retained fully rolled-back prepared marker'
pass 'standalone Recovery retires fully rolled-back prepared state'

reset_recovery_fixture
rm -rf "$old" "$stage"
merv_maintenance_recovery_write restore displaced "$old" "$stage" || fail 'displaced missing-tree marker write'
if mb_reconcile_stale_stages; then fail 'Backup guessed away displaced missing-tree state'; fi
[ -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'Backup cleared displaced missing-tree marker'
recovery_reconcile_stale_stages || fail 'Recovery rejected preserved displaced missing-tree state'
[ -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'Recovery cleared displaced missing-tree marker'
merv_maintenance_recovery_clear || fail 'displaced missing-tree fixture cleanup'
pass 'displaced state with missing trees remains protected'

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
if update_reconcile_stale_stages; then fail 'malformed durable marker admitted Update cleanup'; fi
[ -e "$old/sentinel" ] && [ -e "$stage/sentinel" ] || fail 'malformed marker deleted ambiguous stage'
pass 'malformed durable metadata fails closed without arbitrary deletion'

rm -f "$MERV_MAINTENANCE_RECOVERY_MARKER"
if update_reconcile_stale_stages; then fail 'Update admitted unbound stale stages without durable state'; fi
[ -e "$old" ] && [ -e "$stage" ] || fail 'Update deleted unbound stale stages without durable state'
pass 'Update preserves unbound stale stages without durable state'

mkdir -p "$old" "$stage" || exit 1
: > "$old/sentinel"
: > "$stage/sentinel"
merv_maintenance_recovery_write restore prepared "$old" "$stage" || fail 'Update prepared marker write'
rm -rf "$old"
update_reconcile_stale_stages || fail 'Update did not reconcile known abandoned pre-activation stage'
[ ! -e "$stage" ] && [ ! -e "$MERV_MAINTENANCE_RECOVERY_MARKER" ] || fail 'Update prepared-stage reconciliation retained marker or stage'
pass 'Update preserves the known abandoned pre-activation reclaim rule'

mkdir -p "$old" "$stage" || exit 1
: > "$old/sentinel"
: > "$stage/sentinel"

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
