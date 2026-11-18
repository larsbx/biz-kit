defmodule DispatchCore.Admission do
  @moduledoc """
  Dispatch assignments as signed ledger events: the first Dispatch surface on
  the common append path (consolidation step 4). Pure, in the shape of
  `RestaurantCore.Admission`: the substrate registers the types, runs `check/2`
  inside its single appender and folds admitted events with `fold/2`, so
  concurrent activations are judged one at a time against the advancing state.

    * `DispatchDispatcherGrantedV1`, signed by a declared governance key, binds
      a dispatcher key to a tenant.
    * `DispatchAssignmentPlannedV1`, signed by a granted dispatcher, plans an
      assignment of an operator, and optionally a vehicle and a trailer, to a
      load.
    * `DispatchAssignmentTransitionV1`, signed by a granted dispatcher, moves
      it with an expected version: `activate` (PLANNED → ACTIVE), `complete`
      (ACTIVE → COMPLETED) or `cancel` (PLANNED or ACTIVE → CANCELLED).

  The rule of `Dispatch.Fleet.Assignment`'s partial unique indexes holds at
  activation: an operator, a vehicle and a trailer are each on at most one
  ACTIVE assignment per tenant. Every operator is exclusive here, the
  restrictive default: the role profiles that permit concurrency are not on
  the ledger yet. The trusted context is the grant, never the payload.
  """

  @grant "DispatchDispatcherGrantedV1"
  @planned "DispatchAssignmentPlannedV1"
  @transition "DispatchAssignmentTransitionV1"
  @dispatcher "dispatch_dispatcher"

  @moves %{
    "activate" => {[:PLANNED], :ACTIVE},
    "complete" => {[:ACTIVE], :COMPLETED},
    "cancel" => {[:PLANNED, :ACTIVE], :CANCELLED}
  }

  def event_types do
    %{
      @grant =>
        spec("governance", "dispatch_dispatchers", ["tenant_id"], %{
          "tenant_id" => :string,
          "dispatcher_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey
        }),
      @planned =>
        spec(
          @dispatcher,
          "dispatch_assignments",
          ["tenant_id", "assignment_id"],
          %{
            "tenant_id" => :string,
            "assignment_id" => :string,
            "load_id" => :string,
            "operator_id" => :string
          },
          %{"vehicle_id" => :string, "trailer_id" => :string}
        ),
      @transition =>
        spec(@dispatcher, "dispatch_assignments", ["tenant_id", "assignment_id"], %{
          "tenant_id" => :string,
          "assignment_id" => :string,
          "expected_version" => :int,
          "action" => :string
        })
    }
  end

  defp spec(role, prefix, stream, required, optional \\ %{}),
    do: %{
      required_roles: [role],
      disclosure_class: :edges,
      stream: {:payload_fields, prefix, stream},
      payload: %{required: required, optional: optional}
    }

  def init, do: %{dispatchers: %{}, tenants: %{}}

  @doc "`:ok` when the event may be appended to a gate holding `role_keys` and `dispatch`."
  def check(env, gate), do: with({:ok, _} <- admit(env, gate.role_keys, gate.dispatch), do: :ok)

  @doc "The dispatch state after an admitted event."
  def fold(env, gate) do
    {:ok, state} = admit(env, gate.role_keys, gate.dispatch)
    state
  end

  @doc "A tenant's assignments by id."
  def assignments(state, chapter, tenant),
    do: get_in(state, [:tenants, {chapter, tenant}, :assignments]) || %{}

  @doc "The assignment holding `kind` (`:operator`, `:vehicle`, `:trailer`) `id` ACTIVE, or nil."
  def active(state, chapter, tenant, kind, id),
    do: get_in(state, [:tenants, {chapter, tenant}, :active, {kind, id}])

  defp admit(%{type: @grant, chapter_id: ch, signers: [signer], payload: p}, keys, state) do
    key = {ch, p["tenant_id"], p["key_id"]}

    cond do
      Map.get(keys[{ch, "governance"}] || %{}, signer.key_id) != signer.pubkey ->
        {:error, :dispatch_governance_not_declared}

      Map.has_key?(state.dispatchers, key) ->
        {:error, :dispatcher_key_already_granted}

      true ->
        {:bytes, pubkey} = p["pubkey"]
        grant = %{dispatcher_id: p["dispatcher_id"], pubkey: pubkey}
        {:ok, put_in(state, [:dispatchers, key], grant)}
    end
  end

  defp admit(%{type: @planned, chapter_id: ch, payload: p} = env, _keys, state) do
    with :ok <- dispatcher(env, state) do
      tenant = tenant(state, ch, p["tenant_id"])

      if Map.has_key?(tenant.assignments, p["assignment_id"]) do
        {:error, :assignment_exists}
      else
        assignment = %{
          status: :PLANNED,
          version: 0,
          load: p["load_id"],
          holds: holds(p)
        }

        {:ok,
         put_tenant(
           state,
           ch,
           p["tenant_id"],
           put_in(tenant, [:assignments, p["assignment_id"]], assignment)
         )}
      end
    end
  end

  defp admit(%{type: @transition, chapter_id: ch, payload: p} = env, _keys, state) do
    tenant = tenant(state, ch, p["tenant_id"])
    id = p["assignment_id"]

    with :ok <- dispatcher(env, state),
         {:ok, {from, to}} <- Map.fetch(@moves, p["action"]) |> or_error(:unknown_action),
         {:ok, a} <- Map.fetch(tenant.assignments, id) |> or_error(:unknown_assignment),
         true <- p["expected_version"] == a.version || {:error, :stale_version},
         true <- a.status in from || {:error, {:illegal_transition, a.status, p["action"]}},
         :ok <- if(to == :ACTIVE, do: free(tenant, a.holds), else: :ok) do
      active =
        case to do
          :ACTIVE -> Enum.reduce(a.holds, tenant.active, &Map.put(&2, &1, id))
          _ when a.status == :ACTIVE -> Map.drop(tenant.active, a.holds)
          _ -> tenant.active
        end

      a = %{a | status: to, version: a.version + 1}

      {:ok,
       put_tenant(state, ch, p["tenant_id"], %{
         tenant
         | active: active,
           assignments: Map.put(tenant.assignments, id, a)
       })}
    end
  end

  defp admit(_, _, _), do: {:error, :unknown_dispatch_event}

  # A dispatcher acts only for the tenant it was granted, with its granted key.
  defp dispatcher(%{chapter_id: ch, signers: [signer], payload: p}, state) do
    case state.dispatchers[{ch, p["tenant_id"], signer.key_id}] do
      %{pubkey: pubkey} when pubkey == signer.pubkey -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp dispatcher(_, _), do: {:error, :forbidden}

  defp holds(p) do
    [operator: p["operator_id"], vehicle: p["vehicle_id"], trailer: p["trailer_id"]]
    |> Enum.reject(fn {_, id} -> is_nil(id) end)
  end

  defp free(tenant, holds) do
    case Enum.find(holds, &Map.has_key?(tenant.active, &1)) do
      nil -> :ok
      {kind, id} -> {:error, {:already_active, kind, id, tenant.active[{kind, id}]}}
    end
  end

  defp tenant(state, ch, t), do: state.tenants[{ch, t}] || %{assignments: %{}, active: %{}}
  defp put_tenant(state, ch, t, tenant), do: put_in(state, [:tenants, {ch, t}], tenant)
  defp or_error({:ok, v}, _), do: {:ok, v}
  defp or_error(:error, reason), do: {:error, reason}
end
