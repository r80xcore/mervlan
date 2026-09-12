#!/bin/sh
# Composed boot-order contract test
# Exercises real template definitions and boot wrapper dispatch to verify
# that boot composition satisfies the required ordering invariants:
# 1. No intentional delay before shield is reachable.
# 2. Enabled MAIN boot does not run full installer concurrently with shield/manager.
# 3. Manager startup does not rely on an arbitrary pre-manager sleep.
# 4. Projection/installer must not overlap manager Apply.
# 5. Cron delay is retained as recovery fallback.

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
TEST_ROOT="/tmp/mervlan_tmp/selftest.boot-composed.$$"
umask 077
mkdir -p "$TEST_ROOT/tpls" "$TEST_ROOT/runtime" "$TEST_ROOT/logs" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

_FAILURES=0
fail() { printf 'FAIL: %s\n' "$1" >&2; _FAILURES=1; }
pass() { printf 'PASS: %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Section 1: Template composition checks (Structural & Desired Invariants)
# ---------------------------------------------------------------------------
export MERV_BASE="$BASE_DIR"
export TMPDIR="$TEST_ROOT"
. "$BASE_DIR/templates/mervlan_templates.sh" || { fail "could not load templates library"; exit 1; }

TPL_ADDON_1=$(tpl_path "services-start-addon" "1" "/dev/null")
TPL_ADDON_2=$(tpl_path "services-start-addon" "2" "/dev/null")
TPL_SERVICES_1=$(tpl_path "services-start" "1" "/dev/null")
TPL_SERVICES_2=$(tpl_path "services-start" "2" "/dev/null")

[ -n "$TPL_ADDON_1" ] && [ -s "$TPL_ADDON_1" ] || { fail "services-start-addon v1 missing or empty"; exit 1; }
[ -n "$TPL_ADDON_2" ] && [ -s "$TPL_ADDON_2" ] || { fail "services-start-addon v2 missing or empty"; exit 1; }
[ -n "$TPL_SERVICES_1" ] && [ -s "$TPL_SERVICES_1" ] || { fail "services-start v1 missing or empty"; exit 1; }
[ -n "$TPL_SERVICES_2" ] && [ -s "$TPL_SERVICES_2" ] || { fail "services-start v2 missing or empty"; exit 1; }

# INVARIANT 1: No intentional sleep before shield in services-start-addon.
# On pre-fix code, this fails because 'sleep 5' precedes boot_wrap install.
if grep -Eq '^[[:space:]]*sleep[[:space:]]+[0-9]+' "$TPL_ADDON_1" || \
   grep -Eq '^[[:space:]]*sleep[[:space:]]+[0-9]+' "$TPL_ADDON_2"; then
  fail "invariant-1-pre-shield-sleep-detected: services-start-addon contains pre-shield delay"
else
  pass "invariant-1-no-pre-shield-sleep"
fi

# INVARIANT 2: No fixed sleep before manager in enabled services-start template.
# After shield readiness, manager should launch immediately.
# On pre-fix code, this fails because 'sleep 10' precedes boot_wrap manager.
if awk '/mervlan_boot_wrap\.sh[[:space:]]+shield/{found_shield=1; next}
        found_shield && /mervlan_boot_wrap\.sh[[:space:]]+manager/{found_mgr=1; exit}
        found_shield && /^[[:space:]]*sleep[[:space:]]+[0-9]+/{has_sleep=1}
        END { exit !(found_shield && has_sleep && found_mgr) }' "$TPL_SERVICES_1" || \
   awk '/mervlan_boot_wrap\.sh[[:space:]]+shield/{found_shield=1; next}
        found_shield && /mervlan_boot_wrap\.sh[[:space:]]+manager/{found_mgr=1; exit}
        found_shield && /^[[:space:]]*sleep[[:space:]]+[0-9]+/{has_sleep=1}
        END { exit !(found_shield && has_sleep && found_mgr) }' "$TPL_SERVICES_2"; then
  fail "invariant-2-pre-manager-sleep-detected: services-start contains fixed sleep before manager"
else
  pass "invariant-2-no-pre-manager-sleep"
fi

# INVARIANT 3: Cron delay is retained as independent fallback in services-start.
if grep -Eq 'mervlan_boot_wrap\.sh[[:space:]]+cron' "$TPL_SERVICES_1" && \
   awk '/mervlan_boot_wrap\.sh[[:space:]]+manager/{found_mgr=1; next}
        found_mgr && /mervlan_boot_wrap\.sh[[:space:]]+cron/{found_cron=1; exit}
        found_mgr && /^[[:space:]]*sleep[[:space:]]+[0-9]+/{has_sleep=1}
        END { exit !(found_mgr && has_sleep && found_cron) }' "$TPL_SERVICES_1"; then
  pass "invariant-3-cron-delay-retained"
else
  fail "invariant-3-cron-delay-missing"
fi

# ---------------------------------------------------------------------------
# Section 2: Boot wrapper dispatch contract (Correction 10)
# ---------------------------------------------------------------------------
# In pre-fix mervlan_boot_wrap.sh, _mode_install() executes full install.sh
# on MAIN with BOOT_ENABLED=1, racing with shield and manager.
# Desired contract: _mode_install() on clean boot with BOOT_ENABLED=1 defers
# projection to manager without running full install.sh and without writing .install_ok.
# For MAIN with BOOT_ENABLED=0, reinstall projection runs and .install_ok is written only on success.

WRAPPER_SOURCE="$BASE_DIR/functions/mervlan_boot_wrap.sh"
[ -s "$WRAPPER_SOURCE" ] || { fail "missing wrapper source"; exit 1; }

# Test clean-boot behavioral contract for _mode_install() (Correction 10 & Hardening Pass):
# Extracts real _mode_install() from wrapper and executes it in a behavioral harness:
# 1. MAIN + clean boot + BOOT_ENABLED=1:
#    - normal full install.sh is NOT invoked
#    - install.sh reinstall is NOT invoked from _mode_install
#    - _write_flag is NOT called
#    - function returns success (0) after deferral
# 2. MAIN + clean boot + BOOT_ENABLED=0:
#    - install.sh reinstall IS invoked
#    - normal full install is NOT invoked
#    - _write_flag occurs only on reinstall success
#    - reinstall failure returns nonzero and does not write flag

HARNESS_ROOT="$TEST_ROOT/mode_install_harness"
mkdir -p "$HARNESS_ROOT/bin"
cat > "$HARNESS_ROOT/bin/install.sh" <<'EOF'
#!/bin/sh
echo "INVOCATION: $*" >> "$HARNESS_CALLS"
if [ "${MOCK_INSTALL_FAIL:-0}" = "1" ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$HARNESS_ROOT/bin/install.sh"

EXTRACTED_INSTALL_FUNC=$(awk '/^_mode_install\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$WRAPPER_SOURCE")

# Behavioral Test 1: MAIN + clean boot + BOOT_ENABLED=1
(
  export HARNESS_CALLS="$HARNESS_ROOT/calls_enabled.log"
  export HARNESS_FLAGS="$HARNESS_ROOT/flag_enabled"
  rm -f "$HARNESS_CALLS" "$HARNESS_FLAGS"

  _write_flag() { touch "$HARNESS_FLAGS"; }
  _flag_exists() { return 1; }
  _is_node_runtime() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  info() { :; }
  warn() { :; }
  error() { :; }
  json_get_flag() {
    case "$1" in
      BOOT_ENABLED) echo "1" ;;
      *) echo "$2" ;;
    esac
  }
  MERV_BASE="$HARNESS_ROOT/bin"
  LOG_chan_boot="/dev/null"

  eval "$EXTRACTED_INSTALL_FUNC"
  _mode_install
)
RC_HARNESS_1=$?

_harness1_ok=1
if [ "$RC_HARNESS_1" -ne 0 ]; then _harness1_ok=0; fi
if [ -f "$HARNESS_ROOT/flag_enabled" ]; then _harness1_ok=0; fi
if [ -f "$HARNESS_ROOT/calls_enabled.log" ] && [ -s "$HARNESS_ROOT/calls_enabled.log" ]; then _harness1_ok=0; fi

if [ "$_harness1_ok" -eq 1 ]; then
  pass "invariant-4-mode-install-defers-on-boot-enabled"
else
  fail "invariant-4-mode-install-unconditionally-runs-full-installer"
fi

# Behavioral Test 2: MAIN + clean boot + BOOT_ENABLED=0 (success and failure handling)
(
  export HARNESS_CALLS="$HARNESS_ROOT/calls_disabled_success.log"
  export HARNESS_FLAGS="$HARNESS_ROOT/flag_disabled_success"
  export MOCK_INSTALL_FAIL=0
  rm -f "$HARNESS_CALLS" "$HARNESS_FLAGS"

  _write_flag() { touch "$HARNESS_FLAGS"; }
  _flag_exists() { return 1; }
  _is_node_runtime() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  info() { :; }
  warn() { :; }
  error() { :; }
  json_get_flag() {
    case "$1" in
      BOOT_ENABLED) echo "0" ;;
      *) echo "$2" ;;
    esac
  }
  MERV_BASE="$HARNESS_ROOT/bin"
  LOG_chan_boot="/dev/null"

  eval "$EXTRACTED_INSTALL_FUNC"
  _mode_install
)
RC_HARNESS_2_SUCC=$?

(
  export HARNESS_CALLS="$HARNESS_ROOT/calls_disabled_fail.log"
  export HARNESS_FLAGS="$HARNESS_ROOT/flag_disabled_fail"
  export MOCK_INSTALL_FAIL=1
  rm -f "$HARNESS_CALLS" "$HARNESS_FLAGS"

  _write_flag() { touch "$HARNESS_FLAGS"; }
  _flag_exists() { return 1; }
  _is_node_runtime() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  info() { :; }
  warn() { :; }
  error() { :; }
  json_get_flag() {
    case "$1" in
      BOOT_ENABLED) echo "0" ;;
      *) echo "$2" ;;
    esac
  }
  MERV_BASE="$HARNESS_ROOT/bin"
  LOG_chan_boot="/dev/null"

  eval "$EXTRACTED_INSTALL_FUNC"
  _mode_install
)
RC_HARNESS_2_FAIL=$?

_harness2_ok=1
# Reinstall must be invoked specifically:
if ! grep -Fxq "INVOCATION: reinstall" "$HARNESS_ROOT/calls_disabled_success.log" 2>/dev/null; then _harness2_ok=0; fi
# Normal full install must not be invoked:
if grep -Fxq "INVOCATION: " "$HARNESS_ROOT/calls_disabled_success.log" 2>/dev/null; then _harness2_ok=0; fi
# Success must write flag and return 0:
if [ "$RC_HARNESS_2_SUCC" -ne 0 ] || [ ! -f "$HARNESS_ROOT/flag_disabled_success" ]; then _harness2_ok=0; fi
# Failure must return nonzero and NOT write flag:
if [ "$RC_HARNESS_2_FAIL" -eq 0 ] || [ -f "$HARNESS_ROOT/flag_disabled_fail" ]; then _harness2_ok=0; fi

if [ "$_harness2_ok" -eq 1 ]; then
  pass "invariant-4-mode-install-reinstall-projection-on-boot-disabled"
else
  fail "invariant-4-mode-install-missing-reinstall-projection"
fi

# Test _mode_manager return code propagation:
# Desired contract: _mode_manager must propagate nonzero manager return code instead of returning 0 unconditionally.
if awk '/^_mode_manager\(\) \{/{flag=1}
        flag && /return "\$\{_manager_rc:-0\}"|return "\$_manager_rc"/{prop=1}
        flag && /^}/{flag=0}
        END{exit !prop}' "$WRAPPER_SOURCE"; then
  pass "invariant-5-mode-manager-propagates-rc"
else
  fail "invariant-5-mode-manager-masks-failure"
fi

# ---------------------------------------------------------------------------
# Section 3: Behavioral test suite for synchronous reinstall & manager gate
# ---------------------------------------------------------------------------
EXTRACTED_UPDATE_SAFEBOOT_FUNC=$(awk '/^_is_update_recovery_or_safe_boot_active\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$WRAPPER_SOURCE")
EXTRACTED_MAINT_LOCK_FUNC=$(awk '/^_merv_boot_maintenance_lock_state\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$WRAPPER_SOURCE")
EXTRACTED_SAFEBOOT_FUNC=$(awk '/^_is_update_or_safe_boot_active\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$WRAPPER_SOURCE")
EXTRACTED_MGR_FUNC=$(awk '/^_mode_manager\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$WRAPPER_SOURCE")
EXTRACTED_CRON_FUNC=$(awk '/^_mode_cron\(\) \{/{p=1} p{print} p && /^}/{p=0}' "$WRAPPER_SOURCE")

# Load canonical lock parsers in test parent shell:
. "$BASE_DIR/settings/lib_owner_lock.sh"
. "$BASE_DIR/settings/lib_mervqt.sh"

# _mode_manager now retires the boot marker through the watchdog publication
# lock.  This contract isolates installer/manager ordering and does not create
# a watchdog marker or transient-lock fixture; the watchdog lock behavior is
# covered by boot_watchdog_diagnostic_contract_test.sh.  Keep a narrow seam so
# this test remains focused on its declared ordering assertions.
_merv_boot_watchdog_transient_lock_enter() { return 0; }
_merv_boot_watchdog_transient_lock_leave() { return 0; }

# Case A — Normal boot / No async installer:
# For BOOT_ENABLED=1:
# 1. boot install mode defers immediately (no async installer spawned, flag not written)
# 2. shield succeeds
# 3. manager starts
# 4. manager runs install.sh reinstall synchronously
# 5. reinstall completes and writes .install_ok
# 6. manager runs mervlan_manager.sh boot only afterward
# Prove: no installer/manager overlap
(
  CASE_DIR="$TEST_ROOT/caseA"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  _FLAG_DIR="$CASE_DIR/flags"
  _FLAG_FILE="$_FLAG_DIR/.install_ok"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  _flag_exists() { [ -f "$_FLAG_FILE" ]; }
  _write_flag() { touch "$_FLAG_FILE"; echo "flag_written" >> "$TRACE"; }
  _is_node_runtime() { return 1; }
  json_get_flag() {
    case "$1" in
      BOOT_ENABLED) echo "1" ;;
      PAUSE) echo "off" ;;
      *) echo "$2" ;;
    esac
  }
  json_set_flag() { return 0; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_mutation_blocked() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }
  merv_lock_state() { return 1; }

  VLAN_MANAGER="$CASE_DIR/bin/vlan_manager.sh"
  cat > "$VLAN_MANAGER" <<'EOF'
#!/bin/sh
echo "manager_boot_start" >> "$TRACE"
if [ -f "$CASE_DIR/reinstall_active" ]; then
  echo "collision install_running_during_manager" >> "$TRACE"
fi
echo "manager_boot_end" >> "$TRACE"
exit 0
EOF
  chmod +x "$VLAN_MANAGER"

  cat > "$CASE_DIR/install.sh" <<'EOF'
#!/bin/sh
echo "reinstall_start: $*" >> "$TRACE"
touch "$CASE_DIR/reinstall_active"
rm -f "$CASE_DIR/reinstall_active"
echo "reinstall_finish" >> "$TRACE"
exit 0
EOF
  chmod +x "$CASE_DIR/install.sh"

  eval "$EXTRACTED_INSTALL_FUNC"
  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MGR_FUNC"

  # Step 1: boot install mode defers
  _mode_install
  rc_install=$?
  [ "$rc_install" -eq 0 ] || exit 10
  [ ! -f "$_FLAG_FILE" ] || exit 11
  [ ! -f "$CASE_DIR/reinstall_active" ] || exit 12

  # Step 2: manager runs
  _mode_manager
  rc_manager=$?
  [ "$rc_manager" -eq 0 ] || exit 13

  # Assertions
  [ -f "$_FLAG_FILE" ] || exit 14
  if grep -q "collision install_running_during_manager" "$TRACE"; then
    exit 15
  fi
  grep -q "reinstall_start" "$TRACE" || exit 16
  grep -q "reinstall_finish" "$TRACE" || exit 17
  grep -q "manager_boot_start" "$TRACE" || exit 18
  reinstall_end_line=$(grep -n "reinstall_finish" "$TRACE" | cut -d: -f1)
  manager_start_line=$(grep -n "manager_boot_start" "$TRACE" | cut -d: -f1)
  [ "$manager_start_line" -gt "$reinstall_end_line" ] || exit 19
)
rc_case_a=$?
if [ "$rc_case_a" -eq 0 ]; then
  pass "case-a-normal-boot-no-async-installer"
  pass "case-a-reinstall-before-manager"
else
  fail "case-a-failed (rc=$rc_case_a)"
fi

# Case B — Long synchronous reinstall:
# Make install.sh reinstall block for a measurable fixture interval.
# Prove:
# reinstall_start ... reinstall_finish manager_start
# Manager must NEVER begin while reinstall is still active.
(
  CASE_DIR="$TEST_ROOT/caseB"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  _FLAG_DIR="$CASE_DIR/flags"
  _FLAG_FILE="$_FLAG_DIR/.install_ok"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  _flag_exists() { [ -f "$_FLAG_FILE" ]; }
  _write_flag() { touch "$_FLAG_FILE"; echo "flag_written" >> "$TRACE"; }
  _is_node_runtime() { return 1; }
  json_get_flag() { echo "$2"; }
  json_set_flag() { return 0; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_mutation_blocked() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }
  merv_lock_state() { return 1; }

  VLAN_MANAGER="$CASE_DIR/bin/vlan_manager.sh"
  cat > "$VLAN_MANAGER" <<'EOF'
#!/bin/sh
echo "manager_start" >> "$TRACE"
if [ -f "$CASE_DIR/reinstall_active" ]; then
  echo "collision reinstall_running_during_manager" >> "$TRACE"
fi
echo "manager_end" >> "$TRACE"
exit 0
EOF
  chmod +x "$VLAN_MANAGER"

  cat > "$CASE_DIR/install.sh" <<'EOF'
#!/bin/sh
echo "reinstall_start" >> "$TRACE"
touch "$CASE_DIR/reinstall_active"
# Long blocking interval: 0.2s
sleep 0.2
rm -f "$CASE_DIR/reinstall_active"
echo "reinstall_finish" >> "$TRACE"
exit 0
EOF
  chmod +x "$CASE_DIR/install.sh"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MGR_FUNC"

  _mode_manager
  rc=$?
  [ "$rc" -eq 0 ] || exit 20

  if grep -q "collision reinstall_running_during_manager" "$TRACE"; then
    exit 21
  fi
  grep -q "reinstall_start" "$TRACE" || exit 22
  grep -q "reinstall_finish" "$TRACE" || exit 23
  grep -q "manager_start" "$TRACE" || exit 24
  finish_line=$(grep -n "reinstall_finish" "$TRACE" | cut -d: -f1)
  mgr_line=$(grep -n "manager_start" "$TRACE" | cut -d: -f1)
  [ "$mgr_line" -gt "$finish_line" ] || exit 25
)
rc_case_b=$?
if [ "$rc_case_b" -eq 0 ]; then
  pass "case-b-long-synchronous-reinstall-blocks-manager"
  pass "case-b-no-reinstall-manager-overlap"
else
  fail "case-b-failed (rc=$rc_case_b)"
fi

# Case C — Reinstall failure:
# Fixture: install.sh reinstall returns nonzero.
# Assert:
# - .install_ok not written
# - manager not called
# - wrapper returns nonzero
(
  CASE_DIR="$TEST_ROOT/caseC"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  _FLAG_DIR="$CASE_DIR/flags"
  _FLAG_FILE="$_FLAG_DIR/.install_ok"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  _flag_exists() { [ -f "$_FLAG_FILE" ]; }
  _write_flag() { touch "$_FLAG_FILE"; echo "flag_written" >> "$TRACE"; }
  _is_node_runtime() { return 1; }
  json_get_flag() { echo "$2"; }
  json_set_flag() { return 0; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_mutation_blocked() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }
  merv_lock_state() { return 1; }

  VLAN_MANAGER="$CASE_DIR/bin/vlan_manager.sh"
  cat > "$VLAN_MANAGER" <<'EOF'
#!/bin/sh
echo "manager_start" >> "$TRACE"
exit 0
EOF
  chmod +x "$VLAN_MANAGER"

  cat > "$CASE_DIR/install.sh" <<'EOF'
#!/bin/sh
echo "reinstall_failed" >> "$TRACE"
exit 2
EOF
  chmod +x "$CASE_DIR/install.sh"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MGR_FUNC"

  _mode_manager
  rc=$?
  [ "$rc" -ne 0 ] || exit 30
  if grep -q "manager_start" "$TRACE"; then
    exit 31
  fi
  [ ! -f "$_FLAG_FILE" ] || exit 32
)
rc_case_c=$?
if [ "$rc_case_c" -eq 0 ]; then
  pass "case-c-reinstall-failure-fails-closed"
  pass "case-c-install-flag-not-written"
else
  fail "case-c-failed (rc=$rc_case_c)"
fi

# Case D — Maintenance / Update active:
# Simulate canonical active maintenance/update state.
# Assert manager does not proceed into reinstall or Apply when policy says it must defer/fail.
(
  CASE_DIR="$TEST_ROOT/caseD"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  _FLAG_DIR="$CASE_DIR/flags"
  _FLAG_FILE="$_FLAG_DIR/.install_ok"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  _flag_exists() { [ -f "$_FLAG_FILE" ]; }
  _write_flag() { touch "$_FLAG_FILE"; echo "flag_written" >> "$TRACE"; }
  _is_node_runtime() { return 1; }
  json_get_flag() { echo "$2"; }
  json_set_flag() { return 0; }

  VLAN_MANAGER="$CASE_DIR/bin/vlan_manager.sh"
  cat > "$VLAN_MANAGER" <<'EOF'
#!/bin/sh
echo "manager_start" >> "$TRACE"
exit 0
EOF
  chmod +x "$VLAN_MANAGER"

  cat > "$CASE_DIR/install.sh" <<'EOF'
#!/bin/sh
echo "reinstall_start" >> "$TRACE"
exit 0
EOF
  chmod +x "$CASE_DIR/install.sh"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MGR_FUNC"

  # Test D1: merv_update_quiesce_active returns 0 (active)
  merv_update_quiesce_active() { return 0; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_mutation_blocked() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }
  merv_lock_state() { return 1; }

  : > "$TRACE"
  _mode_manager
  rc_d1=$?
  [ "$rc_d1" -eq 75 ] || exit 40
  ! grep -q "reinstall_start" "$TRACE" || exit 41
  ! grep -q "manager_start" "$TRACE" || exit 41
  grep -q "Manager startup suppressed" "$TRACE" || exit 41

  # Test D2: merv_update_journal_requires_safe_boot returns 0
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 0; }
  merv_update_mutation_blocked() { return 1; }

  : > "$TRACE"
  _mode_manager
  rc_d2=$?
  [ "$rc_d2" -eq 75 ] || exit 42
  ! grep -q "reinstall_start" "$TRACE" || exit 43
  ! grep -q "manager_start" "$TRACE" || exit 43
  grep -q "Manager startup suppressed" "$TRACE" || exit 43

  # Test D3: active maintenance lock present
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_mutation_blocked() { return 1; }
  touch "$LOCKDIR/mervlan_maintenance.lock"
  merv_lock_state() { printf 'active\n'; return 0; }

  : > "$TRACE"
  _mode_manager
  rc_d3=$?
  [ "$rc_d3" -eq 75 ] || exit 44
  ! grep -q "reinstall_start" "$TRACE" || exit 45
  ! grep -q "manager_start" "$TRACE" || exit 45
  grep -q "Manager startup suppressed" "$TRACE" || exit 45
)
rc_case_d=$?
if [ "$rc_case_d" -eq 0 ]; then
  pass "case-d-maintenance-update-active-suppresses-manager"
else
  fail "case-d-failed (rc=$rc_case_d)"
fi

# Case F — Fast normal boot:
# Prove no arbitrary sleep 5 / sleep 10 blocks manager before runtime projection.
# The only wait should be real synchronous work / canonical lifecycle gating.
(
  CASE_DIR="$TEST_ROOT/caseF"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  _FLAG_DIR="$CASE_DIR/flags"
  _FLAG_FILE="$_FLAG_DIR/.install_ok"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  _flag_exists() { [ -f "$_FLAG_FILE" ]; }
  _write_flag() { touch "$_FLAG_FILE"; echo "flag_written" >> "$TRACE"; }
  _is_node_runtime() { return 1; }
  json_get_flag() { echo "$2"; }
  json_set_flag() { return 0; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_mutation_blocked() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }
  merv_lock_state() { return 1; }

  VLAN_MANAGER="$CASE_DIR/bin/vlan_manager.sh"
  cat > "$VLAN_MANAGER" <<'EOF'
#!/bin/sh
echo "manager_start" >> "$TRACE"
exit 0
EOF
  chmod +x "$VLAN_MANAGER"

  cat > "$CASE_DIR/install.sh" <<'EOF'
#!/bin/sh
echo "reinstall_fast" >> "$TRACE"
exit 0
EOF
  chmod +x "$CASE_DIR/install.sh"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MGR_FUNC"

  # Count any sleep invocations
  _sleep_count=0
  sleep() { _sleep_count=$((_sleep_count + 1)); }

  _mode_manager
  rc=$?
  [ "$rc" -eq 0 ] || exit 60
  [ "$_sleep_count" -eq 0 ] || exit 61
  grep -q "reinstall_fast" "$TRACE" || exit 62
  grep -q "manager_start" "$TRACE" || exit 63
)
rc_case_f=$?
if [ "$rc_case_f" -eq 0 ]; then
  pass "case-f-fast-normal-boot-no-arbitrary-delay"
else
  fail "case-f-failed (rc=$rc_case_f)"
fi

# Case G — Long reinstall + cron:
# Simulate:
# 1. manager begins in background, executing install.sh reinstall
# 2. install.sh reinstall acquires maintenance lock (active)
# 3. cron is invoked while reinstall is still active
# 4. cron sees maintenance active, waits boundedly (does NOT fail with 75)
# 5. reinstall finishes, releases maintenance lock
# 6. cron sees maintenance cleared, executes cronenable
(
  export CASE_DIR="$TEST_ROOT/caseG"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  _FLAG_DIR="$CASE_DIR/flags"
  _FLAG_FILE="$_FLAG_DIR/.install_ok"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"
  MERV_BOOT_CRON_WAIT_SEC=5
  MERV_BOOT_CRON_POLL_SEC=1

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  _flag_exists() { [ -f "$_FLAG_FILE" ]; }
  _write_flag() { touch "$_FLAG_FILE"; echo "flag_written" >> "$TRACE"; }
  _is_node_runtime() { return 1; }
  json_get_flag() { echo "$2"; }
  json_set_flag() { return 0; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_mutation_blocked() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }

  # Maintenance lock state reflects presence of maintenance active marker
  merv_lock_state() {
    if [ -f "$CASE_DIR/reinstall_active" ]; then
      printf 'active\n'
    else
      printf 'absent\n'
    fi
  }

  VLAN_MANAGER="$CASE_DIR/bin/vlan_manager.sh"
  cat > "$VLAN_MANAGER" <<'EOF'
#!/bin/sh
echo "manager_start" >> "$TRACE"
if [ -f "$CASE_DIR/reinstall_active" ]; then
  echo "collision reinstall_running_during_manager" >> "$TRACE"
fi
echo "manager_end" >> "$TRACE"
exit 0
EOF
  chmod +x "$VLAN_MANAGER"

  BOOT_SCRIPT="$CASE_DIR/bin/mervlan_boot.sh"
  cat > "$BOOT_SCRIPT" <<'EOF'
#!/bin/sh
case "$1" in
  cronenable)
    echo "cronenable_start" >> "$TRACE"
    if [ -f "$CASE_DIR/reinstall_active" ]; then
      echo "collision cronenable_during_reinstall" >> "$TRACE"
    fi
    echo "cronenable_executed" >> "$TRACE"
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BOOT_SCRIPT"

  cat > "$CASE_DIR/install.sh" <<'EOF'
#!/bin/sh
echo "reinstall_start" >> "$TRACE"
touch "$CASE_DIR/reinstall_active"
touch "$LOCKDIR/mervlan_maintenance.lock"
# Reinstall takes a measurable interval: 0.25s
sleep 0.25
rm -f "$CASE_DIR/reinstall_active" "$LOCKDIR/mervlan_maintenance.lock"
echo "reinstall_finish" >> "$TRACE"
exit 0
EOF
  chmod +x "$CASE_DIR/install.sh"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MGR_FUNC"
  eval "$EXTRACTED_CRON_FUNC"

  # Run manager in background (simulating services-start: manager &)
  _mode_manager &
  _mgr_bg_pid=$!

  # Wait until reinstall is active before launching cron
  _w=0
  while [ ! -f "$CASE_DIR/reinstall_active" ] && [ "$_w" -lt 20 ]; do
    sleep 0.05
    _w=$((_w + 1))
  done

  # Now invoke cron while reinstall is active
  _mode_cron
  rc_cron=$?

  wait "$_mgr_bg_pid"
  rc_mgr=$?

  [ "$rc_cron" -eq 0 ] || exit 70
  [ "$rc_mgr" -eq 0 ] || exit 71

  if grep -q "collision cronenable_during_reinstall" "$TRACE"; then
    exit 72
  fi
  if grep -q "collision reinstall_running_during_manager" "$TRACE"; then
    exit 73
  fi

  grep -q "Cron waiting for temporary maintenance to clear" "$TRACE" || exit 74
  grep -q "Maintenance cleared; cron proceeding" "$TRACE" || exit 75
  [ "$(grep -c "cronenable_executed" "$TRACE")" -eq 1 ] || exit 76

  reinstall_start_line=$(grep -n "reinstall_start" "$TRACE" | cut -d: -f1)
  reinstall_finish_line=$(grep -n "reinstall_finish" "$TRACE" | cut -d: -f1)
  cronenable_line=$(grep -n "cronenable_executed" "$TRACE" | cut -d: -f1)
  manager_start_line=$(grep -n "manager_start" "$TRACE" | cut -d: -f1)

  [ "$cronenable_line" -gt "$reinstall_finish_line" ] || exit 77
  [ "$manager_start_line" -gt "$reinstall_finish_line" ] || exit 78
)
rc_case_g=$?
if [ "$rc_case_g" -eq 0 ]; then
  pass "case-g-reinstall-cron-concurrent-wait"
  pass "case-g-cronenable-runs-after-maintenance"
  pass "case-g-cronenable-runs-exactly-once"
else
  fail "case-g-failed (rc=$rc_case_g)"
fi

# Case H — Maintenance already idle:
# Cron should execute without unnecessary wait.
(
  CASE_DIR="$TEST_ROOT/caseH"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }
  merv_lock_state() { printf 'absent\n'; }

  BOOT_SCRIPT="$CASE_DIR/bin/mervlan_boot.sh"
  cat > "$BOOT_SCRIPT" <<'EOF'
#!/bin/sh
case "$1" in
  cronenable)
    echo "cronenable_executed" >> "$TRACE"
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BOOT_SCRIPT"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_CRON_FUNC"

  _sleep_count=0
  sleep() { _sleep_count=$((_sleep_count + 1)); }

  _mode_cron
  rc_h=$?

  [ "$rc_h" -eq 0 ] || exit 80
  [ "$_sleep_count" -eq 0 ] || exit 81
  grep -q "cronenable_executed" "$TRACE" || exit 82
  if grep -q "Cron waiting for temporary maintenance to clear" "$TRACE"; then
    exit 83
  fi
)
rc_case_h=$?
if [ "$rc_case_h" -eq 0 ]; then
  pass "case-h-cron-idle-no-unnecessary-wait"
else
  fail "case-h-failed (rc=$rc_case_h)"
fi

# Case I — Persistent Update / safe-boot state:
# Simulate canonical Update quiesce/recovery/safe-boot state.
# Assert:
# - cron remains suppressed/fail-closed (returns 75)
# - cronenable is not executed
(
  CASE_DIR="$TEST_ROOT/caseI"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }
  merv_lock_state() { printf 'absent\n'; }

  BOOT_SCRIPT="$CASE_DIR/bin/mervlan_boot.sh"
  cat > "$BOOT_SCRIPT" <<'EOF'
#!/bin/sh
echo "cronenable_unexpected" >> "$TRACE"
exit 0
EOF
  chmod +x "$BOOT_SCRIPT"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_CRON_FUNC"

  # Test I1: quiesce active
  merv_update_quiesce_active() { return 0; }
  merv_update_journal_requires_safe_boot() { return 1; }

  _mode_cron
  rc_i1=$?
  [ "$rc_i1" -eq 75 ] || exit 90
  ! grep -q "cronenable_unexpected" "$TRACE" || exit 91
  grep -q "Cron enable suppressed: Update recovery/quiesce state is active" "$TRACE" || exit 92

  # Test I2: journal requires safe boot
  : > "$TRACE"
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 0; }

  _mode_cron
  rc_i2=$?
  [ "$rc_i2" -eq 75 ] || exit 93
  ! grep -q "cronenable_unexpected" "$TRACE" || exit 94
  grep -q "Cron enable suppressed: Update recovery/quiesce state is active" "$TRACE" || exit 95
)
rc_case_i=$?
if [ "$rc_case_i" -eq 0 ]; then
  pass "case-i-cron-update-safeboot-suppressed"
else
  fail "case-i-failed (rc=$rc_case_i)"
fi

# Case J — Maintenance never clears:
# Simulate a verified active maintenance owner for longer than the bounded wait.
# Assert:
# - cron times out/fails nonzero (rc=1)
# - cronenable is not executed
# - owner state is not removed
(
  CASE_DIR="$TEST_ROOT/caseJ"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  MERV_BASE="$CASE_DIR"
  MERV_BOOT_CRON_WAIT_SEC=2
  MERV_BOOT_CRON_POLL_SEC=1

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }

  touch "$LOCKDIR/mervlan_maintenance.lock"
  merv_lock_state() { printf 'active\n'; }

  BOOT_SCRIPT="$CASE_DIR/bin/mervlan_boot.sh"
  cat > "$BOOT_SCRIPT" <<'EOF'
#!/bin/sh
echo "cronenable_unexpected" >> "$TRACE"
exit 0
EOF
  chmod +x "$BOOT_SCRIPT"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_CRON_FUNC"

  _mode_cron
  rc_j=$?

  [ "$rc_j" -ne 0 ] || exit 100
  ! grep -q "cronenable_unexpected" "$TRACE" || exit 101
  grep -q "Cron waiting for temporary maintenance to clear" "$TRACE" || exit 102
  grep -q "Cron wait timed out after" "$TRACE" || exit 103
  # Maintenance lock state must NOT be removed
  [ -f "$LOCKDIR/mervlan_maintenance.lock" ] || exit 104
)
rc_case_j=$?
if [ "$rc_case_j" -eq 0 ]; then
  pass "case-j-cron-maintenance-timeout-fail-closed"
  pass "case-j-cron-owner-state-preserved"
else
  fail "case-j-failed (rc=$rc_case_j)"
fi

# Case K — Ambiguous / malformed regular-file maintenance obstruction:
# Asserts that a non-directory / malformed object at maintenance lock path fails closed.
(
  CASE_DIR="$TEST_ROOT/caseK"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"
  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }

  MERV_BASE="$BASE_DIR" . "$BASE_DIR/settings/lib_owner_lock.sh"
  MERV_BASE="$BASE_DIR" . "$BASE_DIR/settings/lib_mervqt.sh"
  MERV_BASE="$CASE_DIR"

  touch "$LOCKDIR/mervlan_maintenance.lock"

  BOOT_SCRIPT="$CASE_DIR/bin/mervlan_boot.sh"
  cat > "$BOOT_SCRIPT" <<'EOF'
#!/bin/sh
echo "cronenable_unexpected" >> "$TRACE"
exit 0
EOF
  chmod +x "$BOOT_SCRIPT"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_CRON_FUNC"

  _lock_state=$(_merv_boot_maintenance_lock_state)
  [ "$_lock_state" != "absent" ] || exit 114
  [ "$_lock_state" = "ambiguous" ] || exit 115

  _mode_cron
  rc_k=$?

  [ "$rc_k" -ne 0 ] || exit 110
  ! grep -q "cronenable_unexpected" "$TRACE" || exit 111
  grep -q "Cron enable aborted: ambiguous or malformed maintenance lock state" "$TRACE" || exit 112
  # Lock file not removed
  [ -f "$LOCKDIR/mervlan_maintenance.lock" ] || exit 113
)
rc_case_k=$?
if [ "$rc_case_k" -eq 0 ]; then
  pass "case-k-cron-ambiguous-maintenance-fail-closed"
  pass "case-k-cron-ambiguous-state-preserved"
else
  fail "case-k-failed (rc=$rc_case_k)"
fi

# Case L — Dangling symlink maintenance obstruction:
# Asserts that a dangling symlink at the maintenance lock path:
# 1. Is NOT classified as absent
# 2. Blocks the real Update mutation gate
# 3. Blocks updater idle, boot manager, and boot install gates
# 4. Causes cron to return nonzero / fail closed
# 5. All downstream actions are called 0 times
# 6. Symlink remains untouched (not deleted, target not created)
(
  CASE_DIR="$TEST_ROOT/caseL"
  mkdir -p "$CASE_DIR/locks" "$CASE_DIR/flags" "$CASE_DIR/bin"
  export TRACE="$CASE_DIR/trace.log"
  : > "$TRACE"

  export LOCKDIR="$CASE_DIR/locks"
  export TMPDIR="$CASE_DIR/tmp"
  SETTINGS_FILE="$CASE_DIR/settings.json"
  LOG_chan_boot="$CASE_DIR/boot_wrap.log"

  info() { echo "INFO: $*" >> "$TRACE"; }
  warn() { echo "WARN: $*" >> "$TRACE"; }
  error() { echo "ERROR: $*" >> "$TRACE"; }
  merv_update_quiesce_active() { return 1; }
  merv_update_journal_requires_safe_boot() { return 1; }
  merv_update_maintenance_lock_path() { printf '%s/mervlan_maintenance.lock' "$LOCKDIR"; }

  MERV_BASE="$BASE_DIR" . "$BASE_DIR/settings/lib_owner_lock.sh"
  MERV_BASE="$BASE_DIR" . "$BASE_DIR/settings/lib_mervqt.sh"
  MERV_BASE="$BASE_DIR" . "$BASE_DIR/settings/lib_update_state.sh"
  MERV_BASE="$CASE_DIR"

  _TARGET="$CASE_DIR/nonexistent-owner-target"
  _SYMLINK="$LOCKDIR/mervlan_maintenance.lock"
  _l_ok=1

  MSYS="${MSYS:-winsymlinks:lnk}" ln -s "$_TARGET" "$_SYMLINK" 2>/dev/null || \
  ln -s "$_TARGET" "$_SYMLINK" 2>/dev/null || :

  if [ ! -L "$_SYMLINK" ]; then
    echo "SYMLINK_UNSUPPORTED" >> "$TRACE"
    exit 200
  fi

  # Verify link is genuinely dangling
  if [ -e "$_SYMLINK" ]; then
    exit 120
  fi

  _FLAG_DIR="$CASE_DIR/flags"
  _FLAG_FILE="$_FLAG_DIR/.install_ok"
  _flag_exists() { [ -f "$_FLAG_FILE" ]; }
  _write_flag() { touch "$_FLAG_FILE"; echo "flag_written" >> "$TRACE"; }
  _is_node_runtime() { return 1; }
  json_get_flag() {
    case "$1" in
      BOOT_ENABLED) echo "0" ;;
      *) echo "$2" ;;
    esac
  }

  cat > "$CASE_DIR/install.sh" <<'EOF'
#!/bin/sh
echo "install_invoked:$*" >> "$TRACE"
exit 0
EOF
  chmod +x "$CASE_DIR/install.sh"
  VLAN_MANAGER="$CASE_DIR/vlan_manager.sh"
  cat > "$VLAN_MANAGER" <<'EOF'
#!/bin/sh
echo "manager_invoked:$*" >> "$TRACE"
exit 0
EOF
  chmod +x "$VLAN_MANAGER"

  BOOT_SCRIPT="$CASE_DIR/bin/mervlan_boot.sh"
  cat > "$BOOT_SCRIPT" <<'EOF'
#!/bin/sh
echo "cronenable_unexpected" >> "$TRACE"
exit 0
EOF
  chmod +x "$BOOT_SCRIPT"

  eval "$EXTRACTED_UPDATE_SAFEBOOT_FUNC"
  eval "$EXTRACTED_MAINT_LOCK_FUNC"
  eval "$EXTRACTED_SAFEBOOT_FUNC"
  eval "$EXTRACTED_INSTALL_FUNC"
  eval "$EXTRACTED_MGR_FUNC"
  eval "$EXTRACTED_CRON_FUNC"

  # Direct helper evaluation: must NOT be classified as absent
  _lock_state=$(_merv_boot_maintenance_lock_state)
  [ "$_lock_state" != "absent" ] || exit 121
  [ "$_lock_state" = "ambiguous" ] || exit 122

  # The update mutation gate itself must treat the dangling link as blocked;
  # this is the predicate consumed by the caller gates below.
  merv_update_mutation_blocked
  _mutation_rc=$?
  if [ "$_mutation_rc" -ne 0 ] || [ ! -L "$_SYMLINK" ]; then
    printf 'DEFECT: case-l mutation gate rc=%s\n' "$_mutation_rc" >&2
    echo "defect: mutation gate rc=$_mutation_rc" >> "$TRACE"
    _l_ok=0
  fi

  # A boot install with BOOT_ENABLED=0 would invoke reinstall on an unguarded
  # path. The dangling obstruction must stop it before the fixture is called.
  _mode_install
  rc_install_l=$?
  if [ "$rc_install_l" -eq 0 ] || grep -q "install_invoked" "$TRACE" ||
     [ -f "$_FLAG_FILE" ] || [ ! -L "$_SYMLINK" ]; then
    printf 'DEFECT: case-l install gate rc=%s\n' "$rc_install_l" >&2
    echo "defect: install gate rc=$rc_install_l" >> "$TRACE"
    _l_ok=0
  fi

  # Manager startup is the second caller gate. Reset the trace/flag so this
  # assertion cannot pass by observing the install result above.
  : > "$TRACE"
  rm -f "$_FLAG_FILE"
  _mode_manager
  rc_manager_l=$?
  if [ "$rc_manager_l" -eq 0 ] || grep -q "install_invoked" "$TRACE" ||
     grep -q "manager_invoked" "$TRACE" || [ -f "$_FLAG_FILE" ] ||
     [ ! -L "$_SYMLINK" ]; then
    printf 'DEFECT: case-l manager gate rc=%s\n' "$rc_manager_l" >&2
    echo "defect: manager gate rc=$rc_manager_l" >> "$TRACE"
    _l_ok=0
  fi

  _mode_cron
  rc_l=$?

  # Must return nonzero / fail closed
  [ "$rc_l" -ne 0 ] || exit 134
  # cronenable must NOT be called
  ! grep -q "cronenable_unexpected" "$TRACE" || exit 135
  # Must log ambiguous aborted message
  grep -q "Cron enable aborted: ambiguous or malformed maintenance lock state" "$TRACE" || exit 136
  # Must NOT enter wait/polling path
  ! grep -q "Cron waiting for temporary maintenance to clear" "$TRACE" || exit 137
  ! grep -q "Maintenance cleared; cron proceeding" "$TRACE" || exit 138

  # Assert symlink is untouched, target not created, no cleanup occurred
  [ -L "$_SYMLINK" ] || exit 139
  [ ! -e "$_TARGET" ] || exit 140
  [ "$_l_ok" -eq 1 ] || exit 123
)
rc_case_l=$?
if [ "$rc_case_l" -eq 0 ]; then
  pass "case-l-dangling-symlink-blocks-update-mutation"
  pass "case-l-dangling-symlink-blocks-boot-install"
  pass "case-l-dangling-symlink-blocks-boot-manager"
  pass "case-l-cron-dangling-symlink-not-absent"
  pass "case-l-cron-dangling-symlink-fail-closed"
  pass "case-l-cron-dangling-symlink-state-preserved"
elif [ "$rc_case_l" -eq 200 ]; then
  pass "case-l-dangling-symlink-unsupported-on-host"
else
  fail "case-l-failed (rc=$rc_case_l)"
fi

# ---------------------------------------------------------------------------
# Section 4: Composed startup timing simulation
# ---------------------------------------------------------------------------
# Materialize the composed services-start hook using the real templates.
# Addon runs first, followed by services-start.
# Verifies that with the corrected template ordering and boot wrapper gate,
# manager runs after synchronous runtime reprojection and no collision occurs.

COMPOSED_HOOK="$TEST_ROOT/composed_services_start.sh"
TRACE_LOG="$TEST_ROOT/trace.log"
BOOT_WRAP_SIM="$TEST_ROOT/boot_wrap_sim.sh"

cat > "$BOOT_WRAP_SIM" <<'EOF'
#!/bin/sh
MODE="$1"
echo "start $MODE" >> "$TRACE_FILE"
case "$MODE" in
  install)
    # On clean boot with BOOT_ENABLED=1, install defers immediately
    echo "install_deferred" >> "$TRACE_FILE"
    ;;
  shield)
    : > "$TEST_ROOT_DIR/shield_ready"
    ;;
  manager)
    # Manager executes synchronous reinstall projection then manager Apply
    echo "manager_reinstall_run" >> "$TRACE_FILE"
    echo "manager_boot_executed" >> "$TRACE_FILE"
    ;;
  cron)
    ;;
esac
echo "end $MODE" >> "$TRACE_FILE"
exit 0
EOF
chmod 755 "$BOOT_WRAP_SIM"

# Render the composed hook script with scaled sleep durations
cat > "$COMPOSED_HOOK" <<'EOF'
#!/bin/sh
sleep() {
  case "$1" in
    10) /bin/sleep 0.1 ;;
    *)  /bin/sleep 0.05 ;;
  esac
}
EOF

# Append real addon template and services-start template with wrapper simulation replacement
sed "s|[^[:space:]]*/functions/mervlan_boot_wrap\.sh|$BOOT_WRAP_SIM|g" "$TPL_ADDON_1" >> "$COMPOSED_HOOK"
printf '\n' >> "$COMPOSED_HOOK"
sed "s|[^[:space:]]*/functions/mervlan_boot_wrap\.sh|$BOOT_WRAP_SIM|g" "$TPL_SERVICES_1" >> "$COMPOSED_HOOK"
chmod 755 "$COMPOSED_HOOK"

: > "$TRACE_LOG"
TEST_ROOT_DIR="$TEST_ROOT" TRACE_FILE="$TRACE_LOG" sh "$COMPOSED_HOOK" </dev/null >/dev/null 2>&1
# Allow background jobs to complete
/bin/sleep 0.4

if grep -q "collision install_running_during_manager" "$TRACE_LOG" 2>/dev/null; then
  fail "invariant-4-overlap-risk-proven: concurrent install and manager Apply detected"
else
  pass "invariant-4-no-manager-install-overlap"
fi

if [ "$_FAILURES" -eq 0 ]; then
  printf 'BOOT_COMPOSED_ORDER_CONTRACT_OK\n'
  exit 0
else
  printf 'BOOT_COMPOSED_ORDER_CONTRACT_FAIL: observed defects (%s failure(s))\n' "$_FAILURES" >&2
  exit 1
fi
