#!/bin/sh
# Source-isolated destructive fixtures: no live router paths are accessed.
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
python3 "$TEST_DIR/cleaner_phase6_contract.py"
