# Run from the repository root with Elixir 1.19.0. No Mix dependencies are needed.
# The original commit must be present (CI uses fetch-depth: 0).
# The historical baseline contains one test bug already corrected on main:
# length/1 does not accept the binary commitment. Acknowledge exactly that one
# assertion in exactly that test file, keeping strict AST comparison elsewhere.
defmodule CrossCurrencySetoff.HistoricalASTGuard do
  @corrected_test "apps/coop_substrate/test/commercial_setoff_proof_test.exs"
  @legacy "assert length(ctx.proof.commitment) == 32"
  @repaired "assert byte_size(ctx.proof.commitment) == 32"

  def compare(path, original, current) do
    before_ast = ast(original)
    after_ast = ast(current)

    with {:ok, expected, repairs} <- expected_ast(path, before_ast) do
      if expected == after_ast, do: {:ok, repairs}, else: {:error, :ast_changed}
    end
  end

  defp expected_ast(@corrected_test, before_ast) do
    legacy = ast(@legacy)
    repaired = ast(@repaired)

    {expected, repairs} =
      Macro.prewalk(before_ast, 0, fn
        ^legacy, count -> {repaired, count + 1}
        other, count -> {other, count}
      end)

    if repairs == 1,
      do: {:ok, expected, 1},
      else: {:error, {:unexpected_legacy_assertion_count, repairs}}
  end

  defp expected_ast(_path, before_ast), do: {:ok, before_ast, 0}

  defp ast(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {form, metadata, arguments} when is_list(metadata) -> {form, [], arguments}
      other -> other
    end)
  end

  # Exercise the real comparison function, including edits outside the allowed
  # expression. These controls do not weaken the comparison of the six files.
  def check_controls! do
    controls = [
      {"exact known correction", @corrected_test, @legacy, @repaired, {:ok, 1}},
      {"different expected byte count", @corrected_test, @legacy,
       "assert byte_size(ctx.proof.commitment) == 31", {:error, :ast_changed}},
      {"unrelated length call changed", @corrected_test, @legacy <> "\nassert length(items) == 2",
       @repaired <> "\nassert byte_size(items) == 2", {:error, :ast_changed}},
      {"correction in a different file", "unrelated_test.exs", @legacy, @repaired,
       {:error, :ast_changed}},
      {"missing historical assertion", @corrected_test, "assert true", "assert true",
       {:error, {:unexpected_legacy_assertion_count, 0}}},
      {"duplicate historical assertion", @corrected_test, @legacy <> "\n" <> @legacy,
       @repaired <> "\n" <> @repaired, {:error, {:unexpected_legacy_assertion_count, 2}}},
      {"current test still has binary length bug", @corrected_test, @legacy, @legacy,
       {:error, :ast_changed}},
      {"unrelated added expression", @corrected_test, @legacy, @repaired <> "\nassert false",
       {:error, :ast_changed}}
    ]

    for {name, path, original, current, expected} <- controls do
      actual = compare(path, original, current)
      unless actual == expected, do: raise("historical AST control failed: #{name}")
    end

    IO.puts("PASS: exact historical binary assertion repair and 7 adversarial AST controls.")
  end
end

CrossCurrencySetoff.HistoricalASTGuard.check_controls!()

baseline = "cdf942ec8a30e8b6164438ef384a3d170891dda6"

paths = [
  "apps/barter_core/lib/barter_core/cross_currency_setoff.ex",
  "apps/barter_core/test/cross_currency_setoff_test.exs",
  "apps/coop_substrate/lib/coop_substrate/commercial_setoff_proof.ex",
  "apps/coop_substrate/lib/coop_substrate/commercial_setoff_sources.ex",
  "apps/coop_substrate/test/commercial_setoff_proof_test.exs",
  "apps/coop_substrate/test/commercial_setoff_sources_test.exs"
]

for path <- paths do
  original =
    case System.cmd("git", ["show", baseline <> ":" <> path], stderr_to_stdout: true) do
      {source, 0} -> source
      {output, status} -> raise "git show failed (#{status}) for #{path}: #{output}"
    end

  current = File.read!(path)

  case CrossCurrencySetoff.HistoricalASTGuard.compare(path, original, current) do
    {:ok, 0} ->
      IO.puts("UNCHANGED_AST\t#{path}")

    {:ok, 1} ->
      IO.puts("AST_MATCH_WITH_DOCUMENTED_BINARY_ASSERTION_REPAIR\t#{path}")

    {:error, reason} ->
      raise "historical AST equivalence failed for #{path}: #{inspect(reason)}"
  end
end

IO.puts(
  "PASS: #{length(paths)} files match parsed ASTs at #{baseline}, except exactly one " <>
    "documented preexisting binary-length assertion repair; source metadata ignored."
)
