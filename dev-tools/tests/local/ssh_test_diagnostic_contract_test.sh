#!/bin/sh
# Contract for merv_ssh_test stdout capture and caller-visible diagnostics.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-ssh-test-diagnostic.$(date +%s).$$"
JOB_ROOT="$TEST_ROOT/job"
SSH_TMP_ROOT="$JOB_ROOT/ssh"
SETTINGS_FILE="$TEST_ROOT/settings.json"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (got=$1 expected=$2)"
}

assert_no_private_output() {
    [ -z "$(find "$SSH_TMP_ROOT" -mindepth 1 -print -quit 2>/dev/null)" ] ||
        fail "$1 left a private SSH test artifact"
}

mkdir -p "$SSH_TMP_ROOT"
printf '%s\n' '{}' > "$SETTINGS_FILE"
MERV_BASE="$ROOT"
MERV_NODE_JOB_DIR="$JOB_ROOT"
MERV_SSH_TMPDIR="$SSH_TMP_ROOT"
export MERV_BASE MERV_NODE_JOB_DIR MERV_SSH_TMPDIR SETTINGS_FILE

. "$ROOT/settings/lib_json.sh"
LIB_SSH_TRUST_LOADED=1
. "$ROOT/settings/lib_ssh.sh"

merv_ssh_exec() {
    case "${MERV_TEST_MODE:-}" in
        success)
            MERV_SSH_LAST_REASON=""
            MERV_SSH_LAST_DETAIL=""
            printf '%s' connected
            return 0
            ;;
        wrong-output)
            MERV_SSH_LAST_REASON=""
            MERV_SSH_LAST_DETAIL=""
            printf '%s' unexpected-output
            return 0
            ;;
        auth-failure)
            MERV_SSH_LAST_REASON=auth-failed
            MERV_SSH_LAST_DETAIL='NODE1 public-key authentication failed'
            return 5
            ;;
        host-key-failure)
            MERV_SSH_LAST_REASON=host-key-mismatch
            MERV_SSH_LAST_DETAIL='NODE1 pinned host key did not match'
            return 6
            ;;
        session-timeout)
            MERV_SSH_LAST_REASON=session-timeout
            MERV_SSH_LAST_DETAIL='NODE1 command/session timed out'
            return 5
            ;;
        *)
            return 99
            ;;
    esac
}

run_case() {
    _case_name="$1"
    _expected_rc="$2"
    _expected_reason="$3"
    _expected_detail="$4"
    MERV_TEST_MODE="$_case_name"
    export MERV_TEST_MODE
    if merv_ssh_test 1 192.0.2.1 >/dev/null 2>&1; then
        _actual_rc=0
    else
        _actual_rc=$?
    fi
    assert_eq "$_actual_rc" "$_expected_rc" "$_case_name exit status"
    assert_eq "$MERV_SSH_LAST_REASON" "$_expected_reason" "$_case_name reason"
    assert_eq "$MERV_SSH_LAST_DETAIL" "$_expected_detail" "$_case_name detail"
    assert_no_private_output "$_case_name"
}

run_case success 0 "" ""
run_case auth-failure 5 auth-failed 'NODE1 public-key authentication failed'
run_case host-key-failure 6 host-key-mismatch 'NODE1 pinned host key did not match'
run_case session-timeout 5 session-timeout 'NODE1 command/session timed out'
run_case wrong-output 1 "" ""

# The node-job writer's terminal producer output has a byte-bounded sanitizer,
# private namespace/record modes, and removes its publication scratch files.
LC_ALL=C
export LC_ALL
LONG_DIAGNOSTIC=$(awk 'BEGIN { for (i = 0; i < 600; i++) printf "X" }')
MERV_SSH_DIAGNOSTIC_CONTEXT="$LONG_DIAGNOSTIC"
MERV_SSH_LAST_REASON="$LONG_DIAGNOSTIC"
MERV_SSH_FORENSIC_SEQ=0
if ! merv_ssh_write_forensic 1 192.0.2.1 192.0.2.1 fixture 22 255 failure "$LONG_DIAGNOSTIC"; then
    fail 'forensic writer did not publish synthetic node-job evidence'
fi
FORENSIC_ROOT="$JOB_ROOT/ssh_forensics"
FORENSIC_FILE="$MERV_SSH_FORENSIC_LAST_FILE"
[ -d "$FORENSIC_ROOT" ] && [ ! -L "$FORENSIC_ROOT" ] || fail 'forensic root is not a real directory'
[ "$(LC_ALL=C ls -ldn "$FORENSIC_ROOT" | awk 'NR == 1 {print $1}')" = drwx------ ] || fail 'forensic root mode'
[ "$(LC_ALL=C ls -ldn "$FORENSIC_FILE" | awk 'NR == 1 {print $1}')" = -rw------- ] || fail 'forensic record mode'
assert_eq "${FORENSIC_FILE##*/}" "attempt.$$.1.log" 'forensic final filename grammar'
assert_eq "$(awk -F= '/^phase=/ {print length(substr($0,7))}' "$FORENSIC_FILE")" 512 'forensic field byte bound'
[ -f "$FORENSIC_FILE" ] && [ ! -L "$FORENSIC_FILE" ] && [ -r "$FORENSIC_FILE" ] || fail 'forensic record is not a readable regular file'
FORENSIC_SIZE=$(wc -c < "$FORENSIC_FILE" | tr -d '[:space:]')
case "$FORENSIC_SIZE" in ''|*[!0-9]*) fail 'forensic record size unreadable' ;; esac
[ "$FORENSIC_SIZE" -le 14811 ] || fail 'forensic record exceeded the source-derived maximum'
[ ! -e "$FORENSIC_ROOT/.attempt.$$.1.tmp" ] && [ ! -e "$FORENSIC_ROOT/.list.$$" ] || fail 'forensic publication scratch remained'
printf 'PASS ssh forensic producer grammar, modes, byte bound, and cleanup\n'

printf 'PASS ssh test diagnostic contract\n'
