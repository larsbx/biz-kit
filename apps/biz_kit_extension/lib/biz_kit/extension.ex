defmodule BizKit.Extension do
  @moduledoc """
  Versioned, declarative contract for an explicitly compiled biz-kit domain app.

  A manifest is metadata, never an authorization, an application start request,
  a grant, a committed event or permission to write another domain's facts.
  The host admits actual commands through its existing scoped-grant and
  signed-ledger path. The pure catalog performs no runtime effects.
  """

  @callback manifest() :: map()
end
