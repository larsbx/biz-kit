defmodule Dispatch.Integrations.Geo.Geocoder do
  @moduledoc """
  Address-search port (Section 28.1).

  PostGIS supplies neither geocoding nor road-network routing (Section 6.2), so
  this port stays a genuine external dependency even after the native migration.
  """

  @callback search(query :: String.t(), context :: map()) ::
              {:ok, [Dispatch.Geo.AddressCandidate.t()]} | {:error, term()}

  @callback reverse(Dispatch.Geo.Coordinate.t(), context :: map()) ::
              {:ok, Dispatch.Geo.AddressCandidate.t()} | {:error, term()}
end

defmodule Dispatch.Integrations.Geo.Router do
  @moduledoc """
  Routing port (Section 28.1).

  Section 28.3 requires that a provider failure leave the previous route
  visibly stale rather than fabricate an ETA, so an error is always returned as
  an error and never as a zero-duration result.
  """

  @callback route(Dispatch.Geo.RouteRequest.t()) ::
              {:ok, Dispatch.Geo.RouteResult.t()} | {:error, term()}

  @callback matrix(Dispatch.Geo.MatrixRequest.t()) ::
              {:ok, Dispatch.Geo.MatrixResult.t()} | {:error, term()}
end
