defmodule SchoolOps.Extension do
  @moduledoc """
  Read-only SchoolOps ExtensionV1 reference descriptor.

  SchoolOps workflows only propose TaskCore work. No authorized workflow
  mutation, private learner record or independent writer is exposed here.
  """

  @behaviour BizKit.Extension

  @impl true
  def manifest do
    %{
      id: "school_ops",
      contract_version: 1,
      version: "0.1.0",
      dependencies: [],
      capabilities: ["school_ops.catalog.read", "school_ops.workflow.preview"],
      requested_grants: [],
      commands: [],
      events: [],
      projections: [],
      migrations: [],
      deployment: :integrated,
      activation: :manual,
      health: :host
    }
  end
end
