#!/bin/sh
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
#         - File: templates/mervlan_templates.sh || version="0.50"             #
# ──────────────────────────────────────────────────────────────────────────── #
# - Purpose:    Provide unified template lookup utilities for MerVLAN.         #
#               Each template is stored inline and can be materialized via     #
#               tpl_path for injection/removal helpers.                        #
# ──────────────────────────────────────────────────────────────────────────── #

[ -n "${MERV_TEMPLATE_LIB_LOADED:-}" ] && return 0 2>/dev/null

read_only_templates=$(cat <<'EOF'
%%TEMPLATE service-event 1
# MerVLAN auto-redirect events to service-event-handler.sh
MERV_BASE_PLACEHOLDER/functions/service-event-handler.sh "$@"
%%END

%%TEMPLATE service-event 2
# MerVLAN auto-redirect events to service-event-handler.sh
MERV_BASE_PLACEHOLDER/functions/service-event-handler.sh "$@"
%%END

%%TEMPLATE services-start 1
# MerVLAN auto-enable VLAN on boot
sleep 10
MERV_BASE_PLACEHOLDER/functions/mervlan_manager.sh
sleep 10
MERV_BASE_PLACEHOLDER/functions/mervlan_boot.sh cronenable
%%END

%%TEMPLATE services-start 2
# MerVLAN auto-enable VLAN on boot
sleep 10
MERV_BASE_PLACEHOLDER/functions/mervlan_manager.sh
sleep 10
MERV_BASE_PLACEHOLDER/functions/mervlan_boot.sh cronenable
%%END

%%TEMPLATE services-start-addon 1
# MerVLAN mount addon on boot
sleep 5
MERV_BASE_PLACEHOLDER/install.sh
%%END

%%TEMPLATE services-start-addon 2
# MerVLAN mount addon on boot
sleep 5
MERV_BASE_PLACEHOLDER/install.sh
%%END

EOF
)

_tpl_registry_dir="${TMPDIR:-/tmp}/mervlan_tpls"
[ -d "$_tpl_registry_dir" ] || mkdir -p "$_tpl_registry_dir" 2>/dev/null || :

# tpl_path — materialize template <name> variant <variant> into stable temp file
# Args: $1=name, $2=variant (optional), $3=dest file for variant sniffing (optional)
# Echoes path to rendered template or 'ERR' on failure.
tpl_path() {
  local name="$1" variant="$2" sniff_dest="$3" tmp tmp_raw target inj status
  [ -n "$name" ] || { echo "ERR"; return 1; }

  if [ -z "$variant" ]; then
    if [ -n "$sniff_dest" ] && [ -s "$sniff_dest" ] && head -n 1 "$sniff_dest" 2>/dev/null | grep -q '^#!'; then
      variant="2"
    else
      variant="1"
    fi
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/merv_tpl.${name}.${variant}.XXXXXX" 2>/dev/null || printf '%s/merv_tpl.%s.%s.%s' "${TMPDIR:-/tmp}" "$name" "$variant" "$$")"
  tmp_raw="${tmp}.raw"

  printf '%s
' "$read_only_templates" | awk -v n="$name" -v v="$variant" '
    BEGIN { capture = 0; found = 0 }
    /^%%TEMPLATE[[:space:]]+/ {
      split($0, parts, /[[:space:]]+/)
      tmpl = parts[2]
      ver = parts[3]
      capture = (tmpl == n && ver == v)
      if (capture) {
        found = 1
      }
      next
    }
    /^%%END$/ {
      capture = 0
      next
    }
    capture { print }
    END {
      if (!found) exit 2
    }
  ' > "$tmp_raw" 2>/dev/null
  status=$?
  if [ $status -ne 0 ]; then
    rm -f "$tmp" "$tmp_raw" 2>/dev/null || :
    echo "ERR"
    return 1
  fi

  inj="${MERV_BASE%/}"
  if ! sed "s|MERV_BASE_PLACEHOLDER|$inj|g" "$tmp_raw" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" "$tmp_raw" 2>/dev/null || :
    echo "ERR"
    return 1
  fi

  rm -f "$tmp_raw" 2>/dev/null || :

  target="${_tpl_registry_dir%/}/${name}.v${variant}.tpl"
  mv -f "$tmp" "$target" 2>/dev/null || {
    rm -f "$tmp" "$target" "$tmp_raw" 2>/dev/null || :
    echo "ERR"
    return 1
  }

  echo "$target"
  return 0
}

MERV_TEMPLATE_LIB_LOADED=1
