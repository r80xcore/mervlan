#!/bin/sh
# Execute's target capability check is read-only and hashes the full cohort.

set -eu
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
SOURCE="$BASE_DIR/functions/execute_nodes.sh"
SYNC_SOURCE="$BASE_DIR/functions/sync_nodes.sh"
TEST_ROOT="/tmp/mervlan_tmp/selftest.execute-guard.$$"
TARGET="$TEST_ROOT/nodefs/mervlan"
_last_remote_command=

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup 0 1 2 3 15

umask 077
mkdir -p "$TEST_ROOT/nodefs" || fail fixture-root
chmod 700 "$TEST_ROOT" "$TEST_ROOT/nodefs" || fail fixture-mode
. "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || fail test-context-helper
merv_test_context_enable "$BASE_DIR" "$TEST_ROOT" || fail authenticate-selftest-context
MERV_NODE_GUARD_TEST_ROOT=$TARGET
export MERV_NODE_GUARD_TEST_ROOT

EXEC_NODE_GUARD_FILES=$(awk '
  $0 == "EXEC_NODE_GUARD_FILES=\"" { inside=1; next }
  inside && $0 == "\"" { exit }
  inside { printf "%s ", $1 }
' "$SOURCE")
[ -n "$EXEC_NODE_GUARD_FILES" ] || fail 'Execute capability list missing'
SYNC_RUNTIME_FILES=$(awk '
  $0 == "FILES_TO_COPY=\"" { inside=1; next }
  inside && $0 == "\"" { exit }
  inside { for (i=1; i<=NF; i++) printf "%s ", $i }
' "$SYNC_SOURCE")
[ -n "$SYNC_RUNTIME_FILES" ] || fail 'Sync runtime manifest missing'
for _required in $EXEC_NODE_GUARD_FILES; do
    case " $SYNC_RUNTIME_FILES " in
      *" $_required "*) ;;
      *) fail "Execute requires $_required, which full Sync does not deploy" ;;
    esac
done
MERV_BASE=$BASE_DIR
eval "$(sed -n '/^merv_ssh_digest()/,/^}/p' "$BASE_DIR/settings/lib_ssh.sh")"
eval "$(sed -n '/^execute_node_guard_cohort_check()/,/^}/p' "$SOURCE")"

merv_ssh_shell_quote_word() {
    _q=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$_q"
}

TARGET_MUTATION_CALLS=0
merv_ssh_node_mutate_exec() { TARGET_MUTATION_CALLS=$((TARGET_MUTATION_CALLS + 1)); return 1; }
merv_ssh_node_mutate_stream() { TARGET_MUTATION_CALLS=$((TARGET_MUTATION_CALLS + 1)); return 1; }
merv_ssh_exec() {
    printf '%s\n' "$3" > "$TEST_ROOT/last-command"
    sh -c "$3"
}

# An unsynced target has no cohort. The exact read-only remote check fails and
# no mutation dispatcher is called.
mkdir -p "$TARGET" || fail target-tree
if execute_node_guard_cohort_check 1 192.0.2.1; then
    fail 'Execute accepted an unsynced node'
fi
[ "$TARGET_MUTATION_CALLS" -eq 0 ] || fail 'unsynced-node check invoked a target mutation helper'
pass 'unsynced node is refused by a real read-only capability check'

# A partially upgraded node is also refused; only a complete exact generation
# passes. Populate it from the actual full-Sync runtime manifest without adding
# any Execute-only prerequisites.
for _rel in $SYNC_RUNTIME_FILES; do
    _file="$BASE_DIR/$_rel"
    _dst="$TARGET/$_rel"
    mkdir -p "${_dst%/*}" || fail "target-dir-$_rel"
    cp "$_file" "$_dst" || fail "target-copy-$_rel"
done
rm -f "$TARGET/functions/mervlan_node_runner.sh" || fail partial-cohort
if execute_node_guard_cohort_check 1 192.0.2.1; then
    fail 'Execute accepted a partially upgraded node'
fi
[ "$TARGET_MUTATION_CALLS" -eq 0 ] || fail 'partial-cohort check invoked a target mutation helper'
cp "$BASE_DIR/functions/mervlan_node_runner.sh" "$TARGET/functions/mervlan_node_runner.sh" || fail restore-runner
mv "$TARGET/settings/lib_mervqt.sh" "$TEST_ROOT/lib_mervqt.saved" || fail remove-quiesce-dependency
if execute_node_guard_cohort_check 1 192.0.2.1; then
    fail 'Execute accepted a node missing its Q safety dependency'
fi
mv "$TEST_ROOT/lib_mervqt.saved" "$TARGET/settings/lib_mervqt.sh" || fail restore-quiesce-dependency
execute_node_guard_cohort_check 1 192.0.2.1 || fail 'NODE produced from full Sync manifest was refused'
[ "$TARGET_MUTATION_CALLS" -eq 0 ] || fail 'capability success invoked a target mutation helper'
pass 'NODE produced from full Sync manifest passes exact Execute cohort digest checks'

printf '%s\n' tampered >> "$TARGET/settings/lib_mutation_admission.sh" || fail tamper
if execute_node_guard_cohort_check 1 192.0.2.1; then
    fail 'Execute accepted a tampered target cohort'
fi
[ "$TARGET_MUTATION_CALLS" -eq 0 ] || fail 'tampered-cohort check invoked a target mutation helper'
pass 'tampered target cohort is refused before mutation'

# A hostile ambient alternate destination is ignored outside the authenticated
# test seam; the generated production check remains pinned to the canonical
# installed tree.
unset MERVLAN_SELFTEST_CONTEXT
if execute_node_guard_cohort_check 1 192.0.2.1; then
    fail 'ambient alternate target root redirected production capability check'
fi
_last_remote_command=$(cat "$TEST_ROOT/last-command")
case "$_last_remote_command" in *"_base='/jffs/addons/mervlan'"*) ;; *) fail 'production target root was not canonical' ;; esac
[ "$TARGET_MUTATION_CALLS" -eq 0 ] || fail 'canonicalization check invoked a target mutation helper'
pass 'ambient alternate target root cannot redirect production capability authority'

printf '%s\n' 'EXEC_NODE_GUARD_COHORT_OK'
