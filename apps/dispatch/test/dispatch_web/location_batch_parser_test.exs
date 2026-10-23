defmodule DispatchWeb.Plugs.LocationBatchParserTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias DispatchWeb.Plugs.LocationBatchParser

  defp parse(body, path \\ "/v1/me/location-samples:batch") do
    :post
    |> conn(path, body)
    |> put_req_header("content-type", "application/json")
    |> delete_req_header("content-length")
    |> LocationBatchParser.call([])
  end

  test "counts whitespace on the wire, including the DRIVER route" do
    for path <- [
          "/v1/me/location-samples:batch",
          "/v1/driver/location-samples:batch",
          "/v1/me/location-samples%3Abatch",
          "/v1/driver/location-samples:batch/"
        ] do
      conn = parse(String.duplicate(" ", 300_000) <> ~s({"samples":[]}), path)
      assert conn.halted
      assert conn.status == 413
      assert Jason.decode!(conn.resp_body)["code"] == "BATCH_TOO_LARGE"
    end
  end

  test "counts escaped JSON before decoding it to a smaller string" do
    body = ~s({"samples":[],"padding":") <> String.duplicate("\\u0061", 45_000) <> ~s("})
    assert byte_size(Jason.encode!(Jason.decode!(body))) < 262_144
    assert parse(body).status == 413
  end

  test "accepts exactly 256 KiB but rejects the next byte" do
    body = ~s({"samples":[]})
    at_limit = String.duplicate(" ", 262_144 - byte_size(body)) <> body
    conn = parse(at_limit)
    refute conn.halted
    assert conn.body_params == %{"samples" => []}
    assert parse(" " <> at_limit).status == 413
  end

  test "leaves other endpoint bodies to the general parser" do
    conn = parse(String.duplicate("x", 300_000), "/v1/me/status-events")
    refute conn.halted
    assert %Plug.Conn.Unfetched{} = conn.body_params
  end
end
