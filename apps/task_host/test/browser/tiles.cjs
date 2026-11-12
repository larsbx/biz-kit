// UI acceptance with synthetic data. Exercises real browser layout/events;
// operations.cjs separately covers real identity and ledger authorization.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const assets = path.resolve(__dirname, '../../priv/static/app');
const snapshot = {
  schema_version: 1, title: 'Operations fixture', principal: 'fixture', time_zone: 'UTC',
  workspaces: [{ id: 'work', label: 'Team workspace', category: 'General', chapter_id: 'chapter', tenant_id: 'tenant', project_id: 'project',
    view: { suggestions: {}, workflows: {}, tasks: {
      draft: { state: 'in_progress', title: 'Draft for review', timing: { due_ms: null, schedule: null }, dod: { submission: { event_id: 's1' } } },
    } },
  }],
};
let signedIn = true;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname === '/api/v1/operations') {
    res.writeHead(signedIn ? 200 : 401, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(signedIn ? snapshot : {}));
  }
  if (url.pathname.startsWith('/auth/')) { res.writeHead(401); return res.end('{}'); }
  const file = url.pathname === '/operations' ? 'operations.html' : url.pathname === '/app' ? 'index.html' : path.basename(url.pathname);
  const target = path.join(assets, file);
  if (!fs.existsSync(target) || !fs.statSync(target).isFile()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html',
    'content-security-policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'" });
  res.end(fs.readFileSync(target));
});

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : {}) });
  const errors = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1800, height: 1100 } });
    page.on('pageerror', e => errors.push(e.stack || e.message));
    page.setDefaultTimeout(10000);
    const tile = id => page.locator(`.section-tile[data-section="${id}"]`);
    const add = id => page.getByRole('combobox', { name: 'Add section', exact: true }).selectOption(id);
    const control = (id, label) => tile(id).getByRole('button', { name: label, exact: true });
    await page.goto(base + '/operations');
    await page.locator('#task-list h3').filter({ hasText: 'Draft for review' }).waitFor();
    await page.locator('#search').fill('Draft');
    await page.evaluate(() => { window.savedInput = document.getElementById('search'); window.savedWork = document.getElementById('task-list'); });
    await control('work', 'Split right').click();
    await control('today', 'Close tile').click();
    await control('work', 'Zoom').click();
    assert.equal(await page.locator('.section-tile:visible').count(), 1);
    await page.keyboard.press('Escape');
    await control('filters', 'Close tile').click();
    await add('filters');
    assert.equal(await page.locator('#search').inputValue(), 'Draft');
    assert.ok(await page.evaluate(() => savedInput === document.getElementById('search') && savedWork === document.getElementById('task-list')));
    // Pick an already open section: both DOM instances survive the swap.
    await tile('filters').getByRole('combobox', { name: 'Section in this tile', exact: true }).selectOption('overdue');
    assert.equal(await page.locator('#search').inputValue(), 'Draft');
    assert.equal(await page.locator('#search').count(), 1);

    const separator = page.getByRole('separator').first();
    await separator.focus();
    await page.keyboard.press('ArrowRight');
    assert.equal(await page.getByRole('separator').first().getAttribute('aria-valuenow'), '25');
    await page.keyboard.press('Enter');
    assert.equal(await page.getByRole('separator').first().getAttribute('aria-valuenow'), '50');
    const before = await page.evaluate(() => localStorage.getItem('biz-kit.operations.tiles.v1'));
    const box = await page.getByRole('separator').first().boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 + 80, box.y + box.height / 2, { steps: 8 });
    await page.mouse.up();
    const saved = await page.evaluate(() => localStorage.getItem('biz-kit.operations.tiles.v1'));
    assert.notEqual(saved, before);
    await page.reload();
    await tile('work').waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem('biz-kit.operations.tiles.v1')), saved);

    await add('view-today');
    await add('view-review');
    assert.match(await tile('view-today').textContent(), /Draft for review/);
    assert.match(await tile('view-review').textContent(), /Draft for review/);
    // A failed/unauthorized refresh must clear every view, including closed DOM.
    signedIn = false;
    await page.locator('#refresh').click();
    await page.waitForFunction(() => !document.body.textContent.includes('Draft for review'));
    signedIn = true;
    await page.locator('#refresh').click();
    await page.locator('#task-list h3').waitFor();
    await page.getByRole('button', { name: 'Reset section layout' }).click();
    await page.screenshot({ path: process.env.TILES_SCREENSHOT || '/tmp/biz-kit-operations-tiles.png', fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
    await control('work', 'Zoom').click();
    const mobile = await tile('work').boundingBox();
    assert.ok(mobile.width <= 390 && mobile.width > 300);
    await page.keyboard.press('Escape');

    await page.setViewportSize({ width: 1800, height: 1100 });
    await page.goto(base + '/app');
    await tile('tasks-heading').waitFor();
    await control('tasks-heading', 'Close tile').click();
    await page.evaluate(() => { location.hash = 'tasks-heading'; });
    await tile('tasks-heading').waitFor({ state: 'visible' });
    // Simulate the existing app's permission visibility updates, not a grant.
    await page.evaluate(() => { document.getElementById('admin-section').hidden = false; });
    await add('admin-0');
    await page.locator('#approve-code').fill('unsent-draft');
    await control('admin-0', 'Close tile').click();
    await add('admin-0');
    assert.equal(await page.locator('#approve-code').inputValue(), 'unsent-draft');
    await page.evaluate(() => { document.getElementById('admin-section').hidden = true; });
    await tile('admin-0').waitFor({ state: 'hidden' });
    assert.equal(await page.getByRole('combobox', { name: 'Add section', exact: true }).locator('option[value="admin-0"]').count(), 0);
    await page.evaluate(() => { document.getElementById('admin-section').hidden = false; });
    await tile('admin-0').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#approve-code').inputValue(), 'unsent-draft');
    assert.deepEqual(errors, []);
    console.log('PASS: Operations and TaskHost split, swap, close/reopen, DOM drafts, keyboard/pointer resize, zoom, restore, parallel views, auth clearing, mobile bounds, deep links and permission visibility');
  } catch (error) {
    console.error("Browser errors:", errors);
    for (const context of browser.contexts()) for (const page of context.pages()) {
      console.error(await page.locator("body").innerText());
      await page.screenshot({ path: "/tmp/biz-kit-tiles-failure.png", fullPage: true });
    }
    throw error;
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => server.close());
