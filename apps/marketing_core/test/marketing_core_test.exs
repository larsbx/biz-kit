defmodule MarketingCoreTest do
  use ExUnit.Case, async: true

  alias MarketingCore.{Attribution, Redemption, Touchpoint}

  @delivered ~U[2026-10-28 12:00:00Z]
  @checkin ~U[2026-10-28 12:05:00Z]

  defp event(state, id, at, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        expected_version: state.version,
        op: :redeem,
        code: state.code,
        amount_minor: 10_001,
        currency: "USD",
        occurred_at: at
      },
      extra
    )
  end

  test "confirmed-delivery attribution has exact boundaries and no stale reuse" do
    evidence = %{delivery_status: :confirmed, delivered_at: @delivered}
    assert Attribution.eligible?(evidence, @delivered, 0)
    assert Attribution.eligible?(evidence, @checkin, 300)
    refute Attribution.eligible?(evidence, DateTime.add(@checkin, 1, :microsecond), 300)
    refute Attribution.eligible?(evidence, DateTime.add(@delivered, -1, :microsecond), 300)
    refute Attribution.eligible?(%{evidence | delivery_status: :queued}, @checkin, 300)
    refute Attribution.eligible?(%{delivery_status: :confirmed}, @checkin, 300)
    refute Attribution.eligible?(evidence, @checkin, -1)

    assert Attribution.eligible?(
             Map.put(evidence, :last_attributed_at, DateTime.add(@delivered, -1)),
             @checkin,
             300
           )

    refute Attribution.eligible?(
             Map.put(evidence, :last_attributed_at, @delivered),
             @checkin,
             300
           )
  end

  test "touchpoint generation keeps the legacy non-ambiguous alphabet" do
    for n <- [1, 6, 8, 64] do
      code = Touchpoint.code(n)
      assert String.length(code) == n
      assert String.match?(code, ~r/\A[23456789ABCDEFGHJKMNPQRSTUVWXYZ]+\z/)
    end
  end

  test "restaurant redemption is one-use, replayable and snapshots the rate" do
    {:ok, initial} = Redemption.new("restaurant", "visit-1", "CODE1", @delivered, true, 50_000)
    candidate = event(initial, "receipt-1", @checkin)

    {:ok, final, :accepted} = Redemption.redeem(initial, "restaurant", :cashier, candidate, 300)
    assert final.phase == :redeemed
    assert final.commission_minor == 500
    assert final.rate_ppm == 50_000

    assert {:ok, final, :duplicate} =
             Redemption.redeem(final, "restaurant", :cashier, candidate, 300)

    assert {:ok, final} = Redemption.replay(initial, "restaurant", [candidate, candidate], 300)

    assert {:error, :idempotency_conflict} =
             Redemption.redeem(
               final,
               "restaurant",
               :cashier,
               %{candidate | amount_minor: 500},
               300
             )

    assert {:error, :already_redeemed} =
             Redemption.redeem(
               final,
               "restaurant",
               :cashier,
               event(final, "another", @checkin),
               300
             )
  end

  test "truck repair uses same core without cross-merchant authorization" do
    {:ok, initial} =
      Redemption.new("truck-repair", "visit-2", "CODE2", @delivered, false, 900_000)

    assert initial.rate_ppm == 0

    assert {:error, :wrong_merchant} =
             Redemption.redeem(
               initial,
               "restaurant",
               :cashier,
               event(initial, "one", @checkin),
               300
             )

    assert {:error, :invalid_redemption} =
             Redemption.redeem(
               initial,
               "truck-repair",
               :telegram,
               event(initial, "one", @checkin),
               300
             )

    {:ok, final, :accepted} =
      Redemption.redeem(initial, "truck-repair", :cashier, event(initial, "one", @checkin), 300)

    assert final.commission_minor == 0
  end

  test "malformed, expired, stale and wrong-code candidates fail closed" do
    {:ok, initial} = Redemption.new("merchant", "visit", "CODE", @delivered, true, 500_000)
    assert {:error, :redemption_expired} =
             Redemption.redeem(initial, "merchant", :cashier, event(initial, "a", @checkin), 299)

    assert {:error, :invalid_redemption} =
             Redemption.redeem(
               initial,
               "merchant",
               :cashier,
               event(initial, "a", @checkin, %{code: "bad"}),
               300
             )

    assert {:error, :invalid_currency} =
             Redemption.redeem(
               initial,
               "merchant",
               :cashier,
               event(initial, "a", @checkin, %{currency: "usd"}),
               300
             )

    assert {:error, :invalid_redemption} =
             Redemption.redeem(
               initial,
               "merchant",
               :cashier,
               event(initial, "a", @checkin, %{amount_minor: 0}),
               300
             )

    assert {:error, :stale_redemption_version} =
             Redemption.redeem(
               initial,
               "merchant",
               :cashier,
               event(initial, "a", @checkin, %{expected_version: 1}),
               300
             )
  end

  test "integer commission is explicitly half-up, not a money settlement" do
    assert Redemption.commission_minor(101, 500_000) == 51
    assert Redemption.commission_minor(100, 500_000) == 50
    assert Redemption.commission_minor(10_001, 50_000) == 500
    assert Redemption.commission_minor(987, 0) == 0
    assert Redemption.commission_minor(987, 1_000_000) == 987
    assert {:error, :invalid_amount_or_rate} = Redemption.commission_minor(10, -1)
    assert {:error, :invalid_visit} = Redemption.new("m", "v", "c", @delivered, true, 1_000_001)
  end
end

