defmodule Dispatch.Identity do
  @moduledoc """
  Consent grants, biometric consents, face enrollments, verification challenges
  and attestations, and deletion receipts.

  Section 7.2 keeps every piece of biometric material on the device. This domain
  stores metadata and decisions only — no embedding, landmark, face crop,
  similarity score, or liveness telemetry ever reaches it.

  Slice 1 onward adds resources; the domain itself is declared from Slice 0 so
  each one has a named home rather than being invented under deadline.
  """

  use Ash.Domain

  resources do
  end
end
