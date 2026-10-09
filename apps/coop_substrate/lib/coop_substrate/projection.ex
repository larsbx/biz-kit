defmodule CoopSubstrate.Projection do
  @moduledoc """
  A projection is a PURE fold over the canonical log (phase1a_plan step 7):
  `init/0` gives the empty state, `handle_event/2` folds one verified
  envelope into it. No side effects, no clock, no randomness — replaying the
  same events must reproduce the same state bit-for-bit, in `global_seq`
  order, never wall-clock order (timestamps are author-asserted claims).

  This is the seam every later compute layer (capital accrual, throughput,
  floor) builds on: deterministic state from events alone.
  """

  alias CoopSubstrate.Protocol.Envelope

  @callback init() :: term()
  @callback handle_event(Envelope.t(), term()) :: term()
end
