#!/bin/sh
# Exercise package validators without running install, Update, Sync, or repair.
set -eu
BASE=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
ROOT=$(mktemp -d /tmp/mervlan-phase6-package.XXXXXX)
trap 'rm -rf "$ROOT"' 0 1 2 3 15
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
extract() { sed -n "/^$2() {/,/^}/p" "$1"; }
extract "$BASE/install.sh" install_cleaner_valid > "$ROOT/install-validator"
. "$ROOT/install-validator"
mkdir -p "$ROOT/tree/functions"
if install_cleaner_valid "$ROOT/tree"; then fail 'missing cleaner accepted'; fi
cp -p "$BASE/functions/mervlan_full_cleanup.sh" "$ROOT/tree/functions/cleaner-original"
cleaner="$ROOT/tree/functions/mervlan_full_cleanup.sh"
cp -p "$ROOT/tree/functions/cleaner-original" "$cleaner"
install_cleaner_valid "$ROOT/tree" || fail 'installed cleaner rejected'
chmod 644 "$cleaner"
if install_cleaner_valid "$ROOT/tree"; then fail 'non-executable cleaner accepted'; fi
rm "$cleaner"
ln -s cleaner-original "$cleaner"
if install_cleaner_valid "$ROOT/tree"; then fail 'symlink cleaner accepted'; fi
rm "$cleaner"
printf '#!/bin/sh\n# Cleaner protocol: phase6-v1\nif\n' > "$cleaner"
chmod 755 "$cleaner"
if install_cleaner_valid "$ROOT/tree"; then fail 'invalid syntax cleaner accepted'; fi
printf '#!/bin/sh\nexit 0\n' > "$cleaner"
if install_cleaner_valid "$ROOT/tree"; then fail 'missing signature accepted'; fi
pass 'install cleaner regular file, executable mode, syntax, and signature gates'

extract "$BASE/functions/update_mervlan.sh" update_stage_core_valid > "$ROOT/update-validator"
. "$ROOT/update-validator"
CORE_STAGE_FILES=$(awk '/^CORE_STAGE_FILES="/ {sub(/^[^"]*"/, ""); active=1} active {if (/"$/) {sub(/"$/, "");print;exit} print}' "$BASE/functions/update_mervlan.sh")
CORE_STAGE_DIRS='functions settings templates www'
warn() { :; }
mkdir -p "$ROOT/stage"
for rel in $CORE_STAGE_FILES; do
    [ ! -L "$BASE/$rel" ] && [ -f "$BASE/$rel" ] || fail "source object unsafe: $rel"
    mkdir -p "$ROOT/stage/$(dirname "$rel")"
    cp -p "$BASE/$rel" "$ROOT/stage/$rel"
done
update_stage_core_valid "$ROOT/stage" || fail 'new Update target rejected'
for rel in functions/mervlan_full_cleanup.sh settings/lib_full_fence.sh settings/lib_maintenance_quiesce.sh settings/lib_full_uninstall.sh; do
    mv "$ROOT/stage/$rel" "$ROOT/stage/$rel.saved"
    if update_stage_core_valid "$ROOT/stage"; then fail "new Update target accepts missing $rel"; fi
    mv "$ROOT/stage/$rel.saved" "$ROOT/stage/$rel"
done
chmod 644 "$ROOT/stage/functions/mervlan_full_cleanup.sh"
if update_stage_core_valid "$ROOT/stage"; then fail 'Update accepts non-executable cleaner'; fi
chmod 755 "$ROOT/stage/functions/mervlan_full_cleanup.sh"
pass 'Update new-target cohort and cleaner validation; historical tree validator unchanged'

for name in FILES_TO_COPY FILES_TO_COPY_CHMOD; do
    awk -v name="$name" '$0 == name "=\"" {active=1; next} active && /^"/ {exit} active {print}' "$BASE/functions/sync_nodes.sh" > "$ROOT/$name"
    [ "$(grep -Fxc functions/mervlan_full_cleanup.sh "$ROOT/$name")" = 1 ] || fail "Sync $name cleaner missing/duplicate"
done
sed -n '/^FILES_TO_COPY_CHMOD_644="/,/^"/p' "$BASE/functions/sync_nodes.sh" > "$ROOT/nonexecutable"
if grep -Fq functions/mervlan_full_cleanup.sh "$ROOT/nonexecutable"; then fail 'Sync cleaner in 0644 cohort'; fi
for helper in lib_identity lib_owner_lock lib_selftest_context lib_full_fence lib_continuation lib_mutation_admission lib_maintenance_quiesce; do
    grep -Fqx "settings/$helper.sh" "$ROOT/FILES_TO_COPY" || fail "Sync helper absent: $helper"
done
pass 'full Sync transfers cleaner as executable and retains exclusion cohort'

PATHS_FILE="$ROOT/repair-paths"
for fn in safe_rel_path path_protected repair_path_allowed parse_manifest path_present path_regular mode_matches validate_stage; do
    extract "$BASE/functions/update_mervlan_repair.sh" "$fn" >> "$ROOT/repair-validator"
done
. "$ROOT/repair-validator"
parse_manifest "$BASE/functions/update_mervlan_repair.manifest" || fail 'repair manifest rejected'
STAGE_DIR="$ROOT/repair-stage"
while IFS=' ' read -r mode rel; do
    mkdir -p "$STAGE_DIR/$(dirname "$rel")"
    cp "$BASE/$rel" "$STAGE_DIR/$rel"
    chmod "$mode" "$STAGE_DIR/$rel"
done < "$PATHS_FILE"
validate_stage || fail 'repair stage rejected'
sed '/functions\/mervlan_full_cleanup.sh/d' "$BASE/functions/update_mervlan_repair.manifest" > "$ROOT/missing-manifest"
if parse_manifest "$ROOT/missing-manifest"; then fail 'repair accepts missing cleaner'; fi
sed 's/0755 functions\/mervlan_full_cleanup.sh/0644 functions\/mervlan_full_cleanup.sh/' "$BASE/functions/update_mervlan_repair.manifest" > "$ROOT/mode-manifest"
if parse_manifest "$ROOT/mode-manifest"; then fail 'repair accepts wrong cleaner mode'; fi
pass 'repair allowlist, required cleaner, executable mode, and staged signature'
printf 'CLEANER_PHASE6_PACKAGING_OK\n'
