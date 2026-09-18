defmodule Dispatch.Support.Fixtures do
  @moduledoc """
  The minimum world an authorization test needs: an organization, a person, a
  seeded role definition, and one active assignment.

  Shared rather than repeated per test file, because these fixtures encode the
  seeded capability matrix of Section 23.2. Two copies would drift, and the copy
  a test happened to use would decide whether it was testing the real role.

  Everything here uses `authorize?: false` on purpose: a fixture is not an
  externally initiated action, and building the world under the policies that
  the world's existence is a precondition for is circular. Section 21.1's
  prohibition is about the running system, and `scripts/check-invariants.sh`
  excludes test code for exactly this reason.
  """

  alias Dispatch.Access.{Actor, SeedManifest}
  alias Dispatch.Accounts.{Organization, Participant, RoleAssignment, RoleDefinition, User}

  @doc "A name-unique suffix, so fixtures can be built repeatedly in one run."
  @spec unique(String.t()) :: String.t()
  def unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc "A carrier organization. Its ID is the tenant (ADR-0005)."
  @spec carrier() :: Organization.t()
  def carrier do
    Organization
    |> Ash.Changeset.for_create(:register, %{name: unique("Carrier"), kind: :CARRIER})
    |> Ash.create!(authorize?: false)
  end

  @doc """
  A user and their participant in `tenant`.

  Returns both: an HTTP test needs the user's `oidc_subject` to mint a token,
  and a domain test needs the participant.

  Pass `user:` to enrol an *existing* user in another tenant. Users are global
  and participants are not (ADR-0005), so one person holding authority in two
  operating organizations is two participants sharing one user — which is the
  shape that makes role-assignment selection interesting.
  """
  @spec person(Ash.UUID.t(), Organization.t(), keyword()) ::
          %{user: User.t(), participant: Participant.t()}
  def person(tenant, org, opts \\ []) do
    name = Keyword.get(opts, :display_name, "Person")
    user = Keyword.get_lazy(opts, :user, fn -> register(opts, name) end)

    participant =
      Participant
      |> Ash.Changeset.for_create(:enroll, %{
        tenant_id: tenant,
        user_id: user.id,
        home_organization_id: org.id,
        public_name: name
      })
      |> Ash.create!(authorize?: false, tenant: tenant)

    %{user: user, participant: participant}
  end

  defp register(opts, name) do
    User
    |> Ash.Changeset.for_create(:register, %{
      oidc_subject: Keyword.get(opts, :oidc_subject, unique("sub")),
      display_name: name
    })
    |> Ash.create!(authorize?: false)
  end

  @doc "Just the participant, for tests that never authenticate as them."
  @spec participant(Ash.UUID.t(), Organization.t()) :: Participant.t()
  def participant(tenant, org), do: person(tenant, org).participant

  @doc """
  The seeded role definition for `key` in `tenant`, created once per tenant.

  Seeded from `Dispatch.Access.SeedManifest`, which holds Section 23.2's matrix
  as data, so a test grants the capabilities the specification states rather
  than the ones the test author remembered.
  """
  @spec role_definition(Ash.UUID.t(), String.t()) :: RoleDefinition.t()
  def role_definition(tenant, key) do
    {:ok, manifest} = SeedManifest.fetch(key)

    RoleDefinition
    |> Ash.Changeset.for_create(:seed, %{
      tenant_id: tenant,
      key: manifest.key,
      label: manifest.label,
      capabilities_json: manifest.capabilities,
      constraints_json: manifest.constraints,
      profile_module: inspect(manifest.profile_module)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  @doc "An active role assignment of `key` for `subject`, with its definition loaded."
  @spec assignment(Ash.UUID.t(), Organization.t(), Participant.t(), String.t(), keyword()) ::
          RoleAssignment.t()
  def assignment(tenant, org, subject, key, opts \\ []) do
    definition = Keyword.get_lazy(opts, :definition, fn -> role_definition(tenant, key) end)

    RoleAssignment
    |> Ash.Changeset.for_create(:grant, %{
      tenant_id: tenant,
      principal_type: :PARTICIPANT,
      principal_id: subject.id,
      organization_id: org.id,
      role_definition_id: definition.id,
      scope_type: Keyword.get(opts, :scope_type, scope_for(key)),
      scope_id: Keyword.get(opts, :scope_id),
      starts_at: Keyword.get(opts, :starts_at, DateTime.add(DateTime.utc_now(), -3600, :second)),
      ends_at: Keyword.get(opts, :ends_at)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
    |> Ash.load!([:role_definition], authorize?: false, tenant: tenant)
  end

  @doc "An actor holding one active assignment of `key`."
  @spec actor(Ash.UUID.t(), Organization.t(), Participant.t(), String.t(), keyword()) :: Actor.t()
  def actor(tenant, org, subject, key, opts \\ []) do
    {:ok, actor} = Actor.from_assignment(assignment(tenant, org, subject, key, opts))
    actor
  end

  defp scope_for("DRIVER"), do: :SELF
  defp scope_for(_organization_wide), do: :ORGANIZATION
end
