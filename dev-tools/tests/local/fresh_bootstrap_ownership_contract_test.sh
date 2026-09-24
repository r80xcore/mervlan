#!/bin/sh
# Focused contract for the staged fresh-bootstrap ownership lifecycle.
# This exercises the real owner/recovery/update libraries in an isolated
# temporary tree; it never touches a router or the live addon paths.
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE_REPO=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
OWNER="$MERV_BASE_REPO/settings/lib_owner_lock.sh"
UPDATE_STATE="$MERV_BASE_REPO/settings/lib_update_state.sh"
RECOVERY="$MERV_BASE_REPO/settings/lib_maintenance_recovery.sh"
INSTALL="$MERV_BASE_REPO/install.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TEST_ROOT="/tmp/mervlan_tmp/selftest.fresh-bootstrap.$$"
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15
mkdir -p "$TEST_ROOT" || fail 'fixture root creation'

extract_function() {
    _ef_file=$1
    _ef_name=$2
    _ef_out=$3
    awk -v name="$_ef_name" '
        $0 ~ "^" name "\\(\\) \\{" { emit=1 }
        emit {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth+=opens-closes
            if (depth == 0) exit
        }
    ' "$_ef_file" >"$_ef_out"
    [ -s "$_ef_out" ]
}

# Keep the real implementations available behind wrappers so the test can
# prove the order at the function boundary without making release unconditional.
extract_function "$RECOVERY" merv_maintenance_recovery_root_prepare "$TEST_ROOT/root-prepare.sh" ||
    fail 'recovery-root prepare extraction'
sed '1s/merv_maintenance_recovery_root_prepare/merv_test_root_prepare_real/' \
    "$TEST_ROOT/root-prepare.sh" >"$TEST_ROOT/root-prepare-real.sh"
extract_function "$RECOVERY" merv_maintenance_recovery_direct_gate "$TEST_ROOT/direct-gate.sh" ||
    fail 'recovery direct-gate extraction'
sed '1s/merv_maintenance_recovery_direct_gate/merv_test_direct_gate_real/' \
    "$TEST_ROOT/direct-gate.sh" >"$TEST_ROOT/direct-gate-real.sh"
extract_function "$INSTALL" install_external_owner_current "$TEST_ROOT/external-owner.sh" ||
    fail 'external owner helper extraction'
extract_function "$INSTALL" settings_file_looks_valid "$TEST_ROOT/settings-valid.sh" ||
    fail 'settings validator extraction'
extract_function "$INSTALL" install_tree_valid "$TEST_ROOT/tree-valid.sh" ||
    fail 'active-tree validator extraction'
extract_function "$INSTALL" install_bootstrap_transition "$TEST_ROOT/bootstrap-transition.sh" ||
    fail 'bootstrap transition extraction'

MERV_BASE="$MERV_BASE_REPO"
LIB_IDENTITY_LOADED=""
LIB_OWNER_LOCK_LOADED=""
LIB_UPDATE_STATE_LOADED=""
LIB_MAINTENANCE_RECOVERY_LOADED=""
. "$OWNER" || fail 'owner library load'
. "$UPDATE_STATE" || fail 'update-state library load'
. "$RECOVERY" || fail 'recovery library load'
. "$TEST_ROOT/root-prepare-real.sh" || fail 'real root-prepare helper load'
. "$TEST_ROOT/direct-gate-real.sh" || fail 'real direct-gate helper load'
. "$TEST_ROOT/external-owner.sh" || fail 'external owner helper load'
. "$TEST_ROOT/settings-valid.sh" || fail 'settings validator load'
. "$TEST_ROOT/tree-valid.sh" || fail 'active-tree validator load'

test_owner_live() {
    [ "${MERV_MAINTENANCE_ENTRY_OWNED:-0}" = "1" ] || return 1
    merv_owner_v2_matches "${MERV_MAINTENANCE_ENTRY_LOCK:-}" "$$" \
        "${MERV_MAINTENANCE_ENTRY_START:-}" "${MERV_MAINTENANCE_ENTRY_NONCE:-}"
}

merv_maintenance_recovery_root_prepare() {
    test_owner_live || {
        printf 'root-prepare-owner=0\n' >>"$TRACE_FILE"
        return 1
    }
    printf 'root-prepare-owner=1\n' >>"$TRACE_FILE"
    [ "${FRESH_PREPARE_FAIL:-0}" = "1" ] && return 1
    merv_test_root_prepare_real "$@"
}

merv_maintenance_recovery_direct_gate() {
    test_owner_live || {
        printf 'recovery-gate-owner=0\n' >>"$TRACE_FILE"
        return 1
    }
    [ -d "$MERV_MAINTENANCE_RECOVERY_ROOT" ] || return 1
    printf 'recovery-gate-owner=1\n' >>"$TRACE_FILE"
    merv_test_direct_gate_real "$@"
}

reset_case() {
    CASE_ROOT="$TEST_ROOT/$1"
    mkdir -p "$CASE_ROOT/addons" "$CASE_ROOT/runtime" || return 1
    MERV_BASE="$CASE_ROOT/addons/mervlan"
    MERV_STATE_ROOT="$CASE_ROOT/state"
    MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
    MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
    MERV_MAINTENANCE_RECOVERY_ROOT="$CASE_ROOT/backups"
    MERV_MAINTENANCE_RECOVERY_MARKER="$MERV_MAINTENANCE_RECOVERY_ROOT/.mervlan.recovery"
    MERVLAN_MAINTENANCE_LOCK_OVERRIDE="$CASE_ROOT/runtime/locks/mervlan_maintenance.lock"
    TRACE_FILE="$CASE_ROOT/trace"
    : >"$TRACE_FILE"
    MERV_MAINTENANCE_ENTRY_OWNED=0
    MERV_MAINTENANCE_ENTRY_DELEGATED=0
    MERV_MAINTENANCE_ENTRY_LOCK="$MERVLAN_MAINTENANCE_LOCK_OVERRIDE"
    MERV_MAINTENANCE_ENTRY_NONCE=""
    MERV_MAINTENANCE_ENTRY_START=""
    MERV_MAINTENANCE_DELEGATED=0
    MERV_MAINTENANCE_DELEGATION_KIND=""
    MERV_INSTALL_DELEGATION=0
    unset MERV_BACKUP_DELEGATION MERV_RECOVERY_DELEGATION MERV_UNINSTALL_DELEGATION
    unset FRESH_PREPARE_FAIL
}

# Static ordering guards cover the full installer path between admission and
# the first external/active-tree mutations.
_admit_line=$(grep -n '^install_maintenance_admit || exit 1' "$INSTALL" | cut -d: -f1)
_capture_line=$(grep -n 'install_external_capture_projection || {' "$INSTALL" | tail -1 | cut -d: -f1)
_dirs_line=$(grep -n 'create_dirs_first_install || {' "$INSTALL" | tail -1 | cut -d: -f1)
_download_line=$(grep -n 'download_mervlan || {' "$INSTALL" | tail -1 | cut -d: -f1)
[ "$_admit_line" -lt "$_capture_line" ] || fail 'projection capture precedes maintenance admission'
[ "$_admit_line" -lt "$_dirs_line" ] || fail 'first-install directory mutation precedes admission'
[ "$_admit_line" -lt "$_download_line" ] || fail 'package activation precedes maintenance admission'
! grep -Fq 'normal maintenance ownership begins after the package is installed' "$INSTALL" ||
    fail 'ownerless fresh-bootstrap transition text remains'
grep -Fq 'merv_maintenance_direct_admit fresh-bootstrap' "$INSTALL" ||
    fail 'installer does not request fresh-bootstrap admission'
! grep -Fq 'merv_maintenance_direct_admit;' "$TEST_ROOT/bootstrap-transition.sh" ||
    fail 'bootstrap transition reacquires a second owner'
grep -Fq 'MERV_MAINTENANCE_ENTRY_LOCK="$_ibt_lock"' "$TEST_ROOT/bootstrap-transition.sh" ||
    fail 'bootstrap transition does not restore the original owner tuple'

# A genuine fresh admission uses the real owner and gates. The wrappers prove
# the owner is live before recovery-root preparation and before the ordinary
# recovery gate, while the real implementations perform the mutations/checks.
reset_case success || fail 'success fixture setup'
merv_maintenance_direct_admit fresh-bootstrap || fail 'fresh-bootstrap direct admission'
[ "${MERV_MAINTENANCE_ENTRY_OWNED:-0}" = "1" ] || fail 'fresh owner not marked active'
[ -d "$MERV_MAINTENANCE_RECOVERY_ROOT" ] || fail 'fresh recovery root was not prepared'
grep -Fqx 'root-prepare-owner=1' "$TRACE_FILE" || fail 'recovery root was not prepared under owner'
grep -Fqx 'recovery-gate-owner=1' "$TRACE_FILE" || fail 'recovery gate did not run under owner'
merv_maintenance_direct_export_install_context || fail 'installer delegation export'
install_external_owner_current || fail 'external projection owner check'
_success_nonce="$MERV_MAINTENANCE_ENTRY_NONCE"
merv_maintenance_direct_release || fail 'fresh owner release'
[ ! -e "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" ] || fail 'canonical owner remained after release'
[ "$_success_nonce" != "" ] || fail 'fresh owner nonce was empty'
if install_external_owner_current; then fail 'external owner check passed after release'; fi
printf 'PASS: fresh admission, recovery-root ordering, projection ownership, and release\n'

# Ordinary established-install admission remains fail-closed when the recovery
# root is absent; it must not receive the fresh exception.
reset_case established
if merv_maintenance_direct_admit; then fail 'ordinary admission accepted absent recovery root'; fi
[ ! -e "$MERV_MAINTENANCE_RECOVERY_ROOT" ] || fail 'ordinary admission created recovery root'
[ ! -e "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" ] || fail 'ordinary admission left owner after rejection'
printf 'PASS: established admission remains fail-closed\n'

# The narrow mode rejects an existing recovery object before ownership and does
# not reinterpret it as a safe empty root.
reset_case existing-recovery
mkdir -p "$MERV_MAINTENANCE_RECOVERY_ROOT" || fail 'existing recovery fixture setup'
if merv_maintenance_direct_admit fresh-bootstrap; then fail 'fresh mode accepted existing recovery root'; fi
[ ! -e "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" ] || fail 'existing recovery rejection acquired owner'
printf 'PASS: existing recovery evidence blocks fresh exception\n'

# An externally supplied delegation environment does not authorize fresh mode.
reset_case external-delegation
MERV_MAINTENANCE_DELEGATED=1
MERV_MAINTENANCE_DELEGATION_KIND=install
MERV_INSTALL_DELEGATION=1
MERV_MAINTENANCE_OWNER_PID=1
MERV_MAINTENANCE_OWNER_START=1
MERV_MAINTENANCE_OWNER_NONCE=external
merv_maintenance_direct_admit fresh-bootstrap || fail 'fresh mode trusted external delegation'
[ "${MERV_MAINTENANCE_ENTRY_OWNED:-0}" = "1" ] || fail 'fresh mode used delegated ownership'
merv_maintenance_direct_release || fail 'external-delegation fixture release'
printf 'PASS: fresh mode requires canonical acquisition, not environment authority\n'

# If the canonical owner is unavailable, no recovery root is created.
reset_case owner-failure
merv_owner_lock_acquire "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" 1800 1 test-owner ||
    fail 'owner-failure fixture owner setup'
_held_nonce="$MERV_LOCK_NONCE"
if merv_maintenance_direct_admit fresh-bootstrap; then fail 'fresh admission ignored live owner'; fi
[ ! -e "$MERV_MAINTENANCE_RECOVERY_ROOT" ] || fail 'owner failure created recovery root'
merv_owner_lock_release "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" "$_held_nonce" ||
    fail 'owner-failure fixture owner release'
printf 'PASS: owner acquisition failure is mutation-free\n'

# Preparation failure after owner acquisition releases the exact owner and does
# not activate anything. The wrapper injects only the preparation failure;
# release still uses the real owner implementation.
reset_case prepare-failure
FRESH_PREPARE_FAIL=1
if merv_maintenance_direct_admit fresh-bootstrap; then fail 'fresh admission ignored root preparation failure'; fi
[ ! -e "$MERVLAN_MAINTENANCE_LOCK_OVERRIDE" ] || fail 'preparation failure retained canonical owner'
[ ! -e "$MERV_MAINTENANCE_RECOVERY_ROOT" ] || fail 'preparation failure created recovery root'
grep -Fqx 'root-prepare-owner=1' "$TRACE_FILE" || fail 'preparation failure ran without owner'
printf 'PASS: recovery-root preparation failure releases ownership\n'

# Exercise the real transition against a complete active tree. The owner is
# acquired before the package is treated as active, then the production
# transition reloads the active cohort and must keep the same owner nonce.
reset_case transition
mkdir -p "$MERV_STATE_ROOT" "$CASE_ROOT/active" || fail 'transition state setup'
cp -a "$MERV_BASE_REPO"/. "$CASE_ROOT/active"/ || fail 'transition active-tree fixture copy'
merv_maintenance_direct_admit fresh-bootstrap || fail 'transition fresh admission'
_transition_nonce="$MERV_MAINTENANCE_ENTRY_NONCE"
MERV_BASE="$CASE_ROOT/active"
MODE=full
MERV_INSTALL_BOOTSTRAP_FRESH=1
MERV_MAINTENANCE_ENTRY_ADMITTED=1
. "$TEST_ROOT/bootstrap-transition.sh" || fail 'transition helper load'
install_bootstrap_transition || fail 'same-owner bootstrap transition'
[ "$MERV_SUPPORT_ROOT" = "$MERV_BASE" ] || fail 'support root did not rebind to active tree'
[ "$MERV_MAINTENANCE_ENTRY_OWNED" = "1" ] || fail 'transition lost owner state'
[ "$MERV_MAINTENANCE_ENTRY_NONCE" = "$_transition_nonce" ] || fail 'transition changed owner nonce'
[ "$MERV_INSTALL_BOOTSTRAP_FRESH" = "0" ] || fail 'transition marker was not cleared'
merv_owner_v2_matches "$MERV_MAINTENANCE_ENTRY_LOCK" "$$" \
    "$MERV_MAINTENANCE_ENTRY_START" "$MERV_MAINTENANCE_ENTRY_NONCE" ||
    fail 'transition owner is no longer authoritative'
merv_maintenance_direct_release || fail 'transition owner release'
printf 'PASS: active support transition keeps the same canonical owner\n'

printf 'FRESH_BOOTSTRAP_OWNERSHIP_CONTRACT_OK\n'
