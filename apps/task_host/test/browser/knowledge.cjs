// Real identity + HTTP + canonical grants. No route interception or mocked data.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const readline = require('node:readline');
const fs = require('node:fs');
const path = require('node:path');
const [base, serialized] = process.argv.slice(2);
const reference = JSON.parse(serialized);
const input = readline.createInterface({ input: process.stdin });
const messages = [], waiters = [];
input.on('line', line => { const waiter = waiters.shift(); if (waiter) waiter(line); else messages.push(line); });
const next = () => messages.length ? Promise.resolve(messages.shift()) : new Promise(resolve => waiters.push(resolve));
const say = value => process.stdout.write(JSON.stringify(value) + '\n');

async function signIn(page, subject) {
  const login = await page.request.get(`${base}/auth/second/login`, { maxRedirects: 0 });
  assert.equal(login.status(), 302);
  const state = new URL(login.headers().location).searchParams.get('state');
  const callback = await page.request.get(`${base}/auth/second/callback?${new URLSearchParams({ code: subject, state })}`, { maxRedirects: 0 });
  assert.equal(callback.status(), 302);
}

async function mobile(page) {
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'library overflows the 390px viewport');
}

(async () => {
  const browser = await chromium.launch({ args: ['--no-proxy-server'],
    ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : {}) });
  const errors = [];
  try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await context.newPage(); page.setDefaultTimeout(20_000);
    page.on('pageerror', error => errors.push(error.stack ?? error.message));
    await page.goto(`${base}/operations/knowledge?provider=second`);
    await page.getByRole('link', { name: 'Sign in', exact: true }).waitFor();
    assert.equal(await page.locator('[data-document-id]').count(), 0);

    await signIn(page, 'kb-browser');
    await page.goto(`${base}/operations?provider=second&workspace=knowledge-desk&tab=review&q=retain-this-filter`);
    await page.locator('#operations-title').filter({ hasText: 'Reference acceptance' }).waitFor();
    await page.getByRole('link', { name: 'Reference library →', exact: true }).click();
    await page.locator('[data-document-id]').first().waitFor();
    const back = new URL(await page.locator('#back-to-operations').getAttribute('href'), base);
    assert.equal(back.searchParams.get('workspace'), 'knowledge-desk');
    assert.equal(back.searchParams.get('tab'), 'review');
    assert.equal(back.searchParams.get('q'), 'retain-this-filter');
    await mobile(page);

    const catalog = await page.request.get(`${base}/api/v1/operations/knowledge`);
    assert.equal(catalog.status(), 200); assert.match(catalog.headers()['cache-control'], /no-store/);
    const data = await catalog.json();
    assert.equal(data.catalog.read_only, true);
    assert.ok(data.catalog.total > 0);
    assert.match(await page.locator('#source-revision').getAttribute('href'), new RegExp(data.catalog.source.revision));

    assert.equal(await page.locator('#area-list button').evaluateAll((buttons, area) => {
      const button = buttons.find(button => button.dataset.area === area);
      if (!button) return false;
      button.click(); return true;
    }, reference.area), true);
    await page.locator('#category-filter').selectOption(reference.category);
    await page.locator('#search').fill('24.12a');
    await page.locator('#search-form').getByRole('button', { name: 'Search', exact: true }).click();
    const card = page.locator(`[data-document-id="${reference.id}"]`);
    await card.waitFor(); await card.click();
    await page.locator('#document-title').filter({ hasText: reference.title }).waitFor();
    await page.locator('#document-body').waitFor();
    assert.ok((await page.locator('#document-body').textContent()).length > 50);
    assert.equal(await page.locator('#document-body script, #document-body iframe, #document-body img').count(), 0);
    assert.equal(await page.locator('#document-source').getAttribute('href'), reference.source_url);
    assert.equal(await page.getByRole('button', { name: /run workflow|import as task|approve procedure/i }).count(), 0);
    await mobile(page);

    const original = await (await page.request.get(`${base}/api/v1/operations/knowledge/documents/${reference.id}`)).json();
    const related = original.document.links.find(link => link.status === 'resolved' && link.document_id !== reference.id);
    assert.ok(related, 'the pilot procedure must have a resolved cross-document reference');
    const target = await (await page.request.get(`${base}/api/v1/operations/knowledge/documents/${related.document_id}`)).json();
    assert.equal(await page.locator('#document-body a[data-knowledge-link]').evaluateAll((links, id) => {
      const link = links.find(link => new URL(link.href).searchParams.get('doc') === id);
      if (!link) return false;
      link.click(); return true;
    }, related.document_id), true);
    await page.locator('#document-title').filter({ hasText: target.document.title }).waitFor();
    assert.equal(new URL(page.url()).searchParams.get('doc'), target.document.id);
    if (target.document.jd_id) assert.match(await page.locator('#document-title').textContent(), new RegExp(target.document.jd_id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
    await page.goBack();
    await page.locator('#document-title').filter({ hasText: reference.title }).waitFor();

    if (process.env.KNOWLEDGE_SCREENSHOT_DIR) {
      fs.mkdirSync(process.env.KNOWLEDGE_SCREENSHOT_DIR, { recursive: true });
      await page.locator('#document-panel').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(process.env.KNOWLEDGE_SCREENSHOT_DIR, 'knowledge-mobile.png') });
      await page.setViewportSize({ width: 1280, height: 900 });
      await page.evaluate(() => scrollTo(0, 0));
      await page.screenshot({ path: path.join(process.env.KNOWLEDGE_SCREENSHOT_DIR, 'knowledge-desktop.png') });
      await page.setViewportSize({ width: 390, height: 844 });
    }

    // Render adversarial source through the exact shipped renderer in a real DOM.
    const safe = await page.evaluate(async () => {
      const { renderMarkdown } = await import('/app/knowledge-view.js');
      const host = document.createElement('div');
      renderMarkdown(host, '<img src=x onerror="window.kbInjected=true">\n\n[bad](javascript:alert(1))\n\n| A | B |\n| --- | --- |\n| one | two |');
      document.body.append(host);
      const result = { images: host.querySelectorAll('img').length, scripts: host.querySelectorAll('script').length,
        unsafe: [...host.querySelectorAll('a')].some(link => /^javascript:/i.test(link.href)),
        table: host.querySelectorAll('table').length, injected: window.kbInjected === true };
      host.remove(); return result;
    });
    assert.deepEqual(safe, { images: 0, scripts: 0, unsafe: false, table: 1, injected: false });

    await page.getByRole('button', { name: 'Sign out', exact: true }).click();
    await page.locator('#status').filter({ hasText: 'Signed out' }).waitFor();
    assert.equal(await page.locator('[data-document-id]').count(), 0);
    assert.equal(await page.locator('#document-body').textContent(), '');
    assert.equal((await page.request.get(`${base}/api/v1/operations/knowledge`)).status(), 401);
    await signIn(page, 'kb-browser');
    await page.goto(`${base}/operations/knowledge?provider=second`);
    await page.locator('[data-document-id]').first().waitFor();

    const outsider = await browser.newContext();
    const other = await outsider.newPage();
    await signIn(other, 'kb-browser-outsider');
    await other.goto(`${base}/operations/knowledge?provider=second`);
    await other.locator('#status').filter({ hasText: 'Access to an Operations workspace is required.' }).waitFor();
    assert.equal(await other.locator('[data-document-id]').count(), 0);
    await outsider.close();
    await page.bringToFront();
    say({ stage: 'knowledge_browsed' });
    assert.equal(await next(), 'revoked');
    await page.getByRole('button', { name: 'Refresh', exact: true }).click();
    await page.locator('#status').filter({ hasText: 'Access to an Operations workspace is required.' }).waitFor();
    assert.equal(await page.locator('[data-document-id]').count(), 0);
    assert.equal(await page.locator('#document-body').textContent(), '');
    assert.equal((await page.request.get(`${base}/api/v1/operations/knowledge/documents/${reference.id}`)).status(), 403);
    assert.deepEqual(errors, []);
    say({ stage: 'knowledge_revoked' });
  } finally { await browser.close(); input.close(); }
})().catch(error => { say({ error: error.stack ?? String(error) }); process.exitCode = 1; });
