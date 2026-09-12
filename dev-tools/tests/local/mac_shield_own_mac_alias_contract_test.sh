#!/bin/sh
# Focused MAC Shield collector regression for exact own-interface/U/L aliases.
# The fixture exercises local assoclist/FDB collection, remote NODE collection,
# and the explicit reset path without contacting SSH, ebtables, or hardware.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.mac-own-alias.$$"
umask 077
mkdir -p "$TEST_ROOT/bin" \
  "$TEST_ROOT/sys/br2/brif/wl0.2" \
  "$TEST_ROOT/sys/br2/brif/wl1.2" \
  "$TEST_ROOT/sys/br2/brif/eth1.2" \
  "$TEST_ROOT/sys/br0/brif" \
  "$TEST_ROOT/db" "$TEST_ROOT/locks" "$TEST_ROOT/tmp" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

SYS_ROOT="$TEST_ROOT/sys"
BIN_DIR="$TEST_ROOT/bin"
TRACE="$TEST_ROOT/source.trace"
NODE_SYS_ROOT="$TEST_ROOT/node-sys"
mkdir -p "$NODE_SYS_ROOT/br2/brif/wl0.2" \
  "$NODE_SYS_ROOT/br2/brif/wl1.2" \
  "$NODE_SYS_ROOT/br2/brif/eth1.2" \
  "$NODE_SYS_ROOT/br0/brif" || exit 1

for _root in "$SYS_ROOT" "$NODE_SYS_ROOT"; do
  printf '%s\n' 5 > "$_root/br2/brif/wl0.2/port_no"
  printf '%s\n' 6 > "$_root/br2/brif/wl1.2/port_no"
  printf '%s\n' 8 > "$_root/br2/brif/eth1.2/port_no"
  mkdir -p "$_root/wl0.2" "$_root/wl1.2"
  printf '%s\n' ba:4b:fe:a7:97:76 > "$_root/wl0.2/address"
  printf '%s\n' 9a:4b:fe:a7:97:73 > "$_root/wl1.2/address"
done

cat > "$BIN_DIR/wl" <<'EOF'
#!/bin/sh
set -u
iface=""
mode=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -i)
      iface="$2"
      shift 2
      ;;
    assoclist|cur_etheraddr|perm_etheraddr|bssid)
      mode="$1"
      shift
      ;;
    *) shift ;;
  esac
done
printf 'wl %s %s\n' "$iface" "$mode" >> "$MERV_MAC_TEST_TRACE"
case "$mode:$iface" in
  assoclist:wl0.2)
    printf '%s\n' \
      'assoclist ba:4b:fe:a7:97:76' \
      'assoclist b8:4b:fe:a7:97:76' \
      'assoclist b6:4b:fe:a7:97:76'
    ;;
  assoclist:wl1.2)
    printf '%s\n' \
      'assoclist 9a:4b:fe:a7:97:73' \
      'assoclist 98:4b:fe:a7:97:73' \
      'assoclist b5:4b:fe:a7:97:73'
    ;;
  cur_etheraddr:wl0.2|perm_etheraddr:wl0.2|bssid:wl0.2)
    printf '%s\n' ba:4b:fe:a7:97:76
    ;;
  cur_etheraddr:wl1.2|perm_etheraddr:wl1.2|bssid:wl1.2)
    printf '%s\n' 9a:4b:fe:a7:97:73
    ;;
esac
EOF
chmod 700 "$BIN_DIR/wl" || exit 1

cat > "$BIN_DIR/brctl" <<'EOF'
#!/bin/sh
set -u
[ "$1" = showmacs ] || exit 2
bridge="$2"
printf 'brctl %s\n' "$bridge" >> "$MERV_MAC_TEST_TRACE"
case "$bridge" in
  br0)
    printf '%s\n' '1 ba:4b:fe:a7:97:76 yes 0' '2 9a:4b:fe:a7:97:73 yes 0'
    ;;
  br2)
    printf '%s\n' \
      '1 ba:4b:fe:a7:97:76 yes 0' \
      '2 9a:4b:fe:a7:97:73 yes 0' \
      '5 b8:4b:fe:a7:97:76 no 1' \
      '5 b6:4b:fe:a7:97:76 no 2' \
      '6 98:4b:fe:a7:97:73 no 1' \
      '6 b5:4b:fe:a7:97:73 no 2'
    ;;
esac
EOF
chmod 700 "$BIN_DIR/brctl" || exit 1

export MERV_BASE="$BASE_DIR"
export MERV_SYS_CLASS_NET_ROOT="$SYS_ROOT"
export MERV_MAC_TEST_TRACE="$TRACE"
export PATH="$BIN_DIR:$PATH"
export VAR_SETTINGS_LOADED=1
export TMPDIR="$TEST_ROOT/tmp"
export LOCKDIR="$TEST_ROOT/locks"
export RESULTDIR="$TEST_ROOT/results"
export MERV_STATE_ROOT="$TEST_ROOT/state"
export MERV_MAC_DB_ACTIVE="$TEST_ROOT/db/active.db"
export MERV_MAC_DB_JFFS="$TEST_ROOT/db/jffs.db"
export MERV_MAC_MAX_AGE_SEC=86400
export MERV_MAC_NODE_SYNC=0
export MERV_MAC_HEAL_TRIGGER=0
export MERV_MAC_SNAPSHOT_RESET=0
export MERV_MAC_SNAPSHOT_ALLOW_EMPTY=0
export MERV_MAC_SNAPSHOT_FORCE_RELOAD=0

. "$BASE_DIR/settings/lib_identity.sh" || exit 1
. "$BASE_DIR/settings/lib_owner_lock.sh" || exit 1
. "$BASE_DIR/settings/lib_mervqt.sh" || exit 1
. "$BASE_DIR/settings/mac_shield_snapshot.sh" || exit 1

info() { :; }
warn() { :; }
merv_has() { type "$1" >/dev/null 2>&1; }

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_absent() {
  _aaa_mac="$1" _aaa_file="$2"
  grep -F " $_aaa_mac " "$_aaa_file" >/dev/null 2>&1 &&
    fail "$_aaa_mac unexpectedly admitted in $_aaa_file"
}
assert_count_at_least() {
  _aaa_mac="$1" _aaa_file="$2" _aaa_min="$3"
  _aaa_count=$(grep -F " $_aaa_mac " "$_aaa_file" 2>/dev/null | wc -l | tr -d ' ')
  case "$_aaa_count" in ''|*[!0-9]*) _aaa_count=0 ;; esac
  [ "$_aaa_count" -ge "$_aaa_min" ] ||
    fail "$_aaa_mac count=$_aaa_count in $_aaa_file, expected >= $_aaa_min"
}

LOCAL_SNAPSHOT="$TEST_ROOT/local.snapshot"
LOCAL_COUNT=$(merv_mac_build_snapshot "$LOCAL_SNAPSHOT") || fail local-collector-failed
[ -f "$LOCAL_SNAPSHOT" ] || fail local-snapshot-missing
assert_absent ba:4b:fe:a7:97:76 "$LOCAL_SNAPSHOT"
assert_absent b8:4b:fe:a7:97:76 "$LOCAL_SNAPSHOT"
assert_absent 9a:4b:fe:a7:97:73 "$LOCAL_SNAPSHOT"
assert_absent 98:4b:fe:a7:97:73 "$LOCAL_SNAPSHOT"
# b6 is deliberately locally administered but is not an exact own/pair MAC.
assert_count_at_least b6:4b:fe:a7:97:76 "$LOCAL_SNAPSHOT" 2
assert_count_at_least b5:4b:fe:a7:97:73 "$LOCAL_SNAPSHOT" 2
grep -F 'wl wl0.2 assoclist' "$TRACE" >/dev/null 2>&1 || fail local-assoclist-not-exercised
grep -F 'wl wl1.2 assoclist' "$TRACE" >/dev/null 2>&1 || fail local-assoclist-second-vap-not-exercised
grep -F 'brctl br2' "$TRACE" >/dev/null 2>&1 || fail local-fdb-not-exercised
printf 'PASS: local collector rejects exact own/U-L aliases and keeps unrelated clients (records=%s)\n' "$LOCAL_COUNT"

MERV_SYS_CLASS_NET_ROOT="$NODE_SYS_ROOT"
export MERV_SYS_CLASS_NET_ROOT
merv_ssh_exec() {
  _maa_node_id="$1" _maa_node_ip="$2" _maa_command="$3"
  [ "$_maa_node_id" = 1 ] || return 1
  [ "$_maa_node_ip" = 192.0.2.1 ] || return 1
  MERV_SYS_CLASS_NET_ROOT="$NODE_SYS_ROOT" \
    MERV_MAC_TEST_TRACE="$TRACE" PATH="$BIN_DIR:$PATH" \
    sh -c "$_maa_command"
}
REMOTE_SNAPSHOT="$TEST_ROOT/remote.snapshot"
merv_mac_collect_from_node 1 192.0.2.1 > "$REMOTE_SNAPSHOT" || fail remote-collector-failed
assert_absent ba:4b:fe:a7:97:76 "$REMOTE_SNAPSHOT"
assert_absent b8:4b:fe:a7:97:76 "$REMOTE_SNAPSHOT"
assert_absent 9a:4b:fe:a7:97:73 "$REMOTE_SNAPSHOT"
assert_absent 98:4b:fe:a7:97:73 "$REMOTE_SNAPSHOT"
assert_count_at_least b6:4b:fe:a7:97:76 "$REMOTE_SNAPSHOT" 2
assert_count_at_least b5:4b:fe:a7:97:73 "$REMOTE_SNAPSHOT" 2
grep -F 'brctl br2' "$TRACE" >/dev/null 2>&1 || fail remote-fdb-not-exercised
printf 'PASS: remote NODE collector rejects exact own/U-L aliases and keeps unrelated clients\n'

# Reset is the intentional migration path: an existing poisoned alias is not
# folded back into the fresh complete observation, while a legitimate client
# remains because it is still observed.
MERV_SYS_CLASS_NET_ROOT="$SYS_ROOT"
export MERV_SYS_CLASS_NET_ROOT
merv_mac_snapshot_preconditions_ok() { return 0; }
ebt_mac_shield_init_and_apply() { return 0; }
_now=$(date +%s) || exit 1
printf '%s\n' \
  "$_now b8:4b:fe:a7:97:76 wl0.2 10" \
  "$_now b6:4b:fe:a7:97:76 wl0.2 10" > "$MERV_MAC_DB_ACTIVE" || exit 1
export MERV_MAC_SNAPSHOT_RESET=1
export MERV_MAC_SNAPSHOT_ALLOW_EMPTY=1
export MERV_MAC_SNAPSHOT_FORCE_RELOAD=1
merv_mac_snapshot || fail reset-snapshot-failed
assert_absent b8:4b:fe:a7:97:76 "$MERV_MAC_DB_ACTIVE"
assert_count_at_least b6:4b:fe:a7:97:76 "$MERV_MAC_DB_ACTIVE" 1
printf 'PASS: reset rebuild removes poisoned alias and retains legitimate client\n'

printf 'MAC_SHIELD_OWN_MAC_ALIAS_CONTRACT_OK\n'
