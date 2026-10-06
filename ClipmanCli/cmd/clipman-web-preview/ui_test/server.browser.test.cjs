const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');

test('real HTTPS server supports encrypted browser history without a local relay', {
  skip: !process.env.CLIPMAN_WEB_HTTPS_FIXTURE
}, async t => {
  const { chromium } = require('playwright');
  const fixture = JSON.parse(await fs.readFile(process.env.CLIPMAN_WEB_HTTPS_FIXTURE, 'utf8'));
  const browser = await chromium.launch({headless:true, executablePath:process.env.CLIPMAN_TEST_BROWSER,
    args:['--ignore-certificate-errors-spki-list='+fixture.pin]});
  t.after(() => browser.close());
  const context = await browser.newContext();
  await context.addInitScript(() => {
    window.written = [];
    Object.defineProperty(navigator, 'clipboard', {value:{
      writeText:async text => { window.written.push({text}); },
      write:async items => {
        for (const item of items) {
          const html = item.types.includes('text/html') ? await (await item.getType('text/html')).text() : '';
          window.written.push({html, types:item.types});
        }
      }
    }});
  });
  await context.route('https://example.com/**', route => route.fulfill({contentType:'text/html', body:'<h1>Synthetic destination</h1>'}));
  const page = await context.newPage();
  const errors = [];
  const requests = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => requests.push({url:request.url(), method:request.method()}));
  await page.goto(fixture.url);
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Ready to connect.');
  assert.equal(await page.evaluate(() => isSecureContext), true);
  assert.equal(await page.getByLabel('Server token').inputValue(), '');
  const connect = async password => {
    await page.getByLabel('Server token').fill('browser-test-token');
    await page.getByLabel('History password').fill(password);
    await page.getByRole('button', {name:'Connect', exact:true}).click();
  };
  await connect('wrong-password');
  await page.waitForFunction(() => document.getElementById('status').textContent.includes('no existing history'));
  assert.equal(await page.locator('#entries li').count(), 0);
  await connect('browser-test-password');
  await page.getByRole('heading', {name:'Text and Links history', exact:true}).waitFor();
  assert.equal(await page.locator('#entries li').count(), 100);
  assert.equal(requests.some(request => request.method === 'PUT'), false);
  assert.equal(requests.some(request => request.url.includes('/relay/')), false);
  await page.getByRole('radio', {name:'Links', exact:true}).check();
  const link = page.getByRole('link', {name:'Synthetic link 000 (opens in new tab)', exact:true});
  await link.waitFor();
  const popupPromise = page.waitForEvent('popup');
  await link.focus();
  await page.keyboard.press('Enter');
  const popup = await popupPromise;
  await popup.getByRole('heading', {name:'Synthetic destination'}).waitFor();
  assert.equal(await popup.evaluate(() => opener), null);
  await popup.close();
  await page.getByRole('radio', {name:'Rich Text', exact:true}).check();
  await page.getByRole('button', {name:'View Formatted test', exact:true}).click();
  const rich = page.locator('#rich-content');
  assert.equal(await rich.locator('strong').textContent(), 'Bold');
  assert.equal(await rich.locator('table td').count(), 2);
  assert.equal(await rich.locator('script,iframe,form,input,[style],[id],a[href],img[src^="https:"]').count(), 0);
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('#rich-dialog').evaluate(node => node.open), false);
  await page.getByRole('button', {name:'Copy formatted Image test', exact:true}).click();
  await page.waitForFunction(() => written.length === 1);
  assert.equal(await page.evaluate(() => written[0].types.includes('image/png')), true);
  assert.match(await page.evaluate(() => written[0].html), /data-clipman-filename="Synthetic image.png"/);
  await page.getByRole('button', {name:'Quick Clip', exact:true}).click();
  await page.getByLabel('Text or link').fill('HTTPS Quick Clip');
  await page.getByLabel('Text or link').press('Control+Enter');
  await page.waitForFunction(() => document.getElementById('status').textContent === 'Clip saved to server.');
  assert.equal(requests.filter(request => request.method === 'PUT').length, 1);
  assert.equal(await page.locator('#clip-dialog').evaluate(node => node.open), false);
  await page.getByRole('radio', {name:'Text', exact:true}).check();
  await page.getByLabel('Search history').fill('HTTPS Quick Clip');
  await page.getByRole('heading', {name:'HTTPS Quick Clip', exact:true}).waitFor();
  await page.setViewportSize({width:360,height:760});
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.getByRole('button', {name:'Disconnect', exact:true}).click();
  assert.equal(await page.locator('#entries li').count(), 0);
  assert.equal(await page.getByLabel('History password').inputValue(), '');
  assert.equal(await page.evaluate(() => localStorage.length+sessionStorage.length), 0);
  assert.deepEqual(await context.cookies(), []);
  assert.deepEqual(errors, []);
});
