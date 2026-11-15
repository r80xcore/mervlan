#!/bin/sh
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$DIR/tests"
/bin/sh -n update_mervlan_repair_lean.sh
if command -v busybox >/dev/null 2>&1; then busybox ash -n update_mervlan_repair_lean.sh; fi
python3 test_prepublication_cleanup.py
sh test_update_exit_trap_semantics.sh
# Deliberately NOT invoking the full suite automatically; run and retain logs:
echo 'For full candidate suite: cd tests && python3 test_lean_repair.py'
