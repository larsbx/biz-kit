defmodule OrderCore.Transport do
  @moduledoc """
  The delivery-owned order edges, `last → dispatched → completed | failed`, which
  `OrderCore.Lifecycle` refuses to every order action (`:delivery_owned`).

  Only a transport authority takes them. `trusted` is host-verified context of
  exactly `%{transport: true, principal: p, merchant: m, order_id: id}`, derived
  from a transport grant, never from a request. A device context (anything
  carrying an actor, a grant flag or allowed actions) is refused here, as
  Lifecycle refuses this one, so the two authorities are disjoint.
  Authorization precedes inspection of state, as in Lifecycle.

  A command is `%{id, expected_version, to, reason}`; `:failed` needs a reason.
  Its idempotency key is `{:transport, id}`, a namespace no order command id
  can occupy. No state asserts payment or settlement.
  """

  alias OrderCore.Lifecycle

  @owned ~w(dispatched completed failed)a

  @spec apply(Lifecycle.workflow(), map(), map(), map()) ::
          {:ok, map(), :accepted | :duplicate} | {:error, term()}
  def apply(workflow, order, trusted, cmd) do
    if transport?(trusted) and scoped?(order, trusted),
      do: apply_authorized(workflow, order, trusted.principal, cmd),
      else: {:error, :forbidden}
  end

  defp transport?(%{transport: true, principal: p, merchant: _, order_id: _} = trusted),
    do: map_size(trusted) == 4 and is_binary(p) and byte_size(p) > 0

  defp transport?(_), do: false

  defp scoped?(%{merchant: m, id: id}, %{merchant: m, order_id: id}), do: true
  defp scoped?(_, _), do: false

  defp apply_authorized(
         workflow,
         order,
         principal,
         %{id: id, expected_version: v, to: to, reason: r} = cmd
       )
       when map_size(cmd) == 4 and is_binary(id) and byte_size(id) in 1..128 and is_integer(v) and
              is_atom(to) and (is_nil(r) or is_binary(r)) do
    key = {:transport, id}
    binding = {principal, cmd}

    case Map.get(order.seen, key) do
      ^binding ->
        {:ok, order, :duplicate}

      nil ->
        cond do
          order.fulfillment != :delivery ->
            {:error, :not_a_delivery_order}

          to not in @owned ->
            {:error, :not_delivery_owned}

          v !== order.version ->
            {:error, :stale_order_version}

          not Lifecycle.legal?(workflow, :delivery, order.state, to) ->
            {:error, :invalid_transition}

          to == :failed and r in [nil, ""] ->
            {:error, :reason_required}

          true ->
            {:ok, %{order | state: to, version: v + 1, seen: Map.put(order.seen, key, binding)},
             :accepted}
        end

      _ ->
        {:error, :idempotency_conflict}
    end
  end

  defp apply_authorized(_, _, _, _), do: {:error, :invalid_order_command}
end
