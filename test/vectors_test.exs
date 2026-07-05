defmodule CoopSubstrate.VectorsTest do
  @moduledoc """
  Verifies both encoders against the COMMITTED vectors in
  `test/vectors/canonical_v1_vectors.json` (SUBSTRATE.md §1).

  A failure here means the CoopEventCanonicalV1 profile changed. That is a
  governance event, not a bug fix: do NOT regenerate the vectors to make the
  suite pass (see scripts/gen_vectors.exs).
  """

  use ExUnit.Case, async: true

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.ReferenceEncoder

  @vectors_path Path.expand("vectors/canonical_v1_vectors.json", __DIR__)
  @doc_json JSON.decode!(File.read!(@vectors_path))

  # Inverse of the JSON term representation in scripts/gen_vectors.exs:
  # {"__bytes__": hex} is a {:bytes, bin} wrapper, everything else is literal.
  defp from_json(%{"__bytes__" => hex}), do: {:bytes, Base.decode16!(hex, case: :lower)}
  defp from_json(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, from_json(v)} end)
  defp from_json(l) when is_list(l), do: Enum.map(l, &from_json/1)
  defp from_json(other), do: other

  test "vector file targets the frozen profile" do
    assert @doc_json["profile"] == "CoopEventCanonicalV1"
    assert length(@doc_json["vectors"]) == 6
  end

  for %{"name" => name} = vector <- @doc_json["vectors"] do
    @vector vector

    test "committed vector locks both encoders: #{name}" do
      term = from_json(@vector["term"])
      canonical = Base.decode16!(@vector["canonical_hex"], case: :lower)
      digest = Base.decode16!(@vector["sha256_hex"], case: :lower)
      sig = Base.decode16!(@vector["sig_hex"], case: :lower)
      pub = Base.decode16!(@doc_json["ed25519_pubkey_hex"], case: :lower)

      assert {:ok, ^canonical} = Canonical.encode(term)
      assert {:ok, ^canonical} = ReferenceEncoder.encode(term)

      assert :crypto.hash(:sha256, canonical) == digest
      assert {:ok, ^digest} = Canonical.hash(term)

      assert :crypto.verify(:eddsa, :none, canonical, sig, [pub, :ed25519])
    end
  end
end
