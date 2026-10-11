#!/bin/sh
# Prove that the recursive Q fixture rejects the pre-fix body and each
# individual omission from its eleven frame-local variables.
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
ROOT=$(mktemp -d /tmp/mervlan-q-recursion-mutants.XXXXXXXX)
trap 'rm -rf "$ROOT"' 0 1 2 3 15
SOURCE="$BASE_DIR/settings/lib_maintenance_quiesce.sh"
FIXTURE="$TEST_DIR/maintenance_quiesce_recursive_fixture.sh"
COUNT=0

fail() { printf 'FAIL recursive mutant: %s\n' "$1" >&2; exit 1; }
reject_mutant() {
  _name=$1
  _source=$2
  _log="$ROOT/$_name.log"
  if FIXTURE_Q_SOURCE="$_source" FIXTURE_FRAMES_ONLY=1 sh "$FIXTURE" > "$_log" 2>&1; then
    fail "accepted $_name"
  fi
  grep -F 'FAIL recursive check' "$_log" >/dev/null 2>&1 || fail "$_name failed outside the recursive-frame assertions"
  COUNT=$((COUNT + 1))
  printf 'PASS rejected recursive mutant %s\n' "$_name"
}

# The prior recursive body, reconstructed by removing exactly both lines that
# declare the corrected function-local frames.
awk '
  /^[[:space:]]*local[[:space:]]+_mqnjw_(dir|ready)([[:space:]]|$)/ { removed++; next }
  { print }
  END { if (removed != 2) exit 2 }
' "$SOURCE" > "$ROOT/old-recursion-body.sh" || fail old-recursion-mutant-build
reject_mutant old-recursion-body "$ROOT/old-recursion-body.sh"

for variable in dir depth entry name pid ready node ip extra status next; do
  awk -v target="_mqnjw_$variable" '
    /^[[:space:]]*local[[:space:]]/ && index($0, target) {
      gsub(target, "")
      removed++
    }
    { print }
    END { if (removed != 1) exit 2 }
  ' "$SOURCE" > "$ROOT/missing-$variable.sh" || fail "missing-$variable-mutant-build"
  reject_mutant "missing-$variable" "$ROOT/missing-$variable.sh"
done

[ "$COUNT" -eq 12 ] || fail "mutation count $COUNT"
printf 'QUIESCE_RECURSIVE_MUTANTS_OK rejected=%s\n' "$COUNT"
