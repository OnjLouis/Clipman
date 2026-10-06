const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const context = { URL };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/links.js'), 'utf8'), context);
const target = (text, extra = {}) => context.ClipmanLinks.target({text, ...extra});

test('complete HTTP links retain their original destination', () => {
  const url = 'https://example.com/file%20name?q=1&other=2#section';
  assert.equal(target(url), url);
  assert.equal(target('  ' + url + '  '), url);
  assert.equal(target(url + '  link'), url);
  assert.equal(target('HTTP://example.com/path  LINK'), 'HTTP://example.com/path');
});
test('non-links, active schemes, formatted entries and previews cannot be opened', () => {
  for (const value of ['javascript:alert(1)', 'data:text/html,test', '//example.com',
    'clipman://example.com', 'file:///tmp/test', 'https://', 'A note https://example.com',
    'https://example.com\nAnother line', 'https://example.com/with space',
    'https://example.com/\u0000test', 'https:\\example.com']) {
    assert.equal(target(value), null, value);
  }
  assert.equal(target('https://example.com', {truncated:true}), null);
  assert.equal(target('https://example.com', {rich:true}), null);
});
