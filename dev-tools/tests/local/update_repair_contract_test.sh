#!/bin/sh
# Focused local gate for standalone Repair and normal Update source stability.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
REPAIR="$ROOT/functions/update_mervlan_repair.sh"
UPDATER="$ROOT/functions/update_mervlan.sh"
MANIFEST="$ROOT/functions/update_mervlan_repair.manifest"
FOCUSED="$ROOT/dev-tools/experiments/rc3-lean-repair-luna/tests/test_standalone_persistent_repair.py"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[ "$(sha256sum "$UPDATER" | awk '{print $1}')" = \
  7bb9dcdd0593d156f1a0d7ff15002790a3fff3759c655d7513251d0038440fff ] ||
  fail 'normal Update source changed from the approved checkpoint'
[ "$(awk 'NR > 2 && NF == 2 { n++ } END { print n+0 }' "$MANIFEST")" -eq 58 ] ||
  fail 'Repair manifest must retain the trusted 58-entry contract'
if grep -Eq '^[[:space:]]*\.[[:space:]]|^[[:space:]]*source[[:space:]]' "$REPAIR"; then
  fail 'standalone Repair must not source installed MerVLAN code'
fi
grep -Fq 'READY' "$REPAIR" || fail 'persistent backup readiness marker missing'
grep -Fq 'recover_main' "$REPAIR" || fail 'independent recovery entrypoint missing'
grep -Fq 'journal_append state=committed' "$REPAIR" || fail 'durable transaction journal missing'
pass 'normal Update is unchanged; standalone Repair remains source-free with persistent recovery'

python3 "$FOCUSED"
