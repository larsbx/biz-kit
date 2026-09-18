defmodule Dispatch.Access.Capabilities do
  @moduledoc """
  The canonical capability vocabulary of Section 23.2.

  Authorization is expressed over these keys, never over a role key. Section
  23.2 forbids branching on a hard-coded role column, and Section 34's Slice 1
  exit criterion requires that no shared Ash policy or Android feature module
  branch on a seeded role key at all. Keeping the vocabulary closed here is what
  makes that checkable: a capability that is not in this list cannot be granted,
  so a new role profile is a new bundle of existing keys rather than a new
  branch somewhere.

  Constraint keys are separate from capability keys. A capability says *what*
  an actor may attempt; a constraint says under what conditions, and Section
  23.2 names `self_only`, `active_assignment_only`, `requires_consent`,
  `requires_biometric`, and `audited_read`.
  """

  @self_service ~w(
    profile.read.self
    assignment.read.self
    status.declare.self
    location.share.self
    proposal.decide.self
    communications.read.self
  )

  @administration ~w(
    tenant.configure
    membership.manage
    role_assignment.manage
    integration.configure
    retention.manage
    audit.read
  )

  @operations ~w(
    operations.participant.read
    operations.location.precise.read
  )

  @commercial ~w(
    load.read
    load.update.nonbinding
    stop.read
    stop.update.readiness
    appointment.propose
    instruction.propose
    document_reference.read
    document_reference.add
    communications.read.scoped
    proposal.create
    action.execute.approved
  )

  @all @self_service ++ @administration ++ @operations ++ @commercial

  @constraints ~w(
    self_only
    active_assignment_only
    requires_consent
    requires_biometric
    audited_read
  )a

  @typedoc "A canonical capability key."
  @type t :: String.t()

  @typedoc "A condition attached to a granted capability (Section 23.2)."
  @type constraint ::
          :self_only
          | :active_assignment_only
          | :requires_consent
          | :requires_biometric
          | :audited_read

  @doc "Every canonical capability key, sorted."
  @spec all() :: [t()]
  def all, do: Enum.sort(@all)

  @doc """
  Capabilities that require `principal_type = PARTICIPANT`.

  Section 23.2: operational self-service capabilities are not available to a
  service principal, so an agent runtime or a job cannot declare a status or
  decide a proposal on someone's behalf.
  """
  @spec self_service() :: [t()]
  def self_service, do: Enum.sort(@self_service)

  @doc "Every constraint key that may be attached to a granted capability."
  @spec constraints() :: [constraint()]
  def constraints, do: @constraints

  @doc "Whether `key` is a canonical capability."
  @spec known?(term()) :: boolean()
  def known?(key) when is_binary(key), do: key in @all
  def known?(_key), do: false

  @doc """
  Validates a capability manifest, returning the unknown keys.

  Used by the `RoleDefinition` resource and by the seed script, so a manifest
  containing a typo fails at write time rather than silently granting nothing.
  """
  @spec unknown(Enumerable.t()) :: [t()]
  def unknown(keys) do
    keys
    |> Enum.reject(&known?/1)
    |> Enum.sort()
  end

  @doc "Whether every key in `keys` is canonical."
  @spec valid?(Enumerable.t()) :: boolean()
  def valid?(keys), do: unknown(keys) == []

  @doc """
  Whether a capability requires a participant principal.

  Section 23.2 limits self-service capabilities to `principal_type=PARTICIPANT`.
  """
  @spec self_service?(t()) :: boolean()
  def self_service?(key), do: key in @self_service
end
