#!/bin/sh
# Runtime R3 fault-injection fixture.  The setter and finalization snippets
# are extracted verbatim from save_settings.sh; only JSON/log/sync operations
# are stubbed so this test exercises the production transaction seam.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
SAVE_FILE="$BASE_DIR/functions/save_settings.sh"
export BASE_DIR
ROOT="${TMPDIR:-/tmp}/mervlan-save-transaction-runtime.$$"
mkdir -p "$ROOT/settings" "$ROOT/public/settings" "$ROOT/bin"
trap 'rm -rf "$ROOT"' 0 1 2 3 15

AUTH="$ROOT/settings/settings.json"
OLD="$ROOT/old.json"
CAND="$ROOT/settings/candidate.json"
TMP_KV="$ROOT/tmp.kv"
TMP_SORTED="$ROOT/tmp.sorted"
TMP_JSON="$ROOT/tmp.public.json"
TMP_OVERRIDE="$ROOT/tmp.override"
TMP_CLIENTMETA="$ROOT/tmp.clientmeta"
TMP_NORMAL="$ROOT/tmp.normal"
STATUS="$ROOT/status"
PUBLIC_SETTINGS_DIR="$ROOT/public/settings"
PUBLIC_SETTINGS_FILE="$PUBLIC_SETTINGS_DIR/settings.json"
SETTINGS_FILE="$AUTH"
SETTINGSDIR="$ROOT/settings"
RESULTDIR="$ROOT"
MERV_MAX_NODES=10
MERV_IDENTITY_NONCE='runtime.1.1.1'
MERV_STATE_ROOT="$ROOT/state"
PUBLIC_MERV_BASE="$ROOT/public"
SAVE_SCOPE=full

printf '%s\n' '{"General":{"AUTO_SYNC_SETTINGS":"1"},"Hardware_Override":{"MAIN":{"MAP_OVERRIDE":"0"}},"ClientMeta":{"MAC_SHIELD_OVERRIDES":"","CLIENT_NAME_OVERRIDES":""}}' > "$OLD"

# Pull exact production snippets.  The test must fail if the source markers
# move or either seam becomes empty.
SETTERS="$ROOT/setters.sh"
FINALIZE="$ROOT/finalize.sh"
sed -n '/^save_candidate_is_empty_object() {/,/^rm -f "${TMP_OVERRIDE}" "${TMP_CLIENTMETA}" "${TMP_NORMAL}"/p' "$SAVE_FILE" > "$SETTERS"
awk '
    /^chmod 600 "\$[{]_save_candidate[}]"/ { seen++; if (seen == 2) emit=1 }
    emit { print }
    emit && /^# STEP 6/ { exit }
' "$SAVE_FILE" | sed '$d' > "$FINALIZE"
[ -s "$SETTERS" ] || { printf 'FAIL: setter seam extraction\n' >&2; exit 1; }
[ -s "$FINALIZE" ] || { printf 'FAIL: finalization seam extraction\n' >&2; exit 1; }

log_noop() { :; }

run_setter_case() {
    case_name="$1"
    fault="$2"
    cp "$OLD" "$AUTH"
    cp "$AUTH" "$CAND"
    : > "$TMP_KV"; : > "$TMP_JSON"; : > "$TMP_OVERRIDE"; : > "$TMP_CLIENTMETA"; : > "$TMP_NORMAL"
    case "$case_name" in
        normal|normal_noop)
            SAVE_SCOPE=normal
            printf 'AUTO_SYNC_SETTINGS\t0\n' > "$TMP_SORTED"
            ;;
        override|override_noop)
            SAVE_SCOPE=override
            printf 'OVERRIDE_MAIN_MAP_OVERRIDE\t1\n' > "$TMP_OVERRIDE"
            : > "$TMP_SORTED"
            ;;
        clientmeta)
            SAVE_SCOPE=clientmeta
            printf 'MAC_SHIELD_OVERRIDES\tAA:BB:CC:DD:EE:FF\n' > "$TMP_CLIENTMETA"
            : > "$TMP_SORTED"
            ;;
    esac
    _save_candidate="$CAND"
    export case_name fault SAVE_SCOPE AUTH CAND SETTINGS_FILE SETTINGSDIR RESULTDIR
    export _save_candidate MERV_IDENTITY_NONCE SETTERS
    export TMP_KV TMP_SORTED TMP_JSON TMP_OVERRIDE TMP_CLIENTMETA TMP_NORMAL
    set +e
    sh -c '
        error() { :; }; warn() { :; }; info() { :; }
        json_apply_kv_file() {
            [ "$fault" = normal ] && return 1
            printf "%s\n" '{"new":"normal"}' > "$2"
        }
        json_set_section_value() {
            [ "$fault" = general ] || [ "$fault" = clientmeta ] || [ "$fault" = noop ] && return 1
            printf "%s\n" '{"new":"section"}' > "$4"
        }
        json_set_section2_value() {
            [ "$fault" = override ] || [ "$fault" = noop ] && return 1
            printf "%s\n" '{"new":"override"}' > "$5"
        }
        . "$SETTERS"
    '
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || { printf 'FAIL: %s setter fault unexpectedly succeeded\n' "$case_name" >&2; exit 1; }
    cmp -s "$AUTH" "$OLD" || { printf 'FAIL: %s setter changed authoritative bytes\n' "$case_name" >&2; exit 1; }
}

run_setter_case normal normal
run_setter_case override override
run_setter_case clientmeta clientmeta
run_setter_case normal_noop noop
run_setter_case override_noop noop

run_missing_section_case() {
    section="$1"
    cp "$OLD" "$AUTH"
    : > "$TMP_KV"; : > "$TMP_JSON"; : > "$TMP_OVERRIDE"; : > "$TMP_CLIENTMETA"; : > "$TMP_NORMAL"
    if [ "$section" = general ]; then
        cat > "$CAND" <<'EOF'
{
  "ClientMeta": {
    "MAC_SHIELD_OVERRIDES": "",
    "CLIENT_NAME_OVERRIDES": ""
  }
}
EOF
        SAVE_SCOPE=normal
        printf 'AUTO_SYNC_SETTINGS\t0\n' > "$TMP_SORTED"
    else
        cat > "$CAND" <<'EOF'
{
  "General": {
    "AUTO_SYNC_SETTINGS": "1"
  }
}
EOF
        SAVE_SCOPE=override
        printf 'OVERRIDE_MAIN_MAP_OVERRIDE\t1\n' > "$TMP_OVERRIDE"
        : > "$TMP_SORTED"
    fi
    _save_candidate="$CAND"
    export section SAVE_SCOPE _save_candidate MERV_IDENTITY_NONCE SETTERS
    export TMP_KV TMP_SORTED TMP_JSON TMP_OVERRIDE TMP_CLIENTMETA TMP_NORMAL
    set +e
    sh -c '
        . "$BASE_DIR/settings/lib_json.sh"
        error() { :; }; warn() { :; }; info() { :; }
        json_apply_kv_file() { :; }
        . "$SETTERS"
    '
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || { printf 'FAIL: missing %s section migration failed\n' "$section" >&2; exit 1; }
    if [ "$section" = general ]; then
        grep -q '"General"' "$CAND" || { printf 'FAIL: General section was not seeded\n' >&2; exit 1; }
        grep -q '"AUTO_SYNC_SETTINGS": "0"' "$CAND" || { printf 'FAIL: General value was not verified\n' >&2; exit 1; }
    else
        grep -q '"Hardware_Override"' "$CAND" || { printf 'FAIL: Hardware_Override section was not seeded\n' >&2; exit 1; }
        grep -q '"MAP_OVERRIDE": "1"' "$CAND" || { printf 'FAIL: Hardware_Override value was not verified\n' >&2; exit 1; }
    fi
    cmp -s "$AUTH" "$OLD" || { printf 'FAIL: missing %s migration touched authoritative bytes\n' "$section" >&2; exit 1; }
}

run_missing_section_case general
run_missing_section_case hardware

run_empty_candidate_case() {
    section="$1"
    cp "$OLD" "$AUTH"
    printf '{\n}\n' > "$CAND"
    : > "$TMP_KV"; : > "$TMP_SORTED"; : > "$TMP_OVERRIDE"; : > "$TMP_CLIENTMETA"; : > "$TMP_NORMAL"
    case "$section" in
        general)
            SAVE_SCOPE=normal
            printf 'AUTO_SYNC_SETTINGS\t0\n' > "$TMP_SORTED"
            ;;
        hardware)
            SAVE_SCOPE=override
            printf 'OVERRIDE_MAIN_MAP_OVERRIDE\t1\n' > "$TMP_OVERRIDE"
            ;;
        clientmeta)
            SAVE_SCOPE=clientmeta
            printf 'MAC_SHIELD_OVERRIDES\tAA:BB:CC:DD:EE:FF\n' > "$TMP_CLIENTMETA"
            ;;
    esac
    _save_candidate="$CAND"
    export SAVE_SCOPE _save_candidate MERV_IDENTITY_NONCE SETTERS
    export TMP_KV TMP_SORTED TMP_JSON TMP_OVERRIDE TMP_CLIENTMETA TMP_NORMAL
    set +e
    sh -c '
        . "$BASE_DIR/settings/lib_json.sh"
        error() { :; }; warn() { :; }; info() { :; }
        json_apply_kv_file() { :; }
        . "$SETTERS"
        json_validate_file "$CAND"
    '
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || { printf 'FAIL: formatted-empty %s migration produced invalid JSON\n' "$section" >&2; exit 1; }
    case "$section" in
        general) grep -q '"AUTO_SYNC_SETTINGS": "0"' "$CAND" || { printf 'FAIL: formatted-empty General value missing\n' >&2; exit 1; } ;;
        hardware) grep -q '"MAP_OVERRIDE": "1"' "$CAND" || { printf 'FAIL: formatted-empty Hardware_Override value missing\n' >&2; exit 1; } ;;
        clientmeta) grep -q '"MAC_SHIELD_OVERRIDES": "AA:BB:CC:DD:EE:FF"' "$CAND" || { printf 'FAIL: formatted-empty ClientMeta value missing\n' >&2; exit 1; } ;;
    esac
    cmp -s "$AUTH" "$OLD" || { printf 'FAIL: formatted-empty %s migration touched authoritative bytes\n' "$section" >&2; exit 1; }
}

run_empty_candidate_case general
run_empty_candidate_case hardware
run_empty_candidate_case clientmeta

run_finalize_case() {
    fault="$1"
    expect_rc="$2"
    public_fault="${3:-0}"
    cp "$OLD" "$AUTH"
    printf '%s\n' '{"new":"committed"}' > "$CAND"
    : > "$TMP_KV"; : > "$TMP_SORTED"; : > "$TMP_JSON"
    rm -f "$PUBLIC_SETTINGS_FILE" "$STATUS"
    _save_candidate="$CAND"
    export fault public_fault AUTH CAND SETTINGS_FILE SETTINGSDIR RESULTDIR STATUS
    export _save_candidate FINALIZE
    export TMP_KV TMP_SORTED TMP_JSON TMP_OVERRIDE TMP_CLIENTMETA TMP_NORMAL
    export PUBLIC_MERV_BASE PUBLIC_SETTINGS_DIR PUBLIC_SETTINGS_FILE
    set +e
    sh -c '
        error() { :; }; warn() { :; }; info() { :; }
        merv_settings_node_sync_digest() { return 1; }
        json_validate_file() { [ "$fault" != validate ]; }
        chmod() { [ "$fault" = chmod ] && return 1; command chmod "$@"; }
        mv() { [ "$fault" = rename ] && return 1; command mv "$@"; }
        cp() {
            if [ "$public_fault" = 1 ] && [ "$2" = "$PUBLIC_SETTINGS_FILE" ]; then return 1; fi
            command cp "$@"
        }
        . "$FINALIZE"
        printf "%s\n" "${_save_public_status:-unset}" > "$STATUS"
    '
    rc=$?
    set -e
    if [ "$expect_rc" = 0 ]; then
        [ "$rc" -eq 0 ] || { printf 'FAIL: finalization unexpectedly failed (%s)\n' "$fault" >&2; exit 1; }
    else
        [ "$rc" -ne 0 ] || { printf 'FAIL: finalization fault unexpectedly succeeded (%s)\n' "$fault" >&2; exit 1; }
    fi
    if [ "$expect_rc" = 0 ]; then
        [ "$(cat "$AUTH")" = '{"new":"committed"}' ] || { printf 'FAIL: committed bytes are not all-new (%s)\n' "$fault" >&2; exit 1; }
    else
        cmp -s "$AUTH" "$OLD" || { printf 'FAIL: pre-commit fault changed authoritative bytes (%s)\n' "$fault" >&2; exit 1; }
    fi
}

run_finalize_case validate 1
run_finalize_case chmod 1
run_finalize_case rename 1
run_finalize_case none 0 0

# Publication failure is post-commit: bytes are new, status is failed, and
# the production Step 6 guard must not invoke node synchronization.
run_finalize_case none 0 1
[ "$(cat "$STATUS")" = failed ] || { printf 'FAIL: publication failure was not truthful\n' >&2; exit 1; }
[ ! -e "$ROOT/node-sync-called" ] || { printf 'FAIL: node sync ran after publication failure\n' >&2; exit 1; }

printf 'SETTINGS_SAVE_TRANSACTION_RUNTIME_OK\n'
