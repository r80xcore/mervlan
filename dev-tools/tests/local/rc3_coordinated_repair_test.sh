#!/bin/sh
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
MERV_TEST_ENGINE="$ROOT/dev-tools/experiments/rc3-lean-repair-luna/candidates/update_mervlan_repair_RC3_coordinated.sh" \
	python3 "$ROOT/dev-tools/experiments/rc3-lean-repair-luna/tests/test_coordinated_candidate.py"
