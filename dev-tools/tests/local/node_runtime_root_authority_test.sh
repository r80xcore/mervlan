#!/bin/sh
# Production node job/run inventory stays in Q's canonical runtime roots.

set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.node-runtime-roots.$$"
umask 077
mkdir -p "$TEST_ROOT" || exit 1
chmod 700 "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

. "$TEST_DIR/selftest_context.sh"
MERV_BASE=$BASE_DIR
export MERV_BASE
. "$BASE_DIR/settings/lib_selftest_context.sh"

if (
  unset MERVLAN_SELFTEST_CONTEXT
  MERV_BASE=$BASE_DIR
  unset VAR_SETTINGS_LOADED LIB_NODE_JOBS_LOADED LIB_SELFTEST_CONTEXT_LOADED
  . "$BASE_DIR/settings/lib_node_jobs.sh" || exit 10
  mnj_root_valid "$TEST_ROOT/node_jobs"
); then
  printf '%s\n' 'FAIL: ambient node-job root accepted without explicit test context' >&2
  exit 1
fi

merv_test_context_enable "$BASE_DIR" "$TEST_ROOT" || exit 1
unset VAR_SETTINGS_LOADED LIB_NODE_JOBS_LOADED
. "$BASE_DIR/settings/lib_node_jobs.sh" || exit 1
mnj_root_valid /tmp/mervlan_tmp/node_jobs || {
  printf '%s\n' 'FAIL: canonical production node-job root rejected' >&2
  exit 1
}
mnj_root_valid "$TEST_ROOT/node_jobs" || {
  printf '%s\n' 'FAIL: authenticated self-test node-job root rejected' >&2
  exit 1
}
mnj_job_dir "$TEST_ROOT/node_jobs" 1 run.one >/dev/null || {
  printf '%s\n' 'FAIL: authenticated self-test node-job path rejected' >&2
  exit 1
}
printf '%s\n' 'PASS: node-job roots require the canonical production namespace or authenticated self-test context'
printf '%s\n' 'NODE_RUNTIME_ROOT_AUTHORITY_OK'
