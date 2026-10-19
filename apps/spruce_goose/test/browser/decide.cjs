// Drives the web view in Chromium for SpruceGoose.Web.BrowserTest, talking to
// the test over stdin/stdout one JSON line at a time:
//   → {"code": …, "key_id": …}   once the page has requested access for its key
//   ← "go"                       once an administrator has approved and an agent has suggested
//   → {"done": status text}      after accepting, then revoking this device
// Usage: node decide.cjs <base url> <chapter> <tenant> <project>
const { chromium } = require("playwright");
const readline = require("node:readline");

const [base, chapter, tenant, project] = process.argv.slice(2);
const lines = readline.createInterface({ input: process.stdin });
const next = () => new Promise((resolve) => lines.once("line", resolve));
const say = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");

(async () => {
  // Loopback only: never through an environment proxy.
  const browser = await chromium.launch({ args: ["--no-proxy-server"] });
  try {
    const page = await browser.newPage();
    page.on("console", (m) => process.stderr.write(`[page] ${m.text()}\n`));

    // Sign in through the second provider, whose page would hand straight back
    // with the code. The context's request API shares the browser's cookies.
    const login = await page.request.get(`${base}/auth/second/login`, { maxRedirects: 0 });
    const state = new URL(login.headers().location).searchParams.get("state");
    const callback = `${base}/auth/second/callback?code=sub-person&state=${state}`;
    const signedIn = await page.request.get(callback, { maxRedirects: 0 });
    if (signedIn.status() !== 302) throw new Error(`sign-in failed: ${signedIn.status()}`);

    const query = new URLSearchParams({ chapter, tenant, project });
    await page.goto(`${base}/app?${query}`);
    // Once the page holds its key; the name is typed after it has loaded.
    await page.locator("#key-id").filter({ hasText: /^k-/ }).waitFor({ state: "attached" });
    await page.getByLabel("Name this device").fill("Test laptop");
    await page.getByRole("button", { name: "Request access" }).click();
    const code = page.locator("#enrolment .code");
    await code.waitFor();
    say({ code: await code.textContent(), key_id: await page.locator("#key-id").textContent() });

    if ((await next()) !== "go") throw new Error("expected go");

    // Reloading keeps the device key (IndexedDB) and finds it enrolled.
    await page.reload();
    await page.getByText("This device can decide for you").waitFor();

    await page.getByRole("button", { name: "Accept" }).click();
    const dialog = page.locator("#confirm");
    await dialog.waitFor({ state: "visible" });
    const body = await page.locator("#confirm-body").textContent();
    if (!body.includes("TaskTimingRevisedV1")) throw new Error(`unexpected command: ${body}`);
    await page.getByRole("button", { name: "Sign and send" }).click();

    await page.locator("#status").filter({ hasText: "Recorded on the ledger" }).waitFor();
    await page.getByText("None.").first().waitFor();
    const accepted = await page.locator("#status").textContent();

    // Retire this device: confirm, check the signed command, and the page
    // no longer counts it as enrolled.
    page.once("dialog", (dialog) => dialog.accept());
    await page.getByRole("button", { name: "Revoke this device" }).click();
    await dialog.waitFor({ state: "visible" });
    const revocation = await page.locator("#confirm-body").textContent();
    if (!revocation.includes("TaskDeviceRevokedV1")) throw new Error(`unexpected command: ${revocation}`);
    await page.getByRole("button", { name: "Sign and send" }).click();
    await page.getByText("This device cannot decide yet").waitFor();

    say({ done: accepted });
  } finally {
    await browser.close();
    lines.close();
  }
})().catch((e) => {
  say({ error: String(e.stack ?? e) });
  process.exit(1);
});
