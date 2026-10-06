const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');

test('disconnect prevents delayed operations from restoring private content', {
  skip: !process.env.CLIPMAN_TEST_BROWSER
}, async t => {
  const { chromium } = require('playwright');
  const browser = await chromium.launch({headless:true, executablePath:process.env.CLIPMAN_TEST_BROWSER});
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.route('http://127.0.0.1:41822/**', async route => {
    const name = new URL(route.request().url()).pathname.slice(1) || 'index.html';
    if (name === 'preview.json') return route.fulfill({json:{server:'https://example.com', key:'synthetic'}});
    if (!['index.html','app.js','pagination.js','links.js','purify.min.js','rich.js','style.css'].includes(name)) return route.abort();
    const body = await fs.readFile(path.join(__dirname, '../ui', name));
    return route.fulfill({body, contentType:name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html'});
  });
  await page.addInitScript(() => {
    window.Worker = class {
      constructor() { setTimeout(() => this.onmessage?.({data:{ready:true}}), 0); }
      terminate() {}
    };
    Object.defineProperty(navigator, 'clipboard', {value:{
      writeText:async () => { throw new Error('Denied for synthetic test'); },
      readText:() => new Promise(resolve => { window.finishPaste = resolve; })
    }});
  });
  await page.goto('http://127.0.0.1:41822/');
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Ready to connect.');
  const startup = await page.evaluate(async () => {
    disconnect();
    const original = Worker;
    window.Worker = class { terminate() {} };
    const starting = startWorker();
    disconnect();
    const settled = await Promise.race([
      starting.then(() => 'ready', () => 'cancelled'),
      new Promise(resolve => setTimeout(() => resolve('pending'), 100))
    ]);
    window.Worker = original;
    return settled;
  });
  assert.equal(startup, 'cancelled');
  const copied = await page.evaluate(async () => {
    let finish;
    request = () => new Promise(resolve => { finish = resolve; });
    const copying = copyEntry('synthetic');
    disconnect();
    finish({text:'Private synthetic clip'});
    await copying;
    return {open:document.getElementById('copy-dialog').open, text:document.getElementById('copy-text').value};
  });
  assert.deepEqual(copied, {open:false, text:''});
  const pasted = await page.evaluate(async () => {
    document.getElementById('paste').click();
    disconnect();
    finishPaste('Private delayed clipboard');
    await new Promise(resolve => setTimeout(resolve, 20));
    return document.getElementById('clip-text').value;
  });
  assert.equal(pasted, '');
});
