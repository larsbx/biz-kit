# What the ledger keeps from SpruceGoose

Date: 2026-10-20. Status: **implemented (task rules)**. Follows
[task core](2026-10-20-task-core.md) and
[readiness for a workflow run](2026-10-20-run-readiness.md).

The SpruceGoose specification was revised against the common ledger: where
the two differed, the ledger stands, and SpruceGoose's legacy records are
not carried forward. What remained was a short list of SpruceGoose
guarantees with no ledger counterpart. This change brings the task rules
among them onto the ledger. The rest of that list is not migrated (below).

## Decision

| Guarantee | Before | Now |
| --- | --- | --- |
| No predecessor cycle across a project (I-19) | Workflow definitions refused cycles; a readiness definition could close one between ad-hoc tasks, leaving them unable ever to become ready | `TaskReadinessDefinedV1` is refused with `predecessor_cycle` if the project's predecessor graph, with this task's list replaced, has a cycle |
| An SOP version never goes back (I-20) | SpruceGoose checked `MAJOR.MINOR` compatibility at run time; the ledger knew only digests | `TaskReadinessDefinedV1` may name `sop_version` (`MAJOR.MINOR.PATCH`). Once a task's SOP is versioned, a redefinition must name one (`sop_version_required`), never lower (`sop_version_regressed`), and one version names one document (`sop_version_conflict`) |
| Todos gate completion | SpruceGoose's Ash `Todo` rows | `TaskCore.Todos`: four operator commands; `TaskCompletedV1` is refused with `open_todos` while any todo is open |

A new SOP version is therefore adopted by governance redefining readiness,
never by a compatibility rule evaluated at run time. Redefinition is
admitted only while a task is proposed or queued and clears the SOP
acknowledgment, so work under way keeps the SOP it started under.

### Todos

| Command | Signed by | Needs |
| --- | --- | --- |
| `TaskTodoAddedV1` | operator | a new `todo_id`, a title, `depends_on` naming todos of the task that were not dropped; at most 64 todos |
| `TaskTodoRevisedV1` | operator | an open todo at `expected_todo_version`; the new dependencies close no cycle |
| `TaskTodoCompletedV1` | operator | an open todo at `expected_todo_version`, every dependency completed or dropped |
| `TaskTodoDroppedV1` | operator | an open todo at `expected_todo_version`, a reason, and no open todo depending on it |

- A todo is checklist state, never authority: todo commands leave the
  task's `version` alone (each todo has its own), so a checklist edit never
  makes a lifecycle command stale.
- They are admitted on any task not yet completed or cancelled, in the
  task's stream, by an active operator grant in the project.
- `TaskCore.Todos.ordered/1` lists a task's todos in the order added.
- `TaskCore.Steps` builds the four commands: `{:add_todo, task, todo, title, deps}`,
  `{:revise_todo, …}`, `{:complete_todo, task, todo}` and `{:drop_todo, task, todo, reason}`.

## Not migrated

- **Already on the ledger.** Two registry rules SpruceGoose enforced already
  hold here. A command cites one grant (`authorization_event_id`), so
  capabilities are never unioned across seats. `RoleKeyRevoked` refuses a
  chapter's last governance key (`cannot_orphan_governance`).
- **Deferred.** "A chapter's first governance seat is held by a person"
  needs a principal kind, which the ledger does not record. It belongs with
  Keel's parties (consolidation step 4).
- **Dropped.** Wait notes and the blocked, impact and critical-path views;
  project-less inbox captures; boards, columns and filters; runtime shadows;
  derivation permits and outcome receipts; release provenance; the
  deployment domain. None is migrated. SpruceGoose's code for them goes
  when its writer is retired.

## Verification

- **`TaskCore.SalvageTest` (14 tests):** cycles closed directly and through
  a chain, judged on the replacing list; SOP versions regressing, missing,
  conflicting, malformed, and unversioned before; todos added in order,
  completed once, after their dependencies; unknown, repeated, dropped and
  cyclic dependencies; stale and closed todos; dropping with dependents;
  the task's version untouched; operator only, and only on unfinished tasks;
  completion refused while a todo is open.
- **`CoopSubstrate.TaskSalvageTest`:** the same rules through signed device
  commands and `Log.append`, and replay reproducing the orchestration state.
- **Quint:**
  - `spec/task_todos.qnt`: a completed task has no open todo; dependencies
    stay acyclic and present; a todo completes after its dependencies; a
    drop strands nothing. The model found that a todo could depend on one
    already dropped; dependencies now name only todos not dropped.
  - `spec/task_definitions.qnt`: the predecessor graph stays acyclic under
    any sequence of redefinitions; a versioned SOP's version is the highest
    it has been named at; one version names one document.
  - Both are checked by `check.sh` (sampled, witnesses, Apalache to depth 5).
- **Suites:** task_core, the ledger and SpruceGoose pass unchanged.

## Limits

- `CoopSubstrate.RunReadiness` and the run readiness page do not yet pass
  `sop_version`; a run's batch defines unversioned SOPs as before.
- The web view does not yet show or edit todos; clients build the commands
  with `TaskCore.Steps`.
