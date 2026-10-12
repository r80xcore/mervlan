#!/bin/sh
# Deterministic continuation bind/activation and post-bind identity contract.

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.continuation-bind.$$"
umask 077
mkdir -p "$TEST_ROOT/locks" || exit 1
chmod 700 "$TEST_ROOT" "$TEST_ROOT/locks" || exit 1

CHILD_PID=
PARENT_NONCE=
cleanup() {
  [ -z "$CHILD_PID" ] || kill "$CHILD_PID" 2>/dev/null || :
  [ -z "$CHILD_PID" ] || wait "$CHILD_PID" 2>/dev/null || :
  [ -z "$PARENT_NONCE" ] || merv_owner_lock_release "$PARENT_LOCK" \
    "$PARENT_NONCE" >/dev/null 2>&1 || :
  rm -rf "$TEST_ROOT"
}
trap cleanup 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

export MERV_BASE="$BASE_DIR"
. "$BASE_DIR/settings/lib_selftest_context.sh" || fail context-library
merv_selftest_context_create "$TEST_ROOT" || fail context-create
MERV_CONTINUATION_ROOT="$TEST_ROOT/continuations"
MERV_OWNER_LOCK_PROC_ROOT=/proc
export MERV_CONTINUATION_ROOT MERV_OWNER_LOCK_PROC_ROOT
. "$BASE_DIR/settings/lib_owner_lock.sh" || fail owner-library
. "$BASE_DIR/settings/lib_continuation.sh" || fail continuation-library

PARENT_LOCK="$TEST_ROOT/locks/parent.lock"
merv_owner_lock_acquire "$PARENT_LOCK" 0 0 continuation-bind-test || fail parent-acquire
PARENT_START=$MERV_LOCK_START
PARENT_NONCE=$MERV_LOCK_NONCE
CASE_SEQ=0
HOOK_LEASE=
HOOK_GO=
HOOK_ACK=
HOOK_PID=
HOOK_START=
HOOK_ACTION=none
HOOK_DONE=0

publish_case() {
  CASE_NAME=$1
  CASE_SEQ=$((CASE_SEQ + 1))
  merv_continuation_publish_pending "$CASE_NAME" "$CASE_NAME.run" runtime \
    "$PARENT_LOCK" "$$" "$PARENT_START" "$PARENT_NONCE" || fail "$CASE_NAME-publish"
  CASE_TOKEN=$MERV_CONTINUATION_TOKEN
  CASE_LEASE=$MERV_CONTINUATION_PATH
  MERV_CONTINUATION_TOKEN=$CASE_TOKEN
  export MERV_CONTINUATION_TOKEN
  CASE_GO="$TEST_ROOT/go.$CASE_SEQ"
  CASE_ACK="$TEST_ROOT/ack.$CASE_SEQ"
  HOOK_LEASE=$CASE_LEASE
  HOOK_GO=$CASE_GO
  HOOK_ACK=$CASE_ACK
  HOOK_PID=
  HOOK_START=
  HOOK_ACTION=none
  HOOK_DONE=0
}

start_child() {
  _cbr_mode=$1
  sh -c '
    MERV_BASE=$1
    export MERV_BASE
    . "$MERV_BASE/settings/lib_owner_lock.sh" || exit 11
    . "$MERV_BASE/settings/lib_continuation.sh" || exit 12
    _cbr_tries=0
    while [ ! -f "$2" ]; do
      _cbr_tries=$((_cbr_tries + 1))
      [ "$_cbr_tries" -lt 5000000 ] || exit 13
    done
    merv_continuation_activate_wait "$4" || exit 14
    if [ "$5" = terminal ]; then
      merv_continuation_retire "$4" || exit 15
    fi
    printf "%s\n" "$5" > "$3" || exit 16
    [ "$5" = hold ] || exit 0
    exec sleep 60
  ' continuation-bind-child "$BASE_DIR" "$CASE_GO" "$CASE_ACK" \
    "$CASE_TOKEN" "$_cbr_mode" &
  CHILD_PID=$!
  CHILD_START=$(merv_identity_proc_start "$CHILD_PID" /proc 2>/dev/null || printf '')
  [ -n "$CHILD_START" ] || fail child-start
}

wait_child_ack() {
  _cbr_expected=$1
  _cbr_tries=0
  while [ ! -f "$CASE_ACK" ] && [ "$_cbr_tries" -lt 5000000 ]; do
    _cbr_tries=$((_cbr_tries + 1))
  done
  [ -f "$CASE_ACK" ] || fail child-ack-timeout
  [ "$(cat "$CASE_ACK")" = "$_cbr_expected" ] || fail child-ack-content
}

release_child() {
  : > "$CASE_GO"
  wait_child_ack "$1"
}

stop_and_retire_active() {
  _cbr_token=$1
  kill "$CHILD_PID" 2>/dev/null || fail child-stop
  wait "$CHILD_PID" 2>/dev/null || :
  CHILD_PID=
  merv_continuation_retire "$_cbr_token" || fail parent-retire
  merv_continuation_read "$CASE_LEASE" || fail terminal-read
  [ "$MERV_CONTINUATION_STATE" = terminal ] || fail terminal-state
}

rewrite_field() {
  _cbr_field=$1
  _cbr_value=$2
  _cbr_tmp="$HOOK_LEASE.fixture.$$"
  sed "s/^${_cbr_field}=.*/${_cbr_field}=${_cbr_value}/" \
    "$HOOK_LEASE" > "$_cbr_tmp" || return 1
  chmod 600 "$_cbr_tmp" || return 1
  command mv -f "$_cbr_tmp" "$HOOK_LEASE"
}

rewrite_parent_owner_nonce() {
  _cbr_nonce=$1
  merv_owner_v2_nonce_valid "$_cbr_nonce" || return 1
  merv_owner_v2_read "$PARENT_LOCK" || return 1
  [ "$_cbr_nonce" != "$MERV_OWNER_V2_NONCE" ] || return 1
  _cbr_owner="$PARENT_LOCK/owner"
  _cbr_tmp="$_cbr_owner.fixture.$$"
  sed "s/^owner_nonce=.*/owner_nonce=$_cbr_nonce/" \
    "$_cbr_owner" > "$_cbr_tmp" || return 1
  chmod 600 "$_cbr_tmp" || return 1
  command mv -f "$_cbr_tmp" "$_cbr_owner" || return 1
  merv_owner_v2_read "$PARENT_LOCK" || return 1
  [ "$MERV_OWNER_V2_NONCE" = "$_cbr_nonce" ]
}

rewrite_malformed() {
  _cbr_tmp="$HOOK_LEASE.fixture.$$"
  printf 'format=invalid\n' > "$_cbr_tmp" || return 1
  chmod 600 "$_cbr_tmp" || return 1
  command mv -f "$_cbr_tmp" "$HOOK_LEASE"
}

# This test-only mv wrapper pauses after the real atomic publication. The
# child sees the exact bound record and must finish its real transition before
# the parent bind function can perform its read-back.
mv() {
  if command mv "$@"; then
    _cbr_mv_rc=0
  else
    _cbr_mv_rc=$?
    return "$_cbr_mv_rc"
  fi
  if [ "${3:-}" = "$HOOK_LEASE" ] && [ "$HOOK_DONE" -eq 0 ] &&
     grep -Fqx "child_pid=$HOOK_PID" "$HOOK_LEASE" 2>/dev/null &&
     grep -Fqx "child_start_time=$HOOK_START" "$HOOK_LEASE" 2>/dev/null &&
     grep -Fqx 'state=pending' "$HOOK_LEASE" 2>/dev/null; then
    HOOK_DONE=1
    case "$HOOK_ACTION" in
      activate|terminal)
        : > "$HOOK_GO"
        _cbr_tries=0
        while [ ! -f "$HOOK_ACK" ] && [ "$_cbr_tries" -lt 5000000 ]; do
          _cbr_tries=$((_cbr_tries + 1))
        done
        [ -f "$HOOK_ACK" ] || return 1
        case "$HOOK_ACTION" in
          activate) _cbr_expected_ack=hold ;;
          terminal) _cbr_expected_ack=terminal ;;
        esac
        [ "$(cat "$HOOK_ACK")" = "$_cbr_expected_ack" ] || return 1
        ;;
      wrong-child-pid) rewrite_field child_pid "$$" &&
        rewrite_field child_start_time "$PARENT_START" || return 1 ;;
      wrong-child-start) rewrite_field child_start_time 1 || return 1 ;;
      foreign-token) rewrite_field lease_token foreign.token || return 1 ;;
      foreign-run) rewrite_field run_token foreign.run || return 1 ;;
      parent-nonce) rewrite_field parent_nonce changed.parent.nonce || return 1 ;;
      operation) rewrite_field operation changed-operation || return 1 ;;
      parent-owner-nonce)
        rewrite_parent_owner_nonce tampered.owner.nonce || return 1 ;;
      malformed) rewrite_malformed || return 1 ;;
      none) : ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# An unbound lease remains pending and blocks both activation and quiescence.
publish_case unbound
if (
  sleep() { :; }
  merv_continuation_activate_wait "$CASE_TOKEN"
); then
  fail unbound-activate-wait
fi
if merv_continuation_activate "$CASE_TOKEN"; then fail unbound-activate; fi
if merv_continuation_retire "$CASE_TOKEN"; then fail unbound-retire; fi
merv_continuation_read "$CASE_LEASE" || fail unbound-read
[ "$MERV_CONTINUATION_STATE:$MERV_CONTINUATION_CHILD_PID:$MERV_CONTINUATION_CHILD_START" = \
  pending:none:none ] || fail unbound-state-changed
[ "$(merv_continuation_quiescence)" = busy ] || fail unbound-not-busy
pass 'unbound pending lease cannot activate or retire and remains visible to Q'

# Ordinary bind: hold activation behind an explicit marker until bind returns.
publish_case ordinary
start_child hold
if merv_continuation_bind_child "$CASE_TOKEN" "$CHILD_PID" "$CHILD_START"; then :; else
  fail ordinary-bind
fi
release_child hold
merv_continuation_read "$CASE_LEASE" || fail ordinary-active-read
[ "$MERV_CONTINUATION_STATE" = active ] &&
  [ "$MERV_CONTINUATION_CHILD_PID" = "$CHILD_PID" ] &&
  [ "$MERV_CONTINUATION_CHILD_START" = "$CHILD_START" ] || fail ordinary-active-identity
stop_and_retire_active "$CASE_TOKEN"
pass 'ordinary parent bind accepts its pending read-back and child activation'

# Force activation after the atomic bound write and before the parent's read.
publish_case activation-race
start_child hold
HOOK_PID=$CHILD_PID
HOOK_START=$CHILD_START
HOOK_ACTION=activate
if merv_continuation_bind_child "$CASE_TOKEN" "$CHILD_PID" "$CHILD_START"; then :; else
  fail race-bind-rejected
fi
[ "$HOOK_DONE" -eq 1 ] || fail race-hook-not-run
merv_continuation_read "$CASE_LEASE" || fail race-active-read
[ "$MERV_CONTINUATION_STATE" = active ] &&
  [ "$MERV_CONTINUATION_CHILD_PID" = "$CHILD_PID" ] &&
  [ "$MERV_CONTINUATION_CHILD_START" = "$CHILD_START" ] || fail race-active-identity
stop_and_retire_active "$CASE_TOKEN"
pass 'child activation winning the post-write race is accepted for the exact lease'

assert_readback_rejected() {
  _cbr_name=$1
  _cbr_action=$2
  publish_case "reject-$_cbr_name"
  start_child hold
  HOOK_PID=$CHILD_PID
  HOOK_START=$CHILD_START
  HOOK_ACTION=$_cbr_action
  if merv_continuation_bind_child "$CASE_TOKEN" "$CHILD_PID" "$CHILD_START"; then
    fail "$_cbr_name-accepted"
  fi
  [ "$HOOK_DONE" -eq 1 ] || fail "$_cbr_name-hook-not-run"
  kill "$CHILD_PID" 2>/dev/null || :
  wait "$CHILD_PID" 2>/dev/null || :
  CHILD_PID=
  pass "post-write $_cbr_name mismatch remains fail-closed"
}

assert_readback_rejected wrong-child-pid wrong-child-pid
assert_readback_rejected wrong-child-start wrong-child-start
assert_readback_rejected foreign-token foreign-token
assert_readback_rejected foreign-run foreign-run
assert_readback_rejected parent-nonce-mutation parent-nonce
assert_readback_rejected operation-mutation operation
assert_readback_rejected malformed-lease malformed

# A parent mismatch is rejected before the child record can be bound.
publish_case wrong-parent
rewrite_field parent_pid 99999999 || fail wrong-parent-pid-fixture
rewrite_field parent_start_time 1 || fail wrong-parent-start-fixture
start_child hold
if merv_continuation_bind_child "$CASE_TOKEN" "$CHILD_PID" "$CHILD_START"; then
  fail wrong-parent-accepted
fi
kill "$CHILD_PID" 2>/dev/null || :
wait "$CHILD_PID" 2>/dev/null || :
CHILD_PID=
pass 'lease bound to a different parent is rejected'

# A live child other than the recorded child cannot consume an active lease.
publish_case active-other-child
start_child hold
merv_continuation_bind_child "$CASE_TOKEN" "$CHILD_PID" "$CHILD_START" || fail active-child-bind
release_child hold
sh -c '
  MERV_BASE=$1
  export MERV_BASE
  . "$MERV_BASE/settings/lib_owner_lock.sh" || exit 11
  . "$MERV_BASE/settings/lib_continuation.sh" || exit 12
  merv_continuation_activate_wait "$2" && exit 21
  exit 0
' other-continuation-child "$BASE_DIR" "$CASE_TOKEN" || fail active-other-child-accepted
stop_and_retire_active "$CASE_TOKEN"
pass 'active lease cannot be activated by a different child'

# The public lifecycle permits the exact child to finish before parent
# read-back. Its authenticated active -> terminal transition is still bind
# success when every immutable lease identity matches.
publish_case terminal-race
start_child terminal
HOOK_PID=$CHILD_PID
HOOK_START=$CHILD_START
HOOK_ACTION=terminal
merv_continuation_bind_child "$CASE_TOKEN" "$CHILD_PID" "$CHILD_START" || fail terminal-race-bind
[ "$HOOK_DONE" -eq 1 ] || fail terminal-race-hook
wait "$CHILD_PID" || fail terminal-child-wait
CHILD_PID=
merv_continuation_read "$CASE_LEASE" || fail terminal-race-read
[ "$MERV_CONTINUATION_STATE" = terminal ] &&
  [ "$MERV_CONTINUATION_TOKEN" = "$CASE_TOKEN" ] &&
  [ "$MERV_CONTINUATION_OPERATION" = terminal-race ] &&
  [ "$MERV_CONTINUATION_RUN_TOKEN" = terminal-race.run ] &&
  [ "$MERV_CONTINUATION_PARENT_PID" = "$$" ] &&
  [ "$MERV_CONTINUATION_PARENT_START" = "$PARENT_START" ] &&
  [ "$MERV_CONTINUATION_PARENT_NONCE" = "$PARENT_NONCE" ] &&
  [ "$MERV_CONTINUATION_CHILD_PID" = "$HOOK_PID" ] &&
  [ "$MERV_CONTINUATION_CHILD_START" = "$HOOK_START" ] || fail terminal-race-identity
pass 'exact child terminal transition before read-back is accepted with full identity'

# Revoke only the isolated parent fixture after the exact bound lease is
# atomically visible. The read-back remains otherwise exact; bind must fail at
# its final owner reauthentication, so removing that check makes this test fail.
publish_case final-parent-reauth
start_child hold
HOOK_PID=$CHILD_PID
HOOK_START=$CHILD_START
HOOK_ACTION=parent-owner-nonce
merv_owner_v2_matches "$PARENT_LOCK" "$$" "$PARENT_START" \
  "$PARENT_NONCE" /proc || fail final-parent-initial-auth
[ "$(merv_continuation_process_state "$CHILD_PID" "$CHILD_START")" = live ] ||
  fail final-parent-child-not-live
if merv_continuation_bind_child "$CASE_TOKEN" "$CHILD_PID" "$CHILD_START"; then
  fail final-parent-reauth-accepted
fi
[ "$HOOK_DONE" -eq 1 ] || fail final-parent-reauth-hook
merv_continuation_read "$CASE_LEASE" || fail final-parent-reauth-lease-read
[ "$MERV_CONTINUATION_STATE:$MERV_CONTINUATION_TOKEN:$MERV_CONTINUATION_OPERATION:$MERV_CONTINUATION_RUN_TOKEN" = \
  "pending:$CASE_TOKEN:final-parent-reauth:final-parent-reauth.run" ] &&
  [ "$MERV_CONTINUATION_PARENT_PID" = "$$" ] &&
  [ "$MERV_CONTINUATION_PARENT_START" = "$PARENT_START" ] &&
  [ "$MERV_CONTINUATION_PARENT_NONCE" = "$PARENT_NONCE" ] &&
  [ "$MERV_CONTINUATION_CHILD_PID" = "$CHILD_PID" ] &&
  [ "$MERV_CONTINUATION_CHILD_START" = "$CHILD_START" ] ||
  fail final-parent-reauth-lease-identity
kill "$CHILD_PID" 2>/dev/null || fail final-parent-reauth-child-stop
wait "$CHILD_PID" 2>/dev/null || :
CHILD_PID=
if merv_owner_v2_matches "$PARENT_LOCK" "$$" "$PARENT_START" \
     "$PARENT_NONCE" /proc; then
  fail final-parent-reauth-owner-still-authenticated
fi
rewrite_parent_owner_nonce "$PARENT_NONCE" || fail final-parent-owner-restore
merv_owner_v2_matches "$PARENT_LOCK" "$$" "$PARENT_START" \
  "$PARENT_NONCE" /proc || fail final-parent-owner-reauth
pass 'final parent reauthentication rejects owner loss after exact bind publication'

merv_owner_lock_release "$PARENT_LOCK" "$PARENT_NONCE" || fail parent-release
PARENT_NONCE=
printf '%s\n' 'CONTINUATION_BIND_RACE_OK'
