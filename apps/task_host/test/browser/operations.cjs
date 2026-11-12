// Real identity cookies -> real operations HTTP -> canonical signed ledger.
// No page.route(), mocked API responses, or synthetic authorization endpoints.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const readline = require('node:readline');
const [base, firstChapter, secondChapter, tenant] = process.argv.slice(2);
const lines = readline.createInterface({ input: process.stdin });
const messages = [];
const waiters = [];
lines.on('line', line => {
  const resolve = waiters.shift();
  if (resolve) resolve(line);
  else messages.push(line);
});
const next = () => messages.length ? Promise.resolve(messages.shift()) : new Promise(resolve => waiters.push(resolve));
const say = obj => process.stdout.write(JSON.stringify(obj) + '\n');
const cards = page => page.locator('#task-list [data-task-key]');
const privateValues = ['private-workspace-beta', 'Private B desk', 'Private B record', 'Beta / confidential'];

async function signIn(page, subject) {
  const login = await page.request.get(`${base}/auth/second/login`, { maxRedirects: 0 });
  assert.equal(login.status(), 302, 'real sign-in endpoint must redirect');
  const state = new URL(login.headers().location).searchParams.get('state');
  assert.ok(state, 'sign-in state is required');
  const callback = await page.request.get(`${base}/auth/second/callback?${new URLSearchParams({ code: subject, state })}`, {
    maxRedirects: 0,
  });
  assert.equal(callback.status(), 302, 'real identity callback must issue the session');
  await page.goto(`${base}/operations?provider=second`);
  await page.locator('#operations-title').filter({ hasText: 'Custom desk' }).waitFor();
}

async function waitForCards(page, count) {
  await page.waitForFunction(expected => document.querySelectorAll('#task-list [data-task-key]').length === expected, count);
}

async function metric(page, id, expected) {
  await page.waitForFunction(({ id, expected }) => {
    const element = document.getElementById(id);
    return element && Number(element.textContent.trim()) === expected;
  }, { id, expected });
}

async function metricsCleared(page) {
  await page.waitForFunction(() => ['metric-today', 'metric-overdue', 'metric-review'].every(id =>
    document.getElementById(id)?.textContent.trim() === '—'));
}

async function assertPrivateAbsent(page) {
  const snapshot = await page.request.get(`${base}/api/v1/operations`);
  assert.equal(snapshot.status(), 200);
  assert.match(snapshot.headers()['cache-control'], /no-store/);
  const text = await snapshot.text();
  const body = await page.locator('body').textContent();
  const html = await page.locator('body').innerHTML();
  for (const secret of privateValues) {
    assert.ok(!text.includes(secret), `unauthorized snapshot disclosed ${secret}`);
    assert.ok(!body.includes(secret), `unauthorized page disclosed ${secret}`);
    assert.ok(!html.includes(secret), `hidden DOM disclosed ${secret}`);
  }
  const data = JSON.parse(text);
  assert.deepEqual(data.workspaces.map(w => w.id), ['workspace-a']);
}

async function assertMobile(page) {
  assert.equal(page.viewportSize().width, 390);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1),
    'operations screen overflows the 390px viewport');
}

async function bootstrap(browser) {
  const page = await browser.newPage();
  page.setDefaultTimeout(20_000);
  const app = `${base}/app?${new URLSearchParams({
    chapter: firstChapter, tenant, project: 'project-1', provider: 'bootstrap',
  })}`;
  await page.goto(app);
  await Promise.all([
    page.waitForURL(`${base}/app`),
    page.getByRole('link', { name: 'Sign in', exact: true }).click(),
  ]);
  const identity = await page.request.get(`${base}/auth/me`);
  assert.equal(identity.status(), 200);

  const before = await page.request.get(`${base}/api/v1/operations`);
  assert.equal(before.status(), 200);
  assert.deepEqual((await before.json()).workspaces, [], 'workspace visible before approval');

  await page.goto(app);
  await page.locator('#enrol-label').fill('Synthetic bootstrap browser');
  await page.locator('#enrol-role').selectOption('governance');
  await page.locator('#enrol-form').getByRole('button', { name: 'Request access' }).click();
  const pending = page.locator('#admin-enrolment .code');
  await pending.waitFor();
  assert.equal(await page.locator('.section-tile[data-section^="admin-"]:visible').count(), 0);
  say({ stage: 'bootstrap_pending', code: await pending.textContent() });
  assert.equal(await next(), 'inspected');
  await page.reload();
  await pending.waitFor();
  say({ stage: 'bootstrap_still_pending' });

  assert.equal(await next(), 'approved');
  await page.reload();
  await page.locator('.section-tile[data-section="admin-0"]').waitFor();
  await page.locator('#admin-enrolment').filter({ hasText: 'This browser administers this chapter.' }).waitFor();
  await page.goto(`${base}/operations?provider=bootstrap`);
  await page.locator('#workspace-list [data-workspace="bootstrap-desk"]').waitFor();
  await cards(page).locator('h3').filter({ hasText: 'Synthetic bootstrap record' }).waitFor();
  say({ stage: 'bootstrap_approved' });
}

(async () => {
  const executable = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
  const browser = await chromium.launch({
    args: ['--no-proxy-server'],
    ...(executable ? { executablePath: executable } : {}),
  });
  const errors = [];
  try {
    if (secondChapter === '--bootstrap') {
      await bootstrap(browser);
      return;
    }
    const fullContext = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const full = await fullContext.newPage();
    full.setDefaultTimeout(20_000);
    full.on('pageerror', e => errors.push(e.stack ?? e.message));
    await signIn(full, 'sub-operations-full');
    await waitForCards(full, 2);
    await metric(full, 'metric-today', 2);
    await metric(full, 'metric-overdue', 2);
    await metric(full, 'metric-review', 0);
    assert.deepEqual((await cards(full).locator('h3').allTextContents()).sort(),
      ['Private B record', 'Review <b>A</b> record'].sort(), 'titles must stay literal and scoped');
    assert.equal(await full.locator('#task-list h3 b').count(), 0, 'task title must not become HTML');
    await full.locator('#workspace-list [data-workspace="workspace-a"]').filter({ hasText: 'Custom <A> desk' }).waitFor();
    await full.locator('#workspace-list [data-workspace="private-workspace-beta"]').filter({ hasText: 'Private B desk' }).waitFor();
    const keys = await cards(full).evaluateAll(nodes => nodes.map(node => node.dataset.taskKey));
    assert.equal(new Set(keys).size, 2, 'colliding task IDs from different scopes were conflated');

    const expectedChapters = new Map([
      ['Review <b>A</b> record', firstChapter],
      ['Private B record', secondChapter],
    ]);
    for (const card of await cards(full).all()) {
      const title = await card.locator('h3').textContent();
      const href = await card.getByRole('link', { name: 'Open task', exact: true }).getAttribute('href');
      const target = new URL(href, base);
      assert.equal(target.origin, new URL(base).origin);
      assert.equal(target.pathname, '/app');
      assert.equal(target.searchParams.get('chapter'), expectedChapters.get(title));
      assert.equal(target.searchParams.get('tenant'), tenant);
      assert.equal(target.searchParams.get('project'), 'project-1');
      assert.equal(target.searchParams.get('focus'), 'shared-task');
      assert.equal(target.searchParams.get('provider'), 'second');
    }

    await full.locator('#search').fill('Private B');
    await waitForCards(full, 1);
    assert.equal(await cards(full).locator('h3').textContent(), 'Private B record');
    await full.locator('#search').fill('');
    await waitForCards(full, 2);
    await full.locator('#category-filter').selectOption({ label: 'Alpha / any-work' });
    await waitForCards(full, 1);
    assert.equal(await cards(full).locator('h3').textContent(), 'Review <b>A</b> record');
    await full.locator('#category-filter').selectOption({ index: 0 });
    await waitForCards(full, 2);
    await full.locator('[data-tab="all"]').click();
    await waitForCards(full, 2);
    await assertMobile(full);

    // A separate real login has only A's canonical grant, despite the same
    // deployment configuration listing both workspaces.
    const restrictedContext = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const restricted = await restrictedContext.newPage();
    restricted.setDefaultTimeout(20_000);
    restricted.on('pageerror', e => errors.push(e.stack ?? e.message));
    await signIn(restricted, 'sub-operations-restricted');
    await waitForCards(restricted, 1);
    await metric(restricted, 'metric-today', 1);
    await metric(restricted, 'metric-overdue', 1);
    await assertPrivateAbsent(restricted);
    await assertMobile(restricted);
    assert.deepEqual(errors, []);
    say({ stage: 'authorized_views' });
    assert.equal(await next(), 'revoked');

    // The host has now revoked B's actual signed grant. A complete refresh
    // must replace all previous records and metadata, not append to a cache.
    await full.bringToFront();
    await full.locator('#refresh').click();
    await waitForCards(full, 1);
    await metric(full, 'metric-today', 1);
    await metric(full, 'metric-overdue', 1);
    await assertPrivateAbsent(full);
    assert.equal(await cards(full).locator('h3').textContent(), 'Review <b>A</b> record');

    await full.waitForFunction(() => !document.getElementById('refresh').disabled);
    await full.evaluate(() => {
      // Observe attempts without intercepting a response: every call still
      // goes through the real browser fetch to the real server. Both clicks
      // happen in one JS turn, before the logout request can complete.
      const original = window.fetch;
      window.__operationsLogoutProbe = { original, reads: 0 };
      window.fetch = function (...args) {
        const input = args[0];
        const url = new URL(typeof input === 'string' ? input : input.url, location.href);
        if (url.pathname === '/api/v1/operations') window.__operationsLogoutProbe.reads++;
        return Reflect.apply(original, window, args);
      };
      document.getElementById('sign-out').click();
      document.getElementById('refresh').click();
    });
    await waitForCards(full, 0);
    await metricsCleared(full);
    await full.waitForFunction(() => !document.body.textContent.includes('Review <b>A</b> record') &&
      !document.body.textContent.includes('Custom <A> desk'));
    await full.locator('#status').filter({ hasText: /^Signed out$/ }).waitFor();
    const readsDuringLogout = await full.evaluate(() => {
      const { original, reads } = window.__operationsLogoutProbe;
      window.fetch = original;
      delete window.__operationsLogoutProbe;
      return reads;
    });
    assert.equal(readsDuringLogout, 0, 'Refresh dispatched a snapshot before logout finished');
    const afterLogout = await full.request.get(`${base}/api/v1/operations`);
    assert.equal(afterLogout.status(), 401, 'logout must revoke the actual identity session');
    assert.ok(!(await afterLogout.text()).includes('Review <b>A</b> record'));

    // The second principal's independent session remains authorized.
    await restricted.bringToFront();
    await restricted.locator('#refresh').click();
    await waitForCards(restricted, 1);
    await assertPrivateAbsent(restricted);
    assert.deepEqual(errors, []);
    say({ stage: 'revocation_and_logout' });
  } finally {
    await browser.close();
    lines.close();
  }
})().catch(error => {
  say({ error: error.stack ?? error.message });
  process.exitCode = 1;
});
