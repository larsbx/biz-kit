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
