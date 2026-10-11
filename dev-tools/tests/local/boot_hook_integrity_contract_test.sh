#!/bin/sh
# Production boot-hook integrity scanner contract using isolated script files.

set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
LIB="$BASE_DIR/settings/lib_boot_integrity.sh"
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-boot-integrity.$(date +%s).$$"
SCRIPTS="$TEST_ROOT/scripts"
SERVICES="$SCRIPTS/services-start"
EVENT="$SCRIPTS/service-event"
SETTINGS="$TEST_ROOT/settings.json"
CRON="$TEST_ROOT/cru"
MERV_BASE=/jffs/addons/mervlan

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup 0 1 2 3 15
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }

[ -r "$LIB" ] || fail 'production boot-integrity library is missing'
. "$BASE_DIR/settings/lib_json.sh"
. "$LIB"
export MERV_BASE
mkdir -p "$SCRIPTS"

_md5=0123456789abcdef0123456789abcdef
write_manager() {
    _file="$1"
    _tpl="${2:-services-start.v2.tpl}"
    _base="${3:-/jffs/addons/mervlan}"
    _md5_value="${4:-$_md5}"
    cat > "$_file" <<EOF
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=$_tpl md5=$_md5_value]
# manager hook fixture
if $_base/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  $_base/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 10
$_base/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=$_tpl md5=$_md5_value]
EOF
    chmod 755 "$_file"
}
write_addon() {
    _file="$1"
    _tpl="${2:-services-start-addon.v2.tpl}"
    _base="${3:-/jffs/addons/mervlan}"
    cat >> "$_file" <<EOF
### >>> MERVLAN START: services-start [tpl=$_tpl md5=$_md5]
$_base/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=$_tpl md5=$_md5]
EOF
    chmod 755 "$_file"
}
write_event() {
    _file="$1"
    _tpl="${2:-service-event.v2.tpl}"
    _base="${3:-/jffs/addons/mervlan}"
    cat > "$_file" <<EOF
#!/bin/sh
### >>> MERVLAN START: service-event [tpl=$_tpl md5=$_md5]
$_base/functions/service-event-handler.sh "\$@"
### <<< MERVLAN END: service-event [tpl=$_tpl md5=$_md5]
EOF
    chmod 755 "$_file"
}
write_legacy_manager() {
    _file="$1"
    cat > "$_file" <<'HOOK'
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
    chmod 755 "$_file"
}
write_custom_manager() {
    _file="$1" _tpl="$2" _body="$3"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' "### >>> MERVLAN START: services-start [tpl=$_tpl md5=$_md5]"
        cat "$_body"
        printf '%s\n' "### <<< MERVLAN END: services-start [tpl=$_tpl md5=$_md5]"
    } > "$_file"
    chmod 755 "$_file"
    write_addon "$_file"
}
write_custom_addon() {
    _file="$1" _tpl="$2" _body="$3"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' "### >>> MERVLAN START: services-start [tpl=$_tpl md5=$_md5]"
        cat "$_body"
        printf '%s\n' "### <<< MERVLAN END: services-start [tpl=$_tpl md5=$_md5]"
    } > "$_file"
    chmod 755 "$_file"
}
write_custom_event() {
    _file="$1" _tpl="$2" _body="$3"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' "### >>> MERVLAN START: service-event [tpl=$_tpl md5=$_md5]"
        cat "$_body"
        printf '%s\n' "### <<< MERVLAN END: service-event [tpl=$_tpl md5=$_md5]"
    } > "$_file"
    chmod 755 "$_file"
}
write_settings() {
    _boot="$1"
    _node="${2:-0}"
    cat > "$SETTINGS" <<EOF
{
  "General": {
    "BOOT_ENABLED": "$_boot",
    "IS_NODE": "$_node"
  }
}
EOF
}
state() {
    _expect="$1" _path="$2" _name="$3" _label="$4"
    merv_boot_hook_state "$_path" "$_name" >/dev/null
    _actual="$MERV_BOOT_HOOK_STATE"
    assert_eq "$_expect" "$_actual" "$_label (reason=${MERV_BOOT_HOOK_REASON:-unset})"
}
verify_main_reject() {
    _path="$1" _reason="$2" _allow="${3:-0}" _label="$4"
    if merv_boot_verify_local 1 main "$_path" "$EVENT" "$SETTINGS" "$CRON" \
        /jffs/addons/mervlan "$SCRIPTS" "$_allow"; then
        fail "$_label passed the complete local verifier"
    fi
    assert_eq "$_reason" "$MERV_BOOT_VERIFY_REASON" "$_label top-level reason"
}
bad_manager_case() {
    _label="$1" _body="$2" _hook_reason="$3" _verify_reason="$4" _allow="${5:-0}"
    _dir="$TEST_ROOT/bad-$_label"
    mkdir -p "$_dir"
    write_custom_manager "$_dir/services-start" services-start.v2.tpl "$_body"
    state invalid "$_dir/services-start" services-start "$_label manager payload"
    assert_eq "$_hook_reason" "$MERV_BOOT_HOOK_REASON" "$_label manager payload reason"
    verify_main_reject "$_dir/services-start" "$_verify_reason" "$_allow" "$_label manager fixture"
}

# The two historical false-green states must be independently observable.
printf '#!/bin/sh\n' > "$SERVICES"
chmod 755 "$SERVICES"
write_addon "$SERVICES"
write_event "$EVENT"
state absent "$SERVICES" services-start 'manager absent while addon is installed'
state present "$SERVICES" services-start-addon 'addon remains distinct from manager'
state present "$EVENT" service-event 'event block present'

# Supported pre-shield markers are recognizable for safe replacement/removal,
# but are not reported as healthy effective manager hooks.
mkdir -p "$TEST_ROOT/legacy-manager" "$TEST_ROOT/legacy-addon" "$TEST_ROOT/legacy-event"
write_legacy_manager "$TEST_ROOT/legacy-manager/services-start"
write_addon "$TEST_ROOT/legacy-manager/services-start"
mkdir -p "$TEST_ROOT/unknown-legacy-version"
sed 's/services-start.v2.tpl/node-services.v1.tpl/g' \
    "$TEST_ROOT/legacy-manager/services-start" > "$TEST_ROOT/unknown-legacy-version/services-start"
chmod 755 "$TEST_ROOT/unknown-legacy-version/services-start"
state invalid "$TEST_ROOT/legacy-manager/services-start" services-start 'legacy manager is not effective'
assert_eq legacy_replaceable "$MERV_BOOT_HOOK_REASON" 'legacy manager replacement reason'
state invalid "$TEST_ROOT/unknown-legacy-version/services-start" services-start 'unknown historical marker version'
assert_eq marker_template_unknown "$MERV_BOOT_HOOK_REASON" 'unknown legacy template reason'
write_settings 0 0
if merv_boot_verify_local 0 main "$TEST_ROOT/legacy-manager/services-start" "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS"; then
    fail 'legacy manager was accepted as effectively disabled'
fi
assert_eq manager_invalid "$MERV_BOOT_VERIFY_REASON" 'legacy manager fails effective-state verification'

cat > "$TEST_ROOT/legacy-addon/services-start" <<'HOOK'
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
sleep 5
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
chmod 755 "$TEST_ROOT/legacy-addon/services-start"
state present "$TEST_ROOT/legacy-addon/services-start" services-start-addon 'v0.53.15 delayed install-wrapper addon form'
cat > "$TEST_ROOT/body-legacy-addon-redirected" <<'BODY'
sleep 5
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
BODY
mkdir -p "$TEST_ROOT/legacy-addon-redirected"
write_custom_addon "$TEST_ROOT/legacy-addon-redirected/services-start" services-start-addon.v1.tpl "$TEST_ROOT/body-legacy-addon-redirected"
state present "$TEST_ROOT/legacy-addon-redirected/services-start" services-start-addon 'v0.53.15 delayed install-wrapper addon v1 form'

# A complete old rollback baseline is accepted only with the explicit legacy
# manager option, while its exact addon/event forms remain independently valid.
mkdir -p "$TEST_ROOT/legacy-complete"
write_legacy_manager "$TEST_ROOT/legacy-complete/services-start"
cat >> "$TEST_ROOT/legacy-complete/services-start" <<'HOOK'
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
sleep 5
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef]
HOOK
write_event "$TEST_ROOT/legacy-complete/service-event" service-event.v2.tpl

# BOOT_ENABLED=1 with only the independent addon block is the historical
# false-green case: the effective manager state must still fail verification.
write_settings 1 0
printf '%s\n' > "$TEST_ROOT/cron.list"
if merv_boot_verify_local 1 main "$SERVICES" "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS"; then
    fail 'enabled preference with addon-only startup block was accepted'
fi
assert_eq manager_mismatch "${MERV_BOOT_VERIFY_REASON:-}" 'enabled manager missing reason'

write_manager "$SERVICES"
write_addon "$SERVICES"
state present "$SERVICES" services-start 'manager block present'
write_settings 1 0
_real_merlin_cron='*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron #mervlan_health#'
printf '%s\n' "$_real_merlin_cron" > "$TEST_ROOT/cron.list"
cat > "$CRON" <<EOF
#!/bin/sh
[ "\${1:-}" = l ] || exit 2
cat "$TEST_ROOT/cron.list"
EOF
chmod 755 "$CRON"
merv_boot_cron_state "$CRON" /jffs/addons/mervlan >/dev/null || fail 'present cron entry was not readable'
assert_eq present "$MERV_BOOT_CRON_STATE" 'present cron listing state'
merv_boot_cron_listing_state "$_real_merlin_cron" /jffs/addons/mervlan/functions/heal_event.sh ||
    fail 'literal Merlin cru listing was not parseable'
assert_eq present "$MERV_BOOT_CRON_LISTING_STATE" 'literal Merlin listing state'
merv_boot_verify_local 1 main "$SERVICES" "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS" ||
    fail "healthy ON did not verify with real Merlin cron serialization: ${MERV_BOOT_VERIFY_REASON:-unset}"
merv_boot_verify_local 1 main "$TEST_ROOT/legacy-complete/services-start" \
    "$TEST_ROOT/legacy-complete/service-event" "$SETTINGS" "$CRON" \
    /jffs/addons/mervlan "$SCRIPTS" 1 ||
    fail "explicit rollback rejected the exact legacy manager/addon/event baseline: ${MERV_BOOT_VERIFY_REASON:-unset}"
assert_eq verified "$MERV_BOOT_VERIFY_REASON" 'complete historical rollback verification'

mkdir -p "$TEST_ROOT/current-v1"
write_manager "$TEST_ROOT/current-v1/services-start" services-start.v1.tpl
write_addon "$TEST_ROOT/current-v1/services-start" services-start-addon.v1.tpl
write_event "$TEST_ROOT/current-v1/service-event" service-event.v1.tpl
state present "$TEST_ROOT/current-v1/services-start" services-start 'current v1 manager sequence'
state present "$TEST_ROOT/current-v1/services-start" services-start-addon 'current v1 addon sequence'
state present "$TEST_ROOT/current-v1/service-event" service-event 'current v1 event sequence'
merv_boot_verify_local 1 main "$TEST_ROOT/current-v1/services-start" \
    "$TEST_ROOT/current-v1/service-event" "$SETTINGS" "$CRON" \
    /jffs/addons/mervlan "$SCRIPTS" ||
    fail "healthy v1 ON did not verify: ${MERV_BOOT_VERIFY_REASON:-unset}"
assert_eq verified "$MERV_BOOT_VERIFY_REASON" 'complete current v1 verification'

# Repository tag v0.53.15 used the same manager/addon v1/v2 IDs with an older
# unguarded manager sequence and a five-second addon delay. Recognize those
# exact historical sequences, but promote the manager only in explicit legacy
# mode; a current v2 marker with the older direct-manager payload stays invalid.
cat > "$TEST_ROOT/body-v015-manager" <<'BODY'
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
BODY
mkdir -p "$TEST_ROOT/v015-manager" "$TEST_ROOT/v015-addon"
write_custom_manager "$TEST_ROOT/v015-manager/services-start" services-start.v2.tpl "$TEST_ROOT/body-v015-manager"
state invalid "$TEST_ROOT/v015-manager/services-start" services-start 'exact v0.53.15 manager payload'
assert_eq legacy_replaceable "$MERV_BOOT_HOOK_REASON" 'v0.53.15 manager legacy reason'
verify_main_reject "$TEST_ROOT/v015-manager/services-start" manager_invalid 0 'v0.53.15 ordinary verification'
merv_boot_verify_local 1 main "$TEST_ROOT/v015-manager/services-start" \
    "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS" 1 ||
    fail "explicit rollback rejected the exact v0.53.15 manager: ${MERV_BOOT_VERIFY_REASON:-unset}"
assert_eq verified "$MERV_BOOT_VERIFY_REASON" 'v0.53.15 explicit rollback verification'
mkdir -p "$TEST_ROOT/v015-manager-v1"
write_custom_manager "$TEST_ROOT/v015-manager-v1/services-start" services-start.v1.tpl "$TEST_ROOT/body-v015-manager"
state invalid "$TEST_ROOT/v015-manager-v1/services-start" services-start 'exact v0.53.15 manager v1 payload'
assert_eq legacy_replaceable "$MERV_BOOT_HOOK_REASON" 'v0.53.15 manager v1 legacy reason'
merv_boot_verify_local 1 main "$TEST_ROOT/v015-manager-v1/services-start" \
    "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS" 1 ||
    fail "explicit rollback rejected the exact v0.53.15 v1 manager: ${MERV_BOOT_VERIFY_REASON:-unset}"
assert_eq verified "$MERV_BOOT_VERIFY_REASON" 'v0.53.15 manager v1 rollback verification'
cat > "$TEST_ROOT/body-v015-addon" <<'BODY'
sleep 5
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
BODY
write_custom_addon "$TEST_ROOT/v015-addon/services-start" services-start-addon.v2.tpl "$TEST_ROOT/body-v015-addon"
state present "$TEST_ROOT/v015-addon/services-start" services-start-addon 'exact v0.53.15 addon payload'

# Retain the isolated fixture formats already used by the contract harness.
printf '%s\n' 'mervlan_health */5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron' > "$TEST_ROOT/cron.list"
merv_boot_cron_state "$CRON" /jffs/addons/mervlan >/dev/null || fail 'cru-form cron entry was not readable'
assert_eq present "$MERV_BOOT_CRON_STATE" 'cru-form listing state'
printf '%s\n' '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron' > "$TEST_ROOT/cron.list"
merv_boot_cron_state "$CRON" /jffs/addons/mervlan >/dev/null || fail 'schedule-form cron entry was not readable'
assert_eq present "$MERV_BOOT_CRON_STATE" 'schedule-form listing state'
printf '%s\n' '/jffs/addons/mervlan/functions/heal_event.sh cron' > "$TEST_ROOT/cron.list"
merv_boot_cron_state "$CRON" /jffs/addons/mervlan >/dev/null || fail 'direct command fixture was not readable'
assert_eq present "$MERV_BOOT_CRON_STATE" 'direct command fixture state'

# Malformed arguments for the current-base executable are invalid residue.
for _bad_cron in \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron-broken #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron2 #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron extra #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron #wrong_job#'; do
    printf '%s\n' "$_bad_cron" > "$TEST_ROOT/cron.list"
    merv_boot_cron_state "$CRON" /jffs/addons/mervlan >/dev/null || fail "cron listing inspection failed for $_bad_cron"
    assert_eq invalid "$MERV_BOOT_CRON_STATE" "malformed current-base cron residue for $_bad_cron"
done
printf '%s\n' '*/5 * * * * /tmp/not-mervlan/functions/heal_event.sh cron #mervlan_health#' > "$TEST_ROOT/cron.list"
merv_boot_cron_state "$CRON" /jffs/addons/mervlan >/dev/null || fail 'wrong-base cron listing inspection failed'
assert_eq absent "$MERV_BOOT_CRON_STATE" 'wrong-base cron executable is unrelated'
write_manager "$SERVICES"
write_addon "$SERVICES"
write_event "$EVENT"
write_settings 1 0
for _bad_cron in \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron-broken #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron2 #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron extra #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron #wrong_job#'; do
    printf '%s\n' "$_bad_cron" > "$TEST_ROOT/cron.list"
    verify_main_reject "$SERVICES" cron_invalid 0 "ON verifier rejects $_bad_cron"
done
printf '%s\n' "$_real_merlin_cron" > "$TEST_ROOT/cron.list"

# Older rollback/restore callers may verify one of the explicitly recognized
# pre-current manager payloads with the controller's retained read-only
# library. Ordinary target verification still rejects that block as current.
if merv_boot_verify_local 1 main "$TEST_ROOT/legacy-manager/services-start" \
    "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS"; then
    fail 'ordinary ON verification accepted a legacy manager payload'
fi
assert_eq manager_invalid "$MERV_BOOT_VERIFY_REASON" 'ordinary verification keeps legacy manager invalid'
merv_boot_verify_local 1 main "$TEST_ROOT/legacy-manager/services-start" \
    "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS" 1 ||
    fail "legacy rollback verification rejected a recognized .15 manager: ${MERV_BOOT_VERIFY_REASON:-unset}"
assert_eq verified "$MERV_BOOT_VERIFY_REASON" 'recognized legacy rollback reason'

# Exact command/control-flow allowlist cases. Each fixture keeps a valid addon
# and event baseline so the complete verifier reaches the manager predicate.
cat > "$TEST_ROOT/body-wrong-base" <<'BODY'
if /tmp/not-mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  /tmp/not-mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 10
/tmp/not-mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
BODY
bad_manager_case wrong-base "$TEST_ROOT/body-wrong-base" marker_payload_invalid addon_invalid

cat > "$TEST_ROOT/body-no-shield-gate" <<'BODY'
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
BODY
bad_manager_case no-shield-gate "$TEST_ROOT/body-no-shield-gate" marker_payload_invalid addon_invalid

cat > "$TEST_ROOT/body-manager-outside-gate" <<'BODY'
if /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  :
fi
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
BODY
bad_manager_case manager-outside-gate "$TEST_ROOT/body-manager-outside-gate" marker_payload_invalid addon_invalid

cat > "$TEST_ROOT/body-missing-fi" <<'BODY'
if /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
BODY
bad_manager_case missing-fi "$TEST_ROOT/body-missing-fi" hook_script_syntax_invalid addon_invalid

cat > "$TEST_ROOT/body-sleep-999" <<'BODY'
if /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 999
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
BODY
bad_manager_case sleep-999 "$TEST_ROOT/body-sleep-999" marker_payload_invalid addon_invalid

cat > "$TEST_ROOT/body-extra-manager-command" <<'BODY'
if /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
/bin/true
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
BODY
bad_manager_case extra-manager-command "$TEST_ROOT/body-extra-manager-command" marker_payload_invalid addon_invalid

cat > "$TEST_ROOT/body-current-manager" <<'BODY'
if /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
BODY
mkdir -p "$TEST_ROOT/cross-legacy-marker" "$TEST_ROOT/cross-current-marker"
write_custom_manager "$TEST_ROOT/cross-legacy-marker/services-start" node-services.v1.tpl "$TEST_ROOT/body-current-manager"
state invalid "$TEST_ROOT/cross-legacy-marker/services-start" services-start 'legacy marker with current manager payload'
assert_eq marker_template_unknown "$MERV_BOOT_HOOK_REASON" 'undocumented legacy marker ID is not an alias'

cat > "$TEST_ROOT/body-legacy-manager" <<'BODY'
sleep 10
/jffs/addons/mervlan/functions/mervlan_manager.sh boot >/dev/null 2>&1 || :
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot.sh cronenable >/dev/null 2>&1 || :
BODY
write_custom_manager "$TEST_ROOT/cross-current-marker/services-start" services-start.v2.tpl "$TEST_ROOT/body-legacy-manager"
state invalid "$TEST_ROOT/cross-current-marker/services-start" services-start 'current marker with unsupported direct-manager payload'
assert_eq marker_payload_invalid "$MERV_BOOT_HOOK_REASON" 'current marker/legacy payload reason'

cat > "$TEST_ROOT/body-legacy-addon" <<'BODY'
sleep 5
/jffs/addons/mervlan/install.sh
BODY
mkdir -p "$TEST_ROOT/cross-current-addon"
write_custom_addon "$TEST_ROOT/cross-current-addon/services-start" services-start-addon.v2.tpl "$TEST_ROOT/body-legacy-addon"
state invalid "$TEST_ROOT/cross-current-addon/services-start" services-start-addon 'current addon marker with legacy direct-install payload'
assert_eq marker_payload_invalid "$MERV_BOOT_HOOK_REASON" 'current addon marker/legacy payload reason'

cat > "$TEST_ROOT/body-extra-current-addon" <<'BODY'
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
/bin/true
BODY
mkdir -p "$TEST_ROOT/extra-current-addon"
write_custom_addon "$TEST_ROOT/extra-current-addon/services-start" services-start-addon.v2.tpl "$TEST_ROOT/body-extra-current-addon"
state invalid "$TEST_ROOT/extra-current-addon/services-start" services-start-addon 'current addon extra executable command'
assert_eq marker_payload_invalid "$MERV_BOOT_HOOK_REASON" 'current addon extra command reason'

cat > "$TEST_ROOT/body-tampered-legacy-manager" <<'BODY'
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
/bin/true
BODY
mkdir -p "$TEST_ROOT/tampered-legacy-manager"
write_custom_manager "$TEST_ROOT/tampered-legacy-manager/services-start" services-start.v2.tpl "$TEST_ROOT/body-tampered-legacy-manager"
state invalid "$TEST_ROOT/tampered-legacy-manager/services-start" services-start 'tampered legacy manager extra command'
assert_eq marker_payload_invalid "$MERV_BOOT_HOOK_REASON" 'tampered legacy manager reason'
verify_main_reject "$TEST_ROOT/tampered-legacy-manager/services-start" addon_invalid 1 'tampered legacy manager allow_legacy fixture'

cat > "$TEST_ROOT/body-tampered-legacy-addon" <<'BODY'
sleep 5
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
/bin/true
BODY
mkdir -p "$TEST_ROOT/tampered-legacy-addon"
write_custom_addon "$TEST_ROOT/tampered-legacy-addon/services-start" services-start-addon.v2.tpl "$TEST_ROOT/body-tampered-legacy-addon"
state invalid "$TEST_ROOT/tampered-legacy-addon/services-start" services-start-addon 'tampered legacy addon extra command'
assert_eq marker_payload_invalid "$MERV_BOOT_HOOK_REASON" 'tampered legacy addon reason'

cat > "$TEST_ROOT/body-tampered-legacy-event" <<'BODY'
/jffs/addons/mervlan/functions/service-event-handler.sh "$@"
/bin/true
BODY
mkdir -p "$TEST_ROOT/tampered-legacy-event"
write_custom_event "$TEST_ROOT/tampered-legacy-event/service-event" service-event.v1.tpl "$TEST_ROOT/body-tampered-legacy-event"
state invalid "$TEST_ROOT/tampered-legacy-event/service-event" service-event 'tampered legacy event extra command'
assert_eq marker_payload_invalid "$MERV_BOOT_HOOK_REASON" 'tampered legacy event reason'

cat > "$TEST_ROOT/body-extra-current-event" <<'BODY'
/jffs/addons/mervlan/functions/service-event-handler.sh "$@"
/bin/true
BODY
mkdir -p "$TEST_ROOT/extra-current-event"
write_custom_event "$TEST_ROOT/extra-current-event/service-event" service-event.v2.tpl "$TEST_ROOT/body-extra-current-event"
state invalid "$TEST_ROOT/extra-current-event/service-event" service-event 'current event extra executable command'
assert_eq marker_payload_invalid "$MERV_BOOT_HOOK_REASON" 'current event extra command reason'

if merv_boot_verify_local 1 main "$TEST_ROOT/unknown-legacy-version/services-start" \
    "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS" 1; then
    fail 'legacy rollback verification accepted an unknown marker version'
fi
assert_eq addon_invalid "$MERV_BOOT_VERIFY_REASON" 'unknown legacy marker fails top-level verification'

# OFF rejects a still-installed manager even when the saved preference is OFF.
write_settings 0 0
if merv_boot_verify_local 0 main "$SERVICES" "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS"; then
    fail 'BOOT_ENABLED=0 with manager present was accepted'
fi
assert_eq manager_mismatch "${MERV_BOOT_VERIFY_REASON:-}" 'disabled manager mismatch reason'

# Healthy OFF requires an authoritative cron listing that proves absence.
printf '#!/bin/sh\n' > "$SERVICES"
chmod 755 "$SERVICES"
write_addon "$SERVICES"
: > "$TEST_ROOT/cron.list"
merv_boot_cron_state "$CRON" /jffs/addons/mervlan >/dev/null || fail 'absent cron entry was not readable'
assert_eq absent "$MERV_BOOT_CRON_STATE" 'absent cron listing state'
for _bad_cron in \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron-broken #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron2 #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron extra #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh #mervlan_health#' \
    '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron #wrong_job#'; do
    printf '%s\n' "$_bad_cron" > "$TEST_ROOT/cron.list"
    if merv_boot_verify_local 0 main "$SERVICES" "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS"; then
        fail "BOOT_ENABLED=0 accepted malformed current-base cron residue: $_bad_cron"
    fi
    assert_eq cron_invalid "$MERV_BOOT_VERIFY_REASON" "OFF verifier rejects $_bad_cron"
done
: > "$TEST_ROOT/cron.list"
merv_boot_verify_local 0 main "$SERVICES" "$EVENT" "$SETTINGS" "$CRON" /jffs/addons/mervlan "$SCRIPTS" ||
    fail "healthy OFF did not verify: ${MERV_BOOT_VERIFY_REASON:-unset}"

# CRLF markers and payload remain inspectable.
sed 's/$/\r/' "$EVENT" > "$TEST_ROOT/event.crlf"
mv "$TEST_ROOT/event.crlf" "$EVENT"
chmod 755 "$EVENT"
state present "$EVENT" service-event 'CRLF service-event block'

# Orphan, crossing, duplicates, bad metadata, wrong payload and unknown shapes fail closed.
cp "$SERVICES" "$TEST_ROOT/services.good"
printf '%s\n' '### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]' >> "$SERVICES"
state invalid "$SERVICES" services-start 'unclosed START'
cp "$TEST_ROOT/services.good" "$SERVICES"
printf '%s\n' '### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]' >> "$SERVICES"
state invalid "$SERVICES" services-start 'orphan END'
cp "$TEST_ROOT/services.good" "$SERVICES"
write_manager "$SERVICES"
cat "$SERVICES" >> "$TEST_ROOT/manager.duplicate"
mv "$TEST_ROOT/manager.duplicate" "$SERVICES"
state invalid "$SERVICES" services-start 'duplicate manager'
cp "$TEST_ROOT/services.good" "$SERVICES"
write_addon "$SERVICES"
state invalid "$SERVICES" services-start 'duplicate addon makes shared file unsafe'
cp "$TEST_ROOT/services.good" "$SERVICES"
sed 's/END: services-start \[tpl=services-start-addon.v2.tpl md5=0123456789abcdef0123456789abcdef\]/END: services-start [tpl=services-start-addon.v2.tpl md5=abcdef0123456789abcdef0123456789]/' "$SERVICES" > "$TEST_ROOT/services.badmd5"
mv "$TEST_ROOT/services.badmd5" "$SERVICES"
state invalid "$SERVICES" services-start 'START/END metadata mismatch'
cp "$TEST_ROOT/services.good" "$SERVICES"
sed 's/ shield / wrong /' "$SERVICES" > "$TEST_ROOT/services.badpayload"
mv "$TEST_ROOT/services.badpayload" "$SERVICES"
state invalid "$SERVICES" services-start 'manager payload missing shield'
cp "$TEST_ROOT/services.good" "$SERVICES"
sed 's/ manager / wrong-manager /' "$SERVICES" > "$TEST_ROOT/services.badmanager"
mv "$TEST_ROOT/services.badmanager" "$SERVICES"
state invalid "$SERVICES" services-start 'manager payload missing manager call'
cp "$TEST_ROOT/services.good" "$SERVICES"
sed 's/ cron / missing-cron /' "$SERVICES" > "$TEST_ROOT/services.badcron"
mv "$TEST_ROOT/services.badcron" "$SERVICES"
state invalid "$SERVICES" services-start 'manager payload missing cron call'
cp "$TEST_ROOT/services.good" "$SERVICES"
printf '%s\n' '### >>> MERVLAN START: services-start [tpl=other.v2.tpl md5=0123456789abcdef0123456789abcdef]' >> "$SERVICES"
state invalid "$SERVICES" services-start 'unknown MerVLAN marker shape'
cp "$TEST_ROOT/services.good" "$SERVICES"
printf '%s\n' '### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=short]' >> "$SERVICES"
state invalid "$SERVICES" services-start 'malformed md5 marker'
cp "$TEST_ROOT/services.good" "$SERVICES"
cat > "$TEST_ROOT/services.crossed" <<EOF
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=$_md5]
### >>> MERVLAN START: services-start [tpl=services-start-addon.v2.tpl md5=$_md5]
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install
### <<< MERVLAN END: services-start [tpl=services-start-addon.v2.tpl md5=$_md5]
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=$_md5]
EOF
chmod 755 "$TEST_ROOT/services.crossed"
state invalid "$TEST_ROOT/services.crossed" services-start 'nested and crossed markers'

# Missing and structurally unsafe destinations have distinct states.
mkdir "$TEST_ROOT/missing" "$TEST_ROOT/symlink" "$TEST_ROOT/directory"
state absent "$TEST_ROOT/missing/services-start" services-start 'missing hook file'
ln -s "$SERVICES" "$TEST_ROOT/symlink/services-start"
state invalid "$TEST_ROOT/symlink/services-start" services-start 'symlink hook file'
mkdir "$TEST_ROOT/directory/services-start"
state invalid "$TEST_ROOT/directory/services-start" services-start 'directory hook path'
mkdir -p "$TEST_ROOT/no-shebang" "$TEST_ROOT/malformed-script"
printf '%s\n' '### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]' > "$TEST_ROOT/no-shebang/services-start"
state invalid "$TEST_ROOT/no-shebang/services-start" services-start 'marker file without usable shebang'
cat > "$TEST_ROOT/malformed-script/services-start" <<'HOOK'
#!/bin/sh
if then
HOOK
chmod 755 "$TEST_ROOT/malformed-script/services-start"
state invalid "$TEST_ROOT/malformed-script/services-start" services-start 'malformed startup script'

# An existing startup script remains an active entry point even when it has no
# MerVLAN markers; an unusable script must not be mistaken for healthy absence.
mkdir -p "$TEST_ROOT/unmarked-no-shebang" "$TEST_ROOT/unmarked-no-execute"
printf '%s\n' 'user_start() { :; }' > "$TEST_ROOT/unmarked-no-shebang/services-start"
chmod 755 "$TEST_ROOT/unmarked-no-shebang/services-start"
state invalid "$TEST_ROOT/unmarked-no-shebang/services-start" services-start 'unmarked active script without shebang'
assert_eq hook_shebang_invalid "$MERV_BOOT_HOOK_REASON" 'unmarked script shebang reason'
printf '%s\n' '#!/bin/sh' 'user_start() { :; }' > "$TEST_ROOT/unmarked-no-execute/services-start"
chmod 644 "$TEST_ROOT/unmarked-no-execute/services-start"
state invalid "$TEST_ROOT/unmarked-no-execute/services-start" services-start 'unmarked active script without execute bit'
assert_eq hook_not_executable "$MERV_BOOT_HOOK_REASON" 'unmarked script mode reason'

# Strict preference parsing rejects missing, unsupported and contradictory JSON.
write_settings 1 0
assert_eq 1 "$(merv_boot_read_preference "$SETTINGS")" 'strict preference 1'
write_settings 0 0
assert_eq 0 "$(merv_boot_read_preference "$SETTINGS")" 'strict preference 0'
printf '%s\n' '{"General":{"IS_NODE":"0"}}' > "$SETTINGS"
if merv_boot_read_preference "$SETTINGS"; then fail 'missing preference was accepted'; fi
printf '%s\n' '{"General":{"BOOT_ENABLED":"true","IS_NODE":"0"}}' > "$SETTINGS"
if merv_boot_read_preference "$SETTINGS"; then fail 'unsupported preference was accepted'; fi
printf '%s\n' '{"General":{"BOOT_ENABLED":"0","BOOT_ENABLED":"1","IS_NODE":"0"}}' > "$SETTINGS"
if merv_boot_read_preference "$SETTINGS"; then fail 'contradictory duplicate preference was accepted'; fi
printf '%s\n' '{"General":{"IS_NODE":"0"},"Other":{"BOOT_ENABLED":"1"}}' > "$SETTINGS"
if merv_boot_read_preference "$SETTINGS"; then fail 'preference outside General was accepted'; fi
printf '%s\n' '{ malformed' > "$SETTINGS"
if merv_boot_read_preference "$SETTINGS"; then fail 'malformed JSON preference was accepted'; fi

# Unavailable cron listing is unknown and must not pass the OFF predicate.
write_settings 0 0
printf '#!/bin/sh\n' > "$SERVICES"
chmod 755 "$SERVICES"
write_addon "$SERVICES"
cat > "$TEST_ROOT/cru.fail" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$TEST_ROOT/cru.fail"
if merv_boot_cron_state "$TEST_ROOT/cru.fail" /jffs/addons/mervlan >/dev/null; then
    fail 'failed cron listing was reported as known'
fi
assert_eq unknown "$MERV_BOOT_CRON_STATE" 'failed cron listing state'
assert_eq listing_failed "$MERV_BOOT_CRON_REASON" 'failed cron listing reason'
if merv_boot_verify_local 0 main "$SERVICES" "$EVENT" "$SETTINGS" "$TEST_ROOT/cru.fail" /jffs/addons/mervlan "$SCRIPTS"; then
    fail 'OFF with an unavailable cru listing was accepted'
fi

# Mode-based unreadability is observable for an ordinary test user directly.
# Root can read mode-000 files, so it drops privilege with runuser when present.
mkdir "$TEST_ROOT/unreadable"
printf '%s\n' '#!/bin/sh' > "$TEST_ROOT/unreadable/services-start"
chmod 000 "$TEST_ROOT/unreadable/services-start"
if [ -r "$TEST_ROOT/unreadable/services-start" ] && [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1; then
    _unreadable=$(runuser -u nobody -- /bin/sh -c '. "$1"; . "$2"; merv_boot_hook_state "$3" services-start' sh "$BASE_DIR/settings/lib_json.sh" "$LIB" "$TEST_ROOT/unreadable/services-start" 2>/dev/null) || _unreadable=''
    assert_eq unknown "$_unreadable" 'unreadable startup file state'
elif [ -r "$TEST_ROOT/unreadable/services-start" ]; then
    printf '%s\n' 'SKIP: unreadable-mode hook fixture (no privilege-drop tool available for root)' >&2
else
    state unknown "$TEST_ROOT/unreadable/services-start" services-start 'unreadable startup file'
fi
chmod 600 "$TEST_ROOT/unreadable/services-start"
assert_eq cron_unknown "${MERV_BOOT_VERIFY_REASON:-}" 'unavailable cron reason'

printf 'BOOT_HOOK_INTEGRITY_CONTRACT_OK\n'
