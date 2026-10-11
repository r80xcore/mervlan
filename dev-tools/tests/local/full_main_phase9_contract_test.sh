#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
python3 dev-tools/tests/local/full_main_phase9_contract.py
