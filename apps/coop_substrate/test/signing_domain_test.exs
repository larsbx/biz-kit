defmodule CoopSubstrate.SigningDomainTest do
  @moduledoc """
  ADR 0004 D3 / ADR 0005 gap G9: biz-kit never signs, or accepts a signature
  over, bytes in Hawala's signing domain (every Hawala input begins with
  `hawala`). The guard is byte-level, so it holds for every key, bound or not.
  """
  use ExUnit.Case, async: true

  alias CoopSubstrate.Crypto

  @umbrella_apps Path.expand("../..", __DIR__)
  @vectors Path.expand("vectors/hawala_identity_v1.json", __DIR__)

  defp hawala_vector do
    @vectors |> File.read!() |> Jason.decode!() |> Map.fetch!("vectors") |> hd()
  end

  defp hex(vector, key), do: Base.decode16!(Map.fetch!(vector, key), case: :mixed)

  describe "the ledger signer refuses Hawala's signing domain" do
    test "signing any hawala-prefixed input raises, whatever the key" do
      {_pub, seed} = Crypto.generate_keypair()

      for message <- ["hawala", "hawala-identity-core/v1\0", "hawala/capability-port/call/v1\0x"] do
        assert_raise ArgumentError, ~r/Hawala signing domain/, fn ->
          Crypto.sign(message, seed)
        end
      end
    end

    test "a genuine Hawala signature does not verify through the ledger verifier" do
      v = hawala_vector()
      message = hex(v, "message_hex")
      signature = hex(v, "signature_hex")
      pubkey = hex(v, "public_key_hex")

      assert :crypto.verify(:eddsa, :none, message, signature, [pubkey, :ed25519])
      refute Crypto.verify(message, signature, pubkey)
    end

    test "inputs merely near the prefix are unaffected" do
      {pub, seed} = Crypto.generate_keypair()

      for message <- ["", "hawal", "Hawala", "xhawala", <<0xA1, "hawala">>] do
        assert Crypto.verify(message, Crypto.sign(message, seed), pub)
      end
    end
  end

  # Every direct Ed25519 call outside `CoopSubstrate.Crypto`, with the source
  # evidence that its signed bytes start outside the `hawala` prefix. A new
  # call site fails this test until it is reviewed and listed here.
  @direct_ed25519_sites %{
    "coop_substrate/lib/coop_substrate/crypto.ex" => ~r/@hawala_domain "hawala"/,
    "federation_service/lib/federation_service/gossip.ex" => ~r/@schema "bizkit\./,
    "federation_service/lib/federation_service/gossip_sync.ex" =>
      ~r/when is_map\(value\) do\s+"\{" <>/,
    "federation_service/lib/federation_service/gossip_lease.ex" => ~r/GossipSync\.canonical\(/,
    "group_buy_core/lib/group_buy_core/escrow_proof.ex" =>
      ~r/@domain "bizkit\..*\{:ok, @domain <> encoded\}/s
  }

  test "direct Ed25519 call sites are exactly the reviewed, non-Hawala-prefixed ones" do
    found =
      Path.wildcard(Path.join(@umbrella_apps, "*/lib/**/*.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/:crypto\.(sign|verify)\(\s*:eddsa/))
      |> MapSet.new(&Path.relative_to(&1, @umbrella_apps))

    assert found == MapSet.new(Map.keys(@direct_ed25519_sites))

    for {path, evidence} <- @direct_ed25519_sites do
      assert File.read!(Path.join(@umbrella_apps, path)) =~ evidence,
             "#{path}: prefix evidence missing"
    end
  end
end
