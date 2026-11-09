# Run from the repository root with Elixir 1.19.0. No Mix dependencies are needed.
# The original commit must be present (CI uses fetch-depth: 0).
baseline = "cdf942ec8a30e8b6164438ef384a3d170891dda6"

paths = [
  "apps/barter_core/lib/barter_core/cross_currency_setoff.ex",
  "apps/barter_core/test/cross_currency_setoff_test.exs",
  "apps/coop_substrate/lib/coop_substrate/commercial_setoff_proof.ex",
  "apps/coop_substrate/lib/coop_substrate/commercial_setoff_sources.ex",
  "apps/coop_substrate/test/commercial_setoff_proof_test.exs",
  "apps/coop_substrate/test/commercial_setoff_sources_test.exs"
]

strip_metadata = fn ast ->
  Macro.prewalk(ast, fn
    {form, metadata, arguments} when is_list(metadata) -> {form, [], arguments}
    other -> other
  end)
end

for path <- paths do
  original =
    case System.cmd("git", ["show", baseline <> ":" <> path], stderr_to_stdout: true) do
      {source, 0} -> source
      {output, status} -> raise "git show failed (#{status}) for #{path}: #{output}"
    end

  current = File.read!(path)
  before_ast = original |> Code.string_to_quoted!() |> strip_metadata.()
  after_ast = current |> Code.string_to_quoted!() |> strip_metadata.()

  unless before_ast == after_ast do
    raise "format-only AST equivalence failed for #{path}"
  end

  IO.puts("UNCHANGED_AST\t#{path}")
end

IO.puts(
  "PASS: #{length(paths)} files have equivalent parsed ASTs to #{baseline}; source metadata ignored."
)
