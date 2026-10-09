defmodule Dispatch.Access.Roles.Dispatcher do
  @moduledoc """
  Carrier operations (Section 23.2).

  Scope is the organization, narrowed further by carrier and assignment
  relationship. Precise location is not implied: it requires
  `operations.location.precise.read` plus an active consent grant, and
  acceptance criterion 15 requires that removing the assignment relationship
  terminates REST, page, and SSE access immediately.
  """

  use Dispatch.Access.Roles.Base, projection: :operations
end
