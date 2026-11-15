#!/bin/sh
# Run the production EXIT-status wrapper under Dash and BusyBox ash.
set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
UPDATE="$BASE_DIR/functions/update_mervlan.sh"
TEST_ROOT="${TMPDIR:-/tmp}/mervlan_tmp/selftest.update-exit-status.$$"
umask 077
mkdir -p "${TEST_ROOT%/*}" || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

awk '
  index($0, "BEGIN MERVLAN_UPDATE_CLEANUP_EXIT_CONTRACT") { copying=1; next }
  index($0, "END MERVLAN_UPDATE_CLEANUP_EXIT_CONTRACT") { copying=0; exit }
  copying { print }
' "$UPDATE" >"$TEST_ROOT/exit-wrapper.fn" || fail 'could not extract the production EXIT wrapper'
[ -s "$TEST_ROOT/exit-wrapper.fn" ] || fail 'production EXIT wrapper is empty'

cat >"$TEST_ROOT/fixture.sh" <<'FIXTURE'
#!/bin/sh
_update_cleanup_failed=0
cleanup_tmp() {
  _update_cleanup_failed=$CLEANUP_FAIL
  return "${1:-0}"
}
EXIT_WRAPPER_SOURCE
trap update_cleanup_on_exit EXIT
exit "$PRIOR_STATUS"
FIXTURE

assemble_fixture() {
  _af_source=$1 _af_output=$2
  while IFS= read -r _af_line || [ -n "$_af_line" ]; do
    case "$_af_line" in
      EXIT_WRAPPER_SOURCE) cat "$TEST_ROOT/exit-wrapper.fn" || return 1 ;;
      *) printf '%s\n' "$_af_line" ;;
    esac
  done <"$_af_source" >"$_af_output"
}

assemble_fixture "$TEST_ROOT/fixture.sh" "$TEST_ROOT/fixture-ready.sh" || fail 'fixture assembly'

check_status() {
  _cs_shell=$1 _cs_fail=$2 _cs_prior=$3 _cs_expected=$4
  case "$_cs_shell" in
    dash|busybox) : ;;
    *) fail "unknown shell $_cs_shell" ;;
  esac
  if [ "$_cs_shell" = dash ]; then
    if CLEANUP_FAIL="$_cs_fail" PRIOR_STATUS="$_cs_prior" /bin/sh "$TEST_ROOT/fixture-ready.sh" >/dev/null 2>&1; then
      _cs_actual=0
    else
      _cs_actual=$?
    fi
  else
    if CLEANUP_FAIL="$_cs_fail" PRIOR_STATUS="$_cs_prior" busybox ash "$TEST_ROOT/fixture-ready.sh" >/dev/null 2>&1; then
      _cs_actual=0
    else
      _cs_actual=$?
    fi
  fi
  [ "$_cs_actual" -eq "$_cs_expected" ] || \
    fail "$_cs_shell cleanup_fail=$_cs_fail prior=$_cs_prior produced $_cs_actual, expected $_cs_expected"
}

for _shell in dash busybox; do
  check_status "$_shell" 0 0 0
  check_status "$_shell" 1 0 1
  check_status "$_shell" 0 17 17
  check_status "$_shell" 1 17 17
  check_status "$_shell" 1 130 130
done

pass 'Update EXIT cleanup failure becomes process failure and preserves existing failure/signal status under Dash and BusyBox ash'
