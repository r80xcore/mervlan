#!/bin/sh
# Exercise the production cron lifecycle functions with an isolated Merlin cru.

set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd) || exit 1
BOOT="$BASE_DIR/functions/mervlan_boot.sh"
LIB="$BASE_DIR/settings/lib_boot_integrity.sh"
TEST_ROOT="${TMPDIR:-/tmp}/mervlan-boot-cron-readback.$(date +%s).$$"
CRU_LIST="$TEST_ROOT/cru.list"
CRU_BIN="$TEST_ROOT/cru"
INJ_BASE=/jffs/addons/mervlan
CRON_NAME=mervlan_health

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup 0 1 2 3 15
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }
info() { :; }
warn() { :; }
error() { :; }

mkdir -p "$TEST_ROOT"
. "$LIB"

# Load the exact production functions without running the boot action dispatcher.
sed -n '/^enable_cron_now() {/,/^boot_verify_action_state() {/p' "$BOOT" |
    sed '$d' > "$TEST_ROOT/cron-functions.sh"
printf '\nboot_verify_action_state() { :; }\n' >> "$TEST_ROOT/cron-functions.sh"
. "$TEST_ROOT/cron-functions.sh"

cat > "$CRU_BIN" <<'CRU'
#!/bin/sh
case "${1:-}" in
  l)
    cat "$CRU_LIST"
    ;;
  d)
    if [ "${CRU_PRESERVE_MALFORMED:-0}" != 1 ]; then : > "$CRU_LIST"; fi
    ;;
  a)
    [ "${2:-}" = mervlan_health ] || exit 2
    printf '%s #%s#\n' "${3:-}" "$2" > "$CRU_LIST"
    ;;
  *) exit 2 ;;
esac
CRU
chmod 755 "$CRU_BIN"
export CRU_LIST

# Enable uses cru a, then the production readback must accept Merlin's literal
# trailing job-ID serialization through merv_boot_cron_state.
enable_cron_now || fail 'enable_cron_now failed'
_real='*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron #mervlan_health#'
_actual=$(cat "$CRU_LIST")
assert_eq "$_real" "$_actual" 'fake cru Merlin serialization'
assert_eq present "$MERV_BOOT_CRON_STATE" 'enable readback state'

# Deletion succeeds only after the shared predicate confirms the entry is gone.
disable_cron_now || fail 'disable_cron_now rejected a disappeared Merlin entry'
assert_eq absent "$MERV_BOOT_CRON_STATE" 'disable readback state'

# A malformed current-base residue left behind by cru d remains a hard failure.
printf '%s\n' '*/5 * * * * /jffs/addons/mervlan/functions/heal_event.sh cron-broken #mervlan_health#' > "$CRU_LIST"
CRU_PRESERVE_MALFORMED=1
export CRU_PRESERVE_MALFORMED
if disable_cron_now; then fail 'disable_cron_now accepted malformed current-base residue'; fi
assert_eq invalid "$MERV_BOOT_CRON_STATE" 'malformed disable readback state'

printf '%s\n' 'PASS: production cron readback recognizes Merlin output and rejects malformed residue'
