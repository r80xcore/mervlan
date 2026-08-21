#!/bin/sh
# Round 4 audit fixture: a failed expected-interface builder emits no pairs,
# and the MAC snapshot precondition treats that empty result as a vacuous pass.
# The production function is extracted into temporary state and /sys is
# virtualized; no runtime source or router/device state is changed.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.deep-audit-builder-empty.$$"
umask 077
mkdir -p "$TEST_ROOT/sysfs" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

extract_function() {
    _name="$1"
    _source="$2"
    _destination="$3"
    _occurrence="${4:-1}"
    awk -v function_name="$_name" -v wanted="$_occurrence" '
        { sub(/\r$/, "") }
        $0 ~ ("^" function_name "\\(\\)[[:space:]]*\\{") {
            candidate++
            if (candidate == wanted) active=1
        }
        active { print }
        active && $0 == "}" { exit }
    ' "$_source" > "$_destination" || return 1
    [ -s "$_destination" ]
}

RAW_FUNCTION="$TEST_ROOT/snapshot_preconditions.raw"
FUNCTION="$TEST_ROOT/snapshot_preconditions.sh"
extract_function merv_mac_snapshot_preconditions_ok \
    "$BASE_DIR/settings/mac_shield_snapshot.sh" "$RAW_FUNCTION" || \
    fail 'could not extract merv_mac_snapshot_preconditions_ok'
sed 's#/sys/class/net#${AUDIT_SYSFS}#g' "$RAW_FUNCTION" > "$FUNCTION" || exit 1

AUDIT_SYSFS="$TEST_ROOT/sysfs"
export AUDIT_SYSFS
WARN_TRACE="$TEST_ROOT/warnings.trace"
CONFIGURED_VAP='wl0.1'
CONFIGURED_VID=100
BUILDER_TRACE="$TEST_ROOT/builder.trace"
printf 'configured_vap=%s expected_vid=%s\n' "$CONFIGURED_VAP" "$CONFIGURED_VID" > "$TEST_ROOT/config"

warn() { printf 'warn: %s\n' "$*" >> "$WARN_TRACE"; }
. "$FUNCTION" || fail 'could not load extracted snapshot precondition function'

# Failure fixture: the builder has a configured VAP to report, but fails before
# emitting it.  The caller captures only empty stdout and ignores its rc.
merv_mac_build_expected_iface_vid() {
    : > "$BUILDER_TRACE"
    return 1
}
FAILED_PAIRS=$(merv_mac_build_expected_iface_vid 2>/dev/null)
FAILED_BUILDER_RC=$?
[ "$FAILED_BUILDER_RC" -ne 0 ] || fail 'failure fixture builder unexpectedly succeeded'
[ -z "$FAILED_PAIRS" ] || fail 'failure fixture builder emitted unexpected pairs'
if merv_mac_snapshot_preconditions_ok; then
    FAILED_PRECONDITION_RC=0
else
    FAILED_PRECONDITION_RC=$?
fi
[ "$FAILED_PRECONDITION_RC" -eq 0 ] || \
    fail "failed builder was not interpreted as empty/vacuous pass (rc=$FAILED_PRECONDITION_RC)"
[ -f "$BUILDER_TRACE" ] || fail 'snapshot precondition did not invoke the builder'

# Control fixture: a successful builder exposing the same unsettled VAP must
# fail the precondition, proving that only the builder failure disappears.
merv_mac_build_expected_iface_vid() {
    printf '%s %s\n' "$CONFIGURED_VAP" "$CONFIGURED_VID"
    return 0
}
if merv_mac_snapshot_preconditions_ok; then
    CONTROL_RC=0
else
    CONTROL_RC=$?
fi
[ "$CONTROL_RC" -ne 0 ] || fail 'successful unsettled builder unexpectedly passed precondition'

printf 'FIXTURE: configured VAP %s -> br%s; builder failure emits empty stdout and rc=1\n' \
    "$CONFIGURED_VAP" "$CONFIGURED_VID"
printf 'RESULT: merv_mac_snapshot_preconditions_ok rc=%s after builder failure (accepted)\n' \
    "$FAILED_PRECONDITION_RC"
printf 'CONTROL: same unsettled VAP with successful builder rc=%s (rejected)\n' "$CONTROL_RC"
printf 'EVIDENCE: caller uses pairs=$(builder) followed by empty-output success, dropping builder rc\n'
printf 'DEEP_AUDIT_BUILDER_EMPTY_SECURITY_OK\n'
