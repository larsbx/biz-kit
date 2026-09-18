defmodule Dispatch.PostgisTest do
  @moduledoc """
  Section 28.2 makes PostGIS canonical from the first migration, and Section
  33.2 requires SRID handling to be covered by exact fixtures. These assert the
  extension is present and that SRID 4326 geography behaves as the schema
  assumes, so a database provisioned without PostGIS fails here rather than at
  the first location upload.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
  end

  defp query!(sql, params \\ []) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(Dispatch.Repo, sql, params)
    rows
  end

  test "PostGIS is installed" do
    assert [[version]] = query!("SELECT postgis_version()")
    assert is_binary(version)
  end

  test "the required extensions are installed" do
    installed =
      query!("SELECT extname FROM pg_extension") |> List.flatten() |> MapSet.new()

    for required <- ~w(postgis uuid-ossp citext) do
      assert required in installed, "expected the #{required} extension to be installed"
    end
  end

  test "geography(Point,4326) round-trips with SRID preserved" do
    assert [[srid, lng, lat]] =
             query!(
               """
               SELECT ST_SRID(g), ST_X(g::geometry), ST_Y(g::geometry)
               FROM (SELECT ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography AS g) s
               """,
               [-122.4194, 37.7749]
             )

    assert srid == 4326
    assert_in_delta lng, -122.4194, 0.000001
    assert_in_delta lat, 37.7749, 0.000001
  end

  test "geography distance is in meters, not degrees" do
    # One degree of latitude is about 111 km. A geometry subtraction would
    # return 1.0 here; geography returns meters, which is what accuracy_m,
    # route-deviation thresholds, and the 250 m low-accuracy mark all assume.
    assert [[meters]] =
             query!("""
             SELECT ST_Distance(
               ST_SetSRID(ST_MakePoint(0, 0), 4326)::geography,
               ST_SetSRID(ST_MakePoint(0, 1), 4326)::geography
             )
             """)

    assert_in_delta meters, 110_574.0, 50.0
  end

  test "containment works for a geofence polygon" do
    assert [[inside, outside]] =
             query!("""
             SELECT
               ST_Covers(fence, ST_SetSRID(ST_MakePoint(0.5, 0.5), 4326)::geography),
               ST_Covers(fence, ST_SetSRID(ST_MakePoint(5.0, 5.0), 4326)::geography)
             FROM (
               SELECT ST_SetSRID(
                 ST_MakeEnvelope(0, 0, 1, 1), 4326
               )::geography AS fence
             ) s
             """)

    assert inside
    refute outside
  end
end
