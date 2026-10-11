#!/bin/sh
# Full Uninstall implementation, version 2.1.
# Full helper protocol: full-uninstall-v1
# ---- 01 Protocol and loading contract ----
# Only functions are defined on load. Run data is never shell-sourced.
# Public orchestration belongs to uninstall.sh. Terminal programs below are
# literal templates emitted from the frozen copy of this library.

# ---- 02 Path and object validation ----
full_safe_path() {
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in *..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    fsp_current=/; fsp_rest=${1#/}
    while [ -n "$fsp_rest" ]; do
        case "$fsp_rest" in */*) fsp_part=${fsp_rest%%/*}; fsp_rest=${fsp_rest#*/} ;;
            *) fsp_part=$fsp_rest; fsp_rest= ;; esac
        fsp_current=$fsp_current$fsp_part
        [ ! -L "$fsp_current" ] || return 1
        fsp_current=$fsp_current/
    done
}
full_private() {
    full_safe_path "$1" || return 1
    [ "$(ls -ldn "$1" 2>/dev/null | awk '{print $1 " " $3}')" = "$2 $FULL_UID" ]
}
# ---- 03 Generation digests and immutable manifests ----
full_digest() {
    fd_value=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    if [ "${#fd_value}" != 64 ]; then
        fd_value=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}')
    fi
    [ "${#fd_value}" = 64 ] || return 1
    case "$fd_value" in *[!0-9a-f]*) return 1 ;; esac
    printf '%s\n' "$fd_value"
}
# Shared trust validation uses this Full-private, side-effect-free derivation
# instead of writing fingerprint temporaries into the durable trust tree.
# Canonical base64 round-trip prevents permissive decoding of malformed keys.
# ---- 04 Trust identity and fingerprint validation ----
merv_ssh_trust_derive_fingerprint() {
    merv_ssh_trust_algorithm_valid "$1" && merv_ssh_trust_key_valid "$2" || return 1
    ffp_canon=$(printf '%s' "$2" | openssl base64 -d -A 2>/dev/null | openssl base64 -A 2>/dev/null) || return 1
    [ "$ffp_canon" = "$2" ] || return 1
    ffp_value=$(printf '%s' "$2" | openssl base64 -d -A 2>/dev/null |
        openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null | tr -d '=') || return 1
    merv_ssh_trust_fingerprint_valid "SHA256:$ffp_value" || return 1
    printf 'SHA256:%s\n' "$ffp_value"
}
full_fail() {
    printf 'PHASE7_NOT_READY reason=%s\n' "$1" >&2
    return 1
}
full_freeze() {
    # Only called inside a freshly, atomically created private workspace.
    ff_src=$1; ff_dest=$2
    full_safe_path "$ff_src" && [ -f "$ff_src" ] && [ -s "$ff_src" ] || return 1
    [ ! -e "$ff_dest" ] && [ ! -L "$ff_dest" ] || return 1
    ff_before=$(full_digest "$ff_src") || return 1
    (set -C; cat "$ff_src" > "$ff_dest") || return 1
    full_private "$ff_dest" -rw------- || return 1
    [ "$(full_digest "$ff_dest")" = "$ff_before" ] &&
    [ "$(full_digest "$ff_src")" = "$ff_before" ] || return 1
}
full_stamp() {
    # Private immutable manifest; exact file list comes from the parent.
    for fst_name in "$@"; do
        full_private "$FULL_ROOT/$fst_name" -rw------- || return 1
        fst_hash=$(full_digest "$FULL_ROOT/$fst_name") || return 1
        printf '%s %s\n' "$fst_hash" "$fst_name"
    done
}
full_check_stamp() {
    full_private "$1" -rw------- || return 1
    while IFS=' ' read -r fcs_hash fcs_name fcs_extra; do
        [ -z "$fcs_extra" ] || return 1
        case "$fcs_name" in settings.snapshot.json|topology.map|ssh.freeze|endpoint.map|trust.identity.map|artifacts.manifest|terminal.manifest|authority.manifest|main/terminal.sh|main/cleaner.sh|main/stage.sh|main/node.sh|main/lib_*.sh|nodes.sh|probe.sh|identity.sh|trust.sh|selftest.sh|fingerprint.sh|ssh.sh|topology.awk|bootstrap.sh|NODE[1-9]/.ssh/known_hosts|NODE10/.ssh/known_hosts) ;; *) return 1 ;; esac
        full_private "$FULL_ROOT/$fcs_name" -rw------- || return 1
        [ "$(full_digest "$FULL_ROOT/$fcs_name")" = "$fcs_hash" ] || return 1
    done < "$1"
}
full_authority_check() {
    full_private "$FULL_ROOT" drwx------ || return 1
    [ "$(full_digest "$FULL_ROOT/authority.manifest")" = "$FULL_AUTHORITY_HASH" ] &&
    [ "$(full_digest "$FULL_ROOT/config.manifest")" = "$FULL_CONFIG_HASH" ] || return 1
    full_check_stamp "$FULL_ROOT/authority.manifest" || return 1
    full_private "$FULL_CLIENT" -rwx------ || return 1
    [ "$(full_digest "$FULL_CLIENT")" = "$FULL_CLIENT_HASH" ] || return 1
    full_private "$FULL_KEY" -rw------- && [ -s "$FULL_KEY" ] || return 1
    [ "$(full_digest "$FULL_KEY")" = "$FULL_KEY_HASH" ] || return 1
    full_check_stamp "$FULL_ROOT/config.manifest" && full_main_verify || return 1
}
full_trust_equal() {
    # Re-read durable authority immediately before every authenticated step.
    # Require canonical configured endpoint even when WAN Native was promoted.
    full_private "$MERV_SSH_TRUST_FILE" -rw------- || return 1
    [ "$(full_digest "$MERV_SSH_TRUST_FILE")" = "$FULL_TRUST_HASH" ] || return 1
    merv_ssh_trust_find "$FULL_NODE_ID" || return 1
    [ "$(full_digest "$MERV_SSH_TRUST_FILE")" = "$FULL_TRUST_HASH" ] || return 1
    [ "$SSH_TRUST_SLOT" = "${FULL_SLOT#NODE}" ] &&
    [ "$SSH_TRUST_MAC" = "$FULL_MAC" ] &&
    [ "$SSH_TRUST_HOST" = "$FULL_CANONICAL" ] &&
    [ "$SSH_TRUST_PORT" = "$FULL_PORT" ] &&
    [ "$SSH_TRUST_ALGORITHM" = "$FULL_ALG" ] &&
    [ "$SSH_TRUST_FINGERPRINT" = "$FULL_FP" ] &&
    [ "$SSH_TRUST_PUBLIC_KEY" = "$FULL_PUBLIC_KEY" ]
}
# ---- 05 Frozen SSH transport and preflight ----
full_bounded() {
    # Reuse the established shared deadline implementation, frozen as code.
    # This function definition is extracted nowhere; lib_ssh is loaded into a
    # separate clean shell only for its maintained timeout/client runner.
    env -i PATH="$PATH" LC_ALL=C MERV_BASE="$MERV_BASE" \
        MERVLAN_SELFTEST_CONTEXT="${MERVLAN_SELFTEST_CONTEXT:-}" \
        MERV_SSH_HOME="$FULL_ROOT/transport" MERV_SSH_TMPDIR="$FULL_ROOT/transport" \
        /bin/sh -c '
            LIB_JSON_LOADED=1; LIB_SSH_TRUST_LOADED=1
            . "$1" || exit 2
            MERV_SSH_TIMEOUT=$4
            MERV_SSH_CLIENT=$2
            MERV_SSH_HOME=$3; HOME=$3; export HOME
            shift 4
            merv_ssh_client_run "$@"
        ' full-client "$FULL_ROOT/ssh.sh" "$FULL_CLIENT" "$FULL_ROOT/$FULL_SLOT" "${FULL_OPERATION_TIMEOUT:-20}" \
        -p "$FULL_PORT" -i "$FULL_KEY" -o ConnectTimeout=10 \
        "$FULL_USER@$FULL_ENDPOINT" "$1"
}
full_transport_check() {
    # Closed operation set. No endpoint, user, port or arbitrary shell from caller.
    full_authority_check && full_trust_equal || return 1
    full_private "$FULL_ROOT/$FULL_SLOT" drwx------ &&
    full_private "$FULL_ROOT/$FULL_SLOT/.ssh" drwx------ &&
    full_private "$FULL_ROOT/$FULL_SLOT/.ssh/known_hosts" -rw------- || return 1
    fssh_token=$FULL_ENDPOINT
    [ "$FULL_PORT" = 22 ] || fssh_token="[$FULL_ENDPOINT]:$FULL_PORT"
    [ "$(cat "$FULL_ROOT/$FULL_SLOT/.ssh/known_hosts")" = "$fssh_token $FULL_ALG $FULL_PUBLIC_KEY" ] || return 1
    if [ "$FULL_MAPS_FROZEN" = 1 ]; then
        [ "$(full_digest "$FULL_ROOT/maps.manifest")" = "$FULL_MAPS_HASH" ] || return 1
        full_check_stamp "$FULL_ROOT/maps.manifest" || return 1
    fi
}
full_ssh() {
    full_transport_check || return 1
    case "$1" in
        proof) fssh_command="printf 'PHASE7_AUTH_OK\\n'" ;;
        init|verify|receive|context)
            case "${2:-}" in ''|artifacts.manifest|context|cleaner.sh|stage.sh|node.sh|lib_selftest_context.sh|lib_identity.sh|lib_owner_lock.sh|lib_action_lock.sh|lib_full_fence.sh|lib_update_state.sh|lib_continuation.sh|lib_radio.sh|lib_mervqt.sh|lib_settings_reconcile.sh|lib_maintenance_quiesce.sh) ;; *) return 1 ;; esac
            fssh_code=$(cat "$FULL_ROOT/main/stage.sh") || return 1
            fssh_quoted=$(printf '%s' "$fssh_code" | sed "s/'/'\\\\''/g") || return 1
            fssh_command="/bin/sh -c '$fssh_quoted' full-stage '$1' '$FULL_RUN' '$FULL_ARTIFACTS_HASH' '$FULL_STAGE_HASH' '${2:-}'"
            ;;
        *) return 1 ;;
    esac
    full_bounded "$fssh_command" > "$FULL_ROOT/ssh.stdout" 2> "$FULL_ROOT/ssh.stderr" || return 1
    case "$1" in
        proof) fssh_expected=PHASE7_AUTH_OK ;;
        *) fssh_expected="PHASE7_STAGE_OK $1 $FULL_RUN" ;;
    esac
    [ "$(cat "$FULL_ROOT/ssh.stdout")" = "$fssh_expected" ]
}
full_probe() {
    full_authority_check || return 1
    # Invoke the frozen canonical probe implementation without var_settings or
    # JSON loading: its username/key/client are supplied only from this run.
    # No live settings read, trust enrollment or permanent key generation.
    env -i PATH="$PATH" LC_ALL=C MERV_BASE="$MERV_BASE" \
        MERVLAN_SELFTEST_CONTEXT="${MERVLAN_SELFTEST_CONTEXT:-}" \
        /bin/sh -c '
            . "$1/selftest.sh" || exit 2
            . "$1/identity.sh" || exit 2
            . "$1/trust.sh" || exit 2
            . "$1/fingerprint.sh" || exit 2
            VAR_SETTINGS_LOADED=1; LIB_JSON_LOADED=1
            SSH_KEY=$2; MERV_SSH_CLIENT=$3; FULL_PROBE_USER=$4
            MERV_SSH_CONNECT_TIMEOUT=10; DROPBEARKEY=/usr/bin/dropbearkey
            TMPDIR=/tmp/mervlan_tmp
            json_get_flag() { printf "%s\n" "$FULL_PROBE_USER"; }
            merv_cmd() { [ -x "$1" ] && printf "%s\n" "$1"; }
            shift 4
            full_probe_source=$1; shift
            . "$full_probe_source"
        ' full-probe "$FULL_ROOT" "$FULL_KEY" "$FULL_CLIENT" "$FULL_USER" \
        "$FULL_ROOT/probe.sh" "$FULL_NODE_ID" "$FULL_ENDPOINT" "$FULL_PORT" "$FULL_ROOT/probe-tmp" \
        > "$FULL_ROOT/probe.result" 2> "$FULL_ROOT/probe.stderr"
    fp_probe_rc=$?
    # A canonical probe may retain recovery evidence if its child identity or
    # cleanup is unresolved. Never promote/retry that ambiguous outcome merely
    # because a key tuple was emitted. Do not delete or signal retained state.
    full_private "$FULL_ROOT/probe-tmp" drwx------ || return 4
    env -i PATH="$PATH" /bin/sh -c '
        for child in "$1"/* "$1"/.[!.]* "$1"/..?*; do
            if [ -e "$child" ] || [ -L "$child" ]; then exit 4; fi
        done
    ' full-probe-empty "$FULL_ROOT/probe-tmp" || return 4
    return "$fp_probe_rc"
}
full_read_probe() {
    full_private "$FULL_ROOT/probe.result" -rw------- || return 1
    frp_line=$(cat "$FULL_ROOT/probe.result") || return 1
    printf '%s\n' "$frp_line" | awk -F '\t' 'NR==1 && NF==3 {ok=1} END {exit !(ok && NR==1)}' || return 1
    FULL_ALG=$(printf '%s\n' "$frp_line" | cut -f1)
    FULL_PUBLIC_KEY=$(printf '%s\n' "$frp_line" | cut -f2)
    FULL_FP=$(printf '%s\n' "$frp_line" | cut -f3)
    merv_ssh_trust_algorithm_valid "$FULL_ALG" && merv_ssh_trust_key_valid "$FULL_PUBLIC_KEY" || return 1
    [ "$(merv_ssh_trust_derive_fingerprint "$FULL_ALG" "$FULL_PUBLIC_KEY")" = "$FULL_FP" ]
}
# ---- 06 Snapshot endpoint maps ----
full_node() {
    [ "$#" = 7 ] || return 1
    FULL_SLOT=$1; FULL_CANONICAL=$2; FULL_MAC=$3
    FULL_NATIVE=$6; FULL_WAN_IP=$7
    case "$FULL_SLOT" in NODE[1-9]|NODE10) ;; *) return 1 ;; esac
    FULL_NODE_ID=$(merv_ssh_trust_node_id "${FULL_SLOT#NODE}" "$FULL_MAC" "$FULL_CANONICAL" "$FULL_PORT") || return 1
}
full_pin() {
    fp_token=$FULL_ENDPOINT
    [ "$FULL_PORT" = 22 ] || fp_token="[$FULL_ENDPOINT]:$FULL_PORT"
    mkdir "$FULL_ROOT/$FULL_SLOT" "$FULL_ROOT/$FULL_SLOT/.ssh" || return 1
    printf '%s %s %s\n' "$fp_token" "$FULL_ALG" "$FULL_PUBLIC_KEY" > "$FULL_ROOT/$FULL_SLOT/.ssh/known_hosts" || return 1
    fp_endpoint_row="$FULL_SLOT $FULL_CANONICAL $FULL_ENDPOINT"
    fp_identity_row="$FULL_SLOT $FULL_ENDPOINT $FULL_PORT $FULL_NODE_ID $FULL_MAC $FULL_ALG $FULL_FP $FULL_PUBLIC_KEY"
    FULL_ENDPOINT_EXPECTED=$(printf '%s%s%s' "$FULL_ENDPOINT_EXPECTED" "${FULL_ENDPOINT_EXPECTED:+
}" "$fp_endpoint_row") || return 1
    FULL_IDENTITY_EXPECTED=$(printf '%s%s%s' "$FULL_IDENTITY_EXPECTED" "${FULL_IDENTITY_EXPECTED:+
}" "$fp_identity_row") || return 1
    printf '%s\n' "$fp_endpoint_row" >> "$FULL_ROOT/endpoint.map" || return 1
    printf '%s\n' "$fp_identity_row" >> "$FULL_ROOT/trust.identity.map"
}
full_load_pin() {
    # Maps are hash-bound before use, not shell-sourced. Validate exact row
    # shape, binding and single-match even if a future caller misuses them.
    flp_line=$(awk -v s="$FULL_SLOT" '$1==s {n++; if(NF!=8)exit 1; row=$0} END {if(n!=1)exit 1; print row}' "$FULL_ROOT/trust.identity.map") || return 1
    IFS=' ' read -r flp_slot FULL_ENDPOINT flp_port flp_id flp_mac FULL_ALG FULL_FP FULL_PUBLIC_KEY <<EOF
$flp_line
EOF
    [ "$flp_slot" = "$FULL_SLOT" ] && [ "$flp_port" = "$FULL_PORT" ] && [ "$flp_id" = "$FULL_NODE_ID" ] && [ "$flp_mac" = "$FULL_MAC" ] || return 1
    [ "$(awk -v s="$FULL_SLOT" '$1==s {n++; if(NF!=3)exit 1; row=$0} END {if(n!=1)exit 1; print row}' "$FULL_ROOT/endpoint.map")" = "$FULL_SLOT $FULL_CANONICAL $FULL_ENDPOINT" ]
}
# MAIN-only code: never SSH-staged. The existing exact NODE cohort supplies
# identity, M/F and Q for both wrappers; terminal.manifest binds the extension.
full_terminal_verify() {
    full_private "$FULL_ROOT/terminal.manifest" -rw------- || return 1
    ftv_expected=$(full_stamp main/terminal.sh) || return 1
    [ "$(cat "$FULL_ROOT/terminal.manifest")" = "$ftv_expected" ] &&
    [ "$(wc -c < "$FULL_ROOT/terminal.manifest")" = "$(printf '%s\n' "$ftv_expected" | wc -c)" ] &&
    /bin/sh -n "$FULL_ROOT/main/terminal.sh" &&
    grep -Fx '# Full MAIN protocol: phase9-main-v1' "$FULL_ROOT/main/terminal.sh" >/dev/null
}
# ---- 07 Frozen runtime verification ----
full_main_verify() {
    full_private "$FULL_ROOT/main" drwx------ || return 1
    [ -z "${FULL_ARTIFACTS_HASH:-}" ] || [ "$(full_digest "$FULL_ROOT/artifacts.manifest")" = "$FULL_ARTIFACTS_HASH" ] || return 1
    full_check_stamp "$FULL_ROOT/artifacts.manifest" && full_terminal_verify || return 1
    awk '
        BEGIN {n=split("cleaner.sh stage.sh node.sh lib_selftest_context.sh lib_identity.sh lib_owner_lock.sh lib_action_lock.sh lib_full_fence.sh lib_update_state.sh lib_continuation.sh lib_radio.sh lib_mervqt.sh lib_settings_reconcile.sh lib_maintenance_quiesce.sh",a," ");for(i=1;i<=n;i++)ok["main/" a[i]]=1}
        NF!=2 || !ok[$2] || seen[$2]++ {bad=1}
        END {exit (bad || NR!=n)}' "$FULL_ROOT/artifacts.manifest" || return 1
    while IFS=" " read -r fmv_hash fmv_path; do /bin/sh -n "$FULL_ROOT/$fmv_path" || return 1; done < "$FULL_ROOT/artifacts.manifest"
    grep -Fx '# Cleaner protocol: phase6-v1' "$FULL_ROOT/main/cleaner.sh" >/dev/null &&
    grep -Fx '# Full inert stage protocol: phase7-stage-v2' "$FULL_ROOT/main/stage.sh" >/dev/null &&
    grep -Fx '# Full NODE protocol: phase8-node-v1' "$FULL_ROOT/main/node.sh" >/dev/null
}
# ---- 08 Private workspace, topology, staging and two preflights ----
full_prepare() {
    set -f
    umask 077
    case "${FULL_POLICY:-KEEP}" in KEEP|DELETE) FULL_POLICY=${FULL_POLICY:-KEEP} ;; *) return 2 ;; esac
    . "$MERV_BASE/settings/lib_selftest_context.sh" &&
    . "$MERV_BASE/settings/lib_identity.sh" &&
    . "$MERV_BASE/settings/lib_ssh_trust.sh" || return 1
    # Restore the audited side-effect-free fingerprint adapter after trust load.
    . "$MERV_BASE/settings/lib_full_uninstall.sh" || return 1
    FULL_UID=$(id -u) || return 1
    full_safe_path "$MERV_BASE" || return 1
    merv_identity_nonce_next || return 1
    FULL_RUN=$MERV_IDENTITY_NONCE
    printf '%s\n' "$FULL_RUN" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    [ "${#FULL_RUN}" -le 100 ] || return 1
    FULL_ROOT="/tmp/.mervlan-full.$FULL_RUN"
    if merv_selftest_context_valid; then
        FULL_ROOT="$MERV_SELFTEST_CONTEXT_ROOT/.mervlan-full.$FULL_RUN"
    fi
    [ ! -e "$FULL_ROOT" ] && [ ! -L "$FULL_ROOT" ] || return 1
    mkdir "$FULL_ROOT" || return 1
    full_private "$FULL_ROOT" drwx------ || return 1
    # Failures leave inert exact run data; no automatic remote/local deletion or
    # resume. Never remove an ambiguous replacement or foreign workspace.
    printf 'PHASE7_RUN %s\n' "$FULL_ROOT"
    trap 'exit 130' INT
    trap 'exit 143' TERM
    FULL_MAPS_FROZEN=0
    FULL_ENDPOINT_EXPECTED=; FULL_IDENTITY_EXPECTED=
    [ ! -e "$FULL_ROOT/settings.snapshot.json" ] && [ ! -L "$FULL_ROOT/settings.snapshot.json" ] &&
    full_safe_path "$MERV_BASE/settings/settings.json" && [ -f "$MERV_BASE/settings/settings.json" ] &&
    (set -C; cat "$MERV_BASE/settings/settings.json" > "$FULL_ROOT/settings.snapshot.json") || { full_fail snapshot; return 1; }
    full_private "$FULL_ROOT/settings.snapshot.json" -rw------- || return 1
    full_freeze "$MERV_BASE/settings/lib_full_uninstall.sh" "$FULL_ROOT/bootstrap.sh" || return 1
    [ -z "${FULL_HELPER_HASH:-}" ] || [ "$(full_digest "$FULL_ROOT/bootstrap.sh")" = "$FULL_HELPER_HASH" ] || return 1
    full_emit_frozen topology "$FULL_ROOT/topology.awk" || return 1
    awk -f "$FULL_ROOT/topology.awk" "$FULL_ROOT/settings.snapshot.json" > "$FULL_ROOT/topology.map" || { full_fail topology; return 1; }
    IFS=' ' read -r fp_tag FULL_USER FULL_PORT < "$FULL_ROOT/topology.map"
    [ "$fp_tag" = SSH ] || return 1
    FULL_COUNT=$(awk '$1=="COUNT" {print $2}' "$FULL_ROOT/topology.map")
    FULL_KEY="$MERV_BASE/.ssh/vlan_manager"
    FULL_CLIENT_SOURCE=
    if merv_selftest_context_valid; then
        FULL_CLIENT_SOURCE="$MERV_BASE/bin/dbclient"
    else
        for fp_client in /usr/bin/dbclient /bin/dbclient /usr/sbin/dbclient /sbin/dbclient; do
            if [ -x "$fp_client" ]; then FULL_CLIENT_SOURCE=$fp_client; break; fi
        done
    fi
    # Fixed production search, never inherited PATH/client authority. Probe
    # readlink's resolution capability and freeze real executable bytes under
    # the dbclient basename (including Dropbear multi-call installations).
    FULL_CLIENT=none; FULL_CLIENT_HASH=none
    if [ -n "$FULL_CLIENT_SOURCE" ]; then
        fp_real_client=$(readlink -f "$FULL_CLIENT_SOURCE" 2>/dev/null) || { full_fail client-path; return 1; }
        full_safe_path "$fp_real_client" && [ -x "$fp_real_client" ] || return 1
        mkdir "$FULL_ROOT/bin" || return 1
        FULL_CLIENT="$FULL_ROOT/bin/dbclient"
        full_freeze "$fp_real_client" "$FULL_CLIENT" && chmod 700 "$FULL_CLIENT" || return 1
        FULL_CLIENT_HASH=$(full_digest "$FULL_CLIENT") || return 1
    elif [ "$FULL_COUNT" != 0 ]; then
        full_fail client; return 1
    fi
    FULL_KEY_HASH=none
    FULL_TRUST_HASH=none
    if [ "$FULL_COUNT" != 0 ]; then
        full_private "$FULL_KEY" -rw------- && [ -s "$FULL_KEY" ] || { full_fail permanent-key; return 1; }
        FULL_KEY_HASH=$(full_digest "$FULL_KEY") || return 1
        full_private "$MERV_SSH_TRUST_FILE" -rw------- || { full_fail durable-trust; return 1; }
        FULL_TRUST_HASH=$(full_digest "$MERV_SSH_TRUST_FILE") || return 1
    fi
    printf 'phase7-v1 %s %s %s %s %s %s %s\n' "$FULL_USER" "$FULL_PORT" "$FULL_CLIENT" "$FULL_CLIENT_HASH" "$FULL_KEY" "$FULL_KEY_HASH" "$FULL_TRUST_HASH" > "$FULL_ROOT/ssh.freeze" || return 1
    mkdir "$FULL_ROOT/main" "$FULL_ROOT/transport" "$FULL_ROOT/probe-tmp" || return 1
    full_freeze "$MERV_BASE/functions/mervlan_full_cleanup.sh" "$FULL_ROOT/main/cleaner.sh" &&
    full_emit_frozen stage "$FULL_ROOT/main/stage.sh" || { full_fail source; return 1; }
    full_emit_frozen node "$FULL_ROOT/main/node.sh" || return 1
    for fp_lib in selftest_context identity owner_lock action_lock full_fence update_state continuation radio mervqt settings_reconcile maintenance_quiesce; do
        full_freeze "$MERV_BASE/settings/lib_$fp_lib.sh" "$FULL_ROOT/main/lib_$fp_lib.sh" || return 1
    done
    full_freeze "$FULL_ROOT/bootstrap.sh" "$FULL_ROOT/nodes.sh" || return 1
    full_emit_frozen main "$FULL_ROOT/main/terminal.sh" &&
    full_stamp main/terminal.sh > "$FULL_ROOT/terminal.manifest" || return 1
    FULL_CLEANER_HASH=$(full_digest "$FULL_ROOT/main/cleaner.sh") || return 1
    FULL_STAGE_HASH=$(full_digest "$FULL_ROOT/main/stage.sh") || return 1
    full_stamp main/cleaner.sh main/stage.sh main/node.sh main/lib_selftest_context.sh main/lib_identity.sh main/lib_owner_lock.sh main/lib_action_lock.sh main/lib_full_fence.sh main/lib_update_state.sh main/lib_continuation.sh main/lib_radio.sh main/lib_mervqt.sh main/lib_settings_reconcile.sh main/lib_maintenance_quiesce.sh > "$FULL_ROOT/artifacts.manifest" || return 1
    FULL_ARTIFACTS_HASH=$(full_digest "$FULL_ROOT/artifacts.manifest") || return 1
    full_main_verify || { full_fail main-stage; return 1; }
    for fp_pair in functions/ssh_hostkey_probe.sh:probe.sh settings/lib_identity.sh:identity.sh settings/lib_ssh_trust.sh:trust.sh settings/lib_selftest_context.sh:selftest.sh settings/lib_ssh.sh:ssh.sh; do
        full_freeze "$MERV_BASE/${fp_pair%:*}" "$FULL_ROOT/${fp_pair#*:}" || return 1
    done
    # Freeze only this audited pure function for the canonical probe adapter.
    sed -n '/^merv_ssh_trust_derive_fingerprint() {$/,/^}$/p' "$FULL_ROOT/bootstrap.sh" > "$FULL_ROOT/fingerprint.sh" || return 1
    /bin/sh -n "$FULL_ROOT/fingerprint.sh" || return 1
    full_stamp probe.sh identity.sh trust.sh selftest.sh fingerprint.sh ssh.sh topology.awk bootstrap.sh nodes.sh > "$FULL_ROOT/authority.manifest" || return 1
    full_stamp settings.snapshot.json topology.map ssh.freeze artifacts.manifest terminal.manifest authority.manifest > "$FULL_ROOT/config.manifest" || return 1
    FULL_AUTHORITY_HASH=$(full_digest "$FULL_ROOT/authority.manifest") || return 1
    FULL_CONFIG_HASH=$(full_digest "$FULL_ROOT/config.manifest") || return 1
    # Check the whole installed cohort together before any node operation.
    # From this gate onward only the already-frozen generation is used.
    for fp_pair in functions/mervlan_full_cleanup.sh:main/cleaner.sh functions/ssh_hostkey_probe.sh:probe.sh settings/lib_identity.sh:identity.sh settings/lib_ssh_trust.sh:trust.sh settings/lib_selftest_context.sh:selftest.sh settings/lib_ssh.sh:ssh.sh settings/lib_full_uninstall.sh:bootstrap.sh; do
        [ "$(full_digest "$MERV_BASE/${fp_pair%:*}")" = "$(full_digest "$FULL_ROOT/${fp_pair#*:}")" ] || { full_fail source-generation; return 1; }
    done
    [ "$(full_digest "$FULL_ROOT/bootstrap.sh")" = "$(full_digest "$FULL_ROOT/nodes.sh")" ] || return 1
    for fp_lib in selftest_context identity owner_lock action_lock full_fence update_state continuation radio mervqt settings_reconcile maintenance_quiesce; do
        [ "$(full_digest "$MERV_BASE/settings/lib_$fp_lib.sh")" = "$(full_digest "$FULL_ROOT/main/lib_$fp_lib.sh")" ] || return 1
    done
    : > "$FULL_ROOT/endpoint.map"; : > "$FULL_ROOT/trust.identity.map"
    # First preflight ALL configured slots. Only transport unreachable/refused
    # before a successful key observation can advance to the snapshot candidate.
    while IFS=' ' read -r fp_slot fp_ip fp_mac fp_role fp_cfg fp_native fp_wan fp_extra; do
        [ -z "$fp_extra" ] || return 1
        case "$fp_slot" in SSH|MAIN|COUNT) continue ;; esac
        full_node "$fp_slot" "$fp_ip" "$fp_mac" "$fp_role" "$fp_cfg" "$fp_native" "$fp_wan" || return 1
        fp_candidates=$FULL_CANONICAL
        if [ "$FULL_WAN_IP" != none ] && [ "$FULL_WAN_IP" != "$FULL_CANONICAL" ]; then
            if [ "$FULL_NATIVE" != none ]; then fp_candidates="$FULL_WAN_IP $FULL_CANONICAL"
            else fp_candidates="$FULL_CANONICAL $FULL_WAN_IP"; fi
        fi
        fp_promoted=0
        for FULL_ENDPOINT in $fp_candidates; do
            full_probe; fp_rc=$?
            if [ "$fp_rc" = 0 ]; then fp_promoted=1; break; fi
            case "$fp_rc" in 10|11) ;; *) full_fail first-probe; return 1 ;; esac
        done
        [ "$fp_promoted" = 1 ] && full_read_probe || { full_fail first-identity; return 1; }
        full_trust_equal || { full_fail first-trust; return 1; }
        full_pin || { full_fail first-pin; return 1; }
        full_ssh proof < /dev/null || { full_fail first-auth; return 1; }
    done < "$FULL_ROOT/topology.map"
    [ "$(cat "$FULL_ROOT/endpoint.map")" = "$FULL_ENDPOINT_EXPECTED" ] &&
    [ "$(cat "$FULL_ROOT/trust.identity.map")" = "$FULL_IDENTITY_EXPECTED" ] || { full_fail map-generation; return 1; }
    full_stamp endpoint.map trust.identity.map > "$FULL_ROOT/maps.manifest" || return 1
    while IFS=' ' read -r fp_slot fp_rest; do
        [ -n "$fp_rest" ] || return 1
        case "$fp_slot" in NODE*) full_stamp "$fp_slot/.ssh/known_hosts" >> "$FULL_ROOT/maps.manifest" || return 1 ;; esac
    done < "$FULL_ROOT/topology.map"
    FULL_MAPS_HASH=$(full_digest "$FULL_ROOT/maps.manifest") || return 1
    FULL_MAPS_FROZEN=1
    readonly FULL_RUN FULL_ROOT FULL_USER FULL_PORT FULL_COUNT FULL_CLIENT FULL_CLIENT_HASH
    readonly FULL_KEY FULL_KEY_HASH FULL_TRUST_HASH FULL_CLEANER_HASH FULL_STAGE_HASH
    readonly FULL_AUTHORITY_HASH FULL_CONFIG_HASH FULL_MAPS_HASH FULL_ARTIFACTS_HASH
    # No node is staged until the complete first-preflight gate passes.
    for fp_pass in stage second; do
        while IFS=' ' read -r fp_slot fp_ip fp_mac fp_role fp_cfg fp_native fp_wan fp_extra; do
            [ -z "$fp_extra" ] || return 1
            case "$fp_slot" in SSH|MAIN|COUNT) continue ;; esac
            full_authority_check && [ "$(full_digest "$FULL_ROOT/maps.manifest")" = "$FULL_MAPS_HASH" ] && full_check_stamp "$FULL_ROOT/maps.manifest" &&
            full_node "$fp_slot" "$fp_ip" "$fp_mac" "$fp_role" "$fp_cfg" "$fp_native" "$fp_wan" && full_load_pin || { full_fail maps; return 1; }
            if [ "$fp_pass" = stage ]; then
                full_ssh init < /dev/null &&
                full_ssh receive artifacts.manifest < "$FULL_ROOT/artifacts.manifest" || { full_fail stage-ambiguous; return 1; }
                while IFS=' ' read -r fp_hash fp_artifact; do
                    full_ssh receive "${fp_artifact#main/}" < "$FULL_ROOT/$fp_artifact" || { full_fail stage-ambiguous; return 1; }
                done < "$FULL_ROOT/artifacts.manifest"
                full_ssh verify < /dev/null || { full_fail stage-ambiguous; return 1; }
            else
                fp_expected="$FULL_ALG $FULL_FP $FULL_PUBLIC_KEY"
                full_probe && full_read_probe && [ "$FULL_ALG $FULL_FP $FULL_PUBLIC_KEY" = "$fp_expected" ] || { full_fail second-identity; return 1; }
                full_ssh proof < /dev/null && full_ssh verify < /dev/null || { full_fail second-preflight; return 1; }
            fi
        done < "$FULL_ROOT/topology.map"
    done
    if [ "$FULL_COUNT" != 0 ]; then
        full_authority_check && full_trust_equal || { full_fail final-authority; return 1; }
    fi
    [ "$(full_digest "$FULL_ROOT/config.manifest")" = "$FULL_CONFIG_HASH" ] &&
    [ "$(full_digest "$FULL_ROOT/maps.manifest")" = "$FULL_MAPS_HASH" ] &&
    full_main_verify && full_check_stamp "$FULL_ROOT/config.manifest" && full_check_stamp "$FULL_ROOT/maps.manifest" || { full_fail final-artifacts; return 1; }
    {
        printf 'format=phase7-v3\nrun=%s\nstate=READY_FOR_NODE_CLEANUP\nnode_count=%s\nbackup_policy=%s\nnode_reboot=no\nsupport=full-terminal-v1\n' "$FULL_RUN" "$FULL_COUNT" "$FULL_POLICY"
        full_stamp settings.snapshot.json topology.map ssh.freeze endpoint.map trust.identity.map artifacts.manifest terminal.manifest authority.manifest
        printf 'config_manifest_sha256=%s\nmaps_manifest_sha256=%s\n' "$FULL_CONFIG_HASH" "$FULL_MAPS_HASH"
    } > "$FULL_ROOT/ready.tmp" || return 1
    full_private "$FULL_ROOT/ready.tmp" -rw------- || return 1
    mv "$FULL_ROOT/ready.tmp" "$FULL_ROOT/ready" || return 1
    printf 'READY_FOR_NODE_CLEANUP %s\n' "$FULL_RUN"
}

# ---- 09 Sequential NODE coordination, results and journal ----
full_nodes_ready() {
    FULL_UID=$(id -u) || return 1
    # Loaded code was already authenticated by the private entry. Canonical
    # identity/trust code comes from the frozen authority, never live settings.
    . "$FULL_ROOT/selftest.sh" && . "$FULL_ROOT/identity.sh" && . "$FULL_ROOT/trust.sh" && . "$FULL_ROOT/bootstrap.sh" || return 1
    full_private "$FULL_ROOT" drwx------ && full_private "$FULL_ROOT/ready" -rw------- &&
    [ "$(full_digest "$FULL_ROOT/ready")" = "$FULL_READY_HASH" ] || return 1
    FULL_POLICY=$(awk -F= '$1=="backup_policy" {print $2}' "$FULL_ROOT/ready")
    case "$FULL_POLICY" in KEEP|DELETE) ;; *) return 1 ;; esac
    FULL_RUN=$(awk -F= '$1=="run" {print $2}' "$FULL_ROOT/ready")
    [ "${#FULL_RUN}" -le 100 ] && printf '%s\n' "$FULL_RUN" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    fnr_expected_root="/tmp/.mervlan-full.$FULL_RUN"
    if merv_selftest_context_valid; then fnr_expected_root="$MERV_SELFTEST_CONTEXT_ROOT/.mervlan-full.$FULL_RUN"; fi
    [ "$FULL_ROOT" = "$fnr_expected_root" ] || return 1
    full_private "$FULL_ROOT/ssh.freeze" -rw------- && full_private "$FULL_ROOT/topology.map" -rw------- || return 1
    read -r fnr_protocol FULL_USER FULL_PORT FULL_CLIENT FULL_CLIENT_HASH FULL_KEY FULL_KEY_HASH FULL_TRUST_HASH fnr_extra < "$FULL_ROOT/ssh.freeze"
    [ "$fnr_protocol" = phase7-v1 ] && [ -z "$fnr_extra" ] || return 1
    FULL_COUNT=$(awk '$1=="COUNT" {print $2}' "$FULL_ROOT/topology.map")
    case "$FULL_COUNT" in 0|1|2|3|4|5|6|7|8|9|10) ;; *) return 1 ;; esac
    FULL_CONFIG_HASH=$(full_digest "$FULL_ROOT/config.manifest") && FULL_MAPS_HASH=$(full_digest "$FULL_ROOT/maps.manifest") &&
    FULL_ARTIFACTS_HASH=$(full_digest "$FULL_ROOT/artifacts.manifest") && FULL_AUTHORITY_HASH=$(full_digest "$FULL_ROOT/authority.manifest") || return 1
    FULL_CLEANER_HASH=$(full_digest "$FULL_ROOT/main/cleaner.sh") && FULL_STAGE_HASH=$(full_digest "$FULL_ROOT/main/stage.sh") && FULL_WRAPPER_HASH=$(full_digest "$FULL_ROOT/main/node.sh") || return 1
    full_check_stamp "$FULL_ROOT/authority.manifest" && full_check_stamp "$FULL_ROOT/config.manifest" && full_check_stamp "$FULL_ROOT/maps.manifest" && full_main_verify || return 1
    fnr_expected=$(printf 'format=phase7-v3\nrun=%s\nstate=READY_FOR_NODE_CLEANUP\nnode_count=%s\nbackup_policy=%s\nnode_reboot=no\nsupport=full-terminal-v1\n' "$FULL_RUN" "$FULL_COUNT" "$FULL_POLICY"
        full_stamp settings.snapshot.json topology.map ssh.freeze endpoint.map trust.identity.map artifacts.manifest terminal.manifest authority.manifest
        printf 'config_manifest_sha256=%s\nmaps_manifest_sha256=%s\n' "$FULL_CONFIG_HASH" "$FULL_MAPS_HASH") || return 1
    [ "$(cat "$FULL_ROOT/ready")" = "$fnr_expected" ] &&
    [ "$(wc -c < "$FULL_ROOT/ready")" = "$(printf '%s\n' "$fnr_expected" | wc -c)" ] || return 1
    FULL_MAPS_FROZEN=1
    # No continuation/restart. Even a coordinator that dies before first NODE
    # leaves its claim, journal and evidence for manual inspection.
    mkdir "$FULL_ROOT/phase8.claim" || return 1
    full_private "$FULL_ROOT/phase8.claim" drwx------ || return 1
    readonly FULL_POLICY FULL_ROOT FULL_RUN FULL_READY_HASH FULL_COUNT FULL_CONFIG_HASH FULL_MAPS_HASH FULL_ARTIFACTS_HASH FULL_AUTHORITY_HASH
    readonly FULL_USER FULL_PORT FULL_CLIENT FULL_CLIENT_HASH FULL_KEY FULL_KEY_HASH FULL_TRUST_HASH FULL_CLEANER_HASH FULL_STAGE_HASH FULL_WRAPPER_HASH
}
full_nodes_journal() {
    full_private "$FULL_ROOT/phase8.claim" drwx------ &&
    [ ! -e "$FULL_ROOT/phase8.claim/journal.tmp" ] && [ ! -L "$FULL_ROOT/phase8.claim/journal.tmp" ] || return 1
    (set -C
    {
        printf 'protocol=phase8-journal-v1\nrun=%s\nstate=PHASE8_NODE_CLEANUP\ncurrent_slot=%s\nready_sha256=%s\ngeneration=%s\n' "$FULL_RUN" "${FULL_SLOT:-none}" "$FULL_READY_HASH" "$FULL_ARTIFACTS_HASH"
        for fnj_num in 1 2 3 4 5 6 7 8 9 10; do
            fnj_slot=NODE$fnj_num
            if awk -v s="$fnj_slot" '$1==s {found=1} END {exit !found}' "$FULL_ROOT/topology.map"; then
                if [ -f "$FULL_ROOT/phase8.claim/$fnj_slot.state" ]; then cat "$FULL_ROOT/phase8.claim/$fnj_slot.state"
                else printf '%s NOT_ATTEMPTED none\n' "$fnj_slot"; fi
            fi
        done
    } > "$FULL_ROOT/phase8.claim/journal.tmp") &&
    mv "$FULL_ROOT/phase8.claim/journal.tmp" "$FULL_ROOT/journal"
}
full_nodes_state() {
    full_private "$FULL_ROOT/phase8.claim" drwx------ || return 1
    (set -C; printf '%s %s %s\n' "$FULL_SLOT" "$1" "$2" > "$FULL_ROOT/phase8.claim/$FULL_SLOT.state.tmp") &&
    mv "$FULL_ROOT/phase8.claim/$FULL_SLOT.state.tmp" "$FULL_ROOT/phase8.claim/$FULL_SLOT.state" && full_nodes_journal
}
full_nodes_result() {
    full_private "$1" -rw------- || return 1
    fnv_values=$(awk -F= '
        BEGIN {n=split("protocol run slot identity wrapper_pid wrapper_start cleaner_run cleaner_pid cleaner_start cleanup_rc rc class reason fence maintenance backup_policy reboot generation ready_sha256",a," ");for(i=1;i<=n;i++)ok[a[i]]=1}
        NF!=2 || !ok[$1] || seen[$1]++ || $2=="" || $2 ~ /[^A-Za-z0-9_.:@-]/ {bad=1}
        {v[$1]=$2}
        END {if(bad || NR!=n)exit 1;for(i=1;i<=n;i++)printf "%s%s",v[a[i]],(i==n?"\n":" ")}' "$1") || return 1
    read -r fnv_protocol fnv_run fnv_slot fnv_identity fnv_pid fnv_start fnv_cleaner fnv_child fnv_child_start fnv_cleanup fnv_rc FULL_NODE_CLASS fnv_reason fnv_fence fnv_m fnv_backup fnv_reboot fnv_generation fnv_ready <<EOF
$fnv_values
EOF
    [ "$fnv_protocol" = phase8-result-v1 ] && [ "$fnv_run" = "$FULL_RUN" ] && [ "$fnv_slot" = "$FULL_SLOT" ] &&
    [ "$fnv_identity" = "$FULL_NODE_ID" ] && [ "$fnv_generation" = "$FULL_ARTIFACTS_HASH" ] && [ "$fnv_ready" = "$FULL_READY_HASH" ] &&
    [ "$fnv_backup:$fnv_reboot" = "$FULL_POLICY:no" ] && [ "$fnv_rc" = "$2" ] || return 1
    for fnv_uint in "$fnv_pid" "$fnv_start"; do
        case "$fnv_uint" in ''|0|*[!0-9]*) return 1 ;; esac
        [ "${#fnv_uint}" -le 20 ] || return 1
    done
    case "$FULL_NODE_CLASS:$fnv_rc:$fnv_fence" in
        SUCCESS:0:released|FAILED_TERMINAL:3:released)
            [ "$fnv_cleaner" = "$FULL_RUN.$FULL_SLOT" ] || return 1
            for fnv_uint in "$fnv_child" "$fnv_child_start"; do case "$fnv_uint" in ''|0|*[!0-9]*) return 1 ;; esac; done
            case "$fnv_cleanup" in 0|2|3|4|130|143) ;; *) return 1 ;; esac
            if [ "$FULL_NODE_CLASS" = SUCCESS ]; then [ "$fnv_cleanup" = 0 ] || return 1
            else [ "$fnv_cleanup" != 0 ] || return 1; fi
            case "$fnv_m" in released|removed-with-runtime) ;; *) return 1 ;; esac ;;
        REFUSED:2:released|REFUSED:2:not-owned)
            [ "$fnv_child:$fnv_child_start:$fnv_cleanup" = none:none:none ] || return 1 ;;
        UNVERIFIED:4:retained|UNVERIFIED:4:not-owned) ;;
        *) return 1 ;;
    esac
}
full_nodes_context() {
    printf 'protocol=phase8-node-v1\nrun=%s\nslot=%s\nidentity=%s\ncleaner_sha256=%s\nwrapper_sha256=%s\ngeneration=%s\nready_sha256=%s\nbackup_policy=%s\nreboot=no\n' \
        "$FULL_RUN" "$FULL_SLOT" "$FULL_NODE_ID" "$FULL_CLEANER_HASH" "$FULL_WRAPPER_HASH" "$FULL_ARTIFACTS_HASH" "$FULL_READY_HASH" "$FULL_POLICY"
}
full_nodes() {
    full_nodes_ready || { printf 'PHASE8_REFUSED readiness-or-replay\n' >&2; return 2; }
    full_nodes_journal || return 4
    # Numeric slots explicitly, independent of IP/map/discovery order.
    for fn_num in 1 2 3 4 5 6 7 8 9 10; do
        FULL_SLOT=NODE$fn_num
        fn_row=$(awk -v s="$FULL_SLOT" '$1==s {n++;r=$0} END {if(n>1)exit 1;print r}' "$FULL_ROOT/topology.map") || return 4
        [ -n "$fn_row" ] || continue
        full_nodes_state INVOKING none || return 4
        set -- $fn_row
        if ! full_node "$@" || ! full_load_pin || ! full_ssh verify < /dev/null; then
            full_nodes_state REFUSED none || return 4
            printf 'PHASE8_STOP %s REFUSED pre-invocation\n' "$FULL_SLOT"; return 2
        fi
        (set -C; full_nodes_context > "$FULL_ROOT/phase8.claim/$FULL_SLOT.context") || return 4
        # Exact context upload also verifies artifacts on the NODE before
        # creating the inert context. No destructive operation in this step.
        if ! full_ssh context context < "$FULL_ROOT/phase8.claim/$FULL_SLOT.context"; then
            full_nodes_state REFUSED none || return 4
            printf 'PHASE8_STOP %s REFUSED context-stage\n' "$FULL_SLOT"; return 2
        fi
        if ! full_transport_check; then
            full_nodes_state REFUSED none || return 4
            printf 'PHASE8_STOP %s REFUSED trust-or-generation\n' "$FULL_SLOT"; return 2
        fi
        # Authentication uses frozen known_hosts; no -y, enrollment, probing
        # candidates, fallback or retry. A bounded transport timeout is ambiguous.
        FULL_OPERATION_TIMEOUT=300
        (set -C; full_bounded "env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/sh '/tmp/.mervlan-full-stage.$FULL_RUN/node.sh' --run '/tmp/.mervlan-full-stage.$FULL_RUN/context'" \
            < /dev/null > "$FULL_ROOT/phase8.claim/$FULL_SLOT.result" 2> "$FULL_ROOT/phase8.claim/$FULL_SLOT.stderr")
        fn_rc=$?
        FULL_OPERATION_TIMEOUT=20
        if ! full_nodes_result "$FULL_ROOT/phase8.claim/$FULL_SLOT.result" "$fn_rc"; then FULL_NODE_CLASS=UNVERIFIED; fn_rc=4; fi
        fn_digest=$(full_digest "$FULL_ROOT/phase8.claim/$FULL_SLOT.result") || return 4
        full_nodes_state "$FULL_NODE_CLASS" "$fn_digest" || return 4
        [ "$FULL_NODE_CLASS" = SUCCESS ] || { printf 'PHASE8_STOP %s %s\n' "$FULL_SLOT" "$FULL_NODE_CLASS"; return "$fn_rc"; }
    done
    # Revalidate every stored SUCCESS receipt and digest before handoff. The
    # journal is evidence, never a resume instruction or a success shortcut.
    [ "$(full_digest "$FULL_ROOT/ready")" = "$FULL_READY_HASH" ] &&
    [ "$(full_digest "$FULL_ROOT/config.manifest")" = "$FULL_CONFIG_HASH" ] &&
    [ "$(full_digest "$FULL_ROOT/maps.manifest")" = "$FULL_MAPS_HASH" ] &&
    [ "$(full_digest "$FULL_ROOT/authority.manifest")" = "$FULL_AUTHORITY_HASH" ] &&
    full_check_stamp "$FULL_ROOT/config.manifest" && full_check_stamp "$FULL_ROOT/authority.manifest" &&
    full_check_stamp "$FULL_ROOT/maps.manifest" && full_main_verify || return 4
    for fn_num in 1 2 3 4 5 6 7 8 9 10; do
        FULL_SLOT=NODE$fn_num
        fn_row=$(awk -v s="$FULL_SLOT" '$1==s {print}' "$FULL_ROOT/topology.map") || return 4
        [ -n "$fn_row" ] || continue
        set -- $fn_row
        full_node "$@" && full_load_pin || return 4
        fn_result="$FULL_ROOT/phase8.claim/$FULL_SLOT.result"
        fn_state="$FULL_ROOT/phase8.claim/$FULL_SLOT.state"
        full_private "$fn_state" -rw------- && full_nodes_result "$fn_result" 0 && [ "$FULL_NODE_CLASS" = SUCCESS ] || return 4
        fn_expected="$FULL_SLOT SUCCESS $(full_digest "$fn_result")"
        [ "$(cat "$fn_state")" = "$fn_expected" ] && [ "$(wc -c < "$fn_state")" = "$(printf '%s\n' "$fn_expected" | wc -c)" ] || return 4
    done
    (set -C
    {
        printf 'protocol=phase8-handoff-v2\nrun=%s\nstate=NODE_PHASE_COMPLETE\nnode_count=%s\nbackup_policy=%s\nreboot=no\nready_sha256=%s\ngeneration=%s\ntopology_sha256=%s\njournal_sha256=%s\nsupport=full-terminal-v1\nterminal_manifest_sha256=%s\n' \
            "$FULL_RUN" "$FULL_COUNT" "$FULL_POLICY" "$FULL_READY_HASH" "$FULL_ARTIFACTS_HASH" "$(full_digest "$FULL_ROOT/topology.map")" "$(full_digest "$FULL_ROOT/journal")" "$(full_digest "$FULL_ROOT/terminal.manifest")"
        for fn_num in 1 2 3 4 5 6 7 8 9 10; do
            fn_state="$FULL_ROOT/phase8.claim/NODE$fn_num.state"
            [ ! -f "$fn_state" ] || cat "$fn_state"
        done
    } > "$FULL_ROOT/phase8.claim/handoff.tmp") && full_private "$FULL_ROOT/phase8.claim/handoff.tmp" -rw------- &&
    mv "$FULL_ROOT/phase8.claim/handoff.tmp" "$FULL_ROOT/node-phase-complete" || return 4
    printf 'NODE_PHASE_COMPLETE count=%s run=%s\n' "$FULL_COUNT" "$FULL_RUN"
}

# ---- 10 Authenticated frozen NODE coordinator entry ----
full_nodes_entry() {
# No caller-selected code path outside the exact private run root.
set -f
umask 077
FULL_ROOT=$1; FULL_READY_HASH=$2
case "$FULL_ROOT" in *..*|*//*|*[!A-Za-z0-9_./-]*|*/) exit 2 ;; esac
case "$FULL_ROOT" in /tmp/.mervlan-full.*|/tmp/mervlan-*/.mervlan-full.*) ;; *) exit 2 ;; esac
[ "${#FULL_READY_HASH}" = 64 ] || exit 2
case "$FULL_READY_HASH" in *[!0-9a-f]*) exit 2 ;; esac
fn_digest() {
    _fn_h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    [ "${#_fn_h}" = 64 ] || _fn_h=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}')
    printf '%s\n' "$_fn_h"
}
# Validate all path components before reading/source execution.
_fn_rest=${FULL_ROOT#/}; _fn_path=/
while [ -n "$_fn_rest" ]; do
    case "$_fn_rest" in */*) _fn_part=${_fn_rest%%/*}; _fn_rest=${_fn_rest#*/} ;; *) _fn_part=$_fn_rest; _fn_rest= ;; esac
    _fn_path=$_fn_path$_fn_part
    [ -d "$_fn_path" ] && [ ! -L "$_fn_path" ] || exit 2
    _fn_path=$_fn_path/
done
[ "$(ls -ldn "$FULL_ROOT" | awk '{print $1 " " $3}')" = "drwx------ $(id -u)" ] || exit 2
[ ! -L "$FULL_ROOT/ready" ] && [ "$(fn_digest "$FULL_ROOT/ready")" = "$FULL_READY_HASH" ] || exit 2
# The ready digest binds authority.manifest; it binds every file sourced next.
_fn_authority=$(awk '$2=="authority.manifest" && NF==2 {n++;h=$1} END {if(n!=1)exit 1;print h}' "$FULL_ROOT/ready") || exit 2
[ ! -L "$FULL_ROOT/authority.manifest" ] && [ "$(fn_digest "$FULL_ROOT/authority.manifest")" = "$_fn_authority" ] || exit 2
for _fn_leaf in nodes.sh selftest.sh identity.sh trust.sh bootstrap.sh; do
    [ ! -L "$FULL_ROOT/$_fn_leaf" ] && [ "$(ls -ldn "$FULL_ROOT/$_fn_leaf" | awk '{print $1 " " $3}')" = "-rw------- $(id -u)" ] || exit 2
    _fn_expected=$(awk -v n="$_fn_leaf" '$2==n && NF==2 {count++;h=$1} END {if(count!=1)exit 1;print h}' "$FULL_ROOT/authority.manifest") || exit 2
    [ "$(fn_digest "$FULL_ROOT/$_fn_leaf")" = "$_fn_expected" ] || exit 2
done
. "$FULL_ROOT/nodes.sh" || exit 2
full_nodes
}

# ---- 11 Private deterministic runtime-program emission ----
full_emit_frozen() {
    fef_kind=$1; fef_dest=$2
    case "$fef_kind" in topology|stage|node|main) ;; *) return 1 ;; esac
    full_private "$FULL_ROOT" drwx------ && full_private "$FULL_ROOT/bootstrap.sh" -rw------- || return 1
    full_safe_path "$fef_dest" || return 1
    case "$fef_dest" in "$FULL_ROOT/topology.awk"|"$FULL_ROOT/main/stage.sh"|"$FULL_ROOT/main/node.sh"|"$FULL_ROOT/main/terminal.sh") ;; *) return 1 ;; esac
    [ ! -e "$fef_dest" ] && [ ! -L "$fef_dest" ] || return 1
    (umask 077; set -C
        env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/sh -c \
        '. "$1" || exit 1; "full_emit_${2}_program"' emit "$FULL_ROOT/bootstrap.sh" "$fef_kind" > "$fef_dest") || return 1
    full_private "$fef_dest" -rw------- && [ -s "$fef_dest" ] || return 1
    if [ "$fef_kind" != topology ]; then
        /bin/sh -n "$fef_dest" || return 1
        if type busybox >/dev/null 2>&1; then busybox sh -n "$fef_dest" || return 1; fi
        case "$fef_kind" in
            stage) fef_marker='# Full inert stage protocol: phase7-stage-v2' ;;
            node) fef_marker='# Full NODE protocol: phase8-node-v1' ;;
            main) fef_marker='# Full MAIN protocol: phase9-main-v1' ;;
        esac
        grep -Fx "$fef_marker" "$fef_dest" >/dev/null || return 1
    fi
    full_digest "$fef_dest" >/dev/null
}

# Literal TOPOLOGY program; no runtime data is interpolated.
full_emit_topology_program() {
    cat <<'MERVLAN_FULL_TOPOLOGY_PROGRAM'
# Full-only strict JSON reader, phase7-v1. BusyBox awk; no jq/Python runtime.
# Reject duplicate keys in every object (including escaped aliases), trailing
# data, invalid types and malformed-present determining sections. Bound input
# and recursion; emit only validated, non-secret Full fields in slot order.
function fail() { bad=1; exit 1 }
BEGIN { for(byte=0;byte<256;byte++) ord[sprintf("%c",byte)]=byte }
function utf8(    i,b,n,j,c,lo,hi) {
    for(i=1;i<=length(doc);i++) {
        b=ord[substr(doc,i,1)]
        if(b<128) continue
        lo=128; hi=191
        if(b>=194 && b<=223) n=1
        else if(b>=224 && b<=239) { n=2; if(b==224)lo=160; if(b==237)hi=159 }
        else if(b>=240 && b<=244) { n=3; if(b==240)lo=144; if(b==244)hi=143 }
        else fail()
        for(j=1;j<=n;j++) {
            if(++i>length(doc)) fail()
            c=ord[substr(doc,i,1)]
            if(c<lo || c>hi) fail()
            lo=128; hi=191
        }
    }
}
function ws() { while (substr(doc,pos,1) ~ /^[ \t\r\n]$/) pos++ }
function hex(s,    i,n,c) {
    n=0
    for(i=1;i<=length(s);i++) {
        c=index("0123456789abcdef",tolower(substr(s,i,1)))-1
        if(c<0) fail()
        n=n*16+c
    }
    return n
}
function string(    out,c,e,u,v) {
    if(substr(doc,pos++,1)!="\"") fail()
    out=""
    while(pos<=length(doc)) {
        c=substr(doc,pos++,1)
        if(c=="\"") return out
        if(c ~ /[[:cntrl:]]/) fail()
        if(c!="\\") { out=out c; continue }
        e=substr(doc,pos++,1)
        if(e=="\"" || e=="\\" || e=="/") out=out e
        else if(e=="b") out=out sprintf("%c",8)
        else if(e=="f") out=out sprintf("%c",12)
        else if(e=="n") out=out "\n"
        else if(e=="r") out=out "\r"
        else if(e=="t") out=out "\t"
        else if(e=="u") {
            if(length(substr(doc,pos,4))!=4) fail()
            u=hex(substr(doc,pos,4)); pos+=4
            if(u>=55296 && u<=56319) {
                if(substr(doc,pos,2)!="\\u") fail()
                pos+=2; v=hex(substr(doc,pos,4)); pos+=4
                if(v<56320 || v>57343) fail()
                u=65536+(u-55296)*1024+v-56320
            } else if(u>=56320 && u<=57343) fail()
            # Encode Unicode so escaped and literal keys have the same identity.
            if(u<128) out=out sprintf("%c",u)
            else if(u<2048) out=out sprintf("%c%c",192+int(u/64),128+u%64)
            else if(u<65536) out=out sprintf("%c%c%c",224+int(u/4096),128+int(u/64)%64,128+u%64)
            else out=out sprintf("%c%c%c%c",240+int(u/262144),128+int(u/4096)%64,128+int(u/64)%64,128+u%64)
        } else fail()
    }
    fail()
}
function value(path,depth,    c,key,child,n,t,part) {
    if(depth>32) fail()
    ws(); c=substr(doc,pos,1)
    if(c=="{" || c=="[") {
        typ[path]=(c=="{"?"object":"array"); pos++; ws(); n=0
        if(substr(doc,pos,1)==(c=="{"?"}":"]")) { pos++; return }
        while(1) {
            if(c=="{") {
                key=string(); ws()
                if(substr(doc,pos++,1)!=":") fail()
                # A length prefix avoids collisions from control bytes in keys.
                child=path "/" length(key) ":" key
                if(child in typ) fail()
            } else child=path "/#" ++n
            value(child,depth+1); ws(); t=substr(doc,pos++,1)
            if(t==(c=="{"?"}":"]")) return
            if(t!=",") fail()
            ws()
        }
    }
    if(c=="\"") { typ[path]="string"; val[path]=string(); return }
    part=substr(doc,pos)
    if(match(part,/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
        typ[path]="number"; val[path]=substr(part,1,RLENGTH); pos+=RLENGTH; return
    }
    for(t=1;t<=3;t++) {
        key=(t==1?"true":t==2?"false":"null")
        if(substr(doc,pos,length(key))==key) {
            typ[path]=key; val[path]=key; pos+=length(key); return
        }
    }
    fail()
}
function p(parent,key) { return parent "/" length(key) ":" key }
function section(path) { if((path in typ) && typ[path]!="object") fail() }
function get(parent,key,default,    path) {
    path=p(parent,key)
    if(!(path in typ)) return default
    if(typ[path]!="string" && typ[path]!="number") fail()
    return val[path]
}
function prefer(parent,key,default,    path) {
    path=p(parent,key)
    if(path in typ) return get(parent,key,default)
    return get("",key,default)
}
function ipv4(s,    a,n,i) {
    n=split(s,a,".")
    if(n!=4) return 0
    for(i=1;i<=4;i++) if(a[i]!~/^(0|[1-9][0-9]*)$/ || length(a[i])>3 || a[i]+0>255) return 0
    return 1
}
function native(s) {
    s=tolower(s)
    if(s=="none" || s=="asus") return "none"
    if(s!~/^[0-9]+$/ || length(s)>4 || s+0<2 || s+0>4094) fail()
    return sprintf("%d",s+0)
}
{ doc=doc $0 "\n"; if(length(doc)>1048576) fail() }
END {
    if(bad) exit 1
    utf8()
    pos=1; value("",0); ws()
    if(pos<=length(doc) || typ[""]!="object") fail()
    nodes=p("","Nodes"); ssh=p("","SSH"); vlan=p("","VLAN"); wan=p(vlan,"WAN_Native")
    section(nodes); section(ssh); section(vlan); section(wan)
    user=prefer(ssh,"NODE_SSH_USER",prefer(ssh,"SSH_USER","admin"))
    port=prefer(ssh,"NODE_SSH_PORT",prefer(ssh,"SSH_PORT","22"))
    if(user!~/^[A-Za-z0-9_][A-Za-z0-9._-]*$/ || length(user)>64) fail()
    if(port!~/^[1-9][0-9]*$/ || length(port)>5 || port+0>65535) fail()
    main=native(prefer(wan,"WAN_NATIVE_MAIN","none"))
    # Reject out-of-range actual target keys, even explicit none in Nodes.
    for(path in typ) {
        prefix=nodes "/"; root="/"
        if(substr(path,1,length(prefix))==prefix) rest=substr(path,length(prefix)+1)
        else if(substr(path,1,1)==root) rest=substr(path,2)
        else continue
        sub(/^[0-9]+:/,"",rest)
        if(rest~/^NODE[0-9]+$/) {
            idx=substr(rest,5)+0
            if(idx<1 || idx>10 || rest!="NODE" idx) fail()
        }
    }
    for(i=1;i<=10;i++) {
        key="NODE" i; endpoint=prefer(nodes,key,"none")
        if(endpoint=="none") continue
        if(!ipv4(endpoint)) fail()
        if(endpoint in endpoints) fail()
        endpoints[endpoint]=1
        mac=toupper(prefer(nodes,"AUTO_" key "_MAC","none"))
        if(mac=="NONE") mac="none"
        if(mac!="none") {
            if(mac!~/^[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]$/ || mac in macs) fail()
            macs[mac]=1
        }
        role=tolower(prefer(nodes,key "_ROLE","standalone"))
        if(role!="aimesh" && role!="standalone") fail()
        configured=native(prefer(wan,"WAN_NATIVE_" key,"none"))
        effective=(role=="aimesh"?main:configured)
        ip=prefer(nodes,key "_WAN_NATIVE_IP","none")
        if(ip!="none" && !ipv4(ip)) fail()
        if(effective!="none" && ip=="none") fail()
        rows[i]=key " " endpoint " " mac " " role " " configured " " effective " " ip
        count++
    }
    # Candidate collisions also make two slots cryptographically ambiguous.
    for(i=1;i<=10;i++) if(i in rows) {
        split(rows[i],a," ")
        if(a[7]!="none" && a[7]!=a[2]) {
            if(a[7] in endpoints) fail()
            endpoints[a[7]]=1
        }
    }
    print "SSH " user " " port
    print "MAIN " main
    print "COUNT " count+0
    for(i=1;i<=10;i++) if(i in rows) print rows[i]
}
MERVLAN_FULL_TOPOLOGY_PROGRAM
}

# Literal STAGE program; no runtime data is interpolated.
full_emit_stage_program() {
    cat <<'MERVLAN_FULL_STAGE_PROGRAM'
#!/bin/sh
# Full inert stage protocol: phase7-stage-v2
# Device-local inert transport. Never acquires M/F or executes NODE cleanup.
# Args: operation run artifact-manifest-sha256 verifier-sha256 [name]
umask 077
set -f
fs_op=${1:-}; fs_run=${2:-}; fs_manifest=${3:-}; fs_helper=${4:-}; fs_name=${5:-}
[ "$#" = 5 ] || exit 2
[ "${#fs_run}" -le 100 ] && printf '%s\n' "$fs_run" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || exit 2
for fs_hash in "$fs_manifest" "$fs_helper"; do
    [ "${#fs_hash}" = 64 ] || exit 2
    case "$fs_hash" in *[!0-9a-f]*) exit 2 ;; esac
done
fs_root="/tmp/.mervlan-full-stage.$fs_run"
fs_uid=$(id -u) || exit 2
fs_private() {
    [ ! -L "$1" ] || return 1
    [ "$(LC_ALL=C ls -ldn "$1" 2>/dev/null | awk '{print $1 " " $3}')" = "$2 $fs_uid" ]
}
fs_digest() {
    fs_d=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    if [ "${#fs_d}" != 64 ]; then fs_d=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'); fi
    [ "${#fs_d}" = 64 ] || return 1
    case "$fs_d" in *[!0-9a-f]*) return 1 ;; esac
    printf '%s\n' "$fs_d"
}
fs_names='cleaner.sh stage.sh node.sh lib_selftest_context.sh lib_identity.sh lib_owner_lock.sh lib_action_lock.sh lib_full_fence.sh lib_update_state.sh lib_continuation.sh lib_radio.sh lib_mervqt.sh lib_settings_reconcile.sh lib_maintenance_quiesce.sh'
fs_manifest_valid() {
    fs_private "$fs_root/artifacts.manifest" -rw------- &&
    [ "$(fs_digest "$fs_root/artifacts.manifest")" = "$fs_manifest" ] || return 1
    awk -v names="$fs_names" '
        BEGIN {n=split(names,a," "); for(i=1;i<=n;i++) allowed["main/" a[i]]=1}
        NF!=2 || length($1)!=64 || $1 ~ /[^0-9a-f]/ || !allowed[$2] || seen[$2]++ {bad=1}
        END {exit (bad || NR!=n)}' "$fs_root/artifacts.manifest"
}
fs_verify() {
    fs_private "$fs_root" drwx------ && [ -d "$fs_root" ] && fs_manifest_valid || return 1
    fs_count=0
    # Globbing deliberately enabled only for exact membership inspection.
    set +f
    for fs_path in "$fs_root"/* "$fs_root"/.[!.]* "$fs_root"/..?*; do
        [ -e "$fs_path" ] || [ -L "$fs_path" ] || continue
        fs_leaf=${fs_path##*/}
        [ "$fs_leaf" != artifacts.manifest ] || { fs_count=$((fs_count + 1)); continue; }
        case " $fs_names " in *" $fs_leaf "*) ;; *) set -f; return 1 ;; esac
        fs_expected=$(awk -v n="main/$fs_leaf" '$2==n {print $1}' "$fs_root/artifacts.manifest")
        [ -f "$fs_path" ] && [ -s "$fs_path" ] && fs_private "$fs_path" -rw------- &&
        [ "$(fs_digest "$fs_path")" = "$fs_expected" ] && /bin/sh -n "$fs_path" || { set -f; return 1; }
        case "$fs_leaf" in
            cleaner.sh) fs_marker='# Cleaner protocol: phase6-v1' ;;
            stage.sh) fs_marker='# Full inert stage protocol: phase7-stage-v2' ;;
            node.sh) fs_marker='# Full NODE protocol: phase8-node-v1' ;;
            *) fs_marker='#!/bin/sh' ;;
        esac
        grep -Fx "$fs_marker" "$fs_path" >/dev/null || { set -f; return 1; }
        fs_count=$((fs_count + 1))
    done
    set -f
    [ "$fs_count" = 15 ] && [ "$(fs_digest "$fs_root/stage.sh")" = "$fs_helper" ]
}
[ -d /tmp ] && [ ! -L /tmp ] || exit 2
case "$fs_op" in
    init)
        [ ! -e "$fs_root" ] && [ ! -L "$fs_root" ] && mkdir "$fs_root" && fs_private "$fs_root" drwx------ || exit 3 ;;
    receive|context)
        fs_private "$fs_root" drwx------ && [ -d "$fs_root" ] || exit 3
        if [ "$fs_op" = context ]; then
            [ "$fs_name" = context ] && fs_verify || exit 4
        else
            case " $fs_names artifacts.manifest " in *" $fs_name "*) [ -n "$fs_name" ] || exit 2 ;; *) exit 2 ;; esac
        fi
        fs_dest="$fs_root/$fs_name"
        [ ! -e "$fs_dest" ] && [ ! -L "$fs_dest" ] && [ ! -e "$fs_dest.part" ] && [ ! -L "$fs_dest.part" ] || exit 3
        (set -C; cat > "$fs_dest.part") && fs_private "$fs_dest.part" -rw------- && mv "$fs_dest.part" "$fs_dest" || exit 3 ;;
    verify) fs_verify || exit 4 ;;
    *) exit 2 ;;
esac
printf 'PHASE7_STAGE_OK %s %s\n' "$fs_op" "$fs_run"
MERVLAN_FULL_STAGE_PROGRAM
}

# Literal NODE program; no runtime data is interpolated.
full_emit_node_program() {
    cat <<'MERVLAN_FULL_NODE_PROGRAM'
#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# Full NODE protocol: phase8-node-v1
# Private device-local wrapper. All code is staged; authority stays canonical.
# Exit: 0 SUCCESS, 2 REFUSED, 3 FAILED_TERMINAL, 4 UNVERIFIED.
[ "$#" = 2 ] && [ "$1" = --run ] || exit 2
# No externally callable dirty-environment worker mode. The heredoc is exact
# staged source; only validated paths enter the clean execution environment.
exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/sh -s -- "$0" "$2" <<'FULL_NODE_ENTRY'
set -f
umask 077
nw_script=$1; nw_context=$2; nw_root=${nw_context%/*}; nw_uid=$(id -u) || exit 2
nw_private() {
    [ ! -L "$1" ] && [ "$(ls -ldn "$1" 2>/dev/null | awk '{print $1 " " $3}')" = "$2 $nw_uid" ]
}
nw_hash() {
    nw_h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    if [ "${#nw_h}" != 64 ]; then nw_h=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'); fi
    [ "${#nw_h}" = 64 ] || return 1
    case "$nw_h" in *[!0-9a-f]*) return 1 ;; esac
    printf '%s\n' "$nw_h"
}
nw_context_read() {
    [ "${#nw_context}" -le 240 ] || return 1
    case "$nw_context" in /tmp/.mervlan-full-stage.*/context) ;; *) return 1 ;; esac
    case "$nw_context" in *..*|*//*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    [ ! -L /tmp ] && nw_private "$nw_root" drwx------ && nw_private "$nw_context" -rw------- || return 1
    nw_values=$(awk -F= '
        NF!=2 || seen[$1]++ || $2=="" || $2 ~ /[^A-Za-z0-9_.:@-]/ {bad=1}
        $1=="protocol" || $1=="run" || $1=="slot" || $1=="identity" || $1=="cleaner_sha256" || $1=="wrapper_sha256" || $1=="generation" || $1=="ready_sha256" || $1=="backup_policy" || $1=="reboot" {v[$1]=$2; n++; next}
        {bad=1}
        END {if(bad || NR!=10 || n!=10)exit 1; print v["protocol"],v["run"],v["slot"],v["identity"],v["cleaner_sha256"],v["wrapper_sha256"],v["generation"],v["ready_sha256"],v["backup_policy"],v["reboot"]}' "$nw_context") || return 1
    read -r nw_protocol nw_run nw_slot nw_identity nw_cleaner_hash nw_wrapper_hash nw_generation nw_ready_hash nw_policy nw_reboot <<EOF
$nw_values
EOF
    [ "$nw_protocol" = phase8-node-v1 ] && [ "$nw_reboot" = no ] || return 1
    case "$nw_policy" in KEEP) nw_keep=1 ;; DELETE) nw_keep=0 ;; *) return 1 ;; esac
    [ "${#nw_run}" -le 100 ] && printf '%s\n' "$nw_run" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    case "$nw_slot" in NODE[1-9]|NODE10) ;; *) return 1 ;; esac
    [ "$nw_root" = "/tmp/.mervlan-full-stage.$nw_run" ] && [ "$nw_script" = "$nw_root/node.sh" ] || return 1
    for nw_digest in "$nw_cleaner_hash" "$nw_wrapper_hash" "$nw_generation" "$nw_ready_hash"; do
        [ "${#nw_digest}" = 64 ] || return 1
        case "$nw_digest" in *[!0-9a-f]*) return 1 ;; esac
    done
}
nw_membership() (
    set +f
    nw_count=0
    for nw_path in "$nw_root"/* "$nw_root"/.[!.]* "$nw_root"/..?*; do
        [ -e "$nw_path" ] || [ -L "$nw_path" ] || continue
        nw_leaf=${nw_path##*/}
        case " $nw_names artifacts.manifest context invocation.claim " in *" $nw_leaf "*) ;; *) return 1 ;; esac
        nw_count=$((nw_count + 1))
    done
    [ "$nw_count" = 17 ] && nw_private "$nw_root/invocation.claim" drwx------ &&
    nw_private "$nw_root/invocation.claim/owner" -rw------- &&
    [ "$(cat "$nw_root/invocation.claim/owner")" = "$nw_run:$$:$nw_start" ]
)
nw_artifacts() {
    nw_private "$nw_root/artifacts.manifest" -rw------- && [ "$(nw_hash "$nw_root/artifacts.manifest")" = "$nw_generation" ] || return 1
    nw_names='cleaner.sh stage.sh node.sh lib_selftest_context.sh lib_identity.sh lib_owner_lock.sh lib_action_lock.sh lib_full_fence.sh lib_update_state.sh lib_continuation.sh lib_radio.sh lib_mervqt.sh lib_settings_reconcile.sh lib_maintenance_quiesce.sh'
    nw_membership || return 1
    awk -v names="$nw_names" 'BEGIN {n=split(names,a," ");for(i=1;i<=n;i++) ok["main/" a[i]]=1}
        NF!=2 || length($1)!=64 || $1 ~ /[^0-9a-f]/ || !ok[$2] || seen[$2]++ {bad=1}
        END {exit (bad || NR!=n)}' "$nw_root/artifacts.manifest" || return 1
    while IFS=' ' read -r nw_digest nw_name; do
        nw_file="$nw_root/${nw_name#main/}"
        nw_private "$nw_file" -rw------- && [ -s "$nw_file" ] && [ "$(nw_hash "$nw_file")" = "$nw_digest" ] && /bin/sh -n "$nw_file" || return 1
    done < "$nw_root/artifacts.manifest"
    [ "$(nw_hash "$nw_script")" = "$nw_wrapper_hash" ] && [ "$(nw_hash "$nw_root/cleaner.sh")" = "$nw_cleaner_hash" ] &&
    grep -Fx '# Full NODE protocol: phase8-node-v1' "$nw_script" >/dev/null &&
    grep -Fx '# Cleaner protocol: phase6-v1' "$nw_root/cleaner.sh" >/dev/null
}
nw_record() {
    printf 'protocol=phase8-result-v1\nrun=%s\nslot=%s\nidentity=%s\nwrapper_pid=%s\nwrapper_start=%s\ncleaner_run=%s\ncleaner_pid=%s\ncleaner_start=%s\ncleanup_rc=%s\nrc=%s\nclass=%s\nreason=%s\nfence=%s\nmaintenance=%s\nbackup_policy=%s\nreboot=no\ngeneration=%s\nready_sha256=%s\n' \
        "$nw_run" "$nw_slot" "$nw_identity" "$$" "$nw_start" "$nw_cleaner_run" "$nw_child" "$nw_child_start" "$nw_cleanup_rc" "$nw_rc" "$nw_class" "$nw_reason" "$nw_fdis" "$nw_mdis" "$nw_policy" "$nw_generation" "$nw_ready_hash"
}
nw_decision() {
    # Cleanup/admission certainty is fixed before F disposition. This is not
    # the final wrapper receipt and deliberately has no wrapper exit code.
    printf 'protocol=phase8-decision-v1\nrun=%s\nslot=%s\nclassification=%s\nreason=%s\ncleaner_run=%s\ncleaner_pid=%s\ncleaner_start=%s\ncleanup_rc=%s\ngeneration=%s\nready_sha256=%s\n' \
        "$nw_run" "$nw_slot" "$nw_class" "$nw_reason" "$nw_cleaner_run" "$nw_child" "$nw_child_start" "$nw_cleanup_rc" "$nw_generation" "$nw_ready_hash"
}
nw_publish() {
    nw_private "$nw_root" drwx------ && [ ! -e "$nw_root/$1" ] && [ ! -L "$nw_root/$1" ] &&
    (set -C
        case "$1" in decision) nw_decision ;; result) nw_record ;; *) exit 1 ;; esac > "$nw_root/$1.tmp") && nw_private "$nw_root/$1.tmp" -rw------- && mv "$nw_root/$1.tmp" "$nw_root/$1"
}
nw_m_exact() { merv_owner_lock_path_chain_safe "$nw_m" && nw_private "$nw_m" drwx------ && merv_owner_v2_matches "$nw_m/owner" "$$" "$nw_mstart" "$nw_mnonce" /proc; }
nw_f_exact() { merv_full_fence_owner_is "$nw_f" "$$" "$nw_fstart" "$nw_fnonce"; }
nw_finish() {
    # Fix terminal decision durably before releasing F. Final receipt records
    # actual release. A decision publication failure or changed owner retains F.
    if [ "$nw_mdis" = owned ]; then
        if [ "$nw_entered" = yes ] && [ ! -e /tmp/mervlan_tmp ] && [ ! -L /tmp/mervlan_tmp ] && [ -d /tmp ]; then
            nw_mdis=removed-with-runtime
        elif nw_m_exact && merv_owner_lock_release "$nw_m" "$nw_mnonce"; then nw_mdis=released
        else nw_class=UNVERIFIED; nw_rc=4; nw_reason=maintenance-changed; nw_mdis=unverified; fi
    fi
    [ "$nw_class" != UNVERIFIED ] || nw_fdis=retained
    nw_publish decision || exit 4
    if [ "$nw_fdis" = owned ]; then
        if nw_f_exact && merv_full_fence_release "$nw_f" "$$" "$nw_fstart" "$nw_fnonce"; then nw_fdis=released
        else nw_class=UNVERIFIED; nw_rc=4; nw_reason=fence-release-unverified; nw_fdis=retained; fi
    fi
    nw_publish result || exit 4
    cat "$nw_root/result"
    exit "$nw_rc"
}
nw_refuse() { nw_class=REFUSED; nw_rc=2; nw_reason=$1; nw_finish; }
# Invalid unauthenticated context cannot authorize even a result destination.
nw_context_read || exit 2
nw_start=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$$/stat") || exit 2
case "$nw_start" in ''|*[!0-9]*) exit 2 ;; esac
# Permanent run-local claim prevents concurrent invocation and restart/replay.
mkdir "$nw_root/invocation.claim" 2>/dev/null || exit 4
nw_private "$nw_root/invocation.claim" drwx------ || exit 4
printf '%s:%s:%s\n' "$nw_run" "$$" "$nw_start" > "$nw_root/invocation.claim/owner" || exit 4
nw_class=REFUSED; nw_rc=2; nw_reason=artifact-mismatch; nw_fdis=not-owned; nw_mdis=not-owned
nw_cleaner_run=none; nw_child=none; nw_child_start=none; nw_cleanup_rc=none; nw_entered=no
nw_artifacts || nw_finish
# No installed libraries/settings: preload exact dependencies, then keep all
# state authority canonical. Loaded markers suppress transitive live sources.
# Q inventories canonical state with bounded globs; do not disable them.
set +f
MERV_BASE=/jffs/addons/mervlan
VAR_SETTINGS_LOADED=1
TMPDIR=/tmp/mervlan_tmp; LOCKDIR=/tmp/mervlan_tmp/locks
for nw_lib in selftest_context identity owner_lock action_lock full_fence update_state continuation radio mervqt settings_reconcile maintenance_quiesce; do
    . "$nw_root/lib_$nw_lib.sh" || nw_refuse support-load
 done
for nw_interface in merv_identity_nonce_next merv_identity_proc_start merv_owner_lock_acquire merv_owner_lock_release merv_full_fence_claim merv_full_fence_release merv_maintenance_quiesce_classify merv_settings_reconcile_read merv_dhcp_hold_rules_absent; do
    type "$nw_interface" >/dev/null 2>&1 || nw_refuse support-interface
 done
nw_m=$(merv_update_maintenance_lock_path) || nw_refuse maintenance-path
nw_f=$(merv_full_fence_path) || nw_refuse fence-path
# No catchable signal releases ownership. Abrupt death retains the fence.
trap 'exit 4' HUP INT TERM
merv_owner_lock_acquire "$nw_m" 0 0 full-node || nw_refuse maintenance-busy
nw_mstart=$MERV_LOCK_START; nw_mnonce=$MERV_LOCK_NONCE; nw_mdis=owned
nw_m_exact || nw_refuse maintenance-changed
merv_full_fence_claim "$nw_f" || nw_refuse fence-exists
nw_fstart=$MERV_FULL_FENCE_START; nw_fnonce=$MERV_FULL_FENCE_NONCE; nw_fdis=owned
# Monotonic uptime deadline. Fixed finite 30 seconds; one-second polls.
nw_begin=$(awk '{print int($1)}' /proc/uptime) || nw_refuse clock-unobservable
case "$nw_begin" in ''|*[!0-9]*) nw_refuse clock-unobservable ;; esac
while :; do
    nw_q=$(merv_maintenance_quiesce_classify "$$" "$nw_mstart" "$nw_mnonce" "$$" "$nw_fstart" "$nw_fnonce")
    nw_now=$(awk '{print int($1)}' /proc/uptime) || nw_refuse clock-unobservable
    case "$nw_now" in ''|*[!0-9]*) nw_refuse clock-unobservable ;; esac
    [ "$nw_now" -ge "$nw_begin" ] && [ "$((nw_now - nw_begin))" -lt 30 ] || nw_refuse quiescence-timeout
    [ "$nw_q" != IDLE ] || break
    sleep 1
done
nw_m_exact && nw_f_exact || nw_refuse ownership-changed
# Defense in depth: all frozen code, especially cleaner, checked after drain.
nw_artifacts || nw_refuse artifact-drift
nw_m_exact && nw_f_exact || nw_refuse ownership-changed
nw_cleaner_run="$nw_run.$nw_slot"
nw_cleaner_dir="/tmp/.mervlan-full-cleanup.$nw_cleaner_run"
[ ! -e "$nw_cleaner_dir" ] && [ ! -L "$nw_cleaner_dir" ] && mkdir "$nw_cleaner_dir" && nw_private "$nw_cleaner_dir" drwx------ || nw_refuse cleaner-context-exists
printf 'fence=%s\npid=%s\nstart=%s\nnonce=%s\nrun=%s\nmode=coordinated\nkeep=%s\nno_reboot=1\n' \
    "$nw_f" "$$" "$nw_fstart" "$nw_fnonce" "$nw_cleaner_run" "$nw_keep" > "$nw_cleaner_dir/context.tmp" &&
    mv "$nw_cleaner_dir/context.tmp" "$nw_cleaner_dir/context" || nw_refuse cleaner-context-write
nw_entered=yes
case "$nw_policy" in KEEP) set -- --keep-backups ;; DELETE) set -- --yes --delete-backups ;; esac
/bin/sh "$nw_root/cleaner.sh" --mervlan-cleanup-borrowed "$nw_cleaner_dir/context" "$nw_cleaner_run" "$@" --no-reboot < /dev/null > "$nw_root/cleaner.stdout" 2> "$nw_root/cleaner.stderr" &
nw_child=$!
nw_child_start=$(merv_identity_proc_start "$nw_child" /proc) || nw_child_start=none
merv_owner_v2_positive_uint "$nw_child_start" || nw_child_start=none
# Direct child, synchronously waited. No replay or detached orchestration.
wait "$nw_child"; nw_cleanup_rc=$?
trap '' HUP INT TERM
nw_class=UNVERIFIED; nw_rc=4; nw_reason=cleaner-terminal-unverified
if nw_private "$nw_cleaner_dir/claim" drwx------ && nw_private "$nw_cleaner_dir/claim/consumer" -rw------- && nw_private "$nw_cleaner_dir/terminal" -rw-------; then
    nw_claim=$(printf 'protocol=phase6-v1\nrun=%s\npid=%s\nstart=%s\nowner_pid=%s\nowner_start=%s\nowner_nonce=%s\nkeep=%s\nno_reboot=1\n' "$nw_cleaner_run" "$nw_child" "$nw_child_start" "$$" "$nw_fstart" "$nw_fnonce" "$nw_keep")
    nw_terminal="$nw_cleaner_run:$nw_child:$nw_cleanup_rc"
    if merv_owner_v2_positive_uint "$nw_child_start" && [ "$(cat "$nw_cleaner_dir/claim/consumer")" = "$nw_claim" ] &&
       [ "$(wc -c < "$nw_cleaner_dir/claim/consumer")" = "$(printf '%s\n' "$nw_claim" | wc -c)" ] &&
       [ "$(cat "$nw_cleaner_dir/terminal")" = "$nw_terminal" ] &&
       [ "$(wc -c < "$nw_cleaner_dir/terminal")" = "$(printf '%s\n' "$nw_terminal" | wc -c)" ] && nw_f_exact; then
        if [ "$nw_cleanup_rc" = 0 ]; then nw_class=SUCCESS; nw_rc=0; nw_reason=cleaned
        else nw_class=FAILED_TERMINAL; nw_rc=3; nw_reason=cleaner-failed; fi
    fi
fi
nw_finish
FULL_NODE_ENTRY
MERVLAN_FULL_NODE_PROGRAM
}

# Literal MAIN program; no runtime data is interpolated.
full_emit_main_program() {
    cat <<'MERVLAN_FULL_MAIN_PROGRAM'
#!/bin/sh
# Full MAIN protocol: phase9-main-v1
# Relocated terminal wrapper. Exit 0 complete, 2 refused, 3 terminal failure,
# 4 unverified. Never contacts NODEs or sources installed addon code.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$#" = 4 ] && [ "$1" = --run ] || exit 2
exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C \
    MERVLAN_SELFTEST_CONTEXT="${MERVLAN_SELFTEST_CONTEXT:-}" \
    /bin/sh -s -- "$0" "$2" "$3" "$4" <<'FULL_MAIN_ENTRY'
set -f
umask 077
mw_script=$1; mw_root=$2; mw_ready_hash=$3; mw_handoff_hash=$4
mw_uid=$(id -u) || exit 2
mw_private() {
    [ ! -L "$1" ] && [ "$(ls -ldn "$1" 2>/dev/null | awk '{print $1 " " $3}')" = "$2 $mw_uid" ]
}
mw_hash() {
    mw_h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    if [ "${#mw_h}" != 64 ]; then mw_h=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'); fi
    [ "${#mw_h}" = 64 ] || return 1
    case "$mw_h" in *[!0-9a-f]*) return 1 ;; esac
    printf '%s\n' "$mw_h"
}
# The persistent decision never claims Full completion. SUCCESS_F_HELD is
# terminal cleaner evidence only. The final stdout receipt + process exit are
# the completion stage; there is deliberately no post-release filesystem write.
mw_equal() {
    mw_private "$1" -rw------- && [ "$(cat "$1")" = "$2" ] &&
    [ "$(wc -c < "$1")" = "$(printf '%s\n' "$2" | wc -c)" ]
}
mw_stamp() {
    for mw_leaf in "$@"; do
        mw_private "$mw_root/$mw_leaf" -rw------- || return 1
        mw_digest=$(mw_hash "$mw_root/$mw_leaf") || return 1
        printf '%s %s\n' "$mw_digest" "$mw_leaf"
    done
}
mw_artifacts() {
    mw_private "$mw_root/main" drwx------ || return 1
    mw_names='cleaner.sh stage.sh node.sh lib_selftest_context.sh lib_identity.sh lib_owner_lock.sh lib_action_lock.sh lib_full_fence.sh lib_update_state.sh lib_continuation.sh lib_radio.sh lib_mervqt.sh lib_settings_reconcile.sh lib_maintenance_quiesce.sh'
    mw_private "$mw_root/artifacts.manifest" -rw------- &&
    [ "$(mw_hash "$mw_root/artifacts.manifest")" = "$mw_generation" ] || return 1
    awk -v names="$mw_names" 'BEGIN {n=split(names,a," ");for(i=1;i<=n;i++)ok["main/" a[i]]=1}
        NF!=2 || length($1)!=64 || $1 ~ /[^0-9a-f]/ || !ok[$2] || seen[$2]++ {bad=1}
        END {exit (bad || NR!=n)}' "$mw_root/artifacts.manifest" || return 1
    while IFS=' ' read -r mw_digest mw_leaf; do
        mw_file="$mw_root/$mw_leaf"
        mw_private "$mw_file" -rw------- && [ -s "$mw_file" ] &&
        [ "$(mw_hash "$mw_file")" = "$mw_digest" ] && /bin/sh -n "$mw_file" || return 1
    done < "$mw_root/artifacts.manifest"
    [ "$(mw_hash "$mw_root/terminal.manifest")" = "$mw_terminal_generation" ] &&
    mw_equal "$mw_root/terminal.manifest" "$(mw_stamp main/terminal.sh)" &&
    /bin/sh -n "$mw_script" &&
    grep -Fx '# Full MAIN protocol: phase9-main-v1' "$mw_script" >/dev/null &&
    grep -Fx '# Cleaner protocol: phase6-v1' "$mw_root/main/cleaner.sh" >/dev/null
}
# Evidence directory is data-only and belongs to exactly the frozen slots.
# Reject unknown slots/objects even when they are omitted from the handoff.
mw_evidence_membership() (
    set +f
    for mw_path in "$mw_root/phase8.claim"/* "$mw_root/phase8.claim"/.[!.]* "$mw_root/phase8.claim"/..?*; do
        [ -e "$mw_path" ] || [ -L "$mw_path" ] || continue
        mw_leaf=${mw_path##*/}
        case "$mw_leaf" in
            NODE[1-9].result|NODE10.result|NODE[1-9].state|NODE10.state|NODE[1-9].context|NODE10.context|NODE[1-9].stderr|NODE10.stderr) ;;
            *) return 1 ;;
        esac
        mw_private "$mw_path" -rw------- &&
        awk -v s="${mw_leaf%%.*}" '$1==s {found=1} END {exit !found}' "$mw_root/topology.map" || return 1
    done
)
mw_gate() {
    case "$mw_root" in /tmp/.mervlan-full.*|/tmp/mervlan-*/.mervlan-full.*) ;; *) return 1 ;; esac
    case "$mw_root" in *..*|*//*|*[!A-Za-z0-9_./-]*|*/) return 1 ;; esac
    # Check every parent; no symlink authority or result destination.
    mw_path=/; mw_rest=${mw_root#/}
    while [ -n "$mw_rest" ]; do
        case "$mw_rest" in */*) mw_part=${mw_rest%%/*}; mw_rest=${mw_rest#*/} ;; *) mw_part=$mw_rest; mw_rest= ;; esac
        mw_path=$mw_path$mw_part
        [ -d "$mw_path" ] && [ ! -L "$mw_path" ] || return 1
        mw_path=$mw_path/
    done
    mw_private "$mw_root" drwx------ && [ "$mw_script" = "$mw_root/main/terminal.sh" ] || return 1
    for mw_digest in "$mw_ready_hash" "$mw_handoff_hash"; do
        [ "${#mw_digest}" = 64 ] || return 1
        case "$mw_digest" in *[!0-9a-f]*) return 1 ;; esac
    done
    mw_private "$mw_root/ready" -rw------- && [ "$(mw_hash "$mw_root/ready")" = "$mw_ready_hash" ] &&
    mw_private "$mw_root/node-phase-complete" -rw------- && [ "$(mw_hash "$mw_root/node-phase-complete")" = "$mw_handoff_hash" ] || return 1
    mw_run=$(awk -F= '$1=="run" {print $2}' "$mw_root/ready")
    [ "${#mw_run}" -le 100 ] && printf '%s\n' "$mw_run" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    mw_policy=$(awk -F= '$1=="backup_policy" {print $2}' "$mw_root/ready")
    case "$mw_policy" in KEEP) mw_keep=1 ;; DELETE) mw_keep=0 ;; *) return 1 ;; esac
    mw_count=$(awk '$1=="COUNT" {print $2}' "$mw_root/topology.map")
    case "$mw_count" in 0|1|2|3|4|5|6|7|8|9|10) ;; *) return 1 ;; esac
    mw_generation=$(mw_hash "$mw_root/artifacts.manifest") &&
    mw_terminal_generation=$(mw_hash "$mw_root/terminal.manifest") || return 1
    mw_expected=$(printf 'format=phase7-v3\nrun=%s\nstate=READY_FOR_NODE_CLEANUP\nnode_count=%s\nbackup_policy=%s\nnode_reboot=no\nsupport=full-terminal-v1\n' "$mw_run" "$mw_count" "$mw_policy"
        mw_stamp settings.snapshot.json topology.map ssh.freeze endpoint.map trust.identity.map artifacts.manifest terminal.manifest authority.manifest
        printf 'config_manifest_sha256=%s\nmaps_manifest_sha256=%s\n' "$(mw_hash "$mw_root/config.manifest")" "$(mw_hash "$mw_root/maps.manifest")") || return 1
    mw_equal "$mw_root/ready" "$mw_expected" && mw_artifacts || return 1
    # Only authenticated, hash-bound fixture code may select a test root.
    . "$mw_root/main/lib_selftest_context.sh" || return 1
    mw_expected_root="/tmp/.mervlan-full.$mw_run"
    if merv_selftest_context_valid; then mw_expected_root="$MERV_SELFTEST_CONTEXT_ROOT/.mervlan-full.$mw_run"; fi
    [ "$mw_root" = "$mw_expected_root" ] || return 1
    # Frozen topology and identity rows only; no SSH/trust/settings reread.
    awk -v c="$mw_count" '
        NR==1 {if(NF!=3 || $1!="SSH")bad=1;next}
        NR==2 {if(NF!=2 || $1!="MAIN")bad=1;next}
        NR==3 {if(NF!=2 || $1!="COUNT" || $2!=c)bad=1;next}
        {i=substr($1,5)+0;if(NF!=7 || $1!="NODE" i || i<1 || i>10 || i<=last)bad=1;last=i}
        END {exit(bad || NR!=c+3)}' "$mw_root/topology.map" || return 1
    mw_private "$mw_root/phase8.claim" drwx------ && mw_evidence_membership || return 1
    mw_rows=; mw_last=none
    FULL_ROOT=$mw_root; FULL_UID=$mw_uid; FULL_RUN=$mw_run; FULL_POLICY=$mw_policy
    FULL_ARTIFACTS_HASH=$mw_generation; FULL_READY_HASH=$mw_ready_hash
    for mw_num in 1 2 3 4 5 6 7 8 9 10; do
        FULL_SLOT=NODE$mw_num
        if ! awk -v s="$FULL_SLOT" '$1==s {found=1} END {exit !found}' "$mw_root/topology.map"; then
            for mw_leaf in result state; do
                [ ! -e "$mw_root/phase8.claim/$FULL_SLOT.$mw_leaf" ] && [ ! -L "$mw_root/phase8.claim/$FULL_SLOT.$mw_leaf" ] || return 1
            done
            continue
        fi
        FULL_NODE_ID=$(awk -v s="$FULL_SLOT" '$1==s {n++;if(NF!=8)bad=1;v=$4} END {if(n!=1 || bad)exit 1;print v}' "$mw_root/trust.identity.map") || return 1
        mw_result="$mw_root/phase8.claim/$FULL_SLOT.result"
        full_nodes_result "$mw_result" 0 && [ "$FULL_NODE_CLASS" = SUCCESS ] || return 1
        mw_row="$FULL_SLOT SUCCESS $(mw_hash "$mw_result")"
        mw_equal "$mw_root/phase8.claim/$FULL_SLOT.state" "$mw_row" || return 1
        mw_rows="${mw_rows}${mw_rows:+
}$mw_row"
        mw_last=$FULL_SLOT
    done
    mw_expected=$(printf 'protocol=phase8-journal-v1\nrun=%s\nstate=PHASE8_NODE_CLEANUP\ncurrent_slot=%s\nready_sha256=%s\ngeneration=%s\n' "$mw_run" "$mw_last" "$mw_ready_hash" "$mw_generation"
        [ -z "$mw_rows" ] || printf '%s\n' "$mw_rows")
    mw_equal "$mw_root/journal" "$mw_expected" || return 1
    mw_expected=$(printf 'protocol=phase8-handoff-v2\nrun=%s\nstate=NODE_PHASE_COMPLETE\nnode_count=%s\nbackup_policy=%s\nreboot=no\nready_sha256=%s\ngeneration=%s\ntopology_sha256=%s\njournal_sha256=%s\nsupport=full-terminal-v1\nterminal_manifest_sha256=%s\n' \
        "$mw_run" "$mw_count" "$mw_policy" "$mw_ready_hash" "$mw_generation" "$(mw_hash "$mw_root/topology.map")" "$(mw_hash "$mw_root/journal")" "$mw_terminal_generation"
        [ -z "$mw_rows" ] || printf '%s\n' "$mw_rows")
    mw_equal "$mw_root/node-phase-complete" "$mw_expected"
}
# Pure strict receipt parser. No coordinator, transport or discovery code.
full_private() { mw_private "$@"; }
full_nodes_result() {
    full_private "$1" -rw------- || return 1
    fnv_values=$(awk -F= '
        BEGIN {n=split("protocol run slot identity wrapper_pid wrapper_start cleaner_run cleaner_pid cleaner_start cleanup_rc rc class reason fence maintenance backup_policy reboot generation ready_sha256",a," ");for(i=1;i<=n;i++)ok[a[i]]=1}
        NF!=2 || !ok[$1] || seen[$1]++ || $2=="" || $2 ~ /[^A-Za-z0-9_.:@-]/ {bad=1}
        {v[$1]=$2}
        END {if(bad || NR!=n)exit 1;for(i=1;i<=n;i++)printf "%s%s",v[a[i]],(i==n?"\n":" ")}' "$1") || return 1
    read -r fnv_protocol fnv_run fnv_slot fnv_identity fnv_pid fnv_start fnv_cleaner fnv_child fnv_child_start fnv_cleanup fnv_rc FULL_NODE_CLASS fnv_reason fnv_fence fnv_m fnv_backup fnv_reboot fnv_generation fnv_ready <<EOF
$fnv_values
EOF
    [ "$fnv_protocol" = phase8-result-v1 ] && [ "$fnv_run" = "$FULL_RUN" ] && [ "$fnv_slot" = "$FULL_SLOT" ] &&
    [ "$fnv_identity" = "$FULL_NODE_ID" ] && [ "$fnv_generation" = "$FULL_ARTIFACTS_HASH" ] && [ "$fnv_ready" = "$FULL_READY_HASH" ] &&
    [ "$fnv_backup:$fnv_reboot" = "$FULL_POLICY:no" ] && [ "$fnv_rc" = "$2" ] || return 1
    for fnv_uint in "$fnv_pid" "$fnv_start"; do
        case "$fnv_uint" in ''|0|*[!0-9]*) return 1 ;; esac
        [ "${#fnv_uint}" -le 20 ] || return 1
    done
    case "$FULL_NODE_CLASS:$fnv_rc:$fnv_fence" in
        SUCCESS:0:released|FAILED_TERMINAL:3:released)
            [ "$fnv_cleaner" = "$FULL_RUN.$FULL_SLOT" ] || return 1
            for fnv_uint in "$fnv_child" "$fnv_child_start"; do case "$fnv_uint" in ''|0|*[!0-9]*) return 1 ;; esac; done
            case "$fnv_cleanup" in 0|2|3|4|130|143) ;; *) return 1 ;; esac
            if [ "$FULL_NODE_CLASS" = SUCCESS ]; then [ "$fnv_cleanup" = 0 ] || return 1
            else [ "$fnv_cleanup" != 0 ] || return 1; fi
            case "$fnv_m" in released|removed-with-runtime) ;; *) return 1 ;; esac ;;
        REFUSED:2:released|REFUSED:2:not-owned)
            [ "$fnv_child:$fnv_child_start:$fnv_cleanup" = none:none:none ] || return 1 ;;
        UNVERIFIED:4:retained|UNVERIFIED:4:not-owned) ;;
        *) return 1 ;;
    esac
}
mw_record() {
    printf 'protocol=%s\nrun=%s\nhandoff_sha256=%s\nwrapper_pid=%s\nwrapper_start=%s\ncleaner_run=%s\ncleaner_pid=%s\ncleaner_start=%s\ncleaner_terminal_sha256=%s\ncleanup_rc=%s\nrc=%s\nclass=%s\nreason=%s\nfence=%s\nmaintenance=%s\nbackup_policy=%s\nreboot_required=yes\ngeneration=%s\nterminal_generation=%s\nstate=%s\n' \
        "$mw_protocol" "$mw_run" "$mw_handoff_hash" "$$" "$mw_start" "$mw_cleaner_run" "$mw_child" "$mw_child_start" "$mw_terminal_hash" "$mw_cleanup_rc" "$mw_rc" "$mw_class" "$mw_reason" "$mw_fdis" "$mw_mdis" "$mw_policy" "$mw_generation" "$mw_terminal_generation" "$mw_state"
}
mw_publish() {
    mw_private "$mw_root/phase9.claim" drwx------ &&
    [ ! -e "$mw_root/phase9.claim/decision" ] && [ ! -L "$mw_root/phase9.claim/decision" ] &&
    (set -C
        mw_protocol=phase9-decision-v1
        [ "$mw_class" != SUCCESS ] || mw_class=CLEANER_SUCCESS
        mw_rc=pending
        mw_record > "$mw_root/phase9.claim/decision.tmp") &&
    chmod 600 "$mw_root/phase9.claim/decision.tmp" &&
    mw_private "$mw_root/phase9.claim/decision.tmp" -rw------- &&
    mw_decision_hash=$(mw_hash "$mw_root/phase9.claim/decision.tmp") &&
    mv "$mw_root/phase9.claim/decision.tmp" "$mw_root/phase9.claim/decision" &&
    mw_private "$mw_root/phase9.claim/decision" -rw------- &&
    [ "$(mw_hash "$mw_root/phase9.claim/decision")" = "$mw_decision_hash" ]
}
mw_m_exact() { merv_owner_lock_path_chain_safe "$mw_m" && mw_private "$mw_m" drwx------ && merv_owner_v2_matches "$mw_m/owner" "$$" "$mw_mstart" "$mw_mnonce" /proc; }
mw_f_exact() { merv_full_fence_owner_is "$mw_f" "$$" "$mw_fstart" "$mw_fnonce"; }
mw_finish() {
    if [ "$mw_mdis" = owned ]; then
        if [ "$mw_entered" = yes ] && [ ! -e /tmp/mervlan_tmp ] && [ ! -L /tmp/mervlan_tmp ] && [ -d /tmp ]; then
            mw_mdis=removed-with-runtime
        elif mw_m_exact && merv_owner_lock_release "$mw_m" "$mw_mnonce"; then mw_mdis=released
        else mw_class=UNVERIFIED; mw_rc=4; mw_reason=maintenance-changed; mw_mdis=unverified; fi
    fi
    case "$mw_class" in
        SUCCESS) mw_state=MAIN_CLEANER_TERMINAL_SUCCESS_F_HELD ;;
        FAILED_TERMINAL) mw_state=MAIN_CLEANER_FAILED_TERMINAL ;;
        REFUSED) mw_state=MAIN_REFUSED ;;
        *) mw_state=MAIN_UNVERIFIED_F_HELD; mw_fdis=retained ;;
    esac
    # Fix all terminal obligations before the last authority is released.
    # Publication failure retains F and returns 4; no success receipt exists.
    if ! mw_publish; then
        # A known refusal before cleaner entry has no destructive terminal
        # obligation. Publication failure must not strand our exact fence when
        # M was safely retired. Foreign/ambiguous ownership still stays closed.
        if [ "$mw_entered:$mw_class" = no:REFUSED ]; then
            mw_state=MAIN_REFUSED_EVIDENCE_UNPUBLISHED
            if [ "$mw_fdis" = owned ]; then
                # Known no-entry refusal: commit safe fence disposition before release.
                trap '' HUP INT TERM PIPE
                if mw_f_exact && merv_full_fence_release "$mw_f" "$$" "$mw_fstart" "$mw_fnonce"; then mw_fdis=released
                else mw_class=UNVERIFIED; mw_rc=4; mw_reason=fence-release-unverified; mw_fdis=retained; mw_state=MAIN_UNVERIFIED_F_HELD; fi
            fi
            trap '' HUP INT TERM PIPE
            mw_record
            printf 'NODE phase complete; MAIN %s before cleaner entry. Terminal evidence publication failed; Full incomplete.\n' "$mw_class" >&2
            exit "$mw_rc"
        fi
        printf 'MAIN UNVERIFIED: terminal publication failed; Full incomplete.\n' >&2
        exit 4
    fi
    # Finalization commit follows verified decision and definitive disposition.
    # Catchable signals cannot split exact release from its final receipt/exit.
    # UNVERIFIED remains fail-closed and never enters fence release.
    case "$mw_class:$mw_fdis" in
        SUCCESS:owned|FAILED_TERMINAL:owned|REFUSED:owned) trap '' HUP INT TERM PIPE ;;
    esac
    if [ "$mw_fdis" = owned ]; then
        if mw_f_exact && merv_full_fence_release "$mw_f" "$$" "$mw_fstart" "$mw_fnonce"; then mw_fdis=released
        else mw_class=UNVERIFIED; mw_rc=4; mw_reason=fence-release-unverified; mw_state=MAIN_UNVERIFIED_F_HELD; mw_fdis=retained; fi
    fi
    if [ "$mw_class" = SUCCESS ] && [ "$mw_fdis" = released ]; then
        mw_state=FULL_UNINSTALL_COMPLETE
        # Only shell builtins remain. Reporting errors cannot change the fixed
        # transaction outcome/exit or recreate F. No completion file is written.
        mw_record
        printf 'Full uninstall complete. Reboot before reinstalling MerVLAN.\n'
        exit 0
    fi
    mw_record
    printf 'NODE phase complete; MAIN %s (%s); Full uninstall incomplete.\n' "$mw_class" "$mw_reason" >&2
    [ "$mw_class" != UNVERIFIED ] || printf 'MAIN cleanup may have occurred. Fence/evidence retained; automated replay is unsafe.\n' >&2
    exit "$mw_rc"
}
mw_refuse() { mw_class=REFUSED; mw_rc=2; mw_reason=$1; mw_finish; }
mw_gate || { printf 'MAIN REFUSED: invalid handoff/artifacts; MAIN untouched; Full incomplete.\n' >&2; exit 2; }
mw_start=$(awk '{sub(/^.*\) /,"");print $20}' "/proc/$$/stat") || exit 2
case "$mw_start" in ''|*[!0-9]*) exit 2 ;; esac
# Permanent one-shot wrapper claim; evidence is never an auto-resume command.
mkdir "$mw_root/phase9.claim" 2>/dev/null && mw_private "$mw_root/phase9.claim" drwx------ || exit 4
(set -C; printf '%s:%s:%s\n' "$mw_run" "$$" "$mw_start" > "$mw_root/phase9.claim/owner.tmp") &&
chmod 600 "$mw_root/phase9.claim/owner.tmp" &&
mw_private "$mw_root/phase9.claim/owner.tmp" -rw------- &&
mv "$mw_root/phase9.claim/owner.tmp" "$mw_root/phase9.claim/owner" &&
mw_equal "$mw_root/phase9.claim/owner" "$mw_run:$$:$mw_start" || exit 4
mw_protocol=phase9-result-v1
mw_class=REFUSED; mw_rc=2; mw_reason=artifact-mismatch; mw_fdis=not-owned; mw_mdis=not-owned
mw_cleaner_run=none; mw_child=none; mw_child_start=none; mw_cleanup_rc=none; mw_terminal_hash=none; mw_entered=no
# No installed libraries/settings: preload exact dependencies, then keep all
# state authority canonical. Loaded markers suppress transitive live sources.
# Q inventories canonical state with bounded globs; do not disable them.
set +f
MERV_BASE=/jffs/addons/mervlan
VAR_SETTINGS_LOADED=1
TMPDIR=/tmp/mervlan_tmp; LOCKDIR=/tmp/mervlan_tmp/locks
for mw_lib in selftest_context identity owner_lock action_lock full_fence update_state continuation radio mervqt settings_reconcile maintenance_quiesce; do
    . "$mw_root/main/lib_$mw_lib.sh" || mw_refuse support-load
 done
for mw_interface in merv_identity_nonce_next merv_identity_proc_start merv_owner_lock_acquire merv_owner_lock_release merv_full_fence_claim merv_full_fence_release merv_maintenance_quiesce_classify merv_settings_reconcile_read merv_dhcp_hold_rules_absent; do
    type "$mw_interface" >/dev/null 2>&1 || mw_refuse support-interface
 done
mw_m=$(merv_update_maintenance_lock_path) || mw_refuse maintenance-path
mw_f=$(merv_full_fence_path) || mw_refuse fence-path
# No catchable signal releases ownership. Abrupt death retains the fence.
trap 'exit 4' HUP INT TERM
merv_owner_lock_acquire "$mw_m" 0 0 full-main || mw_refuse maintenance-busy
mw_mstart=$MERV_LOCK_START; mw_mnonce=$MERV_LOCK_NONCE; mw_mdis=owned
mw_m_exact || mw_refuse maintenance-changed
[ "$(merv_full_fence_classify "$mw_f")" = absent ] || mw_refuse fence-exists
if ! merv_full_fence_claim "$mw_f"; then
    mw_class=UNVERIFIED; mw_rc=4; mw_reason=fence-claim-unverified; mw_fdis=retained
    mw_finish
fi
mw_fstart=$MERV_FULL_FENCE_START; mw_fnonce=$MERV_FULL_FENCE_NONCE; mw_fdis=owned
# Monotonic uptime deadline. Fixed finite 30 seconds; one-second polls.
mw_begin=$(awk '{print int($1)}' /proc/uptime) || mw_refuse clock-unobservable
case "$mw_begin" in ''|*[!0-9]*) mw_refuse clock-unobservable ;; esac
while :; do
    mw_q=$(merv_maintenance_quiesce_classify "$$" "$mw_mstart" "$mw_mnonce" "$$" "$mw_fstart" "$mw_fnonce")
    mw_now=$(awk '{print int($1)}' /proc/uptime) || mw_refuse clock-unobservable
    case "$mw_now" in ''|*[!0-9]*) mw_refuse clock-unobservable ;; esac
    [ "$mw_now" -ge "$mw_begin" ] && [ "$((mw_now - mw_begin))" -lt 30 ] || mw_refuse quiescence-timeout
    [ "$mw_q" != IDLE ] || break
    sleep 1
done
mw_m_exact && mw_f_exact || mw_refuse ownership-changed
# Defense in depth: all frozen code, especially cleaner, checked after drain.
mw_artifacts || mw_refuse artifact-drift
mw_m_exact && mw_f_exact || mw_refuse ownership-changed
mw_cleaner_run="$mw_run.MAIN"
mw_cleaner_dir="/tmp/.mervlan-full-cleanup.$mw_cleaner_run"
[ ! -e "$mw_cleaner_dir" ] && [ ! -L "$mw_cleaner_dir" ] && mkdir "$mw_cleaner_dir" && mw_private "$mw_cleaner_dir" drwx------ || mw_refuse cleaner-context-exists
printf 'fence=%s\npid=%s\nstart=%s\nnonce=%s\nrun=%s\nmode=coordinated\nkeep=%s\nno_reboot=1\n' \
    "$mw_f" "$$" "$mw_fstart" "$mw_fnonce" "$mw_cleaner_run" "$mw_keep" > "$mw_cleaner_dir/context.tmp" &&
    mv "$mw_cleaner_dir/context.tmp" "$mw_cleaner_dir/context" || mw_refuse cleaner-context-write
mw_entered=yes
case "$mw_policy" in KEEP) set -- --keep-backups ;; DELETE) set -- --yes --delete-backups ;; esac
/bin/sh "$mw_root/main/cleaner.sh" --mervlan-cleanup-borrowed "$mw_cleaner_dir/context" "$mw_cleaner_run" "$@" --no-reboot < /dev/null > "$mw_root/phase9.claim/cleaner.stdout" 2> "$mw_root/phase9.claim/cleaner.stderr" &
mw_child=$!
mw_child_start=$(merv_identity_proc_start "$mw_child" /proc) || mw_child_start=none
merv_owner_v2_positive_uint "$mw_child_start" || mw_child_start=none
# Direct child, synchronously waited. No replay or detached orchestration.
wait "$mw_child"; mw_cleanup_rc=$?
trap 'exit 4' HUP INT TERM
trap '' PIPE
mw_class=UNVERIFIED; mw_rc=4; mw_reason=cleaner-terminal-unverified
if mw_private "$mw_cleaner_dir/claim" drwx------ && mw_private "$mw_cleaner_dir/claim/consumer" -rw------- && mw_private "$mw_cleaner_dir/terminal" -rw-------; then
    mw_claim=$(printf 'protocol=phase6-v1\nrun=%s\npid=%s\nstart=%s\nowner_pid=%s\nowner_start=%s\nowner_nonce=%s\nkeep=%s\nno_reboot=1\n' "$mw_cleaner_run" "$mw_child" "$mw_child_start" "$$" "$mw_fstart" "$mw_fnonce" "$mw_keep")
    mw_terminal="$mw_cleaner_run:$mw_child:$mw_cleanup_rc"
    if merv_owner_v2_positive_uint "$mw_child_start" && [ "$(cat "$mw_cleaner_dir/claim/consumer")" = "$mw_claim" ] &&
       [ "$(wc -c < "$mw_cleaner_dir/claim/consumer")" = "$(printf '%s\n' "$mw_claim" | wc -c)" ] &&
       [ "$(cat "$mw_cleaner_dir/terminal")" = "$mw_terminal" ] &&
       [ "$(wc -c < "$mw_cleaner_dir/terminal")" = "$(printf '%s\n' "$mw_terminal" | wc -c)" ] && mw_f_exact; then
        mw_terminal_hash=$(mw_hash "$mw_cleaner_dir/terminal") || mw_finish
        if [ "$mw_cleanup_rc" = 0 ]; then mw_class=SUCCESS; mw_rc=0; mw_reason=cleaned
        else mw_class=FAILED_TERMINAL; mw_rc=3; mw_reason=cleaner-failed; fi
    fi
fi
mw_finish
FULL_MAIN_ENTRY
MERVLAN_FULL_MAIN_PROGRAM
}
