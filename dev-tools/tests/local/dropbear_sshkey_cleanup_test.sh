#!/bin/sh
# Focused BusyBox regression coverage for dropbear_sshkey_gen.sh terminal
# status handling.  The fixture owns an isolated action lock and progress
# backend; no router, SSH, or live action is contacted.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." 2>/dev/null && pwd) || exit 1
BUSYBOX=$(command -v busybox 2>/dev/null || printf '')
[ -n "$BUSYBOX" ] || {
    printf 'FAIL: BusyBox is required for this focused regression test\n' >&2
    exit 1
}

TEST_ROOT="/tmp/mervlan_tmp/selftest.dropbear-sshkey.$$"
FIXTURE_ROOT="$TEST_ROOT/base"
umask 077
mkdir -p "$FIXTURE_ROOT/settings" "$FIXTURE_ROOT/bin" "$FIXTURE_ROOT/public" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_TEST_ROOT="$TEST_ROOT"

# Every production library import is redirected to one deterministic fixture.
# The key generator itself remains the real production script.
cat > "$FIXTURE_ROOT/settings/common.sh" <<'EOF'
VAR_SETTINGS_LOADED=1
LOG_SETTINGS_LOADED=1
LIB_JSON_LOADED=1
LIB_SSH_LOADED=1
LIB_ACTION_LOCK_LOADED=1
LIB_UPDATE_STATE_LOADED=1
LIB_ACTION_PROGRESS_LOADED=1

LOCKDIR="$MERV_TEST_ROOT/locks"
SSH_KEY="$MERV_TEST_ROOT/keys/id_ed25519"
SSH_PUBKEY="$MERV_TEST_ROOT/keys/id_ed25519.pub"
PUBLIC_MERV_BASE="$MERV_TEST_ROOT/public"
DROPBEARKEY="$MERV_BASE/bin/dropbearkey"
SETTINGS_FILE="$MERV_TEST_ROOT/settings.json"

info() { :; }
warn() { :; }
error() { :; }

merv_update_mutation_blocked() { return 1; }

merv_action_lock_enter() {
    MERV_ACTION_LOCK_MODE=self
    MERV_ACTION_LOCK_NONCE=sshkey-test-nonce
    MERV_ACTION_LOCK_START=1
    : > "$MERV_TEST_ROOT/lock"
    return 0
}
merv_action_lock_export_child_context() { return 0; }
merv_action_lock_leave() {
    if [ "${MERV_TEST_CLEANUP_FAIL:-0}" = 1 ]; then
        return 1
    fi
    rm -f "$MERV_TEST_ROOT/lock"
    return 0
}

merv_action_progress_init() {
    : > "$MERV_TEST_ROOT/progress"
    printf 'init:%s\n' "$*" >> "$MERV_TEST_ROOT/progress"
    MERV_ACTION_PROGRESS_ENABLED=1
}
merv_action_progress_update() { printf 'update:%s\n' "$*" >> "$MERV_TEST_ROOT/progress"; }
merv_action_progress_complete() { printf 'complete:%s\n' "$*" >> "$MERV_TEST_ROOT/progress"; }
merv_action_progress_fail() { printf 'failed:%s\n' "$*" >> "$MERV_TEST_ROOT/progress"; }

merv_has() { [ "${1:-}" = _sync_ssh_flag ]; }
_sync_ssh_flag() { printf '%s\n' "$1" > "$MERV_TEST_ROOT/flag"; }
json_set_flag() { printf '%s\n' "$2" > "$MERV_TEST_ROOT/flag"; return 0; }
EOF
for _lib in var_settings.sh log_settings.sh lib_json.sh lib_ssh.sh \
    lib_action_lock.sh lib_update_state.sh lib_action_progress.sh; do
    printf '%s\n' '. "$MERV_BASE/settings/common.sh"' > "$FIXTURE_ROOT/settings/$_lib" || exit 1
done

cat > "$FIXTURE_ROOT/bin/dropbearkey" <<'EOF'
#!/bin/sh
if [ "${MERV_TEST_GENERATE_FAIL:-0}" = 1 ]; then
    exit 1
fi
if [ "${1:-}" = -t ]; then
    [ "${MERV_TEST_GENERATE_DELAY:-0}" = 1 ] && sleep 5
    printf '%s\n' private-key > "$4"
    exit 0
fi
if [ "${1:-}" = -y ]; then
    printf '%s\n' 'ssh-ed25519 AAAATEST mer-vlan-test'
    exit 0
fi
exit 2
EOF
chmod 700 "$FIXTURE_ROOT/bin/dropbearkey" || exit 1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

run_case() {
    _case="$1"
    _expected_rc="$2"
    _generate_fail="$3"
    _cleanup_fail="$4"
    _generate_delay="${5:-0}"
    rm -rf "$MERV_TEST_ROOT/keys" "$MERV_TEST_ROOT/public/.ssh" \
        "$MERV_TEST_ROOT/lock" "$MERV_TEST_ROOT/flag" "$MERV_TEST_ROOT/progress"
    mkdir -p "$MERV_TEST_ROOT/keys" || fail "$_case fixture setup"
    MERV_BASE="$FIXTURE_ROOT" \
    MERV_TEST_GENERATE_FAIL="$_generate_fail" \
    MERV_TEST_CLEANUP_FAIL="$_cleanup_fail" \
    MERV_TEST_GENERATE_DELAY="$_generate_delay" \
    MERV_PROGRESS_TOKEN="sshkey-test-$_case" \
    export MERV_BASE MERV_TEST_GENERATE_FAIL MERV_TEST_CLEANUP_FAIL \
        MERV_TEST_GENERATE_DELAY MERV_PROGRESS_TOKEN
    "$BUSYBOX" sh "$BASE_DIR/functions/dropbear_sshkey_gen.sh" \
        > "$MERV_TEST_ROOT/$_case.log" 2>&1
    _rc=$?
    if [ "$_rc" -ne "$_expected_rc" ]; then
        cat "$MERV_TEST_ROOT/$_case.log" >&2
        fail "$_case returned rc=$_rc (expected $_expected_rc)"
    fi
    if [ "$_cleanup_fail" = 1 ]; then
        grep -Fq 'failed:' "$MERV_TEST_ROOT/progress" || fail "$_case did not publish failed progress"
        [ -e "$MERV_TEST_ROOT/lock" ] || fail "$_case removed an unreleased action lock"
    elif [ "$_generate_fail" = 1 ]; then
        grep -Fq 'failed:' "$MERV_TEST_ROOT/progress" || fail "$_case did not publish generation failure"
        [ ! -e "$MERV_TEST_ROOT/lock" ] || fail "$_case retained a released action lock"
        [ "$(cat "$MERV_TEST_ROOT/flag")" = 0 ] || fail "$_case did not mark keys unavailable"
    else
        grep -Fq 'complete:' "$MERV_TEST_ROOT/progress" || fail "$_case did not publish complete progress"
        [ ! -e "$MERV_TEST_ROOT/lock" ] || fail "$_case retained a released action lock"
        [ "$(cat "$MERV_TEST_ROOT/flag")" = 1 ] || fail "$_case did not mark keys installed"
    fi
    pass "$_case terminal status and ownership"
}

# A clean success remains successful and publishes complete progress.
run_case success 0 0 0
# The original generation error remains nonzero and publishes failed progress.
run_case generation-failure 1 1 0
# A pre-existing generation failure remains its original nonzero status even
# when lock release also fails.
run_case generation-failure-cleanup-failure 1 1 1
# A cleanup failure upgrades success to 75, publishes failed progress, and
# leaves the lock available for recovery instead of reporting false success.
run_case cleanup-failure 75 0 1

# A signal-derived nonzero status must also survive the EXIT hook.  The fixture
# delays key generation long enough for this test process to terminate the
# worker deterministically.
rm -rf "$MERV_TEST_ROOT/keys" "$MERV_TEST_ROOT/public/.ssh" \
    "$MERV_TEST_ROOT/lock" "$MERV_TEST_ROOT/flag" "$MERV_TEST_ROOT/progress"
mkdir -p "$MERV_TEST_ROOT/keys" || fail signal-fixture-setup
MERV_BASE="$FIXTURE_ROOT" MERV_TEST_GENERATE_FAIL=0 \
MERV_TEST_CLEANUP_FAIL=0 MERV_TEST_GENERATE_DELAY=1 \
MERV_PROGRESS_TOKEN=sshkey-test-signal \
export MERV_BASE MERV_TEST_GENERATE_FAIL MERV_TEST_CLEANUP_FAIL \
    MERV_TEST_GENERATE_DELAY MERV_PROGRESS_TOKEN
"$BUSYBOX" sh "$BASE_DIR/functions/dropbear_sshkey_gen.sh" \
    > "$MERV_TEST_ROOT/signal.log" 2>&1 &
_signal_pid=$!
sleep 1
kill -TERM "$_signal_pid" 2>/dev/null || fail signal-worker-kill
wait "$_signal_pid" 2>/dev/null
_signal_rc=$?
[ "$_signal_rc" -ne 0 ] || fail 'signal status was masked as success'
pass signal-status-remains-nonzero

printf 'DROPBEAR_SSHKEY_CLEANUP_CONTRACT_OK\n'
