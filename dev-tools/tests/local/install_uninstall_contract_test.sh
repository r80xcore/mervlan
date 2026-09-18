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

# Owner state probes must not follow obstructions: only a non-following absence
# probe whose parent is readable/searchable may become authoritative absence;
# regular files, dangling links, and unreadable parents remain unknown.
grep -Fq 'merv_owner_lock_absent_authoritative() {' "$OWNER" || fail 'owner authoritative absence helper missing'
grep -Fq 'ls -ld "$_molaa_lock" >/dev/null 2>&1 && return 1' "$OWNER" || fail 'owner absence probe follows an obstruction'
grep -Fq '[ ! -L "$_molaa_parent" ] && [ -d "$_molaa_parent" ]' "$OWNER" || fail 'owner absence probe lacks parent authority check'
grep -Fq 'if ! ls -ld "$_mols_lock" >/dev/null 2>&1; then' "$OWNER" || fail 'owner state lacks non-following initial probe'
grep -Fq 'if [ -L "$_mols_lock" ] || [ ! -d "$_mols_lock" ]; then' "$OWNER" || fail 'owner state lacks obstruction classification'
grep -Fq 'merv_owner_lock_absent_authoritative "$_mols_lock"; then' "$OWNER" || fail 'owner state lacks authoritative absence reinspection'
grep -Fq 'merv_owner_lock_state_emit unknown' "$OWNER" || fail 'owner obstruction is not classified unknown'
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

# Tarball metadata is captured in one private, filename-safe menu file and
# loaded from the selected item without eval or shell-word splitting.
grep -Fq 'metadata="$staging_dir/.mervlan-tarball-menu.$$"' "$INSTALL" || fail 'tarball metadata file missing'
grep -Fq 'selected_branch=' "$INSTALL" || fail 'selected tarball branch metadata missing'
! grep -Fq 'eval ' "$INSTALL" || fail 'data-bearing tarball eval remains'
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
grep -Fq 'install_staged_handoff_adopt() {' "$INSTALL" || fail 'staged installer handoff admission helper missing'
grep -Fq 'install_staged_handoff_write() {' "$INSTALL" || fail 'staged installer handoff writer missing'
grep -Fq 'MERV_INSTALL_SCRIPT_PATH" = "$MERV_INSTALL_STAGED_ROOT/install.sh' "$INSTALL" || fail 'staged child does not bind its own installer path'
grep -Fq 'exec /bin/sh "$INSTALL_STAGED_ROOT/install.sh" "$MODE"' "$INSTALL" || fail 'parent does not execute staged installer'
! grep -Fq 'exec /bin/sh "$MERV_INSTALL_SCRIPT_PATH" "$MODE"' "$INSTALL" || fail 'parent can still re-exec detached installer'
grep -Fq 'archive_fingerprint=$_ishrv_fingerprint' "$INSTALL" || fail 'staged handoff does not bind archive fingerprint'
grep -Fq 'type md5sum >/dev/null 2>&1' "$INSTALL" || fail 'staged handoff md5sum digest fallback missing'
grep -Fq 'openssl dgst -md5' "$INSTALL" || fail 'staged handoff OpenSSL digest fallback missing'
! grep -Fq 'cksum "$_ihaf_archive"' "$INSTALL" || fail 'staged handoff still requires cksum'
grep -Fq 'raw.githubusercontent.com/r80xcore/mervlan/refs/heads/pre_v0.53.28-dev/install.sh' "$MERV_BASE/docs/HELP.md" || fail 'custom bootstrap raw-url guidance missing'
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
sed -n '/^validate_install_archive() {/,/^}/p' "$INSTALL" > "$TEST_ROOT/select.sh" || fail 'extract archive validator'
sed -n '/^select_and_validate_tarball() {/,/^}/p' "$INSTALL" >> "$TEST_ROOT/select.sh" || fail 'extract tarball selector'
[ -s "$TEST_ROOT/select.sh" ] || fail 'tarball selector extraction empty'
if printf '1\ny\n' | TEST_ROOT="$TEST_ROOT" sh -c '
  . "$TEST_ROOT/select.sh" || exit 1
  TMP_DIR="$TEST_ROOT"
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
  TMP_DIR="$TEST_ROOT"
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

# The official online and staged-offline bootstraps intentionally start with
# only install.sh. They must admit that exact fresh shape while rejecting an
# incomplete runtime tree or any existing maintenance state, where normal owner
# libraries are required.
extract_function "$INSTALL" install_bootstrap_full_fresh_context "$TEST_ROOT/bootstrap-helper.sh" || fail 'bootstrap helper extraction'
if TEST_ROOT="$TEST_ROOT" sh -c '
  MODE=full; TEST_RUN=0
  MERV_BASE="$TEST_ROOT/bootstrap"
  ACTIVE_MERV_BASE="$MERV_BASE"; ADDON_DIR="$TEST_ROOT"
  TMP_DIR="$TEST_ROOT/runtime"
  MERV_STATE_ROOT="$TEST_ROOT/state"
  mkdir -p "$MERV_BASE" || exit 1
  : > "$MERV_BASE/install.sh" || exit 2
  . "$TEST_ROOT/bootstrap-helper.sh" || exit 3
  install_path_present() { ls -ld "$1" >/dev/null 2>&1; }
  install_path_chain_safe() { case "$1" in /*) ;; *) return 1;; esac; [ ! -L "${1%/*}" ] && [ -d "${1%/*}" ]; }
  install_bootstrap_full_fresh_context || exit 4
  mkdir -p "$MERV_BASE/settings" || exit 5
  if install_bootstrap_full_fresh_context; then exit 6; fi
  rmdir "$MERV_BASE/settings" || exit 7
  mkdir -p "$TMP_DIR/locks" || exit 8
  : > "$TMP_DIR/locks/mervlan_maintenance.lock" || exit 9
  if install_bootstrap_full_fresh_context; then exit 10; fi
'; then :; else fail 'fresh bootstrap admission fixture failed'; fi

# Offline tarball mode has the same intentionally-empty runtime shape as a
# first online install. It must be admitted so the staged archive can provide
# the owner library needed by normal maintenance admission.
if TEST_ROOT="$TEST_ROOT" sh -c '
  MODE=tarball; TEST_RUN=0
  MERV_BASE="$TEST_ROOT/tarball-bootstrap"
  ACTIVE_MERV_BASE="$MERV_BASE"; ADDON_DIR="$TEST_ROOT"
  TMP_DIR="$TEST_ROOT/tarball-runtime"
  MERV_STATE_ROOT="$TEST_ROOT/tarball-state"
  mkdir -p "$MERV_BASE" "$TMP_DIR" || exit 1
  : > "$MERV_BASE/install.sh" || exit 2
  . "$TEST_ROOT/bootstrap-helper.sh" || exit 3
  install_path_present() { ls -ld "$1" >/dev/null 2>&1; }
  install_path_chain_safe() { case "$1" in /*) ;; *) return 1;; esac; [ ! -L "${1%/*}" ] && [ -d "${1%/*}" ]; }
  install_bootstrap_full_fresh_context || exit 4
  mkdir -p "$MERV_BASE/settings" || exit 5
  if install_bootstrap_full_fresh_context; then exit 6; fi
'; then :; else fail 'fresh offline tarball bootstrap admission fixture failed'; fi

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

# External projections are transactional evidence, not incidental cleanup.
for projection_contract in \
  install_external_capture_projection \
  install_external_capture_webui_page \
  install_external_restore_projection \
  install_external_cleanup_projection; do
  grep -Fq "$projection_contract" "$INSTALL" || fail "installer projection contract missing: $projection_contract"
done
grep -Fq 'external projection rollback incomplete' "$INSTALL" || fail 'installer incomplete-projection result missing'
grep -Fq 'INSTALL_EXTERNAL_NODE_ATTEMPTED=1' "$INSTALL" || fail 'installer node reconciliation marker missing'

EXTERNAL_HELPERS="$TEST_ROOT/external-helpers.sh"
: >"$EXTERNAL_HELPERS"
for helper in install_path_present install_path_chain_safe \
  install_external_owner_current install_external_parent_safe \
  install_external_copy_object install_external_remove_object \
  install_external_capture_object install_external_capture_metadata \
  install_external_capture_projection install_external_capture_webui_page \
  install_external_restore_object install_external_restore_metadata \
  install_external_restore_projection install_external_cleanup_projection; do
  extract_function "$INSTALL" "$helper" "$TEST_ROOT/$helper.sh" || fail "projection helper extraction: $helper"
  cat "$TEST_ROOT/$helper.sh" >>"$EXTERNAL_HELPERS"
done
if TEST_ROOT="$TEST_ROOT" EXTERNAL_HELPERS="$EXTERNAL_HELPERS" sh -c '
  CASE="$TEST_ROOT/projection"
  WWW="$CASE/www/user"
  mkdir -p "$WWW/mervlan" "$CASE/tmp" "$CASE/www/require/modules" "$CASE/hooks"
  printf old-public >"$WWW/mervlan/index.html"
  printf old-page >"$WWW/user1.asp"
  printf old-menu >"$CASE/tmp/menuTree.js"
  printf old-target >"$CASE/www/require/modules/menuTree.js"
  printf old-event >"$CASE/hooks/service-event"
  printf old-start >"$CASE/hooks/services-start"
  printf "mervlan_page user9.asp\nmervlan_state disabled\nmervlan_version v-old\n" >"$CASE/metadata"
  . "$EXTERNAL_HELPERS" || exit 1
  install_external_owner_current() { return 0; }
  am_settings_get() { awk -v key="$1" "\$1 == key { print \$2; exit }" "$CASE/metadata"; }
  am_settings_set() { sed -i "/^$1 /d" "$CASE/metadata"; printf "%s %s\n" "$1" "$2" >>"$CASE/metadata"; }
  TMP_DIR="$CASE/tmp"
  INSTALL_EXTERNAL_PRESERVE_DIR=""
  INSTALL_EXTERNAL_CAPTURED=0
  INSTALL_EXTERNAL_RESTORED=0
  INSTALL_EXTERNAL_INCOMPLETE=0
  INSTALL_EXTERNAL_MENU_BOUND=0
  INSTALL_EXTERNAL_PAGE=""
  INSTALL_EXTERNAL_PAGE_CAPTURED=0
  INSTALL_EXTERNAL_NODE_ATTEMPTED=0
  INSTALL_EXTERNAL_WWW_ROOT="$WWW"
  INSTALL_EXTERNAL_MENU_TMP="$CASE/tmp/menuTree.js"
  INSTALL_EXTERNAL_MENU_TARGET="$CASE/www/require/modules/menuTree.js"
  INSTALL_EXTERNAL_SERVICE_EVENT="$CASE/hooks/service-event"
  INSTALL_EXTERNAL_SERVICES_START="$CASE/hooks/services-start"
  install_external_capture_projection || exit 2
  install_external_capture_webui_page user1.asp || exit 3
  printf new-public >"$WWW/mervlan/index.html"
  printf new-page >"$WWW/user1.asp"
  printf new-menu >"$CASE/tmp/menuTree.js"
  printf new-target >"$CASE/www/require/modules/menuTree.js"
  printf new-event >"$CASE/hooks/service-event"
  printf new-start >"$CASE/hooks/services-start"
  am_settings_set mervlan_page user2.asp
  am_settings_set mervlan_state enabled
  am_settings_set mervlan_version v-new
  install_external_restore_projection || exit 4
  [ "$(cat "$WWW/mervlan/index.html")" = old-public ] || exit 5
  [ "$(cat "$WWW/user1.asp")" = old-page ] || exit 6
  [ "$(cat "$CASE/tmp/menuTree.js")" = old-menu ] || exit 7
  [ "$(cat "$CASE/www/require/modules/menuTree.js")" = old-target ] || exit 8
  [ "$(cat "$CASE/hooks/service-event")" = old-event ] || exit 9
  [ "$(cat "$CASE/hooks/services-start")" = old-start ] || exit 10
  [ "$(am_settings_get mervlan_page)" = user9.asp ] || exit 11
  [ "$(am_settings_get mervlan_state)" = disabled ] || exit 12
  [ "$(am_settings_get mervlan_version)" = v-old ] || exit 13
'; then :; else fail 'external projection capture/restore fixture failed'; fi
printf 'PASS: external WebUI/menu/metadata/hook rollback restores the pre-install projection\n'

printf 'INSTALL_UNINSTALL_CONTRACT_OK\n'
