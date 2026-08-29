#!/bin/sh
# Source-level UI contract for the shared Node Role state; no browser/router.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
HTML="$ROOT/www/index.html"
SAVE="$ROOT/functions/save_settings.sh"
FORM_CSS="$ROOT/www/vlan_form_style.css"
INDEX_CSS="$ROOT/www/vlan_index_style.css"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq -- "$1" "$2" || fail "missing: $1"; }

need 'name="NODE1_ROLE"' "$HTML"
need 'data-node-role="${n}"' "$HTML"
need 'aria-label="Node mode" disabled' "$HTML"
need '<option value="aimesh">Mode: AiMesh</option>' "$HTML"
need 'function setNodeRoleControlEnabled(node, enabled)' "$HTML"
need 'setNodeRoleControlEnabled(i, statusNodeIpIsValid(v));' "$HTML"
need 'if (statusNodeIpIsValid(raw)) {' "$HTML"
need 'function firstInvalidNodeIpDraft()' "$HTML"
need 'Correct or clear the invalid Node ${invalidNodeIp} IP before saving.' "$HTML"
need "saveBtn.disabled = state !== 'ready' || !!invalidNodeIp;" "$HTML"
need 'const invalidNodeIp = firstInvalidNodeIpDraft();' "$HTML"
need 'setStatusSymbol(`statusNODE${index}`, STATUS_SYMBOLS.empty);' "$HTML"
need 'id="wanNativePopupRole"' "$HTML"
need 'AiMesh — inherit MAIN' "$HTML"
need 'WAN_NATIVE_POPUP_STATE = { target, vlan, role, standaloneVlanDraft: vlan }' "$HTML"
need 'function handleWanNativePopupRoleChange()' "$HTML"
need "vlanInput.disabled = role === 'aimesh';" "$HTML"
need 'flat[`NODE${i}_ROLE`]' "$HTML"
need 'nodes[roleKey]' "$HTML"
need 'vlanmgr_NODE${i}_ROLE' "$HTML"
need 'NODE([0-9]+)(?:_ALIAS|_WAN_NATIVE_IP|_ROLE)?' "$HTML"
need 'invalid node role' "$SAVE"
need 'NODE[1-9]_ROLE|NODE10_ROLE' "$SAVE"
need 'validate_node_endpoint_kv()' "$SAVE"
need 'invalid node management address' "$SAVE"
need 'if ! validate_node_endpoint_kv "$_vne_key" "$_vne_value"; then' "$SAVE"
need '.node-role-control {' "$FORM_CSS"
need 'height:23px;' "$FORM_CSS"
need '--status-icon-size:14px;' "$INDEX_CSS"
need '--status-rail-inset:34px;' "$INDEX_CSS"
need '--node-status-rail-offset:14.7px;' "$INDEX_CSS"
need 'grid-template-columns:104px 160px 135px minmax(0, 1fr);' "$INDEX_CSS"
need 'grid-template-columns:104px 160px 135px 24px minmax(0, 1fr);' "$INDEX_CSS"
need 'grid-column:4;' "$INDEX_CSS"
need '#ssidTable td:nth-child(4) .status,' "$INDEX_CSS"
need '#lanTable td:nth-child(3) .status {' "$INDEX_CSS"
need '#ssidTable th:nth-child(4)::before,' "$INDEX_CSS"
need 'right:var(--status-rail-inset);' "$INDEX_CSS"
need 'var(--node-status-rail-offset)' "$INDEX_CSS"
need 'width:100%;' "$FORM_CSS"
need 'line-height:21px;' "$FORM_CSS"

# Node 1 keeps its expander immediately after Mode, with status in the final
# visual grid column. Other rows retain Name → IP → Mode → Status.
primary_row=$(sed -n '/id="node1Field"/,/id="nodeToggle"/p' "$HTML")
case "$primary_row" in
  *'id="node1Field"'*'name="NODE1_ROLE"'*'id="nodeToggle"'*) ;;
  *) fail 'NODE1 row does not retain IP, mode, expander order' ;;
esac
additional_row=$(sed -n '/id="node${n}Field"/,/<\/div>`/p' "$HTML")
case "$additional_row" in
  *'id="node${n}Field"'*'name="NODE${n}_ROLE"'*'id="statusNODE${n}"'*) ;;
  *) fail 'additional node rows do not retain IP, mode, status order' ;;
esac

# Execute the exact production endpoint validator. Browser-side control state
# can be bypassed, so malformed NODE<n> input must also be rejected before a
# settings candidate can be published.
node_endpoint_validator=$(sed -n '/^validate_node_endpoint_kv() {/,/^}/p' "$SAVE")
[ -n "$node_endpoint_validator" ] || fail 'node endpoint validator extraction failed'
eval "$node_endpoint_validator"
validate_node_endpoint_kv NODE2 '' || fail 'empty node endpoint rejected'
validate_node_endpoint_kv NODE2 none || fail 'none node endpoint rejected'
validate_node_endpoint_kv NODE2 192.168.186.201 || fail 'valid IPv4 node endpoint rejected'
validate_node_endpoint_kv NODE10 203.0.113.10 || fail 'valid NODE10 endpoint rejected'
validate_node_endpoint_kv NODE2 192.168.186 >/dev/null 2>&1 && fail 'partial node endpoint accepted'
validate_node_endpoint_kv NODE2 192.168.186.999 >/dev/null 2>&1 && fail 'out-of-range node endpoint accepted'
validate_node_endpoint_kv NODE2 example.invalid >/dev/null 2>&1 && fail 'hostname node endpoint accepted'
endpoint_guard_line=$(grep -n 'if ! validate_node_endpoint_kv "$_vne_key" "$_vne_value"; then' "$SAVE" | head -n 1 | cut -d: -f1)
commit_line=$(grep -n 'mv -f "${_save_candidate}" "${SETTINGS_FILE}"' "$SAVE" | head -n 1 | cut -d: -f1)
[ -n "$endpoint_guard_line" ] && [ -n "$commit_line" ] && [ "$endpoint_guard_line" -lt "$commit_line" ] || fail 'node endpoint guard does not precede authoritative commit'
printf '%s\n' 'PASS: node endpoint validation'
printf 'NODE_ROLE_UI_CONTRACT_OK\n'
