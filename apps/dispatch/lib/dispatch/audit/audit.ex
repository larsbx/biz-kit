defmodule Dispatch.Audit do
  @moduledoc """
  The append-only audit stream and the break-glass records of Section 22.6.

  Section 22.3 gives application roles no `UPDATE` or `DELETE` on these tables.
  Events are hash-chained, corrections are compensating events, and retention
  deletion is performed by a dedicated role and is itself audited.

  """

  use Ash.Domain

  resources do
    resource Dispatch.Audit.AuditEvent
  end
end
