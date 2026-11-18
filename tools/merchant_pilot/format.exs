# Default Elixir formatter; intentionally avoids loading unrelated umbrella projects.
root = Path.expand("../..", __DIR__)

paths = [
  "apps/commerce_core/lib/commerce_core/merchant_pilot.ex",
  "apps/commerce_core/lib/commerce_core/merchant_pilot/*.ex",
  "apps/commerce_core/lib/mix/tasks/commerce.pilot.ex",
  "apps/commerce_core/test/merchant_pilot_test.exs",
  "apps/commerce_core/mix.exs",
  "tools/merchant_pilot/*.exs",
  "tools/merchant_pilot/formal/*.exs"
]

files = Enum.flat_map(paths, &Path.wildcard(Path.join(root, &1))) |> Enum.sort()

for file <- files do
  original = File.read!(file)
  formatted = IO.iodata_to_binary(Code.format_string!(original, file: file)) <> "\n"

  if "--check" in System.argv() do
    if original != formatted, do: raise("Merchant pilot Elixir source needs formatting")
  else
    File.write!(file, formatted)
  end
end
