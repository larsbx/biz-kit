defmodule EatsbotCore.Orders.Transitions do
  @moduledoc """
  The order lifecycle as data: the transition relation δ and its fulfillment guards.

  Validation, the order board and the property tests all read this one definition.

      placed → accepted → preparing → ready → dispatched → completed | failed   (delivery)
                                       ready → completed                         (pickup, dine-in)
      {placed, accepted, preparing, ready} → cancelled

  `completed`, `cancelled` and `failed` are terminal.
  """

  @type state ::
          :placed
          | :accepted
          | :preparing
          | :ready
          | :dispatched
          | :completed
          | :cancelled
          | :failed
  @type fulfillment :: :delivery | :pickup | :dine_in
  @type guard :: :any | :delivery | :not_delivery

  @states ~w(placed accepted preparing ready dispatched completed cancelled failed)a
  @fulfillments ~w(delivery pickup dine_in)a

  @delta [
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

  @terminal for s <- @states, not Enum.any?(@delta, &(elem(&1, 0) == s)), do: s

  @spec states() :: [state()]
  def states, do: @states

  @spec fulfillments() :: [fulfillment()]
  def fulfillments, do: @fulfillments

  @spec initial_state() :: state()
  def initial_state, do: :placed

  @spec terminal_states() :: [state()]
  def terminal_states, do: @terminal

  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal

  @doc "Whether `from → to` is in δ for an order with this fulfillment."
  @spec legal?(fulfillment(), state(), state()) :: boolean()
  def legal?(fulfillment, from, to),
    do: Enum.any?(@delta, fn {f, t, g} -> f == from and t == to and admits?(g, fulfillment) end)

  @doc "The states an order may move to next, in δ order."
  @spec next_states(fulfillment(), state()) :: [state()]
  def next_states(fulfillment, from),
    do: for({^from, to, g} <- @delta, admits?(g, fulfillment), do: to)

  @doc """
  Folds a recorded history of `{from, to}` steps from `initial_state/0` (I₆).

  Returns the resulting state, or the index of the first step that does not
  start where the previous one ended, or that is not in δ.
  """
  @spec replay(fulfillment(), [{state(), state()}]) ::
          {:ok, state()}
          | {:error, {:discontinuous, non_neg_integer()}}
          | {:error, {:illegal, non_neg_integer(), state(), state()}}
  def replay(fulfillment, history) do
    history
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, initial_state()}, fn
      {{from, to}, i}, {:ok, from} ->
        if legal?(fulfillment, from, to),
          do: {:cont, {:ok, to}},
          else: {:halt, {:error, {:illegal, i, from, to}}}

      {_step, i}, {:ok, _current} ->
        {:halt, {:error, {:discontinuous, i}}}
    end)
  end

  defp admits?(:any, _fulfillment), do: true
  defp admits?(:delivery, fulfillment), do: fulfillment == :delivery
  defp admits?(:not_delivery, fulfillment), do: fulfillment != :delivery
end
