# Test-only registry extension (TypeRegistry :extra_event_types hook):
# a two-role type to exercise bilateral/asynchronous dual signing.
# Set once, before the suite, so async tests can read it safely.
Application.put_env(:coop_substrate, :extra_event_types, %{
  "TestBilateralEvent" => %{
    required_roles: ["author", "counterparty"],
    disclosure_class: :edges,
    stream: {:chapter_scoped, "test-bilateral"},
    payload: %{
      required: %{"terms" => :string, "amount_minor" => :int},
      optional: %{}
    }
  }
})

# Leave no ledger behind. Tests that forge history (`@tag :tampers_ledger`) end
# on records the application cannot boot against; handing one to the next run
# wedges it at `Log.init/1`, before the reset that would clear it can run.
ExUnit.after_suite(fn _results ->
  CoopSubstrate.LogCase.truncate_store!()
end)

ExUnit.start()
