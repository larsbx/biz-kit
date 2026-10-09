defmodule CoopSubstrate.EventStore do
  @moduledoc """
  The ONE canonical write log (hand-off §1; decision in SUBSTRATE.md §3):
  Commanded's `eventstore` library over Postgres — append-only schema,
  atomic batched appends with `expected_version`, bytea event data.

  Nothing appends here directly; all writes go through `CoopSubstrate.Log`,
  which performs verify-on-append and dual-chain assignment.
  """

  use EventStore, otp_app: :coop_substrate
end
