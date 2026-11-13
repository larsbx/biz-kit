import { test } from "node:test";
import assert from "node:assert/strict";
import {
  validateSnapshot,
  SnapshotState,
  validTimeZone,
  taskRows,
  timingFacts,
  selectRows,
  metrics,
  dateKey,
  projectLink,
  reviewPending,
  workStage,
  workflowRows,
} from "../../priv/static/app/operations-view.js";

const now = Date.parse("2026-11-09T15:00:00Z");
const at = (date) => Date.parse(date);
const task = (attrs = {}) => ({
  state: "queued",
  title: "A task",
  timing: { schedule: null, due_ms: null },
  ...attrs,
});
const workspace = (id, tasks = {}, fields = {}) => ({
  id,
  label: `Custom ${id}`,
  category: "general",
  chapter_id: `chapter-${id}`,
  tenant_id: "tenant",
  project_id: "project",
  view: { tasks, suggestions: {}, workflows: {} },
  ...fields,
});
const snapshot = (...workspaces) => ({
  schema_version: 1,
  title: "Any operations",
  principal: "prn_one",
  time_zone: "Etc/UTC",
  workspaces,
});

test("configuration remains generic and exact scopes cannot be counted twice", () => {
  const value = snapshot(
    workspace("one"),
    workspace("two", {}, { category: "Any user label" }),
  );
  assert.equal(validateSnapshot(value), value);
  assert.throws(() =>
    validateSnapshot(snapshot(workspace("one"), workspace("one"))),
  );
  assert.throws(() =>
    validateSnapshot(
      snapshot(
        workspace("one"),
        workspace("two", {}, { chapter_id: "chapter-one" }),
      ),
    ),
  );
  assert.throws(() =>
    validateSnapshot(
      snapshot(workspace("one", {}, { project_id: "../private" })),
    ),
  );
  assert.throws(() =>
    validateSnapshot({
      ...value,
      workspaces: Array(33).fill(value.workspaces[0]),
    }),
  );
  assert.throws(() =>
    validateSnapshot({ ...value, time_zone: "Imaginary/Zone" }),
  );
  assert.throws(() => validateSnapshot({ ...value, principal: "" }));
  assert.throws(() => validateSnapshot({ ...value, schema_version: 2 }));
  assert.throws(() =>
    validateSnapshot(snapshot(workspace("one", {}, { view: { tasks: [] } }))),
  );
});

test("timezone dates follow real timezone data, including DST", () => {
  assert.equal(validTimeZone("America/New_York"), true);
  assert.equal(validTimeZone("../New_York"), false);
  assert.equal(
    dateKey(at("2026-11-09T02:00:00Z"), "America/New_York"),
    "2026-11-08",
  );
  assert.equal(dateKey(at("2026-11-09T02:00:00Z"), "Asia/Tokyo"), "2026-11-09");
  const repeat = task({
    timing: {
      schedule: {
        kind: "timed",
        start_ms: at("2026-11-01T05:30:00Z"),
        end_ms: at("2026-11-01T06:30:00Z"),
      },
      due_ms: null,
    },
  });
  assert.equal(
    timingFacts(repeat, at("2026-11-01T12:00:00Z"), "America/New_York").today,
    true,
  );
  const spring = task({
    timing: {
      schedule: {
        kind: "timed",
        start_ms: at("2026-03-08T06:30:00Z"),
        end_ms: at("2026-03-08T07:30:00Z"),
      },
      due_ms: null,
    },
  });
  assert.equal(
    timingFacts(spring, at("2026-03-08T12:00:00Z"), "America/New_York").today,
    true,
  );
});

test("Today combines real deadlines, interval overlap and work in progress", () => {
  const due = task({ timing: { schedule: null, due_ms: now - 1 } });
  assert.equal(timingFacts(due, now, "UTC").overdue, true);
  assert.equal(timingFacts(due, now, "UTC").today, true);
  const laterToday = task({
    timing: { schedule: null, due_ms: at("2026-11-09T23:00:00Z") },
  });
  assert.equal(timingFacts(laterToday, now, "UTC").today, true);
  assert.equal(timingFacts(laterToday, now, "UTC").overdue, false);
  assert.equal(
    timingFacts(task({ state: "in_progress" }), now, "UTC").today,
    true,
  );
  for (const state of ["completed", "cancelled"]) {
    const facts = timingFacts({ ...due, state }, now, "UTC");
    assert.equal(facts.active, false);
    assert.equal(facts.today, false);
    assert.equal(facts.overdue, false);
  }
});

test("past scheduled work is not an invented deadline", () => {
  const past = task({
    timing: {
      schedule: {
        kind: "timed",
        start_ms: at("2026-11-08T10:00:00Z"),
        end_ms: at("2026-11-08T11:00:00Z"),
      },
      due_ms: null,
    },
  });
  const facts = timingFacts(past, now, "UTC");
  assert.equal(facts.today, false);
  assert.equal(facts.overdue, false);
  assert.equal(facts.unscheduled, false);
});

test("all-day and timed end boundaries are exclusive", () => {
  const allDay = (start_date, end_date) =>
    task({
      timing: {
        schedule: { kind: "all_day", start_date, end_date },
        due_ms: null,
      },
    });
  assert.equal(
    timingFacts(allDay("2026-11-08", "2026-11-09"), now, "UTC").today,
    false,
  );
  assert.equal(
    timingFacts(allDay("2026-11-09", "2026-11-10"), now, "UTC").today,
    true,
  );
  assert.equal(
    timingFacts(allDay("2026-11-09", "2026-11-10"), now, "UTC").upcoming,
    false,
  );
  assert.equal(
    timingFacts(allDay("2026-11-09", "2026-11-11"), now, "UTC").upcoming,
    true,
  );
  assert.equal(
    timingFacts(
      allDay("2026-12-31", "2027-01-01"),
      at("2027-01-01T12:00:00Z"),
      "UTC",
    ).today,
    false,
  );
  const midnight = task({
    timing: {
      schedule: {
        kind: "timed",
        start_ms: at("2026-11-08T23:00:00Z"),
        end_ms: at("2026-11-09T00:00:00Z"),
      },
      due_ms: null,
    },
  });
  assert.equal(timingFacts(midnight, now, "UTC").today, false);
});

test("upcoming spans tomorrow through seven days, excluding later dates", () => {
  const due = (date) => task({ timing: { schedule: null, due_ms: at(date) } });
  assert.equal(
    timingFacts(due("2026-11-10T00:00:00Z"), now, "UTC").upcoming,
    true,
  );
  assert.equal(
    timingFacts(due("2026-11-16T23:59:59Z"), now, "UTC").upcoming,
    true,
  );
  assert.equal(
    timingFacts(due("2026-11-17T00:00:00Z"), now, "UTC").upcoming,
    false,
  );
});

test("invalid dates are identified and never silently called unscheduled", () => {
  const bad = task({
    timing: {
      schedule: {
        kind: "all_day",
        start_date: "2026-02-30",
        end_date: "2026-03-02",
      },
      due_ms: Number.MAX_SAFE_INTEGER + 1,
    },
  });
  const facts = timingFacts(bad, now, "UTC");
  assert.equal(facts.invalid, true);
  assert.equal(facts.unscheduled, false);
  assert.equal(facts.today, false);
});

test("same task IDs in different projects remain separate through filtering and metrics", () => {
  const due = task({ timing: { schedule: null, due_ms: now - 1000 } });
  const rows = taskRows(
    snapshot(
      workspace(
        "one",
        { same: { ...due, title: "Team paperwork" } },
        { category: "office" },
      ),
      workspace(
        "two",
        { same: { ...due, title: "Equipment check" } },
        { category: "maintenance" },
      ),
    ),
    now,
  );
  assert.equal(rows.length, 2);
  assert.notEqual(rows[0].key, rows[1].key);
  assert.deepEqual(metrics(rows), {
    today: 2,
    overdue: 2,
    review: 0,
    active: 2,
  });
  assert.equal(selectRows(rows, { workspace: "one" }).length, 1);
  assert.equal(
    selectRows(rows, { category: "maintenance" })[0].task.title,
    "Equipment check",
  );
  assert.equal(selectRows(rows, { query: "paperwork" })[0].workspace.id, "one");
});

test("a replacement snapshot removes withdrawn scopes, totals, and workflow metadata", () => {
  const state = new SnapshotState();
  const a = workspace("one", { task: task({ state: "in_progress" }) });
  const b = workspace("two", { task: task({ state: "in_progress" }) });
  b.view.workflows.secret = { name: "Private workflow" };
  state.accept(state.begin(), snapshot(a, b));
  assert.equal(metrics(taskRows(state.value, now)).active, 2);
  state.accept(state.begin(), snapshot(a));
  assert.equal(metrics(taskRows(state.value, now)).active, 1);
  assert.equal(workflowRows(state.value).length, 0);
  assert.doesNotMatch(
    JSON.stringify(state.value),
    /Private workflow|Custom two/,
  );
});

test("logout, hidden-page clearing and failed refresh cannot be undone by late responses", () => {
  const state = new SnapshotState();
  const old = state.begin();
  state.clear();
  assert.equal(state.accept(old, snapshot(workspace("old"))), false);
  assert.equal(state.value, null);
  const first = state.begin();
  const next = state.begin();
  state.accept(next, snapshot(workspace("new")));
  assert.equal(state.accept(first, snapshot(workspace("old"))), false);
  assert.equal(state.value.workspaces[0].id, "new");
  state.clear();
  assert.equal(metrics(taskRows(state.value, now)).active, 0);
});

test("review facts bind to the current submission without claiming reviewer authority", () => {
  const current = task({
    state: "in_progress",
    dod: {
      submission: { event_id: "s2" },
      review: { submission_event_id: "s1", decision: "accept" },
    },
  });
  assert.equal(reviewPending(current), true);
  assert.equal(workStage(current), "Evidence awaiting review");
  current.dod.review = { submission_event_id: "s2", decision: "refuse" };
  assert.equal(reviewPending(current), false);
  assert.equal(workStage(current), "Evidence needs changes");
  current.state = "completed";
  assert.equal(reviewPending(current), false);
});

test("action links remain same-origin and encode query data without granting authority", () => {
  const link = projectLink(workspace("one"), {
    taskId: "task-a",
    provider: "workos&admin=true",
  });
  const url = new URL(link, "https://example.test");
  assert.equal(url.origin, "https://example.test");
  assert.equal(url.pathname, "/app");
  assert.equal(url.searchParams.get("chapter"), "chapter-one");
  assert.equal(url.searchParams.get("focus"), "task-a");
  assert.equal(url.searchParams.get("provider"), "workos&admin=true");
  assert.equal(url.searchParams.has("admin"), false);
});
