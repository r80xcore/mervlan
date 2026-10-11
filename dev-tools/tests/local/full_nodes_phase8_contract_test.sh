#!/bin/sh
# Source-isolated real-process Phase-8 ownership and coordinator fixtures.
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
python3 "$TEST_DIR/full_nodes_phase8_contract.py"
