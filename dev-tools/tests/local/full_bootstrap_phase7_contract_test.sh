#!/bin/sh
# Real-process, source-isolated Phase-7 parser/SSH/inert-stage fixtures.
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
python3 "$TEST_DIR/full_bootstrap_phase7_contract.py"
