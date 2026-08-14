#!/bin/sh
# Focused R3 source contracts for staged settings durability and draft truth.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BASE_DIR=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
SAVE_FILE="$BASE_DIR/functions/save_settings.sh"
UI_FILE="$BASE_DIR/www/index.html"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

grep -Fq 'merv_identity_nonce_next' "$SAVE_FILE" || fail 'transaction nonce generation missing'
grep -Fq '_save_candidate_dir="${SETTINGSDIR}/.settings.json.save.${MERV_IDENTITY_NONCE}"' "$SAVE_FILE" || fail 'nonce-bearing candidate namespace missing'
grep -Fq 'mkdir "${_save_candidate_dir}"' "$SAVE_FILE" || fail 'candidate namespace is not atomically claimed'
grep -Fq '_save_cleanup_candidate' "$SAVE_FILE" || fail 'candidate cleanup helper missing'
! grep -Fq '.settings.json.save.$$' "$SAVE_FILE" || fail 'candidate namespace relies on PID-only uniqueness'
grep -Fq 'json_apply_kv_file "${TMP_SORTED}" "${_save_candidate}"' "$SAVE_FILE" || fail 'flat setters do not target candidate'
grep -Fq 'seed_general_section_if_missing' "$SAVE_FILE" || fail 'missing General migration helper absent'
grep -Fq 'seed_hardware_override_if_missing' "$SAVE_FILE" || fail 'missing Hardware_Override migration helper absent'
grep -Fq 'save_candidate_is_empty_object' "$SAVE_FILE" || fail 'formatted-empty candidate handling absent'
grep -Fq 'json_get_section_value "General"' "$SAVE_FILE" || fail 'General setter verification absent'
grep -Fq 'json_get_section2_value "Hardware_Override"' "$SAVE_FILE" || fail 'Hardware_Override setter verification absent'
grep -Fq 'json_set_section2_value "Hardware_Override" "$_ovr_target" "$_ovr_json_key" "$oval" "${_save_candidate}"' "$SAVE_FILE" || fail 'Hardware Override setter is not staged'
grep -Fq 'MAIN_WAN_NATIVE_IP' "$SAVE_FILE" || fail 'MAIN WAN Native endpoint is not staged as a structured setting'
grep -Fq 'MAIN_WAN_NATIVE_IP' "$UI_FILE" || fail 'MAIN WAN Native endpoint is not serialized by the UI'
grep -Fq 'MAIN_ASUS_IP' "$SAVE_FILE" || fail 'MAIN ASUS endpoint is not staged as a structured setting'
grep -Fq 'MAIN_ASUS_IP' "$UI_FILE" || fail 'MAIN ASUS endpoint is not serialized by the UI'
grep -Fq 'out.vlanmgr_MAIN_WAN_NATIVE_IP' "$UI_FILE" || fail 'MAIN WAN Native endpoint is not submitted in normal save payload'
grep -Fq 'out.vlanmgr_MAIN_ASUS_IP' "$UI_FILE" || fail 'MAIN ASUS endpoint is not submitted in normal save payload'
grep -Fq 'wan_native)' "$SAVE_FILE" || fail 'narrow WAN Native save scope is absent'
grep -Fq 'MAIN_ASUS_IP" || $1 == "PERSISTENT_DEBUG_LOGGING"' "$SAVE_FILE" || fail 'narrow WAN Native scope is not restricted to transport keys'
grep -Fq 'PERSISTENT_DEBUG_LOGGING' "$SAVE_FILE" || fail 'persistent WAN debug setting is not staged as a structured setting'
grep -Fq 'PERSISTENT_DEBUG_LOGGING' "$UI_FILE" || fail 'persistent WAN debug setting is not serialized by the UI'
grep -Fq 'json_set_section_value "ClientMeta" "$cmkey" "$cmval" "${_save_candidate}"' "$SAVE_FILE" || fail 'ClientMeta setter is not staged'
grep -Fq 'json_validate_file "${_save_candidate}"' "$SAVE_FILE" || fail 'candidate validation missing'
grep -Fq 'mv -f "${_save_candidate}" "${SETTINGS_FILE}"' "$SAVE_FILE" || fail 'single authoritative candidate commit missing'
grep -Fq 'elif [ -L "${PUBLIC_SETTINGS_FILE}" ]; then' "$SAVE_FILE" || fail 'public symlink publication guard missing'
grep -Fq '_save_public_status="failed"' "$SAVE_FILE" || fail 'public publication failure is not represented'
grep -Fq 'public-settings-publication-failed' "$SAVE_FILE" || fail 'public publication failure acknowledgement missing'

# Normal Save draft clearing follows persistence, acknowledgement, and reload.
save_line=$(grep -n "Clearing form fields" "$UI_FILE" | tail -n 1 | cut -d: -f1)
ack_line=$(grep -n "waitForVerifiedActionResult" "$UI_FILE" | tail -n 1 | cut -d: -f1)
reload_line=$(grep -n "const reloaded = await loadSettings()" "$UI_FILE" | tail -n 1 | cut -d: -f1)
[ "$save_line" -gt "$ack_line" ] || fail 'normal Save clears draft before acknowledgement'
[ "$save_line" -gt "$reload_line" ] || fail 'normal Save clears draft before verified reload'
grep -Fq "Save reload failed" "$UI_FILE" || fail 'reload failure does not retain draft'
grep -Fq "Client metadata apply did not reach a terminal refresh; keeping the editor draft." "$UI_FILE" || fail 'ClientMeta timeout does not retain draft'

printf 'SETTINGS_SAVE_TRANSACTION_CONTRACT_OK\n'
