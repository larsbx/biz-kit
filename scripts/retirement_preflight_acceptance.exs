# Run from the umbrella root:
#   MIX_ENV=test mix run --no-start scripts/retirement_preflight_acceptance.exs
#
# This deliberately does not load test_helper.exs or LogCase: neither the
# application/appender nor the test alias that drops the event store is run.
# Optional real COPY restore acceptance requires an explicit disposable,
# loopback PostgreSQL endpoint on a nondefault port:
#   RETIREMENT_TEST_DATABASE_URL=postgres://user:password@127.0.0.1:PORT/postgres \
#     MIX_ENV=test mix run --no-start scripts/retirement_preflight_acceptance.exs --restore

root = Path.expand("..", __DIR__)
app = Path.join(root, "apps/coop_substrate")

restore? =
  case System.argv() do
    [] -> false
    ["--restore"] -> true
    _ -> raise "expected no arguments, or --restore with a disposable local database"
  end

if restore? do
  url = System.get_env("RETIREMENT_TEST_DATABASE_URL")

  with {:ok, opts} <- CoopSubstrate.DatabaseUrl.to_postgrex(url),
       true <- opts[:hostname] in ["127.0.0.1", "localhost", "::1"],
       port when is_integer(port) and port > 1024 and port != 5432 <- opts[:port],
       "postgres" <- opts[:database] do
    Application.put_env(:coop_substrate, CoopSubstrate.EventStore, opts)
    {:ok, _} = Application.ensure_all_started(:postgrex)
  else
    _ ->
      raise "--restore requires RETIREMENT_TEST_DATABASE_URL naming a disposable loopback " <>
              "PostgreSQL endpoint on an explicit nondefault port and database postgres"
  end
end

ExUnit.start(autorun: false)

tests = ~w(
  history_archive_preflight_test.exs
  history_archive_governance_test.exs
  history_archive_boundary_test.exs
  writer_fence_gate_test.exs
)

tests = if restore?, do: tests ++ ["history_archive_restore_test.exs"], else: tests
Enum.each(tests, &Code.require_file(Path.join([app, "test", &1])))

if restore?,
  do: Code.require_file(Path.join(root, "scripts/tests/retirement_ledger_reader_test.exs"))

result = ExUnit.run()
System.halt(if(result.failures == 0, do: 0, else: 1))
