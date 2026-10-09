defmodule Dispatch.Geo.Coordinate do
  @moduledoc """
  A canonical WGS 84 coordinate in decimal degrees (Section 19.2).

  Persistence uses PostGIS `geography(Point,4326)` (Section 28.2); this struct
  is the transport and port representation.
  """
  @enforce_keys [:lat, :lng]
  defstruct [:lat, :lng, :accuracy_m]

  @type t :: %__MODULE__{lat: float(), lng: float(), accuracy_m: float() | nil}
end

defmodule Dispatch.Geo.AddressCandidate do
  @moduledoc """
  A geocoder result.

  Section 28.2 keeps vendor identifiers such as a Google Place ID out of the
  domain and in `geo_provider_refs`, so this struct carries only the canonical
  address, coordinate, and provenance.
  """
  @enforce_keys [:formatted_address, :coordinate, :provider]
  defstruct [:formatted_address, :coordinate, :provider, :confidence, :components]

  @type t :: %__MODULE__{
          formatted_address: String.t(),
          coordinate: Dispatch.Geo.Coordinate.t(),
          provider: atom(),
          confidence: float() | nil,
          components: map() | nil
        }
end

defmodule Dispatch.Geo.RouteRequest do
  @moduledoc "An ordered routing request with vehicle constraints."
  @enforce_keys [:origin, :destination]
  defstruct [:origin, :destination, :departure_at, waypoints: [], vehicle_constraints: %{}]

  @type t :: %__MODULE__{
          origin: Dispatch.Geo.Coordinate.t(),
          destination: Dispatch.Geo.Coordinate.t(),
          departure_at: DateTime.t() | nil,
          waypoints: [Dispatch.Geo.Coordinate.t()],
          vehicle_constraints: map()
        }
end

defmodule Dispatch.Geo.RouteResult do
  @moduledoc """
  A computed route.

  `geometry` is GeoJSON, not an encoded provider polyline, so Section 28.6 can
  swap routers without rewriting stored route history.
  """
  @enforce_keys [:distance_m, :duration_s, :geometry, :provider, :computed_at]
  defstruct [:distance_m, :duration_s, :geometry, :provider, :computed_at, :expires_at]

  @type t :: %__MODULE__{
          distance_m: non_neg_integer(),
          duration_s: non_neg_integer(),
          geometry: map(),
          provider: atom(),
          computed_at: DateTime.t(),
          expires_at: DateTime.t() | nil
        }
end

defmodule Dispatch.Geo.MatrixRequest do
  @moduledoc "A route-matrix request over canonical coordinates."
  @enforce_keys [:origins, :destinations]
  defstruct [:origins, :destinations, :departure_at, vehicle_constraints: %{}]

  @type t :: %__MODULE__{
          origins: [Dispatch.Geo.Coordinate.t()],
          destinations: [Dispatch.Geo.Coordinate.t()],
          departure_at: DateTime.t() | nil,
          vehicle_constraints: map()
        }
end

defmodule Dispatch.Geo.MatrixResult do
  @moduledoc "Distance and duration for each origin/destination pair."
  @enforce_keys [:entries, :provider, :computed_at]
  defstruct [:entries, :provider, :computed_at]

  @type entry :: %{
          origin_index: non_neg_integer(),
          destination_index: non_neg_integer(),
          distance_m: non_neg_integer() | nil,
          duration_s: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{entries: [entry()], provider: atom(), computed_at: DateTime.t()}
end
