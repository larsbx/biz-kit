defmodule Dispatch.Access.Roles.Broker do
  @moduledoc """
  Contracted-load counterparty (Section 23.2).

  Scoped to a `LOAD` with an active contractual relationship. Location is
  summary-only unless a separate consented capability is assigned, and Section
  23.3 admits a broker to `can_view_precise_location` only when assigned to the
  active load, granted that capability with consent, and inside the sharing
  window.

  Acceptance criterion 19 requires an unrelated load to return no
  existence-bearing metadata — not a 403 that confirms the load exists.
  """

  use Dispatch.Access.Roles.Base, projection: :load
end
