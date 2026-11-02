defmodule RestaurantHost.EnrollmentTest do
  use ExUnit.Case, async: true
  alias RestaurantHost.{DeviceGrants, Enrollment}

  defp proposal(actor, actions) do
    %{
      "chapter_id" => "chapter-a",
      "type" => "RestaurantDeviceGrantedV1",
      "payload" => %{
        "merchant_id" => "shop",
        "device_id" => "device-a",
        "key_id" => "k-device",
        "pubkey" => Base.url_encode64(:binary.copy(<<7>>, 32), padding: false),
        "actor" => actor,
        "actions" => actions
      }
    }
  end

  test "only the checkout and kitchen capability sets are accepted" do
    assert DeviceGrants.valid_details?(proposal("system", ["checkout"]))

    assert DeviceGrants.valid_details?(
             proposal("staff", ~w(accept start_preparing mark_ready complete cancel))
           )

    for details <- [
          proposal("admin", ["checkout"]),
          proposal("staff", ["checkout"]),
          proposal("system", []),
          proposal("system", ["checkout", "checkout"])
        ] do
      refute DeviceGrants.valid_details?(details)
    end
  end

  test "malformed proposals are refused before review or signing" do
    d = proposal("system", ["checkout"])

    for bad <- [
          nil,
          [],
          %{},
          Map.put(d, "seed", "secret"),
          put_in(d["payload"]["pubkey"], 42),
          put_in(d["payload"]["pubkey"], "AQ"),
          put_in(d["payload"]["device_id"], "a\nforged"),
          put_in(d["payload"]["key_id"], ""),
          put_in(d["payload"]["actions"], %{"checkout" => true})
        ] do
      refute DeviceGrants.valid_details?(bad)
      refute DeviceGrants.grants?(%{}, bad)
    end
  end

  test "canonical core must match every reviewed grant field" do
    d = proposal("system", ["checkout"])
    {:ok, pubkey} = Base.url_decode64(d["payload"]["pubkey"], padding: false)
    core = Map.put(d, "payload", Map.put(d["payload"], "pubkey", {:bytes, pubkey}))
    assert DeviceGrants.grants?(core, d)

    for changed <- [
          Map.put(core, "chapter_id", "chapter-b"),
          Map.put(core, "type", "RoleKeyDeclared"),
          put_in(core["payload"]["merchant_id"], "other-shop"),
          put_in(core["payload"]["key_id"], "other-key"),
          put_in(core["payload"]["device_id"], "other-device"),
          put_in(core["payload"]["actor"], "admin"),
          put_in(core["payload"]["actions"], ["complete"])
        ] do
      refute DeviceGrants.grants?(changed, d)
    end
  end

  test "chapter, merchant and strict options are required even for unattended use" do
    io = %{
      info: fn _ -> flunk("unexpected output") end,
      confirm: fn _ -> flunk("unexpected prompt") end
    }

    base = ["device-a", "--chapter", "chapter-a", "--merchant", "shop"]

    for args <- [
          ["device-a", "--yes"],
          base ++ ["extra"],
          base ++ ["--unknown"],
          base ++ ["--server", "http://remote.example"],
          base ++ ["--server", "https://user:secret@remote.example"],
          base ++ ["--server", "https://remote.example/?query=x"],
          base ++ ["--chapter", "chapter-b"]
        ] do
      assert {:error, :invalid_options} = Enrollment.run(args, io)
    end
  end
end
