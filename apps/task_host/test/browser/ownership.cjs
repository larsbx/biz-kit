// Real enrolled governance browser -> signed HTTP -> authoritative ledger.
const { chromium } = require('playwright');
const readline = require('node:readline');
const [base, chapter, tenant] = process.argv.slice(2);
const lines = readline.createInterface({ input: process.stdin });
const next = () => new Promise(resolve => lines.once('line', resolve));
const say = obj => process.stdout.write(JSON.stringify(obj) + '\n');

(async () => {
  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(20_000);
    page.on('pageerror', e => process.stderr.write(e.stack + '\n'));
    page.on('dialog', d => d.accept());
    const login = await page.request.get(`${base}/auth/second/login`, { maxRedirects: 0 });
    const state = new URL(login.headers().location).searchParams.get('state');
    const callback = await page.request.get(`${base}/auth/second/callback?code=sub-owner-admin&state=${state}`, { maxRedirects: 0 });
    if (callback.status() !== 302) throw Error('sign-in failed');
    await page.goto(`${base}/app?${new URLSearchParams({ chapter, tenant, project: 'project-1' })}`);
    await page.locator('#key-id').filter({ hasText: /^k-/ }).waitFor({ state: 'attached' });
    await page.getByLabel('Name this device').fill('Ownership administrator');
    await page.locator('#enrol-role').selectOption('governance');
    await page.getByRole('button', { name: 'Request access', exact: true }).click();
    await page.locator('#admin-enrolment .code').waitFor();
    say({ code: await page.locator('#admin-enrolment .code').textContent() });
    await next();
    await page.reload();
    await page.getByText('This browser administers this chapter.').waitFor();
    const openSection = label => page.getByLabel('Add section', { exact: true }).selectOption({ label });
    await openSection('Projects of this chapter');
    await openSection('A person in this chapter');
    await openSection('Connection status');
    await page.locator('#projects').getByText('Accountable owner: owner', { exact: false }).first().waitFor();

    const lookup = async () => {
      await page.locator('#person-id').fill('owner');
      await page.locator('#person-form button').click();
      await page.getByLabel(`Successor for ${tenant} / project-1`, { exact: true }).waitFor();
    };
    const choose = async project => {
      const select = page.getByLabel(`Successor for ${tenant} / ${project}`, { exact: true });
      if (await select.locator('option[value="bot"]').count()) throw Error('agent offered as successor');
      if (await select.locator('option[value="owner"]').count()) throw Error('departing owner offered as successor');
      await select.selectOption('alice');
    };
    const offboard = () => page.getByRole('button', { name: 'Offboard from this chapter…', exact: true }).click();
    const dialog = page.locator('#confirm');
    const sign = async () => {
      await dialog.waitFor({ state: 'visible' });
      const commands = await page.locator('#confirm-body').textContent();
      if (!commands.includes('TaskProjectOwnerAssignedV1') || !commands.includes('alice')) throw Error('missing succession review');
      await page.getByRole('button', { name: 'Sign and send', exact: true }).click();
      await dialog.waitFor({ state: 'hidden' });
    };
    await lookup();
    await choose('project-1');
    say({ stage: 'selected' });
    await next(); // unrelated chapter update must preserve this selection
    await page.locator('#projects .row').filter({ hasText: `${tenant} / project-1` }).filter({ hasText: '4 people' }).waitFor();
    if (await page.getByLabel(`Successor for ${tenant} / project-1`, { exact: true }).inputValue() !== 'alice') throw Error('live update erased the successor');
    await offboard();
    await page.locator('#status').filter({ hasText: 'Every successor must name an accountable human principal' }).waitFor();
    if (await dialog.isVisible()) throw Error('incomplete selection reached signing');
    await choose('project-2');
    await offboard();
    await dialog.waitFor({ state: 'visible' });
    say({ stage: 'prepared' });
    await next(); // host adds another project holding while this review is open
    await sign();
    await page.locator('#status').filter({ hasText: 'Look up the person again' }).waitFor();
    say({ stage: 'stale_refused' });
    await next();

    await lookup();
    for (const project of ['project-1', 'project-2', 'project-3']) await choose(project);
    // Reject one signature at the real submit boundary. No prefix may append.
    await page.route('**/chapter_offboarding/*', async route => {
      const body = route.request().postDataJSON();
      body.signatures[0] = Buffer.alloc(64).toString('base64url');
      await route.continue({ postData: JSON.stringify(body) });
    });
    await offboard();
    await sign();
    await page.locator('#status').filter({ hasText: 'signature was rejected' }).waitFor();
    await page.unroute('**/chapter_offboarding/*');
    say({ stage: 'signature_refused' });
    await next();
    await lookup();
    for (const project of ['project-1', 'project-2', 'project-3']) await choose(project);
    await offboard();
    await sign();
    await page.locator('#status').filter({ hasText: 'Recorded on the ledger' }).waitFor();
    say({ stage: 'succeeded' });
    await next();

    await openSection('Projects needing an accountable owner');
    await page.getByRole('button', { name: 'Refresh ownerless projects' }).click();
    const legacy = page.locator('#ownerless-projects .held').filter({ hasText: `${tenant} / old-project` });
    await legacy.waitFor();
    await legacy.getByLabel('Owner', { exact: true }).fill('legacy');
    await legacy.getByRole('button', { name: 'Assign owner…', exact: true }).click();
    await dialog.waitFor({ state: 'visible' });
    const body = await page.locator('#confirm-body').textContent();
    if (!body.includes('TaskPrincipalKindDeclaredV1') || !body.includes('human') || !body.includes('TaskProjectOwnerAssignedV1')) throw Error('missing governed backfill review');
    await page.getByRole('button', { name: 'Sign and send', exact: true }).click();
    await legacy.waitFor({ state: 'detached' });
    say({ stage: 'backfilled' });
  } finally { await browser.close(); lines.close(); }
})().catch(e => { say({ error: e.stack ?? e.message }); process.exitCode = 1; });
