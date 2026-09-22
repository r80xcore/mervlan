#!/bin/sh
# Behavioral regression coverage for Merlin's canonical /www/user WebUI alias.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
INSTALL="$BASE_DIR/install.sh"
TEST_ROOT="/tmp/mervlan_tmp/selftest.installer-webui-alias.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_function() {
    _source="$1" _name="$2" _dest="$3"
    awk -v name="$_name" '
        $0 ~ "^" name "\\(\\) \\{" { emit=1 }
        emit { print }
        emit && /^}/ { exit }
    ' "$_source" > "$_dest" || return 1
    [ -s "$_dest" ]
}

HELPERS="$TEST_ROOT/helpers.sh"
: > "$HELPERS"
for helper in \
    install_path_present install_path_chain_safe \
    install_external_webui_root_validate install_external_parent_safe \
    install_external_capture_error install_external_copy_object \
    install_external_capture_object install_external_capture_metadata \
    install_external_capture_projection install_external_capture_webui_page \
    install_external_cleanup_projection
do
    extract_function "$INSTALL" "$helper" "$TEST_ROOT/$helper.sh" || fail "extract $helper"
    cat "$TEST_ROOT/$helper.sh" >> "$HELPERS"
done

if TEST_ROOT="$TEST_ROOT" HELPERS="$HELPERS" sh -c '
    set -eu
    CASE="$TEST_ROOT/merlin-layout"
    LOGICAL="$CASE/www/user"
    PHYSICAL="$CASE/tmp/var/wwwext"
    RUNTIME="$CASE/runtime"
    MENU_TMP="$CASE/tmp/menuTree.js"
    MENU_TARGET="$CASE/www/require/modules/menuTree.js"
    SERVICE_EVENT="$CASE/hooks/service-event"
    SERVICES_START="$CASE/hooks/services-start"
    mkdir -p "$PHYSICAL/mervlan" "$RUNTIME" "${MENU_TARGET%/*}" "${SERVICE_EVENT%/*}" || exit 1
    ln -s "$PHYSICAL" "$LOGICAL" || exit 2
    printf old-public > "$PHYSICAL/mervlan/index.html"
    printf old-page > "$PHYSICAL/user1.asp"
    printf old-menu > "$MENU_TMP"
    printf old-target > "$MENU_TARGET"
    printf old-service-event > "$SERVICE_EVENT"
    printf old-services-start > "$SERVICES_START"
    printf "mervlan_page user1.asp\nmervlan_state enabled\nmervlan_version v-old\n" > "$CASE/metadata"

    TEST_RUN=1
    MERV_INSTALL_TEST_CANONICAL_WWW_ROOT="$LOGICAL"
    MERV_INSTALL_TEST_CANONICAL_WWW_TARGET="$PHYSICAL"
    MERV_INSTALL_WWW_USER_ROOT="$LOGICAL"
    INSTALL_EXTERNAL_WWW_ROOT="$LOGICAL"
    INSTALL_EXTERNAL_MENU_TMP="$MENU_TMP"
    INSTALL_EXTERNAL_MENU_TARGET="$MENU_TARGET"
    INSTALL_EXTERNAL_SERVICE_EVENT="$SERVICE_EVENT"
    INSTALL_EXTERNAL_SERVICES_START="$SERVICES_START"
    TMP_DIR="$RUNTIME"
    INSTALL_EXTERNAL_PRESERVE_DIR=""
    INSTALL_EXTERNAL_CAPTURED=0
    INSTALL_EXTERNAL_RESTORED=0
    INSTALL_EXTERNAL_INCOMPLETE=0
    INSTALL_EXTERNAL_MENU_BOUND=0
    INSTALL_EXTERNAL_PAGE=""
    INSTALL_EXTERNAL_PAGE_CAPTURED=0
    INSTALL_EXTERNAL_NODE_ATTEMPTED=0
    . "$HELPERS" || exit 3
    install_external_owner_current() { return 0; }
    am_settings_get() { awk -v key="$1" "\$1 == key { print \$2; exit }" "$CASE/metadata"; }

    # Retire successful real captures with the production cleanup helper, then
    # reset the remaining transaction state. Each scenario starts with no
    # preserve directory or capture evidence from a previous scenario.
    fixture_reset_capture() {
        if [ "${INSTALL_EXTERNAL_CAPTURED:-0}" = 1 ]; then
            install_external_cleanup_projection || return 1
        fi
        [ "${INSTALL_EXTERNAL_CAPTURED:-0}" = 0 ] || return 1
        [ -z "${INSTALL_EXTERNAL_PRESERVE_DIR:-}" ] || return 1
        INSTALL_EXTERNAL_CAPTURED=0
        INSTALL_EXTERNAL_RESTORED=0
        INSTALL_EXTERNAL_INCOMPLETE=0
        INSTALL_EXTERNAL_PAGE=""
        INSTALL_EXTERNAL_PAGE_CAPTURED=0
        INSTALL_EXTERNAL_MENU_BOUND=0
        return 0
    }

    # Every negative scenario must reach its explicit capture failure category,
    # never a stale preserve-directory collision or prior fixture state.
    fixture_capture_rejected() {
        _fixture_output="$1" _fixture_reason="$2"
        fixture_reset_capture || return 1
        if install_external_capture_projection >"$_fixture_output" 2>&1; then
            return 1
        fi
        grep -Fq "$_fixture_reason" "$_fixture_output" || return 1
        ! grep -Fq "preserve-directory collision" "$_fixture_output" || return 1
        fixture_reset_capture
    }

    # Canonical firmware alias is accepted through the actual capture helper.
    fixture_reset_capture || exit 9
    install_external_capture_projection || exit 10
    [ "$INSTALL_EXTERNAL_WWW_PHYSICAL_ROOT" = "$PHYSICAL" ] || exit 11
    [ "$(sed -n "1p" "$INSTALL_EXTERNAL_PRESERVE_DIR/public.state")" = present ] || exit 12
    fixture_reset_capture || exit 13

    # Model the post-uninstall projection state and exercise the real target
    # installer capture helpers. This fixture does not invoke uninstall.sh.
    rm -rf "$LOGICAL/mervlan"
    rm -f "$LOGICAL/user1.asp" "$SERVICE_EVENT" "$SERVICES_START"
    fixture_reset_capture || exit 19
    install_external_capture_projection || exit 20
    install_external_capture_webui_page user1.asp || exit 21
    [ "$(sed -n "1p" "$INSTALL_EXTERNAL_PRESERVE_DIR/public.state")" = absent ] || exit 22
    [ "$(sed -n "1p" "$INSTALL_EXTERNAL_PRESERVE_DIR/page.state")" = absent ] || exit 23
    [ "$(sed -n "1p" "$INSTALL_EXTERNAL_PRESERVE_DIR/service_event.state")" = absent ] || exit 24
    [ "$(sed -n "1p" "$INSTALL_EXTERNAL_PRESERVE_DIR/services_start.state")" = absent ] || exit 25
    fixture_reset_capture || exit 26

    # An ordinary override root remains subject to the unmodified strict path
    # checks and is accepted only as a real directory.
    SAFE="$CASE/safe-root"
    mkdir -p "$SAFE" || exit 30
    install_external_webui_root_validate "$SAFE" || exit 31
    [ "$INSTALL_EXTERNAL_WWW_PHYSICAL_ROOT" = "$SAFE" ] || exit 32
    OVERRIDE_LINK="$CASE/override-symlink"
    ln -s "$SAFE" "$OVERRIDE_LINK" || exit 33
    MERV_INSTALL_WWW_USER_ROOT="$OVERRIDE_LINK"
    INSTALL_EXTERNAL_WWW_ROOT="$OVERRIDE_LINK"
    fixture_capture_rejected "$CASE/override.out" "invalid WebUI root mapping" || exit 34
    MERV_INSTALL_WWW_USER_ROOT="$LOGICAL"
    INSTALL_EXTERNAL_WWW_ROOT="$LOGICAL"

    # Only the exact canonical target is accepted for the canonical logical
    # root. Malicious and unrelated targets fail before object capture.
    rm "$LOGICAL"
    mkdir -p "$CASE/tmp/evil" "$CASE/unrelated" || exit 40
    ln -s "$CASE/tmp/evil" "$LOGICAL" || exit 41
    fixture_capture_rejected "$CASE/evil.out" "invalid WebUI root mapping" || exit 42
    rm "$LOGICAL"
    ln -s "$CASE/unrelated" "$LOGICAL" || exit 44
    fixture_capture_rejected "$CASE/unrelated.out" "invalid WebUI root mapping" || exit 45

    # Restore the canonical alias, then prove a nested child symlink remains
    # blocked by the normal object-type checks.
    rm "$LOGICAL"
    ln -s "$PHYSICAL" "$LOGICAL" || exit 50
    mkdir -p "$CASE/nested-evil" || exit 51
    ln -s "$CASE/nested-evil" "$PHYSICAL/mervlan" || exit 52
    fixture_capture_rejected "$CASE/nested.out" "public projection capture" || exit 53
    fixture_reset_capture || exit 54
'; then
    pass 'canonical Merlin alias and modeled post-uninstall projection capture'
    pass 'invalid alias targets, override symlink, and nested object rejected'
else
    fail 'Merlin WebUI alias regression fixture'
fi

printf 'INSTALLER_MERLIN_WEBUI_MAPPING_OK\n'
