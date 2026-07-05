defmodule CoopSubstrate.ULIDTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CoopSubstrate.ULID

  property "generated ULIDs are 26 valid Crockford chars for any timestamp" do
    check all(ts <- StreamData.integer(0..(Integer.pow(2, 48) - 1)), max_runs: 100) do
      ulid = ULID.generate(ts)
      assert byte_size(ulid) == 26
      assert ULID.valid?(ulid)
    end
  end

  test "known ULID validates; malformed values do not" do
    assert ULID.valid?("01ARZ3NDEKTSV4RRFFQ69G5FAV")
    refute ULID.valid?("01ARZ3NDEKTSV4RRFFQ69G5FA")
    refute ULID.valid?("01ARZ3NDEKTSV4RRFFQ69G5FAVX")
    # I, L, O, U are not Crockford base32
    refute ULID.valid?("01ARZ3NDEKTSV4RRFFQ69G5FAI")
    # first char > "7" overflows 128 bits
    refute ULID.valid?("8ZZZZZZZZZZZZZZZZZZZZZZZZZ")
    refute ULID.valid?(nil)
    refute ULID.valid?(42)
  end

  test "distinct ULIDs at the same millisecond" do
    ulids = for _ <- 1..100, do: ULID.generate(1_720_000_000_000)
    assert length(Enum.uniq(ulids)) == 100
  end
end
