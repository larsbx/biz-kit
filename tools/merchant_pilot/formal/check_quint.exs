Code.require_file("support.exs", __DIR__)
alias MerchantPilot.Formal.{Replay, Support}
{opts, [], []} = OptionParser.parse(System.argv(), strict: [quint: :string, verify: :boolean])
quint = Support.executable(Keyword.get(opts, :quint, "quint"))
version = Support.run!(quint, ["--version"]) |> String.trim()
Support.assert!(version == "0.32.0", "Use pinned Quint 0.32.0")
spec = Path.join(__DIR__, "merchant_pilot.qnt")
Support.run!(quint, ["typecheck", spec]) |> IO.write()
Support.run!(quint, ["test", spec, "--backend=typescript"]) |> IO.write()

Support.run!(quint, [
  "run",
  spec,
  "--backend=typescript",
  "--invariant=safety",
  "--max-samples=3000",
  "--max-steps=25",
  "--seed=1",
  "--verbosity=1"
])
|> IO.write()

Support.temp(fn root ->
  Support.run!(quint, [
    "test",
    spec,
    "--backend=typescript",
    "--match=^(?!mutation).*Test$",
    "--out-itf=" <> Path.join(root, "test-{test}-{seq}.itf.json")
  ])
  |> IO.write()

  Support.run!(quint, [
    "run",
    spec,
    "--backend=typescript",
    "--invariant=safety",
    "--max-samples=100",
    "--max-steps=25",
    "--seed=2",
    "--n-traces=100",
    "--out-itf=" <> Path.join(root, "trace-{seq}.itf.json"),
    "--verbosity=1"
  ])
  |> IO.write()

  traces = Path.wildcard(Path.join(root, "*.itf.json")) |> Enum.sort()
  Support.assert!(length(traces) == 112, "Expected 100 simulator and twelve scenario traces")
  Replay.traces(traces) |> Support.print()
end)

if opts[:verify] do
  Support.temp(fn directory ->
    Support.run!(quint, ["verify", spec, "--invariant=safety", "--max-steps=8"], cd: directory)
    |> IO.write()
  end)
else
  IO.puts(
    "Apalache bounded verification NOT requested; simulation is not exhaustive verification."
  )
end
