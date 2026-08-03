#!/bin/sh
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
export MERV_BASE
sh "$TEST_DIR/settings_sync_contract_test.sh"

