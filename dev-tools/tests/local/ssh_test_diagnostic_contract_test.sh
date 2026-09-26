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

printf 'PASS ssh test diagnostic contract\n'
