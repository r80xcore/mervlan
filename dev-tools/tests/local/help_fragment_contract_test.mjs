// Deterministic Help fragment regression: valid anchors still scroll, while a
// malformed percent-encoded hash falls back to the document top.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const source = readFileSync(path.join(root, 'www/help.html'), 'utf8');
const start = source.indexOf('function enhanceRenderedHelp(');
assert.ok(start >= 0, 'production Help enhancement function is missing');
const brace = source.indexOf('{', start);
let depth = 0;
let end = -1;
for (let index = brace; index < source.length; index += 1) {
  if (source[index] === '{') depth += 1;
  else if (source[index] === '}') {
    depth -= 1;
    if (depth === 0) { end = index + 1; break; }
  }
}
assert.ok(end > start, 'production Help enhancement function is unterminated');

let styled = 0;
let prepared = 0;
let lookedUp = [];
let scrolled = [];
const contentEl = { scrollTop: 77 };
const target = { scrollIntoView(options) { scrolled.push(options); } };
const context = vm.createContext({
  console,
  window: { location: { hash: '' } },
  contentEl,
  document: {
    getElementById(id) {
      lookedUp.push(id);
      return id === 'section one' ? target : null;
    }
  },
  styleGitHubAlerts() { styled += 1; },
  prepareLinks() { prepared += 1; }
});
vm.runInContext(source.slice(start, end), context);

context.window.location.hash = '#section%20one';
context.enhanceRenderedHelp();
assert.equal(lookedUp.at(-1), 'section one', 'valid Help hash is decoded for lookup');
assert.equal(scrolled.at(-1)?.block, 'start', 'valid Help hash scrolls to its section');
assert.equal(styled, 1, 'valid Help enhancement styles alerts');
assert.equal(prepared, 1, 'valid Help enhancement prepares links');

contentEl.scrollTop = 77;
context.window.location.hash = '#%E0%A4%A';
assert.doesNotThrow(() => context.enhanceRenderedHelp(), 'malformed Help hash is safely handled');
assert.equal(contentEl.scrollTop, 0, 'malformed Help hash falls back to document top');
assert.equal(scrolled.length, 1, 'malformed Help hash does not scroll a stale target');
assert.equal(styled, 2, 'malformed Help enhancement remains deterministic');
assert.equal(prepared, 2, 'malformed Help enhancement still prepares links');

console.log('HELP_FRAGMENT_CONTRACT_OK');
