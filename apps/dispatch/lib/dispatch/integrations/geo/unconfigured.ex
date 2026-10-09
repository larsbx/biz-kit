defmodule Dispatch.Integrations.Geo.Unconfigured do
  @moduledoc """
  Deterministic "no provider selected" geospatial adapters.

  Section 28.3 requires a provider failure to leave the previous route visibly
  stale rather than fabricate an ETA, so these return errors and never a
  zero-distance route. `Dispatch.Config` rejects them in production.
  """

  defmodule Geocoder do
    @moduledoc "Unconfigured geocoder."
    @behaviour Dispatch.Integrations.Geo.Geocoder

    @impl true
    def search(_query, _context), do: {:error, :geo_adapter_not_configured}

    @impl true
    def reverse(%Dispatch.Geo.Coordinate{}, _context), do: {:error, :geo_adapter_not_configured}
  end

  defmodule Router do
    @moduledoc "Unconfigured router."
    @behaviour Dispatch.Integrations.Geo.Router

    @impl true
    def route(%Dispatch.Geo.RouteRequest{}), do: {:error, :geo_adapter_not_configured}

    @impl true
    def matrix(%Dispatch.Geo.MatrixRequest{}), do: {:error, :geo_adapter_not_configured}
  end
end
