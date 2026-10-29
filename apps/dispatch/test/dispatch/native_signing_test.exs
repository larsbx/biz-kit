defmodule Dispatch.NativeSigningTest do
  use ExUnit.Case, async: true

  test "the shared Android vector uses canonical platform bytes and Ed25519" do
    vector =
      File.read!(Path.expand("../fixtures/native-status-vector.json", __DIR__)) |> Jason.decode!()

    {:ok, bytes} =
      Dispatch.MobileDevices.signing_bytes(vector["payload"], vector["role_assignment_id"])

    assert bytes == Base.url_decode64!(vector["signing_bytes"], padding: false)

    assert CoopSubstrate.Crypto.verify(
             bytes,
             Base.url_decode64!(vector["signature"], padding: false),
             Base.url_decode64!(vector["public_key"], padding: false)
           )
  end
end
