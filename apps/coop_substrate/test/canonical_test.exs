defmodule CoopSubstrate.CanonicalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.ReferenceEncoder

  # -- known-answer encodings (RFC 8949 shapes, restricted profile) -----------

  @known [
    {0, "00"},
    {1, "01"},
    {10, "0a"},
    {23, "17"},
    {24, "1818"},
    {25, "1819"},
    {100, "1864"},
    {1000, "1903e8"},
    {1_000_000, "1a000f4240"},
    {1_000_000_000_000, "1b000000e8d4a51000"},
    {9_223_372_036_854_775_807, "1b7fffffffffffffff"},
    {-1, "20"},
    {-10, "29"},
    {-100, "3863"},
    {-1000, "3903e7"},
    {-9_223_372_036_854_775_808, "3b7fffffffffffffff"},
    {false, "f4"},
    {true, "f5"},
    {nil, "f6"},
    {"", "60"},
    {"a", "6161"},
    {"IETF", "6449455446"},
    {"\"\\", "62225c"},
    {"\u00fc", "62c3bc"},
    {"\u6c34", "63e6b0b4"},
    {{:bytes, <<>>}, "40"},
    {{:bytes, <<1, 2, 3, 4>>}, "4401020304"},
    {[], "80"},
    {[1, 2, 3], "83010203"},
    {[1, [2, 3], [4, 5]], "8301820203820405"},
    {Enum.to_list(1..25),
     "98190102030405060708090a0b0c0d0e0f101112131415161718181819"},
    {%{}, "a0"},
    {%{"a" => 1, "b" => [2, 3]}, "a26161016162820203"},
    {["a", %{"b" => "c"}], "826161a161626163"},
    # Key ordering: bytewise over encoded keys => length-first, then lexicographic
    {%{"a" => 1, "b" => 2, "aa" => 3, "" => 4, "z" => 5},
     "a56004616101616202617a0562616103"}
  ]

  test "known-answer vectors match on the NIF encoder" do
    for {term, hex} <- @known do
      assert {:ok, bytes} = Canonical.encode(term),
             "NIF rejected #{inspect(term)}"

      assert Base.encode16(bytes, case: :lower) == hex,
             "NIF mismatch for #{inspect(term)}"
    end
  end

  test "known-answer vectors match on the reference encoder" do
    for {term, hex} <- @known do
      assert {:ok, bytes} = ReferenceEncoder.encode(term)

      assert Base.encode16(bytes, case: :lower) == hex,
             "reference mismatch for #{inspect(term)}"
    end
  end

  test "hash is SHA-256 over canonical bytes" do
    term = %{"a" => 1}
    {:ok, bytes} = Canonical.encode(term)
    assert {:ok, digest} = Canonical.hash(term)
    assert digest == :crypto.hash(:sha256, bytes)
    assert {:ok, ^digest} = ReferenceEncoder.hash(term)
  end

  # -- rejections --------------------------------------------------------------

  @rejects [
    {1.5, :float_forbidden},
    {0.0, :float_forbidden},
    {9_223_372_036_854_775_808, :int_out_of_range},
    {-9_223_372_036_854_775_809, :int_out_of_range},
    {:some_atom, :forbidden_type},
    {{:bytes, "x", "y"}, :forbidden_type},
    {{:tuple, 1}, :forbidden_type},
    {%{1 => "x"}, :bad_map_key},
    {%{atom_key: 1}, :bad_map_key},
    {<<0xFF, 0xFE>>, :invalid_utf8},
    {%{"k" => <<0xC0>>}, :invalid_utf8}
  ]

  test "forbidden terms are rejected by both encoders with the same reason" do
    runtime_rejects = [{self(), :forbidden_type}, {make_ref(), :forbidden_type}]

    for {term, reason} <- @rejects ++ runtime_rejects do
      assert {:error, ^reason} = Canonical.encode(term),
             "NIF should reject #{inspect(term)} with #{inspect(reason)}"

      assert {:error, ^reason} = ReferenceEncoder.encode(term),
             "reference should reject #{inspect(term)} with #{inspect(reason)}"
    end
  end

  test "invalid UTF-8 map key rejected" do
    assert {:error, :bad_map_key} = Canonical.encode(%{<<0xFF>> => 1})
    assert {:error, :bad_map_key} = ReferenceEncoder.encode(%{<<0xFF>> => 1})
  end

  test "raw bytes must be wrapped; unwrapped non-UTF-8 rejected, wrapped accepted" do
    raw = <<0xDE, 0xAD, 0xBE, 0xEF>>
    assert {:error, :invalid_utf8} = Canonical.encode(raw)
    assert {:ok, _} = Canonical.encode({:bytes, raw})
  end

  test "depth cap enforced" do
    deep = Enum.reduce(1..40, 0, fn _, acc -> [acc] end)
    assert {:error, :too_deep} = Canonical.encode(deep)
    assert {:error, :too_deep} = ReferenceEncoder.encode(deep)
  end

  test "size cap enforced" do
    big = {:bytes, :binary.copy(<<0>>, CoopSubstrate.Constants.max_canonical_bytes() + 1)}
    assert {:error, :too_large} = Canonical.encode(big)
    assert {:error, :too_large} = ReferenceEncoder.encode(big)
  end

  # -- generators ---------------------------------------------------------------

  defp canonical_term do
    leaf =
      StreamData.one_of([
        StreamData.integer(-9_223_372_036_854_775_808..9_223_372_036_854_775_807),
        StreamData.string(:utf8),
        StreamData.map(StreamData.binary(), &{:bytes, &1}),
        StreamData.boolean(),
        StreamData.constant(nil)
      ])

    StreamData.tree(leaf, fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 8),
        StreamData.map_of(StreamData.string(:utf8), child, max_length: 8)
      ])
    end)
  end

  # -- properties ----------------------------------------------------------------

  property "NIF and reference encoder agree byte-for-byte on generated terms" do
    check all(term <- canonical_term(), max_runs: 200) do
      assert Canonical.encode(term) == ReferenceEncoder.encode(term)
    end
  end

  property "encoding is invariant under map construction order" do
    check all(
            pairs <-
              StreamData.uniq_list_of(
                StreamData.tuple(
                  {StreamData.string(:utf8), StreamData.integer(-1000..1000)}
                ),
                uniq_fun: fn {k, _} -> k end,
                min_length: 1,
                max_length: 12
              ),
            max_runs: 100
          ) do
      shuffled = Enum.shuffle(pairs)

      m1 = Map.new(pairs)
      m2 = Map.new(shuffled)
      m3 = pairs |> Enum.reverse() |> Map.new()

      assert Canonical.encode(m1) == Canonical.encode(m2)
      assert Canonical.encode(m1) == Canonical.encode(m3)
      assert m1 == m2
    end
  end

  property "encoding is deterministic (same term twice => same bytes)" do
    check all(term <- canonical_term(), max_runs: 100) do
      assert Canonical.encode(term) == Canonical.encode(term)
    end
  end

  property "floats are rejected wherever they appear" do
    check all(f <- StreamData.float(), max_runs: 50) do
      assert {:error, :float_forbidden} = Canonical.encode(f)
      assert {:error, :float_forbidden} = ReferenceEncoder.encode(f)
      assert {:error, :float_forbidden} = Canonical.encode(%{"x" => [1, f]})
      assert {:error, :float_forbidden} = ReferenceEncoder.encode(%{"x" => [1, f]})
    end
  end
  # -- strict decode (inverse of encode; added with the log, plan step 6) --------

  describe "decode/1" do
    test "round-trips canonical bytes" do
      term = %{"a" => 1, "b" => [true, nil, {:bytes, <<0, 255>>}], "c" => "text"}
      {:ok, bytes} = Canonical.encode(term)
      assert Canonical.decode(bytes) == {:ok, term}
    end

    test "rejects non-shortest-form integers" do
      # 24 encoded with an unnecessary one-byte argument (0x18 0x18 is canonical
      # for 24; 0x19 0x00 0x18 is the non-minimal two-byte form).
      assert {:error, :non_canonical} = Canonical.decode(<<0x19, 0x00, 0x18>>)
    end

    test "rejects unsorted map keys" do
      # {"b": 1, "a": 2} in that wire order — canonical order is "a" first.
      bytes = <<0xA2, 0x61, ?b, 0x01, 0x61, ?a, 0x02>>
      assert {:error, :non_canonical} = Canonical.decode(bytes)
    end

    test "rejects floats, indefinite lengths, and trailing bytes" do
      assert {:error, _} = Canonical.decode(<<0xF9, 0x3C, 0x00>>)
      assert {:error, _} = Canonical.decode(<<0x9F, 0x01, 0xFF>>)
      {:ok, bytes} = Canonical.encode(1)
      assert {:error, :non_canonical} = Canonical.decode(bytes <> <<0x00>>)
    end

    test "rejects garbage" do
      assert {:error, _} = Canonical.decode(<<0xFF, 0xFF>>)
    end
  end

  property "decode is the exact inverse of encode" do
    check all(term <- canonical_term(), max_runs: 200) do
      {:ok, bytes} = Canonical.encode(term)
      assert Canonical.decode(bytes) == {:ok, term}
    end
  end
end
