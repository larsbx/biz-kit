defmodule EatsbotCore.Orders.ActorIn do
  @moduledoc """
  Policy check: the actor's `access_level` is one of `levels`.

      authorize_if {ActorIn, levels: [:staff, :system]}
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor access level is one of #{inspect(opts[:levels])}"

  @impl true
  def match?(%{access_level: level}, _context, opts), do: level in opts[:levels]
  def match?(_actor, _context, _opts), do: false

  @doc "The actor internal processes run as: checkout, history writes and state sync."
  @spec system() :: %{access_level: :system}
  def system, do: %{access_level: :system}

  @doc "The history's `actor_type` for an actor: who caused a change."
  @spec actor_type(term()) :: :staff | :system | :customer
  def actor_type(%{access_level: level}) when level in [:admin, :staff], do: :staff
  def actor_type(%{access_level: :system}), do: :system
  def actor_type(_actor), do: :customer
end
