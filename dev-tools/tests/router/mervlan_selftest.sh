#!/bin/sh
#
# ============================================================================ #
#            - File: mervlan_selftest.sh || version="0.72.4"                #
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
# command failure through FAKE_EBTABLES_FAIL_MATCH.
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

selftest_reset() {
  case "$SELFTEST_FAKE_STATE" in "$SELFTEST_ROOT"/*) ;; *) return 1 ;; esac
  rm -rf "$SELFTEST_FAKE_STATE" "$SELFTEST_STATE" 2>/dev/null || return 1
  mkdir -p "$SELFTEST_FAKE_STATE/chains" "$SELFTEST_STATE/faults" || return 1
  : > "$SELFTEST_FAKE_STATE/chains/FORWARD"
  : > "$SELFTEST_FAKE_STATE/chains/INPUT"
  rm -f "$MERV_DHCP_HOLD_LEGACY_MARKER"
  unset FAKE_EBTABLES_FAIL_MATCH MERV_DHCP_HOLD_FAULT_POINT MERV_DHCP_HOLD_FAULT_ACTION
  export FAKE_EBTABLES_FAIL_MATCH MERV_DHCP_HOLD_FAULT_POINT MERV_DHCP_HOLD_FAULT_ACTION
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

  grep -q '"HTML_CLIENT_REFRESH_MINUTES": "30"' "$_tcr_settings" &&
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

  grep -q "PRODUCTID_NODE' + i" "$_tcr_html" &&
    grep -q "formatName(alias" "$_tcr_html" &&
    grep -q "formatName('Main Router'" "$_tcr_html" &&
    pass "client display uses alias ProductID and IP" ||
    fail "client display uses alias ProductID and IP"

  grep -q 'info -c cli,vlan "Refreshing client list started"' "$_tcr_collect" &&
    grep -q 'info -c cli,vlan "Refreshing client list complete"' "$_tcr_collect" &&
    pass "successful client refresh keeps CLI routine logging concise" ||
    fail "successful client refresh keeps CLI routine logging concise"
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
  while ! mkdir "$NODE_JOB_TEST_ROOT/count.lock" 2>/dev/null; do sleep 1; done
  _tnjh_count=$(find "$NODE_JOB_TEST_ROOT/active" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  _tnjh_max=$(cat "$NODE_JOB_TEST_ROOT/max" 2>/dev/null || printf '0')
  [ "$_tnjh_count" -gt "$_tnjh_max" ] 2>/dev/null && printf '%s\n' "$_tnjh_count" > "$NODE_JOB_TEST_ROOT/max"
  rmdir "$NODE_JOB_TEST_ROOT/count.lock" 2>/dev/null || :
  case "${NODE_JOB_TEST_SCENARIO:-pool}:$_tnjh_node" in
    pool:2) sleep 3 ;;
    pool:3) sleep 1; rmdir "$NODE_JOB_TEST_ROOT/active/$_tnjh_node"; return 7 ;;
    timeout:1) sleep 10 ;;
    *) sleep 1 ;;
  esac
  rmdir "$NODE_JOB_TEST_ROOT/active/$_tnjh_node"
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

test_failure_propagation_contract() {
  _tfpc_ui="$MERV_BASE/www/index.html"
  _tfpc_handler="$MERV_BASE/functions/service-event-handler.sh"
  _tfpc_refresh="$MERV_BASE/functions/mac_refresh.sh"
  _tfpc_meta="$MERV_BASE/functions/mac_client_meta.sh"
  _tfpc_ok=1

  if grep -q 'isCancelled: () => loadingTask && !loadingTask.isRunning()' "$_tfpc_ui" &&
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
     grep -q 'Client metadata applied with warnings' "$_tfpc_meta" &&
     ! grep -q '_name_pairs\|name entries:' "$_tfpc_meta"; then
    pass "MAC refresh and metadata actions publish terminal failure states"
  else
    fail "MAC refresh and metadata actions publish terminal failure states"
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
     grep -Fq 'Auto-abort in' "$_tst_ui" &&
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
     grep -Fq 'MERV_ACTION_LOCK_PARENT_HELD=0' "$_tst_handler" &&
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
     grep -Fq 'reconcile_legacy_boot_file_locks' "$_tst_boot" &&
     grep -Fq 'merv_lock_quarantine_legacy_file' "$_tst_lib"; then
    pass "node SSH activation uses shell-safe invocation, diagnostics, and legacy-lock migration"
  else
    fail "node SSH activation uses shell-safe invocation, diagnostics, and legacy-lock migration"
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

  return "$_tao_ok"
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
    "$MERV_BASE/settings/lib_node_jobs.sh" \
    "$MERV_BASE/settings/var_settings.sh" \
    "$SELFTEST_SCRIPT" \
    "$LIVE_TEST_GUARD_SCRIPT" \
    "$MERV_BASE/functions/post_apply_worker.sh" \
    "$MERV_BASE/functions/mac_refresh.sh" \
    "$MERV_BASE/functions/service-event-handler.sh" \
    "$MERV_BASE/functions/mervlan_manager.sh" \
    "$MERV_BASE/functions/heal_event.sh" \
    "$MERV_BASE/functions/mervlan_boot.sh" \
    "$MERV_BASE/functions/mervlan_boot_wrap.sh" \
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
  for _tss_optional in collect_clients.sh collect_local_clients.sh mac_client_meta.sh mac_refresh.sh execute_nodes.sh update_mervlan.sh hw_probe.sh ssh_trust_action.sh; do
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
    l2-guard-dump) test_l2_guard_dump_contract ;;
    mac-shield-lifecycle) test_mac_shield_lifecycle ;;
    process-identity) test_process_identity ;;
    lock-reclaim) test_lock_reclaim ;;
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
    failure-propagation) test_failure_propagation_contract ;;
    ssh-outbound) test_ssh_outbound_contract ;;
    ssh-trust) test_ssh_trust_contract ;;
    logging-polling) test_logging_polling_contract ;;
    apply-observation) test_apply_observation_contract ;;
    shell-syntax) test_shell_syntax ;;
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
  for SELFTEST_CASE in dhcp-api dhcp-ebtables-failures dhcp-rule-exactness l2-guard-dump mac-shield-lifecycle \
    process-identity lock-reclaim dhcp-owners dhcp-phases dhcp-crash-points \
    heal-handoff boot-handoff duplicate-events manager-ownership \
    settle-watchdog recovery failsafe-status post-apply observation-concurrency \
    observation-timeouts observation-generations observation-resume-progress atomic-publication json-validation client-refresh-contract \
    node-job-logging node-job-ssh-temp node-runner-status node-worker-pool node-worker-timeout \
    execute-node-runner sync-node-pool sync-node-parallel apmo-completion action-lifecycle failure-propagation ssh-outbound ssh-trust logging-polling apply-observation shell-syntax live-audit; do
    printf '\n# %s\n' "$SELFTEST_CASE"
    run_one "$SELFTEST_CASE"
  done
else
  run_one "$SELFTEST_ACTION"
fi

printf '\nselftest: passes=%s failures=%s root=%s\n' \
  "$SELFTEST_PASSES" "$SELFTEST_FAILURES" "$SELFTEST_ROOT"
[ "$SELFTEST_FAILURES" -eq 0 ]
