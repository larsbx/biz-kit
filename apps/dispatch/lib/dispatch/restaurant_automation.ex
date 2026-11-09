defmodule Dispatch.RestaurantAutomation do
  @moduledoc """
  Reconciles the restaurant's signed work with Dispatch's existing load and
  assignment records. The ledger is the retry source. A trip can be planned
  before the handoff, but may only be activated after signed acceptance.
  """

  use GenServer
  require Ash.Query
  require Logger

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.RoleAssignment
  alias Dispatch.Fleet.{Assignment, Load}
  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.Operations.Board
  alias Dispatch.{Repo, RestaurantDelivery}

  @poll_ms 5_000

  def enabled?(source \\ :restaurant), do: RestaurantDelivery.env(source, "AUTOMATED") == "true"

  def child_spec(source) do
    %{id: {__MODULE__, source}, start: {__MODULE__, :start_link, [source]}}
  end

  def start_link(source), do: GenServer.start_link(__MODULE__, source)

  @impl true
  def init(source) do
    Process.send_after(self(), :poll, 0)
    {:ok, {source, ""}}
  end

  @impl true
  def handle_info(:poll, {source, cursor}) do
    next =
      case poll(cursor, source) do
        {:ok, next} ->
          next || ""

        {:error, _reason} ->
          Logger.warning("restaurant dispatch automation could not read work")
          cursor
      end

    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, {source, next}}
  end

  @doc false
  def poll(cursor, source \\ :restaurant) do
    with {:ok, config} <- configuration(source),
         {:ok, actor} <- actor(config),
         {:ok, %{"jobs" => jobs, "next" => next}} when is_list(jobs) <-
           RestaurantDelivery.work(config, cursor) do
      Enum.each(jobs, fn job ->
        case reconcile(actor, config, job) do
          :ok ->
            :ok

          {:error, :courier_unavailable} ->
            :ok

          {:error, _reason} ->
            Logger.warning("restaurant dispatch handoff requires retry or review",
              order_id: job["order_id"]
            )
        end
      end)

      {:ok, next}
    end
  end

  defp configuration(source) do
    with true <- enabled?(source),
         {:ok, scope} <- RestaurantDelivery.configuration(source),
         {:ok, service} <- uuid_env(source, "SERVICE_ROLE"),
         {:ok, courier} <- uuid_env(source, "COURIER"),
         {:ok, site} <- text_env(source, "SITE"),
         {:ok, pickup} <- text_env(source, "PICKUP"),
         {:ok, dropoff} <- text_env(source, "DROPOFF") do
      {:ok,
       Map.merge(scope, %{
         service: service,
         courier: courier,
         site: site,
         pickup: pickup,
         dropoff: dropoff
       })}
    else
      _ -> {:error, :invalid_automation_configuration}
    end
  end

  defp uuid_env(source, name), do: Ecto.UUID.cast(RestaurantDelivery.env(source, name))

  defp text_env(source, name) do
    case RestaurantDelivery.env(source, name) do
      text when is_binary(text) and byte_size(text) in 1..500 ->
        if String.trim(text) != "", do: {:ok, text}, else: :error

      _ ->
        :error
    end
  end

  defp actor(config) do
    # Bootstrap one configured service role. Board revalidates and audits every write.
    with {:ok, %RoleAssignment{principal_type: :SERVICE, scope_type: :ORGANIZATION} = role} <-
           Ash.get(RoleAssignment, config.service,
             tenant: config.tenant,
             authorize?: false,
             load: [:role_definition]
           ),
         {:ok, actor} <- Actor.from_assignment(role),
         {:ok, actor} <- PrincipalResolution.authorize(actor, "assignment.update.status") do
      {:ok, actor}
    else
      _ -> {:error, :unauthorized_service}
    end
  end

  defp reconcile(actor, %{site: site} = config, %{
         "site" => site,
         "phase" => "requested",
         "order_id" => order
       }) do
    with {:ok, {load, trip}} <- prepare(actor, config, order) do
      command = %{
        "op" => "accept",
        "order_id" => order,
        "load_id" => load.id,
        "assignment_id" => trip.id,
        "command_id" =>
          "accept-" <> Base.url_encode64(:crypto.hash(:sha256, order), padding: false),
        "expected_version" => 0
      }

      case RestaurantDelivery.publish_automated(command, config) do
        {:ok, _} ->
          reconcile(actor, config, %{
            "site" => site,
            "phase" => "accepted",
            "order_id" => order,
            "load_id" => load.id,
            "assignment_id" => trip.id
          })

        {:error, {:restaurant_refused, 422, body}} = error ->
          if Jason.decode(body) == {:ok, %{"error" => "delivery_order_not_ready"}},
            do: advance(actor, trip, "cancel", :PLANNED, :CANCELLED),
            else: error

        {:error, _} = error ->
          error
      end
    end
  end

  defp reconcile(actor, %{site: site} = config, %{"site" => site, "phase" => phase} = job)
       when phase in ["accepted", "delivered"] do
    with {:ok, load} <- Board.load(actor, job["load_id"]),
         true <- load.external_reference == reference(config, job["order_id"]),
         %Assignment{} = trip <- Enum.find(load.assignments, &(&1.id == job["assignment_id"])),
         true <- trip.operator_participant_id == config.courier do
      case phase do
        "accepted" ->
          with {:ok, _} <- prepare_load(actor, config, job["order_id"], load),
               :ok <- available?(config, load) do
            advance(actor, trip, "activate", :PLANNED, :ACTIVE)
          end

        "delivered" ->
          advance(actor, trip, "complete", :ACTIVE, :COMPLETED)
      end
    else
      _ -> {:error, :bound_assignment_unavailable}
    end
  end

  defp reconcile(actor, %{site: site} = config, %{
         "site" => site,
         "phase" => "cancelled",
         "order_id" => order
       }) do
    with {:ok, load} <- find_load(actor, reference(config, order)) do
      case load do
        nil ->
          :ok

        %{assignments: []} ->
          :ok

        %{assignments: [%{operator_participant_id: driver} = trip]}
        when driver == config.courier ->
          advance(actor, trip, "cancel", :PLANNED, :CANCELLED)

        _ ->
          {:error, :ambiguous_delivery_assignment}
      end
    end
  end

  defp reconcile(_, _, _), do: {:error, :wrong_delivery_site}

  @doc false
  def prepare(actor, config, order) do
    Repo.transaction(fn ->
      # Both locks and all Board writes use the same Repo transaction. A
      # crash leaves a complete planned trip or no partial load/stops.
      lock(reference(config, order))
      lock(Enum.join(["restaurant-courier", config.tenant, config.courier], ":"))

      with {:ok, load} <- find_load(actor, reference(config, order)),
           :ok <- available?(config, load),
           {:ok, load} <- prepare_load(actor, config, order, load),
           {:ok, trip} <- planned_trip(actor, config, load) do
        {load, trip}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock(key) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))", [key])
  end

  defp find_load(actor, reference) do
    carrier = actor.role_assignment.organization_id

    # Only locate the ID in this service's tenant/carrier; Board authorizes
    # reads and every mutation against that same service role.
    query =
      Load
      |> Ash.Query.filter(
        external_reference == ^reference and carrier_organization_id == ^carrier
      )
      |> Ash.Query.limit(2)

    case Ash.read(query, tenant: actor.tenant_id, authorize?: false) do
      {:ok, []} -> {:ok, nil}
      {:ok, [load]} -> Board.load(actor, load.id)
      {:ok, _} -> {:error, :ambiguous_delivery_load}
      {:error, _} = error -> error
    end
  end

  defp available?(config, load) do
    courier = config.courier
    own_id = if load, do: load.id

    query =
      Assignment
      |> Ash.Query.filter(operator_participant_id == ^courier and status in [:PLANNED, :ACTIVE])

    query = if own_id, do: Ash.Query.filter(query, load_id != ^own_id), else: query

    case Ash.read(query |> Ash.Query.limit(1), tenant: config.tenant, authorize?: false) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :courier_unavailable}
      {:error, _} = error -> error
    end
  end

  defp prepare_load(actor, config, order, nil) do
    with {:ok, load} <-
           Board.create_load(actor, %{"external_reference" => reference(config, order)}),
         {:ok, _} <-
           Board.add_stop(actor, load.id, %{"kind" => "PICKUP", "address_text" => config.pickup}) do
      Board.add_stop(actor, load.id, %{"kind" => "DELIVERY", "address_text" => config.dropoff})
    end
  end

  defp prepare_load(_, config, _, load) do
    if Enum.map(load.stops, &{&1.kind, &1.address_text}) == [
         {:PICKUP, config.pickup},
         {:DELIVERY, config.dropoff}
       ],
       do: {:ok, load},
       else: {:error, :delivery_stops_changed}
  end

  defp planned_trip(actor, config, %{assignments: []} = load) do
    with {:ok, updated} <-
           Board.plan(actor, load.id, %{"operator_participant_id" => config.courier}) do
      existing_trip(config, updated)
    end
  end

  defp planned_trip(_, config, load), do: existing_trip(config, load)

  defp existing_trip(config, %{
         assignments: [%{status: :PLANNED, operator_participant_id: driver} = trip]
       })
       when driver == config.courier,
       do: {:ok, trip}

  defp existing_trip(_, _), do: {:error, :ambiguous_delivery_assignment}

  defp advance(_actor, %{status: target}, _action, _source, target), do: :ok

  defp advance(actor, %{status: source} = trip, action, source, _target) do
    with {:ok, _} <- Board.transition(actor, trip.id, action, trip.version), do: :ok
  end

  defp advance(_, _, _, _, _), do: {:error, :unexpected_assignment_state}

  defp reference(config, order),
    do:
      RestaurantDelivery.load_reference(
        config.chapter,
        config.merchant,
        order,
        Map.get(config, :source, :restaurant)
      )
end
