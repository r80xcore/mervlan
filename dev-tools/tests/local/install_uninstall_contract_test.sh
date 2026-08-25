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
grep -Fq '3) Custom branch (advanced)' "$INSTALL" || fail 'full installer custom-branch option missing'
grep -Fq 'prompt_custom_install_branch && return 0' "$INSTALL" || fail 'full installer custom-branch selection missing'
grep -Fq 'SOURCE_REF="refs/heads/$BRANCH"' "$INSTALL" || fail 'custom installer branch does not resolve to an explicit head ref'
grep -Fq 'am_settings_set mervlan_version "$MERVLAN_VERSION"' "$INSTALL" || fail 'installer MerVLAN version metadata write missing'
grep -Fq 'metadata version verification' "$INSTALL" || fail 'installer MerVLAN version metadata verification missing'
grep -Fq 'install_bootstrap_full_fresh_context' "$INSTALL" || fail 'fresh bootstrap admission helper missing'
grep -Fq 'Fresh bootstrap detected; normal maintenance ownership begins after the package is installed' "$INSTALL" || fail 'fresh bootstrap admission missing'
grep -Fq 'Raw GitHub URLs use the branch name directly' "$MERV_BASE/docs/HELP.md" || fail 'custom bootstrap raw-url guidance missing'
grep -Fq 'confirm_full_uninstall || exit 0' "$UNINSTALL" || fail 'full uninstall confirmation missing'
grep -Fq 'Also permanently delete retained MerVLAN update/manual backups?' "$UNINSTALL" || fail 'full uninstall backup-deletion prompt missing'
grep -Fq 'mervlan_metadata_remove_all' "$UNINSTALL" || fail 'precise MerVLAN metadata cleanup missing'
grep -Fq -- '--delete-backups requires explicit full-uninstall --yes confirmation' "$UNINSTALL" || fail 'full uninstall automation requires explicit confirmation'

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

# Exercise the custom-branch prompt and resolver with an isolated curl stub.
extract_function() {
  awk -v name="$2" '
    $0 ~ "^" name "\\(\\) \\{" { emit=1 }
    emit {
      print
      opens=gsub(/\{/, "{")
      closes=gsub(/\}/, "}")
      depth+=opens-closes
      if (depth == 0) exit
    }
  ' "$1" > "$3" || return 1
  [ -s "$3" ]
}
extract_function "$INSTALL" install_custom_branch_name_valid "$TEST_ROOT/custom-helper.sh" || fail 'custom branch validator extraction'
extract_function "$INSTALL" prompt_custom_install_branch "$TEST_ROOT/custom-prompt.sh" || fail 'custom branch prompt extraction'
extract_function "$INSTALL" resolve_download_source "$TEST_ROOT/custom-resolve.sh" || fail 'custom branch resolver extraction'
cat "$TEST_ROOT/custom-prompt.sh" "$TEST_ROOT/custom-resolve.sh" >> "$TEST_ROOT/custom-helper.sh" || fail 'custom helper assembly'
printf '%s\n' '#!/bin/sh' 'out=""' 'while [ "$#" -gt 0 ]; do' '  case "$1" in -o) shift; out="$1" ;; esac' '  shift' 'done' '[ -n "$out" ] || exit 1' "printf 'mervlan v0.53.28-dev\n' > \"\$out\"" > "$TEST_ROOT/fake-curl.sh"
chmod 700 "$TEST_ROOT/fake-curl.sh"
if printf 'bad..branch\npre_v0.53.28-dev\n' | TEST_ROOT="$TEST_ROOT" sh -c '
  merv_cmd() { printf "%s\n" "$TEST_ROOT/fake-curl.sh"; }
  . "$TEST_ROOT/custom-helper.sh" || exit 1
  TMP_DIR="$TEST_ROOT/stage"; mkdir -p "$TMP_DIR" || exit 2
  BRANCH=main; RESULT_SOURCE=""; SOURCE_DESCRIPTION=""
  prompt_custom_install_branch >/dev/null || exit 3
  [ "$BRANCH" = pre_v0.53.28-dev ] || exit 4
  resolve_download_source || exit 5
  printf "%s|%s\n" "$SOURCE_REF" "$GITHUB_URL" > "$TEST_ROOT/custom-result"
'; then
  [ "$(cat "$TEST_ROOT/custom-result")" = 'refs/heads/pre_v0.53.28-dev|https://codeload.github.com/r80xcore/mervlan/tar.gz/refs/heads/pre_v0.53.28-dev' ] || fail 'custom installer branch resolved incorrectly'
else
  fail 'custom installer branch prompt fixture failed'
fi

# The official online bootstrap intentionally starts with only install.sh.  It
# must admit that exact fresh shape while rejecting an incomplete runtime tree
# or any existing maintenance state, where normal owner libraries are required.
extract_function "$INSTALL" install_bootstrap_full_fresh_context "$TEST_ROOT/bootstrap-helper.sh" || fail 'bootstrap helper extraction'
if TEST_ROOT="$TEST_ROOT" sh -c '
  MODE=full; TEST_RUN=0
  MERV_BASE="$TEST_ROOT/bootstrap"
  TMP_DIR="$TEST_ROOT/runtime"
  MERV_STATE_ROOT="$TEST_ROOT/state"
  mkdir -p "$MERV_BASE" || exit 1
  : > "$MERV_BASE/install.sh" || exit 2
  . "$TEST_ROOT/bootstrap-helper.sh" || exit 3
  install_bootstrap_full_fresh_context || exit 4
  mkdir -p "$MERV_BASE/settings" || exit 5
  if install_bootstrap_full_fresh_context; then exit 6; fi
  rmdir "$MERV_BASE/settings" || exit 7
  mkdir -p "$TMP_DIR/locks" || exit 8
  : > "$TMP_DIR/locks/mervlan_maintenance.lock" || exit 9
  if install_bootstrap_full_fresh_context; then exit 10; fi
'; then :; else fail 'fresh bootstrap admission fixture failed'; fi

# Full uninstall confirmation must be explicit, offer backup deletion, and
# remove only the MerVLAN/legacy metadata keys from Merlin's flat settings API.
extract_function "$UNINSTALL" confirm_full_uninstall "$TEST_ROOT/uninstall-helper.sh" || fail 'uninstall confirmation extraction'
extract_function "$UNINSTALL" mervlan_metadata_remove_all "$TEST_ROOT/metadata-helper.sh" || fail 'metadata cleanup extraction'
if printf 'UNINSTALL\ny\n' | TEST_ROOT="$TEST_ROOT" sh -c '
  . "$TEST_ROOT/uninstall-helper.sh" || exit 1
  ACTION=full; FULL_DELETE_BACKUPS=0
  confirm_full_uninstall >/dev/null || exit 2
  [ "$FULL_DELETE_BACKUPS" = 1 ]
'; then :; else fail 'full uninstall confirmation fixture failed'; fi
if TEST_ROOT="$TEST_ROOT" sh -c '
  . "$TEST_ROOT/uninstall-helper.sh" || exit 1
  ACTION=full; FULL_DELETE_BACKUPS=0
  FULL_UNINSTALL_ASSUME_YES=1; FULL_DELETE_BACKUPS_REQUESTED=1
  confirm_full_uninstall >/dev/null || exit 2
  [ "$FULL_DELETE_BACKUPS" = 1 ]
'; then :; else fail 'automated full uninstall confirmation fixture failed'; fi
printf 'other_addon_state enabled\nmervlan_page user1.asp\nmervlan_state enabled\nmervlan_version v0\nmerlin_vlan_manager_page user2.asp\nother_addon_version v9\n' > "$TEST_ROOT/custom_settings.txt"
if TEST_ROOT="$TEST_ROOT" sh -c '
  . "$TEST_ROOT/metadata-helper.sh" || exit 1
  _am_settings_path="$TEST_ROOT/custom_settings.txt"
  mervlan_metadata_remove_all
'; then
  grep -Fqx 'other_addon_state enabled' "$TEST_ROOT/custom_settings.txt" || fail 'metadata cleanup removed another addon state'
  grep -Fqx 'other_addon_version v9' "$TEST_ROOT/custom_settings.txt" || fail 'metadata cleanup removed another addon version'
  ! grep -Eq '^(mervlan_|merlin_vlan_manager_)' "$TEST_ROOT/custom_settings.txt" || fail 'MerVLAN metadata remained after cleanup'
else
  fail 'MerVLAN metadata cleanup fixture failed'
fi

printf 'INSTALL_UNINSTALL_CONTRACT_OK\n'
