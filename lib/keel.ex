defmodule Keel do
  @moduledoc """
  Company-structure primitives that generalize.

  Four node sorts — `Keel.Party`, `Keel.Unit`, `Keel.Role`, `Keel.Body` — and
  three temporal edge sorts — `Keel.Seat`, `Keel.Line`, `Keel.Stake` — assembled
  into an immutable `Keel.Org`, checked by `Keel.Invariants`, and decided over by
  `Keel.Decision`. `Keel.Forms` shows sole proprietorships, partnerships,
  corporations, co-ops and departments are configurations, not special cases.
  See `docs/PRIMITIVES.md` for the formal model.
  """

  defdelegate new(items), to: Keel.Org
  defdelegate check(org), to: Keel.Invariants
end
