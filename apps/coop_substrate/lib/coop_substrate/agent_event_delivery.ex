defmodule CoopSubstrate.AgentEventDelivery do
  @moduledoc """
  Host-only commit-before-ack ordering. EventStore supplies replay/checkpoints;
  this function only commits an idempotent effect before acknowledging delivery.
  Ports are trusted host functions. Reads must re-fetch canonical ledger bytes,
  never trust a supplied notification's data. No execution authority is granted.
  """
  def deliver(number, ports) when is_integer(number) and number > 0 do
    with {:ok, bundle} <- ports.read.(number),
         {:ok, _} <- ports.register.(bundle),
         :ok <- ports.ack.(number),
         do: :ok
  end

  def deliver(_, _), do: {:error, :invalid_event_number}
end
