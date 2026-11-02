defmodule CommerceCore.OrderLifecycle do
  @moduledoc """
  Pure order lifecycle and authorized candidate reducer (Eatsbot I₃/I₆).

  `trusted` is host-verified context, never request JSON: merchant, order_id,
  principal, actor class, `allowed_actions` and `granted: true` for this order. The
  host must authenticate it, serialize admission and persist the candidate.
  Home-bound candidates also require the exact `home_id` from `new/3`.
  Authorization precedes inspection of state, history, revision or errors.
  Delivery-owned steps require the separate FulfillmentCore/Dispatch handoff;
  even an administrator cannot dispatch a delivery through an order action.
  No lifecycle state asserts payment or financial settlement.

  `replay/2` checks the mathematical history only, not its provenance or grants.
  """

  alias CommerceCore.Ownership

  @states ~w(placed accepted preparing ready dispatched completed cancelled failed)a
  @fulfillments ~w(delivery pickup dine_in)a
  @terminal ~w(completed cancelled failed)a
  @actions %{
    accept: {:accepted, [:admin, :staff]},
    start_preparing: {:preparing, [:admin, :staff]},
    mark_ready: {:ready, [:admin, :staff]},
    dispatch: {:dispatched, [:admin, :system]},
    complete: {:completed, [:admin, :staff, :system]},
    fail: {:failed, [:admin, :system]},
    cancel: {:cancelled, [:admin, :staff]}
  }
  @edges [
    {:placed, :accepted, :any},
    {:accepted, :preparing, :any},
    {:preparing, :ready, :any},
    {:ready, :dispatched, :delivery},
    {:ready, :completed, :not_delivery},
    {:dispatched, :completed, :delivery},
    {:dispatched, :failed, :delivery},
    {:placed, :cancelled, :any},
    {:accepted, :cancelled, :any},
    {:preparing, :cancelled, :any},
    {:ready, :cancelled, :any}
  ]

  def initial_state, do: :placed
  def states, do: @states
  def terminal_states, do: @terminal
  def terminal?(state), do: state in @terminal

  def next_states(fulfillment, from) when fulfillment in @fulfillments do
    for {^from, to, guard} <- @edges,
        guard == :any or (guard == :delivery and fulfillment == :delivery) or
          (guard == :not_delivery and fulfillment != :delivery),
        do: to
  end

  def next_states(_, _), do: []
  def legal?(fulfillment, from, to), do: to in next_states(fulfillment, from)

  def new(%{home_id: _} = owner, id, fulfillment) do
    with true <- Ownership.valid?(owner),
         {:ok, state} <- new(owner.merchant, id, fulfillment) do
      {:ok, Ownership.stamp(owner, state)}
    else
      _ -> {:error, :invalid_order}
    end
  end

  def new(merchant, id, fulfillment)
      when is_binary(merchant) and byte_size(merchant) > 0 and
             is_binary(id) and byte_size(id) > 0 and fulfillment in @fulfillments do
    {:ok,
     %{
       merchant: merchant,
       id: id,
       fulfillment: fulfillment,
       state: :placed,
       version: 0,
       seen: %{}
     }}
  end

  def new(_, _, _), do: {:error, :invalid_order}

  def authorized?(
        %{granted: true, principal: principal, actor: actor, allowed_actions: actions},
        action
      )
      when is_binary(principal) and byte_size(principal) > 0 and is_list(actions) do
    case Map.get(@actions, action) do
      {_, roles} -> actor in roles and action in actions
      _ -> false
    end
  end

  def authorized?(_, _), do: false

  @doc "Return a candidate or a uniform forbidden result before inspecting protected state."
  def apply(state, trusted, command) do
    action = if is_map(command), do: Map.get(command, :action)

    with true <- authorized?(trusted, action),
         true <- scoped?(state, trusted) do
      apply_authorized(state, trusted, command)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp scoped?(%{home_id: _, id: id} = state, %{order_id: id} = trusted),
    do: Ownership.check(state, trusted) == :ok

  defp scoped?(%{home_id: _}, _), do: false

  defp scoped?(%{merchant: m, id: id}, %{merchant: m, order_id: id} = trusted),
    do: not Map.has_key?(trusted, :home_id)

  defp scoped?(_, _), do: false

  defp apply_authorized(
         state,
         trusted,
         %{id: id, expected_version: revision, action: action} = cmd
       )
       when is_binary(id) and byte_size(id) > 0 do
    binding = {trusted.principal, trusted.actor, cmd}

    case Map.get(state.seen, id) do
      ^binding ->
        {:ok, state, :duplicate}

      nil ->
        {to, _} = Map.fetch!(@actions, action)

        cond do
          revision !== state.version ->
            {:error, :stale_order_version}

          not legal?(state.fulfillment, state.state, to) ->
            {:error, :invalid_transition}

          state.fulfillment == :delivery and to in [:dispatched, :completed, :failed] ->
            {:error, :delivery_owned}

          action in [:cancel, :fail] and not reason?(Map.get(cmd, :reason)) ->
            {:error, :reason_required}

          true ->
            {:ok,
             %{
               state
               | state: to,
                 version: state.version + 1,
                 seen: Map.put(state.seen, id, binding)
             }, :accepted}
        end

      _ ->
        {:error, :idempotency_conflict}
    end
  end

  defp apply_authorized(_, _, _), do: {:error, :invalid_order_command}
  defp reason?(s), do: is_binary(s) and byte_size(s) > 0

  def replay(fulfillment, history) when fulfillment in @fulfillments and is_list(history) do
    history
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, :placed}, fn
      {{from, to}, i}, {:ok, from} ->
        if legal?(fulfillment, from, to),
          do: {:cont, {:ok, to}},
          else: {:halt, {:error, {:illegal, i, from, to}}}

      {_, i}, _ ->
        {:halt, {:error, {:discontinuous, i}}}
    end)
  end

  def replay(_, _), do: {:error, :invalid_history}
end
