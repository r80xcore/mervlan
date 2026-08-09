#!/bin/sh
#
# Verify that the node-sync digest ignores main-router/WebUI-local settings
# while still changing for a node-relevant setting.
#

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
export MERV_BASE

TEST_ROOT="${TMPDIR:-/tmp}/mervlan-save-local-only.$$"
mkdir -p "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

# shellcheck disable=SC1091
. "$MERV_BASE/settings/lib_json.sh"

BEFORE="$TEST_ROOT/before.json"
LOCAL_ONLY="$TEST_ROOT/local-only.json"
NODE_CHANGE="$TEST_ROOT/node-change.json"

printf '%s\n' \
    '{' \
    '  "General": {' \
    '    "EXPERIMENTAL": "0",' \
    '    "AUTO_SYNC_SETTINGS": "1",' \
    '    "HTML_CLIENT_REFRESH_MINUTES": "30"' \
    '  },' \
    '  "VLAN": {' \
    '    "VLAN_01": "10"' \
    '  }' \
    '}' > "$BEFORE"

sed \
    -e 's/"EXPERIMENTAL": "0"/"EXPERIMENTAL": "1"/' \
    -e 's/"AUTO_SYNC_SETTINGS": "1"/"AUTO_SYNC_SETTINGS": "0"/' \
    -e 's/"HTML_CLIENT_REFRESH_MINUTES": "30"/"HTML_CLIENT_REFRESH_MINUTES": "5"/' \
    "$BEFORE" > "$LOCAL_ONLY"

sed 's/"VLAN_01": "10"/"VLAN_01": "20"/' "$LOCAL_ONLY" > "$NODE_CHANGE"

before_digest=$(merv_settings_node_sync_digest "$BEFORE")
local_digest=$(merv_settings_node_sync_digest "$LOCAL_ONLY")
node_digest=$(merv_settings_node_sync_digest "$NODE_CHANGE")

[ "$before_digest" = "$local_digest" ] || {
    printf 'FAIL: local-only settings changed the node digest\n' >&2
    exit 1
}
[ "$before_digest" != "$node_digest" ] || {
    printf 'FAIL: node-relevant setting did not change the node digest\n' >&2
    exit 1
}

printf 'SAVE_LOCAL_ONLY_SYNC_OK\n'
