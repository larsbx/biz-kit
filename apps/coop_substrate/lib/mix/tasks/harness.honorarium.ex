defmodule Mix.Tasks.Harness.Honorarium do
  @shortdoc "Honoraria: accrue|paid --interviewee --amount [--note] · list · clear 0|1 --note [--yes]"
  @moduledoc """
  The honorarium rail (docs/honorarium_rail.md). `accrue` records what's
  owed (runbook 0.1 — always allowed); `paid` attests an EXTERNAL payout and
  is unrepresentable until counsel clearance is declared via `clear 1`
  (declare `clear 0` to stop payouts again); `list` is the tracker — a fold,
  never a spreadsheet.
  """

  use Mix.Task

  alias CoopSubstrate.Harness
  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    case args do
      ["accrue" | rest] ->
        {opts, _, _} = OptionParser.parse(rest, strict: [interviewee: :string, amount: :integer])
        CLI.report(Ops.honorarium(required(opts, :interviewee), required(opts, :amount)))

      ["paid" | rest] ->
        {opts, _, _} =
          OptionParser.parse(rest,
            strict: [interviewee: :string, amount: :integer, note: :string]
          )

        CLI.report(
          Ops.honorarium_paid(required(opts, :interviewee), required(opts, :amount), opts[:note])
        )

      ["list"] ->
        case Harness.honoraria("chapter-genesis") do
          {:ok, []} ->
            CLI.ok("no honoraria recorded")

          {:ok, rows} ->
            Enum.each(rows, fn row ->
              CLI.ok(
                "interviewee=#{row.interviewee_ref} accrued=#{row.accrued_minor} " <>
                  "paid=#{row.paid_minor} outstanding=#{row.outstanding_minor}"
              )
            end)

          {:error, reason} ->
            CLI.reject(reason)
        end

      ["clear", value | rest] when value in ["0", "1"] ->
        {opts, _, _} = OptionParser.parse(rest, strict: [note: :string, yes: :boolean])
        note = required(opts, :note)

        CLI.confirm!(
          "Declare honorarium payout clearance = #{value} (note: #{note}).\n" <>
            "1 opens external payouts; 0 stops them.",
          opts
        )

        CLI.report(Ops.honorarium_clearance(String.to_integer(value), note))

      _ ->
        Mix.raise(
          "usage: mix harness.honorarium accrue|paid --interviewee IV-1 --amount 5000 [--note ...] " <>
            "| list | clear 0|1 --note <counsel ref> [--yes]"
        )
    end
  end

  defp required(opts, key), do: opts[key] || Mix.raise("missing --#{key}")
end
