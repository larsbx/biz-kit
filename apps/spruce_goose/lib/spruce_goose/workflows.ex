defmodule SpruceGoose.Workflows do
  use Ash.Domain

  # `:when_requested` rather than Ash's `:by_default`. Every write reaches these
  # resources through `SpruceGoose.Authz`, which always passes `authorize?: true`
  # and an actor; `test/authz_lint_test.exs` fails the build if a CLI module
  # calls Ash directly. That keeps the 142 legitimate system-level `Ash.*` calls
  # in the suite working without rewriting each one to opt out.
  authorization do
    authorize(:when_requested)
  end

  resources do
    resource(SpruceGoose.Workflows.Project)
    resource(SpruceGoose.Workflows.Roadmap)
    resource(SpruceGoose.Workflows.Workflow)
    resource(SpruceGoose.Workflows.Task)
    resource(SpruceGoose.Workflows.Dependency)
    resource(SpruceGoose.Workflows.Todo)
    resource(SpruceGoose.Workflows.TodoDependency)
    resource(SpruceGoose.Workflows.Revision)
    resource(SpruceGoose.Workflows.BlueprintRevision)
  end
end
