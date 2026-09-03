#!/bin/sh
# Standalone recovery rollback/EXIT preservation contract.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.recovery-rollback.$$"
umask 077
mkdir -p "$TEST_ROOT/extracted" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_function() {
  _rrc_src="$1" _rrc_name="$2" _rrc_out="$3"
  awk -v name="$_rrc_name" '
    function delta(line,   i,c,n) {
      gsub(/\$\{[^}]*\}/, "", line)
      for (i=1; i<=length(line); i++) { c=substr(line,i,1); if (c=="{") n++; else if (c=="}") n-- }
      return n
    }
    !inside && $0 ~ "^[[:space:]]*" name "[[:space:]]*\\(\\)[[:space:]]*\\{" { inside=1 }
    inside { print; depth += delta($0); if (depth == 0) exit }
  ' "$_rrc_src" > "$_rrc_out" || return 1
  [ -s "$_rrc_out" ]
}

for _rrc_fn in recovery_cleanup recovery_mark_rollback_required recovery_rollback recovery_on_signal; do
  extract_function "$BASE_DIR/functions/mervlan_recover.sh" "$_rrc_fn" \
    "$TEST_ROOT/extracted/$_rrc_fn.sh" || fail "$_rrc_fn extraction"
done

cat > "$TEST_ROOT/driver.sh" <<'DRIVER'
#!/bin/sh
set -u

CASE_ROOT=${CASE_ROOT:?}
CASE_MODE=${CASE_MODE:?}
TRACE="$CASE_ROOT/trace"
MERVLAN_RECOVERY_TMP_ROOT="$CASE_ROOT/tmp"
MERVLAN_RECOVERY_BACKUP_ROOT="$CASE_ROOT/backups"
MERVLAN_RECOVERY_ACTIVE_ROOT="$CASE_ROOT/active"
RECOVERY_WORK="$MERVLAN_RECOVERY_TMP_ROOT/restore.1"
RECOVERY_JFFS_STAGE="$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.new.1"
RECOVERY_JFFS_OLD="$MERVLAN_RECOVERY_BACKUP_ROOT/.mervlan.old.1"
RECOVERY_ORIGINAL="$RECOVERY_WORK/original"
RECOVERY_PRESERVE_JFFS=0
RECOVERY_REPLACED=0
RECOVERY_ROLLING_BACK=0
RECOVERY_RECOVERY_REQUIRED=0
RECOVERY_LOCK_OWNED=1

recovery_error() { printf 'error=%s\n' "$*" >> "$TRACE"; }
recovery_path_safe() { return 0; }
recovery_release_lock() {
  [ "$RECOVERY_LOCK_OWNED" = 1 ] || return 0
  printf 'lock-release\n' >> "$TRACE"
  RECOVERY_LOCK_OWNED=0
  return 0
}
recovery_copy_tree() { return 1; }
recovery_reconcile() { return 1; }
recovery_boot_state() { printf '0\n'; }
rm() {
  for _rrc_arg in "$@"; do
    if [ "$CASE_MODE" = activated-rollback-failure ] && [ "$_rrc_arg" = "$RECOVERY_JFFS_STAGE" ]; then
      printf 'stage-remove=fail\n' >> "$TRACE"
      return 1
    fi
  done
  command rm "$@"
}

for _rrc_fn in recovery_cleanup recovery_mark_rollback_required recovery_rollback recovery_on_signal; do
  . "$EXTRACT_ROOT/$_rrc_fn.sh" || exit 2
done

mkdir -p "$RECOVERY_WORK" "$RECOVERY_JFFS_STAGE" "$RECOVERY_JFFS_OLD" "$MERVLAN_RECOVERY_ACTIVE_ROOT" || exit 2
: > "$RECOVERY_WORK/marker"
trap recovery_cleanup EXIT

case "$CASE_MODE" in
  normal-clean)
    exit 0
    ;;
  signal-before-activation)
    recovery_on_signal 143
    ;;
  activated-rollback-failure)
    RECOVERY_REPLACED=1
    recovery_on_signal 143
    ;;
  *) exit 2 ;;
esac
DRIVER
chmod 700 "$TEST_ROOT/driver.sh" || exit 1

run_case() {
  _rrc_mode="$1"
  _rrc_root="$TEST_ROOT/$_rrc_mode"
  mkdir -p "$_rrc_root" || fail "$_rrc_mode fixture"
  ( CASE_ROOT="$_rrc_root" CASE_MODE="$_rrc_mode" EXTRACT_ROOT="$TEST_ROOT/extracted" \
    sh "$TEST_ROOT/driver.sh" ) > "$_rrc_root/stdout" 2>&1
  _rrc_rc=$?
  [ "$_rrc_rc" -ne 2 ] || { cat "$_rrc_root/stdout" >&2; fail "$_rrc_mode setup"; }
  [ -f "$_rrc_root/trace" ] || fail "$_rrc_mode trace"
  _rrc_release=$(grep -c '^lock-release$' "$_rrc_root/trace" 2>/dev/null || :)
  _rrc_release=${_rrc_release:-0}
  case "$_rrc_mode" in
    normal-clean)
      [ "$_rrc_rc" -eq 0 ] || fail "normal cleanup rc=$_rrc_rc"
      [ "$_rrc_release" -eq 1 ] || fail "normal cleanup release=$_rrc_release"
      [ ! -e "$_rrc_root/tmp/restore.1/marker" ] || fail 'normal cleanup retained work'
      ;;
    signal-before-activation)
      [ "$_rrc_rc" -eq 143 ] || fail "pre-activation signal rc=$_rrc_rc"
      [ "$_rrc_release" -eq 1 ] || fail "pre-activation signal release=$_rrc_release"
      [ ! -e "$_rrc_root/tmp/restore.1/marker" ] || fail 'pre-activation signal retained work'
      ;;
    activated-rollback-failure)
      [ "$_rrc_rc" -eq 143 ] || fail "failed rollback signal rc=$_rrc_rc"
      grep -q '^stage-remove=fail$' "$_rrc_root/trace" || fail 'failed rollback was not exercised'
      [ "$_rrc_release" -eq 0 ] || fail 'failed rollback released recovery owner lock'
      [ -e "$_rrc_root/tmp/restore.1/marker" ] || fail 'failed rollback discarded recovery work'
      [ -d "$_rrc_root/backups/.mervlan.new.1" ] || fail 'failed rollback discarded activation stage'
      [ -d "$_rrc_root/backups/.mervlan.old.1" ] || fail 'failed rollback discarded rollback tree'
      grep -q 'rollback recovery remains incomplete' "$_rrc_root/trace" || fail 'failed rollback preservation result'
      ;;
  esac
  pass "recovery $_rrc_mode"
}

run_case normal-clean
run_case signal-before-activation
run_case activated-rollback-failure
printf 'RECOVERY_ROLLBACK_CLEANUP_CONTRACT_OK\n'
