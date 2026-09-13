#!/bin/sh
# P1 deterministic contract: effective node-operation width, Save validation,
# local-only Save classification, and Sync/Apply resolver wiring.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
TMP_ROOT="${TMPDIR:-/tmp}/mervlan-node-parallelism.$$"
umask 077
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' 0 1 2 3 15

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
require() { grep -Fq -- "$1" "$2" || fail "$3"; }

# Load the production resolver with only its dependency contracts stubbed.  In
# particular, do not source var_settings.sh here: its router paths are
# deliberately readonly.  This leaves SETTINGS_FILE writable for each case
# while executing the actual lib_node_jobs.sh implementation.
MERV_BASE="$ROOT"
TMPDIR="$TMP_ROOT"
MERV_MAX_NODES=10
SETTINGS_FILE="$TMP_ROOT/settings.json"
VAR_SETTINGS_LOADED=1
LIB_IDENTITY_LOADED=1
LIB_MERVQT_LOADED=1
LIB_JSON_LOADED=""
MERV_NODE_PARALLELISM=""
export MERV_BASE TMPDIR MERV_MAX_NODES SETTINGS_FILE
export VAR_SETTINGS_LOADED LIB_IDENTITY_LOADED LIB_MERVQT_LOADED
export LIB_JSON_LOADED MERV_NODE_PARALLELISM

merv_is_valid_node_id() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le "$MERV_MAX_NODES" ] 2>/dev/null
}
merv_process_identity_matches() { return 1; }
merv_identity_current_start() { printf '1\n'; }
merv_identity_nonce_next() { MERV_IDENTITY_NONCE='test.1'; return 0; }
warn() { :; }

. "$ROOT/settings/lib_json.sh"
. "$ROOT/settings/lib_node_jobs.sh"

assert_resolver() {
    _expected="$1"
    _label="$2"
    _actual=$(mnj_effective_parallelism)
    [ "$_actual" = "$_expected" ] || fail "$_label (got=$_actual expected=$_expected)"
}

# Missing persisted setting retains the legacy default of two.
printf '%s\n' '{' '  "General": {' '    "AUTO_SYNC_SETTINGS": "1"' '  }' '}' > "$SETTINGS_FILE"
unset MERV_NODE_PARALLELISM
assert_resolver 2 'missing NODE_PARALLELISM uses default 2'
pass 'missing persisted setting resolves to 2'

# Every persisted value in the allowed range is effective when no override is
# present.  This also proves the structured General reader, not a root-key
# fallback, is used by the resolver.
for _value in 1 2 3 4 5; do
    printf '%s\n' '{' '  "General": {' "    \"NODE_PARALLELISM\": \"$_value\"" '  }' '}' > "$SETTINGS_FILE"
    unset MERV_NODE_PARALLELISM
    assert_resolver "$_value" "persisted NODE_PARALLELISM=$_value"
done
pass 'persisted NODE_PARALLELISM 1..5 resolves exactly'

# Runtime override takes precedence over persisted settings, and malformed
# values fail closed to one rather than inheriting the persisted width.
printf '%s\n' '{' '  "General": {' '    "NODE_PARALLELISM": "2"' '  }' '}' > "$SETTINGS_FILE"
MERV_NODE_PARALLELISM=''
export MERV_NODE_PARALLELISM
assert_resolver 2 'empty runtime override behaves as absent'
for _value in 1 2 3 4 5; do
    MERV_NODE_PARALLELISM="$_value"
    export MERV_NODE_PARALLELISM
    assert_resolver "$_value" "runtime override NODE_PARALLELISM=$_value"
done
for _value in 0 6 2x malformed; do
    MERV_NODE_PARALLELISM="$_value"
    export MERV_NODE_PARALLELISM
    assert_resolver 1 "malformed runtime override '$_value'"
done
pass 'runtime override wins and malformed override fails closed to 1'

# Malformed persisted values are also fail-closed.  Explicit call arguments
# remain a supported seam for wrappers/tests and use the same bound.
unset MERV_NODE_PARALLELISM
printf '%s\n' '{' '  "General": {' '    "NODE_PARALLELISM": "invalid"' '  }' '}' > "$SETTINGS_FILE"
assert_resolver 1 'malformed persisted NODE_PARALLELISM'
[ "$(mnj_effective_parallelism 4)" = 4 ] || fail 'explicit parallelism 4 rejected'
[ "$(mnj_effective_parallelism 9)" = 1 ] || fail 'explicit malformed parallelism did not fail closed'
pass 'malformed persisted and explicit values fail closed'

# Save's validator is extracted verbatim from the production script.  This
# avoids executing the full router Save transaction while still testing the
# exact validation function and all accepted/rejected values.
SAVE_FILE="$ROOT/functions/save_settings.sh"
VALIDATOR="$TMP_ROOT/save-validator.sh"
sed -n '/^validate_node_parallelism_kv() {/,/^}/p' "$SAVE_FILE" > "$VALIDATOR"
[ -s "$VALIDATOR" ] || fail 'Save NODE_PARALLELISM validator extraction is empty'
. "$VALIDATOR"
for _value in 1 2 3 4 5; do
    validate_node_parallelism_kv NODE_PARALLELISM "$_value" || fail "Save rejected valid NODE_PARALLELISM=$_value"
done
for _value in '' 0 6 -1 2x malformed; do
    if validate_node_parallelism_kv NODE_PARALLELISM "$_value"; then
        fail "Save accepted invalid NODE_PARALLELISM=$_value"
    fi
done
validate_node_parallelism_kv OTHER_SETTING malformed || fail 'Save validator rejected unrelated setting'
pass 'Save accepts only NODE_PARALLELISM 1..5'

# The valid path is structured under General and the invalid gate runs before
# the candidate commit.  Verify the production writer and ordering remain
# coupled to the tested validator.
require 'NODE_PARALLELISM; do' "$SAVE_FILE" 'Save does not include NODE_PARALLELISM in General seeding'
require 'json_set_section_value "General" "$_sg_key" "$_sg_value"' "$SAVE_FILE" 'Save does not persist General setting through structured writer'
require 'validate_node_parallelism_kv' "$SAVE_FILE" 'Save validator is not present'
_validator_line=$(grep -n '^validate_node_parallelism_kv()' "$SAVE_FILE" | cut -d: -f1)
_commit_line=$(grep -n 'mv -f "\${_save_candidate}" "\${SETTINGS_FILE}"' "$SAVE_FILE" | head -n 1 | cut -d: -f1)
[ -n "$_validator_line" ] && [ -n "$_commit_line" ] && [ "$_validator_line" -lt "$_commit_line" ] || fail 'Save validates NODE_PARALLELISM after commit'
require 'skipped-local-only' "$SAVE_FILE" 'Save local-only node-sync classification is missing'
require 'only main-router/WebUI-local settings changed' "$SAVE_FILE" 'Save local-only digest classification is missing'
pass 'Save valid persistence and local-only classification are wired before commit'

# Sync and all three node-operation phases of Apply omit a hard-coded width;
# the common pool entry point must resolve each call against persisted/override
# state.  Keep these assertions source-level because invoking either action is
# a live mutation boundary.
NODE_JOBS="$ROOT/settings/lib_node_jobs.sh"
require '_mnj_run_par=$(mnj_effective_parallelism' "$NODE_JOBS" 'pool does not call effective resolver before shared-state publication'
for _file in "$ROOT/functions/sync_nodes.sh" "$ROOT/functions/execute_nodes.sh"; do
    require 'mnj_pool_run' "$_file" "${_file##*/} does not use bounded pool"
    require '"${MERV_NODE_PARALLELISM:-}"' "$_file" "${_file##*/} hard-codes a parallelism default"
done
_sync_calls=$(grep -c 'mnj_pool_run.*sync' "$ROOT/functions/sync_nodes.sh")
_apply_calls=$(grep -c 'mnj_pool_run.*prepare\|mnj_pool_run.*launch\|mnj_pool_run.*status' "$ROOT/functions/execute_nodes.sh")
[ "$_sync_calls" -ge 1 ] || fail 'Sync pool call missing'
[ "$_apply_calls" -ge 3 ] || fail 'Apply prepare/launch/status pool calls missing'
pass 'Sync and Apply route through the effective resolver seam'

# P1 shell syntax gate for the changed production shell and maintained router
# test harness itself.
for _file in \
    "$ROOT/settings/lib_node_jobs.sh" \
    "$ROOT/functions/save_settings.sh" \
    "$ROOT/functions/sync_nodes.sh" \
    "$ROOT/functions/execute_nodes.sh" \
    "$ROOT/dev-tools/tests/router/mervlan_selftest.sh"; do
    sh -n "$_file" || fail "shell syntax failed: ${_file##*/}"
done
pass 'P1 production and router-test shell syntax'

printf 'NODE_PARALLELISM_CONTRACT_OK\n'
