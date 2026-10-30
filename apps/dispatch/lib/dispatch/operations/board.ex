defmodule Dispatch.Operations.Board do
  @moduledoc """
  The carrier's dispatch board: its loads with their stops and trips, the
  fleet it plans with, and the writes a dispatcher makes (`/v1/operations`).

  Every function is confined to the actor's organization, as the carrier. A
  load is the organization's when it is the carrier on it; a driver, vehicle or
  trailer when it belongs to it. Anything else answers `:not_found`, so the
  board discloses nothing about another carrier's work.

  The writes go beyond Section 23.2's table (see
  `Dispatch.Access.Capabilities`): a dispatcher creates its own loads and
  stops and plans and moves its own trips. Nothing here sets a rate, names a
  broker, or accepts a load for another organization. Each write runs in one
  transaction with its audit event, so a change without its record cannot
  commit.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.{Participant, RoleAssignment}
  alias Dispatch.Audit.AuditEvent
  alias Dispatch.Fleet.{Assignment, Load, Stop, Trailer, Vehicle}

  @type refusal ::
          :forbidden | :not_found | :stale | {:invalid, String.t()}

  @transitions %{"activate" => :activate, "complete" => :complete, "cancel" => :cancel}

  @doc "The organization's loads, newest first, each with its stops and trips."
  @spec loads(Actor.t()) :: {:ok, [Load.t()]} | {:error, :forbidden}
  def loads(%Actor{} = actor) do
    with :ok <- can(actor, "load.read"),
         :ok <- can(actor, "assignment.read") do
      loads =
        Load
        |> Ash.Query.filter(carrier_organization_id == ^organization(actor))
        |> Ash.Query.sort(created_at: :desc)
        |> Ash.Query.load([:stops, :assignments])
        # REVIEWED-UNAUTHORIZED: Load has no policies; the carrier filter on the
        # actor's organization is the authorization, checked above.
        |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
        |> Enum.map(&ordered/1)

      {:ok, loads}
    end
  end

  @doc "One of the organization's loads, with its stops and trips."
  @spec load(Actor.t(), String.t()) :: {:ok, Load.t()} | {:error, :forbidden | :not_found}
  def load(%Actor{} = actor, load_id) do
    with :ok <- can(actor, "load.read"),
         :ok <- can(actor, "assignment.read"),
         {:ok, load} <- own_load(actor, load_id) do
      {:ok, load |> Ash.load!([:stops, :assignments], authorize?: false) |> ordered()}
    end
  end

  @doc """
  Who and what a trip can be planned with: the organization's active drivers,
  vehicles and trailers.
  """
  @spec fleet(Actor.t()) ::
          {:ok, %{drivers: [Participant.t()], vehicles: [Vehicle.t()], trailers: [Trailer.t()]}}
          | {:error, :forbidden}
  def fleet(%Actor{} = actor) do
    with :ok <- can(actor, "fleet.read") do
      {:ok,
       %{
         drivers: Enum.map(drivers(actor), & &1.participant),
         vehicles: equipment(actor, Vehicle),
         trailers: equipment(actor, Trailer)
       }}
    end
  end

  @doc "Creates a DRAFT load with this organization as the carrier."
  @spec create_load(Actor.t(), map()) :: {:ok, Load.t()} | {:error, refusal()}
  def create_load(%Actor{} = actor, params) do
    with :ok <- can(actor, "load.create") do
      transaction(fn ->
        Load
        |> Ash.Changeset.for_create(:create_load, %{
          tenant_id: actor.tenant_id,
          carrier_organization_id: organization(actor),
          external_reference: params["external_reference"],
          commodity_text: params["commodity_text"]
        })
        # REVIEWED-UNAUTHORIZED: authorized above; the carrier is the actor's
        # own organization, never a parameter.
        |> Ash.create(authorize?: false, tenant: actor.tenant_id)
        |> audited(actor, "load.created", "load", & &1.id)
      end)
      |> reloaded(actor)
    end
  end

  @doc "Changes a load's commodity text and reference, if it is still at `expected_version`."
  @spec update_load(Actor.t(), String.t(), map()) :: {:ok, Load.t()} | {:error, refusal()}
  def update_load(%Actor{} = actor, load_id, params) do
    with :ok <- can(actor, "load.update.nonbinding"),
         {:ok, load} <- own_load(actor, load_id),
         :ok <- current(load, params["expected_version"]) do
      transaction(fn ->
        load
        |> Ash.Changeset.for_update(:update_nonbinding, %{
          commodity_text: params["commodity_text"],
          external_reference: params["external_reference"],
          expected_version: params["expected_version"]
        })
        # REVIEWED-UNAUTHORIZED: authorized above against the carrier filter.
        |> Ash.update(authorize?: false, tenant: actor.tenant_id)
        |> audited(actor, "load.updated", "load", & &1.id)
      end)
      |> reloaded(actor)
    end
  end

  @doc "Appends a stop to one of the organization's loads, after its last."
  @spec add_stop(Actor.t(), String.t(), map()) :: {:ok, Load.t()} | {:error, refusal()}
  def add_stop(%Actor{} = actor, load_id, params) do
    with :ok <- can(actor, "stop.add"),
         {:ok, load} <- own_load(actor, load_id),
         {:ok, kind} <- one_of(params["kind"], ~w(PICKUP DELIVERY OTHER), "kind") do
      transaction(fn ->
        # Serialized per load, so two stops added at once cannot take one
        # sequence number.
        lock!("load-stops:" <> load.id)

        Stop
        |> Ash.Changeset.for_create(:add, %{
          tenant_id: actor.tenant_id,
          load_id: load.id,
          sequence: next_sequence(actor, load.id),
          kind: kind,
          address_text: params["address_text"],
          window_start: params["window_start"],
          window_end: params["window_end"],
          contact_name: params["contact_name"],
          contact_phone_e164: blank_to_nil(params["contact_phone_e164"])
        })
        # REVIEWED-UNAUTHORIZED: authorized above; the load is the actor's own.
        |> Ash.create(authorize?: false, tenant: actor.tenant_id)
        |> audited(actor, "stop.added", "load", fn _stop -> load.id end)
      end)
      |> then(fn
        {:ok, _stop} -> load(actor, load.id)
        error -> error
      end)
    end
  end

  @doc """
  Plans a trip for one of the organization's loads with one of its drivers and,
  optionally, its vehicle and trailer. Planning does not start the trip.
  """
  @spec plan(Actor.t(), String.t(), map()) :: {:ok, Load.t()} | {:error, refusal()}
  def plan(%Actor{} = actor, load_id, params) do
    with :ok <- can(actor, "assignment.plan"),
         {:ok, load} <- own_load(actor, load_id),
         {:ok, driver} <- own_driver(actor, params["operator_participant_id"]),
         {:ok, vehicle_id} <- own_equipment(actor, Vehicle, params["vehicle_id"]),
         {:ok, trailer_id} <- own_equipment(actor, Trailer, params["trailer_id"]) do
      transaction(fn ->
        Assignment
        |> Ash.Changeset.for_create(:plan, %{
          tenant_id: actor.tenant_id,
          load_id: load.id,
          operator_participant_id: driver.participant.id,
          # The driver's own role decides exclusivity; see DeriveOperatorExclusivity.
          operator_role_assignment_id: driver.role_assignment.id,
          vehicle_id: vehicle_id,
          trailer_id: trailer_id,
          starts_at: params["starts_at"] || actor.at,
          ends_at: params["ends_at"]
        })
        # REVIEWED-UNAUTHORIZED: authorized above; load, driver and equipment
        # were each confirmed to be the actor's organization's.
        |> Ash.create(authorize?: false, tenant: actor.tenant_id)
        |> audited(actor, "assignment.planned", "assignment", & &1.id)
      end)
      |> then(fn
        {:ok, _trip} -> load(actor, load.id)
        error -> error
      end)
    end
  end

  @doc """
  Moves a trip: `activate`, `complete` or `cancel`, if it is still at
  `expected_version`.
  """
  @spec transition(Actor.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, Load.t()} | {:error, refusal()}
  def transition(%Actor{} = actor, assignment_id, action, expected_version) do
    with :ok <- can(actor, "assignment.update.status"),
         {:ok, action} <- transition_action(action),
         {:ok, trip} <- own_trip(actor, assignment_id) do
      transaction(fn ->
        # Ordinary UPDATEs take this lock too. Re-read ownership, version and
        # source state after acquiring it, in the mutation/audit transaction.
        lock_trip!(actor, trip.id)

        with {:ok, trip} <- own_trip(actor, trip.id),
             :ok <- current(trip, expected_version),
             :ok <- permitted(trip.status, action) do
          trip
          |> Ash.Changeset.for_update(action, %{expected_version: expected_version})
          # REVIEWED-UNAUTHORIZED: authorized above; the trip's load is the actor's.
          |> Ash.update(authorize?: false, tenant: actor.tenant_id)
          |> audited(actor, "assignment.#{action}d", "assignment", & &1.id)
        end
      end)
      |> then(fn
        {:ok, moved} -> load(actor, moved.load_id)
        error -> error
      end)
    end
  end

  defp can(actor, capability),
    do: if(Actor.can?(actor, capability), do: :ok, else: {:error, :forbidden})

  defp organization(%Actor{role_assignment: %RoleAssignment{organization_id: id}}), do: id

  defp own_load(actor, id) when is_binary(id) do
    with {:ok, uuid} <- uuid(id),
         # REVIEWED-UNAUTHORIZED: matched to the actor's organization below.
         {:ok, %Load{} = load} <- Ash.get(Load, uuid, authorize?: false, tenant: actor.tenant_id),
         true <- load.carrier_organization_id == organization(actor) do
      {:ok, load}
    else
      _ -> {:error, :not_found}
    end
  end

  defp own_load(_actor, _id), do: {:error, :not_found}

  defp own_trip(actor, id) when is_binary(id) do
    with {:ok, uuid} <- uuid(id),
         # REVIEWED-UNAUTHORIZED: its load is matched to the organization below.
         {:ok, %Assignment{} = trip} <-
           Ash.get(Assignment, uuid, authorize?: false, tenant: actor.tenant_id),
         {:ok, _load} <- own_load(actor, trip.load_id) do
      {:ok, trip}
    else
      _ -> {:error, :not_found}
    end
  end

  defp own_trip(_actor, _id), do: {:error, :not_found}

  defp own_driver(actor, id) do
    case Enum.find(drivers(actor), &(&1.participant.id == id)) do
      nil -> {:error, {:invalid, "operator_participant_id is not a driver of this organization"}}
      driver -> {:ok, driver}
    end
  end

  defp own_equipment(_actor, _resource, blank) when blank in [nil, ""], do: {:ok, nil}

  defp own_equipment(actor, resource, id) do
    case Enum.find(equipment(actor, resource), &(&1.id == id)) do
      nil ->
        {:error, {:invalid, "#{label(resource)} is not active equipment of this organization"}}

      unit ->
        {:ok, unit.id}
    end
  end

  defp label(Vehicle), do: "vehicle_id"
  defp label(Trailer), do: "trailer_id"

  # Drivers: the organization's active participants holding an active role
  # whose profile drives (`assignment.read.self`), paired with that role, which
  # planning needs to derive exclusivity.
  defp drivers(actor) do
    held =
      RoleAssignment
      |> Ash.Query.for_read(:active, %{at: actor.at})
      |> Ash.Query.filter(
        organization_id == ^organization(actor) and principal_type == :PARTICIPANT
      )
      |> Ash.Query.load(:role_definition)
      # REVIEWED-UNAUTHORIZED: the organization's own roster, for its dispatcher.
      |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
      |> Enum.filter(&Dispatch.Access.can?(&1, "assignment.read.self", actor.at))
      |> Map.new(&{&1.principal_id, &1})

    Participant
    |> Ash.Query.filter(home_organization_id == ^organization(actor) and status == :ACTIVE)
    |> Ash.Query.sort(:public_name)
    # REVIEWED-UNAUTHORIZED: the organization's own roster, for its dispatcher.
    |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
    |> Enum.flat_map(fn participant ->
      case Map.fetch(held, participant.id) do
        {:ok, role} -> [%{participant: participant, role_assignment: role}]
        :error -> []
      end
    end)
  end

  defp equipment(actor, resource) do
    resource
    |> Ash.Query.filter(organization_id == ^organization(actor) and status == :ACTIVE)
    |> Ash.Query.sort(:unit_number)
    # REVIEWED-UNAUTHORIZED: the organization's own equipment, for its dispatcher.
    |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
  end

  defp next_sequence(actor, load_id) do
    Stop
    |> Ash.Query.filter(load_id == ^load_id)
    # REVIEWED-UNAUTHORIZED: the load was confirmed to be the actor's.
    |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
    |> Enum.map(& &1.sequence)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp ordered(%Load{} = load) do
    %{
      load
      | stops: Enum.sort_by(load.stops, & &1.sequence),
        assignments: Enum.sort_by(load.assignments, &{&1.starts_at, &1.id}, &<=/2)
    }
  end

  defp current(_record, nil), do: :ok
  defp current(%{version: version}, version), do: :ok
  defp current(_record, _expected), do: {:error, :stale}

  defp permitted(:PLANNED, action) when action in [:activate, :cancel], do: :ok
  defp permitted(:ACTIVE, action) when action in [:complete, :cancel], do: :ok

  defp permitted(status, action),
    do: {:error, {:invalid, "cannot #{action} a #{status} trip"}}

  defp lock_trip!(actor, id) do
    from(a in "assignments",
      where: a.id == type(^id, :binary_id) and a.tenant_id == type(^actor.tenant_id, :binary_id),
      select: a.id,
      lock: "FOR UPDATE"
    )
    |> Dispatch.Repo.one()
  end

  defp transition_action(action) do
    case Map.fetch(@transitions, action) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid, "action must be one of activate, complete, cancel"}}
    end
  end

  defp one_of(value, allowed, field) do
    if value in allowed,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, {:invalid, "#{field} must be one of #{Enum.join(allowed, ", ")}"}}
  end

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp lock!(key) do
    Dispatch.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))", [key])
  end

  defp transaction(fun) do
    Dispatch.Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Dispatch.Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # Writes the audit event for a successful change in the same transaction.
  defp audited({:ok, record}, actor, event_type, subject_type, subject_id) do
    AuditEvent
    |> Ash.Changeset.for_create(:record, %{
      tenant_id: actor.tenant_id,
      event_type: event_type,
      actor_type: actor.principal_type,
      actor_id: actor.principal_id,
      role_assignment_id: actor.role_assignment.id,
      subject_type: subject_type,
      subject_id: subject_id.(record),
      occurred_at: actor.at,
      correlation_id: Ash.UUID.generate(),
      payload_json: %{"record_id" => record.id}
    })
    # REVIEWED-UNAUTHORIZED: audit append follows an authorized mutation.
    |> Ash.create!(authorize?: false, tenant: actor.tenant_id)

    {:ok, record}
  end

  defp audited({:error, _} = error, _actor, _event_type, _subject_type, _subject_id), do: error

  defp reloaded({:ok, %Load{id: id}}, actor), do: load(actor, id)
  defp reloaded(error, _actor), do: error

  # The database and Ash speak in exceptions; the board answers in refusals.
  defp refusal(reason) when reason in [:forbidden, :not_found, :stale], do: reason
  defp refusal({:invalid, _message} = invalid), do: invalid

  defp refusal(%Ash.Error.Invalid{} = error) do
    message = Exception.message(error)

    cond do
      message =~ "STALE_VERSION" -> :stale
      message =~ "one_active" or message =~ "unique" -> {:invalid, conflict(message)}
      true -> {:invalid, first_line(message)}
    end
  end

  defp refusal(other), do: {:invalid, first_line(inspect(other))}

  defp conflict(_message),
    do: "the driver already has an active trip; complete or cancel it first"

  defp first_line(message) do
    message
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 =~ ~r/^\s*$/))
    |> Enum.at(1, message)
  end
end
