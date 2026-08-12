#!/bin/sh
# Source-level contract for the permanent MerVLAN action status slot and
# experimental footer geometry. Browser execution remains separate.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$BASE_DIR/www/index.html"
STYLE_FILE="$BASE_DIR/www/vlan_index_style.css"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require_ui() {
    grep -Fq "$1" "$UI_FILE" || fail "$2"
}

require_style() {
    grep -Fq "$1" "$STYLE_FILE" || fail "$2"
}

require_ui 'id="mervlanLoadingSlot" class="mervlan-loading-slot" aria-hidden="false"' 'loading slot is not permanent'
require_ui 'id="mervlanLoadingMini"' 'compact loading control missing'
require_ui 'data-state="idle"' 'compact loading control does not start idle'
require_ui '>Idle</span>' 'idle compact status missing'
require_ui 'function renderTerminalSnapshot(snapshot)' 'terminal details snapshot renderer missing'
require_ui 'function scheduleCompletedIdle(snapshot)' 'completed status timer helper missing'
require_ui "if (active && !active.terminal)" 'running phase updates do not guard against terminal state'
require_ui "setCompactState('running', value || active.label || 'Running');" 'running compact status does not follow the current phase'
require_ui '}, 5000);' 'completed status does not return to idle after five seconds'
require_ui 'lastTerminal.token !== snapshot.token' 'stale completed timer guard missing'
require_ui 'const terminalToken = active.token;' 'terminal close token guard missing'
require_ui 'active.token === terminalToken && active.sequence === terminalSequence' 'terminal close timer can affect newer work'
require_ui "error.textContent = snapshot.message;" 'terminal failure details are not retained'
require_ui "setCompactState('running', 'Running — Waiting for router result');" 'transport-unknown was mislabeled as terminal failure'
require_ui "loadingMini.dataset.state === \"running\"" 'loading latch does not distinguish minimized work from idle status'
require_ui '.maintenance-confirm-actions { display: flex; justify-content: center;' 'confirmation buttons are not centered'

require_style 'grid-template-columns:auto minmax(0, 1fr) auto auto;' 'experimental footer columns are not stable'
require_style '.form-box.form-box--experimental > #mervlanLoadingSlot' 'loading status slot is not reserved in footer geometry'
require_style '.form-box.form-box--experimental > #experimentalVersionBadge' 'version badge is not right anchored'
require_style '.mervlan-loading-mini[data-state="completed"]' 'completed compact state styling missing'
require_style '.mervlan-loading-mini[data-state="failed"]' 'failed compact state styling missing'

printf 'LOADING_SLOT_FOOTER_CONTRACT_OK\n'
