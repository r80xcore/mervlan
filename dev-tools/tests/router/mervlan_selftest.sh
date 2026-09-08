#!/bin/sh
#
# ============================================================================ #
#            - File: mervlan_selftest.sh || version="0.72.9"                #
# ============================================================================ #
# Isolated MerVLAN protocol tests. Mutating tests use a fake-ebtables backend
# and a state root beneath /tmp/mervlan_tmp/selftest.<run-id>.
# ============================================================================ #

PATH="/sbin:/bin:/usr/sbin:/usr/bin:${PATH:-}"
export PATH
# Some WSL2 images provide the BusyBox usleep applet without installing a
# standalone usleep command.  Expose that applet only inside this test
# process so the production library sees the same fast-sleep capability as an
# ASUSWRT router, without modifying the host or router environment.
if ! type usleep >/dev/null 2>&1 &&
   type busybox >/dev/null 2>&1 &&
   busybox usleep 1 >/dev/null 2>&1; then
  usleep() { busybox usleep "$@"; }
fi
# Some WSL2 images use uutils coreutils, whose mkdir does not reliably retain
# mutual exclusion for simultaneous creators in this test environment.  Use
# BusyBox only there, matching the router's mkdir/rmdir behavior.
if type busybox >/dev/null 2>&1 &&
   mkdir --version 2>&1 | grep -q 'uutils coreutils'; then
  MERV_SELFTEST_BUSYBOX_FS=1
  export MERV_SELFTEST_BUSYBOX_FS
  mkdir() { busybox mkdir "$@"; }
  rmdir() { busybox rmdir "$@"; }
fi
: "${DEV_TOOLS_ROOT:=$(CDPATH= cd -- "$(dirname -- "$0")/../.." 2>/dev/null && pwd)}"
: "${MERV_BASE:=${MERV_RUNTIME_BASE:-$(CDPATH= cd -- "$DEV_TOOLS_ROOT/.." 2>/dev/null && pwd)}}"
: "${MERV_RUNTIME_BASE:=$MERV_BASE}"
SELFTEST_SCRIPT="$DEV_TOOLS_ROOT/tests/router/mervlan_selftest.sh"
LIVE_TEST_GUARD_SCRIPT="$DEV_TOOLS_ROOT/safety/mervlan_live_test_guard.sh"
SELFTEST_ACTION="${1:-all}"
SELFTEST_RUN_ID="$(date +%s 2>/dev/null || printf '0').$$"
if [ -n "${MERV_SELFTEST_ROOT_OVERRIDE:-}" ]; then
  case "$MERV_SELFTEST_ROOT_OVERRIDE" in /tmp/mervlan_tmp/selftest.*) ;; *) exit 2 ;; esac
  SELFTEST_ROOT="$MERV_SELFTEST_ROOT_OVERRIDE"
else
  SELFTEST_ROOT="/tmp/mervlan_tmp/selftest.${SELFTEST_RUN_ID}"
fi
SELFTEST_STATE="$SELFTEST_ROOT/dhcp_hold"
SELFTEST_FAKE_STATE="$SELFTEST_ROOT/fake-ebtables"
SELFTEST_FAKE_BIN="$SELFTEST_ROOT/bin/fake-ebtables"
SELFTEST_PROC="$SELFTEST_ROOT/proc"
SELFTEST_FAILURES=0
SELFTEST_PASSES=0

case "$SELFTEST_ROOT" in /tmp/mervlan_tmp/selftest.*) ;; *) exit 2 ;; esac
mkdir -p "$SELFTEST_ROOT/bin" "$SELFTEST_STATE" "$SELFTEST_FAKE_STATE" "$SELFTEST_PROC" || exit 2

MERV_DHCP_HOLD_TEST_MODE=1
MERV_DHCP_HOLD_TEST_ROOT="$SELFTEST_ROOT"
MERV_DHCP_HOLD_STATE_ROOT="$SELFTEST_STATE"
MERV_DHCP_HOLD_LEGACY_MARKER="$SELFTEST_ROOT/legacy.active"
MERV_DHCP_HOLD_EBTABLES="$SELFTEST_FAKE_BIN"
MERV_DHCP_HOLD_PROC_ROOT="$SELFTEST_PROC"
FAKE_EBTABLES_STATE="$SELFTEST_FAKE_STATE"
export MERV_BASE MERV_DHCP_HOLD_TEST_MODE MERV_DHCP_HOLD_TEST_ROOT
export MERV_DHCP_HOLD_STATE_ROOT MERV_DHCP_HOLD_LEGACY_MARKER
export MERV_DHCP_HOLD_EBTABLES MERV_DHCP_HOLD_PROC_ROOT FAKE_EBTABLES_STATE

# Minimal log shims keep test output deterministic when the production logging
# library is not loaded.
info() { shift 2 2>/dev/null || :; printf 'INFO: %s\n' "$*"; }
warn() { shift 2 2>/dev/null || :; printf 'WARN: %s\n' "$*" >&2; }
error() { shift 2 2>/dev/null || :; printf 'ERROR: %s\n' "$*" >&2; }

[ -r "$MERV_BASE/settings/var_settings.sh" ] || {
  printf 'selftest: missing var_settings.sh under %s\n' "$MERV_BASE" >&2
  exit 2
}
. "$MERV_BASE/settings/var_settings.sh"
. "$MERV_BASE/settings/lib_json.sh"
. "$MERV_BASE/settings/lib_identity.sh" || exit 2
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 2
. "$MERV_BASE/settings/lib_action_lock.sh" || exit 2
. "$MERV_BASE/settings/lib_mervqt.sh"

write_fake_stat() {
  _wfs_pid="$1"
  _wfs_start="$2"
  mkdir -p "$SELFTEST_PROC/$_wfs_pid" || return 1
  {
    printf '%s (selftest process with spaces) S' "$_wfs_pid"
    _wfs_field=4
    while [ "$_wfs_field" -le 21 ]; do
      printf ' 0'
      _wfs_field=$((_wfs_field + 1))
    done
    printf ' %s\n' "$_wfs_start"
  } > "$SELFTEST_PROC/$_wfs_pid/stat"
}

write_fake_stat "$$" "424242" || exit 2

# The fake backend stores one plain-text rule file per chain. It implements only
# the ebtables operations used by the DHCP-hold API and supports deterministic
# command failure through FAKE_EBTABLES_FAIL_MATCH.  The continuity monitor is
# deliberately evaluated after each successful kernel mutation so a repair
# cannot hide a flush/delete-to-add gap behind an outer checkpoint.
cat > "$SELFTEST_FAKE_BIN" <<'FAKE_EBTABLES'
#!/bin/sh
set -u
state="${FAKE_EBTABLES_STATE:?}"
mkdir -p "$state/chains" || exit 70
printf '%s\n' "$*" >> "$state/commands"
case " $* " in
  *"${FAKE_EBTABLES_FAIL_MATCH:-__never_match__}"*) exit 71 ;;
esac
[ "${1:-}" = "-t" ] && [ "${2:-}" = "filter" ] || exit 64
shift 2
op="${1:-}"
shift || :
if [ "$op" = "-L" ] && [ "${1:-}" = "--Lx" ]; then
  for file in "$state/chains/"*; do
    [ -f "$file" ] || continue
    list_chain=${file##*/}
    printf 'ebtables -t filter -N %s\n' "$list_chain"
    while IFS= read -r rule || [ -n "$rule" ]; do
      [ -n "$rule" ] && printf 'ebtables -t filter -A %s %s\n' "$list_chain" "$rule"
    done < "$file"
  done
  exit 0
fi
chain="${1:-}"
case "$chain" in ''|*[!A-Za-z0-9_-]*) exit 64 ;; esac
shift || :
file="$state/chains/$chain"
case "$op" in
  -N)
    [ ! -e "$file" ] || exit 1
    : > "$file"
    ;;
  -L)
    [ -f "$file" ] || exit 1
    while IFS= read -r rule || [ -n "$rule" ]; do
      [ -n "$rule" ] && printf '%s\n' "-A $chain $rule"
    done < "$file"
    ;;
  -A)
    [ -f "$file" ] || exit 1
    printf '%s\n' "$*" >> "$file"
    ;;
  -I)
    [ -f "$file" ] || exit 1
    tmp="$file.tmp.$$"
    printf '%s\n' "$*" > "$tmp" || exit 1
    cat "$file" >> "$tmp" || exit 1
    mv "$tmp" "$file" || exit 1
    ;;
  -D)
    [ -f "$file" ] || exit 1
    wanted="$*"
    tmp="$file.tmp.$$"
    found=0
    : > "$tmp" || exit 1
    while IFS= read -r rule || [ -n "$rule" ]; do
      if [ "$found" -eq 0 ] && [ "$rule" = "$wanted" ]; then
        found=1
      else
        printf '%s\n' "$rule" >> "$tmp" || exit 1
      fi
    done < "$file"
    mv "$tmp" "$file" || exit 1
    [ "$found" -eq 1 ] || exit 1
    ;;
  -F)
    [ -f "$file" ] || exit 1
    : > "$file"
    ;;
  -X)
    [ -f "$file" ] || exit 1
    [ ! -s "$file" ] || exit 1
    for parent in "$state/chains/"*; do
      [ -f "$parent" ] || continue
      grep -q -- "-j $chain" "$parent" 2>/dev/null && exit 1
    done
    rm -f "$file"
    ;;
  *) exit 64 ;;
esac

case "$op" in
  -N|-A|-I|-D|-F|-X)
    if [ -f "$state/continuous-required" ]; then
      mutation_file="$state/continuous-mutations"
      mutation_count=$(cat "$mutation_file" 2>/dev/null || printf 0)
      case "$mutation_count" in ''|*[!0-9]*) mutation_count=0 ;; esac
      mutation_count=$((mutation_count + 1))
      printf '%s\n' "$mutation_count" > "$mutation_file"

      child_file="$state/chains/${MERV_DHCP_HOLD_CHAIN:-MERV_DHCP_HOLD}"
      forward_file="$state/chains/FORWARD"
      input_file="$state/chains/INPUT"
      child_exact=0 forward_exact=0 input_exact=0
      [ -f "$child_file" ] && child_exact=$(grep -Fxc -- '-p IPv4 --ip-proto udp --ip-dport 67 -j DROP' "$child_file" 2>/dev/null || :)
      [ -f "$forward_file" ] && forward_exact=$(grep -Fxc -- "-j ${MERV_DHCP_HOLD_CHAIN:-MERV_DHCP_HOLD}" "$forward_file" 2>/dev/null || :)
      [ -f "$input_file" ] && input_exact=$(grep -Fxc -- "-j ${MERV_DHCP_HOLD_CHAIN:-MERV_DHCP_HOLD}" "$input_file" 2>/dev/null || :)
      case "$child_exact" in ''|*[!0-9]*) child_exact=0 ;; esac
      case "$forward_exact" in ''|*[!0-9]*) forward_exact=0 ;; esac
      case "$input_exact" in ''|*[!0-9]*) input_exact=0 ;; esac
      if [ "$child_exact" -ge 1 ] 2>/dev/null && { [ "$forward_exact" -ge 1 ] 2>/dev/null || [ "$input_exact" -ge 1 ] 2>/dev/null; }; then
        : > "$state/continuous-established"
      elif [ -f "$state/continuous-established" ]; then
        printf 'gap mutation=%s command=%s child=%s forward=%s input=%s\n' \
          "$mutation_count" "$op $chain $*" "$child_exact" "$forward_exact" "$input_exact" \
          >> "$state/continuous-gaps"
      fi

      case "${FAKE_EBTABLES_POST_FAIL_AT:-}" in
        "$mutation_count") exit 72 ;;
      esac
      case "${FAKE_EBTABLES_SIGNAL_AFTER:-}" in
        "$mutation_count")
          case "${FAKE_EBTABLES_SIGNAL_PID:-}" in
            ''|*[!0-9]*) ;;
            *) kill "-${FAKE_EBTABLES_SIGNAL_NAME:-TERM}" "$FAKE_EBTABLES_SIGNAL_PID" 2>/dev/null || : ;;
          esac
          ;;
      esac
    fi
    ;;
esac
exit 0
FAKE_EBTABLES
chmod 700 "$SELFTEST_FAKE_BIN" || exit 2

# Use separate shell processes for concurrency tests.  A POSIX shell
# subshell keeps the parent's $$, which would make two callers look like one
# live process to the production lock protocol.
SELFTEST_CONCURRENT_CHILD="$SELFTEST_ROOT/bin/concurrent-enforce-child"
cat > "$SELFTEST_CONCURRENT_CHILD" <<'CONCURRENT_ENFORCE_CHILD'
#!/bin/sh
if ! type usleep >/dev/null 2>&1 &&
   type busybox >/dev/null 2>&1 &&
   busybox usleep 1 >/dev/null 2>&1; then
  usleep() { busybox usleep "$@"; }
fi
if [ "${MERV_SELFTEST_BUSYBOX_FS:-0}" = 1 ] &&
   type busybox >/dev/null 2>&1; then
  mkdir() { busybox mkdir "$@"; }
  rmdir() { busybox rmdir "$@"; }
fi
. "$MERV_BASE/settings/var_settings.sh" || exit 2
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 2
. "$MERV_BASE/settings/lib_mervqt.sh" || exit 2
if [ "$MERV_DHCP_HOLD_PROC_ROOT" != /proc ]; then
  _cece_proc_dir="$MERV_DHCP_HOLD_PROC_ROOT/$$"
  mkdir -p "$_cece_proc_dir" || exit 2
  {
    printf '%s (selftest concurrent child) S' "$$"
    _cece_field=4
    while [ "$_cece_field" -le 21 ]; do
      printf ' 0'
      _cece_field=$((_cece_field + 1))
    done
    printf ' 424242\n'
  } > "$_cece_proc_dir/stat" || exit 2
fi
merv_dhcp_hold_enforce
_cece_rc=$?
printf '%s\n' "$_cece_rc" > "$CONCURRENT_ENFORCE_RC"
exit "$_cece_rc"
CONCURRENT_ENFORCE_CHILD
chmod 700 "$SELFTEST_CONCURRENT_CHILD" || exit 2

SELFTEST_DHCP_SIGNAL_CHILD="$SELFTEST_ROOT/bin/dhcp-enforce-signal-child"
cat > "$SELFTEST_DHCP_SIGNAL_CHILD" <<'DHCP_ENFORCE_SIGNAL_CHILD'
#!/bin/sh
. "$MERV_BASE/settings/var_settings.sh" || exit 2
. "$MERV_BASE/settings/lib_identity.sh" || exit 2
. "$MERV_BASE/settings/lib_owner_lock.sh" || exit 2
. "$MERV_BASE/settings/lib_mervqt.sh" || exit 2
FAKE_EBTABLES_SIGNAL_PID="$$"
export FAKE_EBTABLES_SIGNAL_PID
merv_dhcp_hold_enforce
exit $?
DHCP_ENFORCE_SIGNAL_CHILD
chmod 700 "$SELFTEST_DHCP_SIGNAL_CHILD" || exit 2

selftest_reset() {
  case "$SELFTEST_FAKE_STATE" in "$SELFTEST_ROOT"/*) ;; *) return 1 ;; esac
  rm -rf "$SELFTEST_FAKE_STATE" "$SELFTEST_STATE" 2>/dev/null || return 1
  mkdir -p "$SELFTEST_FAKE_STATE/chains" "$SELFTEST_STATE/faults" || return 1
  : > "$SELFTEST_FAKE_STATE/chains/FORWARD"
  : > "$SELFTEST_FAKE_STATE/chains/INPUT"
  rm -f "$MERV_DHCP_HOLD_LEGACY_MARKER"
  unset FAKE_EBTABLES_FAIL_MATCH FAKE_EBTABLES_POST_FAIL_AT FAKE_EBTABLES_SIGNAL_AFTER \
    FAKE_EBTABLES_SIGNAL_PID FAKE_EBTABLES_SIGNAL_NAME MERV_DHCP_HOLD_FAULT_POINT MERV_DHCP_HOLD_FAULT_ACTION \
    MERV_OWNER_LOCK_FAULT MERV_DHCP_STATE_LOCK_FAULT
  export FAKE_EBTABLES_FAIL_MATCH FAKE_EBTABLES_POST_FAIL_AT FAKE_EBTABLES_SIGNAL_AFTER \
    FAKE_EBTABLES_SIGNAL_PID FAKE_EBTABLES_SIGNAL_NAME MERV_DHCP_HOLD_FAULT_POINT MERV_DHCP_HOLD_FAULT_ACTION \
    MERV_OWNER_LOCK_FAULT MERV_DHCP_STATE_LOCK_FAULT
}

pass() {
  SELFTEST_PASSES=$((SELFTEST_PASSES + 1))
  printf 'ok %s\n' "$*"
}

fail() {
  SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
  printf 'not ok %s\n' "$*" >&2
}

assert_ok() {
  _ao_label="$1"
  shift
  if "$@"; then pass "$_ao_label"; else _ao_rc=$?; fail "$_ao_label (rc=$_ao_rc)"; fi
}

assert_rc() {
  _ar_expected="$1"
  _ar_label="$2"
  shift 2
  "$@"
  _ar_rc=$?
  if [ "$_ar_rc" -eq "$_ar_expected" ]; then
    pass "$_ar_label"
  else
    fail "$_ar_label (expected=$_ar_expected actual=$_ar_rc)"
  fi
}

assert_file() {
  if [ -e "$1" ]; then pass "$2"; else fail "$2"; fi
}

assert_no_file() {
  if [ ! -e "$1" ]; then pass "$2"; else fail "$2"; fi
}

test_dhcp_api() {
  selftest_reset || return 1
  assert_ok "enforce succeeds" merv_dhcp_hold_enforce
  assert_ok "exact rules are present" merv_dhcp_hold_rules_present
  _tda_before=$(cksum "$SELFTEST_FAKE_STATE/chains/"* 2>/dev/null)
  : > "$SELFTEST_FAKE_STATE/commands"
  assert_ok "enforcement is idempotent" merv_dhcp_hold_enforce
  _tda_after=$(cksum "$SELFTEST_FAKE_STATE/chains/"* 2>/dev/null)
  [ "$_tda_before" = "$_tda_after" ] && pass "idempotent enforcement preserves rule state" || fail "idempotent enforcement changed rule state"
  ! grep -E -- ' -[NFAIDX]( |$)' "$SELFTEST_FAKE_STATE/commands" >/dev/null 2>&1 &&
    pass "exact watchdog enforcement issues no mutating ebtables commands" ||
    fail "exact watchdog enforcement issues no mutating ebtables commands"
  assert_ok "legacy arm publishes marker" merv_dhcp_hold_arm quiet
  assert_file "$MERV_DHCP_HOLD_LEGACY_MARKER" "legacy marker exists"
  assert_ok "legacy release removes exact rules" merv_dhcp_hold_release
  assert_no_file "$MERV_DHCP_HOLD_LEGACY_MARKER" "legacy marker is removed"
  assert_ok "rules are exactly absent" merv_dhcp_hold_rules_absent
  printf 'test\n' > "$MERV_DHCP_HOLD_LEGACY_MARKER"
  assert_ok "reconcile enforces when legacy marker exists" merv_dhcp_hold_reconcile selftest-marker
  assert_ok "reconcile produced exact held state" merv_dhcp_hold_rules_present
  rm -f "$MERV_DHCP_HOLD_LEGACY_MARKER"
  assert_ok "reconcile removes rules without legacy marker" merv_dhcp_hold_reconcile selftest-clear
  assert_ok "reconciled clear state is exact" merv_dhcp_hold_rules_absent
  assert_rc 1 "path-injection ID rejected" merv_dhcp_hold_valid_id "../../owner"
  assert_rc 1 "empty token rejected" merv_dhcp_hold_valid_id ""
  assert_ok "opaque-safe ID accepted" merv_dhcp_hold_valid_id "manager_1.Run-2"
}

test_dhcp_ebtables_failures() {
  selftest_reset || return 1
  _tdef_backend="$MERV_DHCP_HOLD_EBTABLES"
  MERV_DHCP_HOLD_EBTABLES="$SELFTEST_ROOT/bin/missing-ebtables"
  export MERV_DHCP_HOLD_EBTABLES
  assert_rc 3 "missing ebtables is explicit" merv_dhcp_hold_enforce
  printf 'test\n' > "$MERV_DHCP_HOLD_LEGACY_MARKER"
  assert_rc 3 "release reports unavailable cleanup" merv_dhcp_hold_release
  assert_no_file "$MERV_DHCP_HOLD_LEGACY_MARKER" "release still retires legacy marker"
  MERV_DHCP_HOLD_EBTABLES="$_tdef_backend"
  export MERV_DHCP_HOLD_EBTABLES

  FAKE_EBTABLES_FAIL_MATCH="-A MERV_DHCP_HOLD"
  export FAKE_EBTABLES_FAIL_MATCH
  assert_rc 4 "enforcement command failure is explicit" merv_dhcp_hold_enforce
  unset FAKE_EBTABLES_FAIL_MATCH
  export FAKE_EBTABLES_FAIL_MATCH
  _tdef_fault_found=0
  for _tdef_fault in "$SELFTEST_STATE/faults/"*; do
    [ -f "$_tdef_fault" ] || continue
    _tdef_fault_found=1
    break
  done
  [ "$_tdef_fault_found" -eq 1 ] && pass "enforcement failure records a fault" ||
    fail "enforcement failure records a fault"

  for _tdef_point in enforce-before-chain enforce-after-chain enforce-after-drop \
    enforce-after-forward enforce-after-input enforce-before-verify; do
    selftest_reset || return 1
    MERV_DHCP_HOLD_FAULT_POINT="$_tdef_point"
    export MERV_DHCP_HOLD_FAULT_POINT
    assert_rc 4 "checkpoint $_tdef_point interrupts safely" merv_dhcp_hold_enforce
    unset MERV_DHCP_HOLD_FAULT_POINT
    export MERV_DHCP_HOLD_FAULT_POINT
    assert_ok "checkpoint $_tdef_point is reconcilable" merv_dhcp_hold_enforce
    assert_ok "checkpoint $_tdef_point repairs to exact state" merv_dhcp_hold_rules_present
  done
}

test_dhcp_rule_exactness() {
  selftest_reset || return 1
  assert_ok "baseline exact enforcement" merv_dhcp_hold_enforce
  "$SELFTEST_FAKE_BIN" -t filter -A "$MERV_DHCP_HOLD_CHAIN" -j DROP
  assert_rc 4 "unrelated DROP does not satisfy exact chain state" merv_dhcp_hold_rules_present
  assert_ok "extra chain rule repaired" merv_dhcp_hold_enforce

  "$SELFTEST_FAKE_BIN" -t filter -A FORWARD -j "$MERV_DHCP_HOLD_CHAIN"
  assert_rc 4 "duplicate FORWARD jump is detected" merv_dhcp_hold_rules_present
  assert_ok "duplicate FORWARD jump repaired" merv_dhcp_hold_enforce

  "$SELFTEST_FAKE_BIN" -t filter -A INPUT -p IPv4 -j "$MERV_DHCP_HOLD_CHAIN"
  assert_rc 4 "conditional INPUT jump is not accepted as exact" merv_dhcp_hold_rules_present
  assert_ok "conditional target jump repaired" merv_dhcp_hold_enforce

  "$SELFTEST_FAKE_BIN" -t filter -D INPUT -j "$MERV_DHCP_HOLD_CHAIN"
  assert_rc 4 "partial rule state is detected" merv_dhcp_hold_rules_present
  assert_ok "partial rule state repaired" merv_dhcp_hold_enforce
  assert_ok "repaired state is exact" merv_dhcp_hold_rules_present

  selftest_reset || return 1
  _tdre_proc_root="$MERV_DHCP_HOLD_PROC_ROOT"
  MERV_DHCP_HOLD_PROC_ROOT=/proc
  export MERV_DHCP_HOLD_PROC_ROOT
  _tdre_i=1
  while [ "$_tdre_i" -le 2 ]; do
    CONCURRENT_ENFORCE_RC="$SELFTEST_ROOT/concurrent-enforce.$_tdre_i.rc" \
      sh "$SELFTEST_CONCURRENT_CHILD" &
    _tdre_i=$((_tdre_i + 1))
  done
  wait
  _tdre_ok=1
  _tdre_i=1
  while [ "$_tdre_i" -le 2 ]; do
    [ "$(cat "$SELFTEST_ROOT/concurrent-enforce.$_tdre_i.rc" 2>/dev/null)" = 0 ] || _tdre_ok=0
    _tdre_i=$((_tdre_i + 1))
  done
  if [ "$_tdre_ok" -ne 1 ]; then
    printf 'diagnostic: concurrent return codes: ' >&2
    printf '1=%s 2=%s\n' \
      "$(cat "$SELFTEST_ROOT/concurrent-enforce.1.rc" 2>/dev/null || printf missing)" \
      "$(cat "$SELFTEST_ROOT/concurrent-enforce.2.rc" 2>/dev/null || printf missing)" >&2
    printf 'diagnostic: concurrent state lock:\n' >&2
    ls -la "$MERV_DHCP_HOLD_STATE_ROOT/state.lock" 2>&1 >&2 || :
    for _tdre_file in pid proc_start_time created_epoch owner_nonce; do
      printf '%s=' "$_tdre_file" >&2
      cat "$MERV_DHCP_HOLD_STATE_ROOT/state.lock/$_tdre_file" 2>/dev/null || printf missing >&2
      printf '\n' >&2
    done
    printf 'diagnostic: fake chains:\n' >&2
    for _tdre_chain in FORWARD INPUT MERV_DHCP_HOLD; do
      printf '%s:\n' "$_tdre_chain" >&2
      cat "$SELFTEST_FAKE_STATE/chains/$_tdre_chain" 2>/dev/null || printf missing >&2
    done
  fi
  [ "$_tdre_ok" -eq 1 ] && pass "concurrent enforcement callers all succeed" ||
    fail "concurrent enforcement callers all succeed"
  assert_ok "concurrent enforcement leaves one exact rule set" merv_dhcp_hold_rules_present
  MERV_DHCP_HOLD_PROC_ROOT="$_tdre_proc_root"
  export MERV_DHCP_HOLD_PROC_ROOT
}

# Return true when the fake ebtables state has an effective DHCP server
# protection path: an exact child DROP plus at least one exact parent jump.
# The production contract ultimately requires both parents, but this narrower
# predicate detects the dangerous transition from an already-protective
# damaged state to no protection at all.
selftest_dhcp_effective_protection() {
  _sdep_child="$SELFTEST_FAKE_STATE/chains/$MERV_DHCP_HOLD_CHAIN"
  _sdep_forward="$SELFTEST_FAKE_STATE/chains/FORWARD"
  _sdep_input="$SELFTEST_FAKE_STATE/chains/INPUT"
  _sdep_child_count=0 _sdep_forward_count=0 _sdep_input_count=0
  [ -f "$_sdep_child" ] && _sdep_child_count=$(grep -Fxc -- '-p IPv4 --ip-proto udp --ip-dport 67 -j DROP' "$_sdep_child" 2>/dev/null || :)
  [ -f "$_sdep_forward" ] && _sdep_forward_count=$(grep -Fxc -- "-j $MERV_DHCP_HOLD_CHAIN" "$_sdep_forward" 2>/dev/null || :)
  [ -f "$_sdep_input" ] && _sdep_input_count=$(grep -Fxc -- "-j $MERV_DHCP_HOLD_CHAIN" "$_sdep_input" 2>/dev/null || :)
  case "$_sdep_child_count" in ''|*[!0-9]*) _sdep_child_count=0 ;; esac
  case "$_sdep_forward_count" in ''|*[!0-9]*) _sdep_forward_count=0 ;; esac
  case "$_sdep_input_count" in ''|*[!0-9]*) _sdep_input_count=0 ;; esac
  [ "$_sdep_child_count" -ge 1 ] 2>/dev/null && \
    { [ "$_sdep_forward_count" -ge 1 ] 2>/dev/null || [ "$_sdep_input_count" -ge 1 ] 2>/dev/null; }
}

selftest_dhcp_continuity_arm() {
  rm -f "$SELFTEST_FAKE_STATE/continuous-required" \
    "$SELFTEST_FAKE_STATE/continuous-established" \
    "$SELFTEST_FAKE_STATE/continuous-gaps" \
    "$SELFTEST_FAKE_STATE/continuous-mutations"
  : > "$SELFTEST_FAKE_STATE/continuous-required"
  selftest_dhcp_effective_protection && : > "$SELFTEST_FAKE_STATE/continuous-established"
}

selftest_dhcp_continuity_seed() {
  _sdcs_mode="$1"
  selftest_reset || return 1
  merv_dhcp_hold_enforce || return 1
  case "$_sdcs_mode" in
    extra-child)
      "$SELFTEST_FAKE_BIN" -t filter -A "$MERV_DHCP_HOLD_CHAIN" -j DROP ;;
    duplicate-drop)
      "$SELFTEST_FAKE_BIN" -t filter -A "$MERV_DHCP_HOLD_CHAIN" \
        -p IPv4 --ip-proto udp --ip-dport 67 -j DROP ;;
    duplicate-forward)
      "$SELFTEST_FAKE_BIN" -t filter -A FORWARD -j "$MERV_DHCP_HOLD_CHAIN" ;;
    duplicate-input)
      "$SELFTEST_FAKE_BIN" -t filter -A INPUT -j "$MERV_DHCP_HOLD_CHAIN" ;;
    conditional-parent)
      "$SELFTEST_FAKE_BIN" -t filter -A FORWARD -p IPv4 -j "$MERV_DHCP_HOLD_CHAIN" ;;
    missing-drop)
      "$SELFTEST_FAKE_BIN" -t filter -D "$MERV_DHCP_HOLD_CHAIN" \
        -p IPv4 --ip-proto udp --ip-dport 67 -j DROP ;;
    missing-forward)
      "$SELFTEST_FAKE_BIN" -t filter -D FORWARD -j "$MERV_DHCP_HOLD_CHAIN" ;;
    chain-absent)
      "$SELFTEST_FAKE_BIN" -t filter -D FORWARD -j "$MERV_DHCP_HOLD_CHAIN" || return 1
      "$SELFTEST_FAKE_BIN" -t filter -D INPUT -j "$MERV_DHCP_HOLD_CHAIN" || return 1
      "$SELFTEST_FAKE_BIN" -t filter -F "$MERV_DHCP_HOLD_CHAIN" || return 1
      "$SELFTEST_FAKE_BIN" -t filter -X "$MERV_DHCP_HOLD_CHAIN" ;;
    partial-flush)
      "$SELFTEST_FAKE_BIN" -t filter -F "$MERV_DHCP_HOLD_CHAIN" ;;
    *) return 2 ;;
  esac
}

selftest_dhcp_continuity_no_gap() {
  [ ! -s "$SELFTEST_FAKE_STATE/continuous-gaps" ]
}

selftest_dhcp_continuity_case() {
  _sdcc_label="$1" _sdcc_mode="$2" _sdcc_signal="$3"
  selftest_dhcp_continuity_seed "$_sdcc_mode" || { fail "DHCP continuity $_sdcc_label seed"; return 1; }
  selftest_dhcp_continuity_arm
  if [ -n "$_sdcc_signal" ]; then
    FAKE_EBTABLES_SIGNAL_AFTER="$_sdcc_signal" \
      FAKE_EBTABLES_SIGNAL_NAME="$_sdcc_label" \
      /bin/sh "$SELFTEST_DHCP_SIGNAL_CHILD" >/dev/null 2>&1
    _sdcc_rc=$?
  else
    merv_dhcp_hold_enforce
    _sdcc_rc=$?
  fi
  _sdcc_mutations=$(cat "$SELFTEST_FAKE_STATE/continuous-mutations" 2>/dev/null || printf 0)
  case "$_sdcc_mutations" in ''|*[!0-9]*) _sdcc_mutations=0 ;; esac
  if [ -n "$_sdcc_signal" ]; then
    [ "$_sdcc_rc" -ne 0 ] && pass "DHCP continuity $_sdcc_mode signal $_sdcc_label interrupts owner" ||
      fail "DHCP continuity $_sdcc_mode signal $_sdcc_label interrupts owner"
  else
    [ "$_sdcc_rc" -eq 0 ] && pass "DHCP continuity $_sdcc_mode repairs" ||
      fail "DHCP continuity $_sdcc_mode repairs (rc=$_sdcc_rc)"
  fi
  selftest_dhcp_continuity_no_gap && pass "DHCP continuity $_sdcc_mode preserves effective protection" || {
    fail "DHCP continuity $_sdcc_mode has a protection gap"; cat "$SELFTEST_FAKE_STATE/continuous-gaps" >&2 2>/dev/null || :;
  }
  unset FAKE_EBTABLES_POST_FAIL_AT FAKE_EBTABLES_SIGNAL_AFTER FAKE_EBTABLES_SIGNAL_NAME
  export FAKE_EBTABLES_POST_FAIL_AT FAKE_EBTABLES_SIGNAL_AFTER FAKE_EBTABLES_SIGNAL_NAME
  assert_ok "DHCP continuity $_sdcc_mode reconciles exactly" merv_dhcp_hold_enforce
  assert_ok "DHCP continuity $_sdcc_mode final state exact" merv_dhcp_hold_rules_present
  SELFTEST_CONTINUITY_MUTATIONS="$_sdcc_mutations"
  export SELFTEST_CONTINUITY_MUTATIONS
}

test_dhcp_continuous_repair() {
  for _tdcr_mode in extra-child duplicate-drop duplicate-forward duplicate-input \
    conditional-parent missing-drop missing-forward chain-absent partial-flush; do
    selftest_dhcp_continuity_case baseline "$_tdcr_mode" ""
    _tdcr_mutations="${SELFTEST_CONTINUITY_MUTATIONS:-0}"
    case "$_tdcr_mutations" in ''|*[!0-9]*) _tdcr_mutations=0 ;; esac
    _tdcr_i=1
    while [ "$_tdcr_i" -le "$_tdcr_mutations" ]; do
      selftest_dhcp_continuity_seed "$_tdcr_mode" || { fail "DHCP continuity $_tdcr_mode post-failure seed"; break; }
      selftest_dhcp_continuity_arm
      FAKE_EBTABLES_POST_FAIL_AT="$_tdcr_i"
      export FAKE_EBTABLES_POST_FAIL_AT
      merv_dhcp_hold_enforce >/dev/null 2>&1
      _tdcr_fail_rc=$?
      if [ "$_tdcr_fail_rc" -ne 0 ]; then
        pass "DHCP continuity $_tdcr_mode post-failure $_tdcr_i is visible"
      elif merv_dhcp_hold_rules_present; then
        # `-N` can report failure after successfully creating the chain.  The
        # production idempotence check is allowed to prove that semantic
        # success and continue to an exact held state.
        pass "DHCP continuity $_tdcr_mode post-failure $_tdcr_i is recovered inline"
      else
        fail "DHCP continuity $_tdcr_mode post-failure $_tdcr_i is visible"
      fi
      selftest_dhcp_continuity_no_gap && pass "DHCP continuity $_tdcr_mode post-failure $_tdcr_i retains protection" ||
        fail "DHCP continuity $_tdcr_mode post-failure $_tdcr_i has a protection gap"
      unset FAKE_EBTABLES_POST_FAIL_AT
      export FAKE_EBTABLES_POST_FAIL_AT
      assert_ok "DHCP continuity $_tdcr_mode post-failure $_tdcr_i reconciles" merv_dhcp_hold_enforce
      assert_ok "DHCP continuity $_tdcr_mode post-failure $_tdcr_i exact" merv_dhcp_hold_rules_present

      for _tdcr_signal in TERM INT; do
        selftest_dhcp_continuity_seed "$_tdcr_mode" || { fail "DHCP continuity $_tdcr_mode $_tdcr_signal seed"; continue; }
        selftest_dhcp_continuity_arm
        FAKE_EBTABLES_SIGNAL_AFTER="$_tdcr_i"
        FAKE_EBTABLES_SIGNAL_NAME="$_tdcr_signal"
        export FAKE_EBTABLES_SIGNAL_AFTER FAKE_EBTABLES_SIGNAL_NAME
        /bin/sh "$SELFTEST_DHCP_SIGNAL_CHILD" >/dev/null 2>&1
        _tdcr_signal_rc=$?
        [ "$_tdcr_signal_rc" -ne 0 ] && pass "DHCP continuity $_tdcr_mode $_tdcr_signal $_tdcr_i interrupts owner" ||
          fail "DHCP continuity $_tdcr_mode $_tdcr_signal $_tdcr_i interrupts owner"
        selftest_dhcp_continuity_no_gap && pass "DHCP continuity $_tdcr_mode $_tdcr_signal $_tdcr_i retains protection" ||
          fail "DHCP continuity $_tdcr_mode $_tdcr_signal $_tdcr_i has a protection gap"
        unset FAKE_EBTABLES_SIGNAL_AFTER FAKE_EBTABLES_SIGNAL_NAME
        export FAKE_EBTABLES_SIGNAL_AFTER FAKE_EBTABLES_SIGNAL_NAME
        assert_ok "DHCP continuity $_tdcr_mode $_tdcr_signal $_tdcr_i reconciles" merv_dhcp_hold_enforce
        assert_ok "DHCP continuity $_tdcr_mode $_tdcr_signal $_tdcr_i exact" merv_dhcp_hold_rules_present
      done
      _tdcr_i=$((_tdcr_i + 1))
    done
  done
}

test_l2_guard_dump_contract() {
  _tlgd_human='Bridge chain: MERV_MAC, entries: 1, policy: ACCEPT
-s 02:00:00:00:00:01 --logical-in br0 -j DROP
Bridge chain: MERV_QT, entries: 1, policy: ACCEPT
-i wl0.2 --logical-in br0 -j DROP
Bridge chain: FORWARD, entries: 2, policy: ACCEPT
-j MERV_MAC
-j MERV_QT
Bridge chain: INPUT, entries: 2, policy: ACCEPT
-j MERV_MAC
-j MERV_QT'
  _tlgd_restore='ebtables -t filter -N MERV_MAC
ebtables -t filter -N MERV_QT
ebtables -t filter -A MERV_MAC -s 02:00:00:00:00:01 --logical-in br0 -j DROP
ebtables -t filter -A MERV_QT -i wl0.2 --logical-in br0 -j DROP
ebtables -t filter -A FORWARD -j MERV_MAC
ebtables -t filter -A FORWARD -j MERV_QT
ebtables -t filter -A INPUT -j MERV_MAC
ebtables -t filter -A INPUT -j MERV_QT'
  _tlgd_ok=1

  for _tlgd_dump in "$_tlgd_human" "$_tlgd_restore"; do
    if ! merv_ebtables_verify_parent_jumps "$_tlgd_dump" MERV_MAC ||
       ! merv_ebtables_verify_parent_jumps "$_tlgd_dump" MERV_QT ||
       [ "$(merv_ebtables_rule_count_exact "$_tlgd_dump" MERV_MAC '-s 02:00:00:00:00:01 --logical-in br0 -j DROP')" != 1 ] ||
       [ "$(merv_ebtables_rule_count_exact "$_tlgd_dump" MERV_QT '-i wl0.2 --logical-in br0 -j DROP')" != 1 ] ||
       [ "$(merv_ebtables_chain_rule_count "$_tlgd_dump" MERV_MAC)" != 1 ] ||
       [ "$(merv_ebtables_chain_rule_count "$_tlgd_dump" MERV_QT)" != 1 ]; then
      _tlgd_ok=0
    fi
  done

  # ASUSWRT may print a valid MAC with one-digit octets (08:... as 8:...).
  # The canonical verifier must still match it to the padded database form.
  _tlgd_short_human='Bridge chain: MERV_MAC, entries: 1, policy: ACCEPT
-s 8:95:42:19:53:b2 --logical-in br0 -j DROP'
  _tlgd_short_restore='ebtables -t filter -N MERV_MAC
ebtables -t filter -A MERV_MAC -s 8:95:42:19:53:b2 --logical-in br0 -j DROP'
  for _tlgd_dump in "$_tlgd_short_human" "$_tlgd_short_restore"; do
    [ "$(merv_ebtables_rule_count_exact "$_tlgd_dump" MERV_MAC '-s 08:95:42:19:53:b2 --logical-in br0 -j DROP')" = 1 ] ||
      _tlgd_ok=0
  done

  if [ "$_tlgd_ok" = 1 ]; then
    pass "L2 guard exact verifier accepts firmware MAC formatting in both ebtables dump styles"
  else
    fail "L2 guard exact verifier accepts firmware MAC formatting in both ebtables dump styles"
  fi
  return "$_tlgd_ok"
}

test_l2_guard_exactness_contract() {
  selftest_reset || return 1
  _tlge_dry="${DRY_RUN:-no}"
  DRY_RUN=no
  export DRY_RUN
  ebtables() { "$SELFTEST_FAKE_BIN" "$@"; }
  merv_iface_vid_list() { printf 'wl0.2 189\n'; }
  merv_managed_eth_iface_vid_list() { printf 'lan_mapped 189\n'; }

  assert_ok "QT exact reconciler arms VAP and mapped Ethernet rules" merv_qt_ensure_expected_rules
  assert_ok "QT exact verifier accepts canonical expected rules" merv_qt_verify_exact
  "$SELFTEST_FAKE_BIN" -t filter -A MERV_QT -i rogue0 --logical-in br0 -j DROP
  assert_rc 1 "QT exact verifier rejects stale child" merv_qt_verify_exact
  assert_ok "QT reconciler removes stale child without chain flush" merv_qt_ensure_expected_rules
  "$SELFTEST_FAKE_BIN" -t filter -A MERV_QT -i wl0.2 --logical-in br0 -j DROP
  assert_rc 1 "QT exact verifier rejects duplicate child" merv_qt_verify_exact
  assert_ok "QT reconciler removes duplicate child" merv_qt_ensure_expected_rules
  "$SELFTEST_FAKE_BIN" -t filter -D INPUT -j MERV_QT
  assert_rc 1 "QT exact verifier rejects missing INPUT parent" merv_qt_verify_exact
  assert_ok "strict QT restorer repairs missing parent" restore_merv_qt_shield
  assert_ok "strict QT restorer leaves exact state" merv_qt_verify_exact

  unset -f ebtables merv_iface_vid_list merv_managed_eth_iface_vid_list 2>/dev/null || :
  DRY_RUN="$_tlge_dry"
  export DRY_RUN
}

test_mac_shield_lifecycle() {
  selftest_reset || return 1
  _tms_old_active="$MERV_MAC_DB_ACTIVE"
  _tms_old_jffs="$MERV_MAC_DB_JFFS"
  _tms_old_override="$MERV_MAC_OVERRIDE_DB"
  _tms_old_dry="${DRY_RUN:-no}"
  _tms_db="$SELFTEST_ROOT/mac-shield.db"
  MERV_MAC_DB_ACTIVE="$_tms_db"
  MERV_MAC_DB_JFFS="$SELFTEST_ROOT/mac-shield.jffs.db"
  MERV_MAC_OVERRIDE_DB="$SELFTEST_ROOT/mac-shield.override.db"
  DRY_RUN=no
  export MERV_MAC_DB_ACTIVE MERV_MAC_DB_JFFS MERV_MAC_OVERRIDE_DB DRY_RUN
  printf '1 02:00:00:00:00:01 wl0.2 187\n' > "$_tms_db" || return 1

  # Keep the fake ebtables command scoped to this test. The strict lifecycle
  # must create a missing chain before it tries to flush it.
  ebtables() { "$SELFTEST_FAKE_BIN" "$@"; }
  if ebt_mac_shield_init_and_apply "$_tms_db" && merv_mac_shield_verify_exact; then
    pass "MAC shield initializes a missing owner chain before flushing and verifies exactly"
    _tms_rc=0
  else
    fail "MAC shield initializes a missing owner chain before flushing and verifies exactly"
    _tms_rc=1
  fi
  unset -f ebtables 2>/dev/null || :
  MERV_MAC_DB_ACTIVE="$_tms_old_active"
  MERV_MAC_DB_JFFS="$_tms_old_jffs"
  MERV_MAC_OVERRIDE_DB="$_tms_old_override"
  DRY_RUN="$_tms_old_dry"
  export MERV_MAC_DB_ACTIVE MERV_MAC_DB_JFFS MERV_MAC_OVERRIDE_DB DRY_RUN
  return "$_tms_rc"
}

test_l2_guard_coordinator_contract() {
  _tlgc_ok=1
  for _tlgc_name in restore_merv_qt_shield restore_merv_mac_shield \
    merv_dhcp_hold_restore_if_active merv_l2_guard_restore_all merv_guard_tick \
    merv_guarded_sleep; do
    type "$_tlgc_name" >/dev/null 2>&1 && pass "L2 guard public API exposes $_tlgc_name" || {
      fail "L2 guard public API exposes $_tlgc_name"
      _tlgc_ok=0
    }
  done

  _tlgc_case() {
    _tlgc_expected="$1"
    _tlgc_fail="$2"
    _tlgc_trace="$SELFTEST_ROOT/guard-coordinator.$_tlgc_expected.trace"
    _tlgc_dump="$SELFTEST_ROOT/guard-coordinator.$_tlgc_expected.dump"
    _tlgc_calls="$SELFTEST_ROOT/guard-coordinator.$_tlgc_expected.calls"
    rm -f "$_tlgc_trace" "$_tlgc_dump" "$_tlgc_calls"
    (
      mervqt_has_ebtables() { return 0; }
      ebtables() {
        case "$*" in
          *" -L --Lx")
            printf '%s\n' 'ebtables -t filter -N MERV_QT' > "$_tlgc_dump"
            printf '%s\n' dump >> "$_tlgc_calls"
            cat "$_tlgc_dump"
            ;;
          *) return 64 ;;
        esac
      }
      restore_merv_qt_shield() {
        printf 'qt:%s\n' "$1" >> "$_tlgc_trace"
        [ "$_tlgc_fail" = qt ] && return 17
        return 0
      }
      restore_merv_mac_shield() {
        printf 'mac:%s\n' "$1" >> "$_tlgc_trace"
        [ "$_tlgc_fail" = mac ] && return 18
        return 0
      }
      merv_dhcp_hold_restore_if_active() {
        printf 'dhcp\n' >> "$_tlgc_trace"
        [ "$_tlgc_fail" = dhcp ] && return 19
        return 0
      }
      merv_l2_guard_restore_all
    )
    _tlgc_rc=$?
    case "$_tlgc_fail" in
      '') _tlgc_expected_rc=0; _tlgc_expected_trace=$(printf 'qt:ebtables -t filter -N MERV_QT\nmac:ebtables -t filter -N MERV_QT\ndhcp\n') ;;
      qt) _tlgc_expected_rc=17; _tlgc_expected_trace=$(printf 'qt:ebtables -t filter -N MERV_QT\n') ;;
      mac) _tlgc_expected_rc=18; _tlgc_expected_trace=$(printf 'qt:ebtables -t filter -N MERV_QT\nmac:ebtables -t filter -N MERV_QT\n') ;;
      dhcp) _tlgc_expected_rc=19; _tlgc_expected_trace=$(printf 'qt:ebtables -t filter -N MERV_QT\nmac:ebtables -t filter -N MERV_QT\ndhcp\n') ;;
      *) _tlgc_expected_rc=1; _tlgc_expected_trace='' ;;
    esac
    if [ "$_tlgc_rc" -eq "$_tlgc_expected_rc" ] &&
       [ "$(cat "$_tlgc_trace" 2>/dev/null)" = "${_tlgc_expected_trace%\n}" ] &&
       [ "$(wc -l < "$_tlgc_calls" 2>/dev/null | tr -d ' ')" = 1 ]; then
      pass "L2 guard coordinator $_tlgc_expected propagates failure and shares one dump"
    else
      fail "L2 guard coordinator $_tlgc_expected propagates failure and shares one dump (rc=$_tlgc_rc)"
      _tlgc_ok=0
    fi
  }

  _tlgc_case success ''
  _tlgc_case qt qt
  _tlgc_case mac mac
  _tlgc_case dhcp dhcp

  _tlgc_tick_trace="$SELFTEST_ROOT/guard-tick.trace"
  _tlgc_tick_calls="$SELFTEST_ROOT/guard-tick.calls"
  rm -f "$_tlgc_tick_trace" "$_tlgc_tick_calls"
  (
    mervqt_has_ebtables() { return 0; }
    ebtables() {
      case "$*" in
        *" -L --Lx") printf '%s\n' 'ebtables -t filter -N MERV_QT' >> "$_tlgc_tick_calls"; printf '%s\n' 'ebtables -t filter -N MERV_QT' ;;
        *) return 64 ;;
      esac
    }
    restore_merv_qt_shield() { printf 'qt:%s\n' "$1" >> "$_tlgc_tick_trace"; return 0; }
    restore_merv_mac_shield() { printf 'mac:%s\n' "$1" >> "$_tlgc_tick_trace"; return 0; }
    merv_dhcp_hold_restore_if_active() { printf 'dhcp\n' >> "$_tlgc_tick_trace"; return 0; }
    merv_guard_tick
  )
  _tlgc_rc=$?
  if [ "$_tlgc_rc" -eq 0 ] && [ "$(wc -l < "$_tlgc_tick_calls" 2>/dev/null | tr -d ' ')" = 1 ]; then
    pass "L2 guard tick performs one shared table dump"
  else
    fail "L2 guard tick performs one shared table dump (rc=$_tlgc_rc)"
    _tlgc_ok=0
  fi

  selftest_reset || return 1
  _tlgc_old_dry="${DRY_RUN:-no}"
  _tlgc_old_active="$MERV_MAC_DB_ACTIVE"
  _tlgc_old_jffs="$MERV_MAC_DB_JFFS"
  _tlgc_old_override="$MERV_MAC_OVERRIDE_DB"
  _tlgc_empty_db="$SELFTEST_ROOT/guard-empty.db"
  : > "$_tlgc_empty_db"
  MERV_MAC_DB_ACTIVE="$_tlgc_empty_db"
  MERV_MAC_DB_JFFS="$_tlgc_empty_db"
  MERV_MAC_OVERRIDE_DB="$SELFTEST_ROOT/guard-empty.override"
  DRY_RUN=no
  export MERV_MAC_DB_ACTIVE MERV_MAC_DB_JFFS MERV_MAC_OVERRIDE_DB DRY_RUN
  ebtables() { "$SELFTEST_FAKE_BIN" "$@"; }
  merv_iface_vid_list() { printf 'wl0.2 189\n'; }
  merv_managed_eth_iface_vid_list() { :; }
  assert_ok "L2 guard healthy state can be armed" merv_qt_ensure_expected_rules
  assert_ok "L2 guard healthy MAC state can be armed" ebt_mac_shield_init_and_apply "$_tlgc_empty_db"
  : > "$SELFTEST_FAKE_STATE/commands"
  assert_ok "L2 guard healthy coordinator verifies exact state" merv_l2_guard_restore_all
  if grep -E -- ' -[NFAIDX]( |$)' "$SELFTEST_FAKE_STATE/commands" >/dev/null 2>&1; then
    fail "L2 guard healthy coordinator performs no mutating writes"
    _tlgc_ok=0
  else
    pass "L2 guard healthy coordinator performs no mutating writes"
  fi
  unset -f ebtables merv_iface_vid_list merv_managed_eth_iface_vid_list 2>/dev/null || :
  MERV_MAC_DB_ACTIVE="$_tlgc_old_active"
  MERV_MAC_DB_JFFS="$_tlgc_old_jffs"
  MERV_MAC_OVERRIDE_DB="$_tlgc_old_override"
  DRY_RUN="$_tlgc_old_dry"
  export MERV_MAC_DB_ACTIVE MERV_MAC_DB_JFFS MERV_MAC_OVERRIDE_DB DRY_RUN

  _tlgc_sleep_trace="$SELFTEST_ROOT/guarded-sleep.trace"
  rm -f "$_tlgc_sleep_trace"
  (
    merv_guard_tick() { printf '%s\n' tick >> "$_tlgc_sleep_trace"; return 23; }
    sleep() { printf '%s\n' sleep >> "$_tlgc_sleep_trace"; return 0; }
    merv_guarded_sleep 2
  )
  _tlgc_rc=$?
  if [ "$_tlgc_rc" -eq 23 ] && [ "$(cat "$_tlgc_sleep_trace" 2>/dev/null)" = tick ]; then
    pass "guarded sleep propagates guard failure before sleeping"
  else
    fail "guarded sleep propagates guard failure before sleeping (rc=$_tlgc_rc)"
    _tlgc_ok=0
  fi

  _tlgc_manager="$MERV_BASE/functions/mervlan_manager.sh"
  _tlgc_wait_fn="$SELFTEST_ROOT/manager-wait-for-interface.sh"
  awk '
    /^wait_for_interface\(\) \{/ { emit=1 }
    emit { print }
    emit && /^}$/ { exit }
  ' "$_tlgc_manager" > "$_tlgc_wait_fn"
  if [ -s "$_tlgc_wait_fn" ]; then
    _tlgc_manager_trace="$SELFTEST_ROOT/manager-wait.trace"
    rm -f "$_tlgc_manager_trace"
    (
      . "$_tlgc_wait_fn"
      iface_exists() { return 1; }
      merv_guard_tick() { printf '%s\n' guard >> "$_tlgc_manager_trace"; return 29; }
      sleep() { printf '%s\n' sleep >> "$_tlgc_manager_trace"; return 0; }
      wait_for_interface eth-test
    )
    _tlgc_rc=$?
    if [ "$_tlgc_rc" -eq 1 ] && [ "$(cat "$_tlgc_manager_trace" 2>/dev/null)" = guard ]; then
      pass "manager wait-for-interface caller propagates guard failure"
    else
      fail "manager wait-for-interface caller propagates guard failure (rc=$_tlgc_rc)"
      _tlgc_ok=0
    fi
  else
    fail "manager wait-for-interface caller fixture extracted"
    _tlgc_ok=0
  fi
  return "$_tlgc_ok"
}

test_process_identity() {
  selftest_reset || return 1
  write_fake_stat 9001 123456
  _tpi_start=$(merv_proc_start_time 9001 "$MERV_DHCP_HOLD_PROC_ROOT" 2>/dev/null)
  [ "$_tpi_start" = 123456 ] && pass "process start time parsed with complex comm" ||
    fail "process start time parsed with complex comm (actual=$_tpi_start)"
  assert_ok "matching PID/start identity accepted" merv_process_identity_matches 9001 123456 "$MERV_DHCP_HOLD_PROC_ROOT"
  assert_rc 1 "reused PID/start mismatch rejected" merv_process_identity_matches 9001 654321 "$MERV_DHCP_HOLD_PROC_ROOT"
  assert_rc 1 "invalid PID rejected" merv_proc_start_time "../1" "$MERV_DHCP_HOLD_PROC_ROOT"
}

# Deterministic replacement-window fixture used by the owner-lock tests. The
# production hook is inert unless its named fault is enabled below.
merv_owner_lock_quarantine_hook() {
  _soqr_lock="$1"
  _soqr_backup="${_soqr_lock}.race-original"
  rm -rf "$_soqr_backup" 2>/dev/null || return 1
  mv "$_soqr_lock" "$_soqr_backup" || return 1
  mkdir "$_soqr_lock" || return 1
  _soqr_start=$(merv_identity_current_start /proc 2>/dev/null) || return 1
  merv_owner_v2_write_atomic "$_soqr_lock" "$$" "$_soqr_start" replacement-owner 1 1
}

merv_dhcp_state_lock_quarantine_hook() {
  _sdqr_lock="$1"
  _sdqr_backup="${_sdqr_lock}.race-original"
  rm -rf "$_sdqr_backup" 2>/dev/null || return 1
  mv "$_sdqr_lock" "$_sdqr_backup" || return 1
  mkdir "$_sdqr_lock" || return 1
  _sdqr_start=$(merv_proc_start_time "$$" "$MERV_DHCP_HOLD_PROC_ROOT" 2>/dev/null) || return 1
  _sdqr_now=$(merv_dhcp_state_lock_now 2>/dev/null) || return 1
  printf '%s\n' "$$" > "$_sdqr_lock/pid" || return 1
  printf '%s\n' "$_sdqr_start" > "$_sdqr_lock/proc_start_time" || return 1
  printf '%s\n' "$_sdqr_now" > "$_sdqr_lock/created_epoch" || return 1
  printf '%s\n' replacement-owner > "$_sdqr_lock/owner_nonce"
}

test_owner_state_release_probe() {
  selftest_reset || return 1
  _tosr_lock="$SELFTEST_ROOT/owner-state-release/claim.lock"
  mkdir -p "${_tosr_lock%/*}" || return 1
  mkdir "$_tosr_lock" || return 1
  (
    TOSR_LS_ONCE=1
    TOSR_PATH="$_tosr_lock"
    ls() {
      command ls "$@"
      _tosr_ls_rc=$?
      if [ "${TOSR_LS_ONCE:-0}" -eq 1 ]; then
        TOSR_LS_ONCE=0
        rmdir "$TOSR_PATH" 2>/dev/null || :
      fi
      return "$_tosr_ls_rc"
    }
    _tosr_state=$(merv_owner_lock_state "$TOSR_PATH")
    [ "$_tosr_state" = absent ]
  ) && pass "owner state reclassifies post-probe release as absent" ||
    fail "owner state reclassifies post-probe release as absent"
}

test_owner_state_timestamp_release_probe() {
  selftest_reset || return 1
  _totsr_dir="$SELFTEST_ROOT/owner-state-timestamp-release"
  _totsr_lock="$_totsr_dir/claim.lock"
  _totsr_trace="$_totsr_dir/date.trace"
  _totsr_state="$_totsr_dir/state"
  _totsr_state_rc="$_totsr_dir/state.rc"
  _totsr_acquire_rc="$_totsr_dir/acquire.rc"
  _totsr_owner="$_totsr_dir/acquired.owner"
  _totsr_release_rc="$_totsr_dir/release.rc"
  _totsr_output="$_totsr_dir/acquire.output"
  mkdir -p "$_totsr_dir" || return 1
  mkdir "$_totsr_lock" || return 1

  # This hook is intentionally limited to the production mtime form. The
  # initial ls probe and the now/temporary-name date calls remain untouched;
  # only date -r <lock> removes the incomplete claim before date runs.
  (
    TOTS_DATE_ONCE=1
    TOTS_PATH="$_totsr_lock"
    TOTS_TRACE="$_totsr_trace"
    date() {
      printf 'date %s\n' "$*" >> "$TOTS_TRACE"
      if [ "${1:-}" = -r ] && [ "${2:-}" = "$TOTS_PATH" ] &&
         [ "${TOTS_DATE_ONCE:-0}" -eq 1 ]; then
        TOTS_DATE_ONCE=0
        printf '%s\n' remove-at-mtime >> "$TOTS_TRACE"
        rmdir "$TOTS_PATH" 2>/dev/null || :
      fi
      /bin/date "$@"
    }

    merv_owner_lock_state "$TOTS_PATH" > "$_totsr_state" 2>/dev/null
    printf '%s\n' "$?" > "$_totsr_state_rc"

    # Recreate the same incomplete claim and repeat the exact seam through the
    # real acquisition path. A fixed implementation must retry only after the
    # authoritative absence recheck, then publish and release its own owner.
    mkdir "$TOTS_PATH" || exit 70
    TOTS_DATE_ONCE=1
    merv_owner_lock_acquire "$TOTS_PATH" 0 0 timestamp-release > "$_totsr_output" 2>&1
    _totsr_acq_rc=$?
    printf '%s\n' "$_totsr_acq_rc" > "$_totsr_acquire_rc"
    if [ "$_totsr_acq_rc" -eq 0 ] && [ -f "$TOTS_PATH/owner" ]; then
      cp "$TOTS_PATH/owner" "$_totsr_owner" || exit 71
      merv_owner_lock_release "$TOTS_PATH" "$MERV_LOCK_NONCE" > /dev/null 2>&1
      printf '%s\n' "$?" > "$_totsr_release_rc"
    else
      printf '%s\n' not-published > "$_totsr_owner"
      printf '%s\n' not-attempted > "$_totsr_release_rc"
    fi
  )

  _totsr_state_value=$(cat "$_totsr_state" 2>/dev/null || printf '')
  _totsr_state_status=$(cat "$_totsr_state_rc" 2>/dev/null || printf '')
  _totsr_mtime_calls=$(grep -Fxc -- "date -r $_totsr_lock +%s" "$_totsr_trace" 2>/dev/null || printf 0)
  _totsr_remove_calls=$(grep -Fxc -- remove-at-mtime "$_totsr_trace" 2>/dev/null || printf 0)
  case "$_totsr_state_status" in ''|*[!0-9]*) _totsr_state_status=99 ;; esac
  case "$_totsr_mtime_calls" in ''|*[!0-9]*) _totsr_mtime_calls=99 ;; esac
  case "$_totsr_remove_calls" in ''|*[!0-9]*) _totsr_remove_calls=99 ;; esac
  if [ "$_totsr_state_status" -eq 0 ] 2>/dev/null &&
     [ "$_totsr_state_value" = absent ] &&
     [ "$_totsr_mtime_calls" -eq 2 ] 2>/dev/null &&
     [ "$_totsr_remove_calls" -eq 2 ] 2>/dev/null; then
    pass "owner state reclassifies release at timestamp retrieval as absent"
  else
    fail "owner state reclassifies release at timestamp retrieval as absent (state=$_totsr_state_value state_rc=$_totsr_state_status mtime_calls=$_totsr_mtime_calls remove_calls=$_totsr_remove_calls)"
  fi

  _totsr_acq_status=$(cat "$_totsr_acquire_rc" 2>/dev/null || printf '')
  _totsr_release_status=$(cat "$_totsr_release_rc" 2>/dev/null || printf '')
  case "$_totsr_acq_status" in ''|*[!0-9]*) _totsr_acq_status=99 ;; esac
  case "$_totsr_release_status" in ''|*[!0-9]*) _totsr_release_status=99 ;; esac
  if [ "$_totsr_acq_status" -eq 0 ] 2>/dev/null &&
     grep -q '^pid=' "$_totsr_owner" 2>/dev/null &&
     [ "$_totsr_release_status" -eq 0 ] 2>/dev/null &&
     [ ! -e "$_totsr_lock" ]; then
    pass "owner acquisition retries after timestamp-release and releases exact owner"
  else
    fail "owner acquisition retries after timestamp-release and releases exact owner (acquire_rc=$_totsr_acq_status release_rc=$_totsr_release_status state=$_totsr_state_value)"
  fi
}

test_owner_lock_contract() {
  selftest_reset || return 1
  test_owner_state_release_probe || return 1
  test_owner_state_timestamp_release_probe || return 1
  selftest_reset || return 1
  _tol_root="$SELFTEST_ROOT/owner-lock"
  _tol_lock="$_tol_root/claim"
  _tol_owner="$_tol_lock/owner"
  rm -rf "$_tol_root" 2>/dev/null || return 1
  mkdir -p "$_tol_lock" || return 1

  assert_ok "owner v2 writer publishes a valid record" \
    merv_owner_v2_write_atomic "$_tol_lock" "$$" 424242 owner-contract 100 1
  assert_ok "owner v2 parser accepts a valid record" merv_owner_v2_read "$_tol_lock"
  [ "$MERV_OWNER_V2_PID" = "$$" ] &&
    [ "$MERV_OWNER_V2_PROC_START_TIME" = 424242 ] &&
    [ "$MERV_OWNER_V2_NONCE" = owner-contract ] &&
    [ "$MERV_OWNER_V2_CREATED" = 100 ] &&
    [ "$MERV_OWNER_V2_HEARTBEAT" = 1 ] &&
    pass "owner v2 parser exports all five fields" ||
    fail "owner v2 parser exports all five fields"
  [ "$(ls -l "$_tol_owner" 2>/dev/null | awk '{print $1}')" = "-rw-------" ] &&
    pass "owner v2 publication mode is 0600" ||
    fail "owner v2 publication mode is 0600"
  _tol_tmp_left=0
  for _tol_tmp in "$_tol_lock"/.owner.tmp.*; do
    [ -e "$_tol_tmp" ] || continue
    _tol_tmp_left=1
  done
  [ "$_tol_tmp_left" -eq 0 ] && pass "owner v2 publication leaves no temporary owner" ||
    fail "owner v2 publication leaves no temporary owner"

  printf 'pid=%s\nowner_nonce=owner-contract\ncreated=100\nheartbeat=1\n' "$$" > "$_tol_owner"
  assert_rc 1 "owner v2 missing key rejected" merv_owner_v2_read "$_tol_owner"
  printf 'pid=%s\npid=%s\nproc_start_time=424242\nowner_nonce=owner-contract\ncreated=100\nheartbeat=1\n' "$$" "$$" > "$_tol_owner"
  assert_rc 1 "owner v2 duplicate key rejected" merv_owner_v2_read "$_tol_owner"
  printf 'pid=%s\nproc_start_time=424242\nowner_nonce=owner-contract\ncreated=100\nheartbeat=1\nunknown=x\n' "$$" > "$_tol_owner"
  assert_rc 1 "owner v2 unknown key rejected" merv_owner_v2_read "$_tol_owner"
  printf 'pid=not-a-number\nproc_start_time=424242\nowner_nonce=owner-contract\ncreated=100\nheartbeat=1\n' > "$_tol_owner"
  assert_rc 1 "owner v2 non-numeric field rejected" merv_owner_v2_read "$_tol_owner"
  printf 'pid=0\nproc_start_time=424242\nowner_nonce=owner-contract\ncreated=100\nheartbeat=1\n' > "$_tol_owner"
  assert_rc 1 "owner v2 zero numeric field rejected" merv_owner_v2_read "$_tol_owner"
  printf 'pid=%s \nproc_start_time=424242\nowner_nonce=owner-contract\ncreated=100\nheartbeat=1\n' "$$" > "$_tol_owner"
  assert_rc 1 "owner v2 whitespace rejected" merv_owner_v2_read "$_tol_owner"
  printf 'pid=%s\nproc_start_time=424242\nowner_nonce=bad\$nonce\ncreated=100\nheartbeat=1\n' "$$" > "$_tol_owner"
  assert_rc 1 "owner v2 invalid nonce characters rejected" merv_owner_v2_read "$_tol_owner"
  _tol_long_nonce=$(awk 'BEGIN { for (i = 0; i < 161; i++) printf "a" }')
  printf 'pid=%s\nproc_start_time=424242\nowner_nonce=%s\ncreated=100\nheartbeat=1\n' "$$" "$_tol_long_nonce" > "$_tol_owner"
  assert_rc 1 "owner v2 oversized nonce rejected" merv_owner_v2_read "$_tol_owner"
  _tol_long_num=$(awk 'BEGIN { for (i = 0; i < 130; i++) printf "1" }')
  printf 'pid=%s\nproc_start_time=%s\nowner_nonce=owner-contract\ncreated=%s\nheartbeat=%s\n' \
    "$_tol_long_num" "$_tol_long_num" "$_tol_long_num" "$_tol_long_num" > "$_tol_owner"
  assert_rc 1 "owner v2 oversized record rejected" merv_owner_v2_read "$_tol_owner"

  _tol_marker="$_tol_root/not-executed"
  rm -f "$_tol_marker"
  printf 'pid=%s\nproc_start_time=424242\nowner_nonce=\$(touch %s)\ncreated=100\nheartbeat=1\n' "$$" "$_tol_marker" > "$_tol_owner"
  assert_rc 1 "malformed owner record rejected without execution" merv_owner_v2_read "$_tol_owner"
  assert_no_file "$_tol_marker" "malformed owner record is never sourced"

  assert_ok "owner v2 exact live PID/start/nonce match" \
    merv_owner_v2_write_atomic "$_tol_lock" "$$" 424242 owner-contract 100 1
  assert_ok "owner v2 stale heartbeat does not reclaim live owner" \
    merv_owner_v2_matches "$_tol_lock" "$$" 424242 owner-contract "$MERV_DHCP_HOLD_PROC_ROOT"
  assert_rc 1 "owner v2 wrong PID rejected" \
    merv_owner_v2_matches "$_tol_lock" 9001 424242 owner-contract "$MERV_DHCP_HOLD_PROC_ROOT"
  assert_rc 1 "owner v2 wrong start rejected" \
    merv_owner_v2_matches "$_tol_lock" "$$" 424243 owner-contract "$MERV_DHCP_HOLD_PROC_ROOT"
  assert_rc 1 "owner v2 wrong nonce rejected" \
    merv_owner_v2_matches "$_tol_lock" "$$" 424242 other-owner "$MERV_DHCP_HOLD_PROC_ROOT"

  write_fake_stat 9001 123456
  assert_ok "owner v2 distinguishes a second live identity" \
    merv_owner_v2_write_atomic "$_tol_lock" 9001 123456 second-owner 100 1
  assert_ok "owner v2 live identity matches" \
    merv_owner_v2_matches "$_tol_lock" 9001 123456 second-owner "$MERV_DHCP_HOLD_PROC_ROOT"
  rm -rf "$MERV_DHCP_HOLD_PROC_ROOT/9001"
  assert_rc 1 "owner v2 distinguishes a dead identity" \
    merv_owner_v2_matches "$_tol_lock" 9001 123456 second-owner "$MERV_DHCP_HOLD_PROC_ROOT"

  # A pre-owner-aware lock may be a regular file.  It is an obstruction, not
  # an absent directory: acquire must fail immediately instead of retrying the
  # impossible mkdir forever.
  rm -rf "$_tol_lock" 2>/dev/null || return 1
  : > "$_tol_lock" || return 1
  [ "$(merv_owner_lock_state "$_tol_lock")" = unknown ] &&
    pass "regular-file lock obstruction is fail-closed, not absent" ||
    fail "regular-file lock obstruction is fail-closed, not absent"
  assert_rc 1 "regular-file lock obstruction fails bounded acquisition" \
    merv_owner_lock_acquire "$_tol_lock" 0 0 owner-obstruction

  # A lock-root symlink is equally ambiguous, even when it points at a real
  # directory. Never follow it as an owner directory.
  rm -f "$_tol_lock" 2>/dev/null || return 1
  mkdir -p "$_tol_root/symlink-target" || return 1
  ln -s "$_tol_root/symlink-target" "$_tol_lock" || return 1
  [ "$(merv_owner_lock_state "$_tol_lock")" = unknown ] &&
    pass "symlink lock obstruction is fail-closed" ||
    fail "symlink lock obstruction is fail-closed"
  assert_rc 1 "symlink lock obstruction fails bounded acquisition" \
    merv_owner_lock_acquire "$_tol_lock" 0 0 owner-symlink-obstruction

  # A live replacement installed after dead-owner classification must not be
  # moved into the stale quarantine. The hook opens the exact rename window;
  # production verification restores the replacement and fails closed.
  rm -rf "$_tol_lock" "${_tol_lock}.race-original" 2>/dev/null || return 1
  mkdir "$_tol_lock" || return 1
  merv_owner_v2_write_atomic "$_tol_lock" 999999 1 stale-before-replacement 1 1 || return 1
  MERV_OWNER_LOCK_FAULT=quarantine-window
  export MERV_OWNER_LOCK_FAULT
  assert_rc 1 "replacement owner blocks generic stale quarantine" \
    merv_owner_lock_acquire "$_tol_lock" 0 0 owner-replacement-race
  unset MERV_OWNER_LOCK_FAULT
  export MERV_OWNER_LOCK_FAULT
  merv_owner_v2_read "$_tol_lock" 2>/dev/null &&
    [ "$MERV_OWNER_V2_NONCE" = replacement-owner ] &&
    pass "generic replacement owner remains authoritative" ||
    fail "generic replacement owner remains authoritative"
  [ -d "${_tol_lock}.race-original" ] &&
    pass "generic original stale claim is retained for inspection" ||
    fail "generic original stale claim is retained for inspection"
  assert_ok "generic replacement owner releases after failed reclaim" \
    merv_owner_lock_release "$_tol_lock" replacement-owner
  rm -rf "${_tol_lock}.race-original" 2>/dev/null || return 1
}

test_maintenance_lock_interop() {
  selftest_reset || return 1
  _tmi_root="$SELFTEST_ROOT/maintenance-lock-interop"
  _tmi_lock="$_tmi_root/mervlan_maintenance.lock"
  _tmi_recover="$MERV_BASE/functions/mervlan_recover.sh"
  _tmi_base="$MERV_BASE"
  _tmi_ok=1
  rm -rf "$_tmi_root" 2>/dev/null || return 1
  mkdir -p "$_tmi_root" || return 1

  # Recovery must source and exercise its copied protocol even if no settings
  # tree is available.  The generic library remains loaded only for the normal
  # maintenance side of this interoperability fixture.
  MERVLAN_RECOVERY_SOURCE_ONLY=1 MERVLAN_RECOVERY_LOCK_OVERRIDE="$_tmi_lock" \
    MERV_BASE="$SELFTEST_ROOT/no-installed-settings" . "$_tmi_recover" || return 1
  MERV_BASE="$_tmi_base"
  export MERV_BASE
  pass "standalone Recovery loads without installed settings libraries"

  if merv_owner_lock_acquire "$_tmi_lock" 0 0 normal-maintenance &&
     recovery_lock_read && [ "$RECOVERY_LOCK_FORMAT" = v2 ] &&
     ! recovery_acquire_lock; then
    pass "live normal v2 owner blocks standalone Recovery"
  else
    fail "live normal v2 owner blocks standalone Recovery"; _tmi_ok=0
  fi
  _tmi_normal_nonce="$MERV_LOCK_NONCE"
  merv_owner_lock_release "$_tmi_lock" "$_tmi_normal_nonce" || { fail "normal v2 fixture release"; return 1; }

  mkdir "$_tmi_lock" || return 1
  merv_owner_v2_write_atomic "$_tmi_lock" 999999 1 dead-normal 1 1 || return 1
  if recovery_acquire_lock && recovery_owner_v2_read "$_tmi_lock/owner" &&
     [ "$RECOVERY_OWNER_PID" = "$$" ]; then
    pass "Recovery reclaims dead normal v2 with a v2 owner"
  else
    fail "Recovery reclaims dead normal v2 with a v2 owner"; _tmi_ok=0
  fi
  _tmi_recovery_nonce="$RECOVERY_LOCK_NONCE"
  if ! merv_owner_lock_acquire "$_tmi_lock" 0 0 normal-maintenance; then
    pass "Recovery-created live v2 blocks normal maintenance"
  else
    fail "Recovery-created live v2 blocks normal maintenance"; _tmi_ok=0
  fi
  recovery_release_lock || { fail "Recovery-created v2 fixture release"; return 1; }

  recovery_acquire_lock || { fail "dead Recovery v2 fixture acquire"; return 1; }
  recovery_owner_v2_write_atomic 999998 1 dead-recovery 1 1 || return 1
  RECOVERY_LOCK_OWNED=0
  RECOVERY_LOCK_NONCE=''
  if merv_owner_lock_acquire "$_tmi_lock" 0 0 normal-maintenance; then
    pass "normal maintenance reclaims dead Recovery-created v2"
  else
    fail "normal maintenance reclaims dead Recovery-created v2"; _tmi_ok=0
  fi
  _tmi_normal_nonce="$MERV_LOCK_NONCE"
  merv_owner_lock_release "$_tmi_lock" "$_tmi_normal_nonce" || { fail "normal dead Recovery fixture release"; return 1; }

  recovery_acquire_lock || { fail "wrong nonce fixture acquire"; return 1; }
  _tmi_recovery_nonce="$RECOVERY_LOCK_NONCE"
  RECOVERY_LOCK_NONCE=wrong-nonce
  if ! recovery_release_lock && recovery_owner_v2_read "$_tmi_lock/owner"; then
    pass "wrong Recovery nonce preserves authoritative owner"
  else
    fail "wrong Recovery nonce preserves authoritative owner"; _tmi_ok=0
  fi
  RECOVERY_LOCK_NONCE="$_tmi_recovery_nonce"
  recovery_release_lock || { fail "wrong nonce fixture cleanup"; return 1; }

  mkdir "$_tmi_lock" || return 1
  printf 'pid=%s\nproc_start_time=1\nowner_nonce=bad-v2\ncreated=1\n' "$$" > "$_tmi_lock/owner"
  if ! recovery_acquire_lock; then
    pass "malformed v2 owner fails closed in Recovery"
  else
    fail "malformed v2 owner fails closed in Recovery"; _tmi_ok=0
  fi
  rm -f "$_tmi_lock/owner" || return 1
  rmdir "$_tmi_lock" || return 1

  _tmi_start=$(recovery_proc_start "$$" 2>/dev/null) || return 1
  mkdir "$_tmi_lock" || return 1
  printf 'pid=%s\nstart=%s\nnonce=legacy-live\ncreated=1\n' "$$" "$_tmi_start" > "$_tmi_lock/owner"
  if ! recovery_acquire_lock; then
    pass "complete live four-field legacy owner is respected"
  else
    fail "complete live four-field legacy owner is respected"; _tmi_ok=0
  fi
  rm -f "$_tmi_lock/owner" || return 1
  rmdir "$_tmi_lock" || return 1

  mkdir "$_tmi_lock" || return 1
  printf 'pid=999997\nstart=1\nnonce=legacy-dead\ncreated=1\n' > "$_tmi_lock/owner"
  if recovery_acquire_lock; then
    _tmi_legacy_quarantine=0
    for _tmi_quarantine in "$_tmi_root"/mervlan_maintenance.lock.quarantine.dead.*; do
      [ -d "$_tmi_quarantine" ] && _tmi_legacy_quarantine=1
    done
    [ "$_tmi_legacy_quarantine" -eq 1 ] && pass "dead four-field legacy owner is quarantined" || {
      fail "dead four-field legacy owner is quarantined"; _tmi_ok=0;
    }
  else
    fail "dead four-field legacy owner is reclaimed"; _tmi_ok=0
  fi
  recovery_release_lock || { fail "legacy dead fixture cleanup"; return 1; }

  recovery_acquire_lock || { fail "release restoration fixture acquire"; return 1; }
  _tmi_recovery_nonce="$RECOVERY_LOCK_NONCE"
  : > "$_tmi_lock/release-obstruction"
  if ! recovery_release_lock && recovery_owner_v2_read "$_tmi_lock/owner"; then
    pass "failed Recovery release restores authoritative v2 owner"
  else
    fail "failed Recovery release restores authoritative v2 owner"; _tmi_ok=0
  fi
  rm -f "$_tmi_lock/release-obstruction" || return 1
  RECOVERY_LOCK_NONCE="$_tmi_recovery_nonce"
  recovery_release_lock || { fail "release restoration fixture cleanup"; return 1; }
  return "$_tmi_ok"
}

test_lock_publication() {
  selftest_reset || return 1
  _tlp_root="$SELFTEST_ROOT/lock-publication"
  _tlp_lock="$_tlp_root/claim.lock"
  rm -rf "$_tlp_root" 2>/dev/null || return 1
  mkdir -p "$_tlp_root" || return 1

  assert_ok "generic acquisition publishes a complete owner" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  _tlp_nonce="$MERV_LOCK_NONCE"
  [ -n "$_tlp_nonce" ] && merv_owner_v2_read "$_tlp_lock" &&
    [ "$MERV_OWNER_V2_PID" = "$$" ] && [ "$MERV_OWNER_V2_NONCE" = "$_tlp_nonce" ] &&
    pass "generic acquisition exposes exact owner outputs" ||
    fail "generic acquisition exposes exact owner outputs"
  _tlp_compat_ok=1
  for _tlp_field in pid proc_start_time owner_nonce created heartbeat; do
    [ -f "$_tlp_lock/$_tlp_field" ] || _tlp_compat_ok=0
  done
  [ "$_tlp_compat_ok" -eq 1 ] && pass "generic acquisition retains compatibility sidecars" ||
    fail "generic acquisition retains compatibility sidecars"
  assert_rc 1 "wrong nonce cannot release generic lock" \
    merv_owner_lock_release "$_tlp_lock" wrong-nonce
  assert_file "$_tlp_lock/owner" "wrong nonce preserves authoritative owner"
  assert_rc 1 "live generic owner is never stolen because of age" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  assert_ok "generic owner releases by exact nonce" merv_owner_lock_release "$_tlp_lock" "$_tlp_nonce"
  assert_no_file "$_tlp_lock" "exact generic release removes lock directory"

  for _tlp_fault in identity compat-write compat-rename owner-temp-write owner-permissions owner-rename; do
    MERV_OWNER_LOCK_FAULT="$_tlp_fault"
    export MERV_OWNER_LOCK_FAULT
    assert_rc 1 "publication fault $_tlp_fault fails acquisition" \
      merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
    assert_no_file "$_tlp_lock" "publication fault $_tlp_fault leaves no active claim"
    unset MERV_OWNER_LOCK_FAULT
    export MERV_OWNER_LOCK_FAULT
  done

  MERV_OWNER_LOCK_FAULT=owner-temp-write,cleanup-rmdir
  export MERV_OWNER_LOCK_FAULT
  assert_rc 1 "claim cleanup obstruction fails acquisition" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  unset MERV_OWNER_LOCK_FAULT
  export MERV_OWNER_LOCK_FAULT
  assert_no_file "$_tlp_lock" "cleanup obstruction leaves no active claim"
  _tlp_quarantined=0
  for _tlp_dir in "$_tlp_root"/.claim.lock.acquire-failed.*; do
    [ -d "$_tlp_dir" ] || continue
    _tlp_quarantined=1
  done
  [ "$_tlp_quarantined" -eq 1 ] && pass "failed claim is quarantined exactly" ||
    fail "failed claim is quarantined exactly"

  mkdir "$_tlp_lock" || return 1
  _tlp_state=$(merv_owner_lock_state "$_tlp_lock")
  [ "$_tlp_state" = incomplete-grace ] && pass "new incomplete claim is inside verified grace" ||
    fail "new incomplete claim is inside verified grace (state=$_tlp_state)"
  MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=invalid
  export MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC
  _tlp_state=$(merv_owner_lock_state "$_tlp_lock")
  [ "$_tlp_state" = incomplete-unknown ] && pass "unverifiable incomplete age fails closed" ||
    fail "unverifiable incomplete age fails closed (state=$_tlp_state)"
  MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=0
  export MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC
  sleep 1
  _tlp_state=$(merv_owner_lock_state "$_tlp_lock")
  [ "$_tlp_state" = incomplete-expired ] && pass "expired incomplete claim is classified" ||
    fail "expired incomplete claim is classified (state=$_tlp_state)"
  assert_rc 1 "expired incomplete claim is not automatically reclaimed" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  rmdir "$_tlp_lock" || return 1
  MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC=10
  export MERV_OWNER_LOCK_PUBLICATION_GRACE_SEC

  mkdir "$_tlp_lock" || return 1
  assert_ok "dead complete owner is published for reclaim fixture" \
    merv_owner_v2_write_atomic "$_tlp_lock" 999999 1 dead-owner 1 1
  assert_ok "dead complete owner is quarantined and reacquired" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  _tlp_dead_nonce="$MERV_LOCK_NONCE"
  assert_ok "dead-owner reacquisition releases" merv_owner_lock_release "$_tlp_lock" "$_tlp_dead_nonce"

  mkdir "$_tlp_lock" || return 1
  assert_ok "reused PID fixture is published" \
    merv_owner_v2_write_atomic "$_tlp_lock" "$$" 1 reused-owner 1 1
  assert_ok "reused PID owner is quarantined and reacquired" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  _tlp_reused_nonce="$MERV_LOCK_NONCE"
  assert_ok "reused-PID reacquisition releases" merv_owner_lock_release "$_tlp_lock" "$_tlp_reused_nonce"

  mkdir "$_tlp_lock" || return 1
  printf 'not an owner record\n' > "$_tlp_lock/owner"
  assert_rc 1 "malformed complete state fails closed" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  rm -f "$_tlp_lock/owner" || return 1
  rmdir "$_tlp_lock" || return 1

  assert_ok "release obstruction fixture acquires" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  _tlp_release_nonce="$MERV_LOCK_NONCE"
  : > "$_tlp_lock/release-obstruction"
  assert_rc 1 "release obstruction restores authoritative owner" \
    merv_owner_lock_release "$_tlp_lock" "$_tlp_release_nonce"
  assert_ok "release obstruction keeps owner recoverable" merv_owner_v2_read "$_tlp_lock"
  [ ! -e "$_tlp_lock/pid" ] && [ ! -e "$_tlp_lock/proc_start_time" ] &&
    pass "failed release restores no obsolete compatibility sidecars" ||
    fail "failed release restores no obsolete compatibility sidecars"
  rm -f "$_tlp_lock/release-obstruction" || return 1
  assert_ok "restored owner can release after obstruction clears" \
    merv_owner_lock_release "$_tlp_lock" "$_tlp_release_nonce"

  assert_ok "rapid reacquisition obtains first owner" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  _tlp_old_nonce="$MERV_LOCK_NONCE"
  assert_ok "first rapid owner releases" merv_owner_lock_release "$_tlp_lock" "$_tlp_old_nonce"
  assert_ok "rapid reacquisition obtains second owner" \
    merv_owner_lock_acquire "$_tlp_lock" 0 0 publication
  _tlp_new_nonce="$MERV_LOCK_NONCE"
  assert_rc 1 "old nonce cannot release rapid reacquisition" \
    merv_owner_lock_release "$_tlp_lock" "$_tlp_old_nonce"
  assert_ok "current rapid owner releases" merv_owner_lock_release "$_tlp_lock" "$_tlp_new_nonce"
}

test_nonce_uniqueness() {
  selftest_reset || return 1
  _tn_ok=1
  _tn_seen=""
  _tn_seq_before="${MERV_IDENTITY_NONCE_SEQ:-}"
  . "$MERV_BASE/settings/lib_identity.sh" || _tn_ok=0
  [ "${MERV_IDENTITY_NONCE_SEQ:-}" = "$_tn_seq_before" ] &&
    pass "identity library repeated sourcing is idempotent" || {
      fail "identity library repeated sourcing is idempotent"
      _tn_ok=0
    }

  if grep -q 'RANDOM' "$MERV_BASE/settings/lib_identity.sh" 2>/dev/null; then
    fail "identity nonce has no RANDOM dependency"
    _tn_ok=0
  else
    pass "identity nonce has no RANDOM dependency"
  fi

  MERV_IDENTITY_NONCE_SEQ=0
  unset MERV_IDENTITY_NONCE
  _tn_i=1
  while [ "$_tn_i" -le 100 ]; do
    if merv_identity_nonce_next; then
      _tn_nonce="$MERV_IDENTITY_NONCE"
      if ! merv_identity_nonce_valid "$_tn_nonce"; then
        fail "rapid nonce $_tn_i has valid format"
        _tn_ok=0
      fi
      case " $_tn_seen " in
        *" $_tn_nonce "*)
          fail "rapid same-process nonces are unique"
          _tn_ok=0
          ;;
        *) _tn_seen="$_tn_seen $_tn_nonce" ;;
      esac
    else
      fail "rapid nonce $_tn_i generated in current shell"
      _tn_ok=0
    fi
    _tn_i=$((_tn_i + 1))
  done
  [ "$(printf '%s' "$_tn_seen" | awk '{print NF}')" -eq 100 ] &&
    pass "100 rapid same-process nonces are unique" || {
      fail "100 rapid same-process nonces are unique"
      _tn_ok=0
    }

  write_fake_stat 9001 123456
  write_fake_stat 9002 0
  if merv_identity_proc_start 9001 "$MERV_DHCP_HOLD_PROC_ROOT" >/dev/null 2>&1; then
    pass "positive PID/start identity is readable"
  else
    fail "positive PID/start identity is readable"
    _tn_ok=0
  fi
  if merv_identity_matches 9001 123456 "$MERV_DHCP_HOLD_PROC_ROOT"; then
    pass "exact PID/start identity matches"
  else
    fail "exact PID/start identity matches"
    _tn_ok=0
  fi
  for _tn_case in \
    "zero PID:merv_identity_proc_start 0 $MERV_DHCP_HOLD_PROC_ROOT" \
    "zero-padded PID:merv_identity_proc_start 00 $MERV_DHCP_HOLD_PROC_ROOT" \
    "zero start:merv_identity_proc_start 9002 $MERV_DHCP_HOLD_PROC_ROOT" \
    "missing start:merv_identity_matches 9001 '' $MERV_DHCP_HOLD_PROC_ROOT" \
    "zero expected start:merv_identity_matches 9001 0 $MERV_DHCP_HOLD_PROC_ROOT" \
    "mismatched start:merv_identity_matches 9001 654321 $MERV_DHCP_HOLD_PROC_ROOT"; do
    _tn_label=${_tn_case%%:*}
    _tn_cmd=${_tn_case#*:}
    # The command strings contain only fixed test arguments, so this keeps the
    # selector readable while retaining assert-style diagnostics.
    if sh -c ". \"$MERV_BASE/settings/lib_identity.sh\"; $_tn_cmd" >/dev/null 2>&1; then
      fail "identity rejects $_tn_label"
      _tn_ok=0
    else
      pass "identity rejects $_tn_label"
    fi
  done

  _tn_one="$SELFTEST_ROOT/nonce-parallel.1"
  _tn_two="$SELFTEST_ROOT/nonce-parallel.2"
  rm -f "$_tn_one" "$_tn_two"
  MERV_IDENTITY_LIB="$MERV_BASE/settings/lib_identity.sh" sh -c '
    . "$MERV_IDENTITY_LIB" || exit 2
    _tn_start=$(merv_identity_current_start) || exit 3
    printf "%s:%s\n" "$$" "$_tn_start"
    sleep 1
  ' > "$_tn_one" 2>/dev/null &
  _tn_p1=$!
  MERV_IDENTITY_LIB="$MERV_BASE/settings/lib_identity.sh" sh -c '
    . "$MERV_IDENTITY_LIB" || exit 2
    _tn_start=$(merv_identity_current_start) || exit 3
    printf "%s:%s\n" "$$" "$_tn_start"
    sleep 1
  ' > "$_tn_two" 2>/dev/null &
  _tn_p2=$!
  sleep 1
  _tn_id1=$(sed -n '1p' "$_tn_one" 2>/dev/null)
  _tn_id2=$(sed -n '1p' "$_tn_two" 2>/dev/null)
  _tn_pid1=${_tn_id1%%:*}
  _tn_start1=${_tn_id1#*:}
  _tn_pid2=${_tn_id2%%:*}
  _tn_start2=${_tn_id2#*:}
  if merv_identity_positive_uint "$_tn_pid1" &&
     merv_identity_positive_uint "$_tn_start1" &&
     merv_identity_positive_uint "$_tn_pid2" &&
     merv_identity_positive_uint "$_tn_start2"; then
    pass "parallel process PID/start identities are positive"
  else
    fail "parallel process PID/start identities are positive"
    _tn_ok=0
  fi
  [ -n "$_tn_id1" ] && [ "$_tn_id1" != "$_tn_id2" ] &&
    pass "parallel processes differ through PID/start identity" || {
      fail "parallel processes differ through PID/start identity"
      _tn_ok=0
    }
  wait "$_tn_p1" 2>/dev/null || _tn_ok=0
  wait "$_tn_p2" 2>/dev/null || _tn_ok=0
  return "$_tn_ok"
}

test_lock_reclaim() {
  selftest_reset || return 1
  _tlr_lock="$SELFTEST_STATE/state.lock"
  mkdir -p "$_tlr_lock"
  printf '%s\n' "$$" > "$_tlr_lock/pid"
  printf '1\n' > "$_tlr_lock/proc_start_time"
  printf '1\n' > "$_tlr_lock/created_epoch"
  printf 'old\n' > "$_tlr_lock/owner_nonce"
  assert_ok "reused-PID lock is quarantined and reacquired" merv_dhcp_state_lock_acquire
  _tlr_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _tlr_quarantine_found=0
  for _tlr_quarantine in "$SELFTEST_STATE"/state.lock.stale.*; do
    [ -d "$_tlr_quarantine" ] || continue
    _tlr_quarantine_found=1
    break
  done
  [ "$_tlr_quarantine_found" -eq 1 ] && pass "dead lock quarantine retained" ||
    fail "dead lock quarantine missing"
  assert_rc 2 "wrong nonce cannot release lock" merv_dhcp_state_lock_release wrong-nonce
  assert_file "$_tlr_lock" "wrong nonce leaves lock intact"
  assert_ok "owner nonce releases lock" merv_dhcp_state_lock_release "$_tlr_nonce"

  assert_ok "contention fixture acquires live state lock" merv_dhcp_state_lock_acquire
  _tlr_live_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  (
    if type usleep >/dev/null 2>&1; then usleep 200000; else sleep 1; fi
    [ "$(cat "$SELFTEST_STATE/state.lock/owner_nonce" 2>/dev/null)" = "$_tlr_live_nonce" ] || exit 1
    rm -f "$SELFTEST_STATE/state.lock/pid" "$SELFTEST_STATE/state.lock/proc_start_time" \
      "$SELFTEST_STATE/state.lock/created_epoch" "$SELFTEST_STATE/state.lock/owner_nonce"
    rmdir "$SELFTEST_STATE/state.lock"
  ) &
  assert_ok "matching live state lock is bounded-waited, never stolen" \
    merv_dhcp_state_lock_acquire
  _tlr_wait_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  assert_ok "waited state lock releases by its nonce" \
    merv_dhcp_state_lock_release "$_tlr_wait_nonce"

  mkdir -p "$_tlr_lock"
  printf '%s\n' "$$" > "$_tlr_lock/pid"
  printf '424242\n' > "$_tlr_lock/proc_start_time"
  printf '1\n' > "$_tlr_lock/created_epoch"
  printf 'live\n' > "$_tlr_lock/owner_nonce"
  assert_rc 2 "matching live lock is not stolen because of age" merv_dhcp_state_lock_acquire
  [ "$(cat "$_tlr_lock/owner_nonce")" = live ] && pass "live lock identity preserved" || fail "live lock was replaced"
  rm -f "$_tlr_lock/pid" "$_tlr_lock/proc_start_time" "$_tlr_lock/created_epoch" "$_tlr_lock/owner_nonce"
  rmdir "$_tlr_lock"

  mkdir -p "$_tlr_lock"
  MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC=0
  export MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
  assert_ok "dead incomplete lock is quarantined after its stale threshold" \
    merv_dhcp_state_lock_acquire
  _tlr_incomplete_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  unset MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
  export MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
  _tlr_incomplete_found=0
  for _tlr_quarantine in "$SELFTEST_STATE"/state.lock.incomplete-stale.*; do
    [ -d "$_tlr_quarantine" ] || continue
    _tlr_incomplete_found=1
    break
  done
  [ "$_tlr_incomplete_found" -eq 1 ] && pass "incomplete lock quarantine retained" ||
    fail "incomplete lock quarantine missing"
  assert_ok "reclaimed incomplete lock releases by nonce" \
    merv_dhcp_state_lock_release "$_tlr_incomplete_nonce"
}

test_dhcp_incomplete_lock() {
  selftest_reset || return 1
  _tdil_lock="$SELFTEST_STATE/state.lock"

  # A timestamp read can lose a release race. The replacement timestamp helper
  # removes the real lock before failing; acquisition may retry only after the
  # authoritative non-following absence probe succeeds, and must not warn.
  mkdir "$_tdil_lock" || return 1
  _tdil_absent_output=$( \
    merv_dhcp_state_lock_timestamp() { rmdir "$_tdil_lock" 2>/dev/null || :; return 1; }
    merv_dhcp_state_lock_acquire
  ) 2>&1
  _tdil_absent_rc=$?
  if [ "$_tdil_absent_rc" -eq 0 ] && [ -z "$_tdil_absent_output" ] &&
     [ -d "$_tdil_lock" ] && [ -f "$_tdil_lock/owner_nonce" ]; then
    pass "timestamp failure retries only after verified lock absence"
  else
    fail "timestamp failure retries only after verified lock absence"
  fi
  _tdil_nonce=$(cat "$_tdil_lock/owner_nonce" 2>/dev/null || printf '')
  assert_ok "timestamp-race successor releases by exact nonce" \
    merv_dhcp_state_lock_release "$_tdil_nonce"

  # An unreadable timestamp with the lock still present must warn and retain the
  # claim; no retry or reclaim is allowed from an ambiguous observation.
  mkdir "$_tdil_lock" || return 1
  _tdil_retain_log_root="$SELFTEST_ROOT/dhcp-retain-logs"
  _tdil_retain_log="$_tdil_retain_log_root/vlan.log"
  mkdir -p "$_tdil_retain_log_root" || return 1
  _tdil_retain_output=$( \
    LOGROOT="$_tdil_retain_log_root"
    LOG_chan_cli="$_tdil_retain_log_root/cli.log"
    LOG_chan_vlan="$_tdil_retain_log"
    LOG_SYSLOG=0
    unset LOG_SETTINGS_LOADED
    . "$MERV_BASE/settings/log_settings.sh" || exit 2
    merv_dhcp_state_lock_timestamp() { return 1; }
    merv_dhcp_state_lock_acquire
  ) 2>&1
  _tdil_retain_rc=$?
  if [ "$_tdil_retain_rc" -eq 2 ] && [ -d "$_tdil_lock" ] &&
     [ -f "$_tdil_retain_log" ] &&
     grep -q 'age is unverifiable' "$_tdil_retain_log"; then
    pass "timestamp failure with retained lock warns without reclaim"
  else
    fail "timestamp failure with retained lock warns without reclaim"
  fi
  rmdir "$_tdil_lock" || return 1

  # Open the exact complete-owner quarantine window. A live replacement must
  # remain at state.lock while the stale predecessor is retained separately.
  mkdir "$_tdil_lock" || return 1
  printf '999999\n1\n1\ndead-before-replacement\n' | {
    IFS= read -r _tdil_pid
    IFS= read -r _tdil_start
    IFS= read -r _tdil_created
    IFS= read -r _tdil_nonce
    printf '%s\n' "$_tdil_pid" > "$_tdil_lock/pid"
    printf '%s\n' "$_tdil_start" > "$_tdil_lock/proc_start_time"
    printf '%s\n' "$_tdil_created" > "$_tdil_lock/created_epoch"
    printf '%s\n' "$_tdil_nonce" > "$_tdil_lock/owner_nonce"
  }
  MERV_DHCP_STATE_LOCK_FAULT=quarantine-window
  export MERV_DHCP_STATE_LOCK_FAULT
  assert_rc 2 "replacement owner blocks DHCP stale quarantine" merv_dhcp_state_lock_acquire
  unset MERV_DHCP_STATE_LOCK_FAULT
  export MERV_DHCP_STATE_LOCK_FAULT
  if [ "$(cat "$_tdil_lock/pid" 2>/dev/null)" = "$$" ] &&
     [ "$(cat "$_tdil_lock/owner_nonce" 2>/dev/null)" = replacement-owner ]; then
    pass "DHCP replacement owner remains authoritative"
  else
    fail "DHCP replacement owner remains authoritative"
  fi
  [ -d "${_tdil_lock}.race-original" ] &&
    pass "DHCP stale predecessor is retained for inspection" ||
    fail "DHCP stale predecessor is retained for inspection"
  assert_ok "DHCP replacement owner releases after failed reclaim" \
    merv_dhcp_state_lock_release replacement-owner
  rm -rf "${_tdil_lock}.race-original" 2>/dev/null || return 1

  # A just-published empty claim must remain protected long enough for its
  # writer to complete. Its owner removes it, after which this waiter may
  # acquire; a premature quarantine would leave an incomplete quarantine.
  mkdir "$_tdil_lock" || return 1
  MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC=30
  export MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
  (
    if type usleep >/dev/null 2>&1; then usleep 200000; else sleep 1; fi
    rmdir "$_tdil_lock"
  ) &
  assert_ok "fresh empty DHCP claim is protected, then released by publisher" \
    merv_dhcp_state_lock_acquire
  _tdil_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  assert_ok "fresh empty claim successor releases by exact nonce" \
    merv_dhcp_state_lock_release "$_tdil_nonce"

  # Expired incomplete state is never granted a PID-only exception.
  mkdir "$_tdil_lock" || return 1
  MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC=0
  export MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
  assert_ok "expired empty DHCP claim is quarantined" merv_dhcp_state_lock_acquire
  _tdil_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  _tdil_found=0
  for _tdil_quarantine in "$SELFTEST_STATE"/state.lock.incomplete-stale.*; do
    [ -d "$_tdil_quarantine" ] || continue
    _tdil_found=1
  done
  [ "$_tdil_found" -eq 1 ] && pass "expired empty claim quarantine retained" ||
    fail "expired empty claim quarantine missing"
  assert_ok "expired empty claim successor releases by exact nonce" \
    merv_dhcp_state_lock_release "$_tdil_nonce"

  mkdir "$_tdil_lock" || return 1
  printf '%s\n' "$$" > "$_tdil_lock/pid"
  MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC=30
  export MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
  (
    if type usleep >/dev/null 2>&1; then usleep 200000; else sleep 1; fi
    rm -f "$_tdil_lock/pid"
    rmdir "$_tdil_lock"
  ) &
  assert_ok "fresh PID-only DHCP claim is temporarily protected" \
    merv_dhcp_state_lock_acquire
  _tdil_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  assert_ok "fresh PID-only successor releases by exact nonce" \
    merv_dhcp_state_lock_release "$_tdil_nonce"

  mkdir "$_tdil_lock" || return 1
  printf '%s\n' "$$" > "$_tdil_lock/pid"
  MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC=0
  export MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
  assert_ok "expired PID-only DHCP claim is quarantined" merv_dhcp_state_lock_acquire
  _tdil_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  assert_ok "expired PID-only successor releases by exact nonce" \
    merv_dhcp_state_lock_release "$_tdil_nonce"

  mkdir "$_tdil_lock" || return 1
  printf '%s\n' "$$" > "$_tdil_lock/pid"
  printf '424242\n' > "$_tdil_lock/proc_start_time"
  printf '1\n' > "$_tdil_lock/created_epoch"
  printf 'live-owner\n' > "$_tdil_lock/owner_nonce"
  assert_rc 2 "complete live DHCP owner is never stolen" merv_dhcp_state_lock_acquire
  rm -f "$_tdil_lock/pid" "$_tdil_lock/proc_start_time" "$_tdil_lock/created_epoch" "$_tdil_lock/owner_nonce"
  rmdir "$_tdil_lock" || return 1

  mkdir "$_tdil_lock" || return 1
  printf '999999\n1\n1\ndead-owner\n' | {
    IFS= read -r _tdil_pid
    IFS= read -r _tdil_start
    IFS= read -r _tdil_created
    IFS= read -r _tdil_dead_nonce
    printf '%s\n' "$_tdil_pid" > "$_tdil_lock/pid"
    printf '%s\n' "$_tdil_start" > "$_tdil_lock/proc_start_time"
    printf '%s\n' "$_tdil_created" > "$_tdil_lock/created_epoch"
    printf '%s\n' "$_tdil_dead_nonce" > "$_tdil_lock/owner_nonce"
  }
  assert_ok "dead complete DHCP owner is quarantined" merv_dhcp_state_lock_acquire
  _tdil_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  assert_ok "dead-owner successor releases by exact nonce" \
    merv_dhcp_state_lock_release "$_tdil_nonce"

  mkdir "$_tdil_lock" || return 1
  printf '%s\n' "$$" > "$_tdil_lock/pid"
  printf '1\n' > "$_tdil_lock/proc_start_time"
  printf '1\n' > "$_tdil_lock/created_epoch"
  printf 'reused-owner\n' > "$_tdil_lock/owner_nonce"
  assert_ok "reused-PID DHCP owner is quarantined" merv_dhcp_state_lock_acquire
  _tdil_nonce="$MERV_DHCP_STATE_LOCK_NONCE"
  assert_rc 2 "wrong DHCP state-lock nonce is rejected" \
    merv_dhcp_state_lock_release wrong-nonce
  : > "$_tdil_lock/release-obstruction"
  assert_rc 2 "release obstruction restores complete DHCP ownership" \
    merv_dhcp_state_lock_release "$_tdil_nonce"
  _tdil_restored=1
  [ "$(cat "$_tdil_lock/pid" 2>/dev/null)" = "$$" ] || _tdil_restored=0
  [ "$(cat "$_tdil_lock/proc_start_time" 2>/dev/null)" = 424242 ] || _tdil_restored=0
  [ "$(cat "$_tdil_lock/created_epoch" 2>/dev/null)" -gt 0 ] 2>/dev/null || _tdil_restored=0
  [ "$(cat "$_tdil_lock/owner_nonce" 2>/dev/null)" = "$_tdil_nonce" ] || _tdil_restored=0
  [ "$_tdil_restored" -eq 1 ] && pass "release obstruction keeps exact owner fields recoverable" ||
    fail "release obstruction did not restore exact owner fields"
  rm -f "$_tdil_lock/release-obstruction" || return 1
  assert_ok "restored DHCP owner releases after obstruction clears" \
    merv_dhcp_state_lock_release "$_tdil_nonce"
  unset MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
  export MERV_DHCP_STATE_LOCK_INCOMPLETE_STALE_SEC
}

test_router_portability() {
  selftest_reset || return 1
  _trp_lib="$MERV_BASE/settings/lib_mervqt.sh"
  _trp_update="$MERV_BASE/functions/update_mervlan.sh"
  if grep -q 'stat -c' "$_trp_lib" "$_trp_update" 2>/dev/null; then
    fail "DHCP and GUI Update portability paths have no stat -c dependency"
  else
    pass "DHCP and GUI Update portability paths have no stat -c dependency"
  fi
  mkdir "$SELFTEST_STATE/state.lock" || return 1
  _trp_epoch=$(merv_dhcp_state_lock_timestamp "$SELFTEST_STATE/state.lock" 2>/dev/null)
  case "$_trp_epoch" in ''|*[!0-9]*) fail "portable DHCP timestamp is validated" ;; *) pass "portable DHCP timestamp is validated" ;; esac
  assert_rc 1 "unreadable DHCP state-lock timestamp fails closed" \
    merv_dhcp_state_lock_incomplete_age "$SELFTEST_STATE/missing.lock"
  [ "${MERV_DHCP_STATE_LOCK_INCOMPLETE_REASON:-}" = incomplete-age-timestamp-unreadable ] &&
    pass "unreadable timestamp preserves exact internal reason" ||
    fail "unreadable timestamp reason was lost"
  rmdir "$SELFTEST_STATE/state.lock" || return 1
}

test_ready_owner_count() {
  _troc_count=0
  for _troc_dir in "$SELFTEST_STATE/owners/"*; do
    [ -d "$_troc_dir" ] && [ -f "$_troc_dir/ready" ] || continue
    _troc_count=$((_troc_count + 1))
  done
  printf '%s\n' "$_troc_count"
}

test_failsafe_count() {
  _tfc_count=0
  for _tfc_dir in "$SELFTEST_STATE/failsafe/"*; do
    [ -d "$_tfc_dir" ] && [ -f "$_tfc_dir/ready" ] || continue
    _tfc_count=$((_tfc_count + 1))
  done
  printf '%s\n' "$_tfc_count"
}

test_dhcp_owners() {
  selftest_reset || return 1
  assert_ok "first token owner acquires" merv_dhcp_hold_acquire manager owner-one
  _tdo_one="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "second token owner acquires" merv_dhcp_hold_acquire recovery owner-two
  _tdo_two="$MERV_DHCP_HOLD_TOKEN"
  [ "$(test_ready_owner_count)" -eq 2 ] && pass "two owners coexist" || fail "two owners coexist"
  assert_ok "first owner releases only itself" merv_dhcp_hold_release "$_tdo_one"
  [ "$(test_ready_owner_count)" -eq 1 ] && pass "one owner remains" || fail "one owner remains"
  assert_ok "remaining owner retains exact rules" merv_dhcp_hold_rules_present
  assert_ok "last protected owner releases" merv_dhcp_hold_release "$_tdo_two"
  [ "$(test_ready_owner_count)" -eq 0 ] && pass "last owner removed" || fail "last owner removed"
  assert_ok "last owner cleanup removes rules" merv_dhcp_hold_rules_absent

  assert_ok "ownership-mismatch test owner acquires" merv_dhcp_hold_acquire manager mismatch-owner
  _tdo_mismatch="$MERV_DHCP_HOLD_TOKEN"
  _tdo_owner_dir="$SELFTEST_STATE/owners/$_tdo_mismatch"
  printf '9001\n' > "$_tdo_owner_dir/pid"
  printf '123456\n' > "$_tdo_owner_dir/proc_start_time"
  assert_rc 1 "token cannot release another process identity" merv_dhcp_hold_release "$_tdo_mismatch"
  assert_file "$_tdo_owner_dir/ready" "ownership mismatch leaves lease intact"
  printf '%s\n' "$$" > "$_tdo_owner_dir/pid"
  printf '424242\n' > "$_tdo_owner_dir/proc_start_time"
  assert_ok "restored owner identity can release" merv_dhcp_hold_release "$_tdo_mismatch"
}

test_dhcp_phases() {
  selftest_reset || return 1
  assert_ok "phase owner acquires protected" merv_dhcp_hold_acquire manager phase-run
  _tdp_token="$MERV_DHCP_HOLD_TOKEN"
  [ "$(cat "$SELFTEST_STATE/owners/$_tdp_token/phase")" = protected ] &&
    pass "initial phase is protected" || fail "initial phase is protected"
  assert_ok "owner marks mutating" merv_dhcp_hold_mark_mutating "$_tdp_token" bridge-cleanup
  assert_rc 5 "unsafe mutating release refused" merv_dhcp_hold_release "$_tdp_token"
  assert_ok "mutating abandon converts to failsafe" merv_dhcp_hold_abandon "$_tdp_token" signal-exit
  [ "$(test_ready_owner_count)" -eq 0 ] && pass "abandoned owner retired" || fail "abandoned owner retired"
  [ "$(test_failsafe_count)" -eq 1 ] && pass "security failsafe retained" || fail "security failsafe retained"
  assert_ok "failsafe retains exact rules" merv_dhcp_hold_rules_present
  assert_file "$SELFTEST_STATE/recovery.pending" "failsafe queues recovery"

  selftest_reset || return 1
  assert_ok "verified owner acquires" merv_dhcp_hold_acquire manager verified-run
  _tdp_verified="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "verified owner marks mutating" merv_dhcp_hold_mark_mutating "$_tdp_verified" bridge-cleanup
  assert_ok "owner records final verification" merv_dhcp_hold_mark_verified "$_tdp_verified" verification-1
  assert_ok "verified owner releases" merv_dhcp_hold_release "$_tdp_verified"
  assert_ok "verified last release removes rules" merv_dhcp_hold_rules_absent

  selftest_reset || return 1
  assert_ok "dead protected owner acquires" merv_dhcp_hold_acquire manager dead-protected
  _tdp_dead="$MERV_DHCP_HOLD_TOKEN"
  printf '1\n' > "$SELFTEST_STATE/owners/$_tdp_dead/proc_start_time"
  assert_ok "reconcile cleans dead protected owner" merv_dhcp_hold_reconcile dead-protected
  [ "$(test_ready_owner_count)" -eq 0 ] && pass "dead protected owner removed" || fail "dead protected owner removed"
  [ "$(test_failsafe_count)" -eq 0 ] && pass "dead protected owner creates no failsafe" || fail "dead protected owner creates no failsafe"
  assert_ok "dead protected cleanup removes rules" merv_dhcp_hold_rules_absent

  selftest_reset || return 1
  assert_ok "dead mutating owner acquires" merv_dhcp_hold_acquire manager dead-mutating
  _tdp_dead_mut="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "dead mutating owner marks phase" merv_dhcp_hold_mark_mutating "$_tdp_dead_mut" bridge-cleanup
  printf '1\n' > "$SELFTEST_STATE/owners/$_tdp_dead_mut/proc_start_time"
  assert_ok "reconcile handles dead mutating owner" merv_dhcp_hold_reconcile dead-mutating
  [ "$(test_ready_owner_count)" -eq 0 ] && pass "dead mutating owner retired" || fail "dead mutating owner retired"
  [ "$(test_failsafe_count)" -eq 1 ] && pass "dead mutating owner becomes failsafe" || fail "dead mutating owner becomes failsafe"
  assert_ok "dead mutating failsafe retains rules" merv_dhcp_hold_rules_present
}

test_fault_child_cleanup_proc() {
  _tfcc_pid=$(cat "$SELFTEST_ROOT/fault-child.pid" 2>/dev/null || printf '')
  case "$_tfcc_pid" in ''|*[!0-9]*) return 0 ;; esac
  rm -f "$SELFTEST_PROC/$_tfcc_pid/stat" 2>/dev/null || :
  rmdir "$SELFTEST_PROC/$_tfcc_pid" 2>/dev/null || :
  rm -f "$SELFTEST_ROOT/fault-child.pid" 2>/dev/null || :
}

test_run_kill_checkpoint() {
  _trkc_point="$1"
  _trkc_stage="$2"
  _trkc_expected="$3"
  selftest_reset || return 1
  MERV_SELFTEST_ROOT_OVERRIDE="$SELFTEST_ROOT" \
    MERV_DHCP_HOLD_FAULT_POINT="$_trkc_point" \
    MERV_DHCP_HOLD_FAULT_ACTION=kill \
    /bin/sh "$SELFTEST_SCRIPT" _fault-child "$_trkc_stage" \
    >/dev/null 2>&1
  _trkc_rc=$?
  [ "$_trkc_rc" -ne 0 ] && pass "kill checkpoint $_trkc_point terminated owner" ||
    fail "kill checkpoint $_trkc_point did not terminate owner"
  test_fault_child_cleanup_proc
  assert_ok "kill checkpoint $_trkc_point reconciles" merv_dhcp_hold_reconcile crash-point
  case "$_trkc_expected" in
    clear)
      [ "$(test_ready_owner_count)" -eq 0 ] && [ "$(test_failsafe_count)" -eq 0 ] &&
        pass "kill checkpoint $_trkc_point leaves no security owner" ||
        fail "kill checkpoint $_trkc_point left unexpected security state"
      assert_ok "kill checkpoint $_trkc_point clears rules" merv_dhcp_hold_rules_absent
      ;;
    failsafe)
      [ "$(test_ready_owner_count)" -eq 0 ] && [ "$(test_failsafe_count)" -eq 1 ] &&
        pass "kill checkpoint $_trkc_point becomes failsafe" ||
        fail "kill checkpoint $_trkc_point failsafe state"
      assert_ok "kill checkpoint $_trkc_point retains rules" merv_dhcp_hold_rules_present
      ;;
  esac
}

test_dhcp_crash_points() {
  for _tdcp_point in acquire-intent-published acquire-rules-enforced \
    acquire-owner-staged acquire-owner-published; do
    test_run_kill_checkpoint "$_tdcp_point" acquire clear
  done
  test_run_kill_checkpoint mutate-phase-published mutate failsafe
  test_run_kill_checkpoint verify-phase-published verify clear
  test_run_kill_checkpoint release-owner-removed release clear

  selftest_reset || return 1
  assert_ok "cleanup-failure owner acquires" merv_dhcp_hold_acquire manager cleanup-failure
  _tdcp_cleanup="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "cleanup-failure owner mutates" merv_dhcp_hold_mark_mutating "$_tdcp_cleanup" bridge-cleanup
  assert_ok "cleanup-failure owner verifies" merv_dhcp_hold_mark_verified "$_tdcp_cleanup" verification-cleanup
  FAKE_EBTABLES_FAIL_MATCH="-D FORWARD"
  export FAKE_EBTABLES_FAIL_MATCH
  assert_rc 4 "rule-removal failure is visible" merv_dhcp_hold_release "$_tdcp_cleanup"
  [ "$(test_ready_owner_count)" -eq 0 ] && pass "safe owner cleanup completed before rule failure" ||
    fail "safe owner cleanup completed before rule failure"
  unset FAKE_EBTABLES_FAIL_MATCH
  export FAKE_EBTABLES_FAIL_MATCH
  assert_ok "reconcile retries failed rule cleanup" merv_dhcp_hold_reconcile cleanup-retry
  assert_ok "cleanup retry reaches exact absent state" merv_dhcp_hold_rules_absent
}

test_heal_handoff() {
  selftest_reset || return 1
  assert_ok "heal parent acquires" merv_dhcp_hold_acquire heal heal-parent
  _thh_parent="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "heal marks mutation before handoff" merv_dhcp_hold_mark_mutating "$_thh_parent" heal-eviction
  assert_ok "heal creates exact handoff request" merv_dhcp_handoff_request "$_thh_parent" manager heal-handoff-1
  assert_ok "heal enters handoff wait" merv_dhcp_hold_mark_handoff_wait "$_thh_parent" heal-handoff-1

  assert_ok "unrelated manager acquires independently" merv_dhcp_hold_acquire manager unrelated-manager
  _thh_unrelated="$MERV_DHCP_HOLD_TOKEN"
  assert_rc 1 "unrelated manager cannot acknowledge handoff" \
    merv_dhcp_handoff_ack heal-handoff-1 heal-parent "$_thh_unrelated"
  assert_rc 1 "unrelated manager does not satisfy acknowledgement" \
    merv_dhcp_handoff_is_acknowledged heal-handoff-1 heal-parent
  assert_ok "unrelated manager releases itself" merv_dhcp_hold_release "$_thh_unrelated"

  assert_ok "exact successor manager acquires" merv_dhcp_hold_acquire manager manager-child heal-parent
  _thh_child="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "exact successor acknowledgement succeeds" \
    merv_dhcp_handoff_ack heal-handoff-1 heal-parent "$_thh_child"
  assert_ok "exact acknowledgement is observable" \
    merv_dhcp_handoff_is_acknowledged heal-handoff-1 heal-parent manager-child
  assert_ok "acknowledged heal retires only its lease" \
    merv_dhcp_handoff_parent_release "$_thh_parent" heal-handoff-1
  [ "$(test_ready_owner_count)" -eq 1 ] && pass "successor lease remains after heal retirement" ||
    fail "successor lease remains after heal retirement"
  assert_ok "successor begins mutation" merv_dhcp_hold_mark_mutating "$_thh_child" bridge-cleanup
  assert_ok "successor verifies final state" merv_dhcp_hold_mark_verified "$_thh_child" heal-manager-verification
  assert_ok "successor completes handoff record" \
    merv_dhcp_handoff_child_verified heal-handoff-1 "$_thh_child" heal-manager-verification
  assert_ok "successor releases only itself" merv_dhcp_hold_release "$_thh_child"
  assert_ok "successful heal handoff clears exact rules" merv_dhcp_hold_rules_absent

  selftest_reset || return 1
  assert_ok "timeout heal acquires" merv_dhcp_hold_acquire heal heal-timeout
  _thh_timeout="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "timeout heal marks mutation" merv_dhcp_hold_mark_mutating "$_thh_timeout" heal-eviction
  assert_ok "timeout handoff request publishes" merv_dhcp_handoff_request "$_thh_timeout" manager heal-timeout-1
  assert_ok "timeout heal enters handoff wait" merv_dhcp_hold_mark_handoff_wait "$_thh_timeout" heal-timeout-1
  assert_rc 1 "manager-never-starts times out" merv_dhcp_handoff_wait_ack heal-timeout-1 heal-timeout 0
  assert_ok "timed-out parent publishes exact failed handoff" \
    merv_dhcp_handoff_fail heal-timeout-1 "$_thh_timeout" acknowledgement-timeout
  grep -q '^failed$' "$SELFTEST_STATE/handoffs/heal-timeout-1/handoff_state" &&
    grep -q '^acknowledgement-timeout$' "$SELFTEST_STATE/handoffs/heal-timeout-1/failure_reason" &&
    pass "timeout status records failed handoff and reason" ||
    fail "timeout status records failed handoff and reason"
  assert_file "$SELFTEST_STATE/recovery.pending" "failed handoff queues recovery"
  assert_ok "timed-out unsafe heal becomes failsafe" merv_dhcp_hold_abandon "$_thh_timeout" handoff-timeout
  [ "$(test_failsafe_count)" -eq 1 ] && pass "handoff timeout retains security failsafe" ||
    fail "handoff timeout retains security failsafe"
  assert_ok "handoff timeout remains fail-closed" merv_dhcp_hold_rules_present

  selftest_reset || return 1
  assert_ok "pre-ack kill heal acquires" merv_dhcp_hold_acquire heal heal-pre-ack-kill
  _thh_pre_kill="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "pre-ack kill heal mutates" merv_dhcp_hold_mark_mutating "$_thh_pre_kill" heal-eviction
  assert_ok "pre-ack kill request publishes" merv_dhcp_handoff_request "$_thh_pre_kill" manager heal-pre-ack-handoff
  assert_ok "pre-ack kill enters handoff wait" merv_dhcp_hold_mark_handoff_wait "$_thh_pre_kill" heal-pre-ack-handoff
  printf '1\n' > "$SELFTEST_STATE/owners/$_thh_pre_kill/proc_start_time"
  assert_ok "heal killed before acknowledgement reconciles" merv_dhcp_hold_reconcile heal-pre-ack-kill
  grep -q '^failed$' "$SELFTEST_STATE/handoffs/heal-pre-ack-handoff/handoff_state" &&
    grep -q '^orphaned-parent$' "$SELFTEST_STATE/handoffs/heal-pre-ack-handoff/failure_reason" &&
    pass "orphaned requested handoff is marked failed" ||
    fail "orphaned requested handoff is marked failed"
  [ "$(test_failsafe_count)" -eq 1 ] && pass "pre-ack killed heal becomes failsafe" ||
    fail "pre-ack killed heal becomes failsafe"

  selftest_reset || return 1
  assert_ok "dead-successor parent acquires" merv_dhcp_hold_acquire heal heal-dead-successor
  _thh_dead_parent="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "dead-successor parent mutates" merv_dhcp_hold_mark_mutating "$_thh_dead_parent" heal-eviction
  assert_ok "dead-successor request publishes" \
    merv_dhcp_handoff_request "$_thh_dead_parent" manager heal-dead-successor-handoff
  assert_ok "dead-successor parent waits" \
    merv_dhcp_hold_mark_handoff_wait "$_thh_dead_parent" heal-dead-successor-handoff
  assert_ok "dead-successor manager acquires" \
    merv_dhcp_hold_acquire manager heal-dead-successor-child heal-dead-successor
  _thh_dead_child="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "dead-successor manager acknowledges" \
    merv_dhcp_handoff_ack heal-dead-successor-handoff heal-dead-successor "$_thh_dead_child"
  printf '1\n' > "$SELFTEST_STATE/owners/$_thh_dead_child/proc_start_time"
  assert_ok "acknowledged dead successor reconciles" merv_dhcp_hold_reconcile heal-dead-successor
  grep -q '^failed$' "$SELFTEST_STATE/handoffs/heal-dead-successor-handoff/handoff_state" &&
    grep -q '^dead-successor$' "$SELFTEST_STATE/handoffs/heal-dead-successor-handoff/failure_reason" &&
    pass "acknowledged dead successor marks handoff failed" ||
    fail "acknowledged dead successor marks handoff failed"
  assert_file "$SELFTEST_STATE/recovery.pending" "dead successor queues recovery"
  assert_ok "dead successor remains fail-closed" merv_dhcp_hold_rules_present

  selftest_reset || return 1
  assert_ok "post-ack kill heal acquires" merv_dhcp_hold_acquire heal heal-post-ack-kill
  _thh_post_parent="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "post-ack kill heal mutates" merv_dhcp_hold_mark_mutating "$_thh_post_parent" heal-eviction
  assert_ok "post-ack kill request publishes" merv_dhcp_handoff_request "$_thh_post_parent" manager heal-post-ack-handoff
  assert_ok "post-ack kill enters handoff wait" merv_dhcp_hold_mark_handoff_wait "$_thh_post_parent" heal-post-ack-handoff
  assert_ok "post-ack exact manager acquires" merv_dhcp_hold_acquire manager heal-post-ack-manager heal-post-ack-kill
  _thh_post_child="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "post-ack manager acknowledges" \
    merv_dhcp_handoff_ack heal-post-ack-handoff heal-post-ack-kill "$_thh_post_child"
  printf '1\n' > "$SELFTEST_STATE/owners/$_thh_post_parent/proc_start_time"
  assert_ok "heal killed after acknowledgement reconciles" merv_dhcp_hold_reconcile heal-post-ack-kill
  assert_no_file "$SELFTEST_STATE/owners/$_thh_post_parent/ready" "acknowledged dead heal is retired"
  [ "$(test_failsafe_count)" -eq 0 ] && pass "acknowledged dead heal creates no parent failsafe" ||
    fail "acknowledged dead heal creates no parent failsafe"
  assert_ok "post-ack successor remains protected" merv_dhcp_hold_rules_present
  assert_ok "post-ack successor begins mutation" merv_dhcp_hold_mark_mutating "$_thh_post_child" bridge-cleanup
  assert_ok "post-ack successor verifies" merv_dhcp_hold_mark_verified "$_thh_post_child" post-ack-verification
  assert_ok "post-ack successor completes handoff" \
    merv_dhcp_handoff_child_verified heal-post-ack-handoff "$_thh_post_child" post-ack-verification
  assert_ok "post-ack successor releases itself" merv_dhcp_hold_release "$_thh_post_child"
}

test_boot_handoff() {
  grep -Fq 'MERV_BOOT_SHIELD_MAX_SEC:=480' "$MERV_BASE/settings/var_settings.sh" &&
    pass "boot shield setting retains cold-boot-qualified ceiling" ||
    fail "boot shield setting retains cold-boot-qualified ceiling"
  grep -Fq 'MERV_BOOT_SHIELD_MAX_SEC:-480' "$MERV_BASE/functions/mervlan_boot_wrap.sh" &&
    ! grep -Fq 'MERV_BOOT_SHIELD_MAX_SEC:-120' "$MERV_BASE/functions/mervlan_boot_wrap.sh" &&
    pass "boot watchdog defaults retain cold-boot-qualified ceiling" ||
    fail "boot watchdog defaults retain cold-boot-qualified ceiling"

  selftest_reset || return 1
  assert_ok "boot watchdog acquires its own lease" merv_dhcp_hold_acquire boot-watchdog boot-parent
  _tbh_parent="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "boot watchdog requests manager handoff" merv_dhcp_handoff_request "$_tbh_parent" manager boot-handoff-1
  assert_ok "boot watchdog enters handoff wait" merv_dhcp_hold_mark_handoff_wait "$_tbh_parent" boot-handoff-1
  assert_ok "boot successor manager acquires" merv_dhcp_hold_acquire manager boot-manager boot-parent
  _tbh_child="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "boot successor acknowledges exact request" \
    merv_dhcp_handoff_ack boot-handoff-1 boot-parent "$_tbh_child"
  assert_rc 5 "boot owner cannot retire on acknowledgement alone" \
    merv_dhcp_handoff_parent_release "$_tbh_parent" boot-handoff-1
  assert_ok "boot manager begins mutation" merv_dhcp_hold_mark_mutating "$_tbh_child" bridge-cleanup
  assert_ok "boot manager publishes verification" merv_dhcp_hold_mark_verified "$_tbh_child" boot-verification
  assert_ok "boot manager publishes verified handoff completion" \
    merv_dhcp_handoff_child_verified boot-handoff-1 "$_tbh_child" boot-verification
  assert_ok "verified boot watchdog retires its lease" \
    merv_dhcp_handoff_parent_release "$_tbh_parent" boot-handoff-1
  assert_ok "verified boot manager releases its lease" merv_dhcp_hold_release "$_tbh_child"
  assert_ok "healthy boot completion clears exact hold" merv_dhcp_hold_rules_absent

  selftest_reset || return 1
  assert_ok "live completed boot parent acquires" merv_dhcp_hold_acquire boot-watchdog boot-live-parent
  _tbh_live_parent="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "live completed boot handoff publishes" merv_dhcp_handoff_request "$_tbh_live_parent" manager boot-live-handoff
  assert_ok "live completed boot parent waits" merv_dhcp_hold_mark_handoff_wait "$_tbh_live_parent" boot-live-handoff
  assert_ok "live completed boot successor acquires" merv_dhcp_hold_acquire manager boot-live-child boot-live-parent
  _tbh_live_child="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "live completed boot successor acknowledges" merv_dhcp_handoff_ack boot-live-handoff boot-live-parent "$_tbh_live_child"
  assert_ok "live completed boot successor mutates" merv_dhcp_hold_mark_mutating "$_tbh_live_child" bridge-cleanup
  assert_ok "live completed boot successor verifies" merv_dhcp_hold_mark_verified "$_tbh_live_child" boot-live-verification
  assert_ok "live completed boot handoff completes" merv_dhcp_handoff_child_verified boot-live-handoff "$_tbh_live_child" boot-live-verification
  assert_ok "live completed boot reconciliation is idempotent" merv_dhcp_hold_reconcile boot-live-reconcile
  [ -d "$SELFTEST_STATE/owners/$_tbh_live_parent" ] &&
    pass "live completed boot parent remains owned until process exits" ||
    fail "live completed boot parent remains owned until process exits"
  assert_ok "live completed boot parent releases explicitly" merv_dhcp_handoff_parent_release "$_tbh_live_parent" boot-live-handoff
  assert_ok "live completed boot successor releases explicitly" merv_dhcp_hold_release "$_tbh_live_child"
  assert_ok "live completed boot reconciliation clears exact hold" merv_dhcp_hold_rules_absent

  selftest_reset || return 1
  assert_ok "unsafe-timeout boot watchdog acquires" merv_dhcp_hold_acquire boot-watchdog boot-timeout
  _tbh_timeout="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "unsafe-timeout request publishes" merv_dhcp_handoff_request "$_tbh_timeout" manager boot-timeout-1
  assert_ok "unsafe-timeout enters handoff wait" merv_dhcp_hold_mark_handoff_wait "$_tbh_timeout" boot-timeout-1
  assert_rc 1 "unsafe boot timeout cannot release without verified successor" \
    merv_dhcp_handoff_parent_release "$_tbh_timeout" boot-timeout-1
  assert_ok "unsafe boot timeout publishes failed handoff" \
    merv_dhcp_handoff_fail boot-timeout-1 "$_tbh_timeout" boot-handoff-incomplete
  grep -q '^failed$' "$SELFTEST_STATE/handoffs/boot-timeout-1/handoff_state" &&
    pass "boot timeout status records failed handoff" ||
    fail "boot timeout status records failed handoff"
  assert_ok "unsafe boot timeout converts to failsafe" \
    merv_dhcp_hold_abandon "$_tbh_timeout" boot-handoff-incomplete
  assert_ok "unsafe boot timeout remains fail-closed" merv_dhcp_hold_rules_present

  selftest_reset || return 1
  assert_ok "killed boot watchdog acquires" merv_dhcp_hold_acquire boot-watchdog boot-killed
  _tbh_killed="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "killed boot watchdog requests handoff" merv_dhcp_handoff_request "$_tbh_killed" manager boot-killed-handoff
  assert_ok "killed boot watchdog waits" merv_dhcp_hold_mark_handoff_wait "$_tbh_killed" boot-killed-handoff
  printf '1\n' > "$SELFTEST_STATE/owners/$_tbh_killed/proc_start_time"
  assert_ok "killed boot watchdog reconciles" merv_dhcp_hold_reconcile boot-watchdog-killed
  [ "$(test_failsafe_count)" -eq 1 ] && pass "killed boot watchdog becomes failsafe" ||
    fail "killed boot watchdog becomes failsafe"
  assert_ok "killed boot watchdog remains fail-closed" merv_dhcp_hold_rules_present

  grep -q 'shield-watchdog' "$MERV_BASE/functions/mervlan_boot_wrap.sh" &&
    pass "boot watchdog runs as independent script process" ||
    fail "boot watchdog runs as independent script process"
  grep -q 'merv_dhcp_handoff_child_verified' "$MERV_BASE/functions/mervlan_manager.sh" &&
    pass "manager records verified boot completion" ||
    fail "manager records verified boot completion"
  grep -q '_is_node_runtime' "$MERV_BASE/functions/mervlan_boot_wrap.sh" &&
    grep -q 'installer bootstrap is not required' "$MERV_BASE/functions/mervlan_boot_wrap.sh" &&
    pass "curated node boot does not require install.sh" ||
    fail "curated node boot does not require install.sh"
}

test_duplicate_events() {
  selftest_reset || return 1
  assert_ok "duplicate-test heal acquires" merv_dhcp_hold_acquire heal duplicate-heal-parent
  _tde_parent="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "duplicate-test heal mutates" merv_dhcp_hold_mark_mutating "$_tde_parent" heal-eviction
  assert_ok "duplicate-test handoff publishes" merv_dhcp_handoff_request "$_tde_parent" manager duplicate-handoff
  assert_ok "duplicate-test parent waits" merv_dhcp_hold_mark_handoff_wait "$_tde_parent" duplicate-handoff
  assert_ok "second heal attaches to active handoff" merv_dhcp_handoff_coalesce heal manager duplicate-event
  assert_file "$SELFTEST_STATE/heal.pending" "duplicate heal records one pending request"
  grep -q '^attached_handoff=duplicate-handoff$' "$SELFTEST_STATE/heal.pending" &&
    pass "duplicate request references active handoff" ||
    fail "duplicate request references active handoff"
  [ "$(test_ready_owner_count)" -eq 1 ] && pass "duplicate event creates no second owner" ||
    fail "duplicate event creates no second owner"
  assert_ok "duplicate-test unsafe parent retains failsafe" \
    merv_dhcp_hold_abandon "$_tde_parent" duplicate-test-cleanup

  grep -q 'vlan_event.lock held by another instance' "$MERV_BASE/functions/heal_event.sh" &&
    grep -q 'merv_dhcp_handoff_coalesce heal manager' "$MERV_BASE/functions/heal_event.sh" &&
    pass "heal lock contention is coalesced" || fail "heal lock contention is coalesced"
  grep -q -- '--parent-run-id=.*HEAL_RUN_ID' "$MERV_BASE/functions/heal_event.sh" &&
    grep -q -- '--handoff-id=.*HEAL_HANDOFF_ID' "$MERV_BASE/functions/heal_event.sh" &&
    pass "heal launches one exact successor context" || fail "heal launches one exact successor context"
}

test_settle_observe() {
  _tso_line=$(sed -n '1p' "$SELFTEST_ROOT/settle.sequence" 2>/dev/null)
  sed '1d' "$SELFTEST_ROOT/settle.sequence" > "$SELFTEST_ROOT/settle.sequence.next" 2>/dev/null || :
  mv "$SELFTEST_ROOT/settle.sequence.next" "$SELFTEST_ROOT/settle.sequence" 2>/dev/null || :
  printf '%s\n' "${_tso_line:-unhealthy}"
}

test_settle_correct() {
  _tsc_count=$(cat "$SELFTEST_ROOT/settle.corrected" 2>/dev/null || printf '0')
  printf '%s\n' $((_tsc_count + 1)) > "$SELFTEST_ROOT/settle.corrected"
  return 0
}

test_settle_watchdog() {
  selftest_reset || return 1
  rm -f "$SELFTEST_ROOT/settle.corrected"
  MERV_DHCP_SETTLE_TICK_CMD=:
  export MERV_DHCP_SETTLE_TICK_CMD
  printf '%s\n' busy busy healthy healthy healthy > "$SELFTEST_ROOT/settle.sequence"
  assert_ok "busy-to-three-healthy reaches stable state" \
    merv_dhcp_hold_wait_stable test_settle_observe test_settle_correct 3 6
  assert_no_file "$SELFTEST_ROOT/settle.corrected" "healthy primary pass performs no correction"

  selftest_reset || return 1
  rm -f "$SELFTEST_ROOT/settle.corrected"
  printf '%s\n' healthy unhealthy healthy healthy healthy > "$SELFTEST_ROOT/settle.sequence"
  assert_ok "interrupted healthy streak resets and later stabilizes" \
    merv_dhcp_hold_wait_stable test_settle_observe test_settle_correct 3 6

  selftest_reset || return 1
  rm -f "$SELFTEST_ROOT/settle.corrected"
  printf '%s\n' unhealthy unhealthy unhealthy healthy healthy healthy > "$SELFTEST_ROOT/settle.sequence"
  assert_ok "quiet timeout gets one bounded corrective pass" \
    merv_dhcp_hold_wait_stable test_settle_observe test_settle_correct 3 3
  [ "$(cat "$SELFTEST_ROOT/settle.corrected" 2>/dev/null)" = 1 ] &&
    pass "quiet timeout performs exactly one correction" ||
    fail "quiet timeout performs exactly one correction"

  selftest_reset || return 1
  rm -f "$SELFTEST_ROOT/settle.corrected"
  printf '%s\n' busy busy busy > "$SELFTEST_ROOT/settle.sequence"
  assert_rc 6 "ASUS-work timeout refuses corrective bridge pass" \
    merv_dhcp_hold_wait_stable test_settle_observe test_settle_correct 3 3
  assert_no_file "$SELFTEST_ROOT/settle.corrected" "ASUS-work timeout made no correction"
  assert_file "$SELFTEST_STATE/recovery.pending" "ASUS-work timeout queues recovery"

  selftest_reset || return 1
  rm -f "$SELFTEST_ROOT/settle.corrected"
  printf '%s\n' unhealthy unhealthy unhealthy unhealthy unhealthy unhealthy > "$SELFTEST_ROOT/settle.sequence"
  assert_rc 7 "persistent quiet unhealthy state fails after correction" \
    merv_dhcp_hold_wait_stable test_settle_observe test_settle_correct 3 3
  [ "$(cat "$SELFTEST_ROOT/settle.corrected" 2>/dev/null)" = 1 ] &&
    pass "persistent unhealthy state performs only one correction" ||
    fail "persistent unhealthy state performs only one correction"

  MERV_DHCP_SETTLE_TICK_CMD='sleep 1; false'
  export MERV_DHCP_SETTLE_TICK_CMD
  printf '%s\n' healthy healthy healthy > "$SELFTEST_ROOT/settle.sequence"
  assert_rc 1 "settle tick rejects shell command injection" \
    merv_dhcp_hold_wait_stable test_settle_observe test_settle_correct 3 3
  MERV_DHCP_SETTLE_TICK_CMD=:
  export MERV_DHCP_SETTLE_TICK_CMD
}

test_recovery() {
  selftest_reset || return 1
  assert_ok "failed handoff parent acquires for recovery fixture" \
    merv_dhcp_hold_acquire heal failed-handoff-parent
  _tr_handoff_parent="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "failed handoff parent begins mutation" \
    merv_dhcp_hold_mark_mutating "$_tr_handoff_parent" bridge-cleanup
  assert_ok "failed handoff request is published" \
    merv_dhcp_handoff_request "$_tr_handoff_parent" manager recovery-failed-handoff
  assert_ok "failed handoff parent enters wait" \
    merv_dhcp_hold_mark_handoff_wait "$_tr_handoff_parent" recovery-failed-handoff
  assert_ok "failed handoff queues recovery" \
    merv_dhcp_handoff_fail recovery-failed-handoff "$_tr_handoff_parent" acknowledgement-timeout
  assert_ok "failed handoff converts parent to failsafe" \
    merv_dhcp_hold_abandon "$_tr_handoff_parent" handoff-timeout
  assert_file "$SELFTEST_STATE/handoffs/recovery-failed-handoff/ready" \
    "failed handoff remains until verified recovery"

  MERV_DHCP_FAILSAFE_FAILED_INTERFACES=wl0.1
  MERV_DHCP_FAILSAFE_EXPECTED_BRIDGES=br20
  MERV_DHCP_FAILSAFE_OBSERVED_BRIDGES=br0
  MERV_DHCP_FAILSAFE_MISSING_RULES=none
  MERV_DHCP_FAILSAFE_ASUS_WORK=quiet
  MERV_DHCP_FAILSAFE_SUGGESTED_ACTION=mervlan-manager-recovery
  export MERV_DHCP_FAILSAFE_FAILED_INTERFACES MERV_DHCP_FAILSAFE_EXPECTED_BRIDGES
  export MERV_DHCP_FAILSAFE_OBSERVED_BRIDGES MERV_DHCP_FAILSAFE_MISSING_RULES
  export MERV_DHCP_FAILSAFE_ASUS_WORK MERV_DHCP_FAILSAFE_SUGGESTED_ACTION
  assert_ok "failed manager acquires for recovery fixture" merv_dhcp_hold_acquire manager failed-run
  _tr_failed="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "failed manager begins mutation" merv_dhcp_hold_mark_mutating "$_tr_failed" bridge-cleanup
  assert_ok "failed manager converts to structured failsafe" \
    merv_dhcp_hold_abandon "$_tr_failed" final-verification-failed
  assert_file "$SELFTEST_STATE/recovery.pending" "failsafe recovery request is coalesced"

  assert_ok "recovery owner acquires protection" merv_dhcp_hold_acquire recovery recovery-run
  _tr_recovery="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "recovery owner marks mutation" merv_dhcp_hold_mark_mutating "$_tr_recovery" corrective-pass
  assert_rc 1 "unverified recovery cannot clear failsafe" \
    merv_dhcp_hold_clear_failsafes "$_tr_recovery" recovery-verification
  assert_ok "recovery publishes full verification" \
    merv_dhcp_hold_mark_verified "$_tr_recovery" recovery-verification
  assert_rc 1 "wrong verification cannot clear failsafe" \
    merv_dhcp_hold_clear_failsafes "$_tr_recovery" wrong-verification
  assert_ok "verified recovery clears covered failsafes" \
    merv_dhcp_hold_clear_failsafes "$_tr_recovery" recovery-verification
  [ "$(test_failsafe_count)" -eq 0 ] && pass "verified recovery removed failsafe" ||
    fail "verified recovery removed failsafe"
  assert_no_file "$SELFTEST_STATE/handoffs/recovery-failed-handoff/ready" \
    "verified recovery clears terminal failed handoff"
  assert_no_file "$SELFTEST_STATE/recovery.pending" "verified recovery clears pending request"
  assert_ok "recovery releases its verified lease" merv_dhcp_hold_release "$_tr_recovery"
  assert_ok "completed recovery reconciles exact clear rules" merv_dhcp_hold_rules_absent
}

test_failsafe_status() {
  selftest_reset || return 1
  MERV_DHCP_FAILSAFE_FAILED_INTERFACES=wl0.2
  MERV_DHCP_FAILSAFE_EXPECTED_BRIDGES=br30
  MERV_DHCP_FAILSAFE_OBSERVED_BRIDGES=br0
  MERV_DHCP_FAILSAFE_MISSING_RULES=forward-jump
  MERV_DHCP_FAILSAFE_ASUS_WORK=active
  MERV_DHCP_FAILSAFE_SUGGESTED_ACTION=mervlan-manager-recovery
  export MERV_DHCP_FAILSAFE_FAILED_INTERFACES MERV_DHCP_FAILSAFE_EXPECTED_BRIDGES
  export MERV_DHCP_FAILSAFE_OBSERVED_BRIDGES MERV_DHCP_FAILSAFE_MISSING_RULES
  export MERV_DHCP_FAILSAFE_ASUS_WORK MERV_DHCP_FAILSAFE_SUGGESTED_ACTION
  assert_ok "status fixture owner acquires" merv_dhcp_hold_acquire manager status-failure
  _tfs_token="$MERV_DHCP_HOLD_TOKEN"
  assert_ok "status fixture owner mutates" merv_dhcp_hold_mark_mutating "$_tfs_token" bridge-cleanup
  assert_ok "status fixture creates failsafe" merv_dhcp_hold_abandon "$_tfs_token" verification-failed
  _tfs_output=$(merv_dhcp_hold_status 2>&1)
  printf '%s\n' "$_tfs_output" | grep -q 'failed_interfaces=wl0.2' &&
    pass "status reports failed interfaces" || fail "status reports failed interfaces"
  printf '%s\n' "$_tfs_output" | grep -q 'expected_bridges=br30' &&
    pass "status reports expected bridges" || fail "status reports expected bridges"
  printf '%s\n' "$_tfs_output" | grep -q 'observed_bridges=br0' &&
    pass "status reports observed bridges" || fail "status reports observed bridges"
  printf '%s\n' "$_tfs_output" | grep -q 'missing_rules=forward-jump' &&
    pass "status reports missing rules" || fail "status reports missing rules"
  printf '%s\n' "$_tfs_output" | grep -q 'asus_work=active' &&
    pass "status reports ASUS work evidence" || fail "status reports ASUS work evidence"
  printf '%s\n' "$_tfs_output" | grep -q 'pending_recovery=yes' &&
    pass "status reports pending recovery" || fail "status reports pending recovery"
  grep -q '<--- DHCP Hold State --->' "$MERV_BASE/functions/mervlan_boot.sh" &&
    pass "normal MerVLAN status integrates DHCP hold state" ||
    fail "normal MerVLAN status integrates DHCP hold state"
  grep -q '<--- Observation State --->' "$MERV_BASE/functions/mervlan_boot.sh" &&
    pass "normal MerVLAN status integrates pending observation generations" ||
    fail "normal MerVLAN status integrates pending observation generations"
}

observation_reset() {
  MERV_OBSERVATION_ROOT="$SELFTEST_ROOT/observation"
  MERV_OBSERVATION_PROC_ROOT="/proc"
  MERV_OBSERVATION_CONFIG_LOCKDIR="$SELFTEST_ROOT/observation-config-locks"
  OBS_TEST_LOG="$SELFTEST_ROOT/observation.log"
  OBS_TEST_SNAPSHOT="$SELFTEST_ROOT/bin/observation-snapshot"
  OBS_TEST_COLLECTION="$SELFTEST_ROOT/bin/observation-collection"
  export MERV_OBSERVATION_ROOT MERV_OBSERVATION_PROC_ROOT
  export MERV_OBSERVATION_CONFIG_LOCKDIR
  export OBS_TEST_LOG OBS_TEST_SNAPSHOT OBS_TEST_COLLECTION
  rm -rf "$MERV_OBSERVATION_ROOT" "$MERV_OBSERVATION_CONFIG_LOCKDIR" 2>/dev/null || return 1
  rm -f "$OBS_TEST_LOG" "$SELFTEST_ROOT"/obs-* 2>/dev/null || return 1
  mkdir -p "$MERV_OBSERVATION_CONFIG_LOCKDIR" || return 1
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "snapshot\n" >> "$OBS_TEST_LOG"'
    printf '%s\n' '[ ! -f "$MERV_DHCP_HOLD_TEST_ROOT/obs-snapshot-fail" ] || exit 41'
    printf '%s\n' 'if [ -f "$MERV_DHCP_HOLD_TEST_ROOT/obs-request-during" ] && [ ! -f "$MERV_DHCP_HOLD_TEST_ROOT/obs-requested" ]; then'
    printf '%s\n' '  : > "$MERV_DHCP_HOLD_TEST_ROOT/obs-requested"'
    printf '%s\n' '  MERV_OBS_NO_AUTOSTART=1 "$MERV_BASE/functions/post_apply_worker.sh" request snapshot >/dev/null'
    printf '%s\n' 'fi'
    printf '%s\n' '[ ! -f "$MERV_DHCP_HOLD_TEST_ROOT/obs-snapshot-kill-worker" ] || kill -9 "$PPID"'
  } > "$OBS_TEST_SNAPSHOT" || return 1
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "collection\n" >> "$OBS_TEST_LOG"'
    printf '%s\n' '[ ! -f "$MERV_DHCP_HOLD_TEST_ROOT/obs-collection-fail" ] || exit 42'
  } > "$OBS_TEST_COLLECTION" || return 1
  chmod 700 "$OBS_TEST_SNAPSHOT" "$OBS_TEST_COLLECTION" || return 1
}

observation_worker() {
  MERV_OBS_NO_AUTOSTART=1 \
  MERV_OBS_SNAPSHOT_CMD="$OBS_TEST_SNAPSHOT" \
  MERV_OBS_COLLECTION_CMD="$OBS_TEST_COLLECTION" \
    "$MERV_BASE/functions/post_apply_worker.sh" "$@"
}

observation_number() {
  sed -n "s/^$1=//p" "$MERV_OBSERVATION_ROOT/request.state" 2>/dev/null | tail -n 1
}

test_post_apply() {
  selftest_reset || return 1
  observation_reset || return 1
  grep -q 'settings/lib_ssid_filter.sh' "$MERV_BASE/functions/post_apply_worker.sh" &&
    pass "observation worker loads MAC snapshot SSID filter dependency" ||
    fail "observation worker loads MAC snapshot SSID filter dependency"
  grep -q 'settings/lib_json.sh' "$MERV_BASE/functions/post_apply_worker.sh" &&
    grep -q 'MAX_SSIDS=$(merv_cap_ssids' "$MERV_BASE/functions/post_apply_worker.sh" &&
    grep -q 'ssid_filter_init.*MERV_NODE_ID' "$MERV_BASE/functions/post_apply_worker.sh" &&
    pass "fresh observation worker bootstraps hardware and node identity" ||
    fail "fresh observation worker bootstraps hardware and node identity"
  grep -q 'run-wait.*MERV_OBS_AUTOSTART_WAIT_SEC' "$MERV_BASE/functions/post_apply_worker.sh" &&
    pass "autostart retries generations deferred by configuration mutation" ||
    fail "autostart retries generations deferred by configuration mutation"
  assert_ok "post-apply publishes snapshot and collection" \
    observation_worker request snapshot collect
  assert_ok "post-apply worker drains both operations" observation_worker run
  [ "$(cat "$OBS_TEST_LOG" 2>/dev/null)" = "$(printf 'snapshot\ncollection')" ] &&
    pass "snapshot precedes collection" || fail "snapshot precedes collection"
  [ "$(observation_number snapshot_completed_generation)" = 1 ] &&
    [ "$(observation_number collection_completed_generation)" = 1 ] &&
    pass "post-apply completes both exact generations" ||
    fail "post-apply completes both exact generations"

  _tpa_bad=0
  for _tpa_file in mervlan_manager.sh heal_event.sh mac_refresh.sh \
    mac_client_meta.sh service-event-handler.sh execute_nodes.sh; do
    [ -f "$MERV_BASE/functions/$_tpa_file" ] || continue
    grep -q 'post_apply_worker.sh' "$MERV_BASE/functions/$_tpa_file" ||
      { fail "$_tpa_file uses observation coordinator"; _tpa_bad=1; }
  done
  [ "$_tpa_bad" -eq 0 ] && pass "all production observation callers use coordinator"
  _tpa_direct=0
  for _tpa_name in mervlan_manager.sh heal_event.sh mac_refresh.sh \
    mac_client_meta.sh service-event-handler.sh execute_nodes.sh; do
    _tpa_source="$MERV_BASE/functions/$_tpa_name"
    grep -E '^[[:space:]]*(sh[[:space:]]+)?["$A-Za-z0-9_/{.-]*collect_clients\.sh' \
      "$_tpa_source" >/dev/null 2>&1 && _tpa_direct=1
  done
  [ "$_tpa_direct" -eq 0 ] &&
    pass "no production caller invokes collection directly" ||
    fail "no production caller invokes collection directly"
  grep -q 'functions/collect_local_clients.sh' "$MERV_BASE/functions/post_apply_worker.sh" &&
    pass "node collection uses the synced local observation backend" ||
    fail "node collection uses the synced local observation backend"
  if [ -f "$MERV_BASE/functions/collect_clients.sh" ]; then
    { grep -Fq 'post_apply_worker.sh" run-wait' "$MERV_BASE/functions/collect_clients.sh" ||
      grep -Fq "post_apply_worker.sh' run-wait" "$MERV_BASE/functions/collect_clients.sh"; } &&
      pass "cluster collection waits for the node coordinator generation" ||
      fail "cluster collection waits for the node coordinator generation"
  fi
}

test_observation_lock() {
  selftest_reset || return 1
  observation_reset || return 1
  _tol_ok=1
  _tol_worker="$MERV_OBSERVATION_ROOT/worker.lock"
  _tol_request="$MERV_OBSERVATION_ROOT/request.lock"

  MERV_OBSERVATION_PROC_ROOT="$SELFTEST_ROOT/missing-proc"
  export MERV_OBSERVATION_PROC_ROOT
  if observation_worker request snapshot >/dev/null 2>&1; then
    fail "observation start lookup failure blocks acquisition"; _tol_ok=0
  else
    pass "observation start lookup failure blocks acquisition"
  fi
  [ ! -e "$_tol_request" ] && pass "failed identity lookup leaves no claim" || {
    fail "failed identity lookup leaves no claim"; _tol_ok=0;
  }

  MERV_OBSERVATION_PROC_ROOT="$SELFTEST_ROOT/zero-proc"
  mkdir -p "$MERV_OBSERVATION_PROC_ROOT/$$" || return 1
  {
    printf '%s (observation zero-start) S' "$$"
    _tol_field=4
    while [ "$_tol_field" -le 21 ]; do printf ' 0'; _tol_field=$((_tol_field + 1)); done
    printf ' 0\n'
  } > "$MERV_OBSERVATION_PROC_ROOT/$$/stat" || return 1
  if observation_worker request snapshot >/dev/null 2>&1; then
    fail "observation start time zero is rejected"; _tol_ok=0
  else
    pass "observation start time zero is rejected"
  fi
  MERV_OBSERVATION_PROC_ROOT=/proc
  export MERV_OBSERVATION_PROC_ROOT

  MERV_OWNER_LOCK_FAULT=compat-write
  export MERV_OWNER_LOCK_FAULT
  if observation_worker request snapshot >/dev/null 2>&1; then
    fail "failed observation publication is reported"; _tol_ok=0
  else
    pass "failed observation publication is reported"
  fi
  unset MERV_OWNER_LOCK_FAULT
  export MERV_OWNER_LOCK_FAULT
  [ ! -e "$_tol_request" ] && pass "failed observation publication leaves no unknown claim" || {
    fail "failed observation publication leaves no unknown claim"; _tol_ok=0;
  }

  observation_worker request snapshot >/dev/null || return 1
  merv_owner_lock_acquire "$_tol_worker" 0 0 observation-lock || return 1
  _tol_live_nonce="$MERV_LOCK_NONCE"
  observation_worker run >/dev/null 2>&1
  [ -f "$_tol_worker/owner" ] && pass "live observation owner is not stolen" || {
    fail "live observation owner is not stolen"; _tol_ok=0;
  }
  merv_owner_lock_release "$_tol_worker" "$_tol_live_nonce" || return 1

  mkdir "$_tol_worker" || return 1
  merv_owner_v2_write_atomic "$_tol_worker" 999999 1 dead-observation 1 1 || return 1
  observation_worker run >/dev/null 2>&1 || return 1
  _tol_dead_quarantine=0
  for _tol_dir in "$MERV_OBSERVATION_ROOT"/.worker.lock.dead.*; do
    [ -d "$_tol_dir" ] && _tol_dead_quarantine=1
  done
  [ "$_tol_dead_quarantine" -eq 1 ] && pass "dead observation owner is quarantined" || {
    fail "dead observation owner is quarantined"; _tol_ok=0;
  }
  [ "$(observation_number snapshot_completed_generation)" = 1 ] &&
    pass "dead-owner observation resumes pending generation" || {
      fail "dead-owner observation resumes pending generation"; _tol_ok=0;
    }

  observation_reset || return 1
  observation_worker request snapshot >/dev/null || return 1
  mkdir "$_tol_worker" || return 1
  merv_owner_v2_write_atomic "$_tol_worker" "$$" 1 reused-observation 1 1 || return 1
  observation_worker run >/dev/null 2>&1 || return 1
  _tol_reused_quarantine=0
  for _tol_dir in "$MERV_OBSERVATION_ROOT"/.worker.lock.reused.*; do
    [ -d "$_tol_dir" ] && _tol_reused_quarantine=1
  done
  [ "$_tol_reused_quarantine" -eq 1 ] && pass "reused observation PID is quarantined" || {
    fail "reused observation PID is quarantined"; _tol_ok=0;
  }

  merv_owner_lock_acquire "$_tol_request" 0 0 observation-lock || return 1
  _tol_nonce="$MERV_LOCK_NONCE"
  assert_rc 1 "wrong observation nonce is rejected" \
    merv_owner_lock_release "$_tol_request" wrong-observation-nonce
  assert_file "$_tol_request/owner" "wrong observation nonce preserves owner"
  : > "$_tol_request/release-obstruction"
  assert_rc 1 "observation release obstruction is reported" \
    merv_owner_lock_release "$_tol_request" "$_tol_nonce"
  assert_ok "observation release obstruction restores owner" \
    merv_owner_v2_read "$_tol_request"
  rm -f "$_tol_request/release-obstruction" || return 1
  merv_owner_lock_release "$_tol_request" "$_tol_nonce" || return 1

  observation_reset || return 1
  observation_worker request snapshot >/dev/null || return 1
  : > "$SELFTEST_ROOT/obs-snapshot-kill-worker"
  observation_worker run >/dev/null 2>&1
  [ "$(observation_number snapshot_completed_generation)" = 0 ] &&
    pass "interrupted observation does not advance completion" || {
      fail "interrupted observation does not advance completion"; _tol_ok=0;
  }
  rm -f "$SELFTEST_ROOT/obs-snapshot-kill-worker" || return 1

  # Shield observation owns the node pool while this worker holds the
  # observation lock.  Keep the interruption ordering executable as a
  # contract test: abort must be attempted in cleanup before that lock can be
  # released, and the signal path must invoke the same abort hook.
  _tol_obs_source="$MERV_BASE/functions/post_apply_worker.sh"
  _tol_obs_cleanup=$(sed -n '/^obs_worker_cleanup() {/,/^}/p' "$_tol_obs_source" 2>/dev/null)
  _tol_obs_abort_line=$(printf '%s\n' "$_tol_obs_cleanup" | grep -n 'obs_abort_active_pool' | head -1 | cut -d: -f1)
  _tol_obs_release_line=$(printf '%s\n' "$_tol_obs_cleanup" | grep -n 'obs_lock_release.*OBS_WORKER_LOCK' | head -1 | cut -d: -f1)
  if [ -n "$_tol_obs_abort_line" ] && [ -n "$_tol_obs_release_line" ] &&
     [ "$_tol_obs_abort_line" -lt "$_tol_obs_release_line" ] 2>/dev/null; then
    pass "Shield cleanup aborts node pool before observation lock release"
  else
    fail "Shield cleanup aborts node pool before observation lock release"; _tol_ok=0
  fi
  _tol_obs_signal=$(sed -n '/^obs_handle_signal() {/,/^}/p' "$_tol_obs_source" 2>/dev/null)
  printf '%s\n' "$_tol_obs_signal" | grep -Fq 'obs_abort_active_pool' &&
    pass "Shield interruption signal path invokes node-pool abort" || {
      fail "Shield interruption signal path invokes node-pool abort"; _tol_ok=0;
    }

  # Every parent that can own the shared pool must reconcile it from its
  # interruption/EXIT cleanup before releasing its own action/observation
  # lock.  Keep this as a source contract for the four production paths so a
  # future cleanup edit cannot silently reintroduce early lock release.
  for _tol_route in \
    'collect_clients.sh|cleanup_collect|merv_lock_release.*COLLECT_LOCK|client collection' \
    'execute_nodes.sh|execute_nodes_progress_cleanup|merv_owner_lock_release.*EXEC_NODES_LOCK|execute' \
    'sync_nodes.sh|_cleanup_sync_tmp|merv_owner_lock_release.*SYNC_LOCK|sync' \
    'post_apply_worker.sh|obs_worker_cleanup|obs_lock_release.*OBS_WORKER_LOCK|Shield observation'; do
    _tol_route_file=${_tol_route%%|*}
    _tol_route_rest=${_tol_route#*|}
    _tol_route_fn=${_tol_route_rest%%|*}
    _tol_route_rest=${_tol_route_rest#*|}
    _tol_route_release=${_tol_route_rest%%|*}
    _tol_route_label=${_tol_route_rest#*|}
    _tol_route_body=$(sed -n "/^${_tol_route_fn}() {/,/^}/p" "$MERV_BASE/functions/$_tol_route_file" 2>/dev/null)
    case "$_tol_route_file:$_tol_route_fn" in
      post_apply_worker.sh:obs_worker_cleanup) _tol_route_abort=$(printf '%s\n' "$_tol_route_body" | grep -n 'obs_abort_active_pool' | head -1 | cut -d: -f1) ;;
      *) _tol_route_abort=$(printf '%s\n' "$_tol_route_body" | grep -n 'mnj_pool_abort_active' | head -1 | cut -d: -f1) ;;
    esac
    _tol_route_release_line=$(printf '%s\n' "$_tol_route_body" | grep -E -n "$_tol_route_release" | head -1 | cut -d: -f1)
    if [ -n "$_tol_route_abort" ] && [ -n "$_tol_route_release_line" ] &&
       [ "$_tol_route_abort" -lt "$_tol_route_release_line" ] 2>/dev/null; then
      pass "$_tol_route_label cleanup aborts pool before lock release"
    else
      fail "$_tol_route_label cleanup aborts pool before lock release"; _tol_ok=0
    fi
  done

  MERV_UPDATE_MAINTENANCE_LOCK="$SELFTEST_ROOT/observation-maintenance.lock"
  export MERV_UPDATE_MAINTENANCE_LOCK
  merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 0 0 observation-maintenance || return 1
  _tol_maint_nonce="$MERV_LOCK_NONCE"
  observation_reset || return 1
  if observation_worker request snapshot >/dev/null 2>&1; then
    fail "maintenance-blocked observation is refused"; _tol_ok=0
  else
    pass "maintenance-blocked observation is refused"
  fi
  _tol_requested=$(observation_number snapshot_requested_generation)
  [ -n "$_tol_requested" ] || _tol_requested=0
  [ "$_tol_requested" = 0 ] &&
    pass "maintenance-blocked observation does not increment generation" || {
      fail "maintenance-blocked observation does not increment generation"; _tol_ok=0;
    }
  merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$_tol_maint_nonce" || return 1
  unset MERV_UPDATE_MAINTENANCE_LOCK
  export MERV_UPDATE_MAINTENANCE_LOCK
  return "$_tol_ok"
}

test_observation_timeouts() {
  grep -q '_merv_timeout_run.*MERV_NVRAM_READ_TIMEOUT.*nvram show' \
      "$MERV_BASE/settings/mac_shield_snapshot.sh" &&
    pass "MAC snapshot NVRAM inventory uses a hard timeout" ||
    fail "MAC snapshot NVRAM inventory uses a hard timeout"

  _tot_start=$(date +%s)
  (
    . "$MERV_BASE/settings/lib_ssh.sh"
    merv_has() { return 1; }
    _merv_timeout_run 1 sh -c 'sleep 4'
  )
  _tot_rc=$?
  _tot_elapsed=$(( $(date +%s) - _tot_start ))
  [ "$_tot_rc" -eq 124 ] &&
    pass "timeout fallback returns 124 after terminating command" ||
    fail "timeout fallback returns 124 after terminating command"
  [ "$_tot_elapsed" -lt 4 ] &&
    pass "timeout fallback enforces deadline without timeout applet" ||
    fail "timeout fallback enforces deadline without timeout applet"

  _tot_pipe=$(
    printf 'stream-preserved\n' | (
      . "$MERV_BASE/settings/lib_ssh.sh"
      merv_has() { return 1; }
      _merv_timeout_run 2 sh -c 'cat'
    )
  )
  [ "$_tot_pipe" = "stream-preserved" ] &&
    pass "timeout fallback preserves piped standard input" ||
    fail "timeout fallback preserves piped standard input"
}

test_observation_generations() {
  selftest_reset || return 1
  observation_reset || return 1
  _tog_i=0
  while [ "$_tog_i" -lt 12 ]; do
    observation_worker request snapshot collect >/dev/null || fail "generation request $_tog_i"
    _tog_i=$((_tog_i + 1))
  done
  assert_ok "coalesced generations drain" observation_worker run
  [ "$(grep -c '^snapshot$' "$OBS_TEST_LOG" 2>/dev/null)" = 1 ] &&
    [ "$(grep -c '^collection$' "$OBS_TEST_LOG" 2>/dev/null)" = 1 ] &&
    pass "many requests coalesce into one snapshot and collection" ||
    fail "many requests coalesce into one snapshot and collection"
  [ "$(observation_number snapshot_completed_generation)" = 12 ] &&
    [ "$(observation_number collection_completed_generation)" = 12 ] &&
    pass "completed counters catch exact requested generations" ||
    fail "completed counters catch exact requested generations"

  observation_reset || return 1
  : > "$SELFTEST_ROOT/obs-request-during"
  observation_worker request snapshot >/dev/null || return 1
  assert_ok "request arriving during snapshot remains visible" observation_worker run
  [ "$(grep -c '^snapshot$' "$OBS_TEST_LOG" 2>/dev/null)" = 2 ] &&
    [ "$(observation_number snapshot_requested_generation)" = 2 ] &&
    [ "$(observation_number snapshot_completed_generation)" = 2 ] &&
    pass "in-flight generation is not lost" || fail "in-flight generation is not lost"

  observation_reset || return 1
  : > "$SELFTEST_ROOT/obs-snapshot-fail"
  observation_worker request snapshot collect >/dev/null || return 1
  assert_rc 1 "snapshot failure is reported" observation_worker run
  [ "$(observation_number snapshot_completed_generation)" = 0 ] &&
    [ "$(observation_number collection_completed_generation)" = 0 ] &&
    ! grep -q '^collection$' "$OBS_TEST_LOG" 2>/dev/null &&
    pass "snapshot failure leaves dependent collection pending" ||
    fail "snapshot failure leaves dependent collection pending"
  rm -f "$SELFTEST_ROOT/obs-snapshot-fail"
  assert_ok "pending failed generation resumes" observation_worker run
}

test_observation_concurrency() {
  selftest_reset || return 1
  observation_reset || return 1
  observation_worker request snapshot >/dev/null || return 1
  mkdir -p "$MERV_OBSERVATION_CONFIG_LOCKDIR/mervlan_manager.lock"
  printf '%s\n' "$$" > "$MERV_OBSERVATION_CONFIG_LOCKDIR/mervlan_manager.lock/pid"
  printf '%s\n' "$(date +%s)" > "$MERV_OBSERVATION_CONFIG_LOCKDIR/mervlan_manager.lock/created"
  assert_rc 75 "active manager defers observation" observation_worker run
  [ "$(observation_number snapshot_completed_generation)" = 0 ] &&
    pass "deferred manager generation remains pending" ||
    fail "deferred manager generation remains pending"
  ( sleep 2; rm -rf "$MERV_OBSERVATION_CONFIG_LOCKDIR/mervlan_manager.lock" ) &
  assert_ok "run-wait resumes exact generation after manager" \
    observation_worker run-wait 5

  observation_reset || return 1
  observation_worker request snapshot >/dev/null || return 1
  : > "$SELFTEST_ROOT/obs-snapshot-kill-worker"
  observation_worker run >/dev/null 2>&1
  [ "$(observation_number snapshot_completed_generation)" = 0 ] &&
    pass "worker death leaves generation pending" ||
    fail "worker death leaves generation pending"
  rm -f "$SELFTEST_ROOT/obs-snapshot-kill-worker"
  assert_ok "dead worker lock is reclaimed by PID identity" observation_worker run
  [ "$(observation_number snapshot_completed_generation)" = 1 ] &&
    pass "reclaimed worker completes pending generation" ||
    fail "reclaimed worker completes pending generation"
}

test_observation_resume_progress() {
  selftest_reset || return 1
  observation_reset || return 1
  _torp_previous_root="${MERV_PROGRESS_ROOT:-}"
  _torp_token="resume-progress-contract"
  MERV_PROGRESS_ROOT="$SELFTEST_ROOT/resume-progress"
  MERV_OBS_RESUME_PROGRESS_TOKEN="$_torp_token"
  export MERV_PROGRESS_ROOT MERV_OBS_RESUME_PROGRESS_TOKEN
  case "$MERV_PROGRESS_ROOT" in "$SELFTEST_ROOT"/*) ;; *) return 1 ;; esac
  rm -rf "$MERV_PROGRESS_ROOT" 2>/dev/null || return 1
  observation_worker request snapshot collect >/dev/null || return 1
  assert_ok "resume observation worker drains queued work" observation_worker run
  _torp_progress="$MERV_PROGRESS_ROOT/$_torp_token.json"
  if [ -s "$_torp_progress" ] &&
     grep -Fq '"action":"sshtrustresume_vlanmgr"' "$_torp_progress" &&
     grep -Fq '"phase":"collect"' "$_torp_progress" &&
     grep -Fq '"message":"Refreshing client inventory..."' "$_torp_progress"; then
    pass "resume collection relays coordinator phases to its loading task"
  else
    fail "resume collection relays coordinator phases to its loading task"
  fi
  rm -rf "$MERV_PROGRESS_ROOT" 2>/dev/null || return 1
  MERV_PROGRESS_ROOT="$_torp_previous_root"
  unset MERV_OBS_RESUME_PROGRESS_TOKEN
  export MERV_PROGRESS_ROOT
}

test_atomic_publication() {
  _tap_file="$MERV_BASE/functions/collect_clients.sh"
  if [ -f "$_tap_file" ]; then
    grep -q 'OUT_WORK="${OUT_FINAL}.new.$$"' "$_tap_file" &&
      pass "client JSON work file shares destination directory" ||
      fail "client JSON work file shares destination directory"
    grep -q 'mv "$OUT_WORK" "$OUT_FINAL".*||' "$_tap_file" &&
      pass "client JSON publication checks atomic rename" ||
      fail "client JSON publication checks atomic rename"
    grep -A6 'mv "$OUT_WORK" "$OUT_FINAL"' "$_tap_file" |
      grep -q 'exit 1' &&
      pass "publication failure propagates and preserves prior JSON" ||
      fail "publication failure propagates and preserves prior JSON"
  else
    pass "cluster JSON publication checks skipped on node-only installation"
  fi
  grep -q 'OBS_SNAPSHOT_RESET_CURRENT' "$MERV_BASE/functions/post_apply_worker.sh" &&
    grep -q 'MERV_MAC_SNAPSHOT_ALLOW_EMPTY=1' "$MERV_BASE/functions/post_apply_worker.sh" &&
    pass "manual reset mode is confined to coordinated complete snapshot" ||
    fail "manual reset mode is confined to coordinated complete snapshot"
  grep -q 'json_validate_file "$OUT_WORK"' "$MERV_BASE/functions/collect_clients.sh" &&
    grep -q 'json_validate_file "$MAIN_JSON"' "$MERV_BASE/functions/collect_clients.sh" &&
    pass "client artifacts are validated before publication" ||
    fail "client artifacts are validated before publication"
}

test_json_validation() {
  _tjv_valid="$SELFTEST_ROOT/client-valid.json"
  _tjv_invalid="$SELFTEST_ROOT/client-invalid.json"
  cat > "$_tjv_valid" <<'EOF'
{
  "generated": "2026-08-03T15:00:00",
  "run_id": "run-1",
  "nodes": [
    {
      "generated": "2026-08-03T15:00:00",
      "router": "Main Router",
      "ip": "192.168.1.1",
      "vlans": [
        {
          "id": "189",
          "interfaces": [],
          "clients": [
            {"mac": "e4:2a:ac:5d:48:b6", "source_iface": "eth0.189", "source_type": "trunk-tagged", "source_port": "eth0", "fdb_age": 8, "location_confidence": "relayed", "active": false, "locked": true, "override": false, "unshielded": false, "stale": false, "location_status": "relay_only", "diagnostic": true, "duplicate": true}
          ]
        }
      ]
    }  ],
  "stale_clients": [
    {"mac": "0c:54:15:06:67:1a", "name": "laptop", "active": false, "locked": false, "override": false, "unshielded": true, "stale": true}
  ]
}
EOF
  printf '%s\n' '{"nodes":[]}{"nodes":[]}' > "$_tjv_invalid"
  assert_ok "valid client JSON passes the shared validator" json_validate_file "$_tjv_valid"
  assert_rc 1 "concatenated client JSON is rejected" json_validate_file "$_tjv_invalid"
  grep -q 'json_validate_file "$OUT_TARGET"' "$MERV_BASE/functions/collect_local_clients.sh" 2>/dev/null ||
    grep -q 'json_validate_file "$OUT"' "$MERV_BASE/functions/collect_local_clients.sh" &&
    pass "local client artifacts use the shared validator" ||
    fail "local client artifacts use the shared validator"
}

test_client_refresh_contract() {
  _tcr_heal="$MERV_BASE/functions/heal_event.sh"
  _tcr_collect="$MERV_BASE/functions/collect_clients.sh"
  _tcr_worker="$MERV_BASE/functions/post_apply_worker.sh"
  _tcr_local="$MERV_BASE/functions/collect_local_clients.sh"
  _tcr_html="$MERV_BASE/www/index.html"
  _tcr_settings="$MERV_BASE/settings/settings.json"

  _tcr_cron=$(sed -n '/if \[ "$EVENT" = "cron" \]; then/,/^[[:space:]]*exit 0/p' "$_tcr_heal" 2>/dev/null)
  printf '%s\n' "$_tcr_cron" | grep -q 'request snapshot' &&
    ! printf '%s\n' "$_tcr_cron" | grep -q 'request snapshot collect' &&
    pass "health cron requests snapshot without client collection" ||
    fail "health cron requests snapshot without client collection"

  grep -q 'request snapshot collect' "$MERV_BASE/functions/mervlan_manager.sh" &&
    grep -q 'request snapshot collect' "$MERV_BASE/functions/execute_nodes.sh" &&
    grep -q 'request collect' "$MERV_BASE/functions/service-event-handler.sh" &&
    pass "non-cron collection callers remain enabled" ||
    fail "non-cron collection callers remain enabled"

  # The installed settings file is deliberately user-mutable.  Verify the
  # persisted key plus the UI's shipped default rather than requiring a live
  # router to still use that default.
  grep -q '"HTML_CLIENT_REFRESH_MINUTES"' "$_tcr_settings" &&
    grep -q 'HTML_CLIENT_REFRESH_MINUTES: "30"' "$_tcr_html" &&
    grep -q 'clientAutoRefreshCooldownMs' "$_tcr_html" &&
    grep -q 'clientGeneratedMs(snapshot)' "$_tcr_html" &&
    grep -q 'CLIENTS_AUTO_REFRESH_MINUTES_MAX = 1440' "$_tcr_html" &&
    pass "HTML client refresh setting has default and bounded parser" ||
    fail "HTML client refresh setting has default and bounded parser"

  grep -q 'MERV_OBS_CLIENT_ROUTER' "$_tcr_collect" &&
    grep -q 'MERV_OBS_CLIENT_ROUTER' "$_tcr_worker" &&
    grep -q 'NODE_IP="${3:-}"' "$_tcr_local" &&
    grep -q '"ip"' "$_tcr_local" &&
    pass "node collection preserves configured IP identity through worker" ||
    fail "node collection preserves configured IP identity through worker"

  if grep -Fq 'settings/lib_node_jobs.sh' "$_tcr_collect" &&
     grep -Fq 'mnj_pool_run' "$_tcr_collect" &&
     grep -Fq 'mnj_pool_run "$COLLECT_POOL_ROOT" collect' "$_tcr_collect" &&
     grep -Fq '"${MERV_NODE_PARALLELISM:-}"' "$_tcr_collect" &&
     grep -Fq 'mnj_result_validate' "$_tcr_collect" &&
     grep -Fq 'MERV_NODE_JOB_DIR/client.json' "$_tcr_collect" &&
     grep -Fq 'COLLECT_POOL_ROOT/node_' "$_tcr_collect" &&
     grep -Fq 'collect_main_bounded()' "$_tcr_collect" &&
     grep -Fq 'if ! collect_main_bounded; then' "$_tcr_collect" &&
     ! grep -Fq 'collect_from_node "$node_id" "$node_ip" "$COLLECTDIR' "$_tcr_collect"; then
    pass "client collection uses bounded remote pool with MAIN outside pool"
  else
    fail "client collection uses bounded remote pool with MAIN outside pool"
  fi

  grep -q "PRODUCTID_NODE' + i" "$_tcr_html" &&
    grep -q "formatName(alias" "$_tcr_html" &&
    grep -q "formatName('Main Router'" "$_tcr_html" &&
    pass "client display uses alias ProductID and IP" ||
    fail "client display uses alias ProductID and IP"

  grep -q 'info -c cli,vlan "Refreshing client list started"' "$_tcr_collect" &&
    grep -q 'info -c cli,vlan "Refreshing client list complete"' "$_tcr_collect" &&
    pass "successful client refresh keeps CLI routine logging concise" ||
    fail "successful client refresh keeps CLI routine logging concise"

  grep -q 'REQUIRED_RESULTS=' "$_tcr_collect" &&
    grep -q 'worker-nonzero' "$_tcr_collect" &&
    grep -q 'error-artifact' "$_tcr_collect" &&
    grep -q 'preserving previous inventory' "$_tcr_collect" &&
    grep -q 'client_collection_fault' "$_tcr_collect" &&
    pass "client collection requires a complete non-error generation before publication" ||
    fail "client collection requires a complete non-error generation before publication"

  grep -q 'obs_collection_failure_notice' "$_tcr_worker" &&
    grep -q 'client-collection-failed' "$_tcr_worker" &&
    grep -q 'fetchClientCollectionFailure' "$_tcr_html" &&
    grep -q 'showing the last known client data' "$_tcr_html" &&
    pass "failed client refresh publishes a terminal failure while retaining prior data" ||
    fail "failed client refresh publishes a terminal failure while retaining prior data"
}

test_manager_ownership() {
  _tmo_file="$MERV_BASE/functions/mervlan_manager.sh"
  [ -f "$_tmo_file" ] || { fail "manager ownership source present"; return 1; }
  grep -q 'merv_dhcp_hold_acquire manager' "$_tmo_file" &&
    pass "manager acquires token lease" || fail "manager acquires token lease"
  grep -q 'merv_dhcp_hold_mark_mutating.*MANAGER_DHCP_TOKEN' "$_tmo_file" &&
    pass "manager publishes mutating phase" || fail "manager publishes mutating phase"
  grep -q 'merv_dhcp_hold_mark_verified.*MANAGER_DHCP_TOKEN' "$_tmo_file" &&
    pass "manager publishes verified phase" || fail "manager publishes verified phase"
  grep -q 'merv_dhcp_hold_release.*MANAGER_DHCP_TOKEN' "$_tmo_file" &&
    pass "manager releases token specifically" || fail "manager releases token specifically"
  grep -q 'merv_dhcp_hold_abandon.*MANAGER_DHCP_TOKEN' "$_tmo_file" &&
    pass "manager exit path is phase-aware" || fail "manager exit path is phase-aware"
  grep -q 'merv_dhcp_handoff_ack.*MANAGER_HANDOFF_ID' "$_tmo_file" &&
    pass "manager validates exact handoff acknowledgement" || fail "manager validates exact handoff acknowledgement"
  grep -q 'merv_dhcp_hold_wait_stable' "$_tmo_file" &&
    pass "manager uses state-driven settle verification" || fail "manager uses state-driven settle verification"
  if grep -q 'merv_guarded_sleep.*WATCHDOG_DELAY_SEC' "$_tmo_file"; then
    fail "manager no longer bases completion on fixed watchdog delay"
  else
    pass "manager no longer bases completion on fixed watchdog delay"
  fi
  grep -q 'merv_dhcp_hold_clear_failsafes.*MANAGER_DHCP_TOKEN' "$_tmo_file" &&
    pass "verified manager clears failsafes through token API" ||
    fail "verified manager clears failsafes through token API"
  if grep -q '^[[:space:]]*merv_dhcp_hold_arm' "$_tmo_file"; then
    fail "manager no longer invokes legacy arm"
  else
    pass "manager no longer invokes legacy arm"
  fi
  _tmo_acquire=$(grep -n 'merv_dhcp_hold_acquire manager' "$_tmo_file" | head -n1 | cut -d: -f1)
  _tmo_mutate=$(grep -n 'merv_dhcp_hold_mark_mutating.*MANAGER_DHCP_TOKEN' "$_tmo_file" | head -n1 | cut -d: -f1)
  # The production caller intentionally checks the cleanup return status with
  # `if ! cleanup_existing_config`; match the call rather than only a bare
  # command so this ordering contract remains valid after error handling is
  # made explicit.
  _tmo_cleanup=$(grep -n 'if ! cleanup_existing_config' "$_tmo_file" | head -n1 | cut -d: -f1)
  case "$_tmo_acquire:$_tmo_mutate:$_tmo_cleanup" in *[!0-9:]*|'::'|*::*)
    fail "manager lease ordering locations found"
    ;;
    *)
      if [ "$_tmo_acquire" -lt "$_tmo_mutate" ] && [ "$_tmo_mutate" -lt "$_tmo_cleanup" ]; then
        pass "manager acquires and marks before first cleanup mutation"
      else
        fail "manager acquires and marks before first cleanup mutation"
      fi
      ;;
  esac
}

test_node_job_logging() {
  _tnjl_root="$SELFTEST_ROOT/node-job-logging"
  rm -rf "$_tnjl_root" 2>/dev/null || return 1
  mkdir -p "$_tnjl_root/job1" "$_tnjl_root/job2" || return 1

  unset LOGROOT LOG_chan_cli LOG_chan_vlan LOG_SETTINGS_LOADED
  LOG_SYSLOG=0
  . "$MERV_BASE/settings/log_settings.sh"
  [ "$LOG_chan_cli" = "/tmp/mervlan_tmp/logs/cli_output.log" ] &&
    [ "$LOG_chan_vlan" = "/tmp/mervlan_tmp/logs/vlan_manager.log" ] &&
    pass "node task log defaults stay unchanged" ||
    fail "node task log defaults stay unchanged"
  [ "$LOG_chan_cli" != "$LOG_chan_vlan" ] &&
    pass "default CLI and VLAN task channels differ" ||
    fail "default CLI and VLAN task channels differ"

  LOGROOT="$_tnjl_root/default"
  LOG_chan_cli="$_tnjl_root/job1/cli.log"
  LOG_chan_vlan="$_tnjl_root/job1/vlan.log"
  info -c cli,vlan "node-job-one"
  [ "$(grep -c 'node-job-one' "$LOG_chan_cli" 2>/dev/null)" = 1 ] &&
    [ "$(grep -c 'node-job-one' "$LOG_chan_vlan" 2>/dev/null)" = 1 ] &&
    pass "task CLI and VLAN channels do not duplicate one file" ||
    fail "task CLI and VLAN channels do not duplicate one file"

  LOG_chan_cli="$_tnjl_root/job2/cli.log"
  LOG_chan_vlan="$_tnjl_root/job2/vlan.log"
  info -c cli,vlan "node-job-two"
  [ -f "$_tnjl_root/job1/cli.log" ] && [ -f "$_tnjl_root/job1/vlan.log" ] &&
    [ -f "$_tnjl_root/job2/cli.log" ] && [ -f "$_tnjl_root/job2/vlan.log" ] &&
    ! grep -q 'node-job-two' "$_tnjl_root/job1/cli.log" 2>/dev/null &&
    ! grep -q 'node-job-one' "$_tnjl_root/job2/cli.log" 2>/dev/null &&
    pass "simulated workers use distinct task logs" ||
    fail "simulated workers use distinct task logs"
}

test_node_job_ssh_temp() {
  _tnst_root="$SELFTEST_ROOT/node-job-ssh-temp"
  rm -rf "$_tnst_root" 2>/dev/null || return 1
  mkdir -p "$_tnst_root/job1/ssh" "$_tnst_root/job2/ssh" || return 1
  : > "$_tnst_root/paths" || return 1

  unset LIB_SSH_LOADED
  . "$MERV_BASE/settings/lib_ssh.sh"
  MERV_SSH_RETRIES=1
  MERV_SSH_TEST_PATHS="$_tnst_root/paths"
  merv_ssh_precheck() { return 0; }
  # The production wrapper now requires a verified host-key record before it
  # creates the client known_hosts file.  This test replaces that boundary
  # because it exercises only worker-local stderr allocation and cleanup.
  merv_ssh_prepare_known_host() { return 0; }
  get_node_ssh_port() { printf '22\n'; }
  get_node_ssh_user() { printf 'admin\n'; }
  _merv_timeout_run() { _tnst_sec="$1"; shift; "$@"; }
  dbclient() {
    printf '%s\n' "${MERV_SSH_ERR_FILE:-}" >> "$MERV_SSH_TEST_PATHS"
    sleep 1
    return 0
  }

  (
    MERV_NODE_JOB_DIR="$_tnst_root/job1"
    MERV_SSH_TMPDIR="$MERV_NODE_JOB_DIR/ssh"
    export MERV_NODE_JOB_DIR MERV_SSH_TMPDIR
    merv_ssh_exec 1 192.0.2.1 true >/dev/null
  ) &
  _tnst_one=$!
  (
    MERV_NODE_JOB_DIR="$_tnst_root/job2"
    MERV_SSH_TMPDIR="$MERV_NODE_JOB_DIR/ssh"
    export MERV_NODE_JOB_DIR MERV_SSH_TMPDIR
    merv_ssh_exec 2 192.0.2.2 true >/dev/null
  ) &
  _tnst_two=$!
  wait "$_tnst_one" && wait "$_tnst_two" || {
    fail "simulated SSH calls complete"
    return 1
  }
  [ "$(sed -n '1p' "$_tnst_root/paths")" != "$(sed -n '2p' "$_tnst_root/paths")" ] &&
    grep -q "^$_tnst_root/job1/ssh/ssh_err\." "$_tnst_root/paths" &&
    grep -q "^$_tnst_root/job2/ssh/ssh_err\." "$_tnst_root/paths" &&
    pass "concurrent SSH calls use distinct job-contained stderr files" ||
    fail "concurrent SSH calls use distinct job-contained stderr files"
  [ -z "$(find "$_tnst_root/job1/ssh" "$_tnst_root/job2/ssh" -type f -print 2>/dev/null)" ] &&
    pass "SSH stderr files are cleaned from their own job roots" ||
    fail "SSH stderr files are cleaned from their own job roots"
}

test_node_runner_status() {
  _tnrs_root="$SELFTEST_ROOT/node-runner-status"
  _tnrs_runner="$MERV_BASE/functions/mervlan_node_runner.sh"
  rm -rf "$_tnrs_root" 2>/dev/null || return 1
  mkdir -p "$_tnrs_root" || return 1
  [ -f "$_tnrs_runner" ] || { fail "node runner source present"; return 1; }

  _tnrs_ok="$_tnrs_root/manager-ok.sh"
  printf '#!/bin/sh\nsleep 1\nexit 0\n' > "$_tnrs_ok" || return 1
  _tnrs_start=$(MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" MERV_NODE_RUNNER_MANAGER="$_tnrs_ok" \
    sh "$_tnrs_runner" start 11-22 1) || { fail "node runner start acknowledgement"; return 1; }
  case "$_tnrs_start" in started|complete|failed) pass "node runner start acknowledgement" ;; *) fail "node runner start acknowledgement" ;; esac
  sleep 2
  _tnrs_status=$(MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" sh "$_tnrs_runner" status 11-22 1 2>/dev/null)
  printf '%s\n' "$_tnrs_status" | grep -q '^state=complete$' &&
    printf '%s\n' "$_tnrs_status" | grep -q '^exit_code=0$' &&
    [ -f "$_tnrs_root/runs/11-22/cli.log" ] &&
    [ -f "$_tnrs_root/runs/11-22/vlan.log" ] &&
    [ -f "$_tnrs_root/runs/11-22/stdout.log" ] &&
    pass "node runner publishes complete atomic status and per-run logs" ||
    fail "node runner publishes complete atomic status and per-run logs"

  _tnrs_fail="$_tnrs_root/manager-fail.sh"
  printf '#!/bin/sh\nsleep 1\nexit 7\n' > "$_tnrs_fail" || return 1
  MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" MERV_NODE_RUNNER_MANAGER="$_tnrs_fail" \
    sh "$_tnrs_runner" start 12-22 1 >/dev/null || { fail "node runner failure start acknowledgement"; return 1; }
  sleep 2
  _tnrs_status=$(MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" sh "$_tnrs_runner" status 12-22 1 2>/dev/null)
  printf '%s\n' "$_tnrs_status" | grep -q '^state=failed$' &&
    printf '%s\n' "$_tnrs_status" | grep -q '^exit_code=7$' &&
    pass "node runner publishes manager failure" ||
    fail "node runner publishes manager failure"

  _tnrs_kill="$_tnrs_root/manager-kill.sh"
  printf '#!/bin/sh\nsleep 10\n' > "$_tnrs_kill" || return 1
  MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" MERV_NODE_RUNNER_MANAGER="$_tnrs_kill" \
    sh "$_tnrs_runner" run 13-22 1 >/dev/null 2>&1 &
  _tnrs_pid=$!
  sleep 1
  kill -TERM "$_tnrs_pid" 2>/dev/null || :
  wait "$_tnrs_pid" 2>/dev/null || :
  _tnrs_status=$(MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" sh "$_tnrs_runner" status 13-22 1 2>/dev/null)
  printf '%s\n' "$_tnrs_status" | grep -q '^state=failed$' &&
    printf '%s\n' "$_tnrs_status" | grep -q '^reason=runner-terminated$' &&
    pass "killed runner publishes terminal failure" ||
    fail "killed runner publishes terminal failure"

  mkdir -p "$_tnrs_root/runs/1-2/ssh" || return 1
  printf 'format_version=1\nrun_id=1-2\nnode_id=1\nstate=complete\npid=1\nproc_start_time=1\nstarted_epoch=1\ncompleted_epoch=2\nexit_code=0\nreason=ok\n' > "$_tnrs_root/runs/1-2/node_1.status"
  : > "$_tnrs_root/runs/1-2/cli.log"
  : > "$_tnrs_root/runs/1-2/vlan.log"
  : > "$_tnrs_root/runs/1-2/stdout.log"
  : > "$_tnrs_root/runs/1-2/runner.log"
  MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" MERV_NODE_RUNNER_MANAGER="$_tnrs_ok" MERV_NODE_STATUS_RETENTION_SEC=1 \
    sh "$_tnrs_runner" start 17-22 1 >/dev/null || { fail "node runner retention start"; return 1; }
  [ ! -d "$_tnrs_root/runs/1-2" ] &&
    pass "node runner prunes only old validated terminal run" ||
    fail "node runner prunes only old validated terminal run"

  mkdir -p "$_tnrs_root/runs/14-22" || return 1
  printf 'format_version=1\nrun_id=14-22\nnode_id=1\nstate=complete\npid=1\nproc_start_time=1\nstarted_epoch=1\ncompleted_epoch=2\nexit_code=0\nreason=ok\nreason=duplicate\n' > "$_tnrs_root/runs/14-22/node_1.status"
  if MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" sh "$_tnrs_runner" status 14-22 1 >/dev/null 2>&1; then
    fail "node runner rejects duplicate status field"
  else
    pass "node runner rejects duplicate status field"
  fi
  mkdir -p "$_tnrs_root/runs/15-22" || return 1
  printf 'format_version=1\nrun_id=other-22\nnode_id=1\nstate=started\n' > "$_tnrs_root/runs/15-22/node_1.status"
  if MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" sh "$_tnrs_runner" status 15-22 1 >/dev/null 2>&1; then
    fail "node runner rejects wrong and partial status"
  else
    pass "node runner rejects wrong and partial status"
  fi
  mkdir -p "$_tnrs_root/runs/16-22" || return 1
  printf 'format_version=1\nrun_id=16-22\nnode_id=1\nstate=started\npid=1\nproc_start_time=1\nstarted_epoch=1\ncompleted_epoch=0\nexit_code=\nreason=started\nunknown=x\n' > "$_tnrs_root/runs/16-22/node_1.status"
  if MERV_NODE_STATUS_ROOT="$_tnrs_root/runs" sh "$_tnrs_runner" status 16-22 1 >/dev/null 2>&1; then
    fail "node runner rejects unknown status field"
  else
    pass "node runner rejects unknown status field"
  fi
}

node_job_test_handler() {
  _tnjh_node="$1" _tnjh_ip="$2"
  mkdir "$NODE_JOB_TEST_ROOT/active/$_tnjh_node" || exit 1
  trap 'rmdir "$NODE_JOB_TEST_ROOT/active/$_tnjh_node" 2>/dev/null || :; exit 143' TERM INT
  printf 'start %s\n' "$_tnjh_node" >> "$NODE_JOB_TEST_ROOT/events"
  while ! mkdir "$NODE_JOB_TEST_ROOT/count.lock" 2>/dev/null; do sleep 1; done
  _tnjh_count=$(find "$NODE_JOB_TEST_ROOT/active" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  _tnjh_max=$(cat "$NODE_JOB_TEST_ROOT/max" 2>/dev/null || printf '0')
  [ "$_tnjh_count" -gt "$_tnjh_max" ] 2>/dev/null && printf '%s\n' "$_tnjh_count" > "$NODE_JOB_TEST_ROOT/max"
  rmdir "$NODE_JOB_TEST_ROOT/count.lock" 2>/dev/null || :
  case "${NODE_JOB_TEST_SCENARIO:-pool}:$_tnjh_node" in
    pool:2) sleep 3; printf 'end %s\n' "$_tnjh_node" >> "$NODE_JOB_TEST_ROOT/events" ;;
    pool:3) sleep 1; rmdir "$NODE_JOB_TEST_ROOT/active/$_tnjh_node"; printf 'end %s\n' "$_tnjh_node" >> "$NODE_JOB_TEST_ROOT/events"; return 7 ;;
    setup-failure:1) sleep 10 ;;
    timeout:1) sleep 10 ;;
    # Hold the first batch behind a filesystem barrier.  A fixed sleep is not
    # deterministic on a busy BusyBox/Git shell: at widths 3--5 the parent can
    # take long enough to publish the final slot that an early worker exits
    # before the occupancy sample.  The barrier is released only after every
    # first-batch active marker and wrapper identity has been published.
    matrix:*)
      _tnjh_width="${NODE_JOB_TEST_WIDTH:-0}"
      case "$_tnjh_width" in ''|*[!0-9]*|0) _tnjh_width=1 ;; esac
      while :; do
        _tnjh_active=$(find "$NODE_JOB_TEST_ROOT/active" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        _tnjh_wrappers=0
        for _tnjh_wrapper in "$NODE_JOB_TEST_ROOT"/jobs/node_*/wrapper.pid; do
          [ -f "$_tnjh_wrapper" ] && _tnjh_wrappers=$((_tnjh_wrappers + 1))
        done
        if [ "${_tnjh_active:-0}" -ge "$_tnjh_width" ] 2>/dev/null &&
           [ "$_tnjh_wrappers" -ge "$_tnjh_width" ] 2>/dev/null; then
          : > "$NODE_JOB_TEST_ROOT/matrix.ready"
          break
        fi
        sleep 1
      done
      while [ ! -f "$NODE_JOB_TEST_ROOT/matrix.ready" ]; do sleep 1; done
      # Allow the launcher to finish publishing the last slot before any
      # worker can publish a terminal result and be reaped/reused.
      sleep 2
      printf 'end %s\n' "$_tnjh_node" >> "$NODE_JOB_TEST_ROOT/events"
      ;;
    *) sleep 1; printf 'end %s\n' "$_tnjh_node" >> "$NODE_JOB_TEST_ROOT/events" ;;
  esac
  rmdir "$NODE_JOB_TEST_ROOT/active/$_tnjh_node"
}

node_job_abort_test_handler() {
  sleep 30
}

node_job_progress_hook() {
  printf 'progress\n' >> "$NODE_JOB_TEST_ROOT/progress"
}

test_node_worker_pool() {
  _tnwp_root="$SELFTEST_ROOT/node-jobs/pool"
  rm -rf "$SELFTEST_ROOT/node-jobs" 2>/dev/null || return 1
  mkdir -p "$_tnwp_root/active" || return 1
  NODE_JOB_TEST_ROOT="$_tnwp_root"; export NODE_JOB_TEST_ROOT
  printf '0\n' > "$_tnwp_root/max"
  mkdir "$_tnwp_root/parent.lock" || return 1
  printf 'parent-owned\n' > "$_tnwp_root/parent.lock/owner"
  NODE_JOB_TEST_SCENARIO=pool; export NODE_JOB_TEST_SCENARIO
  MNJ_POOL_PROGRESS_HOOK=node_job_progress_hook
  printf '1 192.0.2.1\n2 192.0.2.2\n3 192.0.2.3\n' > "$_tnwp_root/nodes"
  . "$MERV_BASE/settings/lib_node_jobs.sh"
  if mnj_pool_run "$_tnwp_root" testphase 2 6 "$_tnwp_root/nodes" node_job_test_handler; then
    fail "worker pool reports failed worker"
  else
    pass "worker pool reports failed worker"
  fi
  [ "$(cat "$_tnwp_root/max")" -le 2 ] 2>/dev/null &&
    [ -f "$_tnwp_root/node_1/result" ] && [ -f "$_tnwp_root/node_2/result" ] && [ -f "$_tnwp_root/node_3/result" ] &&
    [ -f "$_tnwp_root/node_1/cli.log" ] && [ -f "$_tnwp_root/node_1/vlan.log" ] && [ -d "$_tnwp_root/node_1/ssh" ] &&
    pass "worker pool bounds concurrency and isolates worker paths" ||
    fail "worker pool bounds concurrency and isolates worker paths"
  mnj_result_validate "$_tnwp_root/node_1/result" 1 testphase && [ "$MNJ_RESULT_STATE" = ok ] &&
    mnj_result_validate "$_tnwp_root/node_3/result" 3 testphase && [ "$MNJ_RESULT_STATE" = failed ] &&
    pass "worker pool publishes success and failure results" ||
    fail "worker pool publishes success and failure results"
  [ "$(cat "$_tnwp_root/parent.lock/owner" 2>/dev/null)" = parent-owned ] &&
    pass "workers retain parent-owned lock state" ||
    fail "workers retain parent-owned lock state"
  [ -s "$_tnwp_root/progress" ] &&
    pass "worker pool progress hook runs only in parent" ||
    fail "worker pool progress hook runs only in parent"
  MNJ_POOL_PROGRESS_HOOK=""

  # Verify the generic abort arguments are carried into a terminal result even
  # when a pending publication has no signalable identity.  This is a pure
  # metadata case; no PID-only signal is permitted.
  _tnwp_abort_exact="$_tnwp_root/abort-exact"
  rm -rf "$_tnwp_abort_exact" 2>/dev/null || :
  mkdir -p "$_tnwp_abort_exact/node_1" || return 1
  MNJ_POOL_ROOT="$_tnwp_abort_exact"; MNJ_POOL_PHASE=abortphase; MNJ_POOL_ACTIVE=1
  MNJ_POOL_PENDING_PID=999999; MNJ_POOL_PENDING_START=''
  MNJ_POOL_PENDING_DIR="$_tnwp_abort_exact/node_1"; MNJ_POOL_PENDING_NODE=1
  if mnj_pool_abort_active failed exact-reason &&
     mnj_result_validate "$_tnwp_abort_exact/node_1/result" 1 abortphase &&
     [ "$MNJ_RESULT_STATE" = failed ] && [ "$MNJ_RESULT_REASON" = exact-reason ]; then
    pass "node pool abort accepts generic state and reason"
  else
    fail "node pool abort accepts generic state and reason"
  fi
  rm -rf "$_tnwp_abort_exact" 2>/dev/null || :

  # Exercise every supported width with one more job than available slots.
  # The handler records active occupancy and start/end ordering.  N+1 can only
  # start after an earlier end, proving a completed slot is reaped and reused;
  # the active maximum proves the pool never exceeds its configured width.
  _tnwp_matrix_ok=1
  for _tnwp_parallel in 1 2 3 4 5; do
    _tnwp_matrix="$SELFTEST_ROOT/node-jobs/matrix-$_tnwp_parallel"
    rm -rf "$_tnwp_matrix" 2>/dev/null || :
    mkdir -p "$_tnwp_matrix/active" || { fail "worker pool matrix N=$_tnwp_parallel fixture setup"; _tnwp_matrix_ok=0; continue; }
    NODE_JOB_TEST_ROOT="$_tnwp_matrix"; export NODE_JOB_TEST_ROOT
    NODE_JOB_TEST_SCENARIO=matrix; export NODE_JOB_TEST_SCENARIO
    NODE_JOB_TEST_WIDTH="$_tnwp_parallel"; export NODE_JOB_TEST_WIDTH
    printf '0\n' > "$_tnwp_matrix/max"
    : > "$_tnwp_matrix/events"
    : > "$_tnwp_matrix/nodes"
    _tnwp_node=1
    while [ "$_tnwp_node" -le $((_tnwp_parallel + 1)) ]; do
      printf '%s 192.0.2.%s\n' "$_tnwp_node" "$_tnwp_node" >> "$_tnwp_matrix/nodes"
      _tnwp_node=$((_tnwp_node + 1))
    done
    if mnj_pool_run "$_tnwp_matrix/jobs" "matrix$_tnwp_parallel" "$_tnwp_parallel" 15 "$_tnwp_matrix/nodes" node_job_test_handler; then
      :
    else
      fail "worker pool N=$_tnwp_parallel reports failure"; _tnwp_matrix_ok=0
    fi
    _tnwp_observed_max=$(cat "$_tnwp_matrix/max" 2>/dev/null || printf 0)
    if [ "$_tnwp_observed_max" -eq "$_tnwp_parallel" ] 2>/dev/null; then
      pass "worker pool N=$_tnwp_parallel never exceeds configured width"
    else
      fail "worker pool N=$_tnwp_parallel never exceeds configured width (max=$_tnwp_observed_max)"; _tnwp_matrix_ok=0
    fi
    _tnwp_starts=$(grep -c '^start ' "$_tnwp_matrix/events" 2>/dev/null || :)
    _tnwp_ends=$(grep -c '^end ' "$_tnwp_matrix/events" 2>/dev/null || :)
    [ "$_tnwp_starts" -eq $((_tnwp_parallel + 1)) ] && [ "$_tnwp_ends" -eq $((_tnwp_parallel + 1)) ] &&
      pass "worker pool N=$_tnwp_parallel starts and reaps N+1 jobs" || {
        fail "worker pool N=$_tnwp_parallel starts/reaps N+1 jobs (starts=$_tnwp_starts ends=$_tnwp_ends)"; _tnwp_matrix_ok=0;
      }
    _tnwp_first_end=$(awk '$1 == "end" { print NR; exit }' "$_tnwp_matrix/events" 2>/dev/null || printf 0)
    _tnwp_extra_start=$(awk -v node=$((_tnwp_parallel + 1)) '$1 == "start" && $2 == node { print NR; exit }' "$_tnwp_matrix/events" 2>/dev/null || printf 0)
    [ "$_tnwp_first_end" -gt 0 ] 2>/dev/null && [ "$_tnwp_extra_start" -gt "$_tnwp_first_end" ] 2>/dev/null &&
      pass "worker pool N=$_tnwp_parallel reuses a reaped slot for job N+1" || {
        fail "worker pool N=$_tnwp_parallel reuses a reaped slot for job N+1"; _tnwp_matrix_ok=0;
      }
    _tnwp_active_left=$(find "$_tnwp_matrix/active" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    [ "$_tnwp_active_left" -eq 0 ] 2>/dev/null &&
      pass "worker pool N=$_tnwp_parallel leaves no active slots" || {
        fail "worker pool N=$_tnwp_parallel leaves no active slots"; _tnwp_matrix_ok=0;
      }
    _tnwp_node=1
    while [ "$_tnwp_node" -le $((_tnwp_parallel + 1)) ]; do
      if mnj_result_validate "$_tnwp_matrix/jobs/node_$_tnwp_node/result" "$_tnwp_node" "matrix$_tnwp_parallel" &&
         [ "$MNJ_RESULT_STATE" = ok ]; then
        :
      else
        fail "worker pool N=$_tnwp_parallel publishes node $_tnwp_node result"; _tnwp_matrix_ok=0
      fi
      _tnwp_node=$((_tnwp_node + 1))
    done
  done
  [ "$_tnwp_matrix_ok" -eq 1 ] || return 1

  # Force a post-launch setup failure on the second node.  The first worker
  # must be reconciled even though its slot was already published, and the
  # pool must leave a terminal result with no handler activity behind.
  _tnwp_setup="$SELFTEST_ROOT/node-jobs/setup-failure"
  rm -rf "$_tnwp_setup" 2>/dev/null || :
  mkdir -p "$_tnwp_setup/active" "$_tnwp_setup/jobs/node_2" || return 1
  NODE_JOB_TEST_ROOT="$_tnwp_setup"; export NODE_JOB_TEST_ROOT
  NODE_JOB_TEST_SCENARIO=setup-failure; export NODE_JOB_TEST_SCENARIO
  printf '0\n' > "$_tnwp_setup/max"
  printf '1 192.0.2.1\n2 192.0.2.2\n' > "$_tnwp_setup/nodes"
  if mnj_pool_run "$_tnwp_setup/jobs" setupfailure 2 10 "$_tnwp_setup/nodes" node_job_test_handler; then
    fail "worker pool setup failure is reported"
  else
    pass "worker pool setup failure is reported"
  fi
  mnj_result_validate "$_tnwp_setup/jobs/node_1/result" 1 setupfailure && [ "$MNJ_RESULT_STATE" != ok ] &&
    pass "worker pool reconciles published slot after setup failure" ||
    fail "worker pool reconciles published slot after setup failure"
  ! mnj_child_identity_live "$_tnwp_setup/jobs/node_1" &&
    [ -z "$MNJ_S1_PID$MNJ_S2_PID$MNJ_S3_PID$MNJ_S4_PID$MNJ_S5_PID" ] &&
    pass "worker pool setup failure leaves no live workers or slots" ||
    fail "worker pool setup failure leaves no live workers or slots"

  # Exercise the parent-abort contract with one pending wrapper plus each
  # supported total slot count (1 through 5).  The test uses real worker
  # wrappers and process start identities, so each case covers TERM/KILL,
  # pending publication, reaping, terminal-result publication, and metadata
  # clearing without relying on a synthetic PID fixture.  Alternate terminal
  # states prove the generic <state> <reason> API rather than one hard-coded
  # setup-failure result.
  _tnwp_abort_matrix_ok=1
  for _tnwp_abort_total in 1 2 3 4 5; do
    _tnwp_abort="$_tnwp_root/abort-$_tnwp_abort_total"
    rm -rf "$_tnwp_abort" 2>/dev/null || :
    mkdir -p "$_tnwp_abort" || { fail "node pool abort N=$_tnwp_abort_total fixture setup"; _tnwp_abort_matrix_ok=0; continue; }
    case "$_tnwp_abort_total" in 1|3|5) _tnwp_abort_state=failed ;; *) _tnwp_abort_state=timeout ;; esac
    MNJ_POOL_ROOT="$_tnwp_abort"; MNJ_POOL_PHASE=abortphase; MNJ_POOL_ACTIVE=1
    MNJ_POOL_PENDING_PID=''; MNJ_POOL_PENDING_START=''; MNJ_POOL_PENDING_DIR=''; MNJ_POOL_PENDING_NODE=''
    MNJ_S1_PID=''; MNJ_S2_PID=''; MNJ_S3_PID=''; MNJ_S4_PID=''; MNJ_S5_PID=''
    MNJ_S1_START=''; MNJ_S2_START=''; MNJ_S3_START=''; MNJ_S4_START=''; MNJ_S5_START=''
    MNJ_S1_DIR=''; MNJ_S2_DIR=''; MNJ_S3_DIR=''; MNJ_S4_DIR=''; MNJ_S5_DIR=''
    MNJ_S1_NODE=''; MNJ_S2_NODE=''; MNJ_S3_NODE=''; MNJ_S4_NODE=''; MNJ_S5_NODE=''
    MNJ_S1_DEADLINE=''; MNJ_S2_DEADLINE=''; MNJ_S3_DEADLINE=''; MNJ_S4_DEADLINE=''; MNJ_S5_DEADLINE=''

    # Publish total-1 workers into slots 1..N-1; leave node N pending.
    _tnwp_abort_slot=1
    while [ "$_tnwp_abort_slot" -lt "$_tnwp_abort_total" ]; do
      _tnwp_abort_dir="$_tnwp_abort/node_$_tnwp_abort_slot"
      mkdir -p "$_tnwp_abort_dir" || { fail "node pool abort N=$_tnwp_abort_total slot setup"; _tnwp_abort_matrix_ok=0; break; }
      ( mnj_worker "$_tnwp_abort_dir" "$_tnwp_abort_slot" abortphase node_job_abort_test_handler "$_tnwp_abort_slot" "192.0.2.$_tnwp_abort_slot" ) </dev/null &
      _tnwp_abort_pid=$!
      _tnwp_abort_start=$(merv_proc_start_time "$_tnwp_abort_pid" 2>/dev/null || printf '')
      MNJ_POOL_PENDING_PID="$_tnwp_abort_pid"; MNJ_POOL_PENDING_START="$_tnwp_abort_start"
      MNJ_POOL_PENDING_DIR="$_tnwp_abort_dir"; MNJ_POOL_PENDING_NODE="$_tnwp_abort_slot"
      printf '%s\n' "$_tnwp_abort_pid" > "$_tnwp_abort_dir/wrapper.pid" || { fail "node pool abort N=$_tnwp_abort_total wrapper PID"; _tnwp_abort_matrix_ok=0; break; }
      printf '%s\n' "$_tnwp_abort_start" > "$_tnwp_abort_dir/wrapper.proc_start_time" || { fail "node pool abort N=$_tnwp_abort_total wrapper identity"; _tnwp_abort_matrix_ok=0; break; }
      mnj_slot_set "$_tnwp_abort_slot" "$_tnwp_abort_pid" "$_tnwp_abort_start" "$_tnwp_abort_dir" "$_tnwp_abort_slot" 999999999
      MNJ_POOL_PENDING_PID=''; MNJ_POOL_PENDING_START=''; MNJ_POOL_PENDING_DIR=''; MNJ_POOL_PENDING_NODE=''
      _tnwp_abort_slot=$((_tnwp_abort_slot + 1))
    done
    _tnwp_abort_dir="$_tnwp_abort/node_$_tnwp_abort_total"
    mkdir -p "$_tnwp_abort_dir" || { fail "node pool abort N=$_tnwp_abort_total pending setup"; _tnwp_abort_matrix_ok=0; continue; }
    ( mnj_worker "$_tnwp_abort_dir" "$_tnwp_abort_total" abortphase node_job_abort_test_handler "$_tnwp_abort_total" "192.0.2.$_tnwp_abort_total" ) </dev/null &
    MNJ_POOL_PENDING_PID=$!; MNJ_POOL_PENDING_START=$(merv_proc_start_time "$MNJ_POOL_PENDING_PID" 2>/dev/null || printf '')
    MNJ_POOL_PENDING_DIR="$_tnwp_abort_dir"; MNJ_POOL_PENDING_NODE="$_tnwp_abort_total"

    if mnj_pool_abort_active "$_tnwp_abort_state" parent-term; then
      pass "node pool abort N=$_tnwp_abort_total accepts state=$_tnwp_abort_state reason=parent-term"
    else
      fail "node pool abort N=$_tnwp_abort_total accepts state=$_tnwp_abort_state reason=parent-term"; _tnwp_abort_matrix_ok=0
    fi
    [ "${MNJ_POOL_ACTIVE:-1}" -eq 0 ] &&
      [ -z "$MNJ_POOL_PENDING_PID$MNJ_POOL_PENDING_START$MNJ_POOL_PENDING_DIR$MNJ_POOL_PENDING_NODE" ] &&
      [ -z "$MNJ_S1_PID$MNJ_S2_PID$MNJ_S3_PID$MNJ_S4_PID$MNJ_S5_PID" ] &&
      pass "node pool abort N=$_tnwp_abort_total clears metadata after identity-safe reap" || {
        fail "node pool abort N=$_tnwp_abort_total clears metadata after identity-safe reap"; _tnwp_abort_matrix_ok=0;
      }
    _tnwp_abort_ok=1
    _tnwp_abort_node=1
    while [ "$_tnwp_abort_node" -le "$_tnwp_abort_total" ]; do
      if mnj_result_validate "$_tnwp_abort/node_$_tnwp_abort_node/result" "$_tnwp_abort_node" abortphase &&
         case "$MNJ_RESULT_STATE" in failed|timeout) true ;; *) false ;; esac &&
         case "$MNJ_RESULT_REASON" in parent-term|worker-term-timeout) true ;; *) false ;; esac &&
         ! mnj_child_identity_live "$_tnwp_abort/node_$_tnwp_abort_node"; then
        :
      else
        fail "node pool abort N=$_tnwp_abort_total publishes/reaps node $_tnwp_abort_node"; _tnwp_abort_ok=0
      fi
      _tnwp_abort_node=$((_tnwp_abort_node + 1))
    done
    [ "$_tnwp_abort_ok" -eq 1 ] && pass "node pool abort N=$_tnwp_abort_total publishes state=$_tnwp_abort_state for pending+slots" || _tnwp_abort_matrix_ok=0
    rm -rf "$_tnwp_abort" 2>/dev/null || :
  done
  [ "$_tnwp_abort_matrix_ok" -eq 1 ] || return 1

  _tnwp_timeout="$SELFTEST_ROOT/node-jobs/timeout"
  mkdir -p "$_tnwp_timeout/active" || return 1
  NODE_JOB_TEST_ROOT="$_tnwp_timeout"; export NODE_JOB_TEST_ROOT
  NODE_JOB_TEST_SCENARIO=timeout; export NODE_JOB_TEST_SCENARIO
  printf '0\n' > "$_tnwp_timeout/max"
  printf '1 192.0.2.1\n' > "$_tnwp_timeout/nodes"
  if mnj_pool_run "$_tnwp_timeout" timeoutphase 1 1 "$_tnwp_timeout/nodes" node_job_test_handler; then
    fail "worker pool timeout is reported"
  else
    pass "worker pool timeout is reported"
  fi
  mnj_result_validate "$_tnwp_timeout/node_1/result" 1 timeoutphase && [ "$MNJ_RESULT_STATE" = timeout ] &&
    pass "worker timeout publishes terminal result before slot release" ||
    fail "worker timeout publishes terminal result before slot release"

  printf '1 192.0.2.1\n1 192.0.2.2\n' > "$_tnwp_timeout/duplicate-id"
  if mnj_pool_run "$_tnwp_timeout/duplicate-id-run" duplicate 1 1 "$_tnwp_timeout/duplicate-id" node_job_test_handler; then
    fail "worker pool rejects duplicate node IDs"
  else
    [ ! -d "$_tnwp_timeout/duplicate-id-run/node_1" ] &&
      pass "worker pool rejects duplicate node IDs before launch" ||
      fail "worker pool rejects duplicate node IDs before launch"
  fi
  printf '1 192.0.2.1\n2 192.0.2.1\n' > "$_tnwp_timeout/duplicate-ip"
  if mnj_pool_run "$_tnwp_timeout/duplicate-ip-run" duplicate 1 1 "$_tnwp_timeout/duplicate-ip" node_job_test_handler; then
    fail "worker pool rejects duplicate node IPs"
  else
    [ ! -d "$_tnwp_timeout/duplicate-ip-run/node_1" ] &&
      pass "worker pool rejects duplicate node IPs before launch" ||
      fail "worker pool rejects duplicate node IPs before launch"
  fi
}

# The pool test above includes the TERM/KILL reconciliation path.  Keep the
# named entry point required by the bounded-node regression contract.
test_node_worker_timeout() {
  test_node_worker_pool
}

test_execute_node_runner_contract() {
  _tener_file="$MERV_BASE/functions/execute_nodes.sh"
  _tener_verify=$(sed -n '/^verify_settings_conf_on_node() {/,/^sync_settings_conf_for_node() {/p' "$_tener_file" 2>/dev/null)
  grep -q 'MERV_EXEC_NODES_LOCK_STALE_SEC' "$_tener_file" &&
    grep -q 'mervlan_node_runner.sh' "$_tener_file" &&
    grep -q 'execute_status_valid' "$_tener_file" &&
    grep -q 'fetch_node_runner_logs' "$_tener_file" &&
    grep -q 'mnj_pool_run.*prepare' "$_tener_file" &&
    grep -q 'mnj_pool_run.*launch' "$_tener_file" &&
    grep -q 'mnj_pool_run.*status' "$_tener_file" &&
    grep -q 'duplicate node ID' "$_tener_file" &&
    grep -q 'mnj_result_validate.*prepare' "$_tener_file" &&
    grep -q 'mnj_result_validate.*launch' "$_tener_file" &&
    grep -q 'No node launches acknowledged' "$_tener_file" &&
    ! grep -q 'if false; then' "$_tener_file" &&
    ! grep -q 'clear_node_completion_marker' "$_tener_file" &&
    ! grep -Eq '^[[:space:]]*wait[[:space:]]*$' "$_tener_file" &&
    ! grep -q '/tmp/mervlan_tmp/results/node_complete' "$_tener_file" &&
    pass "execute uses run-specific detached runner status" ||
    fail "execute uses run-specific detached runner status"
  if printf '%s\n' "$_tener_verify" | grep -Fq 'type sha256sum >/dev/null 2>&1' &&
     printf '%s\n' "$_tener_verify" | grep -Fq 'type md5sum >/dev/null 2>&1' &&
     ! printf '%s\n' "$_tener_verify" | grep -Fq 'command -v'; then
    pass "node Apply exact settings verification avoids the unavailable command builtin"
  else
    fail "node Apply exact settings verification avoids the unavailable command builtin"
  fi
}

sync_job_test_handler() {
  _tsjh_node="$1" _tsjh_ip="$2"
  printf '%s\n' "$_tsjh_node" > "$MERV_NODE_JOB_DIR/sync-artifact" || return 1
  case "$_tsjh_ip" in
    192.0.2.2) return 5 ;;
    192.0.2.3) return 6 ;;
  esac
  return 0
}

test_sync_node_pool() {
  _tsnp_root="$SELFTEST_ROOT/sync-node-pool"
  rm -rf "$_tsnp_root" 2>/dev/null || return 1
  mkdir -p "$_tsnp_root" || return 1
  printf '1 192.0.2.1\n2 192.0.2.2\n3 192.0.2.3\n' > "$_tsnp_root/nodes"
  . "$MERV_BASE/settings/lib_node_jobs.sh"
  if mnj_pool_run "$_tsnp_root/jobs" sync 2 6 "$_tsnp_root/nodes" sync_job_test_handler; then
    fail "sync pool reports transfer and verification failures"
  else
    pass "sync pool reports transfer and verification failures"
  fi
  mnj_result_validate "$_tsnp_root/jobs/node_1/result" 1 sync && [ "$MNJ_RESULT_STATE" = ok ] &&
    [ "$(cat "$_tsnp_root/jobs/node_1/sync-artifact" 2>/dev/null)" = 1 ] &&
    mnj_result_validate "$_tsnp_root/jobs/node_2/result" 2 sync && [ "$MNJ_RESULT_STATE" = failed ] &&
    mnj_result_validate "$_tsnp_root/jobs/node_3/result" 3 sync && [ "$MNJ_RESULT_STATE" = failed ] &&
    pass "sync worker results retain one success and two failures" ||
    fail "sync worker results retain one success and two failures"
  mnj_result_validate "$_tsnp_root/jobs/node_1/result" 1 sync && [ "$MNJ_RESULT_STATE" = ok ] &&
    [ -f "$_tsnp_root/jobs/node_1/cli.log" ] && [ -d "$_tsnp_root/jobs/node_1/ssh" ] &&
    pass "sync failure leaves successful node job isolated" ||
    fail "sync failure leaves successful node job isolated"
}

test_sync_node_parallel_contract() {
  _tsnc_file="$MERV_BASE/functions/sync_nodes.sh"
  _tsnc_verify=$(sed -n '/^sync_verify_batch_manifest()/,/^verify_batch_on_node()/p' "$_tsnc_file" 2>/dev/null)
  _tsnc_worker=$(sed -n '/^sync_node_worker()/,/^sync_copy_worker_log_for_view()/p' "$_tsnc_file" 2>/dev/null)
  grep -q 'sync_node_worker()' "$_tsnc_file" &&
    grep -q 'mnj_nodes_validate' "$_tsnc_file" &&
    grep -q 'mnj_pool_run.*sync' "$_tsnc_file" &&
    grep -q 'MERV_NODE_SYNC_MAX_SEC' "$_tsnc_file" &&
    grep -q 'sync_pool_progress' "$_tsnc_file" &&
    grep -q 'node_workers' "$_tsnc_file" &&
    grep -q 'mervlan_node_runner.sh' "$_tsnc_file" &&
    grep -q 'lib_node_jobs.sh' "$_tsnc_file" &&
    grep -q '.mervlan.new.${SYNC_RUN_ID}.${node_id}' "$_tsnc_file" &&
    grep -q 'sync_expected_path' "$_tsnc_file" &&
    ! grep -q 'for d in /jffs/addons/mervlan_backups/.mervlan.new' "$_tsnc_file" &&
    pass "sync uses isolated bounded staged workers" ||
    fail "sync uses isolated bounded staged workers"

  if printf '%s\n' "$_tsnc_verify" | grep -Fq 'merv_ssh_stream_stdin "$_vbm_id" "$_vbm_ip" "$_vbm_cmd"' &&
     printf '%s\n' "$_tsnc_verify" | grep -Fq '.sync-verify.${_vbm_tag}.manifest' &&
     printf '%s\n' "$_tsnc_verify" | grep -Fq 'SYNC_BATCH_EXACT_OK|' &&
     printf '%s\n' "$_tsnc_verify" | grep -Fq 'SYNC_BATCH_EXACT_FAIL|' &&
     ! printf '%s\n' "$_tsnc_verify" | grep -Fq 'verify_file_on_node'; then
    pass "sync streams exact staged-file verification through one bounded SSH command"
  else
    fail "sync streams exact staged-file verification through one bounded SSH command"
  fi

  if grep -Fq 'prepare_remote_sync_stage()' "$_tsnc_file" &&
     grep -Fq 'MERV_SSH_SKIP_PING=1' "$_tsnc_file" &&
     grep -Fq 'SYNC_STAGE_DIRS_PREPARED=1' "$_tsnc_file" &&
     printf '%s\n' "$_tsnc_worker" | grep -Fq 'pull_node_hardware "$node_ip" "$node_id" "$SYNC_NODE_ACTIVATION_OUTPUT"' &&
     grep -Fq 'SYNC_NODE_ACTIVATION_OUTPUT="$_asn_result"' "$_tsnc_file"; then
    pass "sync combines staging and hardware metadata in bounded verified commands"
  else
    fail "sync combines staging and hardware metadata in bounded verified commands"
  fi
}

test_apmo_completion_contract() {
  _tapm_ui="$MERV_BASE/www/index.html"
  _tapm_handler="$MERV_BASE/functions/service-event-handler.sh"
  _tapm_probe="$MERV_BASE/functions/hw_probe.sh"
  _tapm_css="$MERV_BASE/www/vlan_index_style.css"
  _tapm_ok=1

  if grep -q 'async function runVerifiedHardwareProbe' "$_tapm_ui" &&
     grep -q 'waitForSettingsToMatch(expectedManaged' "$_tapm_ui" &&
     grep -q 'waitForVerifiedActionResult' "$_tapm_ui" &&
     grep -q 'vlanmgr_action_request_token' "$_tapm_ui" &&
     ! grep -q 'setTimeout.*8500' "$_tapm_ui" &&
     ! grep -q 'setTimeout.*16000' "$_tapm_ui"; then
    pass "APMO waits for persistence and verified HW probe completion"
  else
    fail "APMO waits for persistence and verified HW probe completion"
    _tapm_ok=0
  fi

  if grep -q 'hwprobe_vlanmgr_vrt_\*' "$_tapm_handler" &&
     grep -q 'hw_probe.sh" "\$_action_token"' "$_tapm_handler"; then
    pass "service handler dispatches correlated HW probe requests"
  else
    fail "service handler dispatches correlated HW probe requests"
    _tapm_ok=0
  fi

  if grep -q 'ACTION_REQUEST_TOKEN=' "$_tapm_probe" &&
     grep -q 'action_ack_ok' "$_tapm_probe" &&
     grep -q 'action_ack_error' "$_tapm_probe"; then
    pass "HW probe publishes correlated terminal acknowledgements"
  else
    fail "HW probe publishes correlated terminal acknowledgements"
    _tapm_ok=0
  fi

  _tapm_refresh=$(sed -n '/async function refreshHwProfile/,/async function checkForUpdates/p' "$_tapm_ui")
  _tapm_probe_save=$(sed -n '/async function applyOverrideWithHwProbe/,/function extractOverrideSaveExpected/p' "$_tapm_ui")
  _tapm_save_only=$(sed -n '/async function applyOverrideSaveOnly/,/async function refreshHwProfile/p' "$_tapm_ui")
  _tapm_auto_sync=$(sed -n '/async function autoSyncAdvancedOverrideNodes/,/async function applyOverrideWithHwProbe/p' "$_tapm_ui")
  _tapm_payload=$(sed -n '/function buildOverridePayloadForMerlin/,/function buildClientMetaPayloadForMerlin/p' "$_tapm_ui")
  _tapm_ack_wait=$(sed -n '/async function waitForVerifiedActionResult/,/async function executeVerifiedServiceAction/p' "$_tapm_ui")
  _tapm_modal=$(sed -n '/function showAdvancedOverrideModal/,/function hideAdvancedOverrideModal/p' "$_tapm_ui")
  if printf '%s\n' "$_tapm_refresh" | grep -q 'prepareAdvancedOverrideLoadingLayer();' &&
     printf '%s\n' "$_tapm_refresh" | awk '/await loadSettings\(\);/ { loaded = NR } /refreshOpenAdvancedOverrideModalFromCache\(\);/ { refreshed = NR } END { exit !(loaded && refreshed && loaded < refreshed) }' &&
     ! printf '%s\n' "$_tapm_refresh" | grep -q 'hideAdvancedOverrideModal();' &&
     printf '%s\n' "$_tapm_auto_sync" | grep -q 'prepareAdvancedOverrideLoadingLayer();' &&
     printf '%s\n' "$_tapm_probe_save" | awk '/waitForVerifiedActionResult\(saveRequestToken/ { ack = NR } /waitForSettingsToMatch\(expectedManaged/ { persist = NR } END { exit !(ack && persist && ack < persist) }' &&
     printf '%s\n' "$_tapm_save_only" | awk '/waitForVerifiedActionResult\(saveRequestToken/ { ack = NR } /waitForSettingsToMatch\(expectedManaged/ { persist = NR } END { exit !(ack && persist && ack < persist) }' &&
     grep -Fq 'function prepareAdvancedOverrideLoadingLayer()' "$_tapm_ui" &&
     printf '%s\n' "$_tapm_modal" | grep -Fq 'try { formPane.appendChild(modal); } catch (e) { /* ignore */ }' &&
     ! grep -Fq 'document.body.appendChild(backdrop)' "$_tapm_ui" &&
     grep -Fq '.mervlan-loading-backdrop.mervlan-loading-backdrop--apmo .mervlan-loading-panel' "$_tapm_css" &&
     grep -Fq 'left:var(--apmo-loader-center-x, 50%);' "$_tapm_css" &&
     grep -Fq 'top:var(--apmo-loader-center-y, 50%);' "$_tapm_css" &&
     grep -Fq 'const modalIsInForm = modal.parentElement === form;' "$_tapm_ui" &&
     grep -Fq 'function refreshOpenAdvancedOverrideModalFromCache(confirmedOverrides = null)' "$_tapm_ui" &&
     grep -Fq 'Object.prototype.hasOwnProperty.call(confirmedOverrides, key)' "$_tapm_ui" &&
     grep -Fq 'function autoSyncAdvancedOverrideNodesEnabled()' "$_tapm_ui" &&
     grep -Fq 'function configuredAdvancedOverrideTargets()' "$_tapm_ui" &&
     printf '%s\n' "$_tapm_payload" | grep -Fq 'configuredAdvancedOverrideTargets().forEach(t => {' &&
     ! printf '%s\n' "$_tapm_payload" | grep -Fq 'nodeTokens(true).forEach(t => {' &&
     printf '%s\n' "$_tapm_ack_wait" | grep -Fq 'PATHS.ACTION_RESULTS_DIR + encodeURIComponent(requestToken)' &&
     printf '%s\n' "$_tapm_ack_wait" | grep -Fq 'PATHS.ACTION_RESULT +' &&
     printf '%s\n' "$_tapm_ack_wait" | grep -Fq 'parsed.request_token === requestToken && parsed.action === actionName' &&
     printf '%s\n' "$_tapm_probe_save" | awk '/clearFields\(\);/ { cleared = NR } /await loadSettings\(\);/ { loaded = NR } /refreshOpenAdvancedOverrideModalFromCache\(expectedManaged\);/ { refreshed = NR } END { exit !(cleared && loaded && refreshed && cleared < loaded && loaded < refreshed) }' &&
     printf '%s\n' "$_tapm_save_only" | awk '/clearFields\(\);/ { cleared = NR } /await loadSettings\(\);/ { loaded = NR } /refreshOpenAdvancedOverrideModalFromCache\(expectedManaged\);/ { refreshed = NR } END { exit !(cleared && loaded && refreshed && cleared < loaded && loaded < refreshed) }' &&
     printf '%s\n' "$_tapm_probe_save" | awk '/await loadSettings\(\);/ { loaded = NR } /autoSyncAdvancedOverrideNodesEnabled\(\)/ { auto = NR } END { exit !(loaded && auto && loaded < auto) }' &&
     printf '%s\n' "$_tapm_save_only" | awk '/await loadSettings\(\);/ { loaded = NR } /autoSyncAdvancedOverrideNodesEnabled\(\)/ { auto = NR } END { exit !(loaded && auto && loaded < auto) }' &&
     printf '%s\n' "$_tapm_probe_save" | awk '/loadingTask\.completion/ { completed = NR } /MerVLANLoading\.close\(\);/ { released = NR } /autoSyncAdvancedOverrideNodesEnabled\(\)/ { auto = NR } END { exit !(completed && released && auto && completed < released && released < auto) }' &&
     printf '%s\n' "$_tapm_save_only" | awk '/loadingTask\.completion/ { completed = NR } /MerVLANLoading\.close\(\);/ { released = NR } /autoSyncAdvancedOverrideNodesEnabled\(\)/ { auto = NR } END { exit !(completed && released && auto && completed < released && released < auto) }' &&
     grep -Fq 'info -c cli "Refreshing hardware profile for $_OVR_TARGET..."' "$_tapm_probe" &&
     grep -Fq 'info -c cli "Hardware profile refreshed: $MODEL ($MAX_ETH_PORTS LAN ports; WAN $WAN_IF)"' "$_tapm_probe" &&
     grep -Fq 'info -c vlan "Hardware detection complete"' "$_tapm_probe" &&
     grep -Fq 'info -c vlan "Hardware model:' "$_tapm_probe" &&
     grep -Fq 'info -c vlan "Hardware Ethernet:' "$_tapm_probe" &&
     grep -Fq 'info -c vlan "Hardware profile stored in settings.json' "$_tapm_probe" &&
     ! grep -Fq 'info -c cli,vlan' "$_tapm_probe"; then
    pass "manual HW refresh exposes its loading state, summarizes CLI output, and keeps diagnostics in the VLAN log"
  else
    fail "manual HW refresh exposes its loading state, summarizes CLI output, and keeps diagnostics in the VLAN log"
    _tapm_ok=0
  fi

  return "$_tapm_ok"
}

test_action_lifecycle_contract() {
  _talc_ui="$MERV_BASE/www/index.html"
  _talc_parent="$MERV_BASE/mervlan.asp"
  _talc_ok=1

  if grep -q 'function holdActionButton' "$_talc_ui" &&
     grep -q 'function releaseActionLock' "$_talc_ui" &&
     grep -q 'holdUntilReleased' "$_talc_ui" &&
     grep -q 'async function handleApplyClick' "$_talc_ui" &&
     grep -q 'return await triggerAction' "$_talc_ui" &&
     grep -q 'runVlanManagerLocal(this)' "$_talc_ui" &&
     grep -q 'runVlanManagerWithNodes(this)' "$_talc_ui" &&
     grep -q 'runVlanManagerOnlyNodes(this)' "$_talc_ui"; then
    pass "UI actions use completion-based locks and modal button ownership"
  else
    fail "UI actions use completion-based locks and modal button ownership"
    _talc_ok=0
  fi

  if grep -q 'function mvmAcquireRefreshGuard' "$_talc_parent" &&
     grep -q 'function mvmReleaseRefreshGuard' "$_talc_parent" &&
     grep -q '_mvmRefreshGuard.count' "$_talc_parent" &&
     ! grep -q 'var orig = {' "$_talc_parent"; then
    pass "parent refresh suppression uses shared ownership"
  else
    fail "parent refresh suppression uses shared ownership"
    _talc_ok=0
  fi

  return "$_talc_ok"
}

test_action_parent_ownership() {
  selftest_reset || return 1
  _tapo_lock="$SELFTEST_ROOT/action-parent.lock"
  _tapo_ok=1
  unset MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID \
    MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE
  assert_ok "action wrapper acquires a self-owned lock" merv_action_lock_enter "$_tapo_lock"
  _tapo_mode="$MERV_ACTION_LOCK_MODE"
  _tapo_nonce="$MERV_ACTION_LOCK_NONCE"
  _tapo_start="$MERV_ACTION_LOCK_START"
  [ "$_tapo_mode" = self ] && pass "action wrapper records self ownership" || { fail "action wrapper records self ownership"; _tapo_ok=0; }
  assert_ok "action wrapper exports exact parent context" merv_action_lock_export_child_context
  assert_ok "matching parent context is authenticated" merv_action_lock_parent_owned "$_tapo_lock"
  MERV_ACTION_LOCK_PARENT_PID=999999
  assert_rc 1 "wrong parent PID is rejected" merv_action_lock_parent_owned "$_tapo_lock"
  MERV_ACTION_LOCK_PARENT_PID="$$"
  MERV_ACTION_LOCK_PARENT_START=1
  assert_rc 1 "wrong parent start is rejected" merv_action_lock_parent_owned "$_tapo_lock"
  MERV_ACTION_LOCK_PARENT_START="$_tapo_start"
  MERV_ACTION_LOCK_PARENT_NONCE=wrong-parent-nonce
  assert_rc 1 "wrong parent nonce is rejected without fallback" merv_action_lock_parent_owned "$_tapo_lock"
  MERV_ACTION_LOCK_PARENT_NONCE="$_tapo_nonce"
  mv "$_tapo_lock/owner" "$_tapo_lock/owner.missing"
  assert_rc 1 "missing parent owner is rejected" merv_action_lock_parent_owned "$_tapo_lock"
  mv "$_tapo_lock/owner.missing" "$_tapo_lock/owner"
  printf '%s\n' malformed-owner > "$_tapo_lock/owner"
  assert_rc 1 "malformed parent owner is rejected" merv_action_lock_parent_owned "$_tapo_lock"
  merv_owner_v2_write_atomic "$_tapo_lock" "$$" "$_tapo_start" "$_tapo_nonce" 1 1 || { fail "parent owner fixture restore"; _tapo_ok=0; }
  MERV_ACTION_LOCK_PARENT_START=1
  assert_rc 1 "PID-reuse parent identity is rejected" merv_action_lock_parent_owned "$_tapo_lock"
  MERV_ACTION_LOCK_PARENT_START="$_tapo_start"
  assert_ok "parent-mode leave is a no-op" merv_action_lock_leave "$_tapo_lock" "$_tapo_nonce" "$_tapo_start" parent
  [ -d "$_tapo_lock" ] && pass "parent-mode leave retains owner record" || { fail "parent-mode leave retains owner record"; _tapo_ok=0; }
  assert_rc 1 "self release rejects wrong supplied start" merv_action_lock_leave "$_tapo_lock" "$_tapo_nonce" 1 self
  [ -d "$_tapo_lock" ] && pass "wrong-start release retains owner record" || { fail "wrong-start release retains owner record"; _tapo_ok=0; }
  assert_ok "self owner releases by exact nonce" merv_action_lock_leave "$_tapo_lock" "$_tapo_nonce" "$_tapo_start" self
  [ ! -e "$_tapo_lock" ] && pass "action lock is removed after self release" || { fail "action lock is removed after self release"; _tapo_ok=0; }
  unset MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID \
    MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE
  return "$_tapo_ok"
}

test_action_lock_failure() {
  selftest_reset || return 1
  _talf_root="$SELFTEST_ROOT/action-lock-failure"
  _talf_ok=1
  mkdir -p "$_talf_root/state" "$_talf_root/public/actions" || return 1
  ACTION_ACK_FILE="$_talf_root/public/action_result.json"
  ACTION_ACK_DIR="$_talf_root/public/actions"
  ACTION_ACK_INTERNAL_FILE="$_talf_root/state/action_ack.json"
  ACTION_ACK_PENDING_DIR="$_talf_root/state/pending"
  MERV_STATE_ROOT="$_talf_root/state"
  export ACTION_ACK_FILE ACTION_ACK_DIR ACTION_ACK_INTERNAL_FILE ACTION_ACK_PENDING_DIR MERV_STATE_ROOT
  unset LIB_ACTION_ACK_LOADED
  . "$MERV_BASE/settings/lib_action_ack.sh" || return 1

  _talf_event="$_talf_root/event.lock"
  merv_owner_lock_acquire "$_talf_event" 0 0 action-lock-failure || return 1
  _talf_live_nonce="$MERV_LOCK_NONCE"
  merv_action_lock_enter "$_talf_event"
  _talf_rc=$?
  [ "$_talf_rc" -eq 3 ] && [ "${MERV_ACTION_LOCK_LAST_FAILURE:-}" = action-lock-busy ] &&
    pass "live event lock is classified busy" || { fail "live event lock is classified busy"; _talf_ok=0; }
  action_ack_lock_failure live-event sync_vlanmgr "$_talf_rc" event || _talf_ok=0
  grep -q '"status":"busy"' "$_talf_root/public/actions/live-event.json" 2>/dev/null &&
    grep -q 'action-lock-busy' "$_talf_root/public/actions/live-event.json" 2>/dev/null &&
    pass "live event lock publishes one busy terminal result" || { fail "live event lock publishes one busy terminal result"; _talf_ok=0; }
  merv_owner_lock_release "$_talf_event" "$_talf_live_nonce" || return 1

  _talf_bad="$_talf_root/bad-event.lock"
  mkdir -p "$_talf_bad"; printf '%s\n' malformed > "$_talf_bad/owner"
  merv_action_lock_enter "$_talf_bad"
  _talf_rc=$?
  [ "$_talf_rc" -eq 4 ] && [ "${MERV_ACTION_LOCK_LAST_FAILURE:-}" = action-lock-owner-unknown ] &&
    pass "malformed event lock is classified owner-unknown" || { fail "malformed event lock is classified owner-unknown"; _talf_ok=0; }
  action_ack_lock_failure bad-event sync_vlanmgr "$_talf_rc" event || _talf_ok=0
  grep -q '"status":"error"' "$_talf_root/public/actions/bad-event.json" 2>/dev/null &&
    grep -q 'action-lock-owner-unknown' "$_talf_root/public/actions/bad-event.json" 2>/dev/null &&
    pass "malformed event lock publishes one owner-unknown terminal result" || { fail "malformed event lock terminal result"; _talf_ok=0; }

  _talf_global="$_talf_root/global.lock"
  merv_owner_lock_acquire "$_talf_global" 0 0 action-lock-failure || return 1
  _talf_live_nonce="$MERV_LOCK_NONCE"
  merv_action_lock_enter "$_talf_global"
  _talf_rc=$?
  action_ack_lock_failure live-global execute_vlanmgr "$_talf_rc" global || _talf_ok=0
  [ "$_talf_rc" -eq 3 ] && grep -q 'action-lock-busy' "$_talf_root/public/actions/live-global.json" 2>/dev/null &&
    pass "live global lock is classified busy" || { fail "live global lock is classified busy"; _talf_ok=0; }
  merv_owner_lock_release "$_talf_global" "$_talf_live_nonce" || return 1

  _talf_bad_global="$_talf_root/bad-global.lock"
  mkdir -p "$_talf_bad_global"; printf '%s\n' malformed > "$_talf_bad_global/owner"
  merv_action_lock_enter "$_talf_bad_global"
  _talf_rc=$?
  action_ack_lock_failure bad-global execute_vlanmgr "$_talf_rc" global || _talf_ok=0
  [ "$_talf_rc" -eq 4 ] && grep -q 'action-lock-owner-unknown' "$_talf_root/public/actions/bad-global.json" 2>/dev/null &&
    pass "malformed global lock is classified owner-unknown" || { fail "malformed global lock is classified owner-unknown"; _talf_ok=0; }

  _talf_parent="$_talf_root/parent.lock"
  merv_owner_lock_acquire "$_talf_parent" 0 0 action-lock-failure || return 1
  _talf_live_nonce="$MERV_LOCK_NONCE"; _talf_live_start="$MERV_LOCK_START"
  MERV_ACTION_LOCK_PARENT_HELD=1 MERV_ACTION_LOCK_PARENT_PID="$$" \
    MERV_ACTION_LOCK_PARENT_START=1 MERV_ACTION_LOCK_PARENT_NONCE="$_talf_live_nonce"
  merv_action_lock_enter "$_talf_parent"
  _talf_rc=$?
  [ "$_talf_rc" -eq 4 ] && [ "${MERV_ACTION_LOCK_LAST_FAILURE:-}" = action-lock-parent-invalid ] &&
    pass "invalid parent is classified separately" || { fail "invalid parent is classified separately"; _talf_ok=0; }
  action_ack_lock_failure invalid-parent execute_vlanmgr "$_talf_rc" global || _talf_ok=0
  grep -q 'action-lock-parent-invalid' "$_talf_root/public/actions/invalid-parent.json" 2>/dev/null &&
    pass "invalid parent publishes one terminal error" || { fail "invalid parent terminal error"; _talf_ok=0; }
  unset MERV_ACTION_LOCK_PARENT_HELD MERV_ACTION_LOCK_PARENT_PID MERV_ACTION_LOCK_PARENT_START MERV_ACTION_LOCK_PARENT_NONCE
  merv_owner_lock_release "$_talf_parent" "$_talf_live_nonce" || return 1

  action_ack_stage_ok staged-save save_vlanmgr '{"local_saved":"1"}' 'Settings saved.' '[]' || _talf_ok=0
  action_ack_discard_staged staged-save || _talf_ok=0
  action_ack_error staged-save save_vlanmgr '{"local_saved":"1"}' 'Cleanup failed.' '["action-lock-cleanup-failed"]' action-lock-cleanup-failed || _talf_ok=0
  [ ! -e "$_talf_root/state/pending/staged-save.json" ] &&
    grep -q '"status":"error"' "$_talf_root/public/actions/staged-save.json" 2>/dev/null &&
    ! grep -q '"status":"ok"' "$_talf_root/public/actions/staged-save.json" 2>/dev/null &&
    pass "staged Save success is discarded after cleanup failure" || { fail "staged Save success is discarded after cleanup failure"; _talf_ok=0; }

  grep -q 'return 75' "$MERV_BASE/functions/service-event-handler.sh" &&
    grep -q 'action-lock-owner-unknown' "$MERV_BASE/settings/lib_action_ack.sh" &&
    pass "lock refusal paths return nonzero and expose stable classifications" || { fail "lock refusal paths return nonzero and expose stable classifications"; _talf_ok=0; }
  unset ACTION_ACK_FILE ACTION_ACK_DIR ACTION_ACK_INTERNAL_FILE ACTION_ACK_PENDING_DIR MERV_STATE_ROOT
  return "$_talf_ok"
}

test_direct_manager_save_overlap() {
  selftest_reset || return 1
  _tdm_lock="$SELFTEST_ROOT/direct-manager-save.lock"
  _tdm_manager="$SELFTEST_ROOT/direct-manager.sh"
  _tdm_save="$SELFTEST_ROOT/direct-save.sh"
  _tdm_manager_ready="$SELFTEST_ROOT/direct-manager.ready"
  _tdm_save_ready="$SELFTEST_ROOT/direct-save.ready"
  _tdm_ok=1
  if grep -Fq 'merv_action_lock_enter' "$MERV_BASE/functions/mervlan_manager.sh" &&
     grep -Fq 'merv_action_lock_enter' "$MERV_BASE/functions/save_settings.sh"; then
    pass "direct manager and Save participate in the global action lock"
  else
    fail "direct manager and Save participate in the global action lock"
    _tdm_ok=0
  fi
  cat > "$_tdm_manager" <<'ACTION_OVERLAP'
#!/bin/sh
. "$MERV_BASE/settings/lib_action_lock.sh" || exit 2
merv_action_lock_enter "$1" || exit $?
printf '%s\n' ready > "$2"
sleep 3
merv_action_lock_leave "$1" "$MERV_ACTION_LOCK_NONCE" "$MERV_ACTION_LOCK_START" "$MERV_ACTION_LOCK_MODE"
ACTION_OVERLAP
  cp "$_tdm_manager" "$_tdm_save" || return 1
  chmod 700 "$_tdm_manager" "$_tdm_save" || return 1
  rm -f "$_tdm_manager_ready" "$_tdm_save_ready"
  MERV_BASE="$MERV_BASE" MERV_ACTION_LOCK_PARENT_HELD=0 "$_tdm_manager" "$_tdm_lock" "$_tdm_manager_ready" &
  _tdm_manager_pid=$!
  _tdm_wait=0
  while [ ! -f "$_tdm_manager_ready" ] && [ "$_tdm_wait" -lt 30 ]; do sleep 1; _tdm_wait=$((_tdm_wait + 1)); done
  if [ ! -f "$_tdm_manager_ready" ]; then
    fail "direct manager overlap fixture became ready"
    _tdm_ok=0
  else
    MERV_BASE="$MERV_BASE" MERV_ACTION_LOCK_PARENT_HELD=0 "$_tdm_save" "$_tdm_lock" "$_tdm_save_ready"
    _tdm_rc=$?
    [ "$_tdm_rc" -eq 3 ] && pass "direct Save overlap sees manager owner busy" || { fail "direct Save overlap sees manager owner busy (rc=$_tdm_rc)"; _tdm_ok=0; }
    [ ! -f "$_tdm_save_ready" ] && pass "busy Save does not publish a child-ready marker" || { fail "busy Save does not publish a child-ready marker"; _tdm_ok=0; }
  fi
  wait "$_tdm_manager_pid" 2>/dev/null || :
  MERV_BASE="$MERV_BASE" MERV_ACTION_LOCK_PARENT_HELD=0 "$_tdm_save" "$_tdm_lock" "$_tdm_save_ready"
  _tdm_rc=$?
  [ "$_tdm_rc" -eq 0 ] && pass "direct Save enters after manager releases" || { fail "direct Save enters after manager releases (rc=$_tdm_rc)"; _tdm_ok=0; }
  return "$_tdm_ok"
}

test_update_lock_ownership() {
  _tulo_update="$MERV_BASE/functions/update_mervlan.sh"
  _tulo_handler="$MERV_BASE/functions/service-event-handler.sh"
  _tulo_lock="$SELFTEST_ROOT/update-parent-action.lock"
  _tulo_v2_lock="$SELFTEST_ROOT/update-v2.lock"
  _tulo_ok=1

  if grep -Fq 'merv_action_lock_parent_owned "$LOCKDIR/mervlan_action.lock"' "$_tulo_update" &&
     grep -Fq 'merv_action_lock_export_child_context' "$_tulo_handler" &&
     grep -Fq 'MERV_ACTION_LOCK_PARENT_NONCE' "$_tulo_handler"; then
    pass "Update ignores only the dispatcher-owned global action lock"
  else
    fail "Update ignores only the dispatcher-owned global action lock"
    _tulo_ok=0
  fi

  if (
    MERV_ACTION_LOCK_PATH="$_tulo_lock"
    . "$MERV_BASE/settings/lib_action_lock.sh" || exit 1
    merv_action_lock_enter "$_tulo_lock" || exit 1
    _tulo_nonce="$MERV_ACTION_LOCK_NONCE"
    _tulo_start="$MERV_ACTION_LOCK_START"
    merv_action_lock_export_child_context || exit 1
    merv_action_lock_parent_owned "$_tulo_lock" || exit 1
    MERV_ACTION_LOCK_PARENT_NONCE=wrong
    if merv_action_lock_parent_owned "$_tulo_lock"; then exit 1; fi
    MERV_ACTION_LOCK_PARENT_NONCE="$_tulo_nonce"
    : > "$_tulo_lock/.owner.tmp.crash" || exit 1
    rm -f "$_tulo_lock/.owner.tmp.crash" || exit 1
    merv_action_lock_leave "$_tulo_lock" "$_tulo_nonce" "$_tulo_start" self || exit 1
    [ ! -e "$_tulo_lock" ] || exit 1
  ); then
    pass "Update parent-lock exemption requires matching identity and nonce"
  else
    fail "Update parent-lock exemption requires matching identity and nonce"
    _tulo_ok=0
  fi

  if (
    merv_owner_lock_acquire "$_tulo_v2_lock" 60 1 update-v2-test || exit 1
    _tulo_v2_nonce="$MERV_LOCK_NONCE"
    : > "$_tulo_v2_lock/.owner.tmp.crash" || exit 1
    rm -f "$_tulo_v2_lock/.owner.tmp.crash" || exit 1
    merv_owner_lock_release "$_tulo_v2_lock" "$_tulo_v2_nonce" || exit 1
    [ ! -e "$_tulo_v2_lock" ]
  ); then
    pass "Owner-lock release removes its validated owner record"
  else
    fail "Owner-lock release removes its validated owner record"
    _tulo_ok=0
  fi

  return "$_tulo_ok"
}

test_update_exclusivity() {
  _tue_root="$SELFTEST_ROOT/update-exclusivity"
  _tue_ok=1
  mkdir -p "$_tue_root" || return 1
  MERV_STATE_ROOT="$_tue_root/state"
  MERV_UPDATE_JOURNAL="$MERV_STATE_ROOT/update.journal"
  MERV_UPDATE_QUIESCE_FILE="$MERV_STATE_ROOT/update.quiesce"
  MERV_UPDATE_MAINTENANCE_LOCK="$_tue_root/maintenance.lock"
  export MERV_STATE_ROOT MERV_UPDATE_JOURNAL MERV_UPDATE_QUIESCE_FILE MERV_UPDATE_MAINTENANCE_LOCK
  [ -n "${LIB_UPDATE_STATE_LOADED:-}" ] || . "$MERV_BASE/settings/lib_update_state.sh" || return 1

  merv_update_journal_write update-exclusive quiescing ref 0 0 1 0 0 test || {
    fail "update exclusivity journal fixture"; return 1;
  }
  merv_update_quiesce_begin update-exclusive || { fail "update exclusivity quiesce fixture"; return 1; }
  merv_owner_lock_acquire "$MERV_UPDATE_MAINTENANCE_LOCK" 60 1 update-exclusive || {
    fail "update exclusivity maintenance fixture"; return 1;
  }
  _tue_nonce="$MERV_LOCK_NONCE"; _tue_start="$MERV_LOCK_START"

  unset MERV_UPDATE_OWNER_PID MERV_UPDATE_OWNER_START MERV_UPDATE_OWNER_NONCE
  MERV_UPDATE_OWNER=1
  if ! merv_update_owner_context_valid && merv_update_mutation_blocked; then
    pass "bare Update owner flag is rejected and remains blocked"
  else
    fail "bare Update owner flag is rejected and remains blocked"; _tue_ok=0
  fi
  MERV_UPDATE_OWNER_PID="$$"; MERV_UPDATE_OWNER_START=wrong; MERV_UPDATE_OWNER_NONCE="$_tue_nonce"
  if ! merv_update_owner_context_valid && merv_update_mutation_blocked; then
    pass "wrong Update owner start is rejected"
  else
    fail "wrong Update owner start is rejected"; _tue_ok=0
  fi
  MERV_UPDATE_OWNER_START="$_tue_start"; MERV_UPDATE_OWNER_NONCE=wrong
  if ! merv_update_owner_context_valid && merv_update_mutation_blocked; then
    pass "wrong Update owner nonce is rejected"
  else
    fail "wrong Update owner nonce is rejected"; _tue_ok=0
  fi
  MERV_UPDATE_OWNER_PID="$$"; MERV_UPDATE_OWNER_START="$_tue_start"; MERV_UPDATE_OWNER_NONCE="$_tue_nonce"
  if merv_update_owner_context_valid && ! merv_update_mutation_blocked; then
    pass "valid Update child context is accepted"
  else
    fail "valid Update child context is accepted"; _tue_ok=0
  fi
  MERV_MAINTENANCE_SYNC=1; MERV_UPDATE_OWNER_NONCE=wrong
  if ! merv_update_maintenance_sync_context_valid; then
    pass "bare maintenance Sync intent is rejected"
  else
    fail "bare maintenance Sync intent is rejected"; _tue_ok=0
  fi
  MERV_UPDATE_OWNER_NONCE="$_tue_nonce"
  if merv_update_maintenance_sync_context_valid; then
    pass "authenticated maintenance Sync context is accepted"
  else
    fail "authenticated maintenance Sync context is accepted"; _tue_ok=0
  fi
  merv_owner_lock_release "$MERV_UPDATE_MAINTENANCE_LOCK" "$_tue_nonce" || {
    fail "update exclusivity maintenance fixture release"; return 1;
  }
  unset MERV_UPDATE_OWNER MERV_UPDATE_OWNER_PID MERV_UPDATE_OWNER_START MERV_UPDATE_OWNER_NONCE MERV_MAINTENANCE_SYNC
  _tue_parent_start=$(merv_identity_current_start 2>/dev/null || printf '')
  MERV_UPDATE_RECOVERY=1 MERV_UPDATE_RECOVERY_RUN_ID=update-exclusive \
    MERV_UPDATE_RECOVERY_PARENT_PID="$$" MERV_UPDATE_RECOVERY_PARENT_START="$_tue_parent_start"
  if merv_update_recovery_context_valid; then
    pass "matching boot recovery context is accepted"
  else
    fail "matching boot recovery context is accepted"; _tue_ok=0
  fi
  MERV_UPDATE_RECOVERY_RUN_ID=wrong
  if ! merv_update_recovery_context_valid && merv_update_mutation_blocked; then
    pass "mismatched recovery remains blocked during quiesce"
  else
    fail "mismatched recovery remains blocked during quiesce"; _tue_ok=0
  fi
  unset MERV_UPDATE_RECOVERY MERV_UPDATE_RECOVERY_RUN_ID MERV_UPDATE_RECOVERY_PARENT_PID MERV_UPDATE_RECOVERY_PARENT_START

  if grep -n 'OBS_ACTION=' "$MERV_BASE/functions/post_apply_worker.sh" >/dev/null 2>&1 &&
     grep -n 'merv_update_mutation_blocked' "$MERV_BASE/functions/post_apply_worker.sh" >/dev/null 2>&1 &&
     grep -n 'OBS_SR=$((OBS_SR + 1))' "$MERV_BASE/functions/post_apply_worker.sh" >/dev/null 2>&1 &&
     grep -Fq 'merv_update_maintenance_sync_context_valid' "$MERV_BASE/functions/sync_nodes.sh" &&
     grep -Fq 'merv_update_mutation_blocked' "$MERV_BASE/functions/collect_clients.sh" &&
     grep -Fq 'merv_update_mutation_blocked' "$MERV_BASE/functions/dropbear_sshkey_gen.sh"; then
    pass "Update gates precede observation generation and direct mutations"
  else
    fail "Update gates precede observation generation and direct mutations"; _tue_ok=0
  fi
  merv_update_quiesce_clear || { fail "update exclusivity quiesce cleanup"; _tue_ok=0; }
  merv_update_journal_clear || { fail "update exclusivity journal cleanup"; _tue_ok=0; }
  return "$_tue_ok"
}

test_payload_contract() {
  _tpc_update="$MERV_BASE/functions/update_mervlan.sh"
  _tpc_install="$MERV_BASE/install.sh"
  _tpc_sync="$MERV_BASE/functions/sync_nodes.sh"
  _tpc_ok=1
  if grep -Fq 'update_filter_source_tree "$topdir"' "$_tpc_update" &&
     grep -Fq 'install_filter_source_tree "$topdir" "$work_dir"' "$_tpc_install" &&
     grep -Fq 'UPDATE_BACKUP_SOURCE_DIR' "$_tpc_update"; then
    pass "Install and Update filter source payloads before persistent staging"
  else
    fail "Install and Update filter source payloads before persistent staging"
    _tpc_ok=0
  fi
  if grep -Fq 'dev-tools/tests/router/mervlan_selftest.sh' "$_tpc_update" &&
     grep -Fq 'dev-tools/safety/mervlan_live_test_guard.sh' "$_tpc_update" &&
     grep -Fq 'dev-tools/tests/router/mervlan_selftest.sh' "$_tpc_install" &&
     grep -Fq 'dev-tools/safety/mervlan_live_test_guard.sh' "$_tpc_install" &&
     grep -Fq 'dev-tools/tests/router/mervlan_selftest.sh' "$_tpc_sync" &&
     grep -Fq 'dev-tools/safety/mervlan_live_test_guard.sh' "$_tpc_sync"; then
    pass "Only approved executable router development tools are retained"
  else
    fail "Only approved executable router development tools are retained"
    _tpc_ok=0
  fi
  if grep -Fq 'settings/lib_owner_lock.sh' "$_tpc_sync" &&
     grep -Fq 'settings/lib_owner_lock.sh' "$_tpc_update" &&
     grep -Fq 'settings/lib_owner_lock.sh' "$_tpc_install" &&
     grep -Fq 'settings/lib_owner_lock.sh' "$SELFTEST_SCRIPT" &&
     grep -A25 'FILES_TO_COPY_CHMOD_644=' "$_tpc_sync" | grep -Fq 'settings/lib_owner_lock.sh' &&
     sed -n '/^CORE_STAGE_FILES="/,/^OPTIONAL_STAGE_FILES="/p' "$_tpc_update" | grep -Fq 'settings/lib_owner_lock.sh' &&
     grep -Fq 'settings/lib_maintenance_recovery.sh' "$_tpc_sync" &&
     grep -Fq 'settings/lib_maintenance_recovery.sh' "$_tpc_update" &&
     grep -Fq 'settings/lib_maintenance_recovery.sh' "$_tpc_install" &&
     grep -A25 'FILES_TO_COPY_CHMOD_644=' "$_tpc_sync" | grep -Fq 'settings/lib_maintenance_recovery.sh' &&
     sed -n '/^CORE_STAGE_FILES="/,/^OPTIONAL_STAGE_FILES="/p' "$_tpc_update" | grep -Fq 'settings/lib_maintenance_recovery.sh' &&
     sed -n '/^update_stage_core_valid() {/,/^}/p' "$_tpc_update" | grep -Fq 'for _update_stage_required in $CORE_STAGE_FILES'; then
    pass "Full runtime manifests include maintenance recovery libraries"
  else
    fail "Full runtime manifests include maintenance recovery libraries"
    _tpc_ok=0
  fi
  if grep -Fq 'FILES_TO_COPY="settings/settings.json"' "$_tpc_sync" &&
     grep -Fq 'FILES_TO_COPY_CHMOD_644="settings/settings.json"' "$_tpc_sync"; then
    pass "Settings-only Sync Nodes remains limited to settings.json"
  else
    fail "Settings-only Sync Nodes remains limited to settings.json"
    _tpc_ok=0
  fi
  return "$_tpc_ok"
}

test_update_download_retry() {
  _tudr_root="$SELFTEST_ROOT/update-download-retry"
  _tudr_update="$MERV_BASE/functions/update_mervlan.sh"
  _tudr_helper="$_tudr_root/download-helper.sh"
  _tudr_curl="$_tudr_root/fake-curl.sh"
  _tudr_ok=1
  rm -rf "$_tudr_root" 2>/dev/null || return 1
  mkdir -p "$_tudr_root" || return 1
  sed -n '/^download_update_archive() {/,/^}/p' "$_tudr_update" > "$_tudr_helper" || return 1
  [ -s "$_tudr_helper" ] || return 1

  if grep -Fq '"$CURL_BIN" -fsL --connect-timeout 15 --max-time 300' "$_tudr_helper" &&
     ! grep -Fq -- '--retry' "$_tudr_helper" &&
     grep -Fq 'download_update_archive "$GITHUB_URL" "$ARCHIVE"' "$_tudr_update" &&
     grep -Fq 'fail_update downloading "Download failed after 5 attempts"' "$_tudr_update"; then
    pass "update download helper owns retries and preserves download failure lifecycle"
  else
    fail "update download helper owns retries and preserves download failure lifecycle"
    _tudr_ok=0
  fi

  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'count=$(cat "$TUDR_CURL_COUNT" 2>/dev/null || printf 0)'
    printf '%s\n' 'count=$((count + 1))'
    printf '%s\n' 'printf "%s\\n" "$count" > "$TUDR_CURL_COUNT"'
    printf '%s\n' 'out=""'
    printf '%s\n' 'while [ "$#" -gt 0 ]; do'
    printf '%s\n' '  case "$1" in -o) shift; out="${1:-}" ;; esac'
    printf '%s\n' '  shift'
    printf '%s\n' 'done'
    printf '%s\n' '[ -n "$out" ] || exit 64'
    printf '%s\n' 'outcome=$(sed -n "${count}p" "$TUDR_CURL_OUTCOMES")'
    printf '%s\n' 'case "$outcome" in'
    printf '%s\n' '  success) printf "archive-%s\\n" "$count" > "$out"; exit 0 ;;'
    printf '%s\n' '  empty) : > "$out"; exit 0 ;;'
    printf '%s\n' '  partial-fail) printf "partial-%s\\n" "$count" > "$out"; exit 6 ;;'
    printf '%s\n' '  fail) exit 6 ;;'
    printf '%s\n' '  *) exit 64 ;;'
    printf '%s\n' 'esac'
  } > "$_tudr_curl" || return 1
  chmod 700 "$_tudr_curl" || return 1

  if (
    . "$_tudr_helper" || exit 1
    info() { printf 'INFO: %s\n' "$*" >> "$TUDR_LOG"; }
    warn() { printf 'WARN: %s\n' "$*" >> "$TUDR_LOG"; }
    error() { printf 'ERROR: %s\n' "$*" >> "$TUDR_LOG"; }
    sleep() { printf '%s\n' "$1" >> "$TUDR_SLEEPS"; }
    mv() {
      [ "${TUDR_MV_FAIL:-0}" = 1 ] && return 1
      /bin/mv "$@"
    }
    tudr_run_case() {
      TUDR_CASE="$1"
      shift
      TUDR_CASE_ROOT="$_tudr_root/$TUDR_CASE"
      rm -rf "$TUDR_CASE_ROOT" || return 1
      mkdir -p "$TUDR_CASE_ROOT" || return 1
      TUDR_CURL_OUTCOMES="$TUDR_CASE_ROOT/outcomes"
      TUDR_CURL_COUNT="$TUDR_CASE_ROOT/curl.count"
      TUDR_LOG="$TUDR_CASE_ROOT/log"
      TUDR_SLEEPS="$TUDR_CASE_ROOT/sleeps"
      TUDR_MV_FAIL="${TUDR_FORCE_MV_FAILURE:-0}"
      export TUDR_CURL_OUTCOMES TUDR_CURL_COUNT
      printf '%s\n' "$@" > "$TUDR_CURL_OUTCOMES" || return 1
      : > "$TUDR_CURL_COUNT" || return 1
      : > "$TUDR_LOG" || return 1
      : > "$TUDR_SLEEPS" || return 1
      CURL_BIN="$_tudr_curl"
      download_update_archive 'https://example.invalid/mervlan.tar.gz' "$TUDR_CASE_ROOT/archive"
      TUDR_CASE_RC=$?
      return 0
    }
    tudr_expect_sleeps() {
      printf '%s\n' "$@" > "$TUDR_CASE_ROOT/expected-sleeps" || return 1
      cmp -s "$TUDR_CASE_ROOT/expected-sleeps" "$TUDR_SLEEPS"
    }

    tudr_run_case immediate success || exit 1
    [ "$TUDR_CASE_RC" -eq 0 ] && [ "$(cat "$TUDR_CURL_COUNT")" = 1 ] &&
      [ -s "$TUDR_CASE_ROOT/archive" ] && [ ! -s "$TUDR_SLEEPS" ] &&
      grep -Fq 'Download completed successfully on attempt 1/5' "$TUDR_LOG" || exit 1

    tudr_run_case transient fail fail success || exit 1
    [ "$TUDR_CASE_RC" -eq 0 ] && [ "$(cat "$TUDR_CURL_COUNT")" = 3 ] &&
      tudr_expect_sleeps 1 2 &&
      grep -Fq 'Download attempt 1/5 failed (curl rc=6)' "$TUDR_LOG" &&
      grep -Fq 'Download completed successfully on attempt 3/5' "$TUDR_LOG" || exit 1

    tudr_run_case fifth-success fail fail fail fail success || exit 1
    [ "$TUDR_CASE_RC" -eq 0 ] && [ "$(cat "$TUDR_CURL_COUNT")" = 5 ] &&
      tudr_expect_sleeps 1 2 4 8 &&
      [ "$(awk '{sum += $1} END {print sum+0}' "$TUDR_SLEEPS")" = 15 ] &&
      grep -Fq 'Download completed successfully on attempt 5/5' "$TUDR_LOG" || exit 1

    tudr_run_case exhausted fail fail fail fail fail || exit 1
    [ "$TUDR_CASE_RC" -ne 0 ] && [ "$(cat "$TUDR_CURL_COUNT")" = 5 ] &&
      tudr_expect_sleeps 1 2 4 8 &&
      [ ! -e "$TUDR_CASE_ROOT/archive" ] && [ ! -e "$TUDR_CASE_ROOT/archive.part" ] &&
      grep -Fq 'Download failed after 5 attempts (curl rc=6)' "$TUDR_LOG" || exit 1

    tudr_run_case partial-failure partial-fail success || exit 1
    [ "$TUDR_CASE_RC" -eq 0 ] && [ "$(cat "$TUDR_CURL_COUNT")" = 2 ] &&
      [ "$(cat "$TUDR_CASE_ROOT/archive")" = 'archive-2' ] &&
      [ ! -e "$TUDR_CASE_ROOT/archive.part" ] || exit 1

    tudr_run_case empty-success empty success || exit 1
    [ "$TUDR_CASE_RC" -eq 0 ] && [ "$(cat "$TUDR_CURL_COUNT")" = 2 ] &&
      tudr_expect_sleeps 1 && [ -s "$TUDR_CASE_ROOT/archive" ] &&
      [ ! -e "$TUDR_CASE_ROOT/archive.part" ] || exit 1

    TUDR_FORCE_MV_FAILURE=1
    tudr_run_case publish-failure success || exit 1
    TUDR_FORCE_MV_FAILURE=0
    [ "$TUDR_CASE_RC" -ne 0 ] && [ "$(cat "$TUDR_CURL_COUNT")" = 1 ] &&
      [ ! -e "$TUDR_CASE_ROOT/archive" ] && [ ! -e "$TUDR_CASE_ROOT/archive.part" ] &&
      grep -Fq 'could not publish the completed archive' "$TUDR_LOG" || exit 1
    exit 0
  ); then
    pass "update download retry contract covers success, retries, exhaustion, partials, empty output, and publish failure"
  else
    fail "update download retry contract covers success, retries, exhaustion, partials, empty output, and publish failure"
    _tudr_ok=0
  fi
  rm -rf "$_tudr_root" 2>/dev/null || _tudr_ok=0
  return "$_tudr_ok"
}

test_failure_propagation_contract() {
  _tfpc_ui="$MERV_BASE/www/index.html"
  _tfpc_handler="$MERV_BASE/functions/service-event-handler.sh"
  _tfpc_refresh="$MERV_BASE/functions/mac_refresh.sh"
  _tfpc_meta="$MERV_BASE/functions/mac_client_meta.sh"
  _tfpc_ok=1

  if grep -Eq 'isCancelled: \(\) => [A-Za-z]+LoadingTask && ![A-Za-z]+LoadingTask\.isRunning\(\)' "$_tfpc_ui" &&
     grep -q 'isRunning: () => !!active' "$_tfpc_ui" &&
     grep -q 'passProgressToken: true' "$_tfpc_ui" &&
     grep -q 'maintenanceLastPollError' "$_tfpc_ui" &&
     grep -q 'Still waiting for the router to publish maintenance status' "$_tfpc_ui" &&
     grep -q 'Service status polling is temporarily unavailable' "$_tfpc_ui"; then
    pass "UI stops dependent polls on backend failure and logs repeated status errors"
  else
    fail "UI stops dependent polls on backend failure and logs repeated status errors"
    _tfpc_ok=0
  fi

  if grep -q 'macrefresh_vlanmgr_pgt_\*' "$_tfpc_handler" &&
     grep -q 'macclientmeta_vlanmgr_pgt_\*' "$_tfpc_handler" &&
     grep -q 'dispatch_if_executable.*mac_refresh.sh' "$_tfpc_handler" &&
     grep -q 'dispatch_if_executable.*mac_client_meta.sh' "$_tfpc_handler"; then
    pass "service handler accepts progress-token MAC actions"
  else
    fail "service handler accepts progress-token MAC actions"
    _tfpc_ok=0
  fi

  if grep -q 'merv_action_progress_init' "$_tfpc_refresh" &&
     grep -q 'merv_action_progress_fail' "$_tfpc_refresh" &&
     grep -q 'merv_action_progress_complete' "$_tfpc_refresh" &&
     grep -q 'merv_action_progress_init' "$_tfpc_meta" &&
     grep -q 'exit 2' "$_tfpc_meta" &&
     grep -q '_meta_partial=1' "$_tfpc_meta" &&
     grep -q 'Client metadata persisted, but MAC shield enforcement or follow-up work requires recovery' "$_tfpc_meta" &&
     grep -q '_shield_reload=staged' "$_tfpc_meta" &&
     grep -q 'Client metadata saved; MAC Shield has no active database' "$_tfpc_meta" &&
     grep -q 'merv_action_progress_update collect 4 4 94 "Refreshing client inventory..."' "$_tfpc_meta" &&
     grep -q 'merv_action_progress_update complete 1 1 98 "Finalizing client metadata..."' "$_tfpc_meta" &&
     ! grep -q '_name_pairs\|name entries:' "$_tfpc_meta"; then
    pass "MAC refresh and metadata actions distinguish strict failures from safely staged metadata"
  else
    fail "MAC refresh and metadata actions distinguish strict failures from safely staged metadata"
    _tfpc_ok=0
  fi

  return "$_tfpc_ok"
}

test_ssh_outbound_contract() {
  _tsoc_ssh="$MERV_BASE/settings/lib_ssh.sh"
  _tsoc_probe="$MERV_BASE/functions/ssh_hostkey_probe.sh"
  _tsoc_mac="$MERV_BASE/settings/mac_shield_snapshot.sh"
  _tsoc_ok=1

  # Commands and both stream variants must share the same verified precheck and
  # private known_hosts hand-off.  This is the transport boundary for every
  # router-to-node action; individual action code must never call dbclient.
  if grep -Fq 'merv_ssh_require_verified_node' "$_tsoc_ssh" &&
     grep -Fq 'merv_ssh_precheck "$_node_num" "$_node_ip"' "$_tsoc_ssh" &&
     grep -Fq 'merv_ssh_prepare_known_host "$_node_num" "$_node_ip" "$_port" "$_node_mac"' "$_tsoc_ssh" &&
     grep -Fq 'merv_ssh_precheck "$_mssf_node" "$_mssf_ip"' "$_tsoc_ssh" &&
     grep -Fq 'merv_ssh_prepare_known_host "$_mssf_node" "$_mssf_ip" "$_mssf_port" "$_mssf_mac"' "$_tsoc_ssh" &&
     grep -Fq 'merv_ssh_precheck "$_msss_node" "$_msss_ip"' "$_tsoc_ssh" &&
     grep -Fq 'merv_ssh_prepare_known_host "$_msss_node" "$_msss_ip" "$_msss_port" "$_msss_mac"' "$_tsoc_ssh" &&
     grep -Fq 'MERV_SSH_KNOWN_HOME=' "$_tsoc_ssh" &&
     grep -Fq 'merv_ssh_release_known_host' "$_tsoc_ssh"; then
    pass "all outbound SSH transports require a pinned host-key precheck"
  else
    fail "all outbound SSH transports require a pinned host-key precheck"
    _tsoc_ok=0
  fi

  # The only runtime client references are the common wrapper, the isolated
  # first-contact probe, and MAC Shield's capability check.  A new action that
  # invokes the client directly must make this test fail until it is routed
  # through lib_ssh.sh instead.
  _tsoc_client_refs=$(grep -rl '\${MERV_SSH_CLIENT:-dbclient}' \
    "$MERV_BASE/functions" "$MERV_BASE/settings" 2>/dev/null || :)
  _tsoc_bad_refs=""
  for _tsoc_file in $_tsoc_client_refs; do
    case "$_tsoc_file" in
      "$_tsoc_ssh"|"$_tsoc_probe"|"$_tsoc_mac") ;;
      *) _tsoc_bad_refs="$_tsoc_bad_refs ${_tsoc_file##*/}" ;;
    esac
  done
  _tsoc_literal=$(grep -R -n -E '^[[:space:]]*(if[[:space:]]+|then[[:space:]]+|else[[:space:]]+|command[[:space:]]+|exec[[:space:]]+)?dbclient[[:space:]]' \
    "$MERV_BASE/functions" "$MERV_BASE/settings" 2>/dev/null || :)
  if [ -z "$_tsoc_bad_refs" ] && [ -z "$_tsoc_literal" ] &&
     grep -Fq 'merv_has "${MERV_SSH_CLIENT:-dbclient}"' "$_tsoc_mac"; then
    pass "all action paths use the shared SSH client wrapper"
  else
    fail "all action paths use the shared SSH client wrapper"
    _tsoc_ok=0
  fi

  # -y is confined to a no-command, temporary-home host-key discovery probe;
  # normal action traffic consumes the pin through lib_ssh.sh.
  if grep -Fq '"$_shkp_client_path" -y -N -p' "$_tsoc_probe" &&
     ! grep -E -q '(^|[[:space:]])-y([[:space:]]|$)' "$_tsoc_ssh"; then
    pass "first-contact SSH acceptance is isolated from action traffic"
  else
    fail "first-contact SSH acceptance is isolated from action traffic"
    _tsoc_ok=0
  fi

  _tsoc_preflight_ok=1
  for _tsoc_check in \
    'functions/collect_clients.sh|merv_ssh_preflight_node_set' \
    'functions/execute_nodes.sh|merv_ssh_preflight_node_set' \
    'functions/sync_nodes.sh|merv_ssh_preflight_node_set' \
    'functions/mervlan_boot.sh|merv_ssh_preflight_configured_nodes' \
    'functions/mervlan_backup.sh|merv_ssh_preflight_settings_file' \
    'functions/update_mervlan.sh|merv_ssh_preflight_settings_file' \
    'uninstall.sh|merv_ssh_preflight_node_set' \
    'settings/mac_shield_snapshot.sh|merv_ssh_preflight_node_lines'; do
    _tsoc_path=${_tsoc_check%%|*}
    _tsoc_need=${_tsoc_check#*|}
    if [ ! -f "$MERV_BASE/$_tsoc_path" ] || ! grep -Fq "$_tsoc_need" "$MERV_BASE/$_tsoc_path"; then
      _tsoc_preflight_ok=0
    fi
  done
  if [ "$_tsoc_preflight_ok" = 1 ]; then
    pass "every node-changing SSH action preflights the complete configured set"
  else
    fail "every node-changing SSH action preflights the complete configured set"
    _tsoc_ok=0
  fi

  _tsoc_target_settings="$SELFTEST_ROOT/ssh-preflight-target.json"
  {
    printf '%s\n' '{'
    printf '%s\n' '  "NODE1": "192.0.2.1"'
    printf '%s\n' '}'
  } > "$_tsoc_target_settings" || return 1
  if (
    unset LIB_SSH_TRUST_LOADED
    MERV_SSH_TRUST_TEST_MODE=1
    export MERV_SSH_TRUST_TEST_MODE
    . "$MERV_BASE/settings/lib_json.sh" || exit 1
    . "$MERV_BASE/settings/lib_ssh_trust.sh" || exit 1
    # var_settings.sh deliberately makes this read-only on the router.  The
    # staged preflight must pass its file explicitly instead of rebinding it.
    readonly SETTINGS_FILE
    merv_ssh_preflight_node_lines() {
      [ "$1" = '1 192.0.2.1' ] && [ "$2" = "$_tsoc_target_settings" ]
    }
    merv_ssh_preflight_settings_file "$_tsoc_target_settings"
  ); then
    pass "staged SSH preflight works when SETTINGS_FILE is read-only"
  else
    fail "staged SSH preflight works when SETTINGS_FILE is read-only"
    _tsoc_ok=0
  fi
  rm -f "$_tsoc_target_settings" 2>/dev/null || return 1

  return "$_tsoc_ok"
}

test_ssh_trust_contract() {
  _tst_ui="$MERV_BASE/www/index.html"
  _tst_handler="$MERV_BASE/functions/service-event-handler.sh"
  _tst_action="$MERV_BASE/functions/ssh_trust_action.sh"
  _tst_ack="$MERV_BASE/settings/lib_action_ack.sh"
  _tst_parent="$MERV_BASE/mervlan.asp"
  _tst_collect="$MERV_BASE/functions/collect_clients.sh"
  _tst_worker="$MERV_BASE/functions/post_apply_worker.sh"
  _tst_sync="$MERV_BASE/functions/sync_nodes.sh"
  _tst_ssh="$MERV_BASE/settings/lib_ssh.sh"
  _tst_boot="$MERV_BASE/functions/mervlan_boot.sh"
  _tst_lib="$MERV_BASE/settings/lib_mervqt.sh"
  _tst_ok=1

  if grep -q 'sshTrustRegistryTab' "$_tst_ui" &&
     grep -q 'needs_verification' "$_tst_ui" &&
     grep -q 'revokeSshTrustNode' "$_tst_ui" &&
     grep -q 'sshTrustRegistrySelectedSlots' "$_tst_ui" &&
     grep -q 'Verify selected nodes' "$_tst_ui" &&
     grep -Fq 'openSshTrustDecision' "$_tst_ui" &&
     grep -Fq 'sshTrustOverlay' "$_tst_ui" &&
     grep -Fq 'sshTrustPausedTray' "$_tst_ui" &&
     grep -Fq 'sshTrustModalCountdown' "$_tst_ui" &&
     grep -Fq 'MerVLAN loading paused' "$_tst_ui" &&
     grep -Fq 'submitSshTrustAbort' "$_tst_ui" &&
     grep -Fq 'pauseForSshTrust' "$_tst_ui" &&
     grep -Fq 'waitsForSshTrustAck' "$_tst_ui" &&
     grep -Fq 'sshTrustDecisionSelectedChallengeIds' "$_tst_ui" &&
     grep -Fq 'Decision expires in' "$_tst_ui" &&
     grep -Fq '#sshTrustModal {' "$_tst_ui" &&
     grep -Fq 'max-height: calc(100vh - 28px);' "$_tst_ui" &&
     grep -Fq 'formPane.appendChild(overlay)' "$_tst_ui" &&
     grep -Fq 'form-box--main.ssid-assign-view .ssh-trust-overlay' "$_tst_ui" &&
     grep -Fq 'anchorModalToForm(tray);' "$_tst_ui" &&
     grep -Fq 'anchorModalToForm(modal);' "$_tst_ui" &&
     grep -Fq 'ssh-trust-paused-tray.modal--anchored' "$_tst_ui" &&
     ! grep -Fq "submitSshTrustDecision('reject')" "$_tst_ui" &&
     ! grep -Fq 'localSshKeyPairReady' "$_tst_ui"; then
    pass "SSH UI scopes trust review to the addon, supports Assign view, and exposes selected trust, pause, countdown, abort, and revoke controls"
  else
    fail "SSH UI exposes discovery, selected trust, pause, countdown, abort, and revoke controls"
    _tst_ok=0
  fi

  if grep -q 'sshtruststatus_vlanmgr_pgt_\*' "$_tst_handler" &&
     grep -q 'get_ssh_trust_probe_node_slots' "$_tst_handler" &&
     grep -q 'sshtrustprobe_vlanmgr_pgt_\*_nsl_\*' "$_tst_handler" &&
     grep -Fq "tr '.' ' '" "$_tst_handler" &&
     grep -Fq 'MERV_SSH_TRUST_NODE_SLOTS' "$_tst_handler" &&
     grep -q 'sshtrustrevoke_vlanmgr_vrt_\*' "$_tst_handler" &&
     grep -q 'sshtrustabort_vlanmgr_vrt_\*' "$_tst_handler" &&
     grep -Fq 'sshtrustabort_vlanmgr_vrt_*) MERV_PROGRESS_TOKEN=' "$_tst_handler" &&
     grep -q 'dispatch_if_executable.*ssh_trust_action.sh' "$_tst_handler" &&
     grep -Fq 'sh "$SCRIPT_PATH" "$@"' "$_tst_handler"; then
    pass "service handler carries dot-delimited selected trust nodes through BusyBox sh"
  else
    fail "service handler carries selected trust nodes through BusyBox sh"
    _tst_ok=0
  fi

  if grep -Fq 'nodeSlots' "$_tst_parent" &&
     grep -Fq 'selectedNodeSlots.split(".")' "$_tst_parent" &&
     grep -Fq '_nsl_' "$_tst_parent" &&
     grep -Fq "tr '.' ' '" "$_tst_action" &&
     grep -Fq 'trust_probe_apply_selected_slots' "$_tst_action"; then
    pass "SSH trust selection is encoded, validated, and router-derived"
  else
    fail "SSH trust selection is encoded, validated, and router-derived"
    _tst_ok=0
  fi

  if ! grep -Fq 'CUSTOM_SETTINGS_FILE=' "$_tst_action" &&
     grep -Fq 'MERV_ACTION_ACK_PUBLISHED=0' "$_tst_action" &&
     grep -Fq 'trust_request_pending_count' "$_tst_action" &&
     grep -Fq 'trust_request_pending_result' "$_tst_action" &&
     grep -Fq 'trust_selected_challenge_ids' "$_tst_action" &&
     grep -Fq 'trust_abort()' "$_tst_action" &&
     grep -Fq 'sshtrustabort_vlanmgr' "$_tst_action" &&
     grep -Fq 'expires_in_sec' "$_tst_action" &&
     grep -Fq 'action_ack_error' "$_tst_action"; then
    pass "SSH trust worker supports paused partial trust, expiry, abort, and terminal fallback ack"
  else
    fail "SSH trust worker lacks paused partial trust, expiry, abort, or terminal fallback ack"
    _tst_ok=0
  fi

  if grep -Fq 'MERV_ACTION_ACK_PUBLISHED=1' "$_tst_ack"; then
    pass "SSH trust acknowledgements use valid JSON-safe wrapper defaults"
  else
    fail "SSH trust acknowledgements use valid JSON-safe wrapper defaults"
    _tst_ok=0
  fi

  if grep -Fq 'collectclients_vlanmgr_pgt_*' "$_tst_handler" &&
     ( grep -Fq 'MERV_ACTION_LOCK_PARENT_HELD=0' "$_tst_handler" ||
       grep -Fq 'merv_action_lock_clear_child_context' "$_tst_handler" ) &&
     grep -Fq 'obs_collection_trust_gate' "$_tst_worker" &&
     grep -Fq 'MERV_SSH_TRUST_SILENT_IF_VERIFIED=1' "$_tst_worker" &&
     grep -Fq 'MERV_SSH_TRUST_DECISION_EXIT=1' "$_tst_worker" &&
     grep -Fq 'MERV_SSH_TRUST_ORIGINAL_ACTION=collectclients_vlanmgr' "$_tst_collect" &&
     grep -Fq 'collectclients_vlanmgr)' "$_tst_action" &&
     grep -Fq 'SSH_TRUST_PROGRESS_TOKEN="${MERV_SSH_TRUST_PROGRESS_TOKEN:-$SSH_TRUST_TOKEN}"' "$_tst_action" &&
     grep -Fq 'MERV_SSH_TRUST_PROGRESS_TOKEN="$_str_fresh"' "$_tst_action" &&
     grep -Fq 'MERV_OBS_RESUME_PROGRESS_TOKEN="$SSH_TRUST_TOKEN"' "$_tst_action" &&
     grep -Fq 'MERV_ACTION_ACK_PUBLISHED=1' "$_tst_action" &&
     grep -Fq 'case "$_str_rc" in' "$_tst_action" &&
     grep -Fq 'trust_mark_request "$_str_dir" failed' "$_tst_action" &&
     grep -Fq 'obs_resume_progress_phase' "$_tst_worker" &&
     grep -Fq 'merv_progress_phase "$_orpp_token" sshtrustresume_vlanmgr' "$_tst_worker" &&
     grep -Fq 'MERV_OBS_NO_AUTOSTART=1 sh "$MERV_BASE/functions/post_apply_worker.sh" request collect' "$_tst_action" &&
     grep -Fq 'post_apply_worker.sh" run-wait "$_str_wait"' "$_tst_action"; then
    pass "progress-backed client collection isolates verified probes and relays resume progress"
  else
    fail "progress-backed client collection isolates verified probes and relays resume progress"
    _tst_ok=0
  fi

  if grep -Fq 'obs_trust_probe_progress_token()' "$_tst_worker" &&
     grep -Fq 'MERV_SSH_TRUST_PROGRESS_TOKEN="$_octg_progress_token"' "$_tst_worker" &&
     grep -Fq 'obs_trust_gate_grant' "$_tst_worker" &&
     grep -Fq 'merv_node_list_digest' "$MERV_BASE/settings/lib_json.sh" &&
     grep -Fq 'type md5sum' "$MERV_BASE/settings/lib_json.sh" &&
     grep -Fq 'merv_node_list_digest' "$_tst_ssh" &&
     grep -Fq 'merv_ssh_preflight_grant_fresh' "$_tst_ssh" &&
     grep -Fq 'merv_ssh_preflight_grant_fresh' "$_tst_collect" &&
     grep -Fq 'Reusing the verified SSH host-key preflight for this client refresh' "$_tst_collect" &&
     grep -Fq 'frontend_owned: true' "$_tst_ui" &&
     grep -Fq 'active.frontendOwned' "$_tst_ui"; then
    pass "client refresh keeps its own progress while reusing a portable immediate trust preflight"
  else
    fail "client refresh keeps its own progress while reusing a portable immediate trust preflight"
    _tst_ok=0
  fi

  _tst_digest_fallback=$( (
    . "$MERV_BASE/settings/lib_json.sh"
    merv_node_list() { printf '1 192.0.2.1\n'; }
    cksum() { return 127; }
    merv_node_list_digest
  ) 2>/dev/null )
  case "$_tst_digest_fallback" in
    md5:[0-9A-Fa-f][0-9A-Fa-f]*) pass "node-set trust digest falls back when cksum is unavailable" ;;
    *) fail "node-set trust digest falls back when cksum is unavailable"; _tst_ok=0 ;;
  esac

  if grep -Fq 'merv_ssh_require_verified_node' "$_tst_ssh" &&
     grep -Fq 'case "$MERV_SSH_SKIP_PING" in' "$_tst_ssh"; then
    pass "worker SSH ping optimization retains the host-key trust requirement"
  else
    fail "worker SSH ping optimization retains the host-key trust requirement"
    _tst_ok=0
  fi

  if grep -Fq 'MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh nodeenable --local' "$_tst_sync" &&
     grep -Fq 'STAGED_NODE_FAIL' "$_tst_sync" &&
     grep -Fq 'node-activation-failed' "$_tst_sync" &&
     grep -Fq 'MERV_NODE_CONTEXT=1 sh ./mervlan_boot.sh' "$_tst_boot" &&
     [ "$(grep -Fc 'reconcile_legacy_boot_file_locks' "$_tst_boot")" -ge 3 ] &&
     grep -Fq 'Refusing setupenable while legacy boot-file lock state is ambiguous' "$_tst_boot" &&
     grep -Fq 'Refusing setupdisable while legacy boot-file lock state is ambiguous' "$_tst_boot" &&
     grep -Fq 'merv_lock_quarantine_legacy_file' "$_tst_lib"; then
    pass "boot hook activation/removal uses shell-safe invocation, diagnostics, and legacy-lock migration"
  else
    fail "boot hook activation/removal uses shell-safe invocation, diagnostics, and legacy-lock migration"
    _tst_ok=0
  fi

  . "$_tst_lib"
  _tst_legacy="$SELFTEST_ROOT/legacy-service-event.lock"
  : > "$_tst_legacy"
  MERV_LEGACY_LOCK_STALE_SEC=0
  if merv_lock_quarantine_legacy_file "$_tst_legacy" boot-file &&
     [ ! -e "$_tst_legacy" ] &&
     find "$SELFTEST_ROOT" -name 'legacy-service-event.lock.legacy.quarantine.*' -print 2>/dev/null | grep -q .; then
    pass "stale empty legacy lock is quarantined, not deleted"
  else
    fail "stale empty legacy lock is quarantined, not deleted"
    _tst_ok=0
  fi
  _tst_legacy_nonempty="$SELFTEST_ROOT/legacy-nonempty.lock"
  printf 'unknown\n' > "$_tst_legacy_nonempty"
  if merv_lock_quarantine_legacy_file "$_tst_legacy_nonempty" boot-file; then
    fail "non-empty legacy lock remains fail-closed"
    _tst_ok=0
  else
    pass "non-empty legacy lock remains fail-closed"
  fi
  unset MERV_LEGACY_LOCK_STALE_SEC

  return "$_tst_ok"
}

test_logging_polling_contract() {
  _tlpc_ui="$MERV_BASE/www/index.html"
  _tlpc_ok=1

  if grep -q 'cliPollInFlight' "$_tlpc_ui" &&
     grep -q 'updateLogPollInFlight' "$_tlpc_ui" &&
     grep -q 'maintenancePollInFlight' "$_tlpc_ui" &&
     grep -q 'CLI log polling is temporarily unavailable' "$_tlpc_ui" &&
     grep -q 'Update output is temporarily unavailable; retrying' "$_tlpc_ui" &&
     grep -q 'Client inventory polling is temporarily unavailable' "$_tlpc_ui"; then
    pass "UI log and status pollers serialize requests and expose transient failures"
  else
    fail "UI log and status pollers serialize requests and expose transient failures"
    _tlpc_ok=0
  fi

  if grep -q 'const followUp = afterSubmit(loadingTask)' "$_tlpc_ui" &&
     grep -q 'The action follow-up failed' "$_tlpc_ui" &&
     grep -q 'releaseActionLock(actionScriptName)' "$_tlpc_ui" &&
     grep -q "const actionSubmitted = await triggerAction('checkservice_vlanmgr'" "$_tlpc_ui"; then
    pass "action follow-up failures release state and service status awaits submission"
  else
    fail "action follow-up failures release state and service status awaits submission"
    _tlpc_ok=0
  fi

  return "$_tlpc_ok"
}

test_apply_observation_contract() {
  _tao_exec="$MERV_BASE/functions/execute_nodes.sh"
  _tao_manager="$MERV_BASE/functions/mervlan_manager.sh"
  _tao_worker="$MERV_BASE/functions/post_apply_worker.sh"
  _tao_ok=1
  _tao_phase=$(sed -n '/# PHASE 4:/,/^echo ""$/p' "$_tao_exec" 2>/dev/null)

  if printf '%s\n' "$_tao_phase" | grep -Fq 'if [ -f "$FUNCDIR/post_apply_worker.sh" ]; then' &&
     ! printf '%s\n' "$_tao_phase" | grep -Fq 'MODE" != "nodesonly"' &&
     printf '%s\n' "$_tao_phase" | grep -Fq 'if [ "$overall_success" = "true" ] && [ "$local_success" = "true" ]; then' &&
     printf '%s\n' "$_tao_phase" | grep -Fq 'Skipping post-apply observation until every node has reached terminal verified success' &&
     printf '%s\n' "$_tao_phase" | grep -Fq 'request snapshot collect' &&
     printf '%s\n' "$_tao_phase" | grep -Fq '"$FUNCDIR/post_apply_worker.sh" run-wait' &&
     printf '%s\n' "$_tao_phase" | grep -Fq 'overall_success=false'; then
    pass "node Apply refreshes clients only after every node reaches terminal verified success"
  else
    fail "node Apply refreshes clients only after every node reaches terminal verified success"
    _tao_ok=0
  fi

  if grep -Fq '[ -f "$MERV_BASE/functions/collect_clients.sh" ]' "$_tao_worker" &&
     grep -Fq 'sh "$MERV_BASE/functions/collect_clients.sh"' "$_tao_worker" &&
     grep -Fq '[ -f "$MERV_BASE/functions/collect_local_clients.sh" ]' "$_tao_worker" &&
     grep -Fq 'sh "$MERV_BASE/functions/collect_local_clients.sh"' "$_tao_worker"; then
    pass "observation worker invokes shell collectors without relying on executable bits"
  else
    fail "observation worker invokes shell collectors without relying on executable bits"
    _tao_ok=0
  fi

  if grep -Fq 'collect_execute_nodes_observation_grant_valid' "$MERV_BASE/functions/collect_clients.sh" &&
     grep -Fq 'MERV_OBS_EXECUTE_NODES_OWNER_GRANT=1' "$_tao_exec" &&
     grep -Fq 'MERV_OBS_EXECUTE_NODES_OWNER_NONCE' "$_tao_exec" &&
     grep -Fq 'merv_process_identity_matches' "$MERV_BASE/functions/collect_clients.sh"; then
    pass "node Apply final collection authenticates the exact execute_nodes owner"
  else
    fail "node Apply final collection authenticates the exact execute_nodes owner"
    _tao_ok=0
  fi

  if grep -Fq 'sh "$local_script" --no-collect' "$_tao_exec" &&
     grep -Fq 'MERV_OBS_NO_AUTOSTART=1 sh "$FUNCDIR/post_apply_worker.sh"' "$_tao_manager" &&
     grep -Fq '"$FUNCDIR/post_apply_worker.sh" run-wait' "$_tao_manager"; then
    pass "local and no-node combined Apply paths avoid duplicate collection"
  else
    fail "local and no-node combined Apply paths avoid duplicate collection"
    _tao_ok=0
  fi

  if grep -Fq 'if ! merv_mac_boot_init; then' "$_tao_manager" &&
     grep -Fq 'if ! cleanup_existing_config; then' "$_tao_manager" &&
     grep -Fq 'post-restart shield reload failed' "$_tao_manager"; then
    pass "manager fails closed when strict MERV_MAC lifecycle verification fails"
  else
    fail "manager fails closed when strict MERV_MAC lifecycle verification fails"
    _tao_ok=0
  fi

  if grep -Fq 'Refreshing client inventory...' "$_tao_exec" &&
     grep -Fq 'merv_action_progress_update complete 1 1 98 "Refreshing client inventory..."' "$_tao_manager" &&
     ! grep -Fq 'Collecting final cluster information' "$_tao_exec" &&
     grep -Fq 'post-apply-observation-failed' "$_tao_manager" &&
     grep -Fq 'post-apply-observation-unavailable' "$_tao_manager"; then
    pass "client refresh progress wording and failure paths are explicit"
  else
    fail "client refresh progress wording and failure paths are explicit"
    _tao_ok=0
  fi

  _tao_release=$(grep -n 'if ! release_script_lock' "$_tao_manager" 2>/dev/null | tail -n 1 | cut -d: -f1)
  _tao_wait=$(grep -n 'MERV_OBS_NO_AUTOSTART=1 sh "$FUNCDIR/post_apply_worker.sh"' "$_tao_manager" 2>/dev/null | tail -n 1 | cut -d: -f1)
  case "$_tao_release:$_tao_wait" in
    ''|*[!0-9:]*|*::)
      fail "manager releases its configuration lock before observation wait"
      _tao_ok=0
      ;;
    *)
      if [ "$_tao_release" -lt "$_tao_wait" ]; then
        pass "manager releases its configuration lock before observation wait"
      else
        fail "manager releases its configuration lock before observation wait"
        _tao_ok=0
      fi
      ;;
  esac

  _tao_wrap="$MERV_BASE/functions/mervlan_boot_wrap.sh"
  _tao_shield_clear=$(grep -n 'rm -f "$LOCKDIR/merv_boot_shield.active"' "$_tao_wrap" 2>/dev/null | tail -n 1 | cut -d: -f1)
  _tao_boot_wait=$(grep -n 'run-wait "${MERV_OBS_AUTOSTART_WAIT_SEC:-120}"' "$_tao_wrap" 2>/dev/null | tail -n 1 | cut -d: -f1)
  if grep -Fq 'if [ "$MERV_MANAGER_MODE" = "boot" ]' "$_tao_manager" &&
     grep -Fq 'request snapshot collect' "$_tao_manager" &&
     [ -n "$_tao_shield_clear" ] && [ -n "$_tao_boot_wait" ] &&
     [ "$_tao_shield_clear" -lt "$_tao_boot_wait" ]; then
    pass "Boot queues observation, tears down the shield, then runs the worker"
  else
    fail "Boot queues observation, tears down the shield, then runs the worker"
    _tao_ok=0
  fi

  return "$_tao_ok"
}

test_wan_native_contract() {
  _twn_ok=0
  _twn_root="$SELFTEST_ROOT/wan-native"
  _twn_base="$_twn_root/base"
  _twn_bin="$_twn_root/bin"
  _twn_net="$_twn_root/net"
  _twn_proc="$_twn_root/proc"
  _twn_dhcp_pidfile="$_twn_root/udhcpc_lan.pid"
  _twn_dhcp_addr="$_twn_root/lan.addr"
  _twn_dhcp_expected="192.0.2.20"
  rm -rf "$_twn_root" 2>/dev/null || return 1
  mkdir -p "$_twn_base" "$_twn_bin" "$_twn_net/br0/brif" "$_twn_net/eth0" "$_twn_proc" || return 1
  cp -R "$MERV_BASE/settings" "$_twn_base/" || return 1
  mkdir -p "$_twn_base/functions" || return 1
  cp "$MERV_BASE/functions/mervlan_wan.sh" "$_twn_base/functions/" || return 1
  printf '%s\n' '02:00:00:00:00:01' > "$_twn_net/br0/address"
  : > "$_twn_net/eth0/address"
  : > "$_twn_net/br0/brif/eth0"
  printf '%s\n' '192.0.2.10/24' > "$_twn_dhcp_addr"

cat > "$_twn_bin/nvram" <<'MERV_WAN_NVRAM'
#!/bin/sh
[ "$1" = get ] || exit 1
case "$2" in
  lan_proto) printf '%s\n' "${WAN_TEST_LAN_PROTO:-dhcp}" ;;
  lan_ipaddr) printf '%s\n' "${WAN_TEST_EXPECTED_ADDRESS:-192.0.2.20/24}" ;;
  *) exit 1 ;;
esac
MERV_WAN_NVRAM

cat > "$_twn_bin/brctl" <<'MERV_WAN_BRCTL'
#!/bin/sh
wan_test_signal() {
  [ -n "${WAN_TEST_SIGNAL_PHASE:-}" ] || return 0
  [ -n "${WAN_TEST_SIGNAL_PID:-}" ] || return 0
  [ -n "${WAN_TEST_SIGNAL_ONCE:-}" ] || return 0
  [ ! -e "$WAN_TEST_SIGNAL_ONCE" ] || return 0
  : > "$WAN_TEST_SIGNAL_ONCE" || return 0
  kill -TERM "$WAN_TEST_SIGNAL_PID" 2>/dev/null || :
}
case "$1" in
  addif)
    [ "${FAIL_ADD_IF:-}" != "$3" ] || exit 1
    mkdir -p "$MERV_WAN_NET_ROOT/$2/brif" || exit 1
    : > "$MERV_WAN_NET_ROOT/$2/brif/$3"
    [ -n "${WAN_TEST_ORDER_LOG:-}" ] && printf 'add %s\n' "$3" >> "$WAN_TEST_ORDER_LOG"
    [ "${FAIL_VERIFY_IF:-}" = "$3" ] && {
      { printf '%s  VID: 4094\n' "$3"; printf 'Device: wrong-lower\n'; } > "$MERV_WAN_PROC_VLAN_ROOT/$3"
    }
    [ "${WAN_TEST_SIGNAL_PHASE:-}" = attach-before-verify ] && [ "$3" = "${WAN_TEST_SIGNAL_IF:-}" ] && wan_test_signal || :
    ;;
  delif)
    [ "${FAIL_DEL_IF:-}" != "$3" ] || exit 1
    rm -f "$MERV_WAN_NET_ROOT/$2/brif/$3"
    [ -n "${WAN_TEST_ORDER_LOG:-}" ] && printf 'del %s\n' "$3" >> "$WAN_TEST_ORDER_LOG"
    [ "${WAN_TEST_SIGNAL_PHASE:-}" = detach-before-attach ] && [ "$3" = "${WAN_TEST_SIGNAL_IF:-}" ] && wan_test_signal || :
    ;;
  show) : ;;
  *) exit 1 ;;
esac
MERV_WAN_BRCTL
  cat > "$_twn_bin/ip" <<'MERV_WAN_IP'
#!/bin/sh
[ "$1" = -4 ] && shift
[ "$1" = addr ] && {
  shift
  case "$1" in
    show)
      [ "$2" = dev ] || exit 1
      _wan_addr=$(sed -n '1p' "${WAN_TEST_ADDRESS_FILE:?}" 2>/dev/null)
      [ -n "$_wan_addr" ] && printf '    inet %s scope global %s\n' "$_wan_addr" "$3"
      exit 0
      ;;
    flush)
      [ "$2" = dev ] || exit 1
      : > "${WAN_TEST_ADDRESS_FILE:?}" || exit 1
      exit 0
      ;;
    add)
      _wan_addr="$2"
      [ "$3" = dev ] || exit 1
      printf '%s\n' "$_wan_addr" > "${WAN_TEST_ADDRESS_FILE:?}" || exit 1
      exit 0
      ;;
    *) exit 1 ;;
  esac
}
[ "$1" = link ] || exit 1
shift
case "$1" in
  add)
    shift
    [ "$1" = link ] || exit 1; lower="$2"; shift 2
    [ "$1" = name ] || exit 1; ifc="$2"; shift 2
    [ "$1" = type ] && [ "$2" = vlan ] || exit 1; shift 2
    [ "$1" = id ] || exit 1; vid="$2"
    mkdir -p "$MERV_WAN_NET_ROOT/$ifc" || exit 1
    { printf '%s  VID: %s\n' "$ifc" "$vid"; printf 'Device: %s\n' "$lower"; } > "$MERV_WAN_PROC_VLAN_ROOT/$ifc"
    ;;
  set)
    if [ "${FAIL_MAC_DRIFT:-}" = 1 ] && [ "$2" != address ]; then
      printf '%s\n' '02:00:00:00:00:ff' > "$MERV_WAN_NET_ROOT/br0/address"
    fi
    [ "${FAIL_MAC_RESTORE:-}" = 1 ] && [ "$2" = address ] && exit 1
    :
    ;;
  del)
    ifc="$2"
    for x in "$MERV_WAN_NET_ROOT"/*/brif/"$ifc"; do [ -e "$x" ] && rm -f "$x" || :; done
    rm -rf "$MERV_WAN_NET_ROOT/$ifc" "$MERV_WAN_PROC_VLAN_ROOT/$ifc"
    ;;
  *) exit 1 ;;
esac
MERV_WAN_IP
  chmod 755 "$_twn_bin/brctl" "$_twn_bin/ip" "$_twn_bin/nvram" || return 1
  _twn_settings="$_twn_base/settings/settings.json"
  json_set_section2_value VLAN WAN_Native MAIN_WAN_NATIVE_IP "$_twn_dhcp_expected" "$_twn_settings" || return 1
  json_set_section2_value VLAN WAN_Native MAIN_ASUS_IP 192.0.2.10 "$_twn_settings" || return 1
  _twn_dhcp_pid=4242
  printf '%s\n' "$_twn_dhcp_pid" > "$_twn_dhcp_pidfile"
  # The production helper validates PID/start identity against /proc.  This
  # isolated fixture uses a private proc root and an authenticated fake
  # udhcpc identity; the signal itself is published to a marker file, so no
  # host process is ever signalled.
  mkdir -p "$_twn_proc/$_twn_dhcp_pid" || return 1
  {
    printf '%s' '(udhcpc) S'
    _twn_stat_i=1
    while [ "$_twn_stat_i" -lt 19 ]; do printf '%s' ' 0'; _twn_stat_i=$((_twn_stat_i + 1)); done
    printf '%s\n' ' 424242'
  } > "$_twn_proc/$_twn_dhcp_pid/stat" || return 1
  printf 'udhcpc\000-i\000br0\000-p\000%s\000-s\000/sbin/rc\000-H\000wan-test\000' "$_twn_dhcp_pidfile" > "$_twn_proc/$_twn_dhcp_pid/cmdline" || return 1
  printf '%s\n' 424242 > "${_twn_dhcp_pidfile}.start"

  _twn_run() (
    # Every invocation must derive its role from the fixture file.  The parent
    # selftest may have sourced a node-oriented helper, so do not leak a stale
    # shell NODE_ID into this new WAN process.
    export NODE_ID='' MERV_NODE_ID=''
    PATH="$_twn_bin:$PATH" MERV_BASE="$_twn_base" DRY_RUN=no \
      WAN_TEST_LAN_PROTO="${WAN_TEST_LAN_PROTO:-dhcp}" \
      WAN_TEST_EXPECTED_ADDRESS="${WAN_TEST_EXPECTED_ADDRESS:-192.0.2.20}" \
      WAN_TEST_PIDFILE="$_twn_dhcp_pidfile" WAN_TEST_ADDRESS_FILE="$_twn_dhcp_addr" \
      WAN_TEST_SUPPRESS_FILE="$_twn_root/no-address" \
      MERV_WAN_DHCP_PIDFILE="$_twn_dhcp_pidfile" \
      MERV_WAN_DHCP_TEST_ADDRESS_FILE="$_twn_dhcp_addr" \
      MERV_WAN_DHCP_TEST_LIFECYCLE_FILE="$_twn_root/dhcp.lifecycle" \
      MERV_WAN_DHCP_TEST_SUPPRESS_FILE="$_twn_root/no-address" \
      MERV_WAN_DHCP_TEST_ADDRESS_PREFIX="/24" \
      MERV_WAN_DHCP_TEST_DELAY_POLLS="${WAN_TEST_DHCP_DELAY_POLLS:-0}" \
      MERV_WAN_DHCP_TEST_TERM_AFTER_RELEASE="${WAN_TEST_DHCP_TERM_AFTER_RELEASE:-0}" \
      MERV_WAN_DHCP_TEST_TERM_AFTER_TERMINATE="${WAN_TEST_DHCP_TERM_AFTER_TERMINATE:-0}" \
      MERV_WAN_DHCP_TEST_RELEASE_STAYS_ALIVE="${WAN_TEST_DHCP_RELEASE_STAYS_ALIVE:-0}" \
      MERV_WAN_DHCP_TEST_TERM_STICKS="${WAN_TEST_DHCP_TERM_STICKS:-0}" \
      MERV_WAN_DHCP_TEST_STALE_PIDFILE="${WAN_TEST_DHCP_STALE_PIDFILE:-0}" \
      MERV_WAN_DHCP_TEST_STALE_ADDRESS="${WAN_TEST_DHCP_STALE_ADDRESS:-0}" \
      MERV_WAN_DHCP_TEST_REUSE_AFTER_RELEASE="${WAN_TEST_DHCP_REUSE_AFTER_RELEASE:-0}" \
      MERV_WAN_DHCP_TEST_CMDLINE_CHANGE_AFTER_RELEASE="${WAN_TEST_DHCP_CMDLINE_CHANGE_AFTER_RELEASE:-0}" \
      MERV_WAN_DHCP_TEST_DUPLICATE_BEFORE_TERM="${WAN_TEST_DHCP_DUPLICATE_BEFORE_TERM:-0}" \
      MERV_WAN_DHCP_TEST_DUPLICATE_BEFORE_START="${WAN_TEST_DHCP_DUPLICATE_BEFORE_START:-0}" \
      MERV_WAN_DHCP_WAIT_SEC="${WAN_TEST_DHCP_WAIT_SEC:-1}" \
      MERV_WAN_DHCP_RELEASE_WAIT_SEC="${WAN_TEST_DHCP_RELEASE_WAIT_SEC:-1}" \
      MERV_WAN_DHCP_TERM_WAIT_SEC="${WAN_TEST_DHCP_TERM_WAIT_SEC:-1}" \
      MERV_WAN_NET_ROOT="$_twn_net" MERV_WAN_PROC_VLAN_ROOT="$_twn_proc" MERV_WAN_DHCP_PROC_ROOT="$_twn_proc" \
      sh -c 'WAN_TEST_SIGNAL_PID=$$; export WAN_TEST_SIGNAL_PID; exec sh "$1" "$2"' \
      sh "$_twn_base/functions/mervlan_wan.sh" "$1"
  )
  _twn_member() { [ -e "$_twn_net/br0/brif/$1" ]; }
  _twn_dhcp_reset() {
    _twn_reset_callback="${1:-/sbin/rc}"
    _twn_reset_pid="${2:-4242}"
    _twn_reset_hostname="${3:-wan-test}"
    rm -rf "$_twn_proc"/[0-9]*
    rm -f "$_twn_dhcp_pidfile" "${_twn_dhcp_pidfile}.start" "$_twn_root/dhcp.lifecycle" "$_twn_root/dhcp.lifecycle.launch-failed"
    mkdir -p "$_twn_proc/$_twn_reset_pid" || return 1
    {
      printf '%s' '(udhcpc) S'; _twn_reset_i=1
      while [ "$_twn_reset_i" -lt 19 ]; do printf '%s' ' 0'; _twn_reset_i=$((_twn_reset_i + 1)); done
      printf '%s\n' ' 424242'
    } > "$_twn_proc/$_twn_reset_pid/stat" || return 1
    printf 'udhcpc\000-i\000br0\000-p\000%s\000-s\000%s\000-H\000%s\000' "$_twn_dhcp_pidfile" "$_twn_reset_callback" "$_twn_reset_hostname" > "$_twn_proc/$_twn_reset_pid/cmdline" || return 1
    printf '%s\n' "$_twn_reset_pid" > "$_twn_dhcp_pidfile" || return 1
    printf '%s\n' 424242 > "${_twn_dhcp_pidfile}.start" || return 1
    printf '%s\n' '192.0.2.10/24' > "$_twn_dhcp_addr"
  }

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 10 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1 && _twn_member eth0.10 && ! _twn_member eth0 && _twn_run verify >/dev/null 2>&1 && _twn_run health >/dev/null 2>&1; then
    pass "WAN Native converges ASUS -> VLAN 10"
  else fail "WAN Native converges ASUS -> VLAN 10"; _twn_ok=1; fi

  # ASUSWRT's observed LAN-client hostname contains an underscore.  It is a
  # bounded accepted firmware form, not an arbitrary argv escape hatch.
  _twn_dhcp_reset /sbin/rc 4242 ZenWiFi_XT8-79F0 || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 11 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1 && _twn_member eth0.11 && ! _twn_member eth0.10; then
    pass "WAN Native accepts observed ASUS DHCP hostname form"
  else fail "WAN Native accepts observed ASUS DHCP hostname form"; _twn_ok=1; fi

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 20 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1 && _twn_member eth0.20 && ! _twn_member eth0.10 && [ ! -d "$_twn_net/eth0.10" ] && _twn_run verify >/dev/null 2>&1; then
    pass "WAN Native migrates VLAN 10 -> VLAN 20 and removes stale native upper"
  else fail "WAN Native migrates VLAN 10 -> VLAN 20 and removes stale native upper"; _twn_ok=1; fi

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN none "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1 && _twn_member eth0 && ! _twn_member eth0.20 && [ ! -d "$_twn_net/eth0.20" ] && _twn_run verify >/dev/null 2>&1; then
    if _twn_run health >/dev/null 2>&1 && [ "$(sed -n '1p' "$_twn_dhcp_addr")" = "192.0.2.10/24" ]; then
      pass "WAN Native restores VLAN 20 -> ASUS with fresh MAIN DHCP"
    else fail "WAN Native restores VLAN 20 -> ASUS with fresh MAIN DHCP"; _twn_ok=1; fi
  else fail "WAN Native restores VLAN 20 -> ASUS"; _twn_ok=1; fi

  # Reverse MAIN handoff is its own transaction: failure to acquire the ASUS
  # endpoint must restore both the VLAN-20 bridge member and VLAN-20 DHCP
  # state, rather than leaving mixed L2/L3 domains behind.
  _twn_dhcp_reset /sbin/rc || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 20 "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1 || return 1
  : > "$_twn_root/no-address"
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN none "$_twn_settings" || return 1
  (
    WAN_TEST_DHCP_WAIT_SEC=0
    export WAN_TEST_DHCP_WAIT_SEC
    _twn_run apply >/dev/null 2>&1
  )
  _twn_rc=$?
  rm -f "$_twn_root/no-address"
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.20 && ! _twn_member eth0 &&
     [ "$(sed -n '1p' "$_twn_dhcp_addr")" = "192.0.2.20/24" ]; then
    pass "WAN Native ASUS reacquisition timeout rolls back to numeric L2 and L3"
  else fail "WAN Native ASUS reacquisition timeout rolls back to numeric L2 and L3"; _twn_ok=1; fi
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN none "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1 || return 1

  rm -f "$_twn_net/br0/brif/eth0"
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN none "$_twn_settings" || return 1
  if _twn_run health >/dev/null 2>&1 || _twn_run apply >/dev/null 2>&1; then
    fail "WAN Native rejects unsupported ASUS topology without physical uplink"; _twn_ok=1
  else
    pass "WAN Native rejects unsupported ASUS topology without physical uplink"
  fi
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 50 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then
    fail "WAN Native validate rejects missing native replacement path"; _twn_ok=1
  else
    pass "WAN Native validate rejects missing native replacement path"
  fi
  if _twn_run apply >/dev/null 2>&1; then
    fail "WAN Native refuses to invent a new br0 path on non-native WAN"; _twn_ok=1
  elif [ ! -d "$_twn_net/eth0.50" ]; then
    pass "WAN Native refuses to invent a new br0 path on non-native WAN"
  else fail "WAN Native refuses to invent a new br0 path on non-native WAN"; _twn_ok=1; fi
  : > "$_twn_net/br0/brif/eth0"

  # Live preflight must fail closed when either required base interface is
  # absent, without inventing or mutating a replacement path.
  mv "$_twn_net/br0" "$_twn_root/br0-missing" || return 1
  if _twn_run validate >/dev/null 2>&1; then
    fail "WAN Native validate rejects missing br0"; _twn_ok=1
  else
    pass "WAN Native validate rejects missing br0"
  fi
  mv "$_twn_root/br0-missing" "$_twn_net/br0" || return 1
  mv "$_twn_net/eth0" "$_twn_root/eth0-missing" || return 1
  if _twn_run validate >/dev/null 2>&1; then
    fail "WAN Native validate rejects missing uplink"; _twn_ok=1
  else
    pass "WAN Native validate rejects missing uplink"
  fi
  mv "$_twn_root/eth0-missing" "$_twn_net/eth0" || return 1

  # An existing target owned by another bridge is not a valid replacement
  # candidate, even when its VLAN metadata names the expected lower device.
  mkdir -p "$_twn_net/br1/brif" "$_twn_net/eth0.101" || return 1
  : > "$_twn_net/br1/brif/eth0.101"
  {
    printf 'eth0.101  VID: 101\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.101"
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 101 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then
    fail "WAN Native rejects target owned by another bridge"; _twn_ok=1
  else
    pass "WAN Native rejects target owned by another bridge"
  fi
  rm -f "$_twn_net/br1/brif/eth0.101"
  rm -rf "$_twn_net/br1" "$_twn_net/eth0.101" "$_twn_proc/eth0.101"

  # Both halves of target identity are independently required: wrong VID and
  # wrong lower-device metadata must each reject an existing upper.
  mkdir -p "$_twn_net/eth0.102" || return 1
  : > "$_twn_net/br0/brif/eth0.102"
  {
    printf 'eth0.102  VID: 101\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.102"
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 102 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then
    fail "WAN Native rejects existing target with wrong VID metadata"; _twn_ok=1
  else
    pass "WAN Native rejects existing target with wrong VID metadata"
  fi
  {
    printf 'eth0.102  VID: 102\n'; printf 'Device: other0\n'
  } > "$_twn_proc/eth0.102"
  if _twn_run validate >/dev/null 2>&1; then
    fail "WAN Native rejects existing target with wrong lower metadata"; _twn_ok=1
  else
    pass "WAN Native rejects existing target with wrong lower metadata"
  fi
  rm -f "$_twn_net/br0/brif/eth0.102"
  rm -rf "$_twn_net/eth0.102" "$_twn_proc/eth0.102"

  # A pre-existing upper with no deterministic procfs identity must be
  # rejected before validation or mutation; the interface name alone is not
  # proof of its VLAN ID or lower device.
  mkdir -p "$_twn_net/eth0.60" || return 1
  : > "$_twn_net/br0/brif/eth0.60"
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 60 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then
    fail "WAN Native rejects existing upper without VLAN/lower metadata"; _twn_ok=1
  else
    pass "WAN Native rejects existing upper without VLAN/lower metadata"
  fi
  rm -f "$_twn_net/br0/brif/eth0.60"
  rm -rf "$_twn_net/eth0.60" "$_twn_proc/eth0.60"

  # Multiple native members are all captured and removed, while an unrelated
  # detached upper remains outside this helper's deletion ownership.
  mkdir -p "$_twn_net/eth0.60" "$_twn_net/eth0.61" "$_twn_net/eth0.200" || return 1
  {
    printf 'eth0.60  VID: 60\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.60"
  {
    printf 'eth0.61  VID: 61\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.61"
  {
    printf 'eth0.200  VID: 200\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.200"
  : > "$_twn_net/br0/brif/eth0.60"
  : > "$_twn_net/br0/brif/eth0.61"
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 70 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1 && _twn_member eth0.70 && ! _twn_member eth0.60 && ! _twn_member eth0.61 &&
     [ ! -d "$_twn_net/eth0.60" ] && [ ! -d "$_twn_net/eth0.61" ] && [ -d "$_twn_net/eth0.200" ] && ! _twn_member eth0.200; then
    pass "WAN Native handles multiple native members and preserves detached unrelated upper"
  else
    fail "WAN Native handles multiple native members and preserves detached unrelated upper"; _twn_ok=1
  fi

  # Re-applying the selected, already-verified target is idempotent and does
  # not disturb unrelated detached uppers.
  if _twn_run apply >/dev/null 2>&1 && _twn_member eth0.70 && [ -d "$_twn_net/eth0.200" ] && _twn_run verify >/dev/null 2>&1; then
    pass "WAN Native same selection is idempotent"
  else
    fail "WAN Native same selection is idempotent"; _twn_ok=1
  fi

  FAIL_DEL_IF=eth0.70; export FAIL_DEL_IF
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 80 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1; then
    fail "WAN Native detach failure is fail-closed"; _twn_ok=1
  elif _twn_member eth0.70 && ! _twn_member eth0.80 && [ ! -d "$_twn_net/eth0.80" ]; then
    pass "WAN Native detach failure restores captured native path"
  else
    fail "WAN Native detach failure restores captured native path"; _twn_ok=1
  fi
  unset FAIL_DEL_IF

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 1 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then fail "WAN Native rejects VLAN 1"; _twn_ok=1; else pass "WAN Native rejects VLAN 1"; fi

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 4095 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then fail "WAN Native rejects VLAN 4095"; _twn_ok=1; else pass "WAN Native rejects VLAN 4095"; fi
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN not-a-vlan "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then fail "WAN Native rejects nonnumeric VLAN"; _twn_ok=1; else pass "WAN Native rejects nonnumeric VLAN"; fi

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 31 "$_twn_settings" || return 1
  json_set_section2_value WiFi SSIDs SSID_01 guest "$_twn_settings" || return 1
  json_set_section2_value VLAN Pool VLAN_01 31 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then fail "WAN Native rejects SSID VLAN conflict"; _twn_ok=1; else pass "WAN Native rejects SSID VLAN conflict"; fi
  json_set_section2_value WiFi SSIDs SSID_01 unused-placeholder "$_twn_settings" || return 1
  json_set_section2_value VLAN Pool VLAN_01 none "$_twn_settings" || return 1

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 32 "$_twn_settings" || return 1
  json_set_section2_value VLAN Trunks TRUNK1 1 "$_twn_settings" || return 1
  json_set_section2_value VLAN Trunks TAGGED_TRUNK1 32 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then fail "WAN Native rejects tagged trunk VLAN conflict"; _twn_ok=1; else pass "WAN Native rejects tagged trunk VLAN conflict"; fi
  json_set_section2_value VLAN Trunks TAGGED_TRUNK1 none "$_twn_settings" || return 1

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 33 "$_twn_settings" || return 1
  json_set_section2_value VLAN Trunks UNTAGGED_TRUNK1 33 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then fail "WAN Native rejects untagged trunk VLAN conflict"; _twn_ok=1; else pass "WAN Native rejects untagged trunk VLAN conflict"; fi
  json_set_section2_value VLAN Trunks UNTAGGED_TRUNK1 none "$_twn_settings" || return 1
  json_set_section2_value VLAN Trunks TRUNK1 0 "$_twn_settings" || return 1

  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 30 "$_twn_settings" || return 1
  json_set_section2_value VLAN Ethernet_ports ETH1_VLAN 30 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then fail "WAN Native rejects same-device access VLAN conflict"; _twn_ok=1; else pass "WAN Native rejects same-device access VLAN conflict"; fi
  json_set_section2_value VLAN Ethernet_ports ETH1_VLAN none "$_twn_settings" || return 1

  FAIL_ADD_IF=eth0.30; export FAIL_ADD_IF
  if _twn_run apply >/dev/null 2>&1; then
    fail "WAN Native replacement attach failure is fail-closed"; _twn_ok=1
  elif _twn_member eth0.70 && ! _twn_member eth0.30 && [ ! -d "$_twn_net/eth0.30" ]; then
    pass "WAN Native replacement attach failure rolls back prior path"
  else
    fail "WAN Native replacement attach failure rolls back prior path"; _twn_ok=1
  fi
  unset FAIL_ADD_IF

  json_set_section_value General NODE_ID 1 "$_twn_settings" || return 1
  # This section exercises the retained independent-node policy.  Do not
  # inherit the live router's AiMesh role when the fixture expects NODE1's
  # configured native value.
  json_set_section_value Nodes NODE1_ROLE standalone "$_twn_settings" || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 77 "$_twn_settings" || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_NODE1 44 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1 && _twn_member eth0.44 && ! _twn_member eth0 && _twn_run verify >/dev/null 2>&1; then
    pass "WAN Native selects the per-node NODE1 setting"
  else fail "WAN Native selects the per-node NODE1 setting"; _twn_ok=1; fi

  # DHCP handoff is MAIN-only: a node with a static LAN remains untouched by
  # the MAIN protocol guard and does not signal the MAIN udhcpc fixture.
  _twn_node_address_before="$(cat "$_twn_dhcp_addr" 2>/dev/null)"
  # Some ASUSWRT BusyBox ash versions retain a temporary assignment made for
  # a shell function.  Keep this node-only static-LAN probe in a subshell so
  # later MAIN/DHCP cases cannot inherit its intentionally static protocol.
  (
    WAN_TEST_LAN_PROTO=static
    export WAN_TEST_LAN_PROTO
    _twn_run apply >/dev/null 2>&1
  )
  _twn_rc=$?
  if [ "$_twn_rc" -eq 0 ] && _twn_member eth0.44 && [ "$(cat "$_twn_dhcp_addr" 2>/dev/null)" = "$_twn_node_address_before" ]; then
    pass "WAN Native leaves node LAN policy untouched"
  else
    fail "WAN Native leaves node LAN policy untouched"; _twn_ok=1
  fi

  # MAIN trunks do not exist on node runtime. Shared settings may therefore use
  # a VLAN on a MAIN trunk and independently use that VID as NODE1 WAN Native.
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_NODE1 45 "$_twn_settings" || return 1
  json_set_section2_value VLAN Trunks TRUNK1 1 "$_twn_settings" || return 1
  json_set_section2_value VLAN Trunks TAGGED_TRUNK1 45 "$_twn_settings" || return 1
  if _twn_run validate >/dev/null 2>&1; then
    pass "WAN Native node validation ignores MAIN-only trunk VLANs"
  else fail "WAN Native node validation ignores MAIN-only trunk VLANs"; _twn_ok=1; fi
  json_set_section2_value VLAN Trunks TRUNK1 0 "$_twn_settings" || return 1
  json_set_section2_value VLAN Trunks TAGGED_TRUNK1 none "$_twn_settings" || return 1

  # Signals delivered during the active membership transaction must restore
  # the captured path and retain the conventional TERM status.  The fake
  # brctl sends TERM from the exact detach/add transition once per run.
  json_set_section_value General NODE_ID none "$_twn_settings" || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 90 "$_twn_settings" || return 1
  WAN_TEST_SIGNAL_PHASE=detach-before-attach WAN_TEST_SIGNAL_IF=eth0.44 \
    WAN_TEST_SIGNAL_ONCE="$_twn_root/signal-detach.once"
  export WAN_TEST_SIGNAL_PHASE WAN_TEST_SIGNAL_IF WAN_TEST_SIGNAL_ONCE
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -eq 0 ]; then
    fail "WAN Native TERM after detach is nonzero and fail-closed"; _twn_ok=1
  elif [ "$_twn_rc" -ne 143 ]; then
    fail "WAN Native TERM after detach preserves status 143 (actual=$_twn_rc)"; _twn_ok=1
  elif _twn_member eth0.44 && ! _twn_member eth0.90 && [ ! -d "$_twn_net/eth0.90" ]; then
    pass "WAN Native TERM after detach restores captured members"
  else
    fail "WAN Native TERM after detach restores captured members"; _twn_ok=1
  fi
  unset WAN_TEST_SIGNAL_PHASE WAN_TEST_SIGNAL_IF WAN_TEST_SIGNAL_ONCE

  WAN_TEST_SIGNAL_PHASE=attach-before-verify WAN_TEST_SIGNAL_IF=eth0.91 \
    WAN_TEST_SIGNAL_ONCE="$_twn_root/signal-attach.once"
  export WAN_TEST_SIGNAL_PHASE WAN_TEST_SIGNAL_IF WAN_TEST_SIGNAL_ONCE
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 91 "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -eq 0 ]; then
    fail "WAN Native TERM after attach is nonzero and fail-closed"; _twn_ok=1
  elif [ "$_twn_rc" -ne 143 ]; then
    fail "WAN Native TERM after attach preserves status 143 (actual=$_twn_rc)"; _twn_ok=1
  elif _twn_member eth0.44 && ! _twn_member eth0.91 && [ ! -d "$_twn_net/eth0.91" ]; then
    pass "WAN Native TERM after attach restores captured members"
  else
    fail "WAN Native TERM after attach restores captured members"; _twn_ok=1
  fi
  unset WAN_TEST_SIGNAL_PHASE WAN_TEST_SIGNAL_IF WAN_TEST_SIGNAL_ONCE

  # Corrupting verified metadata after attach forces verify_live to fail; the
  # same rollback path must restore the previous native upper.
  FAIL_VERIFY_IF=eth0.92; export FAIL_VERIFY_IF
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 92 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1; then
    fail "WAN Native verification failure is fail-closed"; _twn_ok=1
  elif _twn_member eth0.44 && ! _twn_member eth0.92 && [ ! -d "$_twn_net/eth0.92" ]; then
    pass "WAN Native verification failure restores captured members"
  else
    fail "WAN Native verification failure restores captured members"; _twn_ok=1
  fi
  unset FAIL_VERIFY_IF

  # If convergence finds an extra captured native member after the target is
  # already attached, removal failure must restore every original member and
  # return nonzero.
  rm -f "$_twn_net/br0/brif/eth0.44"
  mkdir -p "$_twn_net/eth0.94" "$_twn_net/eth0.95" || return 1
  {
    printf 'eth0.94  VID: 94\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.94"
  {
    printf 'eth0.95  VID: 95\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.95"
  : > "$_twn_net/br0/brif/eth0.94"
  : > "$_twn_net/br0/brif/eth0.95"
  FAIL_DEL_IF=eth0.95; export FAIL_DEL_IF
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 94 "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -eq 0 ]; then
    fail "WAN Native extra-member removal failure is nonzero"; _twn_ok=1
  elif _twn_member eth0.94 && _twn_member eth0.95; then
    pass "WAN Native extra-member removal failure restores all captured members"
  else
    fail "WAN Native extra-member removal failure restores all captured members"; _twn_ok=1
  fi
  unset FAIL_DEL_IF
  rm -f "$_twn_net/br0/brif/eth0.94" "$_twn_net/br0/brif/eth0.95"
  rm -rf "$_twn_net/eth0.94" "$_twn_net/eth0.95" "$_twn_proc/eth0.94" "$_twn_proc/eth0.95"
  : > "$_twn_net/br0/brif/eth0.44"

  # Force a bridge-MAC drift before restore and make the restore command fail;
  # membership rollback remains mandatory and the operation must be nonzero.
  FAIL_MAC_DRIFT=1 FAIL_MAC_RESTORE=1; export FAIL_MAC_DRIFT FAIL_MAC_RESTORE
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 93 "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -eq 0 ]; then
    fail "WAN Native MAC restore failure is nonzero"; _twn_ok=1
  elif _twn_member eth0.44 && ! _twn_member eth0.93 && [ ! -d "$_twn_net/eth0.93" ]; then
    pass "WAN Native MAC restore failure rolls back native membership"
  else
    fail "WAN Native MAC restore failure rolls back native membership"; _twn_ok=1
  fi
  unset FAIL_MAC_DRIFT FAIL_MAC_RESTORE
  printf '%s\n' '02:00:00:00:00:01' > "$_twn_net/br0/address"

  # Record bridge operations to prove no replacement attach happens until all
  # captured native members have been detached.
  rm -f "$_twn_net/br0/brif/eth0.44"
  mkdir -p "$_twn_net/eth0.96" "$_twn_net/eth0.97" || return 1
  {
    printf 'eth0.96  VID: 96\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.96"
  {
    printf 'eth0.97  VID: 97\n'; printf 'Device: eth0\n'
  } > "$_twn_proc/eth0.97"
  : > "$_twn_net/br0/brif/eth0.96"
  : > "$_twn_net/br0/brif/eth0.97"
  _twn_order_log="$_twn_root/order.log"
  : > "$_twn_order_log"
  WAN_TEST_ORDER_LOG="$_twn_order_log"; export WAN_TEST_ORDER_LOG
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 98 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1 &&
     [ "$(sed -n '1p' "$_twn_order_log")" = "del eth0.96" ] &&
     [ "$(sed -n '2p' "$_twn_order_log")" = "del eth0.97" ] &&
     [ "$(sed -n '3p' "$_twn_order_log")" = "add eth0.98" ] &&
     [ "$(wc -l < "$_twn_order_log")" -eq 3 ]; then
    pass "WAN Native detaches every captured member before target attach"
  else
    fail "WAN Native detaches every captured member before target attach"; _twn_ok=1
  fi
  unset WAN_TEST_ORDER_LOG

  # A numeric MAIN target needs only its target-domain reservation.  The ASUS
  # recovery reservation is optional until a later return to ASUS/default.
  json_set_section2_value VLAN WAN_Native MAIN_ASUS_IP none "$_twn_settings" || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 99 "$_twn_settings" || return 1
  if _twn_run apply >/dev/null 2>&1 && _twn_member eth0.99 && ! _twn_member eth0.98; then
    pass "WAN Native numeric MAIN works without ASUS/default recovery IP"
  else
    fail "WAN Native numeric MAIN works without ASUS/default recovery IP"; _twn_ok=1
  fi
  : > "$_twn_order_log"
  WAN_TEST_ORDER_LOG="$_twn_order_log"; export WAN_TEST_ORDER_LOG
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN none "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.99 && ! _twn_member eth0 && [ "$(wc -l < "$_twn_order_log")" -eq 0 ]; then
    pass "WAN Native refuses return to ASUS without recovery IP before mutation"
  else
    fail "WAN Native refuses return to ASUS without recovery IP before mutation"; _twn_ok=1
  fi
  unset WAN_TEST_ORDER_LOG
  json_set_section2_value VLAN WAN_Native MAIN_ASUS_IP 192.0.2.10 "$_twn_settings" || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 98 "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1 || return 1

  # MAIN static LAN is rejected before any bridge operation.  The target and
  # captured native member must remain exactly as they were before preflight.
  : > "$_twn_order_log"
  json_set_section_value General NODE_ID none "$_twn_settings" || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 99 "$_twn_settings" || return 1
  if (
    WAN_TEST_LAN_PROTO=static
    export WAN_TEST_LAN_PROTO
    _twn_run validate >/dev/null 2>&1
  ); then
    fail "WAN Native manager preflight rejects numeric MAIN on static LAN"; _twn_ok=1
  else
    pass "WAN Native manager preflight rejects numeric MAIN on static LAN"
  fi
  (
    WAN_TEST_LAN_PROTO=static
    export WAN_TEST_LAN_PROTO
    _twn_run apply >/dev/null 2>&1
  )
  _twn_rc=$?
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && ! _twn_member eth0.99 && [ "$(wc -l < "$_twn_order_log")" -eq 0 ]; then
    pass "WAN Native blocks numeric MAIN on static LAN before mutation"
  else
    fail "WAN Native blocks numeric MAIN on static LAN before mutation"; _twn_ok=1
  fi

  # The explicit MAIN endpoint is production state, not a test-only default.
  # Its absence must fail before bridge mutation even when LAN DHCP is active.
  json_set_section2_value VLAN WAN_Native MAIN_WAN_NATIVE_IP none "$_twn_settings" || return 1
  : > "$_twn_order_log"
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && ! _twn_member eth0.99 && [ "$(wc -l < "$_twn_order_log")" -eq 0 ]; then
    pass "WAN Native requires persisted MAIN DHCP endpoint before mutation"
  else
    fail "WAN Native requires persisted MAIN DHCP endpoint before mutation"; _twn_ok=1
  fi
  json_set_section2_value VLAN WAN_Native MAIN_WAN_NATIVE_IP "$_twn_dhcp_expected" "$_twn_settings" || return 1

  # Reboots can remove the configured MerVLAN tmp root before any manager
  # initialization. DHCP argv identity parsing must fall back to /tmp rather
  # than turning this read-only preflight into a false safety failure.
  MERV_WAN_DHCP_TMP_ROOT="$_twn_root/missing-tmpdir"; export MERV_WAN_DHCP_TMP_ROOT
  if _twn_run validate >/dev/null 2>&1; then
    pass "WAN Native DHCP identity preflight tolerates missing configured tmp root"
  else
    fail "WAN Native DHCP identity preflight tolerates missing configured tmp root"; _twn_ok=1
  fi
  unset MERV_WAN_DHCP_TMP_ROOT

  # Delayed lease publication must be observed before commit.  The fake
  # address is CIDR-shaped at rest, while persisted endpoint is host-only.
  printf '%s\n' '192.0.2.10/24' > "$_twn_dhcp_addr"
  (
    WAN_TEST_DHCP_DELAY_POLLS=1
    WAN_TEST_DHCP_WAIT_SEC=2
    export WAN_TEST_DHCP_DELAY_POLLS WAN_TEST_DHCP_WAIT_SEC
    _twn_run apply >/dev/null 2>&1
  )
  _twn_rc=$?
  if [ "$_twn_rc" -eq 0 ] && _twn_member eth0.99 && ! _twn_member eth0.98 && [ "$(cat "$_twn_dhcp_addr" 2>/dev/null)" = "192.0.2.20/24" ]; then
    pass "WAN Native accepts delayed persisted MAIN DHCP endpoint acquisition"
  else
    fail "WAN Native accepts delayed persisted MAIN DHCP endpoint acquisition"; _twn_ok=1
  fi
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 98 "$_twn_settings" || return 1
  (
    WAN_TEST_DHCP_DELAY_POLLS=0
    WAN_TEST_DHCP_WAIT_SEC=1
    export WAN_TEST_DHCP_DELAY_POLLS WAN_TEST_DHCP_WAIT_SEC
    _twn_run apply >/dev/null 2>&1
  ) || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 99 "$_twn_settings" || return 1

  # A successful release/restart is not success by itself: without the expected
  # lease, bounded acquisition times out and restores both L2 membership and
  # the captured L3 address through a fresh original-domain lifecycle.
  printf '%s\n' '192.0.2.10/24' > "$_twn_dhcp_addr"
  : > "$_twn_root/no-address"
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 99 "$_twn_settings" || return 1
  (
    WAN_TEST_DHCP_WAIT_SEC=1
    export WAN_TEST_DHCP_WAIT_SEC
    _twn_run apply >/dev/null 2>&1
  )
  _twn_rc=$?
  rm -f "$_twn_root/no-address"
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && ! _twn_member eth0.99 && [ "$(cat "$_twn_dhcp_addr" 2>/dev/null)" = "192.0.2.10/24" ]; then
    pass "WAN Native DHCP restart timeout rolls back L2 and L3"
  else
    fail "WAN Native DHCP restart timeout rolls back L2 and L3"; _twn_ok=1
  fi

  # Lifecycle authentication rejects an unexpected callback before bridge
  # mutation; no process control action may occur for a foreign argv.
  _twn_dhcp_reset /not-asus/rc || return 1
  : > "$_twn_order_log"
  : > "$_twn_root/dhcp.lifecycle"
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && [ ! -s "$_twn_root/dhcp.lifecycle" ] && [ "$(wc -l < "$_twn_order_log")" -eq 0 ]; then
    pass "WAN Native rejects unexpected ASUS udhcpc callback before mutation"
  else
    fail "WAN Native rejects unexpected ASUS udhcpc callback before mutation"; _twn_ok=1
  fi

  # This is the exact live ASUS behavior: RELEASE deconfigures the old lease
  # but leaves the authenticated process alive. It must then be explicitly
  # terminated before exactly one fresh target-domain client is started.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_order_log"
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_RELEASE_STAYS_ALIVE=1; export WAN_TEST_DHCP_RELEASE_STAYS_ALIVE
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_RELEASE_STAYS_ALIVE
  if [ "$_twn_rc" -eq 0 ] && _twn_member eth0.99 && ! _twn_member eth0.98 &&
     [ "$(cat "$_twn_dhcp_addr" 2>/dev/null)" = "192.0.2.20/24" ] &&
     grep -q '^release 4242$' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     grep -q '^terminate 4242$' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     grep -q '^start 4243$' "$_twn_root/dhcp.lifecycle" 2>/dev/null; then
    pass "WAN Native RELEASE-live client terminates before one replacement starts"
  else
    fail "WAN Native RELEASE-live client terminates before one replacement starts"; _twn_ok=1
  fi
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 98 "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1 || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 99 "$_twn_settings" || return 1

  # A released but still-live client that ignores TERM must never compete with
  # a new client. Rollback restores L2 before renewing the exact client.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_RELEASE_STAYS_ALIVE=1 WAN_TEST_DHCP_TERM_STICKS=1 WAN_TEST_DHCP_TERM_WAIT_SEC=0
  export WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_TERM_STICKS WAN_TEST_DHCP_TERM_WAIT_SEC
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_TERM_STICKS WAN_TEST_DHCP_TERM_WAIT_SEC
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && ! _twn_member eth0.99 &&
     [ "$(cat "$_twn_dhcp_addr" 2>/dev/null)" = "192.0.2.10/24" ] &&
     grep -q '^terminate 4242$' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     grep -q '^renew 4242$' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     ! grep -q '^start ' "$_twn_root/dhcp.lifecycle" 2>/dev/null; then
    pass "WAN Native TERM timeout renews released client only after L2 rollback"
  else
    fail "WAN Native TERM timeout renews released client only after L2 rollback"; _twn_ok=1
  fi

  # A PID/start identity change after RELEASE must block TERM and any fresh
  # client. L2 is still restored, but the unknown process is never signalled.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_RELEASE_STAYS_ALIVE=1 WAN_TEST_DHCP_REUSE_AFTER_RELEASE=1
  export WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_REUSE_AFTER_RELEASE
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_REUSE_AFTER_RELEASE
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && ! _twn_member eth0.99 &&
     grep -q '^release 4242$' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     ! grep -q '^terminate ' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     ! grep -q '^start ' "$_twn_root/dhcp.lifecycle" 2>/dev/null; then
    pass "WAN Native never TERM-signals a reused DHCP PID after RELEASE"
  else
    fail "WAN Native never TERM-signals a reused DHCP PID after RELEASE"; _twn_ok=1
  fi

  # A changed argv is likewise an unknown process: do not signal or replace it.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_RELEASE_STAYS_ALIVE=1 WAN_TEST_DHCP_CMDLINE_CHANGE_AFTER_RELEASE=1
  export WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_CMDLINE_CHANGE_AFTER_RELEASE
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_CMDLINE_CHANGE_AFTER_RELEASE
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && ! _twn_member eth0.99 &&
     ! grep -q '^terminate ' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     ! grep -q '^start ' "$_twn_root/dhcp.lifecycle" 2>/dev/null; then
    pass "WAN Native never replaces an altered DHCP client after RELEASE"
  else
    fail "WAN Native never replaces an altered DHCP client after RELEASE"; _twn_ok=1
  fi

  # A second valid client that appears during RELEASE is ambiguous and blocks
  # both TERM and replacement launch.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_RELEASE_STAYS_ALIVE=1 WAN_TEST_DHCP_DUPLICATE_BEFORE_TERM=1
  export WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_DUPLICATE_BEFORE_TERM
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_DUPLICATE_BEFORE_TERM
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && ! _twn_member eth0.99 &&
     ! grep -q '^terminate ' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     ! grep -q '^start ' "$_twn_root/dhcp.lifecycle" 2>/dev/null; then
    pass "WAN Native rejects a second DHCP client before TERM"
  else
    fail "WAN Native rejects a second DHCP client before TERM"; _twn_ok=1
  fi

  # The exiting RELEASE branch must also reject another client before the
  # replacement boundary; the helper may not collapse or overwrite it.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_DUPLICATE_BEFORE_START=1; export WAN_TEST_DHCP_DUPLICATE_BEFORE_START
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_DUPLICATE_BEFORE_START
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && ! _twn_member eth0.99 &&
     ! grep -q '^start ' "$_twn_root/dhcp.lifecycle" 2>/dev/null; then
    pass "WAN Native rejects a DHCP client that appears before replacement"
  else
    fail "WAN Native rejects a DHCP client that appears before replacement"; _twn_ok=1
  fi

  # An interrupt after SIGTERM but before exit follows the same L2-first,
  # exact-client renew recovery path and keeps status 143.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_RELEASE_STAYS_ALIVE=1 WAN_TEST_DHCP_TERM_AFTER_TERMINATE=1
  export WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_TERM_AFTER_TERMINATE
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_TERM_AFTER_TERMINATE
  if [ "$_twn_rc" -eq 143 ] && _twn_member eth0.98 && ! _twn_member eth0.99 &&
     grep -q '^terminate 4242$' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     grep -q '^renew 4242$' "$_twn_root/dhcp.lifecycle" 2>/dev/null &&
     ! grep -q '^start ' "$_twn_root/dhcp.lifecycle" 2>/dev/null; then
    pass "WAN Native TERM after DHCP SIGTERM restores released client safely"
  else
    fail "WAN Native TERM after DHCP SIGTERM restores released client safely"; _twn_ok=1
  fi

  # RELEASE may legitimately exit the client. A pidfile left behind may be
  # cleaned only after the old authenticated process is proved gone.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_STALE_PIDFILE=1; export WAN_TEST_DHCP_STALE_PIDFILE
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_STALE_PIDFILE
  if [ "$_twn_rc" -eq 0 ] && _twn_member eth0.99 &&
     grep -q '^start 4243$' "$_twn_root/dhcp.lifecycle" 2>/dev/null; then
    pass "WAN Native clears only proven stale DHCP pidfile after released exit"
  else
    fail "WAN Native clears only proven stale DHCP pidfile after released exit"; _twn_ok=1
  fi
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 98 "$_twn_settings" || return 1
  _twn_run apply >/dev/null 2>&1 || return 1
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 99 "$_twn_settings" || return 1

  # A fresh release must remove the old lease; leaving it installed fails
  # closed before any replacement client is started.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  WAN_TEST_DHCP_STALE_ADDRESS=1 WAN_TEST_DHCP_RELEASE_WAIT_SEC=0
  export WAN_TEST_DHCP_STALE_ADDRESS WAN_TEST_DHCP_RELEASE_WAIT_SEC
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_STALE_ADDRESS WAN_TEST_DHCP_RELEASE_WAIT_SEC
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && [ "$(cat "$_twn_dhcp_addr" 2>/dev/null)" = "192.0.2.10/24" ] &&
     [ "$(grep -c '^start ' "$_twn_root/dhcp.lifecycle" 2>/dev/null)" -ge 1 ]; then
    pass "WAN Native rejects stale address after DHCP release"
  else
    fail "WAN Native rejects stale address after DHCP release"; _twn_ok=1
  fi

  # A replacement launch failure leaves no target client; rollback uses the
  # captured authenticated argv contract to restore one original-domain client.
  _twn_dhcp_reset /sbin/rc || return 1
  : > "$_twn_root/dhcp.lifecycle"
  (
    MERV_WAN_DHCP_TEST_LAUNCH_FAIL=1
    export MERV_WAN_DHCP_TEST_LAUNCH_FAIL
    _twn_run apply >/dev/null 2>&1
  )
  _twn_rc=$?
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && [ "$(cat "$_twn_dhcp_addr" 2>/dev/null)" = "192.0.2.10/24" ] &&
     [ "$(grep -c '^start ' "$_twn_root/dhcp.lifecycle" 2>/dev/null)" -ge 1 ]; then
    pass "WAN Native replacement launch failure restores original DHCP client"
  else
    fail "WAN Native replacement launch failure restores original DHCP client"; _twn_ok=1
  fi

  # A second authenticated LAN client is never collapsed or signalled by this
  # helper; the ambiguous state fails closed before transport mutation.
  _twn_dhcp_reset /sbin/rc || return 1
  cp -R "$_twn_proc/4242" "$_twn_proc/4243" || return 1
  sed 's/424242/424243/' "$_twn_proc/4243/stat" > "$_twn_proc/4243/stat.tmp" && mv "$_twn_proc/4243/stat.tmp" "$_twn_proc/4243/stat"
  : > "$_twn_order_log"
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98; then
    pass "WAN Native rejects duplicate authenticated LAN DHCP clients"
  else
    fail "WAN Native rejects duplicate authenticated LAN DHCP clients"; _twn_ok=1
  fi
  _twn_dhcp_reset /sbin/rc || return 1

  # A TERM immediately after live-client RELEASE is an interruption point.
  # The transaction trap must restore L2 before renewing that same exact
  # released client, then retain the conventional signal status.
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 99 "$_twn_settings" || return 1
  _twn_dhcp_reset /sbin/rc || return 1
  WAN_TEST_DHCP_RELEASE_STAYS_ALIVE=1 WAN_TEST_DHCP_TERM_AFTER_RELEASE=1
  export WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_TERM_AFTER_RELEASE
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  unset WAN_TEST_DHCP_RELEASE_STAYS_ALIVE WAN_TEST_DHCP_TERM_AFTER_RELEASE
  if [ "$_twn_rc" -eq 143 ] && _twn_member eth0.98 && ! _twn_member eth0.99 &&
     [ "$(cat "$_twn_dhcp_addr" 2>/dev/null)" = "192.0.2.10/24" ]; then
    pass "WAN Native TERM after DHCP release restores original DHCP lifecycle"
  else
    fail "WAN Native TERM after DHCP release restores original DHCP lifecycle"; _twn_ok=1
  fi
  _twn_dhcp_reset /sbin/rc || return 1

  # PID zero and a mismatched start-time sidecar are both rejected before any
  # signal or bridge operation; this covers positive/non-reused PID safety.
  printf '%s\n' 0 > "$_twn_dhcp_pidfile"
  json_set_section2_value VLAN WAN_Native WAN_NATIVE_MAIN 100 "$_twn_settings" || return 1
  : > "$_twn_order_log"
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && [ "$(wc -l < "$_twn_order_log")" -eq 0 ]; then
    pass "WAN Native rejects non-positive udhcpc PID"
  else
    fail "WAN Native rejects non-positive udhcpc PID"; _twn_ok=1
  fi
  printf '%s\n' "$_twn_dhcp_pid" > "$_twn_dhcp_pidfile"
  printf '%s\n' 999999999 > "${_twn_dhcp_pidfile}.start"
  : > "$_twn_order_log"
  _twn_run apply >/dev/null 2>&1; _twn_rc=$?
  rm -f "${_twn_dhcp_pidfile}.start"
  if [ "$_twn_rc" -ne 0 ] && _twn_member eth0.98 && [ "$(wc -l < "$_twn_order_log")" -eq 0 ]; then
    pass "WAN Native rejects reused udhcpc PID identity"
  else
    fail "WAN Native rejects reused udhcpc PID identity"; _twn_ok=1
  fi

  if grep -Fq 'Preserving live WAN Native transport' "$MERV_BASE/functions/mervlan_manager.sh" &&
     [ "$(grep -c 'run_wan_native apply' "$MERV_BASE/functions/mervlan_manager.sh" 2>/dev/null)" -ge 2 ] &&
     grep -Fq 'run_wan_native verify' "$MERV_BASE/functions/mervlan_manager.sh"; then
    pass "manager protects, reapplies, and finally verifies WAN Native"
  else fail "manager protects, reapplies, and finally verifies WAN Native"; _twn_ok=1; fi

  if grep -Fq 'functions/mervlan_wan.sh' "$MERV_BASE/functions/sync_nodes.sh" &&
     grep -Fq 'functions/mervlan_wan.sh' "$MERV_BASE/functions/update_mervlan.sh" &&
     grep -Fq 'functions/mervlan_wan.sh' "$MERV_BASE/functions/update_mervlan_repair.manifest"; then
    pass "WAN Native helper is covered by node sync, update, and repair manifests"
  else fail "WAN Native helper is covered by node sync, update, and repair manifests"; _twn_ok=1; fi

  if grep -Fq 'wan_main_dhcp_restart()' "$MERV_BASE/functions/mervlan_wan.sh" &&
     grep -Fq 'nvram get lan_proto' "$MERV_BASE/functions/mervlan_wan.sh" &&
     grep -Fq 'case "$WAN_DHCP_ASUS_IP_CONFIG" in '"'"''"'"')' "$MERV_BASE/functions/mervlan_wan.sh" &&
     grep -Fq 'kill -USR2' "$MERV_BASE/functions/mervlan_wan.sh"; then
    pass "WAN Native restarts MAIN DHCP only after verified transport swap"
  else fail "WAN Native DHCP restart contract is wired"; _twn_ok=1; fi

  if grep -Fq 'class="no-vlanfield wan-native-value"' "$MERV_BASE/www/index.html" &&
     ! grep -Fq 'wan-native-input' "$MERV_BASE/www/index.html" &&
     grep -Fq 'validateAllWanNativeSettings' "$MERV_BASE/www/index.html" &&
     grep -Fq 'WAN_NATIVE_MAIN' "$MERV_BASE/settings/settings.json" &&
     grep -Fq 'json_set_section2_value "VLAN" "WAN_Native"' "$MERV_BASE/functions/save_settings.sh"; then
    pass "WAN Native UI, schema, and sectioned save path are wired"
  else fail "WAN Native UI, schema, and sectioned save path are wired"; _twn_ok=1; fi

  # Safety-popup contract: the table owns the one visible VLAN field, while the
  # form-anchored dialog owns only DHCP reservation endpoints and stages them
  # through the normal settings transaction.
  if grep -Fq 'wanNativeConfigPopup' "$MERV_BASE/www/index.html" &&
     grep -Fq 'function saveWanNativeConfig' "$MERV_BASE/www/index.html" &&
     grep -Fq "openHelpPopup('wan-native')" "$MERV_BASE/www/index.html" &&
     ! grep -Fq 'WanNativeIpField' "$MERV_BASE/www/index.html" &&
     grep -Fq 'WAN Native VLAN ID' "$MERV_BASE/www/index.html" &&
     grep -Fq 'wan-native-edit-btn' "$MERV_BASE/www/index.html" &&
     grep -Fq '>Edit</button><span id="statusWAN_NATIVE"' "$MERV_BASE/www/index.html" &&
     ! grep -Fq 'wan-native-config-btn' "$MERV_BASE/www/index.html" &&
     grep -Fq 'wanNativePopupVlan' "$MERV_BASE/www/index.html" &&
     ! grep -Fq 'wanNativePopupEdit' "$MERV_BASE/www/index.html" &&
     grep -Fq 'wanNativePopupNodeIp' "$MERV_BASE/www/index.html" &&
     grep -Fq 'wanNativePopupNodeAsusIp' "$MERV_BASE/www/index.html" &&
     grep -Fq 'cachedWanNativeIp' "$MERV_BASE/www/index.html" &&
     grep -Fq 'WAN_NATIVE_POPUP_STATE && target !== CURRENT_LAN_TARGET' "$MERV_BASE/www/index.html" &&
     grep -Fq 'wanNativeOptionalIpIsValid' "$MERV_BASE/www/index.html" &&
     grep -Fq 'The ASUS/default reservation is optional until you switch back to ASUS.' "$MERV_BASE/www/index.html" &&
     ! grep -Fq 'requires both DHCP reservations' "$MERV_BASE/www/index.html" &&
     grep -Fq 'requires a WAN Native DHCP reservation' "$MERV_BASE/www/index.html" &&
     grep -Fq 'nodeAsusRow.style.display = isMain ?' "$MERV_BASE/www/index.html" &&
     grep -Fq 'min-width:var(--wan-native-edit-width, 50px);' "$MERV_BASE/www/vlan_form_style.css" &&
     grep -Fq 'value.textContent = (!raw || raw.toLowerCase() === "none") ? "ASUS" : raw' "$MERV_BASE/www/index.html" &&
     ! grep -Fq 'validateWanNativeField(wanInput' "$MERV_BASE/www/index.html" &&
     grep -Fq 'anchorModalToForm(popup)' "$MERV_BASE/www/index.html" &&
     ! grep -Fq 'top: 16%' "$MERV_BASE/www/vlan_form_style.css" &&
     grep -Fq 'wan-native-popup.modal' "$MERV_BASE/www/vlan_form_style.css"; then
    pass "WAN Native uses a compact form-anchored DHCP reservation editor"
  else
    fail "WAN Native uses a compact form-anchored DHCP reservation editor"
    _twn_ok=1
  fi

  return "$_twn_ok"
}

test_shell_syntax() {
  _tss_bad=0
  if grep -q 'grep -c "\^-s ".*|| :' "$MERV_BASE/functions/mervlan_boot.sh"; then
    pass "MAC Shield status zero-count fallback stays numeric"
  else
    fail "MAC Shield status zero-count fallback stays numeric"
    _tss_bad=1
  fi
  for _tss_file in \
    "$MERV_BASE/settings/lib_mervqt.sh" \
    "$MERV_BASE/settings/lib_owner_lock.sh" \
    "$MERV_BASE/settings/lib_maintenance_recovery.sh" \
    "$MERV_BASE/settings/lib_update_state.sh" \
    "$MERV_BASE/settings/lib_action_lock.sh" \
    "$MERV_BASE/settings/lib_node_jobs.sh" \
    "$MERV_BASE/settings/var_settings.sh" \
    "$SELFTEST_SCRIPT" \
    "$LIVE_TEST_GUARD_SCRIPT" \
    "$MERV_BASE/functions/post_apply_worker.sh" \
    "$MERV_BASE/functions/mac_refresh.sh" \
    "$MERV_BASE/functions/service-event-handler.sh" \
    "$MERV_BASE/functions/mervlan_manager.sh" \
    "$MERV_BASE/functions/mervlan_wan.sh" \
    "$MERV_BASE/functions/heal_event.sh" \
    "$MERV_BASE/functions/mervlan_backup.sh" \
    "$MERV_BASE/functions/mervlan_recover.sh" \
    "$MERV_BASE/functions/update_mervlan.sh" \
    "$MERV_BASE/functions/mervlan_boot.sh" \
    "$MERV_BASE/functions/mervlan_boot_wrap.sh" \
    "$MERV_BASE/settings/mac_shield_snapshot.sh" \
    "$MERV_BASE/templates/mervlan_templates.sh"; do
    [ -f "$_tss_file" ] || { fail "shell syntax target missing: ${_tss_file##*/}"; _tss_bad=1; continue; }
    if sh -n "$_tss_file"; then pass "shell syntax ${_tss_file##*/}"; else fail "shell syntax ${_tss_file##*/}"; _tss_bad=1; fi
  done
  if [ -f "$MERV_BASE/functions/sync_nodes.sh" ]; then
    if sh -n "$MERV_BASE/functions/sync_nodes.sh"; then
      pass "shell syntax sync_nodes.sh"
    else
      fail "shell syntax sync_nodes.sh"
      _tss_bad=1
    fi
  else
    pass "shell syntax sync_nodes.sh skipped on node-only installation"
  fi
  for _tss_optional in collect_clients.sh collect_local_clients.sh mac_client_meta.sh mac_refresh.sh execute_nodes.sh update_mervlan.sh mervlan_backup.sh hw_probe.sh ssh_trust_action.sh dropbear_sshkey_gen.sh; do
    if [ -f "$MERV_BASE/functions/$_tss_optional" ]; then
      if sh -n "$MERV_BASE/functions/$_tss_optional"; then
        pass "shell syntax $_tss_optional"
      else
        fail "shell syntax $_tss_optional"
        _tss_bad=1
      fi
    else
      pass "shell syntax $_tss_optional skipped on node-only installation"
    fi
  done
  return "$_tss_bad"
}

test_signal_termination() {
  _tst_root="$SELFTEST_ROOT/signal-termination"
  _tst_fixture="$_tst_root/fixture.sh"
  _tst_ok=1
  rm -rf "$_tst_root" 2>/dev/null || return 1
  mkdir -p "$_tst_root" || return 1
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '. "$MERV_BASE/settings/lib_mervqt.sh" 2>/dev/null || exit 2'
    printf '%s\n' 'root="${SIGNAL_TEST_ROOT:?}"; lock="$root/owner.lock"; result="$root/result"; cleanup_count="$root/cleanup.count"; child_pid=""; child_start=""; signal_handling=0'
    printf '%s\n' 'cleanup() {'
    printf '%s\n' '  rc=$?; count=$(cat "$cleanup_count" 2>/dev/null || printf 0); count=$((count + 1)); printf "%s\\n" "$count" > "$cleanup_count"'
    printf '%s\n' '  if [ -n "$child_pid" ] && [ -n "$child_start" ] && merv_process_identity_matches "$child_pid" "$child_start" 2>/dev/null; then kill -TERM "$child_pid" 2>/dev/null || :; fi'
    printf '%s\n' '  [ -n "$child_pid" ] && wait "$child_pid" 2>/dev/null || :'
    printf '%s\n' '  if [ "${SIGNAL_TEST_FAIL_CLEANUP:-0}" = 1 ]; then printf "%s\\n" cleanup-failed > "$root/cleanup.failed"; else rm -f "$lock" 2>/dev/null || printf "%s\\n" cleanup-failed > "$root/cleanup.failed"; fi'
    printf '%s\n' '  if [ ! -f "$result" ]; then printf "%s\\n" interrupted > "$result"; else printf "%s\\n" duplicate > "$root/result.duplicate"; fi'
    printf '%s\n' '  return "$rc"'
    printf '%s\n' '}'
    printf '%s\n' 'handle_signal() { status="$1"; [ "$signal_handling" -eq 0 ] || exit "$status"; signal_handling=1; trap - INT TERM; printf "%s\\n" "$status" > "$root/signal.status"; exit "$status"; }'
    printf '%s\n' 'trap - INT TERM; trap cleanup EXIT; trap "handle_signal 130" INT; trap "handle_signal 143" TERM'
    printf '%s\n' ': > "$lock"; printf "%s\\n" "$$" > "$root/fixture.pid"; ( trap - EXIT INT TERM; exec sleep 3 ) & child_pid="$!"; child_start=$(merv_proc_start_time "$child_pid" 2>/dev/null || printf ""); printf "%s\\n" "$child_pid" > "$root/child.pid"; printf "%s\\n" "$child_start" > "$root/child.start"; sleep 3; printf "%s\\n" success > "$result"; exit 0'
  } > "$_tst_fixture" || return 1
  chmod 700 "$_tst_fixture" || return 1

  for _tst_signal_case in TERM:143 INT:130; do
    _tst_signal=${_tst_signal_case%%:*}
    _tst_expected=${_tst_signal_case#*:}
    _tst_case="$_tst_root/$_tst_signal"
    mkdir -p "$_tst_case" || { _tst_ok=0; continue; }
    # Run the fixture in the foreground.  A non-interactive BusyBox shell
    # launched as a background job inherits an ignored INT disposition and
    # cannot test a real INT trap.  Its helper writes the exact fixture PID;
    # this sibling then delivers the requested signal after that publication.
    (
      _tst_wait=0
      while [ "$_tst_wait" -lt 5 ]; do
        if [ -s "$_tst_case/fixture.pid" ]; then
          _tst_fixture_pid=$(cat "$_tst_case/fixture.pid" 2>/dev/null)
          case "$_tst_fixture_pid" in
            ''|*[!0-9]*) ;;
            *) kill -"$_tst_signal" "$_tst_fixture_pid" 2>/dev/null || :; exit 0 ;;
          esac
        fi
        sleep 1
        _tst_wait=$((_tst_wait + 1))
      done
      exit 1
    ) &
    _tst_killer=$!
    SIGNAL_TEST_ROOT="$_tst_case" MERV_BASE="$MERV_BASE" sh "$_tst_fixture" >/dev/null 2>&1
    _tst_rc=$?
    wait "$_tst_killer" 2>/dev/null || {
      fail "signal termination $_tst_signal helper did not deliver"
      _tst_ok=0
    }
    if [ "$_tst_rc" -eq "$_tst_expected" ]; then pass "signal termination $_tst_signal returns $_tst_expected"; else fail "signal termination $_tst_signal returns $_tst_expected (actual=$_tst_rc)"; _tst_ok=0; fi
    [ "$(cat "$_tst_case/cleanup.count" 2>/dev/null)" = 1 ] && pass "signal termination $_tst_signal cleanup runs once" || { fail "signal termination $_tst_signal cleanup runs once"; _tst_ok=0; }
    [ "$(cat "$_tst_case/result" 2>/dev/null)" = interrupted ] && pass "signal termination $_tst_signal publishes one interruption result" || { fail "signal termination $_tst_signal publishes one interruption result"; _tst_ok=0; }
    [ ! -e "$_tst_case/result.duplicate" ] && [ "$(cat "$_tst_case/result" 2>/dev/null)" != success ] && pass "signal termination $_tst_signal prevents later success" || { fail "signal termination $_tst_signal prevents later success"; _tst_ok=0; }
    [ ! -e "$_tst_case/owner.lock" ] && pass "signal termination $_tst_signal removes owner lock" || { fail "signal termination $_tst_signal removes owner lock"; _tst_ok=0; }
    _tst_child=$(cat "$_tst_case/child.pid" 2>/dev/null)
    [ -n "$_tst_child" ] && ! kill -0 "$_tst_child" 2>/dev/null && pass "signal termination $_tst_signal reconciles tracked child" || { fail "signal termination $_tst_signal reconciles tracked child"; _tst_ok=0; }
  done

  sleep 3 &
  _tst_reuse_pid=$!
  _tst_reuse_start=$(merv_proc_start_time "$_tst_reuse_pid" 2>/dev/null || printf '')
  case "$_tst_reuse_start" in
    ''|*[!0-9]*|0)
      fail "signal termination PID reuse fixture has no positive start time"
      _tst_ok=0
      ;;
    *)
      _tst_wrong_start=$((_tst_reuse_start + 1))
      if ! merv_process_identity_matches "$_tst_reuse_pid" "$_tst_wrong_start" 2>/dev/null && kill -0 "$_tst_reuse_pid" 2>/dev/null; then
        pass "signal termination rejects PID reuse with mismatched start time"
      else
        fail "signal termination rejects PID reuse with mismatched start time"
        _tst_ok=0
      fi
      ;;
  esac
  if merv_process_identity_matches "$_tst_reuse_pid" "$_tst_reuse_start" 2>/dev/null; then
    kill "$_tst_reuse_pid" 2>/dev/null || :
  else
    fail "signal termination rejects PID reuse with mismatched start time"
    _tst_ok=0
  fi
  wait "$_tst_reuse_pid" 2>/dev/null || :

  mkdir -p "$_tst_root/cleanup-failure"
  SIGNAL_TEST_ROOT="$_tst_root/cleanup-failure" SIGNAL_TEST_FAIL_CLEANUP=1 MERV_BASE="$MERV_BASE" sh "$_tst_fixture" >/dev/null 2>&1 &
  _tst_pid=$!
  _tst_parent_start=$(merv_proc_start_time "$_tst_pid" 2>/dev/null || printf '')
  sleep 1
  if merv_process_identity_matches "$_tst_pid" "$_tst_parent_start" 2>/dev/null; then
    kill -TERM "$_tst_pid" 2>/dev/null || :
  else
    fail "signal termination cleanup-failure parent identity changed before signal"
    _tst_ok=0
  fi
  wait "$_tst_pid" 2>/dev/null || :
  [ -f "$_tst_root/cleanup-failure/cleanup.failed" ] && pass "signal termination exposes cleanup failure" || { fail "signal termination exposes cleanup failure"; _tst_ok=0; }
  return "$_tst_ok"
}

test_live_audit() {
  _tla_backend="$MERV_DHCP_HOLD_EBTABLES"
  _tla_mode="$MERV_DHCP_HOLD_TEST_MODE"
  _tla_marker="$MERV_DHCP_HOLD_LEGACY_MARKER"
  _tla_state_root="$MERV_DHCP_HOLD_STATE_ROOT"
  MERV_DHCP_HOLD_EBTABLES=""
  MERV_DHCP_HOLD_TEST_MODE=0
  MERV_DHCP_HOLD_LEGACY_MARKER="${LOCKDIR:-/tmp/mervlan_tmp/locks}/merv_dhcp_hold.active"
  MERV_DHCP_HOLD_STATE_ROOT="${LOCKDIR:-/tmp/mervlan_tmp/locks}/dhcp_hold"
  export MERV_DHCP_HOLD_EBTABLES MERV_DHCP_HOLD_TEST_MODE MERV_DHCP_HOLD_LEGACY_MARKER MERV_DHCP_HOLD_STATE_ROOT
  if type ebtables >/dev/null 2>&1; then
    merv_dhcp_hold_status
    _tla_rc=$?
    [ "$_tla_rc" -eq 0 ] && pass "live audit desired and observed state agree" ||
      fail "live audit found mismatch (rc=$_tla_rc)"
  else
    pass "live audit skipped: ebtables unavailable on this host"
  fi
  MERV_DHCP_HOLD_EBTABLES="$_tla_backend"
  MERV_DHCP_HOLD_TEST_MODE="$_tla_mode"
  MERV_DHCP_HOLD_LEGACY_MARKER="$_tla_marker"
  MERV_DHCP_HOLD_STATE_ROOT="$_tla_state_root"
  export MERV_DHCP_HOLD_EBTABLES MERV_DHCP_HOLD_TEST_MODE MERV_DHCP_HOLD_LEGACY_MARKER MERV_DHCP_HOLD_STATE_ROOT
}

run_one() {
  case "$1" in
    dhcp-api) test_dhcp_api ;;
    dhcp-ebtables-failures) test_dhcp_ebtables_failures ;;
    dhcp-rule-exactness) test_dhcp_rule_exactness ;;
    dhcp-continuous-repair) test_dhcp_continuous_repair ;;
    l2-guard-coordinator) test_l2_guard_coordinator_contract ;;
    l2-guard-dump) test_l2_guard_dump_contract ;;
    l2-guard-exactness) test_l2_guard_exactness_contract ;;
    mac-shield-lifecycle) test_mac_shield_lifecycle ;;
    process-identity) test_process_identity ;;
    owner-lock-contract) test_owner_lock_contract ;;
    maintenance-lock-interop) test_maintenance_lock_interop ;;
    lock-publication) test_lock_publication ;;
    nonce-uniqueness) test_nonce_uniqueness ;;
    lock-reclaim) test_lock_reclaim ;;
    dhcp-incomplete-lock) test_dhcp_incomplete_lock ;;
    router-portability) test_router_portability ;;
    dhcp-owners) test_dhcp_owners ;;
    dhcp-phases) test_dhcp_phases ;;
    dhcp-crash-points) test_dhcp_crash_points ;;
    heal-handoff) test_heal_handoff ;;
    boot-handoff) test_boot_handoff ;;
    duplicate-events) test_duplicate_events ;;
    settle-watchdog) test_settle_watchdog ;;
    recovery) test_recovery ;;
    failsafe-status) test_failsafe_status ;;
    post-apply) test_post_apply ;;
    observation-lock) test_observation_lock ;;
    observation-timeouts) test_observation_timeouts ;;
    observation-concurrency) test_observation_concurrency ;;
    observation-resume-progress) test_observation_resume_progress ;;
    observation-generations) test_observation_generations ;;
    atomic-publication) test_atomic_publication ;;
    json-validation) test_json_validation ;;
    client-refresh-contract) test_client_refresh_contract ;;
    manager-ownership) test_manager_ownership ;;
    node-job-logging) test_node_job_logging ;;
    node-job-ssh-temp) test_node_job_ssh_temp ;;
    node-runner-status) test_node_runner_status ;;
    node-worker-pool) test_node_worker_pool ;;
    node-worker-timeout) test_node_worker_timeout ;;
    execute-node-runner) test_execute_node_runner_contract ;;
    sync-node-pool) test_sync_node_pool ;;
    sync-node-parallel) test_sync_node_parallel_contract ;;
    apmo-completion) test_apmo_completion_contract ;;
    action-lifecycle) test_action_lifecycle_contract ;;
    action-parent-ownership) test_action_parent_ownership ;;
    action-lock-failure) test_action_lock_failure ;;
    direct-manager-save-overlap) test_direct_manager_save_overlap ;;
    update-lock-ownership) test_update_lock_ownership ;;
    update-exclusivity) test_update_exclusivity ;;
    update-download-retry) test_update_download_retry ;;
    payload-contract) test_payload_contract ;;
    failure-propagation) test_failure_propagation_contract ;;
    ssh-outbound) test_ssh_outbound_contract ;;
    ssh-trust) test_ssh_trust_contract ;;
    logging-polling) test_logging_polling_contract ;;
    apply-observation) test_apply_observation_contract ;;
    wan-native-contract) test_wan_native_contract ;;
    shell-syntax) test_shell_syntax ;;
    signal-termination) test_signal_termination ;;
    live-audit) test_live_audit ;;
    *)
      printf 'Unknown selftest: %s\n' "$1" >&2
      return 2
      ;;
  esac
}

if [ "$SELFTEST_ACTION" = "_fault-child" ]; then
  printf '%s\n' "$$" > "$SELFTEST_ROOT/fault-child.pid"
  case "${2:-}" in
    acquire)
      merv_dhcp_hold_acquire manager fault-child-acquire
      ;;
    mutate)
      merv_dhcp_hold_acquire manager fault-child-mutate || exit $?
      _fc_token="$MERV_DHCP_HOLD_TOKEN"
      merv_dhcp_hold_mark_mutating "$_fc_token" bridge-cleanup
      ;;
    verify)
      merv_dhcp_hold_acquire manager fault-child-verify || exit $?
      _fc_token="$MERV_DHCP_HOLD_TOKEN"
      merv_dhcp_hold_mark_mutating "$_fc_token" bridge-cleanup || exit $?
      merv_dhcp_hold_mark_verified "$_fc_token" fault-verification
      ;;
    release)
      merv_dhcp_hold_acquire manager fault-child-release || exit $?
      _fc_token="$MERV_DHCP_HOLD_TOKEN"
      merv_dhcp_hold_mark_mutating "$_fc_token" bridge-cleanup || exit $?
      merv_dhcp_hold_mark_verified "$_fc_token" fault-verification || exit $?
      merv_dhcp_hold_release "$_fc_token"
      ;;
    *) exit 2 ;;
  esac
  exit $?
fi

if [ "$SELFTEST_ACTION" = all ]; then
  for SELFTEST_CASE in dhcp-api dhcp-ebtables-failures dhcp-rule-exactness dhcp-continuous-repair l2-guard-coordinator l2-guard-dump l2-guard-exactness mac-shield-lifecycle \
    process-identity nonce-uniqueness owner-lock-contract maintenance-lock-interop lock-publication lock-reclaim dhcp-incomplete-lock router-portability dhcp-owners dhcp-phases dhcp-crash-points \
    heal-handoff boot-handoff duplicate-events manager-ownership \
    settle-watchdog recovery failsafe-status post-apply observation-lock observation-concurrency \
    observation-timeouts observation-generations observation-resume-progress atomic-publication json-validation client-refresh-contract \
    node-job-logging node-job-ssh-temp node-runner-status node-worker-pool node-worker-timeout \
    execute-node-runner sync-node-pool sync-node-parallel apmo-completion action-lifecycle action-parent-ownership action-lock-failure direct-manager-save-overlap update-lock-ownership update-exclusivity update-download-retry payload-contract failure-propagation ssh-outbound ssh-trust logging-polling apply-observation wan-native-contract shell-syntax signal-termination live-audit; do
    printf '\n# %s\n' "$SELFTEST_CASE"
    run_one "$SELFTEST_CASE"
  done
else
  run_one "$SELFTEST_ACTION"
fi

printf '\nselftest: passes=%s failures=%s root=%s\n' \
  "$SELFTEST_PASSES" "$SELFTEST_FAILURES" "$SELFTEST_ROOT"
[ "$SELFTEST_FAILURES" -eq 0 ]
