Code.require_file("support.exs", __DIR__)

defmodule MerchantPilot.Formal.LeanChecks do
  alias MerchantPilot.Formal.Support, as: S
  alias CommerceCore.MerchantPilot.{Intake, Scorecard, Validation}
  def option(nil), do: "none"
  def option(value), do: "(some (#{value}))"

  def cases do
    equations =
      for refund <- [0, 1000, 10000],
          expense <- [0, 7000],
          complete <- [false, true],
          closed <- [false, true],
          reduce: [] do
        acc ->
          b = S.base()
          original = hd(b["orders"])
          data = original["data"]
          refunds = if refund == 0, do: [], else: [Map.put(hd(data["refunds"]), "minor", refund)]

          fees =
            Map.new([{"servicing_store", 250, 50}, {"platform", 600, 100}], fn {role, gross,
                                                                                partial} ->
              reversed =
                cond do
                  refund == 10000 -> gross
                  refund == 1000 -> partial
                  true -> 0
                end

              {role, Map.put(data["fees"][role], "reversed_minor", reversed)}
            end)

          data =
            Map.merge(data, %{
              "refunds" => refunds,
              "fees" => fees,
              "reconciled_at" => if(closed, do: data["reconciled_at"], else: nil)
            })

          b =
            b
            |> Map.put("orders", [Map.put(original, "data", data)])
            |> put_in(["costs", Access.at(0), "data", "items", Access.at(0), "minor"], expense)
            |> put_in(["costs", Access.at(0), "data", "complete"], complete)

          {snapshot, _} = Intake.export!(b)
          result = Scorecard.score!(snapshot, include_orders: true)
          net_store = 250 - fees["servicing_store"]["reversed_minor"]
          net_platform = 600 - fees["platform"]["reversed_minor"]

          model = [
            {"merchant", 10000 - refund - net_store - net_platform,
             if(complete, do: expense, else: nil), 25},
            {"servicing_store", net_store, 180, 10},
            {"platform", net_platform, 200, 100}
          ]

          acc ++
            Enum.flat_map(model, fn {role, revenue, cost, overhead} ->
              actual =
                get_in(result, [
                  "economics",
                  "orders",
                  Access.at(0),
                  "roles",
                  role,
                  "margin_minor"
                ])

              expression = "reportedMargin #{closed} #{option(revenue)} #{option(cost)}"

              cohort =
                get_in(result, [
                  "economics",
                  "by_currency",
                  "USD",
                  role,
                  "scenarios",
                  Access.at(0),
                  "cohort_margin_minor"
                ])

              [
                "example : #{expression} = #{option(actual)} := by decide",
                "example : cohortMargin true [(#{expression})] #{option(overhead)} = #{option(cohort)} := by decide"
              ]
            end)
      end

    {snapshot, _} = Intake.export!(S.base())
    result = Scorecard.score!(snapshot)
    origin = Validation.time!(snapshot["cohort_started_at"])
    now = Validation.time!(snapshot["as_of"]) - origin

    buckets =
      Enum.map(snapshot["requests"], fn request ->
        q = Validation.time!(request["qualified_at"]) - origin

        ending =
          if is_nil(request["withdrawn_at"]),
            do: nil,
            else: Validation.time!(request["withdrawn_at"]) - origin

        "(bucket #{q} #{now} #{option(ending)} 604800)"
      end)
      |> Enum.join(", ")

    totals =
      for {label, metric} <- [
            {"mature", "denominator"},
            {"incomplete", "incomplete"},
            {"earlyWithdrawal", "withdrawn_early"}
          ] do
        "example : ([#{buckets}].filter (fun b => b == Bucket.#{label})).length = #{result["demand"]["seven_day_match"][metric]} := by decide"
      end

    {Enum.join(["import MerchantPilot", "open MerchantPilot"] ++ equations ++ totals, "\n") <>
       "\n", length(equations) + length(totals)}
  end

  def run(opts, here) do
    {examples, count} = cases()

    if opts[:emit] do
      File.write!(opts[:emit], examples)
      S.print(%{"runtime_examples" => count, "implementation" => "Elixir"})
    else
      lean = S.executable(Keyword.get(opts, :lean, "lean"))

      checker =
        S.executable(
          Keyword.get(opts, :leanchecker, Path.join(Path.dirname(lean), "leanchecker"))
        )

      source = File.read!(Path.join(here, "MerchantPilot.lean"))
      names = Regex.scan(~r/^theorem\s+(\w+)/m, source) |> Enum.map(&Enum.at(&1, 1))

      S.temp(fn work ->
        File.write!(Path.join(work, "MerchantPilot.lean"), source)

        env = [
          {"LEAN_PATH", work},
          {"PATH", Path.dirname(lean) <> ":" <> System.get_env("PATH", "")}
        ]

        run = fn command, args, extra ->
          S.run!(command, args, Keyword.merge([cd: work, env: env], extra))
        end

        version = run.(lean, ["--version"], []) |> String.trim()

        S.assert!(
          String.contains?(version, "version 4.35.0"),
          "Use repository-pinned Lean 4.35.0"
        )

        run.(lean, ["-o", "MerchantPilot.olean", "MerchantPilot.lean"], [])
        run.(checker, ["--fresh", "MerchantPilot"], [])
        File.write!(Path.join(work, "RuntimeChecks.lean"), examples)
        run.(lean, ["RuntimeChecks.lean"], [])

        audit_file =
          "import MerchantPilot\n" <>
            Enum.map_join(names, "\n", &("#print axioms MerchantPilot." <> &1))

        File.write!(Path.join(work, "Audit.lean"), audit_file)
        audit = run.(lean, ["Audit.lean"], [])
        allowed = MapSet.new(~w(propext Classical.choice Quot.sound))

        for [_, group] <- Regex.scan(~r/depends on axioms:\s*\[([^]]*)\]/, audit) do
          actual =
            group |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

          S.assert!(MapSet.subset?(actual, allowed), "Unapproved transitive axiom")
        end

        S.assert!(not String.contains?(audit, "sorryAx"), "Admitted proof in audit")

        File.write!(
          Path.join(work, "WrongRefund.lean"),
          "import MerchantPilot\nopen MerchantPilot\nexample : (margins 10000 10000 0 0 7000 180 200).merchant = 0 := by decide\n"
        )

        run.(lean, ["WrongRefund.lean"], negative: true, marker: "decide")

        File.write!(
          Path.join(work, "MixedCurrency.lean"),
          "import MerchantPilot\nopen MerchantPilot\ndef invalid := addAmount (⟨1⟩ : Amount .USD) (⟨1⟩ : Amount .JPY)\n"
        )

        run.(lean, ["MixedCurrency.lean"], negative: true, marker: "type mismatch")

        S.print(%{
          "toolchain" => version,
          "named_proofs" => length(names),
          "runtime_examples" => count,
          "negative_controls" => 2,
          "permitted_axioms" => Enum.sort(allowed),
          "dataset" => "synthetic",
          "implementation" => "Elixir"
        })
      end)
    end
  end
end

{opts, [], []} =
  OptionParser.parse(System.argv(), strict: [lean: :string, leanchecker: :string, emit: :string])

MerchantPilot.Formal.LeanChecks.run(opts, __DIR__)
