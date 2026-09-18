#!/bin/sh
# Maintained local regression gate. Historical deep_audit_*.sh fixtures are
# intentionally excluded; they do not match the *_test.sh glob.

set -u

# shellcheck disable=SC1007
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FAILURES=0
SHELL_COUNT=0
NODE_COUNT=0

run_test() {
	_test_path=$1
	printf '%s\n' "== $_test_path =="
	sh "$_test_path"
	_test_rc=$?
	[ "$_test_rc" -eq 0 ] && return 0
	printf 'FAIL: %s (exit %s)\n' "$_test_path" "$_test_rc" >&2
	FAILURES=$((FAILURES + 1))
	return 0
}

for _test_path in "$TEST_DIR"/*_test.sh; do
	[ -f "$_test_path" ] || continue
	SHELL_COUNT=$((SHELL_COUNT + 1))
	run_test "$_test_path"
done

if type node >/dev/null 2>&1; then
	for _test_path in "$TEST_DIR"/*_test.mjs; do
		[ -f "$_test_path" ] || continue
		NODE_COUNT=$((NODE_COUNT + 1))
		printf '%s\n' "== $_test_path =="
		node "$_test_path"
		_test_rc=$?
		if [ "$_test_rc" -ne 0 ]; then
			printf 'FAIL: %s (exit %s)\n' "$_test_path" "$_test_rc" >&2
			FAILURES=$((FAILURES + 1))
		fi
	done
else
	printf '%s\n' 'FAIL: Node.js is required for the complete local gate' >&2
	FAILURES=$((FAILURES + 1))
fi

printf 'LOCAL_TEST_SUMMARY shell=%s node=%s failures=%s\n' \
	"$SHELL_COUNT" "$NODE_COUNT" "$FAILURES"
[ "$FAILURES" -eq 0 ]
