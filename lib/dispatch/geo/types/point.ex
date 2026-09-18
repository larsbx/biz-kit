defmodule Dispatch.Geo.Types.Point do
  @moduledoc """
  An Ash type for a PostGIS `geography(Point,4326)` column.

  Section 28.2 makes PostGIS canonical from the first migration and requires
  stop and location positions to be stored as `geography(Point,4326)`.
  `geography` rather than `geometry` is the load-bearing part: Section 6.1
  records accuracy in metres, Section 25.3 marks a sample low-accuracy above
  250 m, and Section 28.2 computes deviation and containment in
  provider-neutral PostGIS queries. On a `geometry` column those distances come
  back in degrees, which vary with latitude — so the wrong column type would
  make every threshold silently wrong rather than obviously broken.

  Ash has no geometry type and `Geo.PostGIS.Geometry` is an Ecto type, so this
  adapts one to the other. Casting accepts a `%Geo.Point{}` or a plain
  `{lng, lat}` pair, and always stamps SRID 4326: a point with no SRID is not a
  location, and one with a different SRID compared against 4326 data produces a
  wrong answer rather than an error.
  """

  use Ash.Type

  @srid 4326

  @impl Ash.Type
  def storage_type(_constraints), do: :"geography(Point,4326)"

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(%Geo.Point{} = point, _constraints), do: {:ok, with_srid(point)}

  def cast_input({lng, lat}, _constraints) when is_number(lng) and is_number(lat) do
    {:ok, %Geo.Point{coordinates: {lng / 1, lat / 1}, srid: @srid}}
  end

  def cast_input(%{"lat" => lat, "lng" => lng}, constraints)
      when is_number(lat) and is_number(lng) do
    cast_input({lng, lat}, constraints)
  end

  def cast_input(%{lat: lat, lng: lng}, constraints) when is_number(lat) and is_number(lng) do
    cast_input({lng, lat}, constraints)
  end

  def cast_input(_other, _constraints), do: :error

  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(value, _constraints) do
    case Geo.PostGIS.Geometry.load(value) do
      {:ok, %Geo.Point{} = point} -> {:ok, with_srid(point)}
      # A stored value that is not a point is a schema mismatch, not a null.
      _ -> :error
    end
  end

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%Geo.Point{} = point, _constraints) do
    Geo.PostGIS.Geometry.dump(with_srid(point))
  end

  def dump_to_native(_other, _constraints), do: :error

  @impl Ash.Type
  def equal?(%Geo.Point{} = left, %Geo.Point{} = right), do: with_srid(left) == with_srid(right)
  def equal?(left, right), do: left == right

  @doc """
  Latitude and longitude in decimal degrees.

  Section 19.2 makes decimal degrees the API representation, while storage stays
  PostGIS. `Geo.Point` orders its tuple `{lng, lat}`, which is the opposite of
  how every human writes a coordinate, so the conversion happens here once
  rather than at each call site.
  """
  @spec to_lat_lng(Geo.Point.t() | nil) :: %{lat: float(), lng: float()} | nil
  def to_lat_lng(nil), do: nil
  def to_lat_lng(%Geo.Point{coordinates: {lng, lat}}), do: %{lat: lat, lng: lng}

  @doc "Builds a point from decimal degrees, stamping SRID 4326."
  @spec from_lat_lng(number(), number()) :: Geo.Point.t()
  def from_lat_lng(lat, lng) when is_number(lat) and is_number(lng) do
    %Geo.Point{coordinates: {lng / 1, lat / 1}, srid: @srid}
  end

  defp with_srid(%Geo.Point{} = point), do: %{point | srid: @srid}
end
