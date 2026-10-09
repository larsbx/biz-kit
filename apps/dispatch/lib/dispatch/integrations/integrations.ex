defmodule Dispatch.Integrations do
  @moduledoc """
  Provider endpoints and the external reference rows that keep a vendor
  identifier out of the domain.

  The ports themselves are plain behaviours (Sections 27.1, 28.1, 29.0); this
  domain owns only the persisted side — `communication_endpoints`,
  `geo_provider_refs`, `communication_provider_refs`, and `agent_provider_refs`
  — so switching a provider never rewrites a domain record.

  Slice 1 onward adds resources; the domain itself is declared from Slice 0 so
  each one has a named home rather than being invented under deadline.
  """

  use Ash.Domain

  resources do
  end
end
