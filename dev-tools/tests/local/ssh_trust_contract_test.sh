#!/bin/sh
# Local contract test for the main-router-owned SSH trust database.
# It creates only bounded, disposable state below /tmp/mervlan_tmp.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.ssh-trust.$$"
umask 077
mkdir -p /tmp/mervlan_tmp || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

export MERV_BASE="$BASE_DIR"
export MERV_SSH_TRUST_TEST_MODE=1
export MERV_STATE_ROOT="$TEST_ROOT/state"
. "$BASE_DIR/settings/var_settings.sh" || exit 1

export MERV_SSH_TRUST_ROOT="$TEST_ROOT/ssh_trust"
export MERV_SSH_TRUST_FILE="$MERV_SSH_TRUST_ROOT/known_hosts.v1"
export MERV_SSH_TRUST_PENDING_ROOT="$MERV_SSH_TRUST_ROOT/pending"
export MERV_SSH_TRUST_REQUESTS_ROOT="$MERV_SSH_TRUST_ROOT/requests"
export MERV_SSH_TRUST_STAGING_ROOT="$MERV_SSH_TRUST_ROOT/staging"
export MERV_SSH_TRUST_QUARANTINE_ROOT="$MERV_SSH_TRUST_ROOT/quarantine"
export MERV_SSH_TRUST_LOCK_PATH="$MERV_SSH_TRUST_ROOT/state.lock"
. "$BASE_DIR/settings/lib_ssh_trust.sh" || exit 1

ok() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SYNC_FILE="$MERV_BASE/functions/sync_nodes.sh"
TRUST_ACTION_FILE="$MERV_BASE/functions/ssh_trust_action.sh"
grep -q 'MERV_SSH_TRUST_ORIGINAL_ACTION="$SYNC_PROGRESS_ACTION"' "$SYNC_FILE" || fail settings-only-trust-action
grep -q 'syncsettings_vlanmgr) sh "\$MERV_BASE/functions/sync_nodes.sh" --settings-only' "$TRUST_ACTION_FILE" || fail settings-only-trust-resume
grep -q 'sync_vlanmgr|syncsettings_vlanmgr|' "$TRUST_ACTION_FILE" || fail settings-only-trust-allowlist
grep -q '^functions/ssh_hostkey_probe.sh$' "$SYNC_FILE" || fail sync-hostkey-probe-payload
grep -A20 '^FILES_TO_COPY_CHMOD="' "$SYNC_FILE" | grep -q '^functions/ssh_hostkey_probe.sh$' || fail sync-hostkey-probe-mode
ok sync-hostkey-probe-payload

# The action worker sources var_settings.sh, where CUSTOM_SETTINGS_FILE is
# readonly.  Its startup path must not try to assign that canonical value a
# second time; otherwise every status/probe request exits before publishing an
# acknowledgement and the UI reports a misleading timeout.
_startup_output=$(MERV_BASE="$BASE_DIR" MERV_STATE_ROOT="$TEST_ROOT/startup-state" \
  MERV_SSH_TRUST_TEST_MODE=1 sh "$BASE_DIR/functions/ssh_trust_action.sh" invalid "startup-regression" 2>&1)
_startup_rc=$?
[ "$_startup_rc" -eq 2 ] || fail action-worker-invalid-action
printf '%s' "$_startup_output" | grep -Fq 'is read only' && fail readonly-settings-startup
ok readonly-settings-startup

# A first-contact probe must retain its short timeout even when its client
# never responds.  The helper runs as a separate shell, so give it a minimal
# disposable MerVLAN tree and a fake client that records its PID then blocks.
# The probe must terminate that exact child and return its normal no-key rc.
PROBE_BASE="$TEST_ROOT/probe-base"
PROBE_CLIENT="$TEST_ROOT/probe-client"
PROBE_PID_FILE="$TEST_ROOT/probe-client.pid"
mkdir -p "$PROBE_BASE/functions" "$PROBE_BASE/settings" "$PROBE_BASE/.ssh" || fail probe-fixture-root
for _probe_file in \
  functions/ssh_hostkey_probe.sh \
  settings/var_settings.sh settings/lib_json.sh settings/lib_identity.sh settings/lib_ssh_trust.sh; do
  mkdir -p "$PROBE_BASE/$(dirname "$_probe_file")" || fail probe-fixture-dir
  cp "$BASE_DIR/$_probe_file" "$PROBE_BASE/$_probe_file" || fail probe-fixture-copy
done
: > "$PROBE_BASE/.ssh/vlan_manager" || fail probe-fixture-key
printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n" "$$" > "$FAKE_PROBE_PID_FILE"' \
  'trap "exit 0" INT TERM' \
  'while :; do sleep 1; done' > "$PROBE_CLIENT" || fail probe-client-write
chmod 700 "$PROBE_CLIENT" || fail probe-client-mode
_probe_started=$(date +%s)
FAKE_PROBE_PID_FILE="$PROBE_PID_FILE" MERV_BASE="$PROBE_BASE" \
  MERV_SSH_CLIENT="$PROBE_CLIENT" MERV_SSH_CONNECT_TIMEOUT=1 \
  timeout -k 2 8 sh "$PROBE_BASE/functions/ssh_hostkey_probe.sh" \
    'NODE1@198.51.100.10:22' 198.51.100.10 22 >/dev/null 2>&1
_probe_rc=$?
_probe_elapsed=$(( $(date +%s) - _probe_started ))
if [ -f "$PROBE_PID_FILE" ]; then
  _probe_pid=$(cat "$PROBE_PID_FILE" 2>/dev/null || printf '')
  if kill -0 "$_probe_pid" 2>/dev/null; then
    kill -TERM "$_probe_pid" 2>/dev/null || :
    sleep 1
    kill -0 "$_probe_pid" 2>/dev/null && kill -KILL "$_probe_pid" 2>/dev/null || :
    fail probe-client-cleanup
  fi
fi
[ "$_probe_rc" -eq 5 ] || fail probe-timeout-result
[ "$_probe_elapsed" -lt 8 ] || fail probe-timeout-bound
ok probe-timeout-cleans-up-client

# ASUS Dropbear emits "Connect failed" for an unreachable route.  With no
# captured known_hosts entry that is strictly a pre-session transport failure,
# so the probe must return the recovery-fallback classification rather than
# the ambiguous generic probe result.
PROBE_CONNECT_FAIL="$TEST_ROOT/probe-connect-fail"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n" "dbclient: Connection to test@198.51.100.10:22 exited: Connect failed: No route to host" >&2' \
  'exit 1' > "$PROBE_CONNECT_FAIL" || fail probe-connect-fail-write
chmod 700 "$PROBE_CONNECT_FAIL" || fail probe-connect-fail-mode
MERV_BASE="$PROBE_BASE" MERV_SSH_CLIENT="$PROBE_CONNECT_FAIL" \
  MERV_SSH_CONNECT_TIMEOUT=1 \
  sh "$PROBE_BASE/functions/ssh_hostkey_probe.sh" \
    'NODE1@198.51.100.10:22' 198.51.100.10 22 >/dev/null 2>&1
[ "$?" -eq 10 ] || fail probe-connect-failed-transport-result
ok probe-connect-failed-transport-result

# Keep the browser-facing acknowledgement contract covered as well: a trust
# required result must be valid JSON and must be published to both paths.
export ACTION_ACK_FILE="$TEST_ROOT/public/action_result.json"
export ACTION_ACK_INTERNAL_FILE="$TEST_ROOT/internal/action_ack.json"
. "$BASE_DIR/settings/lib_action_ack.sh" || fail action-ack-library
action_ack_ssh_trust_required "ack-regression" "sshtrustprobe_vlanmgr" \
  '{"reason":"ssh-trust-required"}' "SSH verification is required." '[]' || fail action-ack-write
[ -s "$ACTION_ACK_FILE" ] || fail action-ack-public-file
[ -s "$ACTION_ACK_INTERNAL_FILE" ] || fail action-ack-internal-file
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"] == "ssh_trust_required"; assert d["result"]["reason"] == "ssh-trust-required"' "$ACTION_ACK_FILE" || fail action-ack-json
ok action-ack-json

merv_ssh_trust_init >/dev/null 2>&1 || fail init
type ssh-keygen >/dev/null 2>&1 || fail ssh-keygen-unavailable

ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key1" >/dev/null 2>&1 || fail key1-generation
KEY1=$(cut -d ' ' -f 2 "$TEST_ROOT/key1.pub") || fail key1-read
MAC1=$(merv_ssh_trust_normalize_mac 'aa:bb:cc:dd:ee:01') || fail mac1-normalization
NODE1=$(merv_ssh_trust_node_id 1 "$MAC1" 192.168.1.2 22) || fail node1-id
FP1=$(merv_ssh_trust_derive_fingerprint ssh-ed25519 "$KEY1") || fail fingerprint-derivation
# ASUSWRT may ship OpenSSL without the BusyBox base64 applet. Exercise that
# production fallback locally so a router-only utility difference cannot make
# trust discovery regress again.
merv_has() {
  [ "${1:-}" = base64 ] && return 1
  command -v "$1" >/dev/null 2>&1
}
FP1_OPENSSL=$(merv_ssh_trust_derive_fingerprint ssh-ed25519 "$KEY1") || fail openssl-fingerprint-fallback
[ "$FP1_OPENSSL" = "$FP1" ] || fail openssl-fingerprint-match
ok openssl-fingerprint-fallback
merv_has() {
  command -v "$1" >/dev/null 2>&1
}

# The router also omits od. Safe, validated production fields must still be
# encodable while arbitrary unsafe values remain rejected.
merv_has() {
  case "${1:-}" in od) return 1 ;; esac
  command -v "$1" >/dev/null 2>&1
}
[ "$(merv_ssh_trust_escape 'NODE1@192.168.1.2:22')" = 'NODE1@192.168.1.2:22' ] || fail no-od-safe-escape
merv_ssh_trust_escape 'unsafe value' >/dev/null 2>&1 && fail no-od-unsafe-escape
ok no-od-safe-escape
merv_has() {
  command -v "$1" >/dev/null 2>&1
}
MERV_SSH_TEST_PROBE_FILE="$TEST_ROOT/probe.tsv"
export MERV_SSH_TEST_PROBE_FILE
printf '%s\tssh-ed25519\t%s\n' "$NODE1" "$KEY1" > "$MERV_SSH_TEST_PROBE_FILE" || fail probe-fixture

merv_ssh_hostkey_probe 1 192.168.1.2 22 "$MAC1"
[ "$?" -eq 6 ] || fail untrusted-probe
ok untrusted-probe

STAGE=$(merv_ssh_trust_stage_record 1 "$MAC1" 192.168.1.2 22 ssh-ed25519 "$KEY1" "$FP1") || fail stage-record
merv_ssh_trust_publish_stage "$STAGE" >/dev/null 2>&1 || fail publish-record
merv_ssh_hostkey_probe 1 192.168.1.2 22 "$MAC1"
[ "$?" -eq 0 ] || fail verified-probe
ok verified-probe
merv_ssh_require_verified_node 1 192.168.1.99 22 "$MAC1" 192.168.1.2 || fail alternate-endpoint-canonical-trust
ok alternate-endpoint-canonical-trust
merv_ssh_hostkey_probe 1 192.168.1.99 22 "$MAC1" 192.168.1.2
[ "$?" -eq 0 ] || fail alternate-endpoint-canonical-probe
ok alternate-endpoint-canonical-probe
merv_ssh_hostkey_probe 1 192.168.1.99 22 "$MAC1"
[ "$?" -eq 8 ] || fail endpoint-change
ok endpoint-change

# A healthy sync invokes several bounded SSH commands.  The unchanged trust
# database must not derive every fingerprint repeatedly, but an atomic revoke
# must invalidate that optimization before the next trust lookup.
(
  unset MERV_SSH_TRUST_VALIDATED_FILE MERV_SSH_TRUST_VALIDATED_DIGEST
  : > "$TEST_ROOT/cache-derive.count" || exit 1
  merv_ssh_trust_derive_fingerprint() {
    printf '1\n' >> "$TEST_ROOT/cache-derive.count" || return 1
    [ "$2" = "$KEY1" ] || return 1
    printf '%s\n' "$FP1"
  }
  merv_ssh_trust_validate_db || exit 1
  _cache_first=$(wc -l < "$TEST_ROOT/cache-derive.count" | tr -d ' ')
  merv_ssh_trust_validate_db || exit 1
  _cache_second=$(wc -l < "$TEST_ROOT/cache-derive.count" | tr -d ' ')
  [ "$_cache_first" = 1 ] && [ "$_cache_second" = 1 ] || exit 1
  # A worker frequently runs SSH commands in short-lived child shells.  Once
  # the exact trust-file digest has been checked, the record cache must avoid
  # reparsing that same record while a changed/revoked file still invalidates
  # the cache before the next lookup.
  (
    merv_ssh_trust_find "$NODE1" || exit 1
    merv_ssh_trust_unescape() { return 1; }
    merv_ssh_trust_find "$NODE1" || exit 1
  ) || exit 1
  REMOVE_STAGE=$(merv_ssh_trust_stage_remove_node "$NODE1") || exit 1
  merv_ssh_trust_publish_stage "$REMOVE_STAGE" >/dev/null 2>&1 || exit 1
  merv_ssh_trust_find "$NODE1" >/dev/null 2>&1
  [ "$?" -eq 1 ] || exit 1
)
[ "$?" -eq 0 ] || fail trust-validation-cache-or-revoke
ok trust-validation-cache-and-revoke
STAGE=$(merv_ssh_trust_stage_record 1 "$MAC1" 192.168.1.2 22 ssh-ed25519 "$KEY1" "$FP1") || fail restore-record
merv_ssh_trust_publish_stage "$STAGE" >/dev/null 2>&1 || fail restore-record-publish

# The SSH wrapper may reuse the just-verified record only between its
# precheck and known_hosts hand-off. Run this in a fresh shell so the
# production readonly SSH_KEY path can be replaced by the disposable test key.
# A trust-file change in that gap must force the normal lookup instead of
# permitting the cached key.
_cache_db="$MERV_SSH_TRUST_ROOT/cache-precheck.v1"
cp "$MERV_SSH_TRUST_FILE" "$_cache_db" || fail precheck-known-host-cache-copy
env MERV_BASE="$BASE_DIR" MERV_SSH_TRUST_TEST_MODE=1 \
  MERV_STATE_ROOT="$TEST_ROOT/state" MERV_SSH_TRUST_ROOT="$MERV_SSH_TRUST_ROOT" \
  MERV_SSH_TRUST_FILE="$_cache_db" MERV_SSH_TRUST_PENDING_ROOT="$MERV_SSH_TRUST_PENDING_ROOT" \
  MERV_SSH_TRUST_REQUESTS_ROOT="$MERV_SSH_TRUST_REQUESTS_ROOT" MERV_SSH_TRUST_STAGING_ROOT="$MERV_SSH_TRUST_STAGING_ROOT" \
  MERV_SSH_TRUST_QUARANTINE_ROOT="$MERV_SSH_TRUST_QUARANTINE_ROOT" MERV_SSH_TRUST_LOCK_PATH="$MERV_SSH_TRUST_LOCK_PATH" \
  MERV_SSH_HOME="$TEST_ROOT/cache-precheck-home" SSH_KEY="$TEST_ROOT/key1" MERV_SSH_SKIP_PING=1 \
  CACHE_TEST_MAC="$MAC1" sh -s <<'CACHE_PRECHECK'
unset LIB_SSH_LOADED LIB_SSH_TRUST_LOADED MERV_SSH_TRUST_VALIDATED_FILE MERV_SSH_TRUST_VALIDATED_DIGEST
. "$MERV_BASE/settings/lib_ssh.sh" || exit 1
merv_ssh_node_mac() { printf '%s\n' "$CACHE_TEST_MAC"; }
get_node_ssh_port() { printf '22\n'; }
ssh_keys_effectively_installed() { return 0; }
merv_ssh_precheck 1 192.168.1.2 || { printf 'cache-fixture precheck failed: %s\n' "${MERV_SSH_LAST_REASON:-unknown}" >&2; exit 1; }
merv_ssh_trust_find() { return 1; }
merv_ssh_prepare_known_host 1 192.168.1.2 22 "$CACHE_TEST_MAC" || { printf '%s\n' 'cache-fixture reuse unexpectedly performed a lookup' >&2; exit 1; }
printf 'changed\n' >> "$MERV_SSH_TRUST_FILE" || exit 1
if merv_ssh_prepare_known_host 1 192.168.1.2 22 "$CACHE_TEST_MAC"; then
  printf '%s\n' 'cache-fixture reused a changed trust file' >&2
  exit 1
fi
exit 0
CACHE_PRECHECK
[ "$?" -eq 0 ] || fail precheck-known-host-cache
ok precheck-known-host-cache

ESCAPED=$(merv_ssh_trust_escape 'a%b/c') || fail escape
[ "$(merv_ssh_trust_unescape "$ESCAPED")" = 'a%b/c' ] || fail unescape
ok percent-escape-roundtrip
OPTIONAL_NODE=$(merv_ssh_trust_node_id 3 none 192.168.1.9 22) || fail optional-mac
[ "$OPTIONAL_NODE" = 'NODE3@192.168.1.9:22' ] || fail optional-mac-value
ok optional-mac-identity

cp "$MERV_SSH_TRUST_FILE" "$TEST_ROOT/duplicate.db" || fail duplicate-copy
sed -n '3p' "$MERV_SSH_TRUST_FILE" >> "$TEST_ROOT/duplicate.db" || fail duplicate-append
merv_ssh_trust_validate_file "$TEST_ROOT/duplicate.db" >/dev/null 2>&1
[ "$?" -ne 0 ] || fail duplicate-accepted
ok duplicate-rejected

sed '3s/\tSHA256:[^\t]*/\tSHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' \
  "$MERV_SSH_TRUST_FILE" > "$TEST_ROOT/bad-fingerprint.db" || fail fingerprint-copy
merv_ssh_trust_validate_file "$TEST_ROOT/bad-fingerprint.db" >/dev/null 2>&1
[ "$?" -ne 0 ] || fail fingerprint-accepted
ok fingerprint-rejected

sed '3s/[0-9][0-9]*\t[0-9][0-9]*$/9999999999\t9999999999/' \
  "$MERV_SSH_TRUST_FILE" > "$TEST_ROOT/future.db" || fail future-copy
merv_ssh_trust_validate_file "$TEST_ROOT/future.db" >/dev/null 2>&1
[ "$?" -ne 0 ] || fail future-accepted
ok future-timestamps-rejected

ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key2" >/dev/null 2>&1 || fail key2-generation
KEY2=$(cut -d ' ' -f 2 "$TEST_ROOT/key2.pub") || fail key2-read
MAC2=$(merv_ssh_trust_normalize_mac 'aa:bb:cc:dd:ee:02') || fail mac2-normalization
NODE2=$(merv_ssh_trust_node_id 2 "$MAC2" 192.168.1.3 22) || fail node2-id
FP2=$(merv_ssh_trust_derive_fingerprint ssh-ed25519 "$KEY2") || fail fingerprint2-derivation
printf '%s\tssh-ed25519\t%s\n' "$NODE2" "$KEY2" >> "$MERV_SSH_TEST_PROBE_FILE" || fail probe-fixture2
STAGE=$(merv_ssh_trust_stage_record 2 "$MAC2" 192.168.1.3 22 ssh-ed25519 "$KEY2" "$FP2") || fail stage-record2
merv_ssh_trust_publish_stage "$STAGE" >/dev/null 2>&1 || fail publish-record2
{
  sed -n '1,2p' "$MERV_SSH_TRUST_FILE"
  sed -n '4p' "$MERV_SSH_TRUST_FILE"
  sed -n '3p' "$MERV_SSH_TRUST_FILE"
} > "$TEST_ROOT/reverse.db" || fail reverse-copy
merv_ssh_trust_validate_file "$TEST_ROOT/reverse.db" >/dev/null 2>&1
[ "$?" -ne 0 ] || fail unsorted-accepted
ok unsorted-rejected

ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key3" >/dev/null 2>&1 || fail key3-generation
KEY3=$(cut -d ' ' -f 2 "$TEST_ROOT/key3.pub") || fail key3-read
MAC3=$(merv_ssh_trust_normalize_mac 'aa:bb:cc:dd:ee:03') || fail mac3-normalization
NODE3=$(merv_ssh_trust_node_id 3 "$MAC3" 192.168.1.4 22) || fail node3-id
printf '%s\tssh-ed25519\t%s\n' "$NODE3" "$KEY3" >> "$MERV_SSH_TEST_PROBE_FILE" || fail probe-fixture3
printf '3 192.168.1.4 %s\n' "$MAC3" > "$TEST_ROOT/preflight.tsv" || fail preflight-fixture
MERV_NODE_SSH_PORT=22
export MERV_NODE_SSH_PORT
merv_ssh_preflight_node_set "$TEST_ROOT/preflight.tsv" >/dev/null 2>&1
[ "$?" -eq 6 ] || fail preflight-untrusted
[ "${MERV_SSH_TRUST_LAST_REASON:-}" = ssh-trust-required ] || fail preflight-reason
ok preflight-reason
MERV_SSH_TRUST_MAX_PENDING=1
CHALLENGE=$(merv_ssh_trust_issue_challenge 3 192.168.1.4 22 "$MAC3") || fail challenge-issue
merv_ssh_trust_validate_challenge "$MERV_SSH_TRUST_PENDING_ROOT/$CHALLENGE" || fail challenge-validation
ok challenge-issue-and-validation
merv_ssh_trust_issue_challenge 4 192.168.1.5 22 none >/dev/null 2>&1
[ "$?" -eq 12 ] || fail challenge-cap
ok challenge-cap
printf 'bogus\n' > "$MERV_SSH_TRUST_PENDING_ROOT/$CHALLENGE/state" || fail malformed-state
merv_ssh_trust_prune_pending >/dev/null 2>&1 || fail prune
_quarantined=0
for _q in "$MERV_SSH_TRUST_QUARANTINE_ROOT"/"$CHALLENGE".invalid.*; do
  [ -e "$_q" ] || continue
  _quarantined=1
  break
done
[ "$_quarantined" -eq 1 ] || fail malformed-challenge-quarantine
ok malformed-challenge-quarantine

# Legacy nodes can lack AUTO_NODE<n>_MAC. Their trust identity is therefore
# the configured ASUS/recovery endpoint, not a temporary WAN Native address.
LEGACY_STAGE=$(merv_ssh_trust_stage_record 9 none 192.168.1.9 22 ssh-ed25519 "$KEY1" "$FP1") || fail legacy-stage-record
merv_ssh_trust_publish_stage "$LEGACY_STAGE" >/dev/null 2>&1 || fail legacy-publish-record
merv_ssh_require_verified_node 9 192.168.1.99 22 none 192.168.1.9 || fail alternate-endpoint-legacy-canonical-trust
ok alternate-endpoint-legacy-canonical-trust

printf 'SSH_TRUST_CONTRACT_OK\n'
