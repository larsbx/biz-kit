# TaskCore

Task and workflow rules for any application:
- lifecycles;
- dependency graphs;
- readiness and execution;
- Definitions of Done, evidence and review;
- timing, suggestions and delegation;
- roadmaps and workflows from reviewed blueprints, and workflow runs.

TaskCore is pure Elixir with no dependencies. Your application keeps
storage, signing and transport. See
[the design](../../docs/architecture/2026-10-20-task-core.md).

```elixir
{:task_core, git: "https://github.com/larsbx/biz-kit.git", sparse: "apps/task_core", ref: "<commit>"}
```

```elixir
defmodule MyApp.TaskHost do
  @behaviour TaskCore.Host
  @impl true
  def verify_artifact(digest, limit), do: MyApp.Store.verify(digest, limit)
  @impl true
  def hash(term), do: MyApp.Canonical.hash(term)
end

state = TaskCore.State.init(MyApp.TaskHost)
:ok = TaskCore.Admission.check(event, %{orchestration: state, role_keys: keys})
state = TaskCore.State.handle_event(event, state)
```

`test/lesson_workflow_test.exs` is a complete host in one file.

Model checks: `spec/check.sh` (Quint 0.25).

## Portable blueprint consumers

`TaskCore.Blueprint.normalize/1` validates decoded schema-2 data without a
YAML, Ash, database or network dependency. The hierarchy is Project → Roadmap
→ Workflow → Task definition; the names can describe releases, maintenance,
research or a curriculum. All dependencies are local to a workflow.

```elixir
{:ok, source} = TaskCore.Blueprint.Source.normalize(%{
  "repository" => "acme/plans", "commit" => commit, "tree" => tree,
  "path" => "release.yaml", "manifest_digest" => {:bytes, digest}
})
{:ok, plan} = TaskCore.Workflow.plan(
  decoded_document, "q4", "release", %{"build" => "build-42", "publish" => "publish-42"},
  {MyApp.TaskLifecycle, 1}
)
```

A plan is a list of string-keyed task maps in dependency order, ties broken
by definition ID. Each keeps its definition's `id`, criteria and input names
and adds `task_id`, `predecessor_ids`, `state` and `lifecycle_version`. IDs
must cover every definition exactly once and be distinct safe segments.
Invalid documents, cycles, missing workflows, malformed ID maps and
unsupported lifecycle versions return `{:error, reason}` without effects.
The lifecycle module is trusted host code implementing `TaskCore.Lifecycle`;
never turn an untrusted document string into a module or atom. No lifecycle
module is serialized into the blueprint or inferred from a version number.

`Blueprint.normalize/1` preserves author order for signing; `Workflow.plan/5`
produces execution order separately. It does not claim that a valid plan is
ready to run. The host verifies Git objects and the manifest digest, decodes
bytes safely, authorizes use of the revision, checks ID availability, and
persists the whole run atomically. `Blueprint.Source` checks only identity
syntax: commit and tree must be lowercase 40-hex SHA-1 Git OIDs, the path must be relative with no empty, `.` or `..` segments, and
the manifest digest is a SHA-256 byte string.

For hosts using `State` and `Admission`, `Hierarchy` additionally enforces
current-revision admission, governance and operator grants, and binds
readiness to the run's predecessors and input names. Those commands use
`TaskCore.TaskLifecycle`; selecting another lifecycle for a standalone plan
does **not** change ledger admission. SpruceGoose retains its own lifecycle,
predecessor-at-start check and versioned SOP policy. The ledger retains its
predecessor-before-ready check and exact SOP digest. Both use the same DAG
and lifecycle contract, without treating their relations as equivalent.

The curriculum fixture is committed data in `test/fixtures/curriculum.exs`.
`LessonWorkflowTest` places it in a temporary local Git repository, reads
its pinned commit, applies it, instantiates both lessons, and completes the
first with verified evidence and a separate reviewer before the second can
become ready. Evaluating this trusted test fixture is **not** a production
decoder: production hosts must not evaluate source code from a blueprint.
The ledger/web fixtures separately cover YAML and source verification.
