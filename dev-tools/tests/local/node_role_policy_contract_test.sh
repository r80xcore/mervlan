#!/bin/sh
# Deterministic Round 6 policy contract.  No router state is read or changed.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TMP_ROOT=${TMPDIR:-/tmp}/mervlan-node-role.$$
SETTINGS_FILE="$TMP_ROOT/settings.json"
export SETTINGS_FILE
trap 'rm -rf "$TMP_ROOT"' 0 1 2 3 15
mkdir -p "$TMP_ROOT"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got=$1 expected=$2)"; }
assert_ok() { "$@" || fail "command failed: $*"; }
assert_fail() { if "$@"; then fail "command unexpectedly succeeded: $*"; fi; }

write_settings() {
  role=$1 main=$2 own=$3 native_ip=$4
  cat > "$SETTINGS_FILE" <<EOF
{
  "General": { "NODE_SSH_PORT": "22" },
  "Nodes": {
    "NODE1": "192.0.2.11",
    "NODE1_WAN_NATIVE_IP": "$native_ip"$role
  },
  "VLAN": { "WAN_Native": {
    "WAN_NATIVE_MAIN": "$main",
    "WAN_NATIVE_NODE1": "$own"
  } }
}
EOF
}

. "$ROOT/settings/lib_json.sh"
. "$ROOT/settings/lib_ssh.sh"

# Role-less persisted settings are legacy compatibility, not a new-node UX
# default: they remain standalone and keep their independent WAN value.
write_settings '' 190 200 192.0.2.201
assert_eq "$(merv_node_role 1 "$SETTINGS_FILE")" standalone 'legacy role defaults to standalone'
assert_eq "$(merv_effective_wan_native_value 1 "$SETTINGS_FILE")" 200 'legacy independent WAN mode remains effective'

# Explicit standalone accepts none and its own numeric setting.
write_settings ', "NODE1_ROLE": "standalone"' none none none
assert_eq "$(merv_effective_wan_native_value 1 "$SETTINGS_FILE")" none 'standalone own none is effective none'
write_settings ', "NODE1_ROLE": "standalone"' 190 200 192.0.2.201
assert_eq "$(merv_effective_wan_native_value 1 "$SETTINGS_FILE")" 200 'standalone keeps own configured value'

# AiMesh inherits MAIN without deleting the dormant standalone setting.
write_settings ', "NODE1_ROLE": "aimesh"' none 200 none
assert_eq "$(merv_effective_wan_native_value 1 "$SETTINGS_FILE")" none 'AiMesh inherits MAIN none'
write_settings ', "NODE1_ROLE": "aimesh"' 190 200 192.0.2.201
assert_eq "$(merv_effective_wan_native_value 1 "$SETTINGS_FILE")" 190 'AiMesh inherits MAIN numeric mode'
assert_eq "$(merv_configured_wan_native_value 1 "$SETTINGS_FILE")" 200 'AiMesh retains dormant standalone mode'
assert_ok merv_node_validate_wan_native_management "$SETTINGS_FILE"
write_settings ', "NODE1_ROLE": "aimesh"' 190 200 none
assert_fail merv_node_validate_wan_native_management "$SETTINGS_FILE"

# Switching back exposes the retained independent setting again.
write_settings ', "NODE1_ROLE": "standalone"' 190 200 192.0.2.201
assert_eq "$(merv_effective_wan_native_value 1 "$SETTINGS_FILE")" 200 'standalone switch restores dormant own value'

# Invalid persisted roles are fail-closed and management policy changes alter
# the reusable preflight digest.
write_settings ', "NODE1_ROLE": "invalid"' 190 200 192.0.2.201
assert_fail merv_node_role 1 "$SETTINGS_FILE"
assert_fail merv_node_validate_wan_native_management "$SETTINGS_FILE"
write_settings ', "NODE1_ROLE": "standalone"' 190 200 192.0.2.201
before=$(merv_node_list_digest)
write_settings ', "NODE1_ROLE": "aimesh"' 190 200 192.0.2.201
after_role=$(merv_node_list_digest)
[ "$before" != "$after_role" ] || fail 'role change did not invalidate policy digest'
write_settings ', "NODE1_ROLE": "aimesh"' 190 200 192.0.2.202
after_ip=$(merv_node_list_digest)
[ "$after_role" != "$after_ip" ] || fail 'native endpoint change did not invalidate policy digest'

grep -q '"NODE1_ROLE": "standalone"' "$ROOT/settings/settings.json" ||
  fail 'template migration default is not standalone'
printf 'NODE_ROLE_POLICY_CONTRACT_OK\n'
