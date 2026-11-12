defmodule ResearchExchange.Ports do
  @moduledoc """
  Future integration contract; no implementation is installed by this adapter.
  A durable implementation must atomically check the expected version, consume
  the principal/idempotency key, store immutable artifacts and receipts, reserve
  capacity, and append a dispatch outbox event before acknowledging admission.
  Crash recovery must fence old capabilities and reconcile stopped execution.
  """
  @callback admit(expected_version :: non_neg_integer(), command :: map()) ::
              {:ok, map()} | {:error, :conflict | :unavailable}
  @callback claim_outbox() :: {:ok, map()} | :empty
  @callback record_authenticated_observation(
              expected_version :: non_neg_integer(),
              observation :: map()
            ) ::
              {:ok, map()} | {:error, :conflict | :unavailable}
end
