defmodule CommerceCore.MerchantPilotTest do
  use ExUnit.Case, async: true
  alias CommerceCore.MerchantPilot
  alias CommerceCore.MerchantPilot.{CLI, Intake, InvalidEvidence, JSON, Scorecard, Validation}
  @root Path.expand("../../../tools/merchant_pilot", __DIR__)
  defp fixture(name), do: @root |> Path.join(name) |> File.read!() |> JSON.decode!()
  defp intake, do: fixture("intake.synthetic.json")
  defp snapshot, do: fixture("synthetic.json")
  defp report(b), do: b |> Intake.export!() |> elem(0) |> Scorecard.score!(include_orders: true)

  defp row(b, collection, index, path, value),
    do: put_in(b, [collection, Access.at(index)] ++ path, value)

  defp baseline(r, role),
    do:
      get_in(r, [
        "economics",
        "by_currency",
        "USD",
        role,
        "scenarios",
        Access.at(0),
        "cohort_margin_minor"
      ])

  test "original snapshot report matches the frozen synthetic reference" do
    assert Scorecard.score!(snapshot(), include_orders: true) ==
             fixture("parity.synthetic.json")["scorecard"]
  end

  test "intake snapshot, provenance, hashes and report preserve the original contract" do
    {s, m} = Intake.export!(intake())
    reference = fixture("parity.synthetic.json")["intake"]
    assert JSON.digest(s) == reference["snapshot_sha256"]
    assert JSON.digest(m) == reference["manifest_sha256"]
    assert Scorecard.score!(s, include_orders: true) == reference["report"]
    assert length(s["requests"]) == 4
    assert map_size(m["excluded_requests"]) == 1
    assert {:ok, {^s, ^m}} = MerchantPilot.export(intake())
  end

  test "mature, withdrawn and incomplete demand and separate role margins" do
    r = report(intake())

    assert r["demand"]["seven_day_match"] == %{
             "numerator" => 1,
             "denominator" => 2,
             "incomplete" => 1,
             "withdrawn_early" => 1
           }

    assert r["orders"]["intervention_disputes_30_day"] == %{
             "numerator" => 1,
             "denominator" => 1,
             "incomplete" => 1
           }

    assert r["orders"]["merchant_repeat_90_day"] == %{
             "numerator" => 0,
             "denominator" => 1,
             "incomplete" => 0
           }

    roles = get_in(r, ["economics", "orders", Access.at(0), "roles"])

    assert Map.new(roles, fn {role, d} -> {role, d["margin_minor"]} end) == %{
             "merchant" => 1300,
             "servicing_store" => 20,
             "platform" => 300
           }

    assert baseline(r, "merchant") == nil
    assert baseline(r, "platform") == nil
    assert baseline(r, "servicing_store") == 10
  end

  test "unknown, incomplete and absent expense pools never become zero" do
    b = intake()

    variants = [
      Map.update!(b, "costs", &tl/1),
      row(b, "costs", 0, ["data", "complete"], false),
      row(b, "costs", 0, ["data", "items", Access.at(0), "minor"], nil)
    ]

    for variant <- variants do
      {s, _} = Intake.export!(variant)
      assert hd(s["orders"])["costs_minor"]["merchant"] == nil

      roles =
        get_in(Scorecard.score!(s, include_orders: true), [
          "economics",
          "orders",
          Access.at(0),
          "roles"
        ])

      assert roles["merchant"]["status"] == "missing_inputs"
      assert roles["platform"]["margin_minor"] == 300
    end
  end

  test "unallocated pools require explicit review; confirmed empty pool attests zero" do
    b =
      intake()
      |> Map.update!("costs", &Enum.reject(&1, fn row -> is_nil(row["data"]["order_id"]) end))

    {s, _} = Intake.export!(b)
    assert Enum.all?(s["unallocated_costs"], &is_nil(&1["minor"]))
    assert baseline(report(b), "servicing_store") == nil

    pool =
      b["costs"]
      |> hd()
      |> Map.put("record_id", String.duplicate("f", 32))
      |> Map.put("data", %{
        "order_id" => nil,
        "role" => "servicing_store",
        "currency" => "USD",
        "complete" => true,
        "items" => []
      })

    assert baseline(report(Map.update!(b, "costs", &(&1 ++ [pool]))), "servicing_store") == 20
  end

  test "full refund and fee reversals preserve incurred costs" do
    b = row(intake(), "orders", 0, ["data", "refunds", Access.at(0), "minor"], 10000)

    b =
      update_in(
        b,
        ["orders", Access.at(0), "data", "fees"],
        &Map.new(&1, fn {role, fee} ->
          {role, Map.put(fee, "reversed_minor", fee["gross_minor"])}
        end)
      )

    roles = get_in(report(b), ["economics", "orders", Access.at(0), "roles"])

    assert Map.new(roles, fn {role, d} -> {role, d["margin_minor"]} end) == %{
             "merchant" => -7000,
             "servicing_store" => -180,
             "platform" => -200
           }
  end

  test "cancelled accepted orders retain attributable losses" do
    b =
      update_in(intake(), ["orders", Access.at(0), "data"], fn d ->
        Map.merge(d, %{
          "outcome" => "cancelled",
          "paid_at" => nil,
          "gross_minor" => 0,
          "refunds" => [],
          "returned_at" => nil,
          "disputed_at" => nil,
          "fees" => %{
            "servicing_store" => %{"gross_minor" => 0, "reversed_minor" => 0},
            "platform" => %{"gross_minor" => 0, "reversed_minor" => 0}
          }
        })
      end)

    r = report(b)
    assert r["orders"]["cancelled"] == %{"numerator" => 1, "denominator" => 1}

    assert get_in(r, ["economics", "orders", Access.at(0), "roles", "merchant", "margin_minor"]) ==
             -7000
  end

  test "quote revisions survive and an old revision cannot be accepted after supersession" do
    {s, m} = Intake.export!(intake())
    [old, new, _] = Enum.sort_by(s["quotes"], & &1["issued_at"])
    assert old["withdrawn_at"] == new["issued_at"]
    assert old["id"] != new["id"]
    assert hd(s["orders"])["quote_id"] == new["id"]
    assert length(m["quote_ids"]) == 3

    assert_raise InvalidEvidence, fn ->
      intake() |> row("orders", 0, ["data", "quote_ref", "revision"], 1) |> Intake.export!()
    end
  end

  test "sharing revocation preserves historical demand while retention is separately required" do
    b =
      intake()
      |> row("requests", 2, ["data", "withdrawn_at"], nil)
      |> row("requests", 2, ["data", "consent", "sharing_revoked_at"], "2026-01-03T00:00:00Z")

    assert report(b)["demand"]["seven_day_match"]["withdrawn_early"] == 1

    assert_raise InvalidEvidence, fn ->
      b
      |> row("requests", 2, ["data", "consent", "measurement_authorized"], false)
      |> Intake.export!()
    end
  end

  test "source coverage and individual follow-up must reach common cutoff" do
    for {collection, path} <- [
          {"coverage", ["through"]},
          {"requests", ["data", "observed_through"]},
          {"orders", ["data", "observed_through"]}
        ] do
      assert_raise InvalidEvidence, fn ->
        intake() |> row(collection, 0, path, "2026-04-09T00:00:00Z") |> Intake.export!()
      end
    end
  end

  test "recent first-order merchants remain outside the mature 90-day cohort" do
    b = intake()
    recent = Enum.at(b["requests"], 3)["data"]["id"]

    b =
      b
      |> Map.put("as_of", "2026-02-21T00:00:00Z")
      |> Map.update!("requests", &Enum.reject(&1, fn row -> row["data"]["id"] == recent end))
      |> Map.update!(
        "invitations",
        &Enum.reject(&1, fn row -> row["data"]["request_id"] == recent end)
      )
      |> Map.update!(
        "quotes",
        &Enum.reject(&1, fn row -> row["data"]["request_id"] == recent end)
      )
      |> Map.update!("orders", &Enum.take(&1, 1))

    b =
      Enum.reduce(Intake.collections(), b, fn collection, acc ->
        Map.update!(
          acc,
          collection,
          &Enum.map(&1, fn row -> Map.put(row, "captured_at", b["as_of"]) end)
        )
      end)

    assert report(b)["orders"]["merchant_repeat_90_day"] == %{
             "numerator" => 0,
             "denominator" => 0,
             "incomplete" => 1
           }
  end

  test "source record assembly and input ordering are deterministic" do
    b = intake()
    control = Map.drop(b, Intake.collections())

    records =
      for collection <- Intake.collections(),
          record <- b[collection],
          do: %{"collection" => collection, "record" => record}

    assert Intake.assemble!(control, records) == b

    scrambled =
      Enum.reduce(["coverage" | Intake.collections()], b, fn collection, acc ->
        Map.update!(acc, collection, &Enum.reverse/1)
      end)

    assert Intake.export!(scrambled) == Intake.export!(b)

    assert Scorecard.score!(snapshot()) ==
             Scorecard.score!(
               Enum.reduce(
                 ~w(requests invitations quotes orders unallocated_costs),
                 snapshot(),
                 fn k, acc -> Map.update!(acc, k, &Enum.reverse/1) end
               )
             )
  end

  test "strict intake admission rejects adversarial identity, consent, payment, fee and cost inputs" do
    bad = [
      fn b -> Map.put(b, "dataset", "observed") end,
      fn b -> Map.update!(b, "requests", &(&1 ++ [hd(&1)])) end,
      fn b ->
        row(b, "merchants", 1, ["data", "business_id"], hd(b["merchants"])["data"]["business_id"])
      end,
      fn b -> row(b, "quotes", 0, ["owner_id"], String.duplicate("f", 32)) end,
      fn b -> row(b, "quotes", 1, ["revision"], 3) end,
      fn b -> row(b, "quotes", 1, ["data", "supersedes_revision"], true) end,
      fn b -> row(b, "quotes", 1, ["data", "supersedes_revision"], 1.0) end,
      fn b -> row(b, "quotes", 1, ["data", "withdrawn_at"], "2026-01-04T00:00:00Z") end,
      fn b -> row(b, "quotes", 1, ["data", "expires_at"], "2026-01-04T00:00:00Z") end,
      fn b -> row(b, "quotes", 0, ["data", "buyer_fee_minor"], 100) end,
      fn b -> row(b, "quotes", 1, ["data", "qualified"], false) end,
      fn b -> row(b, "orders", 0, ["data", "stock_terms_revalidated"], false) end,
      fn b -> row(b, "orders", 0, ["data", "provider_verified"], false) end,
      fn b ->
        row(b, "orders", 0, ["data", "refunds", Access.at(0), "provider_verified"], false)
      end,
      fn b -> row(b, "orders", 0, ["data", "refunds", Access.at(0), "minor"], 10001) end,
      fn b -> row(b, "requests", 0, ["data", "consent", "granted_at"], nil) end,
      fn b -> row(b, "requests", 0, ["data", "geography"], String.duplicate("f", 32)) end,
      fn b ->
        update_in(b, ["requests", Access.at(0), "data"], &Map.put(&1, "email", "private-token"))
      end,
      fn b -> row(b, "merchants", 0, ["data", "withdrawn_at"], "2026-01-02T00:00:00Z") end,
      fn b -> row(b, "fee_arrangements", 0, ["data", "payer"], "buyer") end,
      fn b ->
        row(
          b,
          "fee_arrangements",
          0,
          ["data", "merchant_id"],
          Enum.at(b["merchants"], 1)["data"]["id"]
        )
      end,
      fn b -> row(b, "costs", 0, ["data", "currency"], "JPY") end,
      fn b ->
        row(
          b,
          "costs",
          1,
          ["data", "items", Access.at(0), "id"],
          hd(b["costs"])["data"]["items"] |> hd() |> Map.fetch!("id")
        )
      end
    ]

    for mutate <- bad,
        do: assert_raise(InvalidEvidence, fn -> mutate.(intake()) |> Intake.export!() end)
  end

  test "an absent store cannot conceal an explicitly unknown cost pool" do
    b = intake()

    pool =
      Enum.at(b["costs"], 1)
      |> Map.put("record_id", String.duplicate("f", 32))
      |> Map.put("data", %{
        "order_id" => Enum.at(b["orders"], 1)["data"]["id"],
        "role" => "servicing_store",
        "currency" => "USD",
        "complete" => false,
        "items" => []
      })

    assert_raise InvalidEvidence, fn ->
      Map.update!(b, "costs", &(&1 ++ [pool])) |> Intake.export!()
    end
  end

  test "integer minor units, same-currency orders, unique refunds and fee reversal bounds" do
    s = snapshot()

    for {path, value} <- [
          {["currency"], "JPY"},
          {["gross_minor"], true},
          {["gross_minor"], 1.5},
          {["gross_minor"], 999},
          {["paid_at"], nil},
          {["returned_at"], "2026-01-05T00:00:00Z"},
          {["reconciled_at"], "2026-01-21T00:00:00Z"},
          {["fees", "platform", "reversed_minor"], 10000}
        ] do
      assert_raise InvalidEvidence, fn ->
        row(s, "orders", 0, path, value) |> Scorecard.score!()
      end
    end

    assert_raise InvalidEvidence, fn ->
      row(
        s,
        "orders",
        0,
        ["refunds", Access.at(1), "id"],
        hd(s["orders"])["refunds"] |> hd() |> Map.fetch!("id")
      )
      |> Scorecard.score!()
    end
  end

  test "future and unlinked source responses and costs for an absent store are refused" do
    assert_raise InvalidEvidence, fn ->
      row(snapshot(), "invitations", 0, ["responded_at"], "2026-04-11T00:00:00Z")
      |> Scorecard.score!()
    end

    assert_raise InvalidEvidence, fn ->
      row(snapshot(), "invitations", 0, ["responded_at"], nil) |> Scorecard.score!()
    end

    assert_raise InvalidEvidence, fn ->
      row(snapshot(), "orders", 1, ["costs_minor", "servicing_store"], 1) |> Scorecard.score!()
    end
  end

  test "fees of unknown amount withhold only dependent roles" do
    s = row(snapshot(), "orders", 0, ["fees", "platform"], nil)

    roles =
      get_in(Scorecard.score!(s, include_orders: true), [
        "economics",
        "orders",
        Access.at(0),
        "roles"
      ])

    assert roles["merchant"]["status"] == "missing_inputs"
    assert roles["platform"]["status"] == "missing_inputs"
    assert roles["servicing_store"]["margin_minor"] == 20
  end

  test "empty cohort and no-sales costs remain explicit" do
    s =
      Enum.reduce(
        ~w(requests invitations quotes orders unallocated_costs),
        snapshot(),
        &Map.put(&2, &1, [])
      )

    r = Scorecard.score!(s)
    assert r["economics"]["by_currency"] == %{}
    assert r["orders"]["merchant_repeat_90_day"]["denominator"] == 0
    assert r["demand"]["first_quote_within_seven_days"]["median_seconds"] == nil
    s = Map.put(snapshot(), "orders", [])
    r = Scorecard.score!(s)
    assert baseline(r, "merchant") == -hd(s["unallocated_costs"])["minor"]
  end

  test "sequential retry retains failed order but counts one accepted request" do
    s = snapshot()
    old = Enum.at(s["orders"], 3)

    quote =
      Enum.at(s["quotes"], 5)
      |> Map.merge(%{"id" => String.duplicate("a", 32), "expires_at" => "2026-01-25T00:00:00Z"})

    retry =
      Map.merge(old, %{
        "id" => String.duplicate("b", 32),
        "quote_id" => quote["id"],
        "accepted_at" => "2026-01-19T00:00:00Z",
        "outcome" => "pending",
        "outcome_at" => nil,
        "reconciled_at" => nil
      })

    s = s |> Map.update!("quotes", &(&1 ++ [quote])) |> Map.update!("orders", &(&1 ++ [retry]))
    r = Scorecard.score!(s)
    assert r["orders"]["accepted_orders"] == 6
    assert r["demand"]["requests_with_accepted_order"] == 5

    assert_raise InvalidEvidence, fn ->
      row(s, "orders", 5, ["accepted_at"], old["outcome_at"]) |> Scorecard.score!()
    end
  end

  test "strict JSON rejects duplicate keys at any nesting and trailing data" do
    for bad <- [~s({"a":1,"a":2}), ~s({"a":{"x":1,"x":2}}), ~s({} {}), <<255>>] do
      assert catch_error(JSON.decode!(bad))
    end

    assert JSON.decode!(" {\"n\":null,\"b\":false,\"v\":9007199254740993} \n") == %{
             "n" => nil,
             "b" => false,
             "v" => 9_007_199_254_740_993
           }

    assert JSON.encode!(%{"z" => nil, "a" => 1}) == ~s({"a":1,"z":null})
  end

  test "public API returns privacy-safe validation errors for malformed evidence" do
    for bad <- [nil, [], %{}, true, %{"private-token" => 1}] do
      assert MerchantPilot.score(bad) == {:error, :invalid_evidence}
      assert MerchantPilot.export(bad) == {:error, :invalid_evidence}
    end

    assert_raise InvalidEvidence, fn -> Validation.time!("2026-02-30T00:00:00Z") end
  end

  test "default report omits IDs" do
    report = Scorecard.score!(snapshot()) |> JSON.encode!()

    for collection <- ~w(requests quotes orders),
        do: refute(String.contains?(report, hd(snapshot()[collection])["id"]))
  end

  test "private files are owner-only, destination is exclusive and CLI errors never echo input" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "merchant-elixir-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    output = Path.join(directory, "export")
    {s, m} = Intake.export!(intake())
    assert CLI.write!(output, s, m) == :ok

    for path <- [output | Path.wildcard(Path.join(output, "*"))] do
      assert Bitwise.band(File.stat!(path).mode, 0o077) == 0
    end

    assert_raise File.Error, fn -> CLI.write!(output, s, m) end
    source = Path.join(directory, "input.json")
    File.write!(source, ~s({"secret":"private-token"}))

    message =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert CLI.main(["export", source, Path.join(directory, "bad")]) == 2
      end)

    refute message =~ "private-token"
    refute message =~ source
    refute File.exists?(Path.join(directory, "bad"))
  end
end
