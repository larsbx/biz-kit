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

    const card = (text) => page.locator("#pending .card").filter({ hasText: text });
    await card("Reschedule").getByRole("button", { name: "Accept" }).click();
    const dialog = page.locator("#confirm");
    await dialog.waitFor({ state: "visible" });
    const body = await page.locator("#confirm-body").textContent();
    if (!body.includes("TaskTimingRevisedV1")) throw new Error(`unexpected command: ${body}`);
    await page.getByRole("button", { name: "Sign and send" }).click();
    await card("Reschedule").waitFor({ state: "detached" });

    // Edit the create suggestion's title, then accept it as edited.
    await card("Create").getByRole("button", { name: "Edit…" }).click();
    await page.locator("#amend").waitFor({ state: "visible" });
    await page.getByLabel("Title").fill("Write up the audit");
    await page.getByRole("button", { name: "Review and sign" }).click();
    await dialog.waitFor({ state: "visible" });
    const amended = await page.locator("#confirm-body").textContent();
    if (!amended.includes("TaskCreatedV1") || !amended.includes("Write up the audit"))
      throw new Error(`unexpected command: ${amended}`);
    await page.getByRole("button", { name: "Sign and send" }).click();

    await page.locator("#status").filter({ hasText: "Recorded on the ledger" }).waitFor();
    await page.getByText("None.").first().waitFor();
    const accepted = await page.locator("#status").textContent();

    // Lifecycle: each step is a button on the task, signed like a decision.
    const task = page.locator("#tasks .card").filter({ hasText: "Write up the audit" });
    const sign = async (type, button) => {
      await task.getByRole("button", { name: button }).click();
      await dialog.waitFor({ state: "visible" });
      const command = await page.locator("#confirm-body").textContent();
      if (!command.includes(type)) throw new Error(`unexpected command: ${command}`);
      await page.getByRole("button", { name: "Sign and send" }).click();
      await dialog.waitFor({ state: "hidden" });
    };
    await sign("TaskProposedV1", "Propose");
    await task.getByText("Waiting for a Definition of Done").waitFor();
    say({ proposed: true });

    // Governance defines what the task needs. This device stores the SOP and
    // the input from files, refusing a file that is not the one named.
    if ((await next()) !== "go") throw new Error("expected go");
    const upload = async (text, signs = true) => {
      const [chooser] = await Promise.all([
        page.waitForEvent("filechooser"),
        task.getByRole("button", { name: "Upload…" }).click(),
      ]);
      await chooser.setFiles({ name: "file.txt", mimeType: "text/plain", buffer: Buffer.from(text) });
      if (!signs) return;
      await dialog.waitFor({ state: "visible" });
      const command = await page.locator("#confirm-body").textContent();
      if (!command.includes("ArtifactCustodyRecordedV1")) throw new Error(`unexpected command: ${command}`);
      await page.getByRole("button", { name: "Sign and send" }).click();
      await dialog.waitFor({ state: "hidden" });
    };
    await upload("Not the SOP", false);
    await page.locator("#status").filter({ hasText: "not the file this task names" }).waitFor();
    await upload(`SOP for ${chapter}`);
    await sign("TaskSOPAcknowledgedV1", "Acknowledge the SOP");
    await sign("TaskQueuedV1", "Queue");
    await task.getByText("Waiting for a stored copy of input").waitFor();
    await upload(`Input for ${chapter}`);
    await sign("TaskReadyV1", "Mark ready");
    await task.getByText("ready", { exact: true }).waitFor();

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
