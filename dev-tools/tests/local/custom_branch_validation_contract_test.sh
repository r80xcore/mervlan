#!/bin/sh
# Source contract for fail-closed Custom branch update validation.
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
block() { sed -n "/^$1/,/^}/p" "$UI_FILE"; }

fetch_block=$(block '        async function fetchCustomBranchVersion(branch)')
input_block=$(block 'function onCustomBranchInput()')
submit_block=$(block 'async function runUpdateFromModal(buttonEl)')

grep -Fq 'function isValidCustomBranchName(value)' "$UI_FILE" || fail 'shared custom branch syntax helper missing'
printf '%s\n' "$fetch_block" | grep -Fq 'method: "GET"' || fail 'custom validation does not use GET'
! printf '%s\n' "$fetch_block" | grep -Fq 'method: "HEAD"' || fail 'custom validation still uses HEAD'
for kind in not_found http network version; do
  printf '%s\n' "$fetch_block" | grep -Fq "kind: \"$kind\"" || fail "missing structured $kind failure"
done

printf '%s\n' "$input_block" | grep -Fq 'clearCustomBranchTarget(runUpdateBtn);' || fail 'input change retains stale custom target'
printf '%s\n' "$input_block" | grep -Fq 'const validation = await fetchCustomBranchVersion(branch);' || fail 'input never validates remote version'
[ "$(printf '%s\n' "$input_block" | grep -Fc 'checkSequence !== _customBranchCheckSequence')" -ge 2 ] || fail 'stale request guards are incomplete'
printf '%s\n' "$input_block" | grep -Fq 'if (!validation.ok)' || fail 'input validation is not fail closed'
! printf '%s\n' "$input_block" | grep -Fq 'is ready to install. Its version could not be compared' || fail 'legacy fail-open message remains'

printf '%s\n' "$submit_block" | grep -Fq 'if (!isValidCustomBranchName(branch))' || fail 'submit does not share syntax gate'
printf '%s\n' "$submit_block" | grep -Fq 'const validation = await fetchCustomBranchVersion(branch);' || fail 'submit-time GET/version validation missing'
printf '%s\n' "$submit_block" | grep -Fq 'if (!validation.ok)' || fail 'submit-time validation is not fail closed'
! printf '%s\n' "$submit_block" | grep -Fq 'method: "HEAD"' || fail 'submit path still uses HEAD'
! printf '%s\n' "$submit_block" | grep -Fq 'proceed and let the update script report the failure' || fail 'submit path still fails open on network error'

grep -Fq 'Custom branch "${result.branch}" was not found. Check the branch name.' "$UI_FILE" || fail '404 message missing'
grep -Fq 'does not report a valid MerVLAN version. Update is blocked.' "$UI_FILE" || fail 'missing-version block message missing'
printf 'CUSTOM_BRANCH_VALIDATION_CONTRACT_OK\n'
