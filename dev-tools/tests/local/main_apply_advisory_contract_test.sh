#!/bin/sh
# Behavioral coverage for the best-effort MAIN-only Apply advisory and durable
# memory evidence. These helpers are extracted from the manager so this test
# never invokes an actual router mutation.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
MANAGER="$MERV_BASE/functions/mervlan_manager.sh"
ROOT="${TMPDIR:-/tmp}/mervlan-main-apply-advisory.$$"
mkdir -p "$ROOT" || exit 2
trap 'rm -rf "$ROOT"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

extract_helper() {
  _name="$1" _out="$2"
  awk -v name="$_name" '
    $0 == name "() {" { emit=1 }
    emit { print }
    emit && /^}$/ { exit }
  ' "$MANAGER" > "$_out"
  [ -s "$_out" ] || return 1
}

extract_helper merv_main_apply_memory_snapshot "$ROOT/memory.sh" || fail 'memory helper extraction'
extract_helper merv_main_apply_advisory_record "$ROOT/advisory.sh" || fail 'advisory helper extraction'
. "$ROOT/memory.sh"
. "$ROOT/advisory.sh"
info() { :; }

MERV_IS_NODE=0
DRY_RUN=no
MERV_MANAGER_MODE=normal
MERV_STATE_ROOT="$ROOT/state"
MERV_MAIN_APPLY_MEMORY_FILE="$ROOT/state/main_apply_memory.json"
MERV_MAIN_APPLY_ADVISORY_FILE="$ROOT/public/main_apply_advisory.json"
MERV_MAIN_APPLY_ADVISORY_COOLDOWN_SEC=300
MEMORY_PREFLIGHT_FILE="${MERV_MAIN_APPLY_MEMORY_FILE%.json}.preflight.json"
MEMORY_VERIFIED_FILE="${MERV_MAIN_APPLY_MEMORY_FILE%.json}.verified.json"

merv_main_apply_memory_snapshot preflight || fail 'live MAIN memory snapshot return'
[ -s "$MEMORY_PREFLIGHT_FILE" ] || fail 'preflight memory snapshot exists'
grep -Fq '"stage":"preflight"' "$MEMORY_PREFLIGHT_FILE" || fail 'preflight memory snapshot stage'
grep -Fq '"sunreclaim_kb":' "$MEMORY_PREFLIGHT_FILE" || fail 'preflight snapshot includes unreclaimable slab'
merv_main_apply_memory_snapshot verified || fail 'verified MAIN memory snapshot return'
[ -s "$MEMORY_VERIFIED_FILE" ] || fail 'verified memory snapshot exists'
grep -Fq '"stage":"verified"' "$MEMORY_VERIFIED_FILE" || fail 'verified memory snapshot stage'
grep -Fq '"stage":"preflight"' "$MEMORY_PREFLIGHT_FILE" || fail 'verified snapshot overwrote preflight evidence'
pass 'live MAIN durable preflight and verified memory snapshots'

merv_main_apply_advisory_record || fail 'live MAIN advisory return'
[ -s "$MERV_MAIN_APPLY_ADVISORY_FILE" ] || fail 'live MAIN advisory exists'
grep -Fq '"scope":"main-apply"' "$MERV_MAIN_APPLY_ADVISORY_FILE" || fail 'advisory scope'
grep -Fq '"cooldown_sec":300' "$MERV_MAIN_APPLY_ADVISORY_FILE" || fail 'advisory cooldown'
pass 'live MAIN cooldown advisory'

rm -f "$MEMORY_PREFLIGHT_FILE" "$MEMORY_VERIFIED_FILE" "$MERV_MAIN_APPLY_ADVISORY_FILE"
DRY_RUN=yes
merv_main_apply_memory_snapshot preflight
merv_main_apply_advisory_record
[ ! -e "$MEMORY_PREFLIGHT_FILE" ] && [ ! -e "$MEMORY_VERIFIED_FILE" ] && [ ! -e "$MERV_MAIN_APPLY_ADVISORY_FILE" ] || fail 'dry-run should not publish evidence'
pass 'dry-run suppression'

DRY_RUN=no
MERV_IS_NODE=1
merv_main_apply_memory_snapshot preflight
merv_main_apply_advisory_record
[ ! -e "$MEMORY_PREFLIGHT_FILE" ] && [ ! -e "$MEMORY_VERIFIED_FILE" ] && [ ! -e "$MERV_MAIN_APPLY_ADVISORY_FILE" ] || fail 'node should not publish MAIN evidence'
pass 'node suppression'

MERV_IS_NODE=0
MERV_MANAGER_MODE=boot
merv_main_apply_memory_snapshot preflight
merv_main_apply_advisory_record
[ ! -e "$MEMORY_PREFLIGHT_FILE" ] && [ ! -e "$MEMORY_VERIFIED_FILE" ] && [ ! -e "$MERV_MAIN_APPLY_ADVISORY_FILE" ] || fail 'boot should not publish MAIN advisory'
pass 'boot suppression'

printf 'MAIN_APPLY_ADVISORY_CONTRACT_OK\n'
