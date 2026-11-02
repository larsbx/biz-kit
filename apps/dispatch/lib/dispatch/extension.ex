defmodule Dispatch.Extension do
  @moduledoc """
  Dispatch ExtensionV1 reference descriptor for its compiled server backend.

  This descriptor starts no process, confers no grant and does not migrate the
  existing Dispatch operational writer or bypass any scoped authorization.
  """

  @behaviour BizKit.Extension

  @impl true
  def manifest do
    %{
      id: "dispatch",
      contract_version: 1,
      version: "0.1.0",
      dependencies: [],
      capabilities: ["dispatch.capability_document.read"],
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
