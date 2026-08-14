#!/bin/sh
# Focused source contract for main-page Save ownership and Preset UI state.
set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"
CSS_FILE="$MERV_BASE/www/vlan_index_style.css"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
require() { grep -Fq -- "$1" "$2" || fail "$3"; }
reject() { ! grep -Fq -- "$1" "$2" || fail "$3"; }

require '--apmo-button-width:60px;' "$CSS_FILE" 'manual APMO width is not centralized'
require '--wan-native-edit-width:50px;' "$CSS_FILE" 'manual WAN Edit width is not centralized'
require '--wan-native-edit-height:22px;' "$CSS_FILE" 'manual WAN Edit height is not centralized'
require '--wan-native-edit-status-gap:45px;' "$CSS_FILE" 'manual WAN Edit gap is not centralized'
require '.form-box.controls-panel.controls-panel--preset' "$CSS_FILE" 'Preset-specific padding selector missing'
require 'padding-bottom:var(--preset-panel-bottom-padding);' "$CSS_FILE" 'Preset bottom padding is not tunable'
require '.settings-authority-status {' "$CSS_FILE" 'status row geometry is not in CSS'
require 'min-height:var(--preset-status-min-height);' "$CSS_FILE" 'status row does not reserve height'
require 'class="form-box controls-panel controls-panel--preset"' "$UI_FILE" 'Preset panel class missing'
reject 'settingsAuthorityStatus" class="settings-authority-status" role="status" aria-live="polite" style=' "$UI_FILE" 'status geometry remains inline'

require 'function extractMainPageSaveKeys(flat)' "$UI_FILE" 'main-page key extractor missing'
require 'function mainPageSaveIsDirty()' "$UI_FILE" 'main-page dirty comparator missing'
require 'function refreshMainSaveNeededState()' "$UI_FILE" 'central dirty refresh missing'
require 'Service modal, APMO, client metadata, and update state have separate' "$UI_FILE" 'main-page ownership boundary is undocumented'
require 'saveBtn.classList.toggle(' "$UI_FILE" 'Save dirty class update missing'
require 'Unsaved changes. Click Save to persist.' "$UI_FILE" 'dirty status message missing'
require 'Unsaved main-page changes. Click Save to persist.' "$UI_FILE" 'dirty Save accessibility text missing'
require "'PERSISTENT_DEBUG_LOGGING'" "$UI_FILE" 'service scope is not explicit'

require 'function buildServiceSettingsPayloadForMerlin(changes)' "$UI_FILE" 'service subset payload builder missing'
require 'function extractServiceSettingsExpected(changes)' "$UI_FILE" 'service subset verifier missing'
require "verificationScope: 'service'" "$UI_FILE" 'service save does not use scoped verification'
require 'scopedPayload: buildServiceSettingsPayloadForMerlin(stage.changes)' "$UI_FILE" 'service save still lacks scoped payload'
require 'restoreMainPageDraftToCache(mainDraft);' "$UI_FILE" 'service refresh does not restore main draft'
require 'subset: isScopedSave' "$UI_FILE" 'scoped save verification is not subset-based'

printf 'MAIN_SAVE_DIRTY_CONTRACT_OK\n'
