#!/bin/sh
#
# ──────────────────────────────────────────────────────────────────────────── #
#                                                                              #
#   /$$      /$$                     /$$    /$$ /$$        /$$$$$$  /$$   /$$  #
#  | $$$    /$$$                    | $$   | $$| $$       /$$__  $$| $$$ | $$  #
#  | $$$$  /$$$$  /$$$$$$   /$$$$$$ | $$   | $$| $$      | $$  \ $$| $$$$| $$  #
#  | $$ $$/$$ $$ /$$__  $$ /$$__  $$|  $$ / $$/| $$      | $$$$$$$$| $$ $$ $$  #
#  | $$  $$$| $$| $$$$$$$$| $$  \__/ \  $$ $$/ | $$      | $$__  $$| $$  $$$$  #
#  | $$\  $ | $$| $$_____/| $$        \  $$$/  | $$      | $$  | $$| $$\  $$$  #
#  | $$ \/  | $$|  $$$$$$$| $$         \  $/   | $$$$$$$$| $$  | $$| $$ \  $$  #
#  |__/     |__/ \_______/|__/          \_/    |________/|__/  |__/|__/  \__/  #
#                                                                              #
# ──────────────────────────────────────────────────────────────────────────── #
#                - File: device_support_mapper.sh || version="0.50"            #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:  Creates a map template by detecting physical LAN/WAN port order  #
#             to enable MerVLAN support with correct device mapping.           #
# ──────────────────────────────────────────────────────────────────────────── #
#
# - Fully standalone: no dependencies on MerVLAN libs
#
# - Designed to give the developer accurate device mapping info.
#   for adding official support into hw_probe.sh.
#
# - Can be run before MerVLAN is installed (prints report + saves it under /tmp) 
#   but can also be used to patch an existing MerVLAN install's hw_probe.sh automatically.
#
# - Uses carrier snapshot BEFORE prompt/plug (detects 0->1 reliably)
#
# - Robust nvram detection + re-read before report
#
# - Allows for accurate hw_probe.sh case snippet generation
#
# - IMPORTANT! While this tools can add temporary local support by patching
#   hw_probe.sh, this is NOT a substitute for official support. Please share
#   the generated report with the MerVLAN developer team for inclusion in
#   future releases.
# -----------------------------
# Config
# -----------------------------
MERV_BASE="/jffs/addons/mervlan"
DEFAULT_HW_PROBE="$MERV_BASE/functions/hw_probe.sh"

RESULTDIR="/tmp/mervlan_tmp/results"
mkdir -p "$RESULTDIR" 2>/dev/null || :

HEADER_LINE="# === Custom Support Mapper ==="
PLACEHOLDER_LINE="# DEVICE_SUPPORT_MAPPER_PLACEHOLDER"

# Optional CLI:
#   --hw-probe /path/to/hw_probe.sh   (patch that file)
#   --no-patch                        (never patch, only report)
#   --report-file /path/to/file       (write report to that exact path)
HW_PROBE_PATH=""
NO_PATCH=0
REPORT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hw-probe) shift; HW_PROBE_PATH="$1" ;;
    --no-patch) NO_PATCH=1 ;;
    --report-file) shift; REPORT_FILE="$1" ;;
  esac
  shift
done

# Auto-detect hw_probe if not provided
if [ -z "$HW_PROBE_PATH" ] && [ -f "$DEFAULT_HW_PROBE" ]; then
  HW_PROBE_PATH="$DEFAULT_HW_PROBE"
fi

# -----------------------------
# Helpers (BusyBox ash)
# -----------------------------
say() { printf "%s\n" "$*"; }

prompt_line() { printf "%s" "$*"; read REPLY; }

ask_enter_or_q() {
  prompt_line "$1"
  case "$REPLY" in q|Q) return 1 ;; esac
  return 0
}

yesno() {
  # Returns: 0=yes, 1=no, 2=quit
  prompt="$1"
  def="${2:-Y}"
  while :; do
    if [ "$def" = "Y" ]; then
      printf "%s [Y/n] (or q): " "$prompt"
    else
      printf "%s [y/N] (or q): " "$prompt"
    fi
    read ans
    [ -z "$ans" ] && ans="$def"
    case "$ans" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      q|Q) return 2 ;;
    esac
  done
}

# Only real eth devices (no eth0.187)
list_eth_ifaces() {
  ls /sys/class/net 2>/dev/null | grep -E '^eth[0-9]+$' | sort
}

carrier() { cat "/sys/class/net/$1/carrier" 2>/dev/null; }

tx_packets() {
  cat "/sys/class/net/$1/statistics/tx_packets" 2>/dev/null || echo 0
}

now_stamp() { date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "unknown_time"; }

# -----------------------------
# Robust nvram detection
# -----------------------------
find_nvram() {
  if command -v nvram >/dev/null 2>&1; then
    command -v nvram
    return 0
  fi
  for p in /usr/sbin/nvram /sbin/nvram /bin/nvram /usr/bin/nvram; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

nvget() {
  [ -n "${NVRAM_CMD:-}" ] || return 1
  "$NVRAM_CMD" get "$1" 2>/dev/null
}

read_device_info() {
  PRODUCTID="unknown"
  FIRMWARE="unknown"
  NVRAM_CMD="$(find_nvram 2>/dev/null)" || NVRAM_CMD=""

  if [ -n "$NVRAM_CMD" ]; then
    p="$(nvget productid)"
    [ -n "$p" ] && PRODUCTID="$p"

    fv="$(nvget firmver)"
    bn="$(nvget buildno)"
    if [ -n "$fv" ]; then
      FIRMWARE="$fv"
      [ -n "$bn" ] && FIRMWARE="$FIRMWARE.$bn"
    fi
  fi
}

# -----------------------------
# WAN detection (route dev, else br0 delta)
# -----------------------------
detect_wan() {
  WAN_DETECTED=""
  WAN_METHOD=""

  dev="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [ -z "$dev" ]; then
    WAN_METHOD="could not determine"
    return 1
  fi

  if [ "$dev" != "br0" ]; then
    WAN_DETECTED="$dev"
    WAN_METHOD="ip route"
    return 0
  fi

  gw="$(ip route show default 2>/dev/null | awk 'NR==1{print $3; exit}')"
  members="$(ls /sys/class/net/br0/brif 2>/dev/null | grep -E '^eth[0-9]+$')"
  [ -n "$gw" ] && [ -n "$members" ] || {
    WAN_METHOD="bridge mode, no eth members or no gateway"
    return 1
  }

  ip neigh del "$gw" dev br0 >/dev/null 2>&1

  tmp="/tmp/uplink.$$"
  : > "$tmp"
  for i in $members; do
    printf "%s %s\n" "$i" "$(tx_packets "$i")" >> "$tmp"
  done

  ping -c2 -W1 "$gw" >/dev/null 2>&1

  best=""; bestd=0
  while read -r i tx1; do
    tx2="$(tx_packets "$i")"
    d=$((tx2 - tx1))
    [ "$d" -gt "$bestd" ] && bestd="$d" && best="$i"
  done < "$tmp"
  rm -f "$tmp"

  WAN_DETECTED="${best:-unknown}"
  WAN_METHOD="br0 delta"
  [ "$WAN_DETECTED" = "unknown" ] && return 1
  return 0
}

# -----------------------------
# Carrier snapshot + detect 0->1 since snapshot
# -----------------------------
snapshot_carrier() {
  candidates="$1"
  out="$2"
  : > "$out"
  for i in $candidates; do
    c="$(carrier "$i")"
    [ -z "$c" ] && c="0"
    printf "%s %s\n" "$i" "$c" >> "$out"
  done
}

detect_linkup_since_snapshot() {
  snap="$1"
  candidates="$2"

  n=0
  while [ $n -lt 25 ]; do
    while read -r i c0; do
      case " $candidates " in
        *" $i "*) : ;;
        *) continue ;;
      esac
      c1="$(carrier "$i")"
      [ -z "$c1" ] && c1="0"
      if [ "$c0" = "0" ] && [ "$c1" = "1" ]; then
        printf "%s" "$i"
        return 0
      fi
    done < "$snap"
    sleep 1
    n=$((n + 1))
  done
  return 1
}

# -----------------------------
# Patch hw_probe.sh under header/placeholder; update mapping if already present
# -----------------------------
patch_hw_probe() {
  hw="$1"
  productid="$2"
  payload="$3"   # multi-line

  [ -f "$hw" ] || { say "ERROR: hw_probe not found: $hw"; return 1; }
  [ -w "$hw" ] || { say "ERROR: hw_probe not writable: $hw"; return 1; }

  grep -qF "$HEADER_LINE" "$hw" || {
    say "ERROR: Missing header in hw_probe:"
    say "  $HEADER_LINE"
    say "  $PLACEHOLDER_LINE"
    return 1
  }
  grep -qF "$PLACEHOLDER_LINE" "$hw" || {
    say "ERROR: Missing placeholder in hw_probe:"
    say "  $HEADER_LINE"
    say "  $PLACEHOLDER_LINE"
    return 1
  }

  tmp="/tmp/hw_probe.patched.$$"

  in_custom=0
  inserted=0
  pending_mapper_comment=""

  while IFS= read -r line; do
    if [ "$line" = "$HEADER_LINE" ]; then
      in_custom=1
      pending_mapper_comment=""
      printf "%s\n" "$line" >> "$tmp"
      continue
    fi

    if [ "$in_custom" -eq 1 ] && [ "$line" = "$PLACEHOLDER_LINE" ]; then
      if [ -n "$pending_mapper_comment" ]; then
        printf "%s\n" "$pending_mapper_comment" >> "$tmp"
        pending_mapper_comment=""
      fi
      if [ "$inserted" -eq 0 ]; then
        printf "%s\n" "$payload" >> "$tmp"
        inserted=1
      fi
      printf "%s\n" "$line" >> "$tmp"
      in_custom=0
      continue
    fi

    if [ "$in_custom" -eq 1 ]; then
      case "$line" in
        "# [Custom Support Mapper]"*)
          pending_mapper_comment="$line"
          continue
          ;;
      esac

      case "$line" in
        "${productid})"*)
          pending_mapper_comment=""
          if [ "$inserted" -eq 0 ]; then
            printf "%s\n" "$payload" >> "$tmp"
            inserted=1
          fi
          continue
          ;;
      esac

      if [ -n "$pending_mapper_comment" ]; then
        printf "%s\n" "$pending_mapper_comment" >> "$tmp"
        pending_mapper_comment=""
      fi
    fi

    printf "%s\n" "$line" >> "$tmp"
  done < "$hw"

  if [ "$inserted" -ne 1 ]; then
    rm -f "$tmp"
    say "ERROR: Patch failed; could not insert/replace mapping."
    return 1
  fi

  mv "$tmp" "$hw" || {
    rm -f "$tmp"
    say "ERROR: Could not write patched hw_probe.sh"
    return 1
  }

  return 0
}

# -----------------------------
# Main
# -----------------------------
say ""
say "=== MerVLAN Device Support Mapper ==="
say "Report output directory:"
say "  $RESULTDIR"
say "NOTE: /tmp is cleared on reboot, so these files will be removed."
say ""
say "IMPORTANT: While this tool can add temporary local support by patching"
say "hw_probe.sh, this is NOT a substitute for official support. Please share"
say "the generated report with the MerVLAN developer team for inclusion in"
say "future releases."
say ""

# Device info (early)
read_device_info
say "Detected (best-effort):"
say "  productid: $PRODUCTID"
say "  firmware : $FIRMWARE"
say ""

# Step 1: WAN detection
say "Step 1/2: WAN detection"
say "Unplug ALL Ethernet cables except the WAN/uplink cable."
if ! ask_enter_or_q "Press Enter when ready (or 'q' to quit)... "; then
  say "Quit."
  exit 0
fi

detect_wan >/dev/null 2>&1 || :
WAN_IF="$WAN_DETECTED"

if [ -z "$WAN_IF" ] || [ "$WAN_IF" = "unknown" ]; then
  say "WAN/uplink: (could not determine) (method: $WAN_METHOD)"
else
  say "WAN/uplink: $WAN_IF (method: $WAN_METHOD)"
fi
say ""

# Candidates (exclude WAN)
ALL_ETH="$(list_eth_ifaces)"
[ -z "$ALL_ETH" ] && { say "ERROR: No eth interfaces found."; exit 1; }

CAND_ETH=""
for i in $ALL_ETH; do
  [ -n "$WAN_IF" ] && [ "$i" = "$WAN_IF" ] && continue
  CAND_ETH="$CAND_ETH $i"
done
CAND_ETH="$(printf '%s\n' "$CAND_ETH" | sed 's/^ *//; s/ *$//; s/  */ /g')"

[ -z "$CAND_ETH" ] && { say "ERROR: No LAN candidates detected."; exit 1; }

say "LAN candidate interfaces (excluding WAN):"
say "  $CAND_ETH"
say ""

# Default LAN count = number of candidates
DEFAULT_COUNT=0
for _ in $CAND_ETH; do DEFAULT_COUNT=$((DEFAULT_COUNT + 1)); done

say "How many *LAN ports* does your router have? (exclude WAN)"
say "Default detected LAN-candidate count: $DEFAULT_COUNT"
prompt_line "Enter LAN port count (1-$DEFAULT_COUNT) or press Enter for default (ONLY if it corresponds to the actual number of LAN ports you have) (or 'q' to quit): "
case "$REPLY" in q|Q) say "Quit."; exit 0 ;; esac

LAN_COUNT="$REPLY"
[ -z "$LAN_COUNT" ] && LAN_COUNT="$DEFAULT_COUNT"

case "$LAN_COUNT" in
  *[!0-9]*)
    say "Invalid number. Using default: $DEFAULT_COUNT"
    LAN_COUNT="$DEFAULT_COUNT"
    ;;
esac
[ "$LAN_COUNT" -lt 1 ] 2>/dev/null && LAN_COUNT=1
[ "$LAN_COUNT" -gt "$DEFAULT_COUNT" ] 2>/dev/null && LAN_COUNT="$DEFAULT_COUNT"

say ""
say "Step 2/2: LAN port mapping (LAN1..LAN${LAN_COUNT})"
say "IMPORTANT:"
say " - Unplug the LAN cable before each step."
say " - When prompted, plug into the requested LAN port, then press Enter."
say " - You can type 'q' at any prompt to stop early."
say ""

LAN_MAP_ORDER=""
LAN_MAP_LINES=""
LAN_IDX=1
CAND_WORK="$CAND_ETH"

while [ "$LAN_IDX" -le "$LAN_COUNT" ]; do
  say "Mapping LAN${LAN_IDX} ($LAN_IDX/$LAN_COUNT)"
  say "Unplug any LAN cable now (only WAN should be connected)."

  snap="/tmp/mervlan_carrier_snap.$$"
  snapshot_carrier "$CAND_WORK" "$snap"

  if ! ask_enter_or_q "Now plug cable into LAN${LAN_IDX} and press Enter (or 'q' to stop)... "; then
    rm -f "$snap"
    say "Stopping early."
    break
  fi

  hit="$(detect_linkup_since_snapshot "$snap" "$CAND_WORK")"
  rm -f "$snap"

  if [ -z "$hit" ]; then
    say "  Could not detect a new link-up on: $CAND_WORK"
    yesno "Retry LAN${LAN_IDX}?" Y
    rc=$?
    [ $rc -eq 2 ] && { say "Stopping early."; break; }
    [ $rc -eq 0 ] && continue
    break
  fi

  say "  Detected: LAN${LAN_IDX} -> $hit"

  yesno "Accept this mapping?" Y
  rc=$?
  if [ $rc -eq 2 ]; then
    say "Stopping early."
    break
  elif [ $rc -ne 0 ]; then
    say "  Discarded."
    continue
  fi

  LAN_MAP_ORDER="$LAN_MAP_ORDER $hit"
  LAN_MAP_LINES="$LAN_MAP_LINES
  LAN${LAN_IDX} -> $hit"

  # Remove mapped iface from candidates
  newcand=""
  for i in $CAND_WORK; do
    [ "$i" = "$hit" ] && continue
    newcand="$newcand $i"
  done
  CAND_WORK="$(printf '%s\n' "$newcand" | sed 's/^ *//; s/ *$//; s/  */ /g')"

  LAN_IDX=$((LAN_IDX + 1))
  [ -z "$CAND_WORK" ] && break

  say "Unplug the cable from the previous LAN port before continuing."
  say ""
done

LAN_MAP_ORDER="$(printf '%s\n' "$LAN_MAP_ORDER" | sed 's/^ *//; s/ *$//; s/  */ /g')"

MAX_ETH_PORTS=0
for _ in $LAN_MAP_ORDER; do MAX_ETH_PORTS=$((MAX_ETH_PORTS + 1)); done
[ "$MAX_ETH_PORTS" -eq 0 ] && { say "ERROR: No LAN ports mapped."; exit 1; }

LAN_PORT_LABELS=""
i=1
while [ $i -le "$MAX_ETH_PORTS" ]; do
  LAN_PORT_LABELS="$LAN_PORT_LABELS LAN$i"
  i=$((i + 1))
done
LAN_PORT_LABELS="$(printf '%s\n' "$LAN_PORT_LABELS" | sed 's/^ *//; s/ *$//; s/  */ /g')"

# Re-read device info right before report (crucial for debugging)
read_device_info

MODEL="$PRODUCTID"
SUGGESTED_CASE="${PRODUCTID}) MODEL=\"${MODEL}\"; ETH_PORTS=\"${LAN_MAP_ORDER}\"; LAN_PORT_LABELS=\"${LAN_PORT_LABELS}\"; MAX_ETH_PORTS=${MAX_ETH_PORTS}; WAN_IF=\"${WAN_IF:-eth0}\" ;;"
ENCODED_SUGGESTED_CASE="$(printf '%s' "$SUGGESTED_CASE" \
  | sed 's/%/%25/g; s/ /%20/g; s/"/%22/g; s/;/%3B/g; s/)/%29/g')"

STAMP="$(now_stamp)"
[ -z "$REPORT_FILE" ] && REPORT_FILE="$RESULTDIR/device_support_${PRODUCTID}_${STAMP}.txt"

{
  say "=== MerVLAN Device Support Mapper Report ==="
  say "productid: $PRODUCTID"
  say "firmware: $FIRMWARE"
  if [ -n "$WAN_IF" ] && [ "$WAN_IF" != "unknown" ]; then
    say "detected_wan: $WAN_IF (method: $WAN_METHOD)"
  else
    say "detected_wan: (could not determine) (method: $WAN_METHOD)"
  fi
  say "lan_map:$LAN_MAP_LINES"
  say ""
  say "Suggested hw_probe.sh case:"
  say "$SUGGESTED_CASE"
} > "$REPORT_FILE"

say ""
say "=============================="
cat "$REPORT_FILE"
say "=============================="
say ""
say "Report saved to:"
say "  $REPORT_FILE"
say ""
say "View it again with:"
say "  cat \"$REPORT_FILE\""
say ""
say "NOTE: This is under /tmp and will be removed on the next reboot."
say ""
say "Next steps:"
say " - Open a ticket on the MerVLAN GitHub and paste the report by following the instructions below."
say ""
say "   Paste this URL in your browser:"
say "   https://github.com/r80xcore/mervlan/issues/new?title=[Device%20Support%20Request]%20$PRODUCTID&body=$ENCODED_SUGGESTED_CASE"
say ""
say "   If needed, add additional information in the ticket description."
say "   Then click on "Create" to submit the ticket."

# Patch (optional)
if [ "$NO_PATCH" -eq 1 ]; then
  say "Patching disabled (--no-patch). Done."
  exit 0
fi

if [ -z "$HW_PROBE_PATH" ]; then
  say "MerVLAN hw_probe.sh not found (no MerVLAN install detected)."
  say "You can still share the report above for adding official support."
  exit 0
fi

say "hw_probe candidate:"
say "  $HW_PROBE_PATH"
say ""

yesno "Apply temporary local support by patching hw_probe.sh (recommended)?" Y
rc=$?
[ $rc -eq 2 ] && { say "Quit."; exit 0; }
if [ $rc -ne 0 ]; then
  say "No patch applied. Done."
  exit 0
fi

STAMP_HUMAN="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown-time")"
PAYLOAD="# [Custom Support Mapper] added/updated ${STAMP_HUMAN}
$SUGGESTED_CASE"

patch_hw_probe "$HW_PROBE_PATH" "$PRODUCTID" "$PAYLOAD" || exit 1

say ""
say "Patched hw_probe.sh successfully (custom mapping stored under the Custom Support Mapper header)."

if [ "$HW_PROBE_PATH" = "$DEFAULT_HW_PROBE" ]; then
  say "Running hw_probe.sh once to apply the mapping into MerVLAN hardware settings..."
  sh "$HW_PROBE_PATH" || say "WARNING: hw_probe.sh returned non-zero."
fi

say ""
say "Done."
