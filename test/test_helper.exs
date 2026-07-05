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

ExUnit.start()
