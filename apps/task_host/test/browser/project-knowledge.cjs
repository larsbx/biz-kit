// Actual identity, browser-generated governance key, signed reviews and scoped
// Operations reads. No routes or API responses are intercepted.
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const readline = require('node:readline');
const [base, chapter, tenant, project] = process.argv.slice(2);
const input = readline.createInterface({ input: process.stdin });
const messages = [], waiters = [];
input.on('line', line => { const waiter = waiters.shift(); if (waiter) waiter(line); else messages.push(line); });
const next = () => messages.length ? Promise.resolve(messages.shift()) : new Promise(resolve => waiters.push(resolve));
const say = value => process.stdout.write(JSON.stringify(value) + '\n');
const query = new URLSearchParams({ chapter, tenant, project, provider: 'second' });
const api = `${base}/api/v1/chapters/${chapter}/tenants/${tenant}/projects/${project}/knowledge`;

async function signIn(page, subject) {
  const login = await page.request.get(`${base}/auth/second/login`, { maxRedirects: 0 });
  assert.equal(login.status(), 302);
  const state = new URL(login.headers().location).searchParams.get('state');
  const callback = await page.request.get(`${base}/auth/second/callback?${new URLSearchParams({ code: subject, state })}`, { maxRedirects: 0 });
  assert.equal(callback.status(), 302);
}

async function read(page, path = '') {
  const response = await page.request.get(api + path);
  assert.equal(response.status(), 200);
  assert.match(response.headers()['cache-control'], /no-store/);
  return response.json();
}

async function signShown(page, candidate, decision) {
  const dialog = page.locator('#confirm');
  await dialog.waitFor({ state: 'visible' });
  const command = JSON.parse(await page.locator('#confirm-body').textContent());
  assert.equal(command.type, 'KnowledgeCandidateReviewedV1');
  assert.equal(command.payload.candidate_id, candidate.id);
  assert.equal(command.payload.decision, decision);
  assert.equal(command.payload.tenant_id, tenant);
  assert.equal(command.payload.project_id, project);
  assert.deepEqual(command.payload.source_fingerprint, { __bytes__: candidate.source_fingerprint });
  assert.deepEqual(command.payload.draft_digest, { __bytes__: candidate.draft_digest });
  assert.equal(command.payload.snapshot.body, candidate.body);
  assert.deepEqual(command.payload.snapshot.source, candidate.source);
  const [response] = await Promise.all([
    page.waitForResponse(response => response.request().method() === 'POST' &&
      response.url().startsWith(`${api}/${candidate.id}/reviews/`)),
    page.getByRole('button', { name: 'Sign and send', exact: true }).click(),
  ]);
  assert.equal(response.status(), 201);
  await dialog.waitFor({ state: 'hidden' });
}

(async () => {
  const browser = await chromium.launch({ args: ['--no-proxy-server'],
    ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : {}) });
  const errors = [];
  try {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await context.newPage(); page.setDefaultTimeout(20_000);
    page.on('pageerror', error => errors.push(error.stack ?? error.message));
    await signIn(page, 'project-kb-admin');
    await page.goto(`${base}/app?${query}`);
    await page.locator('#key-id').filter({ hasText: /^k-/ }).waitFor({ state: 'attached' });
    await page.getByLabel('Name this device').fill('Knowledge review browser');
    await page.locator('#enrol-role').selectOption('governance');
    await page.getByRole('button', { name: 'Request access', exact: true }).click();
    await page.locator('#admin-enrolment .code').waitFor();
    say({ stage: 'enrolment', code: await page.locator('#admin-enrolment .code').textContent(), key_id: await page.locator('#key-id').textContent() });
    assert.equal(await next(), 'enrolled');

    await page.goto(`${base}/app?${query}#knowledge-heading`);
    await page.getByText('This browser administers this chapter').waitFor();
    const pending = page.locator('#project-knowledge [data-knowledge-status="pending"]');
    await pending.waitFor();
    const initial = await read(page, '?status=pending');
    assert.equal(initial.items.length, 1);
    const candidate = initial.items[0];
    assert.equal(candidate.kind, 'adopted_workflow');
    assert.equal(candidate.review_version, 0);
    assert.deepEqual((await read(page, '/suggestions?task_id=kb-build')).items, []);
    await pending.getByRole('button', { name: 'Approve draft…', exact: true }).waitFor();
    await pending.getByLabel(`Review reason for ${candidate.title}`).fill('Verified against the adopted workflow.');
    await pending.getByRole('button', { name: 'Approve draft…', exact: true }).click();
    await signShown(page, candidate, 'approve');

    await page.getByLabel('Knowledge status', { exact: true }).selectOption('approved');
    await page.locator(`#project-knowledge [data-knowledge-candidate="${candidate.id}"][data-knowledge-status="approved"]`).waitFor();
    assert.equal((await read(page, `/${candidate.id}`)).candidate.review_version, 1);
    assert.equal((await read(page, '/suggestions?task_id=kb-build')).items[0].id, candidate.id);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'knowledge queue overflows the mobile viewport');

    // A normal project reader gets the reference but has no approval control.
    const readerContext = await browser.newContext();
    const reader = await readerContext.newPage(); reader.setDefaultTimeout(20_000);
    reader.on('pageerror', error => errors.push(error.stack ?? error.message));
    await signIn(reader, 'project-kb-reader');
    await reader.goto(`${base}/app?${query}&knowledge_status=approved&knowledge=${candidate.id}#knowledge-heading`);
    await reader.locator(`[data-knowledge-candidate="${candidate.id}"]`).waitFor();
    assert.equal(await reader.locator('#project-knowledge').getByRole('button', { name: /Approve draft|Withdraw approval|Reconsider and approve/ }).count(), 0);
    await readerContext.close();

    await page.bringToFront();
    await page.goto(`${base}/operations?provider=second&workspace=knowledge-desk&tab=all`);
    await page.getByRole('link', { name: 'Project knowledge: 0 pending approval · 1 approved', exact: true }).waitFor();
    const task = page.locator('.task-card:visible').filter({ hasText: 'Build the release' }).first();
    await task.locator('details.knowledge-suggestions > summary').click();
    await task.locator(`[data-suggested-knowledge="${candidate.id}"]`).waitFor();
    assert.match(await task.locator('.knowledge-reason').textContent(), /adopted workflow/);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'knowledge suggestion overflows the mobile viewport');
    say({ stage: 'approved', candidate_id: candidate.id, source_fingerprint: candidate.source_fingerprint, draft_digest: candidate.draft_digest });
    assert.equal(await next(), 'withdraw');

    await task.locator(`[data-suggested-knowledge="${candidate.id}"]`).getByRole('link', { name: candidate.title, exact: true }).click();
    const approved = page.locator(`#project-knowledge [data-knowledge-candidate="${candidate.id}"]`);
    await approved.getByRole('button', { name: 'Withdraw approval…', exact: true }).waitFor();
    await approved.getByLabel(`Review reason for ${candidate.title}`).fill('Reference is no longer appropriate for use.');
    await approved.getByRole('button', { name: 'Withdraw approval…', exact: true }).click();
    await signShown(page, candidate, 'withdraw');
    const withdrawn = (await read(page, `/${candidate.id}`)).candidate;
    assert.equal(withdrawn.status, 'withdrawn');
    assert.equal(withdrawn.review_version, 2);
    assert.deepEqual((await read(page, '/suggestions?task_id=kb-build')).items, []);

    await page.goto(`${base}/operations?provider=second&workspace=knowledge-desk&tab=all`);
    const after = page.locator('.task-card:visible').filter({ hasText: 'Build the release' }).first();
    await after.locator('details.knowledge-suggestions > summary').click();
    await after.getByText('No approved knowledge matches this work yet.', { exact: true }).waitFor();
    assert.equal(await after.locator('[data-suggested-knowledge]').count(), 0);
    assert.deepEqual(errors, []);
    say({ stage: 'withdrawn' });
  } finally { await browser.close(); input.close(); }
})().catch(error => { say({ error: error.stack ?? String(error) }); process.exitCode = 1; });
