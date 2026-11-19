#!/bin/sh
# Confirm Repair inspects process argv sequentially and repeats admission scans.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
ENGINE="${1:-$ROOT/functions/update_mervlan_repair.sh}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-repair-sequential.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

awk '
  /^trap cleanup 0$/ { boundary = 1 }
  /^main "\$@"$/ { if (!boundary) exit 1; entry++ }
  !boundary { print }
  END { if (entry != 1) exit 1 }
' "$ENGINE" >"$WORK/functions.sh" || fail 'could not isolate Repair function definitions'
awk '
  /^publish_batch\(\) \{$/ { batch = 1 }
  batch && /^}/ { batch = 0 }
  batch && index($0, "owner_ok && scan_processes || return 1") { scan = NR }
  batch && index($0, "mv -f \"$_pu_tmp\" \"$_pu_target\"") { rename = NR }
  END { if (!scan || !rename || scan >= rename) exit 1 }
' "$ENGINE" ||
  fail 'publication does not recheck owner and legacy mutators before rename'

cat >"$WORK/driver.sh" <<'DRIVER'
#!/bin/sh
set -u
export LC_ALL=C
phase=$1
fixture=$2
live_pid=$$
MERV_BASE="$fixture/addon"
MERV_REPAIR_PROC_ROOT="$fixture/proc"
MERV_REPAIR_OWNER_PROC_ROOT=/proc
MERV_REPAIR_ACTION_LOCK="$fixture/locks/mervlan_action.lock"
MERV_REPAIR_LOCK="$fixture/locks/mervlan_maintenance.lock"
MERV_REPAIR_MANAGER_LOCK="$fixture/locks/mervlan_manager.lock"
MERV_REPAIR_LEGACY_LOCK_ROOT="$fixture/locks"
export MERV_BASE MERV_REPAIR_PROC_ROOT MERV_REPAIR_OWNER_PROC_ROOT
export MERV_REPAIR_ACTION_LOCK MERV_REPAIR_LOCK MERV_REPAIR_MANAGER_LOCK MERV_REPAIR_LEGACY_LOCK_ROOT
. "$4"

fail() { printf 'FAIL: %s %s\n' "$phase" "$*" >&2; exit 1; }
early="$MERV_REPAIR_PROC_ROOT/1/cmdline"
late="$MERV_REPAIR_PROC_ROOT/$live_pid/cmdline"
triggered="$fixture/triggered"
mkdir -p "${early%/*}" "${late%/*}" "$MERV_REPAIR_PROC_ROOT/$$" "$MERV_BASE" "$fixture/locks" || exit 1
cp "/proc/$$/stat" "${late%/*}/stat" || exit 1
printf 'ordinary\000' >"$MERV_REPAIR_PROC_ROOT/$$/cmdline"
# This substring must not be treated as an exact legacy writer argument.
printf 'worker\000prefix_heal_event.sh_suffix\000' >"$early"
printf 'ordinary\000' >"$late"
printf '/bin/sh\000%s/functions/./heal_event.sh\000' "$MERV_BASE" >"$fixture/mutator"

tr() {
  if [ "${1:-}" = '\000' ] && [ "${2:-}" = '\n' ] &&
      [ "${SCAN_PHASE:-}" = "$phase" ] &&
      [ /dev/stdin -ef "$early" ] && [ ! -e "$triggered" ]; then
    cp "$fixture/mutator" "$late" && : >"$triggered" || return 2
  fi
  command tr "$@"
}

rc=0
if [ "$phase" != initial ]; then acquire || fail 'could not acquire fixture ownership'; fi
scan_processes || rc=$?
[ -e "$triggered" ] || fail 'scanner did not inspect the later PID after the early ordinary PID'
[ "$rc" -eq 1 ] || fail "expected recognized writer refusal, got rc=$rc"
case "$phase" in
  initial) : ;;
  post_acquisition|publication)
    owner_ok || fail 'fixture owner changed during the scan'
    release || fail 'fixture owner release failed' ;;
  *) fail 'unknown fixture phase' ;;
esac
[ ! -e "$MERV_REPAIR_ACTION_LOCK" ] || [ "$phase" = initial ] || fail 'action lock retained'
printf 'PASS: %s inspected later mutator and refused\n' "$phase"

# Observe each variant against the current PID and canonical fixture cwd.
ln -s "$MERV_BASE" "${late%/*}/cwd"
mkdir -p "$MERV_BASE/functions"
for argument in "$MERV_BASE/functions/heal_event.sh" "$MERV_BASE/functions/./heal_event.sh" \
  "/./${MERV_BASE#/}/./functions/././heal_event.sh" "$MERV_BASE/functions/../functions/heal_event.sh" \
  "$MERV_BASE/functions//heal_event.sh"; do
  printf '/bin/sh\000%s\000' "$argument" >"$late"
  if scan_processes; then fail "scanner accepted absolute candidate $argument"; fi
done
for argument in 'functions/heal_event.sh' './functions/./heal_event.sh' '../heal_event.sh'; do
  printf '/bin/sh\000%s\000' "$argument" >"$late"
  if scan_processes; then fail "scanner accepted relative candidate $argument"; fi
done
rm "${late%/*}/cwd"
ln -s "$MERV_BASE/functions" "${late%/*}/cwd"
printf '/bin/sh\000heal_event.sh\000' >"$late"
if scan_processes; then fail 'scanner accepted a bare writer'; fi
printf '/bin/sh\000%s/functions/service-event-handler.sh\000collectclients_vlanmgr\000' "$MERV_BASE" >"$late"
scan_processes || fail 'recognized read-only dispatcher was refused'
printf '/bin/sh\000%s/functions/./service-event-handler.sh\000collectclients_vlanmgr\000' "$MERV_BASE" >"$late"
if scan_processes; then fail 'alternate spelling granted a dispatcher exception'; fi
printf '/bin/sh\000%s/functions/service-event-handler.sh\000collectclients_vlanmgr\000%s/functions/./heal_event.sh\000' "$MERV_BASE" "$MERV_BASE" >"$late"
if scan_processes; then fail 'dispatcher exception masked an alternate writer'; fi
printf '/bin/sh\000%s/other/./unknown.sh\000' "$fixture" >"$late"
scan_processes || fail 'unknown script outside the addon was refused'
printf 'ordinary\000' >"$late"
scan_processes || fail 'ordinary processes were refused'
rm "$late"
if scan_processes; then fail 'scanner accepted missing cmdline'; fi
ln -s "$early" "$late"
if scan_processes; then fail 'scanner accepted symlinked cmdline'; fi
rm "$late"
printf 'ordinary\000' >"$late"
chmod 000 "$late"
if [ ! -r "$late" ] && scan_processes; then fail 'scanner accepted unreadable cmdline'; fi
chmod 600 "$late"
: >"$MERV_REPAIR_PROC_ROOT/900bad"
if scan_processes; then fail 'scanner accepted a malformed proc entry'; fi
DRIVER

failures=0
shell_run=0
run_shell() {
  shell_run=$((shell_run + 1))
  printf 'Repair sequential scan using %s\n' "$*"
  for phase in initial post_acquisition publication; do
    _case="$WORK/$phase.$shell_run"
    if ! env -i PATH="$PATH" SCAN_PHASE="$phase" "$@" "$WORK/driver.sh" \
        "$phase" "$_case" unused "$WORK/functions.sh"; then failures=1; fi
  done
}
run_shell /bin/sh
if command -v busybox >/dev/null 2>&1; then run_shell busybox ash; else printf '%s\n' 'BusyBox ash unavailable'; fi
[ "$failures" -eq 0 ] || exit 1
printf 'REPAIR_SEQUENTIAL_SCAN_CONTRACT_OK\n'
