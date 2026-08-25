#!/bin/sh
# Keep supported hardware profiles authoritative and separate from candidates.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
PROBE="$ROOT/functions/hw_probe.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'DSL-AX82U) MODEL="DSL-AX82U"; ETH_PORTS="eth2 eth1 eth0"; LAN_PORT_LABELS="LAN1 LAN2 LAN3"; MAX_ETH_PORTS=3; WAN_IF="eth3" ;;' "$PROBE" \
  || fail 'DSL-AX82U verified hardware mapping is missing'

awk '
  /# === Supported Models ===/ { section = "supported"; next }
  /# === Models that needs port layout testing\/verification ===/ { section = "verification"; next }
  /# === Custom Support Mapper ===/ { section = "" }
  section != "" && match($0, /MODEL="[^"]+"/) {
    model = substr($0, RSTART + 7, RLENGTH - 8)
    if (section == "supported") supported[model] = 1
    else if (supported[model]) { print model; duplicate = 1 }
  }
  END { exit duplicate ? 1 : 0 }
' "$PROBE" >/dev/null || fail 'verification candidates duplicate a supported hardware profile'

printf 'HW_PROBE_MODEL_PROFILES_CONTRACT_OK\n'
