#!/bin/sh
# Focused Save/reconcile handoff regression.
#
# The Step 6 seam is extracted from save_settings.sh so this fixture exercises
# the production ordering and branching while keeping all node transport in a
# private fake runtime.  It proves that a token-backed Save publishes durable
# intent without starting inline Sync Nodes, and that a direct Save retains the
# same intent when its immediate sync start fails.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
SAVE_FILE="$BASE_DIR/functions/save_settings.sh"
ROOT="${TMPDIR:-/tmp}/mervlan-save-reconcile.$$"
trap 'rm -rf "$ROOT"' 0 1 2 3 15
mkdir -p "$ROOT/functions" "$ROOT/state"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

SNIP="$ROOT/step6.sh"
sed -n \
    '/^# STEP 6: Publish backend-owned node convergence/,/^# Publish a correlated terminal result/p' \
    "$SAVE_FILE" > "$SNIP"
[ -s "$SNIP" ] || fail 'Step 6 extraction is empty'

# The fake command deliberately fails.  The token case must not invoke it at
# all; the no-token case demonstrates that a failed immediate start leaves the
# durable current intent available for a later reconciler.
cat > "$ROOT/functions/sync_nodes.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$MERV_TEST_SYNC_CALLED"
exit 1
EOF
chmod 755 "$ROOT/functions/sync_nodes.sh"

SETTINGS_FILE="$ROOT/settings.json"
MERV_STATE_ROOT="$ROOT/state"
MERV_SETTINGS_RECONCILE_FILE="$MERV_STATE_ROOT/settings_reconcile.state"
MERV_TEST_SYNC_CALLED="$ROOT/sync-called"
MERV_TEST_INFO="$ROOT/info"
export BASE_DIR SNIP SETTINGS_FILE MERV_STATE_ROOT MERV_SETTINGS_RECONCILE_FILE
export MERV_TEST_INFO
export MERV_TEST_SYNC_CALLED MERV_MAX_NODES=10 MERV_BASE="$ROOT"

cat > "$SETTINGS_FILE" <<'EOF'
{
  "General": {
    "AUTO_SYNC_SETTINGS": "1"
  },
  "Nodes": {
    "NODE1": "192.0.2.10",
    "NODE1_ROLE": "standalone"
  },
  "VLAN": {
    "VLAN_01": "10"
  }
}
EOF

. "$BASE_DIR/settings/lib_json.sh"
. "$BASE_DIR/settings/lib_settings_reconcile.sh"

# Feed the same structured settings inputs consumed by Step 6, and verify the
# production readers resolve them before exercising the extracted branch.  The
# explicit auto-sync flag makes the computed _should_auto_sync state yes
# without needing SSH key files or a live node.
[ "$(json_get_flag AUTO_SYNC_SETTINGS '' "$SETTINGS_FILE")" = 1 ] || fail 'auto-sync input was not parsed'
[ "$(merv_node_list "$SETTINGS_FILE")" = '1 192.0.2.10' ] || fail 'configured node input was not parsed'
_node_list_digest=$(merv_node_list_digest) || fail 'node-list digest input was not available'
[ -n "$_node_list_digest" ] || fail 'node-list digest was empty'

run_step6() {
    save_token="$1"
    save_scope="${2:-full}"
    save_public="${3:-ok}"
    save_required="${4:-yes}"
    save_reset="${5:-yes}"
    if [ "$save_reset" = yes ]; then
        rm -f "$MERV_SETTINGS_RECONCILE_FILE"
    fi
    rm -f "$MERV_TEST_SYNC_CALLED"
    _save_public_status="$save_public"
    _save_node_sync_required="$save_required"
    _save_node_sync_after_digest=md5:current-settings
    SAVE_SCOPE="$save_scope"
    _save_auto_sync_changed=no
    if [ "$save_token" = token ]; then
        MERV_PROGRESS_TOKEN=browser-loss
        export MERV_PROGRESS_TOKEN
    else
        unset MERV_PROGRESS_TOKEN
    fi
    export _save_public_status _save_node_sync_required _save_node_sync_after_digest SAVE_SCOPE
    set +e
    sh -c '
        info() { printf "%s\n" "$*" >> "$MERV_TEST_INFO"; }
        warn() { :; }
        . "$BASE_DIR/settings/lib_json.sh"
        . "$BASE_DIR/settings/lib_settings_reconcile.sh"
        . "$SNIP"
    '
    run_rc=$?
    set -e
    [ "$run_rc" -eq 0 ] || fail "Step 6 failed ($save_token)"
}

run_step6 token override
merv_settings_reconcile_read || fail 'token Save did not publish intent'
_expected_current_digest=$(merv_settings_node_sync_digest "$SETTINGS_FILE") || fail 'current settings digest unavailable'
[ "$MERV_SETTINGS_RECONCILE_SETTINGS_DIGEST" = "$_expected_current_digest" ] || fail 'wrong token settings digest'
[ "$MERV_SETTINGS_RECONCILE_STATUS" = pending ] || fail 'token intent is not pending'
[ ! -e "$MERV_TEST_SYNC_CALLED" ] || fail 'token Save invoked inline Sync Nodes'
grep -q 'Node settings auto-sync queued after local save' "$MERV_TEST_INFO" || fail 'token Save did not take queued branch'
printf '%s\n' 'PASS: override Save without browser follow-up leaves durable intent'

run_step6 token full failed
merv_settings_reconcile_read || fail 'public failure lost durable intent'
[ "$MERV_SETTINGS_RECONCILE_STATUS" = pending ] || fail 'public failure did not retain pending intent'
[ ! -e "$MERV_TEST_SYNC_CALLED" ] || fail 'public failure started browser-owned sync'
printf '%s\n' 'PASS: public publication failure retains pending convergence intent'

# Public WebUI publication is not a cluster-commit precondition.  The same
# authoritative Save with automatic synchronization disabled remains a
# durable, manual-only obligation.
sed 's/"AUTO_SYNC_SETTINGS": "1"/"AUTO_SYNC_SETTINGS": "0"/' "$SETTINGS_FILE" > "$SETTINGS_FILE.auto-off"
mv "$SETTINGS_FILE.auto-off" "$SETTINGS_FILE"
run_step6 token full failed
merv_settings_reconcile_read || fail 'public failure with auto-sync disabled lost durable intent'
[ "$MERV_SETTINGS_RECONCILE_STATUS" = paused ] || fail 'public failure with auto-sync disabled did not pause intent'
printf '%s\n' 'PASS: public publication failure retains paused convergence intent'

# A public failure must not invent cluster work for a change already classified
# as MAIN/WebUI-local-only.
sed 's/"AUTO_SYNC_SETTINGS": "0"/"AUTO_SYNC_SETTINGS": "1"/' "$SETTINGS_FILE" > "$SETTINGS_FILE.auto-on"
mv "$SETTINGS_FILE.auto-on" "$SETTINGS_FILE"
run_step6 token full failed no
if merv_settings_reconcile_read; then
    fail 'public failure published unnecessary local-only node generation'
fi
printf '%s\n' 'PASS: public publication failure leaves local-only Save without node intent'

# With no configured targets the empty-set policy is vacuous success, even
# when the public artifact is unavailable.
cat > "$SETTINGS_FILE" <<'EOF'
{
  "General": { "AUTO_SYNC_SETTINGS": "1" },
  "VLAN": { "VLAN_01": "10" }
}
EOF
run_step6 token full failed yes
if merv_settings_reconcile_read; then
    fail 'public failure published node intent with no configured nodes'
fi
printf '%s\n' 'PASS: public publication failure with no nodes leaves no active intent'

# This is the actual Save Step 6 seam, not a direct library call: removing the
# final target clears a previously durable paused generation even while
# AUTO_SYNC_SETTINGS is disabled.
cat > "$SETTINGS_FILE" <<'EOF'
{
  "General": { "AUTO_SYNC_SETTINGS": "0" },
  "Nodes": { "NODE1": "192.0.2.10", "NODE1_ROLE": "standalone" },
  "VLAN": { "VLAN_01": "10" }
}
EOF
merv_settings_reconcile_publish md5:old-current cksum:old-current paused 0 0 || fail 'final-node fixture could not publish paused intent'
merv_settings_reconcile_read || fail 'final-node fixture did not create paused intent'
[ "$MERV_SETTINGS_RECONCILE_STATUS" = paused ] || fail 'final-node fixture intent is not paused'
cat > "$SETTINGS_FILE" <<'EOF'
{
  "General": { "AUTO_SYNC_SETTINGS": "0" },
  "VLAN": { "VLAN_01": "10" }
}
EOF
run_step6 token full ok yes no
if merv_settings_reconcile_read; then
    fail 'Save Step 6 left stale intent after final-node removal'
fi
printf '%s\n' 'PASS: Save Step 6 clears final-node paused intent'

# Restore the configured-node fixture used by the historical direct/CLI path.
cat > "$SETTINGS_FILE" <<'EOF'
{
  "General": {
    "AUTO_SYNC_SETTINGS": "1"
  },
  "Nodes": {
    "NODE1": "192.0.2.10",
    "NODE1_ROLE": "standalone"
  },
  "VLAN": {
    "VLAN_01": "10"
  }
}
EOF

run_step6 cli full
merv_settings_reconcile_read || fail 'CLI Save lost intent after failed sync start'
[ "$MERV_SETTINGS_RECONCILE_STATUS" = pending ] || fail 'CLI intent is not pending after failed start'
[ -e "$MERV_TEST_SYNC_CALLED" ] || fail 'CLI Save did not attempt immediate settings sync'
[ "$(cat "$MERV_TEST_SYNC_CALLED")" = '--settings-only' ] || fail 'CLI Save used unexpected sync mode'
grep -q 'Auto-syncing settings to nodes...' "$MERV_TEST_INFO" || fail 'CLI Save did not take immediate-sync branch'

printf 'SETTINGS_SAVE_RECONCILE_PUBLISH_OK\n'
