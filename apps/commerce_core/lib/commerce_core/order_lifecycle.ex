defmodule CommerceCore.OrderLifecycle do
  @moduledoc """
  Merchant-neutral order lifecycle and authorized candidate reducer (I₃/I₆).

  The core owns the commercial steps; a workflow layer supplies the merchant's
  production stages between acceptance and hand-off (a kitchen's `preparing` and
  `ready`, a shop's `picking` and `packed`). For stages `s₁ … sₙ`, with `last`
  the final stage, or `accepted` when there are none:

      placed → accepted → s₁ → … → sₙ
      last → completed                     (fulfillments other than delivery)
      last → dispatched → completed | failed   (delivery; delivery-owned)
      {placed, accepted, s₁ … sₙ} → cancelled

  `completed`, `cancelled` and `failed` are terminal. Build a workflow once with
  `workflow/1` and pass it first to every call.

  `trusted` is host-verified context, never request JSON: merchant, order_id,
  principal, actor class, `allowed_actions` and `granted: true` for this order. The
  host must authenticate it, serialize admission and persist the candidate.
  Authorization precedes inspection of state, history, revision or errors.
  Delivery-owned steps require the separate FulfillmentCore/Dispatch handoff;
  even an administrator cannot dispatch a delivery through an order action.
  No lifecycle state asserts payment or financial settlement.

  `replay/3` checks the mathematical history only, not its provenance or grants.
  """

  @core_states ~w(placed accepted dispatched completed cancelled failed)a
  @terminal ~w(completed cancelled failed)a
  @delivery_owned ~w(dispatched completed failed)a
  @core_actions %{
    accept: {:accepted, [:admin, :staff]},
    dispatch: {:dispatched, [:admin, :system]},
    complete: {:completed, [:admin, :staff, :system]},
    fail: {:failed, [:admin, :system]},
    cancel: {:cancelled, [:admin, :staff]}
  }

  @type workflow :: %{
          fulfillments: [atom()],
          states: [atom()],
          edges: [{atom(), atom(), :any | :delivery | :not_delivery}],
          actions: %{atom() => {atom(), [atom()]}}
        }

  @doc """
  Builds a workflow from its production stages, in order, as `{action, stage}`
  pairs taken by `stage_roles`, and the fulfillments it offers.
  """
  @spec workflow(map()) :: {:ok, workflow()} | {:error, :invalid_workflow}
  def workflow(%{
        fulfillments: [_ | _] = fulfillments,
        stages: stages,
        stage_roles: [_ | _] = roles
      })
      when is_list(stages) do
    names = Enum.map(stages, &stage_name/1)
    actions = Enum.map(stages, &stage_action/1)

    if Enum.all?(fulfillments ++ names ++ actions ++ roles, &is_atom/1) and
         nil not in names and nil not in actions and
         unique?(fulfillments) and unique?(names) and unique?(actions) and
         Enum.all?(names, &(&1 not in @core_states)) and
         Enum.all?(actions, &(not Map.has_key?(@core_actions, &1))) do
      sequence = [:accepted | names]
      last = List.last(sequence)

      edges =
        [{:placed, :accepted, :any}] ++
          for({from, to} <- Enum.zip(sequence, tl(sequence)), do: {from, to, :any}) ++
          [
            {last, :dispatched, :delivery},
            {last, :completed, :not_delivery},
            {:dispatched, :completed, :delivery},
            {:dispatched, :failed, :delivery}
          ] ++ for(from <- [:placed | sequence], do: {from, :cancelled, :any})

      stage_actions = Map.new(stages, fn {action, stage} -> {action, {stage, roles}} end)

      {:ok,
       %{
         fulfillments: fulfillments,
         states: [:placed, :accepted | names] ++ (@core_states -- [:placed, :accepted]),
         edges: edges,
         actions: Map.merge(@core_actions, stage_actions)
       }}
    else
      {:error, :invalid_workflow}
    end
  end

  def workflow(_), do: {:error, :invalid_workflow}

  @doc "`workflow/1`, raising on an invalid definition (for compile-time layers)."
  def workflow!(definition) do
    case workflow(definition) do
      {:ok, workflow} -> workflow
      {:error, reason} -> raise ArgumentError, "#{reason}: #{inspect(definition)}"
    end
  end

  defp stage_name({_action, stage}), do: stage
  defp stage_name(_), do: nil
  defp stage_action({action, _stage}), do: action
  defp stage_action(_), do: nil
  defp unique?(list), do: Enum.uniq(list) == list

  def initial_state, do: :placed
  def states(%{states: states}), do: states
  def terminal_states, do: @terminal
  def terminal?(state), do: state in @terminal

  @doc "The states an order may move to next, in the workflow's edge order."
  def next_states(%{fulfillments: fulfillments, edges: edges}, fulfillment, from) do
    if fulfillment in fulfillments,
      do: for({^from, to, guard} <- edges, admits?(guard, fulfillment), do: to),
      else: []
  end

  def legal?(workflow, fulfillment, from, to), do: to in next_states(workflow, fulfillment, from)

  defp admits?(:any, _fulfillment), do: true
  defp admits?(:delivery, fulfillment), do: fulfillment == :delivery
  defp admits?(:not_delivery, fulfillment), do: fulfillment != :delivery

  def new(%{fulfillments: fulfillments}, merchant, id, fulfillment)
      when is_binary(merchant) and byte_size(merchant) > 0 and
             is_binary(id) and byte_size(id) > 0 do
    if fulfillment in fulfillments,
      do:
        {:ok,
         %{
           merchant: merchant,
           id: id,
           fulfillment: fulfillment,
           state: :placed,
           version: 0,
           seen: %{}
         }},
      else: {:error, :invalid_order}
  end

  def new(_, _, _, _), do: {:error, :invalid_order}

  def authorized?(
        %{actions: actions},
        %{granted: true, principal: principal, actor: actor, allowed_actions: allowed},
        action
      )
      when is_binary(principal) and byte_size(principal) > 0 and is_list(allowed) do
    case Map.get(actions, action) do
      {_, roles} -> actor in roles and action in allowed
      _ -> false
    end
  end

  def authorized?(_, _, _), do: false

  @doc "Return a candidate or a uniform forbidden result before inspecting protected state."
  def apply(workflow, state, trusted, command) do
    action = if is_map(command), do: Map.get(command, :action)

    with true <- authorized?(workflow, trusted, action),
         true <- scoped?(state, trusted) do
      apply_authorized(workflow, state, trusted, command)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp scoped?(%{merchant: m, id: id}, %{merchant: m, order_id: id}), do: true
  defp scoped?(_, _), do: false

  defp apply_authorized(
         workflow,
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
        {to, _} = Map.fetch!(workflow.actions, action)

        cond do
          revision !== state.version ->
            {:error, :stale_order_version}

          not legal?(workflow, state.fulfillment, state.state, to) ->
            {:error, :invalid_transition}

          state.fulfillment == :delivery and to in @delivery_owned ->
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

  defp apply_authorized(_, _, _, _), do: {:error, :invalid_order_command}
  defp reason?(s), do: is_binary(s) and byte_size(s) > 0

  def replay(%{fulfillments: fulfillments} = workflow, fulfillment, history)
      when is_list(history) do
    if fulfillment in fulfillments do
      history
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, :placed}, fn
        {{from, to}, i}, {:ok, from} ->
          if legal?(workflow, fulfillment, from, to),
            do: {:cont, {:ok, to}},
            else: {:halt, {:error, {:illegal, i, from, to}}}

        {_, i}, _ ->
          {:halt, {:error, {:discontinuous, i}}}
      end)
    else
      {:error, :invalid_history}
    end
  end

  def replay(_, _, _), do: {:error, :invalid_history}
end
