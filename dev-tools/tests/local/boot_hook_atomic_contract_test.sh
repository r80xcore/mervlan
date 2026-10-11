#!/bin/sh
# Exercise the production boot mutation functions against isolated paths.

set -eu
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
SOURCE="$BASE_DIR/functions/mervlan_boot.sh"
TEST_ROOT="${MERV_TEST_ROOT:-${TMPDIR:-/tmp}/mervlan-boot-atomic.$(date +%s).$$}"
CHILD_MODE=0
[ "${1:-}" = --signal-child ] && CHILD_MODE=1
LOCKDIR="$TEST_ROOT/locks"
SCRIPTS="$TEST_ROOT/scripts"
SERVICES="$SCRIPTS/services-start"
EVENT="$SCRIPTS/service-event"
TPL_DIR="$TEST_ROOT/templates"
TPL_MANAGER="$TPL_DIR/services-start.v2.tpl"
TPL_ADDON="$TPL_DIR/services-start-addon.v2.tpl"
TPL_EVENT="$TPL_DIR/service-event.v2.tpl"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }
assert_count() {
    _expected="$1" _pattern="$2" _file="$3" _label="$4"
    _actual=$(grep -cF "$_pattern" "$_file" 2>/dev/null) || :
    assert_eq "$_expected" "${_actual:-0}" "$_label"
}
file_mode() { ls -ld "$1" | awk '{ print substr($1,2,9) }'; }
no_tempdirs() {
    set -- "$SCRIPTS"/.mervlan-hook.*
    [ ! -e "$1" ] && [ ! -L "$1" ]
}
cleanup() { [ "$CHILD_MODE" = 1 ] || rm -rf "$TEST_ROOT"; }
if [ "$CHILD_MODE" = 0 ]; then trap cleanup 0 1 2 3 15; fi

if [ "$CHILD_MODE" = 0 ]; then
    mkdir -p "$LOCKDIR" "$SCRIPTS" "$TPL_DIR"
    . "$BASE_DIR/dev-tools/tests/local/selftest_context.sh" || exit 1
    merv_test_context_enable "$BASE_DIR" "$TEST_ROOT" || exit 1
    cat > "$TPL_MANAGER" <<'EOF'
# MerVLAN auto-enable VLAN on boot
if /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1; then
  /jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
fi
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
EOF
    cat > "$TPL_ADDON" <<'EOF'
# MerVLAN mount addon on boot
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh install </dev/null >/dev/null 2>&1 &
EOF
    cat > "$TPL_EVENT" <<'EOF'
# MerVLAN service-event handler
/jffs/addons/mervlan/functions/service-event-handler.sh "$@"
EOF
    chmod 644 "$TPL_MANAGER" "$TPL_ADDON" "$TPL_EVENT"
    printf '%s\n' '#!/bin/sh' '# user content stays outside MerVLAN markers' 'user_start() { :; }' \
        '# >>> another-addon >>>' 'another_addon_start() { :; }' '# <<< another-addon <<<' > "$SERVICES"
    chmod 750 "$SERVICES"
    export MERV_TEST_ROOT="$TEST_ROOT"
else
    mkdir -p "$LOCKDIR" "$SCRIPTS" "$TPL_DIR"
fi

MERV_BASE=/jffs/addons/mervlan
TEST_RUN=1
MERV_DISABLE_LOCKS=0
MARKER_PREFIX='### >>> MERVLAN START:'
MARKER_SUFFIX='### <<< MERVLAN END:'
MERV_BOOT_SCRIPTS_ROOT="$SCRIPTS"
export MERV_BASE TEST_RUN MERV_DISABLE_LOCKS MERV_BOOT_SCRIPTS_ROOT
. "$BASE_DIR/settings/lib_selftest_context.sh" || exit 1
. "$BASE_DIR/settings/lib_json.sh"
. "$BASE_DIR/settings/lib_boot_integrity.sh"

# Pull only the production mutation definitions out of the CLI entry script;
# dispatch and hardware actions remain out of this isolated unit fixture.
eval "$(sed -n '/^boot_mutation_fault()/,/^# copy_inject/p' "$SOURCE" | sed '$d')"
eval "$(sed -n '/^copy_inject() {/,/^}/p' "$SOURCE")"
eval "$(sed -n '/^remove_inject() {$/, /^}/p' "$SOURCE")"
_content_md5() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
info() { :; }
warn() { :; }
error() { :; }

LOCK_RELEASES=0
RELEASE_FAIL_ONCE=0
merv_owner_lock_acquire() {
    _lock="$1"
    mkdir -p "${_lock%/*}" 2>/dev/null || return 1
    mkdir "$_lock" 2>/dev/null || return 1
    MERV_LOCK_NONCE=test-owner
    MERV_LOCK_START=1
    return 0
}
merv_owner_lock_release() {
    _lock="$1" _nonce="${2:-}"
    LOCK_RELEASES=$((LOCK_RELEASES + 1))
    [ "$_nonce" = test-owner ] || return 1
    if [ "$RELEASE_FAIL_ONCE" = 1 ]; then RELEASE_FAIL_ONCE=0; return 1; fi
    rmdir "$_lock" 2>/dev/null
}

if [ "$CHILD_MODE" = 1 ]; then
    MERV_BOOT_TEST_FAULT=signal_before_commit
    export MERV_BOOT_TEST_FAULT
    copy_inject "$TPL_MANAGER" "$SERVICES"
    exit 9
fi

copy_inject "$TPL_MANAGER" "$SERVICES" || fail 'first manager insertion failed'
[ -x "$SERVICES" ] || fail 'new services-start is not executable'
[ "$(file_mode "$SERVICES")" = 'rwxr-x---' ] || fail 'safe existing mode was not preserved'
"${MERV_BOOT_SH_BIN:-sh}" -n "$SERVICES" || fail 'inserted script failed syntax validation'
assert_eq present "$(merv_boot_hook_state "$SERVICES" services-start)" 'manager state after insertion'
assert_count 1 '### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl' "$SERVICES" 'single manager block'
grep -qF 'user_start() { :; }' "$SERVICES" || fail 'unrelated user script content was lost'
grep -qF 'another_addon_start() { :; }' "$SERVICES" || fail 'another add-on block was lost'

chmod 644 "$SERVICES"
copy_inject "$TPL_MANAGER" "$SERVICES" || fail 'non-executable hook mode repair failed'
[ -x "$SERVICES" ] || fail 'mode repair left the startup script non-executable'
chmod 777 "$SERVICES"
copy_inject "$TPL_MANAGER" "$SERVICES" || fail 'unsafe writable hook mode repair failed'
[ "$(file_mode "$SERVICES")" = 'rwxr-xr-x' ] || fail 'unsafe group/world write permissions were preserved'

# A render/source failure occurs before the destination is touched.
cp -p "$SERVICES" "$TEST_ROOT/services.render-original"
_render_mode=$(file_mode "$SERVICES")
if copy_inject "$TEST_ROOT/templates/missing-template.v2.tpl" "$SERVICES"; then fail 'missing rendered template was accepted'; fi
cmp -s "$TEST_ROOT/services.render-original" "$SERVICES" || fail 'template failure changed destination bytes'
assert_eq "$_render_mode" "$(file_mode "$SERVICES")" 'template failure preserved mode'

_inode_before=$(ls -i "$SERVICES" | awk '{print $1}')
cp -p "$SERVICES" "$TEST_ROOT/services.idempotent"
copy_inject "$TPL_MANAGER" "$SERVICES" || fail 'identical manager repeat failed'
_inode_after=$(ls -i "$SERVICES" | awk '{print $1}')
assert_eq "$_inode_before" "$_inode_after" 'identical repeat inode'
cmp -s "$TEST_ROOT/services.idempotent" "$SERVICES" || fail 'identical repeat changed bytes'

# Replacement updates only its managed block; unrelated bytes survive.
sed 's/auto-enable VLAN/updated VLAN/' "$TPL_MANAGER" > "$TEST_ROOT/manager.new"
mv "$TEST_ROOT/manager.new" "$TPL_MANAGER"
copy_inject "$TPL_MANAGER" "$SERVICES" || fail 'manager replacement failed'
assert_count 1 '### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl' "$SERVICES" 'single manager after replacement'
grep -qF 'updated VLAN' "$SERVICES" || fail 'replacement payload was not installed'
grep -qF 'user_start() { :; }' "$SERVICES" || fail 'replacement lost user content'

copy_inject "$TPL_ADDON" "$SERVICES" || fail 'addon insertion failed'
copy_inject "$TPL_EVENT" "$EVENT" || fail 'service-event first install failed'
assert_eq present "$(merv_boot_hook_state "$SERVICES" services-start-addon)" 'addon state after insertion'
assert_eq present "$(merv_boot_hook_state "$EVENT" service-event)" 'service-event state after insertion'
assert_eq present "$(merv_boot_hook_state "$SERVICES" services-start)" 'manager remains independent'

# The exact manager sequence shipped at v0.53.15 reused the services-start.v2
# marker ID. It remains an exact safe replacement/removal candidate only in
# this historical form.
mkdir -p "$TEST_ROOT/v015-replace" "$TEST_ROOT/v015-remove"
for _v015_dir in "$TEST_ROOT/v015-replace" "$TEST_ROOT/v015-remove"; do
    cat > "$_v015_dir/services-start" <<'V015'
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
V015
    chmod 755 "$_v015_dir/services-start"
done
copy_inject "$TPL_MANAGER" "$TEST_ROOT/v015-replace/services-start" || fail 'v0.53.15 exact manager replacement failed'
assert_eq present "$(merv_boot_hook_state "$TEST_ROOT/v015-replace/services-start" services-start)" 'v0.53.15 manager replaced with current block'
remove_inject "$TPL_MANAGER" "$TEST_ROOT/v015-remove/services-start" || fail 'v0.53.15 exact manager removal failed'
assert_eq absent "$(merv_boot_hook_state "$TEST_ROOT/v015-remove/services-start" services-start)" 'v0.53.15 manager removal state'

# A malformed block carrying a known historical marker is not safe to replace
# or remove. Both operations must leave its original bytes and mode untouched.
mkdir -p "$TEST_ROOT/legacy-tampered"
cat > "$TEST_ROOT/legacy-tampered/services-start" <<'LEGACY'
#!/bin/sh
### >>> MERVLAN START: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh shield </dev/null >/dev/null 2>&1
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh manager </dev/null >/dev/null 2>&1 &
sleep 10
/jffs/addons/mervlan/functions/mervlan_boot_wrap.sh cron </dev/null >/dev/null 2>&1 &
/bin/true
### <<< MERVLAN END: services-start [tpl=services-start.v2.tpl md5=0123456789abcdef0123456789abcdef]
LEGACY
chmod 750 "$TEST_ROOT/legacy-tampered/services-start"
cp -p "$TEST_ROOT/legacy-tampered/services-start" "$TEST_ROOT/legacy-tampered/original"
_legacy_tampered_mode=$(file_mode "$TEST_ROOT/legacy-tampered/services-start")
if copy_inject "$TPL_MANAGER" "$TEST_ROOT/legacy-tampered/services-start"; then
    fail 'tampered historical manager block was replaced'
fi
cmp -s "$TEST_ROOT/legacy-tampered/original" "$TEST_ROOT/legacy-tampered/services-start" || fail 'failed replacement changed tampered legacy bytes'
assert_eq "$_legacy_tampered_mode" "$(file_mode "$TEST_ROOT/legacy-tampered/services-start")" 'failed replacement preserved tampered legacy mode'
if remove_inject "$TPL_MANAGER" "$TEST_ROOT/legacy-tampered/services-start"; then
    fail 'tampered historical manager block was removed'
fi
cmp -s "$TEST_ROOT/legacy-tampered/original" "$TEST_ROOT/legacy-tampered/services-start" || fail 'failed removal changed tampered legacy bytes'
assert_eq "$_legacy_tampered_mode" "$(file_mode "$TEST_ROOT/legacy-tampered/services-start")" 'failed removal preserved tampered legacy mode'

# Atomic staging runs the strict verifier over the rendered payload itself;
# an otherwise current template with an extra executable line is rejected.
mkdir -p "$TEST_ROOT/bad-rendered-template" "$TEST_ROOT/bad-rendered-destination"
cp "$TPL_MANAGER" "$TEST_ROOT/bad-rendered-template/services-start.v2.tpl"
printf '%s\n' '/bin/true' >> "$TEST_ROOT/bad-rendered-template/services-start.v2.tpl"
if copy_inject "$TEST_ROOT/bad-rendered-template/services-start.v2.tpl" \
    "$TEST_ROOT/bad-rendered-destination/services-start"; then
    fail 'atomic insertion accepted a non-canonical rendered manager template'
fi
[ ! -e "$TEST_ROOT/bad-rendered-destination/services-start" ] || fail 'rejected rendered template was committed'
set -- "$TEST_ROOT/bad-rendered-destination"/.mervlan-hook.*
[ ! -e "$1" ] && [ ! -L "$1" ] || fail 'rejected rendered template left a same-directory staging area'
no_tempdirs || fail 'earlier atomic mutation leaked a staging area'

# A non-newline-terminated script and CRLF script both retain user lines.
# Insert/remove boundaries normalize an absent final newline so the marker
# block stays on its own line; unrelated line content remains unchanged.
mkdir -p "$TEST_ROOT/no-newline"
printf '#!/bin/sh\nuser_tail' > "$TEST_ROOT/no-newline/services-start"
chmod 644 "$TEST_ROOT/no-newline/services-start"
copy_inject "$TPL_MANAGER" "$TEST_ROOT/no-newline/services-start" || fail 'first install on no-newline script failed'
grep -q '^user_tail$' "$TEST_ROOT/no-newline/services-start" || fail 'no-newline user content was changed'

mkdir -p "$TEST_ROOT/crlf"
printf '#!/bin/sh\r\nuser_crlf_line\r\n' > "$TEST_ROOT/crlf/services-start"
chmod 755 "$TEST_ROOT/crlf/services-start"
copy_inject "$TPL_MANAGER" "$TEST_ROOT/crlf/services-start" || fail 'CRLF script insertion failed'
grep -q 'user_crlf_line' "$TEST_ROOT/crlf/services-start" || fail 'CRLF user content was lost'
od -An -tx1 "$TEST_ROOT/crlf/services-start" > "$TEST_ROOT/crlf.hex" || fail 'CRLF byte inspection failed'
grep -q '0d 0a' "$TEST_ROOT/crlf.hex" || fail 'CRLF line endings were not preserved'

remove_inject "$TPL_MANAGER" "$SERVICES" || fail 'manager removal failed'
assert_eq absent "$(merv_boot_hook_state "$SERVICES" services-start)" 'manager state after removal'
assert_eq present "$(merv_boot_hook_state "$SERVICES" services-start-addon)" 'addon retained after manager removal'
remove_inject "$TPL_MANAGER" "$SERVICES" || fail 'idempotent manager removal failed'
remove_inject "$TPL_ADDON" "$SERVICES" || fail 'addon removal failed'
remove_inject "$TPL_EVENT" "$EVENT" || fail 'service-event removal failed'
grep -qF 'user_start() { :; }' "$SERVICES" || fail 'removal lost unrelated user content'

# Every pre-commit fault leaves the exact original bytes and mode in place.
copy_inject "$TPL_MANAGER" "$SERVICES" || fail 'could not establish mutation-fault baseline'
cp -p "$SERVICES" "$TEST_ROOT/services.original"
_mode_original=$(file_mode "$SERVICES")
for _fault in stage_write no_space stage_chmod chmod syntax rename lock_acquire; do
    if [ "$_fault" = lock_acquire ]; then
        # Lock acquisition fails before any destination-local stage exists.
        :
    fi
    MERV_BOOT_TEST_FAULT="$_fault"
    export MERV_BOOT_TEST_FAULT
    if copy_inject "$TPL_ADDON" "$SERVICES"; then fail "$_fault fault reported success"; fi
    unset MERV_BOOT_TEST_FAULT
    cmp -s "$TEST_ROOT/services.original" "$SERVICES" || fail "$_fault fault changed original bytes"
    assert_eq "$_mode_original" "$(file_mode "$SERVICES")" "$_fault original mode"
    no_tempdirs || fail "$_fault fault leaked a staging directory"
    [ ! -d "$LOCKDIR/services-start.lock" ] || fail "$_fault fault leaked the owner lock"
done

# A failed first release is retried with the same owner identity and still
# returns failure, even though the committed bytes pass readback.
RELEASE_FAIL_ONCE=1
MERV_BOOT_TEST_FAULT=none
export MERV_BOOT_TEST_FAULT
if copy_inject "$TPL_ADDON" "$SERVICES"; then fail 'lock release failure was reported as success'; fi
unset MERV_BOOT_TEST_FAULT
[ ! -d "$LOCKDIR/services-start.lock" ] || fail 'owner lock retry left a lock behind'
assert_eq present "$(merv_boot_hook_state "$SERVICES" services-start-addon)" 'post-release-failure committed state'

# Readback failure happens after rename and must report failure without claiming
# the original was untouched.
remove_inject "$TPL_ADDON" "$SERVICES" || fail 'could not clear addon before postcommit test'
cp -p "$SERVICES" "$TEST_ROOT/services.precommit"
MERV_BOOT_TEST_FAULT=post_readback
export MERV_BOOT_TEST_FAULT
if copy_inject "$TPL_ADDON" "$SERVICES"; then fail 'post-commit readback failure was reported as success'; fi
unset MERV_BOOT_TEST_FAULT
[ "${MERV_BOOT_MUTATION_POSTCOMMIT_FAILURE:-0}" = 1 ] || fail 'post-commit failure was not classified'
! cmp -s "$TEST_ROOT/services.precommit" "$SERVICES" || fail 'post-commit fault did not expose the committed rename'

# TERM before rename cleans its exclusive stage and owner lock; original bytes
# and mode remain unchanged.
remove_inject "$TPL_ADDON" "$SERVICES" || fail 'could not clear addon before signal test'
cp -p "$SERVICES" "$TEST_ROOT/services.signal-original"
_signal_mode=$(file_mode "$SERVICES")
if MERV_TEST_ROOT="$TEST_ROOT" TEST_RUN=1 sh "$0" --signal-child; then
    fail 'SIGTERM before commit unexpectedly succeeded'
else
    _signal_rc=$?
fi
assert_eq 143 "$_signal_rc" 'SIGTERM exit status'
cmp -s "$TEST_ROOT/services.signal-original" "$SERVICES" || fail 'SIGTERM changed original bytes'
assert_eq "$_signal_mode" "$(file_mode "$SERVICES")" 'SIGTERM original mode'
no_tempdirs || fail 'SIGTERM leaked a staging directory'
[ ! -d "$LOCKDIR/services-start.lock" ] || fail 'SIGTERM leaked an owner lock'

printf 'BOOT_HOOK_ATOMIC_CONTRACT_OK\n'
