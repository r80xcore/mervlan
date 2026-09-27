#!/bin/sh
# Contract coverage for exact Full Uninstall residual cleanup boundaries.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mervlan-uninstall-residue.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_function() {
  _fur_src="$1"
  _fur_name="$2"
  _fur_out="$3"
  awk -v name="$_fur_name" '
    function brace_delta(line, i, c, n) {
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") n++
        else if (c == "}") n--
      }
      return n
    }
    !inside && $0 ~ "^[[:space:]]*" name "[[:space:]]*\\(\\)[[:space:]]*\\{" {
      inside = 1
    }
    inside {
      print
      depth += brace_delta($0)
      if (depth == 0) exit
    }
  ' "$_fur_src" >"$_fur_out" || return 1
  [ -s "$_fur_out" ]
}

LEGACY_FN="$TEST_ROOT/legacy.sh"
RECOVERY_FN="$TEST_ROOT/recovery.sh"
extract_function "$BASE_DIR/uninstall.sh" uninstall_remove_legacy_persistent_page "$LEGACY_FN" ||
  fail 'legacy cleanup helper extraction'
extract_function "$BASE_DIR/uninstall.sh" uninstall_remove_empty_recovery_tmp "$RECOVERY_FN" ||
  fail 'recovery cleanup helper extraction'

ACTION=full
. "$LEGACY_FN" || fail 'legacy cleanup helper load'
. "$RECOVERY_FN" || fail 'recovery cleanup helper load'

mkdir -p "$TEST_ROOT/addons" || fail 'fixture addon directory'
printf 'legacy-page\n' >"$TEST_ROOT/addons/mervlan.asp"
printf 'unrelated-addon\n' >"$TEST_ROOT/addons/other-addon"
uninstall_remove_legacy_persistent_page "$TEST_ROOT/addons/mervlan.asp" ||
  fail 'exact legacy page cleanup failed'
[ ! -e "$TEST_ROOT/addons/mervlan.asp" ] || fail 'exact legacy page remained'
[ -f "$TEST_ROOT/addons/other-addon" ] || fail 'unrelated addon file was removed'
pass 'exact legacy page cleanup preserves unrelated addon state'

ln -s other-addon "$TEST_ROOT/addons/mervlan.asp" || fail 'legacy symlink fixture'
uninstall_remove_legacy_persistent_page "$TEST_ROOT/addons/mervlan.asp" ||
  fail 'legacy symlink handling failed'
[ -L "$TEST_ROOT/addons/mervlan.asp" ] || fail 'legacy symlink was removed'
rm -f "$TEST_ROOT/addons/mervlan.asp"
mkdir "$TEST_ROOT/addons/mervlan.asp" || fail 'legacy directory fixture'
uninstall_remove_legacy_persistent_page "$TEST_ROOT/addons/mervlan.asp" ||
  fail 'legacy directory handling failed'
[ -d "$TEST_ROOT/addons/mervlan.asp" ] || fail 'legacy directory was removed'
pass 'legacy cleanup refuses symlink and directory obstructions'

mkdir "$TEST_ROOT/recovery-empty" || fail 'empty recovery fixture'
uninstall_remove_empty_recovery_tmp "$TEST_ROOT/recovery-empty" ||
  fail 'empty recovery root cleanup failed'
[ ! -e "$TEST_ROOT/recovery-empty" ] || fail 'empty recovery root remained'
uninstall_remove_empty_recovery_tmp "$TEST_ROOT/recovery-empty" ||
  fail 'empty recovery cleanup was not idempotent'
pass 'empty recovery root cleanup is exact and idempotent'

mkdir -p "$TEST_ROOT/recovery-retained/restore.123/stage" ||
  fail 'retained recovery fixture'
printf 'rollback-evidence\n' >"$TEST_ROOT/recovery-retained/restore.123/stage/marker"
uninstall_remove_empty_recovery_tmp "$TEST_ROOT/recovery-retained" ||
  fail 'non-empty recovery root handling failed'
[ -f "$TEST_ROOT/recovery-retained/restore.123/stage/marker" ] ||
  fail 'non-empty recovery evidence was removed'
pass 'non-empty recovery evidence is preserved'

# This fixture follows the production repair ownership contract. Full
# Uninstall helpers may remove the separate empty recovery parent, but never
# traverse or wildcard-delete a retained repair workspace.
REPAIR="$TEST_ROOT/mervlan_repair.1790383788.22770.0"
mkdir -p "$REPAIR/protected"
printf 'mervlan-repair-workspace-v2\n' >"$REPAIR/.owner"
printf '%s\n' \
  'format=2' \
  'run_dir=/tmp/mervlan_repair.1790383788.22770.0' \
  'source_root=/tmp/mervlan_repair.1790383788.22770.0/extract/mervlan-pre_v0.53.29-dev' \
  'snapshot_root=mervlan-pre_v0.53.29-dev' \
  'archive=/tmp/mervlan_repair.1790383788.22770.0/snapshot.tar.gz' \
  'protected=/tmp/mervlan_repair.1790383788.22770.0/protected' >"$REPAIR/.handoff"
: >"$REPAIR/protected/index"
: >"$REPAIR/snapshot.tar.gz"
mkdir "$TEST_ROOT/recovery-for-repair" || fail 'repair boundary fixture'
uninstall_remove_empty_recovery_tmp "$TEST_ROOT/recovery-for-repair" ||
  fail 'repair boundary cleanup failed'
[ -f "$REPAIR/.owner" ] && [ -f "$REPAIR/.handoff" ] &&
  [ -f "$REPAIR/protected/index" ] && [ -f "$REPAIR/snapshot.tar.gz" ] ||
  fail 'retained repair workspace was removed'
pass 'valid retained repair evidence survives Full Uninstall cleanup helpers'

# Source guards prevent this narrow contract from regressing into broad
# pathname deletion or accidental cleanup of retained evidence.
grep -Fq 'if [ -f /jffs/addons/mervlan.asp ] && [ ! -L /jffs/addons/mervlan.asp ]; then' \
  "$BASE_DIR/uninstall.sh" || fail 'node legacy cleanup is not exact and type-checked'
grep -Fq 'uninstall_remove_empty_recovery_tmp' "$BASE_DIR/uninstall.sh" ||
  fail 'empty recovery cleanup is not wired to Full Uninstall'
! grep -Eq 'rm -rf /tmp/mervlan_\*|rm -rf /tmp/\*mervlan|rm -rf /tmp/mervlan\*' \
  "$BASE_DIR/uninstall.sh" || fail 'broad temporary MerVLAN cleanup was introduced'
! grep -Fq 'mervlan_repair.*' "$BASE_DIR/uninstall.sh" ||
  fail 'Full Uninstall gained repair-workspace deletion knowledge'
pass 'production cleanup remains ownership-specific with no wildcard repair deletion'

printf '%s\n' 'FULL_UNINSTALL_RESIDUE_CONTRACT_OK'
