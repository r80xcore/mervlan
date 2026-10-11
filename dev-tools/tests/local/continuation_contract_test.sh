#!/bin/sh
# Strict continuation publication, activation, retirement, and Q inventory.

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.continuation.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
chmod 700 "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

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
merv_owner_lock_acquire "$PARENT_LOCK" 0 0 test-parent || fail parent-acquire
PARENT_START=$MERV_LOCK_START
PARENT_NONCE=$MERV_LOCK_NONCE

[ "$(merv_continuation_quiescence)" = idle ] || fail empty-root-idle
merv_continuation_publish_pending test-child run.one runtime "$PARENT_LOCK" \
  "$$" "$PARENT_START" "$PARENT_NONCE" || fail pending-publication
LEASE_TOKEN=$MERV_CONTINUATION_TOKEN
LEASE_FILE=$MERV_CONTINUATION_PATH
[ -f "$LEASE_FILE" ] && [ ! -L "$LEASE_FILE" ] || fail pending-file
[ "$(LC_ALL=C ls -ldn "$LEASE_FILE" | awk '{print $1}')" = -rw------- ] || fail lease-mode
merv_continuation_read "$LEASE_FILE" || fail pending-parse
[ "$MERV_CONTINUATION_STATE" = pending ] || fail pending-state
[ "$(merv_continuation_quiescence)" = busy ] || fail pending-q-busy
if merv_continuation_retire "$LEASE_TOKEN"; then fail pending-retired; fi
pass 'pending lease is atomically visible and blocks Q before spawn'

sh -c '
  MERV_BASE="$1"
  . "$MERV_BASE/settings/lib_owner_lock.sh" || exit 11
  . "$MERV_BASE/settings/lib_continuation.sh" || exit 12
  merv_continuation_activate_wait "$2" || exit 13
  exec sleep 20
' sh "$BASE_DIR" "$LEASE_TOKEN" &
CHILD_PID=$!
CHILD_START=
_wait=0
while [ "$_wait" -lt 5 ]; do
  CHILD_START=$(merv_identity_proc_start "$CHILD_PID" /proc 2>/dev/null || printf '')
  [ -n "$CHILD_START" ] && break
  sleep 1
  _wait=$((_wait + 1))
done
[ -n "$CHILD_START" ] || { kill "$CHILD_PID" 2>/dev/null || :; wait "$CHILD_PID" 2>/dev/null || :; fail child-start; }
merv_continuation_bind_child "$LEASE_TOKEN" "$CHILD_PID" "$CHILD_START" || {
  kill "$CHILD_PID" 2>/dev/null || :
  wait "$CHILD_PID" 2>/dev/null || :
  fail child-bind
}
_wait=0
while [ "$_wait" -lt 5 ]; do
  if merv_continuation_read "$LEASE_FILE" 2>/dev/null &&
     [ "$MERV_CONTINUATION_STATE" = active ] &&
     [ "$MERV_CONTINUATION_CHILD_PID" = "$CHILD_PID" ]; then
    break
  fi
  sleep 1
  _wait=$((_wait + 1))
done
[ "$(merv_continuation_classify_file "$LEASE_FILE")" = active ] || {
  kill "$CHILD_PID" 2>/dev/null || :
  wait "$CHILD_PID" 2>/dev/null || :
  fail active-classification
}
[ "$(merv_continuation_quiescence)" = busy ] || {
  kill "$CHILD_PID" 2>/dev/null || :
  wait "$CHILD_PID" 2>/dev/null || :
  fail active-q-busy
}
cp "$LEASE_FILE" "$TEST_ROOT/active.saved" || fail save-active
pass 'child authenticates pending lease and activates with PID/start identity'

# A dead parent with an active child still blocks; parent liveness is not used
# to retire a continuation.
sed 's/^parent_pid=.*/parent_pid=99999999/; s/^parent_start_time=.*/parent_start_time=1/' \
  "$LEASE_FILE" > "$TEST_ROOT/active.dead-parent" || fail dead-parent-fixture
chmod 600 "$TEST_ROOT/active.dead-parent" || fail dead-parent-mode
mv -f "$TEST_ROOT/active.dead-parent" "$LEASE_FILE" || fail dead-parent-publish
[ "$(merv_continuation_quiescence)" = busy ] || fail dead-parent-active-idle
cp "$TEST_ROOT/active.saved" "$LEASE_FILE" || fail parent-restore
pass 'dead parent plus active child remains busy'

kill "$CHILD_PID" 2>/dev/null || fail child-kill
wait "$CHILD_PID" 2>/dev/null || :
merv_continuation_retire "$LEASE_TOKEN" || fail terminal-retirement
[ "$(merv_continuation_classify_file "$LEASE_FILE")" = terminal ] || fail terminal-classification
[ "$(merv_continuation_quiescence)" = idle ] || fail terminal-q-idle
cp "$LEASE_FILE" "$TEST_ROOT/terminal.saved" || fail save-terminal
pass 'parent retires only after child is terminal and Q observes idle'

# Unknown keys, malformed content, and symlink records all fail closed.
printf '%s\n' malformed > "$LEASE_FILE"
chmod 600 "$LEASE_FILE"
[ "$(merv_continuation_quiescence)" = blocking ] || fail malformed-blocks
cp "$TEST_ROOT/terminal.saved" "$LEASE_FILE" || fail restore-terminal
printf 'unknown=value\n' >> "$LEASE_FILE"
[ "$(merv_continuation_quiescence)" = blocking ] || fail unknown-key-blocks
cp "$TEST_ROOT/terminal.saved" "$LEASE_FILE" || fail restore-terminal-again
rm -f "$LEASE_FILE"
printf '%s\n' 'not a lease' > "$TEST_ROOT/bad"
chmod 600 "$TEST_ROOT/bad"
ln -s "$TEST_ROOT/bad" "$TEST_ROOT/continuations/foreign" || fail lease-symlink-create
[ "$(merv_continuation_quiescence)" = blocking ] || fail symlink-blocks
pass 'malformed, unknown, and symlink lease state fails closed'

merv_owner_lock_release "$PARENT_LOCK" "$PARENT_NONCE" || fail parent-release
printf '%s\n' 'CONTINUATION_CONTRACT_OK'
