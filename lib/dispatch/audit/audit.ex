defmodule Dispatch.Audit do
  @moduledoc """
  The append-only audit stream and the break-glass records of Section 22.6.

  Section 22.3 gives application roles no `UPDATE` or `DELETE` on these tables.
  Events are hash-chained, corrections are compensating events, and retention
  deletion is performed by a dedicated role and is itself audited.

  Slice 1 onward adds resources; the domain itself is declared from Slice 0 so
  each one has a named home rather than being invented under deadline.
  """

  use Ash.Domain

  resources do
  end
end
