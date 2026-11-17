#!/usr/bin/env bash
# Exercise an installed orchestration release on a disposable synthetic host.
set -euo pipefail

if [[ $# != 6 || $1 != --isolated-synthetic ]]; then
  echo 'Usage: accept-packaged-bootstrap.sh --isolated-synthetic CHAPTER TENANT PROJECT WORKSPACE_ID TASK_TITLE' >&2
  exit 2
fi
shift

base=$HOME/ops/bizops-dev
helper=$base/approve.sh
if [[ ! -x "$helper" || "$(stat -c %a "$helper")" != 700 || ! -O "$helper" ||
      ! -x "$base/release/bin/orchestration" ]]; then
  echo 'Expected an installed orchestration release and an owner-only approval helper' >&2
  exit 1
fi

systemctl --user is-active --quiet bizops-dev.service
if [[ "$(systemctl --user show -p ExecStart --value bizops-dev.service)" != *"path=$base/release/bin/orchestration ;"* ]]; then
  echo 'bizops-dev is not running the expected installed release' >&2
  exit 1
fi

check_listener() {
  if [[ "$(ss -H -ltn 'sport = :4001' | awk '{print $4}')" != 127.0.0.1:4001 ]]; then
    echo 'Expected a single IPv4 loopback listener on port 4001' >&2
    exit 1
  fi
}
check_listener

principal=$(systemd-run --user --wait --pipe --quiet -p EnvironmentFile="$base/env" \
  python3 -c '
import json
import os
from urllib.parse import urlsplit

def expect(condition, message):
    if not condition:
        raise SystemExit(message)

env = os.environ
expect(env.get("EVENTSTORE_DATABASE") == "bizops_dev_eventstore"
       and env.get("EVENTSTORE_USERNAME") == "bizops_dev"
       and env.get("EVENTSTORE_HOST") == "127.0.0.1"
       and env.get("EVENTSTORE_PORT") == "5432", "Unexpected event store settings")
for name, database in (("TASK_HOST_DATABASE_URL", "bizops_dev_task_host"),
                       ("SPRUCE_GOOSE_DATABASE_URL", "bizops_dev_spruce_goose")):
    url = urlsplit(env.get(name, ""))
    expect((url.hostname, url.port, url.username, url.path) ==
           ("127.0.0.1", 5432, "bizops_dev", "/" + database), "Unexpected " + name)
expect(env.get("SPRUCE_GOOSE_PUBLIC_URL") == "http://127.0.0.1:4001", "Unexpected public URL")
expect(env.get("BIZKIT_DEVELOPMENT_SIGN_IN") == "bootstrap=synthetic-bootstrap",
       "Expected the dedicated synthetic development provider")
bindings = json.loads(env["BIZKIT_IDENTITY_BINDINGS"])
expect(len(bindings) == 1 and bindings[0].get("issuer") == "biz-kit-development"
       and bindings[0].get("subject") == "synthetic-bootstrap"
       and str(bindings[0].get("principal", "")).startswith("prn_"),
       "Expected a single synthetic identity binding")
print(bindings[0]["principal"])
')

node - "$helper" "$principal" "$@" <<'JS'
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { chromium } = require('playwright');

const [helper, principal, chapter, tenant, project, workspace, title] = process.argv.slice(2);
const base = 'http://127.0.0.1:4001';
const app = `${base}/app?${new URLSearchParams({ chapter, tenant, project, provider: 'bootstrap' })}`;
const label = 'Synthetic packaged bootstrap';
const options = { encoding: 'utf8', timeout: 45_000, stdio: ['ignore', 'pipe', 'pipe'] };
const approve = (...args) => execFileSync(helper, args, options);

async function snapshot(page) {
  const response = await page.request.get(`${base}/api/v1/operations`);
  assert.equal(response.status(), 200);
  const data = await response.json();
  assert.equal(data.principal, principal);
  return data;
}

async function main() {
  assert.throws(() => approve('ZZZZ-ZZZZ-ZZZZ'), error =>
    error.status === 1 && /Could not fetch enrolment request.*404.*unknown_code/.test(error.stderr));
  console.log('PASS installed helper rejects an unknown code');

  const browser = await chromium.launch({ args: ['--no-proxy-server'] });
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(20_000);
    await page.goto(app);
    const [callback] = await Promise.all([
      page.waitForResponse(response =>
        new URL(response.url()).pathname === '/auth/bootstrap/callback'),
      page.getByRole('link', { name: 'Sign in', exact: true }).click(),
    ]);
    assert.equal(callback.status(), 302);
    assert.deepEqual((await snapshot(page)).workspaces, [], 'expected a fresh principal');

    await page.goto(app);
    await page.locator('#enrol-label').fill(label);
    await page.locator('#enrol-role').selectOption('governance');
    await page.locator('#enrol-form').getByRole('button', { name: 'Request access' }).click();
    const pending = page.locator('#admin-enrolment .code');
    await pending.waitFor();
    const code = (await pending.textContent()).trim();
    assert.match(code, /^[A-Z0-9]{4}(?:-[A-Z0-9]{4}){2}$/);
    const request = await page.request.get(`${base}/api/v1/enrolments/${code}`);
    assert.equal(request.status(), 200);
    const details = await request.json();
    assert.deepEqual(
      [details.code, details.role, details.principal_id, details.identity.issuer,
        details.identity.subject, details.chapter_id, details.tenant_id, details.project_id, details.label],
      [code, 'governance', principal, 'biz-kit-development', 'synthetic-bootstrap', chapter, tenant, project, label],
    );

    assert.match(approve(code), /not approved \(pass --yes\)/);
    await page.reload();
    await pending.waitFor();
    assert.equal((await pending.textContent()).trim(), code);
    assert.deepEqual((await snapshot(page)).workspaces, []);
    console.log('PASS development sign-in and read-only inspection of the pending browser request');

    assert.match(approve(code, '--yes'), /^approved:/m);
    await page.reload();
    await page.locator('#admin-section').waitFor();
    await page.locator('#admin-enrolment').filter({ hasText: 'This browser administers this chapter.' }).waitFor();
    assert.ok((await snapshot(page)).workspaces.some(entry => entry.id === workspace));
    execFileSync('systemctl', ['--user', 'restart', 'bizops-dev.service'], {
      ...options, timeout: 310_000,
    });
    // The unit starts the process before its HTTP listener is ready.
    let ready = false;
    for (let attempt = 0; attempt < 60 && !ready; attempt++) {
      try {
        ready = (await page.request.get(`${base}/operations`, { timeout: 1000 })).ok();
      } catch {
        // A restart briefly closes the loopback listener.
      }
      if (!ready) await new Promise(resolve => setTimeout(resolve, 1000));
    }
    assert.ok(ready, 'Operations did not return after the service restart');
    assert.ok((await snapshot(page)).workspaces.some(entry => entry.id === workspace));
    await page.goto(`${base}/operations?provider=bootstrap`);
    await page.waitForFunction(id => Array.from(
      document.querySelectorAll('#workspace-list [data-workspace]'),
    ).some(node => node.dataset.workspace === id), workspace);
    await page.waitForFunction(expected => Array.from(
      document.querySelectorAll('#task-list [data-task-key] h3'),
    ).some(node => node.textContent === expected), title);
    console.log('PASS signed administrator approval and synthetic Operations workspace and record');
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(error.message.split('\n')[0]);
  process.exitCode = 1;
});
JS

check_listener
