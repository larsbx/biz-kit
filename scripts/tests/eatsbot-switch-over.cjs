const assert = require('node:assert/strict');
const { randomBytes } = require('node:crypto');
const { readFileSync } = require('node:fs');
const { get } = require('node:http');
const { chromium } = require('playwright');

async function openLiveView(page, url) {
  await Promise.all([
    page.waitForEvent('websocket', socket => new URL(socket.url()).pathname === '/live/websocket'),
    page.goto(url),
  ]);
  await page.locator('[data-phx-main].phx-connected').waitFor();
}

function websocketUpgradeStatus(storefront, origin) {
  const url = new URL('/live/websocket?vsn=2.0.0', storefront);
  return new Promise((resolve, reject) => {
    const request = get(url, {
      headers: {
        Origin: origin,
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': randomBytes(16).toString('base64'),
      },
    }, response => {
      response.resume();
      resolve(response.statusCode);
    });
    request.on('upgrade', (response, socket) => {
      socket.destroy();
      resolve(response.statusCode);
    });
    request.on('error', reject);
    request.setTimeout(5_000, () => request.destroy(new Error('WebSocket upgrade timed out')));
  });
}

async function run() {
  const stackFile = process.argv[2];
  assert.ok(stackFile, 'Pass the disposable stack’s restaurant-stack.json');
  const { storefront, board_pairing: boardPairing } = JSON.parse(readFileSync(stackFile, 'utf8'));
  assert.equal(new URL(boardPairing).origin, new URL(storefront).origin);

  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_EXECUTABLE_PATH });
  try {
    // Each new page has its own cookie jar. Only the kitchen uses the pairing link.
    const shopper = await browser.newPage();
    const kitchen = await browser.newPage();
    shopper.setDefaultTimeout(15_000);
    kitchen.setDefaultTimeout(15_000);

    await openLiveView(kitchen, boardPairing);
    assert.equal(new URL(kitchen.url()).pathname, '/board');
    await kitchen.locator('#empty').waitFor();

    await openLiveView(shopper, storefront);
    await shopper.locator('#add-margherita').click();
    await shopper.locator('#basket').getByText('1 × Margherita', { exact: true }).waitFor();
    await shopper.getByLabel('Name for order').fill('Browser pickup');
    await shopper.getByRole('button', { name: 'Place order, pay cash' }).click();

    const status = shopper.locator('#order-status');
    await status.filter({ hasText: /^Received$/ }).waitFor();
    const id = await shopper.locator('#order-id').textContent();
    const order = kitchen.locator(`#order-${id}`);
    await order.getByText('Browser pickup', { exact: true }).waitFor();
    await order.getByText('1 × Margherita', { exact: true }).waitFor();

    for (const [action, state, customerStatus] of [
      ['accept', /^accepted$/, /^Accepted$/],
      ['start_preparing', /^preparing$/, /^Being prepared$/],
      ['mark_ready', /^ready$/, /^Ready for pickup$/],
    ]) {
      await order.locator(`#${action}-${id}`).click();
      await order.locator('.state').filter({ hasText: state }).waitFor();
      await status.filter({ hasText: customerStatus }).waitFor();
    }

    await order.locator(`#complete-${id}`).click();
    await order.waitFor({ state: 'detached' });
    await status.filter({ hasText: /^Picked up$/ }).waitFor();

    const foreignOrigin = new URL(storefront);
    foreignOrigin.port = '1';
    assert.equal(await websocketUpgradeStatus(storefront, foreignOrigin.origin), 403,
      'A WebSocket upgrade from a different origin must be refused');

    console.log('Pickup placed, accepted, prepared and completed over LiveView. Foreign origin refused.');
  } finally {
    await browser.close();
  }
}

run().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
