defmodule Dispatch.Fleet do
  @moduledoc """
  Vehicles, trailers, loads, stops, assignments, and the party relationships
  that scope access to them.

  Section 22.2 makes a `LOAD`- or `STOP`-scoped grant require both an active
  role assignment and a matching active party row, so an organization kind, a
  phone number, or a caller's claim never grants access on its own.

  Slice 1 onward adds resources; the domain itself is declared from Slice 0 so
  each one has a named home rather than being invented under deadline.
  """

  use Ash.Domain

  resources do
  end
end
