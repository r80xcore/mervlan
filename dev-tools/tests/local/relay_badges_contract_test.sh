#!/bin/sh
# Source contract for presentation-only relay client badges.

set -eu

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
MERV_BASE=$(CDPATH= cd -- "$TEST_DIR/../../.." && pwd)
UI_FILE="$MERV_BASE/www/index.html"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

. "$TEST_DIR/js_source_helpers.sh"

if command -v node >/dev/null 2>&1; then
  node - "$UI_FILE" <<'NODE' || fail 'relay badge behavior regression'
const fs = require('fs');
const vm = require('vm');
const file = process.argv[2];
const html = fs.readFileSync(file, 'utf8');

function extractFunction(name) {
  const declaration = new RegExp('(?:^|\\n)[\\t ]*function[\\t ]+' + name + '[\\t ]*\\(').exec(html);
  if (!declaration) throw new Error(name + ' declaration is missing');
  const start = declaration.index + declaration[0].indexOf('function');
  const open = html.indexOf('{', start);
  if (open < 0) throw new Error(name + ' body is missing');
  let depth = 0;
  let quote = null;
  let lineComment = false;
  let blockComment = false;
  for (let index = open; index < html.length; index += 1) {
    const ch = html[index];
    const next = html[index + 1];
    if (lineComment) {
      if (ch === '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (ch === '*' && next === '/') { blockComment = false; index += 1; }
      continue;
    }
    if (quote) {
      if (ch === '\\') { index += 1; continue; }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '/' && next === '/') { lineComment = true; index += 1; continue; }
    if (ch === '/' && next === '*') { blockComment = true; index += 1; continue; }
    if (ch === '"' || ch === "'" || ch === String.fromCharCode(96)) { quote = ch; continue; }
    if (ch === '{') depth += 1;
    if (ch === '}' && --depth === 0) return html.slice(start, index + 1);
  }
  throw new Error(name + ' has an unterminated body');
}

const context = vm.createContext({});
vm.runInContext(extractFunction('renderClientMetaBadges') +
  '\nglobalThis.renderClientMetaBadges = renderClientMetaBadges;', context);
const render = context.renderClientMetaBadges;
const cases = [
  ['relay_only', { location_status: 'relay_only' }, '>R/O</span>', 'Relay-only (R/O):'],
  ['diagnostic', { diagnostic: true }, '>R/O</span>', 'Relay-only (R/O):'],
  ['relayed', { location_status: 'relayed' }, '>R</span>', 'Relayed (R):'],
  ['ambiguous', { location_status: 'ambiguous' }, '>?</span>', 'Conflicting direct observations'],
  ['unknown', { location_status: 'unknown' }, '>!</span>', 'Location could not be determined']
];
for (const item of cases) {
  const output = render(item[1]);
  if (!output.includes(item[2]) || !output.includes(item[3])) {
    throw new Error(item[0] + ' badge/text mismatch');
  }
  if (item[0] === 'relayed' && output.includes('>R/O</span>')) {
    throw new Error('relayed state became relay-only');
  }
}
if (render({ location_status: 'relay_only' }).includes('>Relay-only</span>')) {
  throw new Error('legacy relay-only badge remains');
}
console.log('RELAY_BADGE_BEHAVIOR_OK cases=5');
NODE
else
  block=$(extract_js_function renderClientMetaBadges "$UI_FILE") || fail 'relay badge function extraction failed'
  printf '%s\n' "$block" | grep -Fq "c.location_status === 'relay_only' || c.diagnostic" || fail 'relay-only predicate changed'
  printf '%s\n' "$block" | grep -Fq '>R/O</span>' || fail 'relay-only badge is not R/O'
  printf '%s\n' "$block" | grep -Fq "c.location_status === 'relayed'" || fail 'relayed predicate changed'
fi

printf 'RELAY_BADGES_CONTRACT_OK\n'
