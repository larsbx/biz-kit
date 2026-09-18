defmodule Dispatch.Access.SeedManifest do
  @moduledoc """
  The normative seeded role manifests of Section 23.2.

  These are transcribed from the specification's capability table. Section 33.1
  requires the seed manifests for `ADMIN`, `DISPATCHER`, `SHIPPER`, `RECEIVER`,
  and `BROKER` to match that table *exactly*, so the matrix lives here as data
  and the test compares against it rather than against the seed script's output
  — a seed bug and a test bug cannot then cancel out.

  What is absent matters as much as what is present:

  - `ADMIN` has no operational read. Section 23.3 states an administrative role
    does not satisfy an operational read check, and acceptance criterion 14
    requires a separate scoped role before precise location, message content, or
    negotiated load data becomes visible.
  - `DISPATCHER` does not carry `operations.location.precise.read`. Section 23.2
    makes precise location a separate capability that additionally requires
    active consent.
  - No profile carries `action.execute.approved`. Section 23.2: no seeded role
    may accept a load, alter a rate, change a confirmed appointment, bind
    another organization, or execute a consequential action because of its
    profile. Execution is a service path behind the proposal, approval,
    action-hash, expiry, and execution-receipt flow.
  """

  alias Dispatch.Access.Capabilities

  @manifests [
    %{
      key: "DRIVER",
      label: "Driver",
      profile_module: Dispatch.Access.Roles.Driver,
      scope_type: :SELF,
      capabilities: ~w(
        profile.read.self
        assignment.read.self
        status.declare.self
        location.share.self
        proposal.decide.self
        communications.read.self
      ),
      constraints: %{
        "status.declare.self" => ["self_only"],
        "location.share.self" => ["self_only", "requires_consent"],
        "proposal.decide.self" => ["self_only", "requires_biometric"],
        "assignment.read.self" => ["self_only", "active_assignment_only"],
        "communications.read.self" => ["self_only"]
      }
    },
    %{
      key: "ADMIN",
      label: "Administrator",
      profile_module: Dispatch.Access.Roles.Admin,
      scope_type: :ORGANIZATION,
      capabilities: ~w(
        tenant.configure
        membership.manage
        role_assignment.manage
        integration.configure
        retention.manage
        audit.read
      ),
      constraints: %{"audit.read" => ["audited_read"]}
    },
    %{
      key: "DISPATCHER",
      label: "Dispatcher",
      profile_module: Dispatch.Access.Roles.Dispatcher,
      scope_type: :ORGANIZATION,
      capabilities: ~w(
        operations.participant.read
        load.read
        stop.read
        load.update.nonbinding
        proposal.create
        appointment.propose
        instruction.propose
        communications.read.scoped
      ),
      constraints: %{
        "operations.participant.read" => ["active_assignment_only"],
        "communications.read.scoped" => ["active_assignment_only"]
      }
    },
    %{
      key: "SHIPPER",
      label: "Shipper",
      profile_module: Dispatch.Access.Roles.Shipper,
      scope_type: :STOP,
      capabilities: ~w(
        load.read
        stop.read
        stop.update.readiness
        appointment.propose
        instruction.propose
        document_reference.read
        document_reference.add
        communications.read.scoped
        proposal.create
      ),
      constraints: %{
        "stop.read" => ["active_assignment_only"],
        "stop.update.readiness" => ["active_assignment_only"],
        "communications.read.scoped" => ["active_assignment_only"]
      }
    },
    %{
      key: "RECEIVER",
      label: "Receiver",
      profile_module: Dispatch.Access.Roles.Receiver,
      scope_type: :STOP,
      capabilities: ~w(
        load.read
        stop.read
        stop.update.readiness
        appointment.propose
        instruction.propose
        document_reference.read
        document_reference.add
        communications.read.scoped
        proposal.create
      ),
      constraints: %{
        "stop.read" => ["active_assignment_only"],
        "stop.update.readiness" => ["active_assignment_only"],
        "communications.read.scoped" => ["active_assignment_only"]
      }
    },
    %{
      key: "BROKER",
      label: "Broker",
      profile_module: Dispatch.Access.Roles.Broker,
      scope_type: :LOAD,
      capabilities: ~w(
        load.read
        stop.read
        appointment.propose
        instruction.propose
        document_reference.read
        communications.read.scoped
        proposal.create
      ),
      constraints: %{
        "load.read" => ["active_assignment_only"],
        "communications.read.scoped" => ["active_assignment_only"]
      }
    }
  ]

  @doc "Every seeded manifest, in the order Section 23.2 tabulates them."
  @spec all() :: [map()]
  def all, do: @manifests

  @doc "The manifest for a stable role key."
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(key) do
    case Enum.find(@manifests, &(&1.key == key)) do
      nil -> :error
      manifest -> {:ok, manifest}
    end
  end

  @doc "Every seeded role key."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@manifests, & &1.key)

  @doc """
  Capability keys used by a manifest that are not canonical.

  Empty for a correct manifest. The seed script refuses to run otherwise, so a
  transcription error fails loudly rather than seeding a role that grants
  nothing.
  """
  @spec unknown_capabilities() :: [{String.t(), [String.t()]}]
  def unknown_capabilities do
    @manifests
    |> Enum.map(fn manifest -> {manifest.key, Capabilities.unknown(manifest.capabilities)} end)
    |> Enum.reject(fn {_key, unknown} -> unknown == [] end)
  end
end
