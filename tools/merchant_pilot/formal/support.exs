Code.require_file("../load.exs", __DIR__)

defmodule MerchantPilot.Formal.Support do
  alias CommerceCore.MerchantPilot.JSON
  def base, do: Path.expand("../intake.synthetic.json", __DIR__) |> File.read!() |> JSON.decode!()

  def assert!(condition, message \\ "Formal conformance mismatch") do
    unless condition, do: raise(message)
  end

  def temp(fun) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "merchant-formal-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(directory)

    try do
      fun.(directory)
    after
      File.rm_rf!(directory)
    end
  end

  def executable(name) do
    if String.contains?(name, "/"),
      do: Path.expand(name),
      else: System.find_executable(name) || raise("Required verification executable is missing")
  end

  def run!(command, args, opts \\ []) do
    {output, status} =
      System.cmd(
        command,
        args,
        Keyword.merge([stderr_to_stdout: true], Keyword.take(opts, [:cd, :env]))
      )

    if Keyword.get(opts, :negative, false) do
      marker = Keyword.fetch!(opts, :marker)

      assert!(
        status != 0 and String.contains?(output, marker),
        "Negative control did not fail for the required reason: " <> output
      )
    else
      assert!(status == 0, output)
    end

    output
  end

  def print(value), do: IO.puts(JSON.encode!(value))
end

defmodule MerchantPilot.Formal.Replay do
  alias CommerceCore.MerchantPilot.{Intake, Scorecard, InvalidEvidence, JSON}
  alias MerchantPilot.Formal.Support, as: S

  def date(day),
    do: DateTime.add(~U[2026-01-01 00:00:00Z], day * 86_400, :second) |> DateTime.to_iso8601()

  def optional(day), do: if(day < 0, do: nil, else: date(day))

  def bundle(state) do
    b = S.base()
    cutoff = date(state["now"])
    first = hd(b["requests"])
    second = Enum.at(b["requests"], 1)

    canonical =
      Map.put(
        second,
        "data",
        Map.merge(first["data"], %{"id" => second["data"]["id"], "withdrawn_at" => nil})
      )

    status =
      cond do
        state["qualified"] -> "qualified"
        state["duplicate"] -> "duplicate"
        true -> "unreviewed"
      end

    request =
      first
      |> put_in(["data", "status"], status)
      |> put_in(["data", "qualified_at"], if(state["qualified"], do: date(0), else: nil))
      |> put_in(["data", "withdrawn_at"], nil)
      |> put_in(
        ["data", "duplicate_of"],
        if(state["duplicate"], do: canonical["data"]["id"], else: nil)
      )

    revoked =
      cond do
        state["qualified"] -> optional(state["requestEnd"])
        not state["sharing"] -> cutoff
        true -> nil
      end

    request = put_in(request, ["data", "consent", "sharing_revoked_at"], revoked)

    requests =
      for row <- [request, canonical], do: put_in(row, ["data", "observed_through"], cutoff)

    invitation =
      hd(b["invitations"])
      |> put_in(["data", "invited_at"], date(0))
      |> put_in(["data", "responded_at"], optional(state["firstAt"]))

    quotes =
      b["quotes"]
      |> Enum.take(state["revision"])
      |> Enum.with_index(1)
      |> Enum.map(fn {row, rev} ->
        row
        |> put_in(
          ["data", "issued_at"],
          date(state[if(rev == 1, do: "firstAt", else: "secondAt")])
        )
        |> put_in(["data", "expires_at"], date(12))
        |> put_in(
          ["data", "withdrawn_at"],
          optional(state[if(rev == 1, do: "firstEnd", else: "secondEnd")])
        )
      end)

    original = hd(b["orders"])

    refund =
      hd(original["data"]["refunds"])
      |> Map.merge(%{"at" => optional(state["refundAt"]), "minor" => state["refund"]})

    fees =
      Map.new([{"servicing_store", 250, 50}, {"platform", 600, 100}], fn {role, gross, partial} ->
        reversed =
          cond do
            state["refund"] == 10000 -> gross
            state["refund"] == 1000 -> partial
            true -> 0
          end

        {role,
         %{
           "gross_minor" => if(state["paidAt"] >= 0, do: gross, else: 0),
           "reversed_minor" => reversed
         }}
      end)

    data =
      Map.merge(original["data"], %{
        "accepted_at" => optional(state["acceptedAt"]),
        "promised_by" => date(state["acceptedAt"] + 2),
        "outcome" => if(state["deliveredAt"] >= 0, do: "fulfilled", else: "pending"),
        "outcome_at" => optional(state["deliveredAt"]),
        "paid_at" => optional(state["paidAt"]),
        "returned_at" => nil,
        "disputed_at" => nil,
        "reconciled_at" => optional(state["closedAt"]),
        "gross_minor" => if(state["paidAt"] >= 0, do: 10000, else: nil),
        "provider_verified" => state["paidAt"] >= 0,
        "observed_through" => cutoff,
        "refunds" => if(state["refund"] > 0, do: [refund], else: []),
        "fees" => fees
      })
      |> put_in(["quote_ref", "revision"], state["accepted"])

    orders = if state["accepted"] > 0, do: [Map.put(original, "data", data)], else: []

    fields = %{
      "merchant" => "merchantKnown",
      "servicing_store" => "storeKnown",
      "platform" => "platformKnown"
    }

    costs =
      b["costs"]
      |> Enum.reject(&(not is_nil(&1["data"]["order_id"]) and state["accepted"] == 0))
      |> Enum.map(fn row ->
        pool = row["data"]
        unallocated = is_nil(pool["order_id"])

        items =
          Enum.map(
            pool["items"],
            &Map.put(&1, "incurred_at", date(if unallocated, do: 0, else: state["acceptedAt"]))
          )

        Map.put(
          row,
          "data",
          Map.merge(pool, %{
            "items" => items,
            "complete" => state[if(unallocated, do: "overheadKnown", else: fields[pool["role"]])]
          })
        )
      end)

    b =
      Map.merge(b, %{
        "as_of" => cutoff,
        "requests" => requests,
        "invitations" => if(state["revision"] > 0, do: [invitation], else: []),
        "quotes" => quotes,
        "orders" => orders,
        "costs" => costs,
        "coverage" => Enum.map(b["coverage"], &Map.put(&1, "through", date(state["coverage"])))
      })

    Enum.reduce(Intake.collections(), b, fn collection, acc ->
      Map.update!(
        acc,
        collection,
        &Enum.map(&1, fn row -> Map.put(row, "captured_at", cutoff) end)
      )
    end)
  end

  def check(state, report) do
    {snapshot, _} = Intake.export!(bundle(state))
    S.assert!(report["accepted"])
    result = Scorecard.score!(snapshot)
    S.assert!(result["demand"]["qualified_requests"] - 1 == report["requests"])

    S.assert!(
      result["demand"]["seven_day_match"]["denominator"] - if(state["now"] >= 7, do: 1, else: 0) ==
        report["denominator"]
    )

    S.assert!(result["demand"]["seven_day_match"]["numerator"] == report["matched"])

    for {role, flag, value} <- [
          {"merchant", "merchantKnown", "merchant"},
          {"servicing_store", "storeKnown", "store"},
          {"platform", "platformKnown", "platform"}
        ] do
      actual =
        hd(result["economics"]["by_currency"]["USD"][role]["scenarios"])["cohort_margin_minor"]

      expected = if report[flag], do: report[value], else: nil
      S.assert!(actual == expected)
    end

    true
  rescue
    e in InvalidEvidence ->
      S.assert!(
        not report["accepted"] and e.reason == :coverage,
        "Unexpected exporter refusal during conformance"
      )

      false
  end

  defp decode(%{"#bigint" => value} = map) when map_size(map) == 1, do: String.to_integer(value)
  defp decode(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, decode(value)} end)
  defp decode(list) when is_list(list), do: Enum.map(list, &decode/1)
  defp decode(value), do: value

  def traces(files) do
    {count, admitted, unique} =
      Enum.reduce(files, {0, 0, MapSet.new()}, fn file, acc ->
        trace = file |> File.read!() |> JSON.decode!() |> decode()
        S.assert!(trace["states"] != [])

        Enum.reduce(trace["states"], acc, fn state, {count, admitted, unique} ->
          valid = check(state["s"], state["report"])
          {count + 1, admitted + if(valid, do: 1, else: 0), MapSet.put(unique, state["s"])}
        end)
      end)

    %{
      "traces" => length(files),
      "states" => count,
      "unique_states" => MapSet.size(unique),
      "admitted" => admitted,
      "coverage_refusals" => count - admitted,
      "dataset" => "synthetic",
      "implementation" => "Elixir"
    }
  end
end
