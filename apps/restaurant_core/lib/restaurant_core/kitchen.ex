defmodule RestaurantCore.Kitchen do
  @moduledoc """
  The restaurant order workflow: `CommerceCore.OrderLifecycle` with a kitchen's
  production stages, `start_preparing → preparing` and `mark_ready → ready`, taken
  by admin or staff, for delivery, pickup and dine-in.

      placed → accepted → preparing → ready → completed          (pickup, dine-in)
      ready → dispatched → completed | failed                     (delivery)
      {placed, accepted, preparing, ready} → cancelled

  Every rule — authorization first, scope, revision, idempotency, delivery
  ownership, reasons — is the core's; this layer only names the stages.
  """

  alias CommerceCore.OrderLifecycle, as: Core

  @workflow Core.workflow!(%{
              fulfillments: [:delivery, :pickup, :dine_in],
              stages: [start_preparing: :preparing, mark_ready: :ready],
              stage_roles: [:admin, :staff]
            })

  def workflow, do: @workflow
  def states, do: Core.states(@workflow)
  defdelegate initial_state, to: Core
  defdelegate terminal_states, to: Core
  defdelegate terminal?(state), to: Core
  def next_states(fulfillment, from), do: Core.next_states(@workflow, fulfillment, from)
  def legal?(fulfillment, from, to), do: Core.legal?(@workflow, fulfillment, from, to)
  def new(merchant, id, fulfillment), do: Core.new(@workflow, merchant, id, fulfillment)
  def authorized?(trusted, action), do: Core.authorized?(@workflow, trusted, action)
  def apply(state, trusted, command), do: Core.apply(@workflow, state, trusted, command)
  def replay(fulfillment, history), do: Core.replay(@workflow, fulfillment, history)
end
