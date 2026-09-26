#!/bin/sh
# Static boundary contract: the normal updater follows only a terminal repair
# completion, with no client-side delay or retry masking dispatcher ownership.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
UI="$ROOT/www/index.html"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

. "$ROOT/dev-tools/tests/local/js_source_helpers.sh"

REPAIR_BLOCK=$(extract_js_function repairUpdateComponentsBeforeUpdate "$UI") || fail 'repair function extraction failed'
UPDATE_BLOCK=$(extract_js_function runUpdateFromModal "$UI") || fail 'update function extraction failed'

printf '%s\n' "$REPAIR_BLOCK" | grep -Fq 'const terminal = await loadingTask.completion;' || \
  fail 'repair flow does not await loading completion'
printf '%s\n' "$REPAIR_BLOCK" | grep -Fq 'terminal.state !== "complete"' || \
  fail 'repair flow accepts a non-complete terminal state'
printf '%s\n' "$REPAIR_BLOCK" | grep -Fq 'return { ok: false' || \
  fail 'repair failure does not return a failed handoff result'
printf '%s\n' "$UPDATE_BLOCK" | grep -Fq 'const repair = await repairUpdateComponentsBeforeUpdate(repairBranch);' || \
  fail 'update flow does not await repair result'
printf '%s\n' "$UPDATE_BLOCK" | grep -Fq 'if (!repair.ok) {' || \
  fail 'update flow does not stop after repair failure'
printf '%s\n' "$UPDATE_BLOCK" | grep -Fq 'return;' || \
  fail 'update flow can continue after repair failure'
! printf '%s\n' "$REPAIR_BLOCK$UPDATE_BLOCK" | grep -Eq 'setTimeout|sleep|retry' || \
  fail 'repair-to-update flow contains a client-side timing workaround'

printf 'REPAIR_UPDATE_MODAL_CONTRACT_OK\n'
