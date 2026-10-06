const { test } = require('node:test');
const assert = require('node:assert/strict');

test('link navigation presents the entry name first and preserves the session', {
  skip: !process.env.CLIPMAN_PREVIEW_FIXTURE_URL
}, async t => {
  const { chromium } = require('playwright');
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.CLIPMAN_TEST_BROWSER || undefined
  });
  t.after(() => browser.close());
  const context = await browser.newContext();
  await context.route('https://example.com/**', route => route.fulfill({
    status: 200, contentType: 'text/html',
    body: '<!doctype html><h1>Synthetic destination</h1>'
  }));
  const page = await context.newPage();
  await page.goto(process.env.CLIPMAN_PREVIEW_FIXTURE_URL);
  await page.getByLabel('Server token').fill('browser-test-token');
  await page.getByLabel('History password').fill('browser-test-password');
  await page.getByRole('button', {name:'Connect', exact:true}).click();
  await page.getByRole('radio', {name:'Links', exact:true}).check();
  await page.getByRole('heading', {name:'Synthetic link 000', exact:true}).waitFor();
  const link = page.locator('#entries a').first();
  assert.equal(await link.textContent(), 'Synthetic link 000 (opens in new tab)');
  assert.equal(await link.getAttribute('aria-label'), null);
  await page.getByRole('link', {name:'Synthetic link 000 (opens in new tab)', exact:true}).waitFor();
  assert.equal(await link.getAttribute('target'), '_blank');
  assert.equal(await link.getAttribute('rel'), 'noopener noreferrer');
  await page.getByRole('button', {name:'Copy Synthetic link 000', exact:true}).focus();
  await page.keyboard.press('Tab');
  assert.equal(await page.evaluate(() => document.activeElement.textContent),
    'Synthetic link 000 (opens in new tab)');
  const opened = page.waitForEvent('popup');
  await page.keyboard.press('Enter');
  const popup = await opened;
  await popup.getByRole('heading', {name:'Synthetic destination', exact:true}).waitFor();
  assert.equal(await popup.evaluate(() => window.opener), null);
  assert.equal(await popup.evaluate(() => document.referrer), '');
  await popup.close();
  assert.equal(await page.locator('#disconnect').isVisible(), true);
  assert.equal(await page.locator('#entries li').count(), 12);
  await page.evaluate(() => {
    const rows = pageState.rows.map(row => ({...row}));
    rows[0].name = '   ';
    render({...pageState, rows});
  });
  assert.equal(await page.locator('#entries a').first().textContent(),
    'https://example.com/page/0 (opens in new tab)');
  await page.evaluate(() => {
    const rows = pageState.rows.map(row => ({...row}));
    rows[0].name = 'x'.repeat(300);
    render({...pageState, rows});
  });
  await page.setViewportSize({width:360, height:760});
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
});
