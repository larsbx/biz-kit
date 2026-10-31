defmodule DispatchCore.EatsbotCharacterizationTest do
  @moduledoc """
  `DispatchCore.LegacyDelivery` against the old eatsbot's recorded delivery graph:
  the validity of every pair of its states, plus an unknown one, and the next states
  it offered staff (rebuild design, slice 1).

  The fixture is copied from larsbx/eatsbot at the commit below and pinned by its
  sha256; a changed copy fails here rather than silently moving the baseline.
  """
  use ExUnit.Case, async: true

  alias DispatchCore.LegacyDelivery

  @source "larsbx/eatsbot@15a201ee1279bffce09ab200609c2490f219af8c:eatsbot/test/fixtures/characterization/delivery_transitions.jsonl"
  @sha256 "01ab04e7f74565f7f1ffdb269a28b487b86a6a13dac619fe525984426e4b3618"
  @path Path.expand("fixtures/eatsbot_characterization/delivery_transitions.jsonl", __DIR__)

  setup_all do
    {:ok, records: @path |> File.stream!() |> Enum.map(&:json.decode/1)}
  end

  test "the fixture is the pinned copy from #{@source}" do
    assert :crypto.hash(:sha256, File.read!(@path)) |> Base.encode16(case: :lower) == @sha256
  end

  test "every recorded pair is valid in LegacyDelivery exactly when it was in eatsbot",
       %{records: records} do
    pairs = for %{"kind" => "valid"} = r <- records, do: r
    assert length(pairs) == 121

    mismatches =
      for %{"from" => from, "to" => to, "valid" => valid} <- pairs,
          LegacyDelivery.valid?(from, to) != valid,
          do: {from, to, valid}

    assert mismatches == []
  end

  # eatsbot offered staff the next states without the archival Stale_* ones.
  test "the next states offered match, once the archival states are set aside",
       %{records: records} do
    for %{"kind" => "possible_states", "from" => from, "next" => recorded} <- records do
      offered =
        from
        |> LegacyDelivery.next_states()
        |> Enum.reject(&String.starts_with?(&1, "Stale"))
        |> Enum.sort()

      assert offered == recorded, "from #{from}"
    end
  end
end
