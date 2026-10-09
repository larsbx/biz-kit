# Generates test/vectors/canonical_v1_vectors.json.
#
# Run with: MIX_ENV=test mix run scripts/gen_vectors.exs
#
# The vectors are COMMITTED artifacts: once generated and reviewed they lock
# the CoopEventCanonicalV1 profile. Regenerating them is a profile change and
# requires the governance process (SUBSTRATE.md §1.3).
#
# The Ed25519 key here is TEST-ONLY (committed on purpose, for vectors).

alias CoopSubstrate.ReferenceEncoder

seed = :binary.copy(<<0x42>>, 32)
{pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)

# JSON representation of logical terms: {"__bytes__": hex} means {:bytes, bin}.
to_json_term = fn
  {:bytes, b}, _self -> %{"__bytes__" => Base.encode16(b, case: :lower)}
  m, self when is_map(m) -> Map.new(m, fn {k, v} -> {k, self.(v, self)} end)
  l, self when is_list(l) -> Enum.map(l, &self.(&1, self))
  other, _self -> other
end

vectors = [
  {"primitive-grabbag",
   %{
     "int" => 42,
     "neg" => -1_000_000,
     "str" => "hello",
     "bool_t" => true,
     "bool_f" => false,
     "null" => nil,
     "list" => [1, "two", {:bytes, <<3, 3, 3>>}, nil],
     "nested" => %{"deep" => %{"deeper" => [-9_223_372_036_854_775_808]}},
     "bytes" => {:bytes, <<0xDE, 0xAD, 0xBE, 0xEF>>}
   }},
  {"int-boundaries",
   [
     0,
     -1,
     23,
     24,
     255,
     256,
     65_535,
     65_536,
     4_294_967_295,
     4_294_967_296,
     9_223_372_036_854_775_807,
     -9_223_372_036_854_775_808
   ]},
  {"empty-structures", [%{}, [], "", {:bytes, <<>>}]},
  {"key-ordering", %{"a" => 1, "b" => 2, "aa" => 3, "" => 4, "z" => 5}},
  {"unicode-exact-bytes",
   %{
     # NFC "é" (U+00E9) and NFD "e" + U+0301 are DIFFERENT strings — no
     # normalization is applied by the profile.
     "nfc" => <<0xC3, 0xA9>>,
     "nfd" => <<0x65, 0xCC, 0x81>>,
     "cjk" => "水",
     "emoji" => "🚚"
   }},
  {"envelope-core",
   %{
     "auth_ref" => nil,
     "canonical_profile" => "CoopEventCanonicalV1",
     "chapter_id" => "chapter-genesis",
     "event_id" => "01ARZ3NDEKTSV4RRFFQ69G5FAV",
     "payload" => %{"note" => "vector fixture", "amount_minor" => 12_345},
     "schema_version" => "EventEnvelopeV1",
     "signers" => [
       %{
         "key_id" => "test-vector-key-1",
         "pubkey" => {:bytes, pub},
         "role" => "author"
       }
     ],
     "timestamp_ms" => 1_720_000_000_000,
     "type" => "TestProjectionEvent"
   }}
]

entries =
  Enum.map(vectors, fn {name, term} ->
    {:ok, bytes} = ReferenceEncoder.encode(term)
    digest = :crypto.hash(:sha256, bytes)
    sig = :crypto.sign(:eddsa, :none, bytes, [seed, :ed25519])

    %{
      "name" => name,
      "term" => to_json_term.(term, to_json_term),
      "canonical_hex" => Base.encode16(bytes, case: :lower),
      "sha256_hex" => Base.encode16(digest, case: :lower),
      "sig_hex" => Base.encode16(sig, case: :lower)
    }
  end)

doc = %{
  "profile" => "CoopEventCanonicalV1",
  "note" =>
    "Committed vectors locking the canonical profile. Ed25519 key is test-only. " <>
      "Signatures are over the canonical bytes.",
  "ed25519_seed_hex" => Base.encode16(seed, case: :lower),
  "ed25519_pubkey_hex" => Base.encode16(pub, case: :lower),
  "vectors" => entries
}

# OTP :json doesn't map Elixir's nil to JSON null on its own.
json_formatter = fn
  nil, _fun, _state -> "null"
  other, fun, state -> :json.format_value(other, fun, state)
end

json = :json.format(doc, json_formatter, %{}) |> IO.iodata_to_binary()

File.mkdir_p!("test/vectors")
File.write!("test/vectors/canonical_v1_vectors.json", json)
IO.puts("wrote test/vectors/canonical_v1_vectors.json (#{length(entries)} vectors)")
