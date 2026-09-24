#!/bin/sh
# Focused regression coverage for the bounded first-contact SSH host-key
# probe.  The fixture exercises functions/ssh_hostkey_probe.sh itself; it does
# not use the trust-library probe-file shortcut.

set -u

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd) || exit 1
TEST_ROOT="/tmp/mervlan_tmp/selftest.ssh-hostkey-probe.$$"
umask 077
mkdir -p /tmp/mervlan_tmp || exit 1
mkdir "$TEST_ROOT" || exit 1
trap 'rm -rf "$TEST_ROOT"' 0 1 2 3 15

ok() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

PROBE_BASE="$TEST_ROOT/probe-base"
mkdir -p "$PROBE_BASE/functions" "$PROBE_BASE/settings" "$PROBE_BASE/.ssh" || fail fixture-root
for _probe_file in \
  functions/ssh_hostkey_probe.sh \
  settings/lib_json.sh settings/lib_identity.sh settings/lib_ssh_trust.sh; do
  cp "$BASE_DIR/$_probe_file" "$PROBE_BASE/$_probe_file" || fail fixture-copy
done

# Keep the production probe script unchanged while giving this disposable
# fixture a test-only Dropbear key generator.  The real source's var_settings
# contract remains in force; only its configured executable path is replaced
# inside the fixture tree.
FAKE_KEYGEN="$TEST_ROOT/fake-dropbearkey"
FAKE_CLIENT="$TEST_ROOT/fake-dbclient"
FAKE_KEYGEN_LOG="$TEST_ROOT/keygen.calls"
FAKE_IDENTITY_LOG="$TEST_ROOT/client.identity"
FAKE_MODE_LOG="$TEST_ROOT/client.mode"
FAKE_ARGS_LOG="$TEST_ROOT/client.args"
FAKE_KNOWN_HOSTS_LOG="$TEST_ROOT/client.known_hosts"
FAKE_FINGERPRINT_LOG="$TEST_ROOT/client.fingerprint"
HOST_KEY_FILE="$TEST_ROOT/host-key"
HOST_KEY_PUB="$HOST_KEY_FILE.pub"

printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$FAKE_KEYGEN_LOG"' \
  'if [ "${FAKE_KEYGEN_MODE:-ok}" = fail ]; then' \
  '  exit 17' \
  'fi' \
  '_out=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    -f) [ "$#" -ge 2 ] || exit 2; _out="$2"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  '[ -n "$_out" ] || exit 2' \
  'printf "%s\n" ephemeral-test-identity > "$_out"' \
  > "$FAKE_KEYGEN" || fail keygen-fixture
chmod 700 "$FAKE_KEYGEN" || fail keygen-mode

printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" > "$FAKE_ARGS_LOG"' \
  '_identity=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    -i|-p) [ "$#" -ge 2 ] || exit 2; if [ "$1" = "-i" ]; then _identity="$2"; fi; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  '[ -n "$_identity" ] && [ -f "$_identity" ] || exit 12' \
  'printf "%s\n" "$_identity" > "$FAKE_IDENTITY_LOG"' \
  'ls -ld "$_identity" 2>/dev/null | awk '\''NR == 1 {print $1}'\'' > "$FAKE_MODE_LOG"' \
  'mkdir -p "$HOME/.ssh" || exit 13' \
  'printf "%s ssh-ed25519 %s\n" "$FAKE_PROBE_HOST" "$FAKE_PROBE_KEY" > "$HOME/.ssh/known_hosts"' \
  'cp "$HOME/.ssh/known_hosts" "$FAKE_KNOWN_HOSTS_LOG"' \
  'printf "%s\n" "dbclient: host key fingerprint $FAKE_PROBE_FP" >&2' \
  'printf "%s\n" "$FAKE_PROBE_FP" > "$FAKE_FINGERPRINT_LOG"' \
  '_fake_sleep=""' \
  '_fake_stop() { [ -n "${_fake_sleep:-}" ] && kill "$_fake_sleep" 2>/dev/null || :; exit 0; }' \
  'trap _fake_stop INT TERM' \
  'while :; do sleep 1 & _fake_sleep=$!; wait "$_fake_sleep"; done' \
  > "$FAKE_CLIENT" || fail client-fixture
chmod 700 "$FAKE_CLIENT" || fail client-mode

sed "s|readonly DROPBEARKEY=\"/usr/bin/dropbearkey\"|readonly DROPBEARKEY=\"$FAKE_KEYGEN\"|" \
  "$BASE_DIR/settings/var_settings.sh" > "$PROBE_BASE/settings/var_settings.sh" || fail settings-fixture
printf '%s\n' '{' '  "NODE_SSH_USER": "admin",' '  "SSH_KEYS_INSTALLED": "0"' '}' > "$PROBE_BASE/settings/settings.json" || fail settings-json

ssh-keygen -q -t ed25519 -N '' -f "$HOST_KEY_FILE" >/dev/null 2>&1 || fail host-key-generation
HOST_KEY=$(awk '{print $2; exit}' "$HOST_KEY_PUB") || fail host-key-read

# Use the production trust fingerprint helper only to construct the fake
# server response.  No key material is printed by this test.
export MERV_BASE="$BASE_DIR"
export MERV_SSH_TRUST_TEST_MODE=1
export MERV_SSH_TRUST_ROOT="$TEST_ROOT/state/ssh_trust"
export MERV_SSH_TRUST_FILE="$MERV_SSH_TRUST_ROOT/known_hosts.v1"
export MERV_SSH_TRUST_PENDING_ROOT="$MERV_SSH_TRUST_ROOT/pending"
export MERV_SSH_TRUST_REQUESTS_ROOT="$MERV_SSH_TRUST_ROOT/requests"
export MERV_SSH_TRUST_STAGING_ROOT="$MERV_SSH_TRUST_ROOT/staging"
export MERV_SSH_TRUST_QUARANTINE_ROOT="$MERV_SSH_TRUST_ROOT/quarantine"
export MERV_SSH_TRUST_LOCK_PATH="$MERV_SSH_TRUST_ROOT/state.lock"
. "$BASE_DIR/settings/lib_ssh_trust.sh" || fail trust-library
mkdir -p "$MERV_SSH_TRUST_STAGING_ROOT" || fail trust-staging-root
HOST_FP=$(merv_ssh_trust_derive_fingerprint ssh-ed25519 "$HOST_KEY") || fail host-fingerprint
mkdir -p "$TEST_ROOT/state/ssh_trust/staging" || fail probe-staging-root

export FAKE_KEYGEN_LOG FAKE_IDENTITY_LOG FAKE_MODE_LOG FAKE_ARGS_LOG FAKE_KNOWN_HOSTS_LOG FAKE_FINGERPRINT_LOG
export FAKE_PROBE_HOST=198.51.100.10
export FAKE_PROBE_KEY="$HOST_KEY"
export FAKE_PROBE_FP="$HOST_FP"
export MERV_SSH_CLIENT="$FAKE_CLIENT"
export MERV_SSH_CONNECT_TIMEOUT=3

run_probe() {
  MERV_BASE="$PROBE_BASE" \
  MERV_STATE_ROOT="$TEST_ROOT/state" \
  MERV_SSH_TRUST_TEST_MODE=1 \
  MERV_SSH_CLIENT="$FAKE_CLIENT" \
  FAKE_KEYGEN_LOG="$FAKE_KEYGEN_LOG" \
  FAKE_IDENTITY_LOG="$FAKE_IDENTITY_LOG" \
  FAKE_MODE_LOG="$FAKE_MODE_LOG" \
  FAKE_ARGS_LOG="$FAKE_ARGS_LOG" \
  FAKE_KNOWN_HOSTS_LOG="$FAKE_KNOWN_HOSTS_LOG" \
  FAKE_FINGERPRINT_LOG="$FAKE_FINGERPRINT_LOG" \
  FAKE_PROBE_HOST="$FAKE_PROBE_HOST" \
  FAKE_PROBE_KEY="$FAKE_PROBE_KEY" \
  FAKE_PROBE_FP="$FAKE_PROBE_FP" \
  FAKE_KEYGEN_MODE="${FAKE_KEYGEN_MODE:-ok}" \
  sh "$PROBE_BASE/functions/ssh_hostkey_probe.sh" \
    'NODE1@198.51.100.10:22' 198.51.100.10 22
}

probe_workspace_gone() {
  [ -n "${1:-}" ] || return 1
  [ ! -e "$(dirname "$1")" ] && [ ! -L "$(dirname "$1")" ]
}

: > "$FAKE_KEYGEN_LOG"
rm -f "$FAKE_IDENTITY_LOG" "$FAKE_MODE_LOG" "$FAKE_ARGS_LOG"
SETTINGS_DIGEST_BEFORE=$(sha256sum "$PROBE_BASE/settings/settings.json") || fail settings-digest-before
FAKE_KEYGEN_MODE=ok
_probe_output=$(run_probe 2>"$TEST_ROOT/absent.stderr")
_probe_rc=$?
if [ "$_probe_rc" -ne 0 ]; then
  printf 'DEBUG: absent probe rc=%s stderr=%s\n' "$_probe_rc" "$(sed -n '1,8p' "$TEST_ROOT/absent.stderr" 2>/dev/null)" >&2
  [ -f "$FAKE_IDENTITY_LOG" ] && printf 'DEBUG: client identity=%s mode=%s args=%s known_hosts=%s fingerprint=%s\n' "$(cat "$FAKE_IDENTITY_LOG")" "$(cat "$FAKE_MODE_LOG" 2>/dev/null)" "$(cat "$FAKE_ARGS_LOG" 2>/dev/null)" "$(cat "$FAKE_KNOWN_HOSTS_LOG" 2>/dev/null)" "$(cat "$FAKE_FINGERPRINT_LOG" 2>/dev/null)" >&2
  fail absent-key-probe
fi
printf '%s' "$_probe_output" | awk -F '\t' -v k="$HOST_KEY" -v f="$HOST_FP" \
  '$1 == "ssh-ed25519" && $2 == k && $3 == f {ok=1} END {exit ok ? 0 : 1}' || fail absent-key-tuple
[ -s "$FAKE_KEYGEN_LOG" ] || fail absent-key-not-generated
_probe_identity=$(cat "$FAKE_IDENTITY_LOG") || fail absent-key-identity-log
case "$_probe_identity" in /tmp/mervlan_tmp/ssh_hostkey_probe.*/probe_identity) ;; *) fail absent-key-not-ephemeral ;; esac
[ "$_probe_identity" != "$PROBE_BASE/.ssh/vlan_manager" ] || fail absent-key-used-permanent
[ "$(cat "$FAKE_MODE_LOG")" = "-rw-------" ] || fail absent-key-permissions
grep -Fq -- '-y -N' "$FAKE_ARGS_LOG" || fail absent-key-bounded-flags
probe_workspace_gone "$_probe_identity" || fail absent-key-workspace-cleanup
[ ! -e "$PROBE_BASE/.ssh/vlan_manager" ] || fail absent-key-created-permanent
[ ! -e "$MERV_SSH_TRUST_FILE" ] || fail absent-key-created-trust
SETTINGS_DIGEST_AFTER=$(sha256sum "$PROBE_BASE/settings/settings.json") || fail settings-digest-after
[ "$SETTINGS_DIGEST_BEFORE" = "$SETTINGS_DIGEST_AFTER" ] || fail absent-key-settings-mutated
ok absent-permanent-key-uses-ephemeral-identity

# A real permanent key keeps the old path and does not invoke key generation.
printf '%s\n' permanent-test-identity > "$PROBE_BASE/.ssh/vlan_manager" || fail permanent-key-create
chmod 600 "$PROBE_BASE/.ssh/vlan_manager" || fail permanent-key-mode
: > "$FAKE_KEYGEN_LOG"
rm -f "$FAKE_IDENTITY_LOG" "$FAKE_MODE_LOG" "$FAKE_ARGS_LOG"
_probe_output=$(run_probe 2>"$TEST_ROOT/permanent.stderr")
_probe_rc=$?
[ "$_probe_rc" -eq 0 ] || fail permanent-key-probe
[ "$(cat "$FAKE_IDENTITY_LOG")" = "$PROBE_BASE/.ssh/vlan_manager" ] || fail permanent-key-not-used
[ ! -s "$FAKE_KEYGEN_LOG" ] || fail permanent-key-regenerated
ok permanent-key-path-unchanged

# An existing symlink or directory is suspicious and must not trigger the
# absent-key fallback.
rm -f "$PROBE_BASE/.ssh/vlan_manager" || fail unsafe-key-remove
printf '%s\n' unsafe-target > "$TEST_ROOT/unsafe-target" || fail unsafe-target
ln -s "$TEST_ROOT/unsafe-target" "$PROBE_BASE/.ssh/vlan_manager" || fail unsafe-symlink
: > "$FAKE_KEYGEN_LOG"
rm -f "$FAKE_IDENTITY_LOG"
run_probe >/dev/null 2>&1
[ "$?" -eq 3 ] || fail unsafe-symlink-result
[ ! -s "$FAKE_KEYGEN_LOG" ] || fail unsafe-symlink-keygen
[ ! -e "$FAKE_IDENTITY_LOG" ] || fail unsafe-symlink-client
rm -f "$PROBE_BASE/.ssh/vlan_manager" || fail unsafe-symlink-remove
mkdir "$PROBE_BASE/.ssh/vlan_manager" || fail unsafe-directory
run_probe >/dev/null 2>&1
[ "$?" -eq 3 ] || fail unsafe-directory-result
rm -rf "$PROBE_BASE/.ssh/vlan_manager" || fail unsafe-directory-remove
ok unsafe-existing-key-fails-closed

# Key generation failure is terminal and leaves no probe workspace.
: > "$FAKE_KEYGEN_LOG"
rm -f "$FAKE_IDENTITY_LOG"
FAKE_KEYGEN_MODE=fail run_probe >/dev/null 2>&1
[ "$?" -eq 3 ] || fail keygen-failure-result
[ ! -e "$FAKE_IDENTITY_LOG" ] || fail keygen-failure-client
_keygen_identity=$(awk '{print $NF}' "$FAKE_KEYGEN_LOG" 2>/dev/null | tail -n 1)
[ -z "$_keygen_identity" ] || probe_workspace_gone "$_keygen_identity" || fail keygen-failure-cleanup
ok temporary-key-generation-failure

# A host-key/fingerprint mismatch remains terminal even though the temporary
# identity allowed the transport to reach the first-contact capture point.
FAKE_PROBE_FP=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
rm -f "$FAKE_IDENTITY_LOG" "$FAKE_MODE_LOG" "$FAKE_ARGS_LOG"
run_probe >/dev/null 2>&1
[ "$?" -eq 5 ] || fail host-key-mismatch-result
_mismatch_identity=$(cat "$FAKE_IDENTITY_LOG" 2>/dev/null || printf '')
[ -n "$_mismatch_identity" ] && probe_workspace_gone "$_mismatch_identity" || fail host-key-mismatch-client-cleanup
ok host-key-mismatch-fails-closed
FAKE_PROBE_FP="$HOST_FP"

# Exercise the trust-library adapter with the production probe command and no
# MERV_SSH_TEST_PROBE_FILE.  This is the no-permanent-key modern-preflight
# regression, not the older trust-file mock path.
rm -f "$MERV_SSH_TRUST_FILE"
merv_ssh_trust_init >/dev/null 2>&1 || fail adapter-trust-init
_stage=$(merv_ssh_trust_stage_record 1 none 198.51.100.10 22 ssh-ed25519 "$HOST_KEY" "$HOST_FP") || fail adapter-trust-stage
merv_ssh_trust_publish_stage "$_stage" >/dev/null 2>&1 || fail adapter-trust-publish
env MERV_BASE="$PROBE_BASE" MERV_STATE_ROOT="$TEST_ROOT/state" \
  MERV_SSH_TRUST_TEST_MODE=1 MERV_SSH_CLIENT="$FAKE_CLIENT" \
  MERV_SSH_CAPABILITY_PROVEN=1 MERV_SSH_HOSTKEY_PROBE_CMD="$PROBE_BASE/functions/ssh_hostkey_probe.sh" \
  MERV_SSH_TRUST_ROOT="$MERV_SSH_TRUST_ROOT" MERV_SSH_TRUST_FILE="$MERV_SSH_TRUST_FILE" \
  MERV_SSH_TRUST_PENDING_ROOT="$MERV_SSH_TRUST_PENDING_ROOT" \
  MERV_SSH_TRUST_REQUESTS_ROOT="$MERV_SSH_TRUST_REQUESTS_ROOT" \
  MERV_SSH_TRUST_STAGING_ROOT="$MERV_SSH_TRUST_STAGING_ROOT" \
  MERV_SSH_TRUST_QUARANTINE_ROOT="$MERV_SSH_TRUST_QUARANTINE_ROOT" \
  MERV_SSH_TRUST_LOCK_PATH="$MERV_SSH_TRUST_LOCK_PATH" \
  FAKE_KEYGEN_LOG="$FAKE_KEYGEN_LOG" FAKE_IDENTITY_LOG="$FAKE_IDENTITY_LOG" \
  FAKE_MODE_LOG="$FAKE_MODE_LOG" FAKE_ARGS_LOG="$FAKE_ARGS_LOG" \
  FAKE_PROBE_HOST="$FAKE_PROBE_HOST" FAKE_PROBE_KEY="$FAKE_PROBE_KEY" \
  FAKE_PROBE_FP="$HOST_FP" FAKE_KEYGEN_MODE=ok \
  sh -s <<'ADAPTER_TEST'
. "$MERV_BASE/settings/var_settings.sh" || exit 1
. "$MERV_BASE/settings/lib_json.sh" || exit 1
. "$MERV_BASE/settings/lib_identity.sh" || exit 1
. "$MERV_BASE/settings/lib_ssh_trust.sh" || exit 1
unset MERV_SSH_TEST_PROBE_FILE
merv_ssh_hostkey_probe 1 198.51.100.10 22 none
exit $?
ADAPTER_TEST
[ "$?" -eq 0 ] || fail adapter-uses-production-probe
ok modern-preflight-uses-no-key-production-probe

# The authenticated SSH precheck retains its permanent-key gate.  Establish a
# valid trust record, then verify a fresh/no-key installation is rejected before
# any authenticated client invocation can occur.
AUTH_BASE="$TEST_ROOT/auth-base"
mkdir -p "$AUTH_BASE/settings" "$AUTH_BASE/.ssh" || fail auth-fixture-root
for _auth_file in settings/var_settings.sh settings/lib_json.sh settings/lib_identity.sh settings/lib_ssh_trust.sh settings/lib_ssh.sh; do
  cp "$BASE_DIR/$_auth_file" "$AUTH_BASE/$_auth_file" || fail auth-fixture-copy
done
printf '%s\n' '{"SSH_KEYS_INSTALLED":"0"}' > "$AUTH_BASE/settings/settings.json" || fail auth-settings
AUTH_TRUST_ROOT="$TEST_ROOT/auth-state/ssh_trust"
MERV_SSH_TRUST_ROOT="$AUTH_TRUST_ROOT"
MERV_SSH_TRUST_FILE="$AUTH_TRUST_ROOT/known_hosts.v1"
MERV_SSH_TRUST_PENDING_ROOT="$AUTH_TRUST_ROOT/pending"
MERV_SSH_TRUST_REQUESTS_ROOT="$AUTH_TRUST_ROOT/requests"
MERV_SSH_TRUST_STAGING_ROOT="$AUTH_TRUST_ROOT/staging"
MERV_SSH_TRUST_QUARANTINE_ROOT="$AUTH_TRUST_ROOT/quarantine"
MERV_SSH_TRUST_LOCK_PATH="$AUTH_TRUST_ROOT/state.lock"
merv_ssh_trust_init >/dev/null 2>&1 || fail auth-trust-init
_auth_stage=$(merv_ssh_trust_stage_record 1 none 198.51.100.10 22 ssh-ed25519 "$HOST_KEY" "$HOST_FP") || fail auth-trust-stage
merv_ssh_trust_publish_stage "$_auth_stage" >/dev/null 2>&1 || fail auth-trust-publish
env MERV_BASE="$AUTH_BASE" MERV_STATE_ROOT="$TEST_ROOT/auth-state" \
  MERV_SSH_TRUST_TEST_MODE=1 MERV_SSH_SKIP_PING=1 \
  MERV_SSH_TRUST_ROOT="$AUTH_TRUST_ROOT" MERV_SSH_TRUST_FILE="$AUTH_TRUST_ROOT/known_hosts.v1" \
  MERV_SSH_TRUST_PENDING_ROOT="$AUTH_TRUST_ROOT/pending" \
  MERV_SSH_TRUST_REQUESTS_ROOT="$AUTH_TRUST_ROOT/requests" \
  MERV_SSH_TRUST_STAGING_ROOT="$AUTH_TRUST_ROOT/staging" \
  MERV_SSH_TRUST_QUARANTINE_ROOT="$AUTH_TRUST_ROOT/quarantine" \
  MERV_SSH_TRUST_LOCK_PATH="$AUTH_TRUST_ROOT/state.lock" \
  sh -s <<'AUTH_TEST'
. "$MERV_BASE/settings/lib_ssh.sh" || exit 1
merv_ssh_node_mac() { printf '%s\n' none; }
get_node_ssh_port() { printf '%s\n' 22; }
get_node_ssh_user() { printf '%s\n' admin; }
merv_ssh_precheck 1 198.51.100.10
[ "$?" -ne 0 ] || exit 2
[ "${MERV_SSH_LAST_REASON:-}" = ssh-keys-missing ] || exit 3
exit 0
AUTH_TEST
[ "$?" -eq 0 ] || fail authenticated-ssh-permanent-key-gate
ok authenticated-ssh-still-requires-permanent-key

printf 'SSH_HOSTKEY_PROBE_REGRESSION_OK\n'
