#!/bin/sh
# Exercise the standalone Repair scanner without running its main entry point.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
ENGINE=${1:-$ROOT/functions/update_mervlan_repair.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-repair-sequential.XXXXXX")
sleeper=
cleanup() {
  if [ -n "$sleeper" ]; then
    kill "$sleeper" 2>/dev/null || :
    wait "$sleeper" 2>/dev/null || :
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Keep the function definitions and omit the top-level traps and entry point.
awk '
  /^trap repair_exit_handler EXIT$/ { boundary = 1 }
  /^main "\$@"$/ { if (!boundary) exit 1; entry++ }
  !boundary { print }
  END { if (entry != 1) exit 1 }
' "$ENGINE" >"$WORK/functions.sh"
sleep 60 &
sleeper=$!

cat >"$WORK/driver.sh" <<'DRIVER'
#!/bin/sh
set -u
export LC_ALL=C
phase=$1
fixture=$2
live_pid=$3
MERV_BASE="$fixture/addon"
MERV_REPAIR_TMP_ROOT="$fixture"
MERV_REPAIR_PROC_ROOT="$fixture/proc"
MERV_REPAIR_LEGACY_LOCK_ROOT="$fixture/locks"
MERV_REPAIR_MAINTENANCE_LOCK="$fixture/locks/mervlan_maintenance.lock"
export MERV_BASE MERV_REPAIR_TMP_ROOT MERV_REPAIR_PROC_ROOT
export MERV_REPAIR_LEGACY_LOCK_ROOT MERV_REPAIR_MAINTENANCE_LOCK
. "$4"

fail() {
  printf 'FAIL: %s %s\n' "$phase" "$*" >&2
  exit 1
}

early="$MERV_REPAIR_PROC_ROOT/1/cmdline"
late="$MERV_REPAIR_PROC_ROOT/$live_pid/cmdline"
triggered="$fixture/triggered"
mkdir -p "${early%/*}" "${late%/*}" "$MERV_REPAIR_PROC_ROOT/$$" "$MERV_BASE" || exit 1
cp "/proc/$$/stat" "$MERV_REPAIR_PROC_ROOT/$$/stat" || exit 1
cp "/proc/$live_pid/stat" "${late%/*}/stat" || exit 1
printf 'ordinary\000' >"$MERV_REPAIR_PROC_ROOT/$$/cmdline"
# A substring makes the early PID eligible for exact inspection by the old
# batch grep scanner, while exact parsing leaves it an ordinary process.
printf 'worker\000prefix_heal_event.sh_suffix\000' >"$early"
printf 'ordinary\000' >"$late"
printf '/bin/sh\000%s/functions/heal_event.sh\000' "$MERV_BASE" >"$fixture/mutator"

tr() {
  if [ "${1:-}" = '\000' ] && [ "${2:-}" = '\n' ] &&
      [ "${REPAIR_ADMISSION_PHASE:-}" = "$phase" ] &&
      [ /dev/stdin -ef "$early" ] && [ ! -e "$triggered" ]; then
    cp "$fixture/mutator" "$late" && : >"$triggered" || return 2
  fi
  command tr "$@"
}

rc=0
case "$phase" in
  initial|post_acquisition)
    repair_admit || rc=$?
    ;;
  publication)
    repair_admit || fail 'could not acquire fixture owner before publication'
    STAGE_DIR="$fixture/stage"
    BACKUP_DIR="$fixture/backup"
    PATHS_FILE="$fixture/paths"
    LEDGER_FILE="$fixture/ledger"
    mkdir -p "$STAGE_DIR" || exit 1
    printf 'before\n' >"$MERV_BASE/changelog.txt"
    printf 'after\n' >"$STAGE_DIR/changelog.txt"
    printf '0644 changelog.txt\n' >"$PATHS_FILE"
    publish || rc=$?
    ;;
esac

problem=
if [ ! -e "$triggered" ] || ! cmp -s "$late" "$fixture/mutator"; then
  problem='schedule did not leave the later mutator active'
elif [ "$rc" -ne 1 ] || [ "$REPAIR_ADMISSION_PHASE" != "$phase" ] ||
    [ "$REPAIR_BLOCK_CATEGORY" != recognized_legacy_mutator ] ||
    [ "$REPAIR_BLOCK_PID" != "$live_pid" ] ||
    [ "$REPAIR_BLOCK_OPERATION" != heal_event.sh ]; then
  problem="expected refusal at $phase, got rc=$rc phase=$REPAIR_ADMISSION_PHASE category=${REPAIR_BLOCK_CATEGORY:-clear} owned=$REPAIR_LOCK_OWNED"
fi

if [ "$phase" = publication ]; then
  [ "$(cat "$MERV_BASE/changelog.txt")" = before ] ||
    problem="$problem fixture destination was published"
  repair_owner_owned_and_current || problem="$problem fixture owner changed"
  repair_publish_temp_cleanup || problem="$problem publication temp cleanup failed"
elif [ "$REPAIR_LOCK_OWNED" != 0 ] || [ -e "$MERV_REPAIR_MAINTENANCE_LOCK" ]; then
  problem="$problem fixture maintenance lock retained"
fi

if [ "$REPAIR_LOCK_OWNED" = 1 ]; then
  repair_lock_release || problem="$problem fixture owner release failed"
fi
[ -z "$problem" ] || fail "$problem"
printf 'PASS: %s observed later mutator and refused\n' "$phase"
DRIVER

run_shell() {
  printf 'Repair sequential scan using %s\n' "$*"
  for phase in initial post_acquisition publication; do
    env -i PATH="$PATH" "$@" "$WORK/driver.sh" "$phase" \
      "$WORK/$phase" "$sleeper" "$WORK/functions.sh" || failures=1
    rm -rf "$WORK/$phase"
  done
}

failures=0
run_shell /bin/sh
if command -v busybox >/dev/null 2>&1; then
  run_shell busybox ash
else
  printf '%s\n' 'BusyBox ash unavailable for the additional host-shell comparison'
fi
exit "$failures"
