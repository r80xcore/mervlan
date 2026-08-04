#!/bin/sh
# Source-level contracts for request-owned WebUI transport, correlated Save
# acknowledgement publication, and updater diagnostics.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -q 'function MVM_execAsync' "$MERV_BASE/mervlan.asp" || fail 'async parent transport missing'
grep -q 'mvm_action_form_' "$MERV_BASE/mervlan.asp" || fail 'request-owned form naming missing'
grep -q 'mvm_action_frame_' "$MERV_BASE/mervlan.asp" || fail 'request-owned frame naming missing'
grep -q 'initial-about-blank-load' "$MERV_BASE/mervlan.asp" || fail 'initial iframe load guard missing'
grep -q 'function MVM_triggerVerifiedAsync' "$MERV_BASE/mervlan.asp" || fail 'verified async wrapper missing'

grep -q 'hw_probe.sh' "$MERV_BASE/functions/service-event-handler.sh" || fail 'hardware probe global lock classification missing'
grep -q 'action_ack_publish_staged' "$MERV_BASE/functions/service-event-handler.sh" || fail 'staged Save ack publication missing'
grep -q 'MERV_ACTION_ACK_STAGE' "$MERV_BASE/functions/save_settings.sh" || fail 'Save worker staging switch missing'

grep -q 'ACTION_ACK_DIR' "$MERV_BASE/settings/lib_action_ack.sh" || fail 'per-token ack directory missing'
grep -q 'action_ack_token_valid' "$MERV_BASE/settings/lib_action_ack.sh" || fail 'ack token validation missing'
grep -q 'action_ack_atomic_copy' "$MERV_BASE/settings/lib_action_ack.sh" || fail 'atomic ack publication helper missing'

grep -q 'run_update_step' "$MERV_BASE/functions/update_mervlan.sh" || fail 'updater logged-step helper missing'
grep -q 'return 0' "$MERV_BASE/functions/update_mervlan.sh" || fail 'updater helper success return missing'
grep -q 'MERV_UPDATE_OWNER=1 sh "\$HW_PROBE"' "$MERV_BASE/functions/update_mervlan.sh" || fail 'update-owned hardware probe missing'
grep -q 'MerVLAN is updating!' "$MERV_BASE/functions/update_mervlan.sh" || fail 'update start banner missing'
grep -q 'index\\.html version=' "$MERV_BASE/functions/update_mervlan.sh" || fail 'HTML version header reader missing'

grep -q "tmp/results/actions/" "$MERV_BASE/www/index.html" || fail 'frontend per-token ack polling missing'
grep -q 'completion' "$MERV_BASE/www/index.html" || fail 'frontend loading completion promise missing'
! grep -q 'setTimeout(resolve, 550)' "$MERV_BASE/www/index.html" || fail 'fixed 550ms chaining delay remains'

printf 'ACTION_PIPELINE_CONTRACT_OK\n'
