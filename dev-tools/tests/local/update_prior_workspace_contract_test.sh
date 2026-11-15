#!/bin/sh
# Prior Update workspaces are retained until inspected; this test executes the
# production classifier under Dash and BusyBox ash with isolated tmp roots.
set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
UPDATE="$BASE_DIR/functions/update_mervlan.sh"
TEST_ROOT="${TMPDIR:-/tmp}/mervlan_tmp/selftest.update-prior-workspace.$$"
umask 077
mkdir -p "${TEST_ROOT%/*}" || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

awk '
  index($0, "BEGIN MERVLAN_UPDATE_PRIOR_WORKSPACE_CONTRACT") { copying=1; next }
  index($0, "END MERVLAN_UPDATE_PRIOR_WORKSPACE_CONTRACT") { copying=0; exit }
  copying { print }
' "$UPDATE" >"$TEST_ROOT/classifier.fn" || fail 'could not extract Update workspace classifier'
[ -s "$TEST_ROOT/classifier.fn" ] || fail 'Update workspace classifier is empty'

cat >"$TEST_ROOT/fixture.sh" <<'FIXTURE'
#!/bin/sh
set -u
TMP_DIR=${MERV_TEST_TMP_DIR:?}
UPDATE_PRESERVE_TMP=0
UPDATE_PRIOR_TMP_PATH=
UPDATE_PRIOR_TMP_SIZE=unknown
update_path_size_kb() { du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'; }
UPDATE_CLASSIFIER_SOURCE
case "$MERV_TEST_MODE" in
  clear)
    update_prior_tmp_workspaces_clear || exit 10
    [ "$UPDATE_PRESERVE_TMP" = 0 ] || exit 11
    ;;
  directory)
    update_prior_tmp_workspaces_clear && exit 20
    [ "$UPDATE_PRESERVE_TMP" = 1 ] || exit 21
    [ "$UPDATE_PRIOR_TMP_PATH" = "$MERV_TEST_TMP_DIR/updates.foreign" ] || exit 22
    case "$UPDATE_PRIOR_TMP_SIZE" in ''|*[!0-9]*) exit 23 ;; esac
    [ -f "$UPDATE_PRIOR_TMP_PATH/sentinel" ] || exit 24
    ;;
  workspace-link)
    update_prior_tmp_workspaces_clear && exit 30
    [ "$UPDATE_PRESERVE_TMP" = 1 ] || exit 31
    [ "$UPDATE_PRIOR_TMP_PATH" = "$MERV_TEST_TMP_DIR/updates.foreign-link" ] || exit 32
    [ "$UPDATE_PRIOR_TMP_SIZE" = unknown ] || exit 33
    [ -L "$UPDATE_PRIOR_TMP_PATH" ] || exit 34
    ;;
  root-link)
    update_prior_tmp_workspaces_clear && exit 40
    [ "$UPDATE_PRESERVE_TMP" = 1 ] || exit 41
    [ "$UPDATE_PRIOR_TMP_PATH" = "$MERV_TEST_TMP_DIR" ] || exit 42
    [ -L "$UPDATE_PRIOR_TMP_PATH" ] || exit 43
    ;;
  *) exit 50 ;;
esac
FIXTURE

assemble_fixture() {
  _af_source=$1 _af_output=$2
  while IFS= read -r _af_line || [ -n "$_af_line" ]; do
    case "$_af_line" in
      UPDATE_CLASSIFIER_SOURCE) cat "$TEST_ROOT/classifier.fn" || return 1 ;;
      *) printf '%s\n' "$_af_line" ;;
    esac
  done <"$_af_source" >"$_af_output"
}

assemble_fixture "$TEST_ROOT/fixture.sh" "$TEST_ROOT/fixture-ready.sh" || fail 'fixture assembly'

run_case() {
  _rc_shell=$1 _rc_mode=$2 _rc_tmp=$3
  case "$_rc_shell" in
    dash)
      MERV_TEST_MODE="$_rc_mode" MERV_TEST_TMP_DIR="$_rc_tmp" /bin/sh "$TEST_ROOT/fixture-ready.sh" || \
        fail "Dash rejected $_rc_mode fixture"
      ;;
    busybox)
      MERV_TEST_MODE="$_rc_mode" MERV_TEST_TMP_DIR="$_rc_tmp" busybox ash "$TEST_ROOT/fixture-ready.sh" || \
        fail "BusyBox ash rejected $_rc_mode fixture"
      ;;
  esac
}

for _shell in dash busybox; do
  _root="$TEST_ROOT/$_shell"
  mkdir -p "$_root/empty" "$_root/with-directory/updates.foreign" \
    "$_root/with-link" "$_root/actual-root"
  printf 'preserve me\n' >"$_root/with-directory/updates.foreign/sentinel"
  printf 'foreign target\n' >"$_root/foreign-target"
  ln -s "$_root/foreign-target" "$_root/with-link/updates.foreign-link"
  ln -s "$_root/actual-root" "$_root/tmp-root-link"

  run_case "$_shell" clear "$_root/empty"
  run_case "$_shell" directory "$_root/with-directory"
  run_case "$_shell" workspace-link "$_root/with-link"
  run_case "$_shell" root-link "$_root/tmp-root-link"

  [ -f "$_root/with-directory/updates.foreign/sentinel" ] || fail "$_shell removed foreign Update evidence"
  [ -L "$_root/with-link/updates.foreign-link" ] || fail "$_shell removed a foreign workspace symlink"
done

pass 'Update proceeds with a clean tmp root and preserves prior directories, workspace symlinks, and a symlinked root under Dash and BusyBox ash'
