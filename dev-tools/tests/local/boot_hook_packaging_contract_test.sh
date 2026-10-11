#!/bin/sh
# Verify the boot-integrity library is closed over each staged/package path.

set -eu
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-boot-package.$(date +%s).$$"
PATHS_FILE="$TEST_ROOT/repair-paths"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { grep -Fq "$2" "$1" || fail "$3"; }
count_at_least() {
    _count=$(grep -Fc "$2" "$1" 2>/dev/null || :)
    [ "${_count:-0}" -ge "$3" ] || fail "$4 (found ${_count:-0}, wanted at least $3)"
}

_integrity="$BASE_DIR/settings/lib_boot_integrity.sh"
_manifest="$BASE_DIR/functions/update_mervlan_repair.manifest"
[ -f "$_integrity" ] && [ -r "$_integrity" ] || fail 'integrity library is absent from source tree'
[ ! -x "$_integrity" ] || fail 'integrity library must remain a 0644 sourceable settings library'

# Exercise the emergency repair's actual manifest admission functions against
# the checked-in manifest, so the new 0644 component is accepted by the repair
# path without adding any hook mutation behavior to the rescue executable.
eval "$(sed -n '/^safe_rel_path() {/,/^}/p' "$BASE_DIR/functions/update_mervlan_repair.sh")"
eval "$(sed -n '/^path_protected() {/,/^}/p' "$BASE_DIR/functions/update_mervlan_repair.sh")"
eval "$(sed -n '/^repair_path_allowed() {/,/^}/p' "$BASE_DIR/functions/update_mervlan_repair.sh")"
eval "$(sed -n '/^parse_manifest() {/,/^}/p' "$BASE_DIR/functions/update_mervlan_repair.sh")"
parse_manifest "$_manifest" || fail 'emergency repair rejects its checked-in manifest'
grep -Fqx '0644 settings/lib_boot_integrity.sh' "$PATHS_FILE" || fail 'emergency repair manifest did not admit the integrity library as 0644'

# Each independent package/staging/activation boundary must carry the library.
_installer="$BASE_DIR/install.sh"
_updater="$BASE_DIR/functions/update_mervlan.sh"
_sync="$BASE_DIR/functions/sync_nodes.sh"
_backup="$BASE_DIR/functions/mervlan_backup.sh"
_recovery="$BASE_DIR/functions/mervlan_recover.sh"
count_at_least "$_installer" 'settings/lib_boot_integrity.sh' 7 'installer required-file, staged-cohort, or final-check closure'
contains "$_updater" 'settings/lib_boot_integrity.sh' 'updater core stage closure'
count_at_least "$_sync" 'settings/lib_boot_integrity.sh' 2 'node transfer and 0644 manifest closure'
contains "$_sync" '"644:$_snfr_file"' 'staged finalization no longer applies the non-executable manifest'
contains "$BASE_DIR/functions/mervlan_node_mutate.sh" 'lib_boot_integrity.sh' 'guarded node activation lost its staged integrity dependency'
contains "$_backup" 'MB_RECOVERY_INTEGRITY_SOURCE|$MB_RECOVERY_INTEGRITY_SCRIPT' 'protected Backup recovery-helper copy closure'
contains "$_recovery" 'recovery_integrity_lib="$MERVLAN_RECOVERY_BACKUP_ROOT/lib_boot_integrity.sh"' 'Recovery protected verifier lookup closure'
contains "$_recovery" 'recovery_json_lib="$MERVLAN_RECOVERY_BACKUP_ROOT/lib_json.sh"' 'Recovery protected JSON lookup closure'
if grep -Fq 'recovery_candidate/lib_boot_integrity.sh' "$_recovery"; then
    fail 'Recovery sources verifier from the selected tree'
fi

# Reinstall remains public-only, and the emergency repair remains independent
# of the external router hook files.
contains "$_installer" 'RESULT_HOOKS="PRESERVED - reinstall does not modify hooks"' 'installer reinstall no longer records hook preservation'
contains "$_installer" '[ "$MODE" != "reinstall" ]' 'installer final hook verification is not gated away from reinstall'
if grep -Fq '/jffs/scripts/' "$BASE_DIR/functions/update_mervlan_repair.sh"; then
    fail 'emergency repair references external /jffs/scripts hooks'
fi

printf 'BOOT_HOOK_PACKAGING_CONTRACT_OK\n'
