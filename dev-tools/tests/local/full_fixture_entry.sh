#!/bin/sh
# Host-only adapter for the private Full helper APIs. Never ships on routers.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset LIB_SELFTEST_CONTEXT_LOADED
. "$MERV_BASE/settings/lib_selftest_context.sh" || exit 2
merv_selftest_context_valid && merv_selftest_context_path_allowed "$MERV_BASE" || exit 2
exec env -i PATH="$PATH" LC_ALL=C MERV_BASE="$MERV_BASE" MERVLAN_SELFTEST_CONTEXT="$MERVLAN_SELFTEST_CONTEXT" /bin/sh -c '
. "$MERV_BASE/settings/lib_full_uninstall.sh" || exit 2
case "$1" in
 --prepare) FULL_POLICY=${2:-KEEP}; full_prepare ;;
 --nodes) [ "$#" = 3 ] || exit 2; full_nodes_entry "$2" "$3" ;;
 *) exit 2 ;;
esac
' fixture "$@"
