defmodule Dispatch.Identity.Tokens.JoseSecurityTest do
  use ExUnit.Case, async: true

  test "AES-GCM authenticates the full tag and rejects truncated tags" do
    key = JOSE.JWK.from_oct(:crypto.strong_rand_bytes(16))
    plaintext = "private fixture payload"

    {_, token} =
      key
      |> JOSE.JWE.block_encrypt(plaintext, %{"alg" => "dir", "enc" => "A128GCM"})
      |> JOSE.JWE.compact()

    assert {^plaintext, _} = JOSE.JWE.block_decrypt(key, token)
    parts = String.split(token, ".")
    tag = parts |> List.last() |> Base.url_decode64!(padding: false)

    for size <- [0, 1, 4, 8, 15] do
      shortened = Base.url_encode64(binary_part(tag, 0, size), padding: false)
      bad = parts |> List.replace_at(4, shortened) |> Enum.join(".")
      assert refused?(fn -> JOSE.JWE.block_decrypt(key, bad) end)
    end
  end

  test "ECDSA accepts its canonical signature length and refuses redundant integer padding" do
    key = JOSE.JWK.generate_key({:ec, :secp256r1})

    {_, token} =
      JOSE.JWT.sign(key, %{"alg" => "ES256"}, %{"sub" => "fixture"}) |> JOSE.JWS.compact()

    assert {true, _, _} = JOSE.JWT.verify_strict(key, ["ES256"], token)
    [header, payload, signature] = String.split(token, ".")
    <<r::binary-size(32), s::binary-size(32)>> = Base.url_decode64!(signature, padding: false)

    for bytes <- [<<0>> <> r <> <<0>> <> s, r <> s <> <<0>>, binary_part(r <> s, 0, 63)] do
      bad = Enum.join([header, payload, Base.url_encode64(bytes, padding: false)], ".")
      assert refused?(fn -> JOSE.JWT.verify_strict(key, ["ES256"], bad) end)
    end
  end

  defp refused?(fun) do
    case fun.() do
      :error -> true
      {:error, _} -> true
      {:error, _, _} -> true
      {false, _, _} -> true
      _ -> false
    end
  rescue
    _ -> true
  end
end
