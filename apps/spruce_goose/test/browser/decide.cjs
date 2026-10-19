// Drives the web view in Chromium for SpruceGoose.Web.BrowserTest, talking to
// the test over stdin/stdout one JSON line at a time:
//   → {"code": …, "key_id": …}   once the page has requested access for its key
//   ← "go"                       once an administrator has approved and an agent has suggested
//   → {"proposed": true}         after accepting both suggestions and proposing the task
//   ← "go"                       once governance has defined what the task needs
//   → {"reviewer_code": …, "reviewer_key_id": …}
//                                after taking the task to ready, starting it and submitting
//                                evidence; a second browser has asked for reviewer access
//   ← "go"                       once an administrator has approved the reviewer
//   → {"done": status text}      after the review, completing the task and revoking this device
// Usage: node decide.cjs <base url> <chapter> <tenant> <project>
const { chromium } = require("playwright");
const readline = require("node:readline");

const [base, chapter, tenant, project] = process.argv.slice(2);
const lines = readline.createInterface({ input: process.stdin });
const next = () => new Promise((resolve) => lines.once("line", resolve));
const say = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");

// A fresh browser context (its own cookies and device key) signed in as `subject`
// through the second provider, whose page would hand straight back with the code.
async function signIn(browser, subject) {
  const context = await browser.newContext();
  const page = await context.newPage();
  page.on("console", (m) => process.stderr.write(`[${subject}] ${m.text()}\n`));
  const login = await page.request.get(`${base}/auth/second/login`, { maxRedirects: 0 });
  const state = new URL(login.headers().location).searchParams.get("state");
  const callback = `${base}/auth/second/callback?code=${subject}&state=${state}`;
  const signedIn = await page.request.get(callback, { maxRedirects: 0 });
  if (signedIn.status() !== 302) throw new Error(`sign-in failed: ${signedIn.status()}`);
  return page;
}

(async () => {
  // Loopback only: never through an environment proxy.
  const browser = await chromium.launch({ args: ["--no-proxy-server"] });
  try {
    const page = await signIn(browser, "sub-person");

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

    // Call off the rescheduled task, with a reason (docs/architecture/2026-10-19-cancel-reopen.md).
    const other = page.locator("#tasks .card").filter({ hasText: "Task task-1" });
    page.once("dialog", (prompt) => prompt.accept("No longer needed"));
    await other.getByRole("button", { name: "Cancel…" }).click();
    await dialog.waitFor({ state: "visible" });
    const cancelling = await page.locator("#confirm-body").textContent();
    if (!cancelling.includes("TaskCancelledV1") || !cancelling.includes("No longer needed"))
      throw new Error(`unexpected command: ${cancelling}`);
    await page.getByRole("button", { name: "Sign and send" }).click();
    await other.getByText("Cancelled by").waitFor();

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

    // Start, then submit a file as evidence for the one criterion: its
    // custody, then the submission citing it, each signed.
    const confirm = async (type) => {
      await dialog.waitFor({ state: "visible" });
      const command = await page.locator("#confirm-body").textContent();
      if (!command.includes(type)) throw new Error(`unexpected command: ${command}`);
      await page.getByRole("button", { name: "Sign and send" }).click();
      await dialog.waitFor({ state: "hidden" });
    };
    await sign("TaskStartedV1", "Start");
    await task.getByRole("button", { name: "Submit evidence…" }).click();
    await page.locator("#evidence-fields input[type=file]").setInputFiles({
      name: "report.txt",
      mimeType: "text/plain",
      buffer: Buffer.from(`Report for ${chapter}`),
    });
    await page.getByRole("button", { name: "Store and sign" }).click();
    await confirm("ArtifactCustodyRecordedV1");
    await confirm("TaskEvidenceSubmittedV2");
    await task.getByText("Waiting for a review of the evidence").waitFor();

    // A reviewer, in a browser of their own, asks for reviewer access.
    const reviewer = await signIn(browser, "sub-reviewer");
    await reviewer.goto(`${base}/app?${query}`);
    await reviewer.locator("#key-id").filter({ hasText: /^k-/ }).waitFor({ state: "attached" });
    await reviewer.getByLabel("Name this device").fill("Review tablet");
    await reviewer.locator("#enrol-role").selectOption("reviewer");
    await reviewer.getByRole("button", { name: "Request access" }).click();
    const reviewerCode = reviewer.locator("#review-enrolment .code");
    await reviewerCode.waitFor();
    say({
      reviewer_code: await reviewerCode.textContent(),
      reviewer_key_id: await reviewer.locator("#key-id").textContent(),
    });

    if ((await next()) !== "go") throw new Error("expected go");

    // The reviewer reads the evidence, then accepts it, signed by their device.
    await reviewer.reload();
    await reviewer.getByText("This device can review evidence").waitFor();
    const submission = reviewer.locator("#reviews .card").filter({ hasText: "Write up the audit" });
    const download = submission.getByRole("link", { name: "Download" });
    await download.waitFor();
    const file = await reviewer.request.get(new URL(await download.getAttribute("href"), base).href);
    if ((await file.text()) !== `Report for ${chapter}`) throw new Error("the evidence is not the file submitted");
    reviewer.once("dialog", (prompt) => prompt.accept("Complete and clear"));
    await submission.getByRole("button", { name: "Accept" }).click();
    const reviewed = reviewer.locator("#confirm");
    await reviewed.waitFor({ state: "visible" });
    const verdict = await reviewer.locator("#confirm-body").textContent();
    if (!verdict.includes("TaskDoDReviewedV1") || !verdict.includes("Complete and clear"))
      throw new Error(`unexpected command: ${verdict}`);
    await reviewer.getByRole("button", { name: "Sign and send" }).click();
    await reviewer.locator("#reviews").getByText("None.").waitFor();

    // The person completes the task, citing that review.
    await sign("TaskCompletedV1", "Complete");
    await task.getByText("completed", { exact: true }).waitFor();

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
