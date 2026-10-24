defmodule Dispatch.FulfillmentBridge do
  @moduledoc """
  Transport-side pure handoff adapter.

  A service handler must verify scopes and append the resulting event through
  its real admission path; this function never assigns a driver or route.
  """

  def accept(state, merchant, event_id, transport_ref) do
    FulfillmentCore.apply(state, merchant, :dispatch, %{
      id: event_id,
      expected_version: state.version,
      op: :accept,
      transport_ref: transport_ref
    })
  end
end
