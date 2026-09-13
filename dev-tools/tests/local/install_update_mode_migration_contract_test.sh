#!/bin/sh
# Focused installer/update contract fixture for script modes and legacy
# pre-correction installation classification.  All state is disposable.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
INSTALL_FILE="$BASE_DIR/install.sh"
UPDATE_FILE="$BASE_DIR/functions/update_mervlan.sh"
TEST_ROOT="/tmp/mervlan_tmp/selftest.install-update-mode.$$"
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_function() {
    _source="$1"
    _name="$2"
    _dest="$3"
    awk -v name="$_name" '
        $0 ~ "^" name "\\(\\) \\{" { emit=1 }
        emit { print }
        emit && /^}/ { exit }
    ' "$_source" > "$_dest" || return 1
    [ -s "$_dest" ]
}

mode_of() { stat -c '%a' "$1" 2>/dev/null; }
assert_mode() {
    _expected="$1"
    _file="$2"
    _actual=$(mode_of "$_file")
    [ "$_actual" = "$_expected" ] || fail "mode $_file: expected $_expected, got $_actual"
}

mkdir -p "$TEST_ROOT/functions" "$TEST_ROOT/settings" "$TEST_ROOT/templates" \
    "$TEST_ROOT/nested/dir" || fail fixture-root

INSTALL_HELPER="$TEST_ROOT/install-helper.sh"
UPDATE_HELPER="$TEST_ROOT/update-helper.sh"
extract_function "$INSTALL_FILE" normalize_install_script_permissions "$INSTALL_HELPER" || fail install-helper-extraction
extract_function "$UPDATE_FILE" update_normalize_script_permissions "$UPDATE_HELPER" || fail update-helper-extraction

# Build a fake package tree from every current library, then deliberately make
# every shell file non-executable before each production normalizer runs.
for _source_lib in "$BASE_DIR"/settings/lib_*.sh; do
    [ -f "$_source_lib" ] || continue
    _lib_name=${_source_lib##*/}
    : > "$TEST_ROOT/settings/$_lib_name" || fail library-fixture
done
: > "$TEST_ROOT/settings/var_settings.sh" || fail static-fixture
: > "$TEST_ROOT/settings/log_settings.sh" || fail static-fixture
: > "$TEST_ROOT/settings/mac_shield_snapshot.sh" || fail static-fixture
: > "$TEST_ROOT/templates/mervlan_templates.sh" || fail static-fixture
: > "$TEST_ROOT/functions/runtime.sh" || fail runtime-fixture
: > "$TEST_ROOT/nested/dir/runtime.sh" || fail runtime-fixture

for _shell_file in "$TEST_ROOT"/settings/*.sh "$TEST_ROOT"/templates/*.sh \
    "$TEST_ROOT"/functions/*.sh "$TEST_ROOT"/nested/dir/*.sh; do
    [ -f "$_shell_file" ] || continue
    chmod 600 "$_shell_file" || fail fixture-mode
done

MERV_BASE="$TEST_ROOT"
export MERV_BASE
. "$INSTALL_HELPER" || fail install-helper-source
normalize_install_script_permissions || fail install-normalizer

for _library in "$TEST_ROOT"/settings/lib_*.sh; do
    [ -f "$_library" ] || continue
    assert_mode 644 "$_library"
done
assert_mode 644 "$TEST_ROOT/settings/var_settings.sh"
assert_mode 644 "$TEST_ROOT/settings/log_settings.sh"
assert_mode 644 "$TEST_ROOT/settings/mac_shield_snapshot.sh"
assert_mode 644 "$TEST_ROOT/templates/mervlan_templates.sh"
assert_mode 755 "$TEST_ROOT/functions/runtime.sh"
assert_mode 755 "$TEST_ROOT/nested/dir/runtime.sh"
pass install-all-library-modes

for _shell_file in "$TEST_ROOT"/settings/*.sh "$TEST_ROOT"/templates/*.sh \
    "$TEST_ROOT"/functions/*.sh "$TEST_ROOT"/nested/dir/*.sh; do
    [ -f "$_shell_file" ] || continue
    chmod 600 "$_shell_file" || fail fixture-reset-mode
done

. "$UPDATE_HELPER" || fail update-helper-source
update_normalize_script_permissions "$TEST_ROOT" || fail update-normalizer
for _library in "$TEST_ROOT"/settings/lib_*.sh; do
    [ -f "$_library" ] || continue
    assert_mode 644 "$_library"
done
assert_mode 644 "$TEST_ROOT/settings/var_settings.sh"
assert_mode 644 "$TEST_ROOT/settings/log_settings.sh"
assert_mode 644 "$TEST_ROOT/settings/mac_shield_snapshot.sh"
assert_mode 644 "$TEST_ROOT/templates/mervlan_templates.sh"
assert_mode 755 "$TEST_ROOT/functions/runtime.sh"
assert_mode 755 "$TEST_ROOT/nested/dir/runtime.sh"
pass update-all-library-modes

# A complete immediate pre-correction install has valid settings and the old
# baseline files but lacks only the newly introduced reconcile pair.  It must
# remain valid so the full installer presents the normal preserve path.
LEGACY_ROOT="$TEST_ROOT/legacy"
mkdir -p "$LEGACY_ROOT/settings" "$LEGACY_ROOT/www" "$LEGACY_ROOT/tmp" "$LEGACY_ROOT/.ssh" || fail legacy-root
printf '%s\n' '{"General":{},"SSH":{},"Nodes":{},"SSH_USER":"admin","SSH_PORT":"22"}' \
    > "$LEGACY_ROOT/settings/settings.json"
for _required in install.sh uninstall.sh mervlan.asp www/index.html \
    settings/lib_json.sh settings/lib_update_state.sh settings/lib_node_reconcile.sh; do
    case "$_required" in
        */*) mkdir -p "$LEGACY_ROOT/${_required%/*}" 2>/dev/null || fail legacy-dir ;;
    esac
    : > "$LEGACY_ROOT/$_required" || fail legacy-file
done
printf 'private\n' > "$LEGACY_ROOT/.ssh/vlan_manager"
printf 'public\n' > "$LEGACY_ROOT/.ssh/vlan_manager.pub"
printf 'client\n' > "$LEGACY_ROOT/tmp/client_name_override.db"

CLASSIFIER="$TEST_ROOT/classifier.sh"
: > "$CLASSIFIER" || fail classifier-file
extract_function "$INSTALL_FILE" settings_file_looks_valid "$CLASSIFIER" || fail settings-helper-extraction
extract_function "$INSTALL_FILE" detect_existing_installation "$TEST_ROOT/detect.sh" || fail detect-extraction
cat "$TEST_ROOT/detect.sh" >> "$CLASSIFIER" || fail classifier-append
extract_function "$INSTALL_FILE" prepare_preserved_files "$TEST_ROOT/preserve.sh" || fail preserve-extraction
cat "$TEST_ROOT/preserve.sh" >> "$CLASSIFIER" || fail classifier-append
. "$CLASSIFIER" || fail classifier-source

ACTIVE_MERV_BASE="$LEGACY_ROOT"
INSTALL_STATE=absent
detect_existing_installation || fail legacy-detect
[ "$INSTALL_STATE" = valid ] || fail "legacy pre-correction install classified as $INSTALL_STATE"

TMP_DIR="$TEST_ROOT/preserve"
INSTALL_POLICY=preserve
RESULT_EXISTING=""
prepare_preserved_files || fail legacy-preserve
[ -f "$INSTALL_PRESERVE_DIR/settings/settings.json" ] || fail preserved-settings
[ -f "$INSTALL_PRESERVE_DIR/.ssh/vlan_manager" ] || fail preserved-private-key
[ -f "$INSTALL_PRESERVE_DIR/tmp/client_name_override.db" ] || fail preserved-client-db
pass legacy-valid-preserve

rm -f "$LEGACY_ROOT/settings/lib_node_reconcile.sh" || fail baseline-removal
INSTALL_STATE=absent
detect_existing_installation || fail partial-detect
[ "$INSTALL_STATE" = partial ] || fail "baseline-incomplete install classified as $INSTALL_STATE"
pass baseline-incomplete-partial

# New reconcile files remain strict package requirements even though they are
# intentionally excluded from pre-download legacy classification.
grep -Fq 'settings/lib_settings_reconcile.sh' "$INSTALL_FILE" || fail strict-library-requirement
grep -Fq 'functions/settings_reconcile.sh' "$INSTALL_FILE" || fail strict-helper-requirement
pass strict-new-package-requirements

printf 'INSTALL_UPDATE_MODE_MIGRATION_CONTRACT_OK\n'
