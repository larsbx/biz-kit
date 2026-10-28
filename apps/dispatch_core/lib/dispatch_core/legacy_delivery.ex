defmodule DispatchCore.LegacyDelivery do
  @moduledoc """
  Exact unlocalized transition graph from Eatsbot Deliveries.Transitions.

  Characterization/replay compatibility only, not an operational authority.
  In particular, legacy "Stale_*" states are archival classifications, not
  proof that a carrier stopped, delivered, or definitively failed. Never use
  this module to authorize a biz-kit Dispatch command.
  """

  @edges [
    {"Init", "In_Preparation"},
    {"Init", "Delivery_Aborted"},
    {"In_Preparation", "Ready_To_Pickup"},
    {"In_Preparation", "Delivery_Aborted"},
    {"Ready_To_Pickup", "In_Delivery"},
    {"Ready_To_Pickup", "Delivery_Aborted"},
    {"Delivery_Aborted", "Stale_Delivery_Aborted"},
    {"In_Delivery", "Delivery_With_Problems"},
    {"In_Delivery", "Delivery_Done"},
    {"In_Delivery", "Stale_Delivery_With_Problems"},
    {"Delivery_With_Problems", "In_Delivery"},
    {"Delivery_With_Problems", "Stale_Delivery_With_Problems"},
    {"Delivery_Done", "Stale_Delivery_Done"}
  ]

  @states Enum.uniq(Enum.flat_map(@edges, fn {from, to} -> [from, to] end))

  @spec edges() :: [{String.t(), String.t()}]
  def edges, do: @edges

  @spec valid?(String.t(), String.t()) :: boolean()
  def valid?(from, to) when is_binary(from) and is_binary(to), do: {from, to} in @edges
  def valid?(_, _), do: false

  @spec next_states(String.t()) :: [String.t()]
  def next_states(from) when is_binary(from) do
    for {^from, to} <- @edges, do: to
  end

  def next_states(_), do: []

  @doc """
  Replay a list of recorded {from, to} legacy transitions from a known state.
  Refuses discontinuity and unknown edges, but does not authenticate history.
  """
  def replay(initial, steps) when initial in @states and is_list(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, initial}, fn {step, index}, {:ok, current} ->
      case step do
        {^current, to} ->
          if valid?(current, to) do
            {:cont, {:ok, to}}
          else
            {:halt, {:error, {:illegal, index}}}
          end

        {_other, _to} ->
          {:halt, {:error, {:discontinuous, index}}}

        _ ->
          {:halt, {:error, {:invalid_step, index}}}
      end
    end)
  end

  def replay(_, _), do: {:error, :invalid_legacy_history}
end
