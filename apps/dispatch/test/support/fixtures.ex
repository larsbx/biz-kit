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

  alias Dispatch.Accounts.{
    Device,
    Organization,
    Participant,
    RoleAssignment,
    RoleDefinition,
    User
  }

  alias Dispatch.Fleet.{Assignment, Load, Stop, StopParty}

  require Ash.Query

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
      # A STOP- or LOAD-scoped profile is meaningless without the subject it is
      # scoped to, so the fixture requires one rather than silently granting a
      # wider scope than the manifest declares.
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

  @doc "An active device registered to `participant`."
  @spec device(Ash.UUID.t(), Participant.t()) :: Device.t()
  def device(tenant, participant) do
    Device
    |> Ash.Changeset.for_create(:register, %{
      tenant_id: tenant,
      participant_id: participant.id,
      installation_id: unique("installation"),
      public_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  @doc """
  A planned operational assignment for `operator`.

  Named `assignment_record` because `assignment/5` above builds a *role*
  assignment. The two are different things Section 22 keeps apart: authority
  versus a trip.
  """
  @spec assignment_record(Ash.UUID.t(), Organization.t(), Participant.t(), keyword()) ::
          Assignment.t()
  def assignment_record(tenant, org, operator, opts \\ []) do
    load =
      Keyword.get_lazy(opts, :load, fn ->
        Load
        |> Ash.Changeset.for_create(:create_load, %{
          tenant_id: tenant,
          carrier_organization_id: org.id,
          external_reference: unique("LOAD")
        })
        |> Ash.create!(authorize?: false, tenant: tenant)
      end)

    Assignment
    |> Ash.Changeset.for_create(:plan, %{
      tenant_id: tenant,
      load_id: load.id,
      operator_participant_id: operator.id,
      starts_at: Keyword.get(opts, :starts_at, DateTime.utc_now())
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  @doc "The role definition an existing assignment was granted from."
  @spec role_definition_for(Ash.UUID.t(), RoleAssignment.t()) :: RoleDefinition.t()
  def role_definition_for(tenant, %RoleAssignment{} = assignment) do
    Ash.get!(RoleDefinition, assignment.role_definition_id, authorize?: false, tenant: tenant)
  end

  @doc "An organization of `kind` in `tenant`."
  @spec organization(Ash.UUID.t(), atom()) :: Organization.t()
  def organization(_tenant, kind) do
    Organization
    |> Ash.Changeset.for_create(:register, %{name: unique(to_string(kind)), kind: kind})
    |> Ash.create!(authorize?: false)
  end

  @doc "A load for `carrier`, with whatever commercial terms a test needs."
  @spec load(Ash.UUID.t(), Organization.t(), keyword()) :: Load.t()
  def load(tenant, carrier, opts \\ []) do
    Load
    |> Ash.Changeset.for_create(
      :create_load,
      %{
        tenant_id: tenant,
        carrier_organization_id: carrier.id,
        external_reference: unique("LOAD")
      }
      |> Map.merge(Map.new(Keyword.take(opts, ~w(commodity_text currency agreed_rate_minor)a)))
    )
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  @doc "A stop on `load`."
  @spec stop(Ash.UUID.t(), Load.t(), atom(), keyword()) :: Stop.t()
  def stop(tenant, load, kind, opts \\ []) do
    Stop
    |> Ash.Changeset.for_create(:add, %{
      tenant_id: tenant,
      load_id: load.id,
      sequence: Keyword.get(opts, :sequence, 1),
      kind: kind,
      address_text: Keyword.get(opts, :address_text, unique("address")),
      window_start: Keyword.get(opts, :window_start, DateTime.utc_now()),
      window_end: Keyword.get(opts, :window_end, DateTime.add(DateTime.utc_now(), 3600, :second)),
      contact_name: Keyword.get(opts, :contact_name, "Gate"),
      contact_phone_e164: Keyword.get(opts, :contact_phone_e164)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  @doc "An active party relationship between `organization` and `stop`."
  @spec stop_party(Ash.UUID.t(), Stop.t(), Organization.t(), atom()) :: StopParty.t()
  def stop_party(tenant, stop, organization, relationship) do
    StopParty
    |> Ash.Changeset.for_create(:add, %{
      tenant_id: tenant,
      stop_id: stop.id,
      organization_id: organization.id,
      relationship: relationship,
      starts_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
  end

  @doc """
  Ends every active party relationship between `organization` and `stop`.

  Section 33.2 requires that removing the relationship invalidate access
  immediately, so a test needs to be able to remove it mid-flight.
  """
  @spec end_stop_party(Ash.UUID.t(), Stop.t(), Organization.t()) :: :ok
  def end_stop_party(tenant, stop, organization) do
    StopParty
    |> Ash.Query.filter(stop_id == ^stop.id and organization_id == ^organization.id)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.each(fn party ->
      party
      |> Ash.Changeset.for_update(:end_relationship, %{})
      |> Ash.update!(authorize?: false, tenant: tenant)
    end)
  end

  @doc "Revokes a role assignment, so a test can end a grant mid-flight."
  @spec revoke(Ash.UUID.t(), RoleAssignment.t()) :: RoleAssignment.t()
  def revoke(tenant, %RoleAssignment{} = assignment) do
    assignment
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(authorize?: false, tenant: tenant)
  end

  # Read from the manifest rather than guessed. Section 23.2 declares each
  # profile's scope type there, and a fixture that assumed `ORGANIZATION` for
  # everything but `DRIVER` would grant `SHIPPER` a wider scope than the
  # specification gives it — which is exactly the kind of test-only over-grant
  # that makes an authorization test pass for the wrong reason.
  defp scope_for(key) do
    {:ok, manifest} = SeedManifest.fetch(key)
    manifest.scope_type
  end
end
