const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const context = {};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/pagination.js'), 'utf8'), context);
const pages = (total, current) => Array.from(context.ClipmanPaging.pages(total, current));

test('small histories show every page; empty history shows none', () => {
  assert.deepEqual(pages(0, 1), []);
  assert.deepEqual(pages(1, 1), [1]);
  assert.deepEqual(pages(7, 4), [1, 2, 3, 4, 5, 6, 7]);
});
test('large histories keep edges and neighbours without excessive buttons', () => {
  assert.deepEqual(pages(100, 1), [1, 2, 3, 98, 99, 100]);
  assert.deepEqual(pages(100, 50), [1, 2, 3, 49, 50, 51, 98, 99, 100]);
  assert.deepEqual(pages(100, 100), [1, 2, 3, 98, 99, 100]);
  for (let total = 1; total <= 150; total++) {
    for (let current = 1; current <= total; current++) {
      const result = pages(total, current);
      assert.ok(result.length <= 9);
      assert.ok(result.includes(current));
      assert.equal(result[0], 1);
      assert.equal(result.at(-1), total);
      assert.deepEqual(result, [...new Set(result)].sort((a, b) => a - b));
    }
  }
});
