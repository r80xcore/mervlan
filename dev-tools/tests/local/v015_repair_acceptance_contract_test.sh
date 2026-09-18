#!/bin/sh
# Permanent acceptance fixture for repairing an installation whose active tree
# is the real v0.53.15 tag. The tag is used as an object, not recreated from
# the current source, so old-tree drift cannot silently invalidate the test.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
REPAIR="$ROOT/functions/update_mervlan_repair.sh"
MANIFEST="$ROOT/functions/update_mervlan_repair.manifest"
V015_COMMIT=9d45c72d59d5fa2ce3cbe9b1265d4b4e33e9e3ab
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mervlan-v015-acceptance.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

git cat-file -e "$V015_COMMIT^{commit}" 2>/dev/null || fail 'v0.53.15 tag commit is unavailable'

CASE="$WORK/case"
OLD="$CASE/old"
REMOTE="$CASE/remote"
PROC="$CASE/proc"
mkdir -p "$OLD" "$REMOTE" "$PROC" "$CASE/work" "$CASE/locks" "$CASE/progress" "$CASE/backups"
git archive --format=tar "$V015_COMMIT" | tar -xf - -C "$OLD" || fail 'could not materialize exact v0.53.15 tree'

# Seed realistic protected user state on top of the immutable tag tree. These
# are files an installed .15 router can have without changing its source.
mkdir -p "$OLD/.ssh" "$OLD/tmp" "$OLD/flags" "$OLD/www/settings"
printf '%s\n' '{"General":{"KEEP":"v015"},"SSH":{"SSH_USER":"admin"},"Nodes":{},"SSH_USER":"admin","SSH_PORT":"22"}' >"$OLD/settings/settings.json"
printf 'v015-private-key\n' >"$OLD/.ssh/vlan_manager"
printf 'ssh-rsa v015-public\n' >"$OLD/.ssh/vlan_manager.pub"
printf 'v015-mac-db\n' >"$OLD/tmp/mac_shield.db"
printf 'v015-install-ok\n' >"$OLD/flags/.install_ok"
printf '{"v015":true}\n' >"$OLD/www/settings/hardware_profiles.json"
chmod 600 "$OLD/.ssh/vlan_manager" "$OLD/settings/settings.json"
chmod 644 "$OLD/.ssh/vlan_manager.pub" "$OLD/tmp/mac_shield.db" "$OLD/flags/.install_ok" "$OLD/www/settings/hardware_profiles.json"
printf 'v015-backup-preserved\n' >"$CASE/backups/v0.53.15.tar.gz"

# A detached full/tarball installer must validate its complete support cohort
# in the private staging workspace before it can touch the exact old active
# tree. Exercise the production helper against the current package while the
# active tree is still the unmodified v0.53.15 fixture.
extract_function() {
    awk -v name="$2" '
        $0 ~ "^" name "\\(\\) \\{" { emit=1 }
        emit {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth+=opens-closes
            if (depth == 0) exit
        }
    ' "$1" >"$3"
    [ -s "$3" ]
}
STAGED="$CASE/staging/install.1234/mervlan-current"
mkdir -p "$STAGED"
cp -a "$ROOT"/. "$STAGED"/ || fail 'private installer support staging failed'
INSTALL_HELPERS="$CASE/install-helpers.sh"
: >"$INSTALL_HELPERS"
for helper in settings_file_looks_valid install_staged_support_root_valid install_tree_valid install_support_cohort_valid; do
    extract_function "$ROOT/install.sh" "$helper" "$CASE/$helper.sh" || fail "installer helper extraction failed: $helper"
    cat "$CASE/$helper.sh" >>"$INSTALL_HELPERS"
done
before_old_installer=$(cksum "$OLD/install.sh")
if TMP_DIR="$CASE/staging" STAGED="$STAGED" sh -c '. "$1"; install_support_cohort_valid "$STAGED"' sh "$INSTALL_HELPERS"; then
    :
else
    fail 'private detached installer support cohort was rejected'
fi
[ "$(cksum "$OLD/install.sh")" = "$before_old_installer" ] || fail 'staging validation touched exact v0.53.15 installer'
pass 'exact v0.53.15 installer stages support cohort before active-tree admission'

# Exercise the actual staged-child handoff, not just cohort inspection. The
# child adopts only a private marker whose root/work/archive, argv mode,
# branch/policy/SSH choices and archive fingerprint all agree; setting the
# handoff environment alone is insufficient.
HANDOFF_HELPERS="$CASE/install-handoff-helpers.sh"
: >"$HANDOFF_HELPERS"
for helper in install_staged_support_root_valid install_handoff_scalar_valid \
    install_handoff_path_chain_safe \
    install_handoff_token_valid install_handoff_archive_fingerprint \
    install_staged_handoff_record_valid install_staged_handoff_adopt \
    install_staged_handoff_write; do
    extract_function "$ROOT/install.sh" "$helper" "$CASE/$helper.sh" || fail "installer handoff helper extraction failed: $helper"
    cat "$CASE/$helper.sh" >>"$HANDOFF_HELPERS"
done
HANDOFF_WORK="$CASE/staging/install.1234"
mkdir -p "$HANDOFF_WORK"
HANDOFF_ARCHIVE="$HANDOFF_WORK/mervlan-current.tar.gz"
tar -czf "$HANDOFF_ARCHIVE" -C "$HANDOFF_WORK" "$(basename "$STAGED")" || fail 'staged handoff archive fixture failed'
DIGEST_SHIM="$CASE/digest-no-cksum"
OPENSSL_ONLY_SHIM="$CASE/digest-openssl-only"
NO_DIGEST_SHIM="$CASE/digest-none"
mkdir -p "$DIGEST_SHIM" "$OPENSSL_ONLY_SHIM" "$NO_DIGEST_SHIM"
cat >"$DIGEST_SHIM/cksum" <<'EOF'
#!/bin/sh
: >"$MERV_HANDOFF_CKSUM_CALLED"
exit 97
EOF
cat >"$OPENSSL_ONLY_SHIM/md5sum" <<'EOF'
#!/bin/sh
exit 127
EOF
for digest_tool in md5sum openssl; do
    cat >"$NO_DIGEST_SHIM/$digest_tool" <<'EOF'
#!/bin/sh
: >"$MERV_HANDOFF_NO_DIGEST_CALLED"
exit 127
EOF
done
chmod 700 "$DIGEST_SHIM/cksum" "$OPENSSL_ONLY_SHIM/md5sum" \
    "$NO_DIGEST_SHIM/md5sum" "$NO_DIGEST_SHIM/openssl"
if HANDOFF_HELPERS="$HANDOFF_HELPERS" HANDOFF_WORK="$HANDOFF_WORK" \
   HANDOFF_ARCHIVE="$HANDOFF_ARCHIVE" STAGED="$STAGED" \
   DIGEST_SHIM="$DIGEST_SHIM" OPENSSL_ONLY_SHIM="$OPENSSL_ONLY_SHIM" \
   NO_DIGEST_SHIM="$NO_DIGEST_SHIM" \
   MERV_HANDOFF_CKSUM_CALLED="$CASE/cksum-called" \
   MERV_HANDOFF_NO_DIGEST_CALLED="$CASE/no-digest-called" sh -c '
  . "$HANDOFF_HELPERS" || exit 1
  ORIGINAL_PATH=$PATH
  PATH="$DIGEST_SHIM:$ORIGINAL_PATH"
  TMP_DIR="${HANDOFF_WORK%/install.1234}"
  MODE=full; TEST_RUN=0; BRANCH=main; INSTALL_POLICY=preserve
  INSTALL_SSH_USER=admin; INSTALL_SSH_PORT=22; INSTALL_ARCHIVE_SEQ=0
  MERV_INSTALL_STAGED_ROOT="$STAGED"; MERV_INSTALL_STAGED_WORK="$HANDOFF_WORK"
  MERV_INSTALL_STAGED_ARCHIVE="$HANDOFF_ARCHIVE"; MERV_INSTALL_STAGED_READY=1
  MERV_INSTALL_SCRIPT_PATH="$STAGED/install.sh"; MERV_INSTALL_SUPPORT_HANDOFF=1
  MERV_INSTALL_HANDOFF_BRANCH=""; MERV_INSTALL_HANDOFF_POLICY=""
  MERV_INSTALL_HANDOFF_SSH_USER=""; MERV_INSTALL_HANDOFF_SSH_PORT=""
  MERV_INSTALL_HANDOFF_TOKEN=""
  install_staged_handoff_write || exit 2
  grep -Fq "archive_fingerprint=md5:" "$MERV_INSTALL_HANDOFF_FILE" || exit 3
  MERV_INSTALL_HANDOFF_ADOPTED=0
  install_staged_handoff_adopt || exit 4
  [ "$MERV_INSTALL_HANDOFF_ADOPTED" = 1 ] || exit 5
  [ ! -e "$MERV_HANDOFF_CKSUM_CALLED" ] || exit 6
  # A staged child may use OpenSSL after the parent used md5sum: both emit
  # the same labelled md5 value, while cksum remains unavailable.
  PATH="$OPENSSL_ONLY_SHIM:$DIGEST_SHIM:$ORIGINAL_PATH"
  MERV_INSTALL_HANDOFF_ADOPTED=0
  install_staged_handoff_adopt || exit 7
  [ "$MERV_INSTALL_HANDOFF_ADOPTED" = 1 ] || exit 8
  [ ! -e "$MERV_HANDOFF_CKSUM_CALLED" ] || exit 9
  # With neither supported digest implementation, authenticated adoption
  # fails closed even though the handoff marker itself remains intact.
  PATH="$NO_DIGEST_SHIM:$DIGEST_SHIM:$ORIGINAL_PATH"
  MERV_INSTALL_HANDOFF_ADOPTED=0
  if install_staged_handoff_adopt; then exit 10; fi
  [ -e "$MERV_HANDOFF_NO_DIGEST_CALLED" ] || exit 11
  [ ! -e "$MERV_HANDOFF_CKSUM_CALLED" ] || exit 12
  PATH="$DIGEST_SHIM:$ORIGINAL_PATH"
  rm -f "$MERV_INSTALL_HANDOFF_FILE" || exit 13
  MERV_INSTALL_HANDOFF_ADOPTED=0
  if install_staged_handoff_adopt; then exit 14; fi
'; then
    :
else
    fail 'staged installer handoff record was not enforced'
fi
[ "$(cksum "$OLD/install.sh")" = "$before_old_installer" ] || fail 'staged handoff touched exact v0.53.15 installer'
pass 'exact v0.53.15 staged installer handoff is authenticated before admission'

REMOTE_ROOT="$REMOTE/mervlan-main-v015-snapshot"
mkdir -p "$REMOTE_ROOT"
while IFS=' ' read -r mode path; do
    case "$mode" in format=*|cohort=*|\#*|'') continue ;; esac
    case "$path" in */*) parent=${path%/*} ;; *) parent=. ;; esac
    mkdir -p "$REMOTE_ROOT/$parent"
    cp -p "$ROOT/$path" "$REMOTE_ROOT/$path" || fail "snapshot source missing: $path"
    chmod "$mode" "$REMOTE_ROOT/$path" 2>/dev/null || fail "snapshot mode failed: $path"
done <"$MANIFEST"
ARCHIVE="$REMOTE/mervlan-main-v015-snapshot.tar.gz"
( cd "$REMOTE" && tar -czf "$ARCHIVE" "$(basename "$REMOTE_ROOT")" ) || fail 'snapshot archive creation failed'

cat >"$CASE/curl" <<'EOF'
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$out" ] || exit 2
cp "$MERV_REPAIR_FIXTURE_ARCHIVE" "$out"
EOF
chmod 755 "$CASE/curl"

before_settings=$(cksum "$OLD/settings/settings.json")
before_key=$(cksum "$OLD/.ssh/vlan_manager")
before_pubkey=$(cksum "$OLD/.ssh/vlan_manager.pub")
before_db=$(cksum "$OLD/tmp/mac_shield.db")
before_install_ok=$(cksum "$OLD/flags/.install_ok")
before_profiles=$(cksum "$OLD/www/settings/hardware_profiles.json")
before_backup=$(cksum "$CASE/backups/v0.53.15.tar.gz")

MERV_BASE="$OLD" \
MERV_REPAIR_CURL="$CASE/curl" \
MERV_REPAIR_FIXTURE_ARCHIVE="$ARCHIVE" \
MERV_REPAIR_SNAPSHOT_BASE='https://repair.test/snapshot' \
MERV_REPAIR_MAINTENANCE_LOCK="$CASE/locks/mervlan_maintenance.lock" \
MERV_REPAIR_LEGACY_LOCK_ROOT="$CASE/locks" \
MERV_REPAIR_PROC_ROOT="$PROC" \
MERV_REPAIR_TMP_ROOT="$CASE/work" \
MERV_REPAIR_PROGRESS_ROOT="$CASE/progress" \
sh "$REPAIR" main || fail 'repair rejected exact v0.53.15 installation'

[ "$(cksum "$OLD/settings/settings.json")" = "$before_settings" ] || fail 'v0.53.15 settings changed'
[ "$(cksum "$OLD/.ssh/vlan_manager")" = "$before_key" ] || fail 'v0.53.15 private SSH key changed'
[ "$(cksum "$OLD/.ssh/vlan_manager.pub")" = "$before_pubkey" ] || fail 'v0.53.15 public SSH key changed'
[ "$(cksum "$OLD/tmp/mac_shield.db")" = "$before_db" ] || fail 'v0.53.15 MAC database changed'
[ "$(cksum "$OLD/flags/.install_ok")" = "$before_install_ok" ] || fail 'v0.53.15 install marker changed'
[ "$(cksum "$OLD/www/settings/hardware_profiles.json")" = "$before_profiles" ] || fail 'v0.53.15 hardware profile changed'
[ "$(cksum "$CASE/backups/v0.53.15.tar.gz")" = "$before_backup" ] || fail 'backup outside active tree changed'

grep -Fq 'Standalone emergency repair' "$OLD/functions/update_mervlan_repair.sh" || fail 'repair engine was not published'
for required in install.sh uninstall.sh functions/update_mervlan.sh functions/update_mervlan_repair.sh \
    functions/mervlan_boot.sh functions/mervlan_wan.sh settings/lib_owner_lock.sh \
    settings/lib_update_state.sh settings/lib_maintenance_recovery.sh; do
    [ -f "$OLD/$required" ] || fail "repaired control plane missing: $required"
done
for shell_file in install.sh uninstall.sh functions/update_mervlan.sh functions/update_mervlan_repair.sh; do
    sh -n "$OLD/$shell_file" || fail "repaired shell is not parseable: $shell_file"
done
[ "$(stat -c %a "$OLD/functions/update_mervlan.sh")" = 755 ] || fail 'repaired updater mode'
[ "$(stat -c %a "$OLD/install.sh")" = 755 ] || fail 'repaired installer mode'
pass 'exact v0.53.15 protected-state repair and control-plane recovery'

# Prove the repaired updater can qualify a local archive without invoking the
# mutating Update entrypoint. This is the strongest safe local eligibility
# check available on a host: archive validation plus complete core-stage
# qualification, followed by shell syntax checks above.
HELPERS="$CASE/updater-helpers.sh"
sed -n '/^# LOCAL ARCHIVE HELPERS BEGIN$/,/^# LOCAL ARCHIVE HELPERS END$/p' \
    "$OLD/functions/update_mervlan.sh" | sed '/^# LOCAL ARCHIVE HELPERS /d' >"$HELPERS"
sed -n '/^# CORE STAGE VALIDATOR BEGIN$/,/^# CORE STAGE VALIDATOR END$/p' \
    "$OLD/functions/update_mervlan.sh" | sed '/^# CORE STAGE VALIDATOR /d' >>"$HELPERS"
sed -n '/^CORE_STAGE_FILES="/,/www\/vlan_index_style.css"/p' "$OLD/functions/update_mervlan.sh" >>"$HELPERS"
sed -n '/^CORE_STAGE_DIRS=/p' "$OLD/functions/update_mervlan.sh" >>"$HELPERS"
RUN_DIR="$CASE/updater-eligibility"
TMP_BASE="$RUN_DIR"
RAW_ARCHIVE="$RUN_DIR/raw.tar"
mkdir -p "$RUN_DIR"
info() { :; }
warn() { :; }
. "$HELPERS" || fail 'repaired updater helper extraction failed'
validate_update_archive_members "$ARCHIVE" || fail 'repaired updater rejected qualified local archive'
# The repair manifest intentionally excludes protected settings and two public
# CSS files. Add those package-owned files to the non-mutating stage fixture
# before exercising the normal updater's core-stage validator.
mkdir -p "$REMOTE_ROOT/settings" "$REMOTE_ROOT/www"
cp -p "$ROOT/settings/settings.json" "$REMOTE_ROOT/settings/settings.json"
cp -p "$ROOT/www/vlan_form_style.css" "$REMOTE_ROOT/www/vlan_form_style.css"
cp -p "$ROOT/www/vlan_index_style.css" "$REMOTE_ROOT/www/vlan_index_style.css"
update_stage_core_valid "$REMOTE_ROOT" || fail 'repaired updater rejected qualified core stage'
pass 'repaired updater local-source eligibility without mutation'

printf '%s\n' 'V015_REPAIR_ACCEPTANCE_CONTRACT_OK'
