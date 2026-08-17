#!/bin/sh
# Static contract for release installer/uninstaller recovery paths.
# This test does not mutate a router.
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
INSTALL="$MERV_BASE/install.sh"
UNINSTALL="$MERV_BASE/uninstall.sh"
BOOT="$MERV_BASE/functions/mervlan_boot.sh"
OWNER="$MERV_BASE/settings/lib_owner_lock.sh"
UPDATE_STATE="$MERV_BASE/settings/lib_update_state.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Old regular lock files must not be mistaken for an absent directory and spin.
grep -Fq '[ -d "$_mols_lock" ] || { printf '"'"'unknown'"'"'; return 0; }' "$OWNER" || fail 'owner lock obstruction is not fail-closed unknown'
grep -Fq 'incomplete-expired|incomplete-unknown|malformed|unknown|*)' "$OWNER" || fail 'owner acquire does not fail closed on unknown obstruction'

# Both direct local hook paths reconcile the known legacy lock format.
[ "$(grep -Fc 'reconcile_legacy_boot_file_locks' "$BOOT")" -ge 4 ] || fail 'boot legacy reconciliation is not wired to setupenable/setupdisable/nodeenable'
grep -Fq 'Refusing setupenable while legacy boot-file lock state is ambiguous' "$BOOT" || fail 'setupenable legacy gate missing'
grep -Fq 'Refusing setupdisable while legacy boot-file lock state is ambiguous' "$BOOT" || fail 'setupdisable legacy gate missing'
grep -Fq 'Service-event injection remains after setupdisable' "$BOOT" || fail 'setupdisable verification missing'

# Uninstall gets a narrow authenticated maintenance child grant and refuses to
# erase the source tree after failed local hook removal.
grep -Fq 'merv_maintenance_direct_export_uninstall_context' "$UPDATE_STATE" || fail 'uninstall delegation helper missing'
grep -Fq 'merv_maintenance_direct_export_uninstall_context' "$UNINSTALL" || fail 'uninstall does not export maintenance delegation'
grep -Fq 'UNINSTALL_HOOKS_OK=0' "$UNINSTALL" || fail 'uninstall hook failure state missing'
grep -Fq 'addon files were retained' "$UNINSTALL" || fail 'uninstall does not preserve source on hook failure'
! grep -Fq "xargs -r -n1 basename | head -n1" "$UNINSTALL" || fail 'SIGPIPE-prone ASP discovery pipeline remains'

# Tarball metadata is captured per menu item and loaded from the selected item.
grep -Fq 'TARBALL_BRANCH_$idx' "$INSTALL" || fail 'per-tarball branch metadata missing'
grep -Fq 'eval "BRANCH=\${TARBALL_BRANCH_$sel}"' "$INSTALL" || fail 'selected tarball branch is not selected indirectly'
grep -Fq 'topname="$(tar -tzf' "$INSTALL" || fail 'archive top-level branch discovery missing'
grep -Fq 'install-hooks.$$' "$INSTALL" || fail 'installer hook diagnostics capture missing'
! grep -Fq '*/changelog.txt' "$INSTALL" || fail 'wildcard member-to-stdout tar extraction remains'

# Exercise the selected-item metadata rather than only inspecting source text.
# Reverse sort lists main before dev; selecting item 1 must therefore resolve
# main even though the loop's final metadata value is dev.
TEST_ROOT="/tmp/mervlan_tmp/selftest.install-uninstall.$$"
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15
mkdir -p "$TEST_ROOT/stage" "$TEST_ROOT/src/mervlan-main" "$TEST_ROOT/src/mervlan-dev" || fail 'tarball fixture mkdir'
printf 'mervlan v1\n' > "$TEST_ROOT/src/mervlan-main/changelog.txt"
printf 'mervlan v2\n' > "$TEST_ROOT/src/mervlan-dev/changelog.txt"
tar -czf "$TEST_ROOT/stage/mervlan-main-v1.tar.gz" -C "$TEST_ROOT/src" mervlan-main || fail 'main fixture archive'
tar -czf "$TEST_ROOT/stage/mervlan-dev-v2.tar.gz" -C "$TEST_ROOT/src" mervlan-dev || fail 'dev fixture archive'
sed -n '/^select_and_validate_tarball() {/,/^}/p' "$INSTALL" > "$TEST_ROOT/select.sh" || fail 'extract tarball selector'
[ -s "$TEST_ROOT/select.sh" ] || fail 'tarball selector extraction empty'
if printf '1\ny\n' | TEST_ROOT="$TEST_ROOT" sh -c '
  . "$TEST_ROOT/select.sh" || exit 1
  select_and_validate_tarball "$TEST_ROOT/stage" >/dev/null || exit 2
  printf "%s|%s\n" "$BRANCH" "${SELECTED_TARBALL##*/}" > "$TEST_ROOT/result"
'; then
  [ "$(cat "$TEST_ROOT/result")" = 'main|mervlan-main-v1.tar.gz' ] || fail 'tarball selection inherited wrong loop metadata'
else
  fail 'tarball selection fixture failed'
fi

# A retained stable tag is named as the main channel even though GitHub's
# codeload top directory is the tag itself. Preserve that public channel.
mkdir -p "$TEST_ROOT/stage-tag" "$TEST_ROOT/src/mervlan-v3.0" || fail 'stable tag fixture mkdir'
printf 'mervlan v3.0\n' > "$TEST_ROOT/src/mervlan-v3.0/changelog.txt"
tar -czf "$TEST_ROOT/stage-tag/mervlan-main-v3.0.tar.gz" -C "$TEST_ROOT/src" mervlan-v3.0 || fail 'stable tag fixture archive'
if printf '1\ny\n' | TEST_ROOT="$TEST_ROOT" sh -c '
  . "$TEST_ROOT/select.sh" || exit 1
  select_and_validate_tarball "$TEST_ROOT/stage-tag" >/dev/null || exit 2
  printf "%s|%s\n" "$BRANCH" "${SELECTED_TARBALL##*/}" > "$TEST_ROOT/tag-result"
'; then
  [ "$(cat "$TEST_ROOT/tag-result")" = 'main|mervlan-main-v3.0.tar.gz' ] || fail 'stable tag lost main channel metadata'
else
  fail 'stable tag selection fixture failed'
fi

printf 'INSTALL_UNINSTALL_CONTRACT_OK\n'
