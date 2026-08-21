#!/bin/sh
# Source-level UI contract for the shared Node Role state; no browser/router.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
HTML="$ROOT/www/index.html"
SAVE="$ROOT/functions/save_settings.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { grep -Fq -- "$1" "$2" || fail "missing: $1"; }

need 'name="NODE1_ROLE"' "$HTML"
need 'data-node-role="${n}"' "$HTML"
need 'id="wanNativePopupRole"' "$HTML"
need 'AiMesh — inherit MAIN' "$HTML"
need 'WAN_NATIVE_POPUP_STATE = { target, vlan, role }' "$HTML"
need "wanNativePopupInput('wanNativePopupVlan').disabled = !isMain && role === 'aimesh'" "$HTML"
need 'flat[`NODE${i}_ROLE`]' "$HTML"
need 'nodes[roleKey]' "$HTML"
need 'vlanmgr_NODE${i}_ROLE' "$HTML"
need 'NODE([0-9]+)(?:_ALIAS|_WAN_NATIVE_IP|_ROLE)?' "$HTML"
need 'invalid node role' "$SAVE"
need 'NODE[1-9]_ROLE|NODE10_ROLE' "$SAVE"
printf 'NODE_ROLE_UI_CONTRACT_OK\n'
