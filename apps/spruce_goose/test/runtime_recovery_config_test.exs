defmodule SpruceGoose.RuntimeRecoveryConfigTest do
  use ExUnit.Case, async: true

  defp read_runtime(extra_env, opts \\ []) do
    code = """
    config = Config.Reader.read!(#{inspect(SpruceGoose.UmbrellaRuntime.path())}, env: :prod)
    app = Keyword.fetch!(config, :spruce_goose)
    oban = Keyword.fetch!(app, Oban)
    IO.puts(\"queues=\#{inspect(Keyword.fetch!(oban, :queues))}\")
    IO.puts(\"plugins=\#{inspect(Keyword.fetch!(oban, :plugins))}\")
    IO.puts(\"expected_genesis_actor=\#{Keyword.fetch!(app, :expected_genesis_actor)}\")
    """

    genesis_env =
      if Keyword.get(opts, :include_genesis?, true) do
        [{"SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR", "configured-genesis"}]
      else
        []
      end

    System.cmd("elixir", ["-e", code],
      env:
        [
          {"DATABASE_URL", "ecto://rehearsal:rehearsal@127.0.0.1/rehearsal"},
          {"TOKEN_SIGNING_SECRET", String.duplicate("x", 64)},
          {"OUTBOX_DISPATCHER_ENABLED", "false"}
        ] ++ SpruceGoose.UmbrellaRuntime.peer_env() ++ genesis_env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  test "recovery mode can disable every Oban queue and plugin" do
    {output, status} = read_runtime([{"SPRUCE_GOOSE_OBAN_ENABLED", "false"}])
    assert status == 0, output
    assert output =~ "queues=false"
    assert output =~ "plugins=false"
    assert output =~ "expected_genesis_actor=configured-genesis"
  end

  test "production runtime refuses to start without an expected Genesis actor" do
    {output, status} =
      read_runtime([{"SPRUCE_GOOSE_OBAN_ENABLED", "false"}], include_genesis?: false)

    assert status != 0
    assert output =~ "SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR is required in production"
  end

  test "outbox dispatch refuses to start while Oban is disabled" do
    {output, status} =
      read_runtime([
        {"SPRUCE_GOOSE_OBAN_ENABLED", "false"},
        {"OUTBOX_DISPATCHER_ENABLED", "true"},
        {"OUTBOX_HANDLER", "SpruceGoose.Outbox.TestHandler"}
      ])

    assert status != 0
    assert output =~ "OUTBOX_DISPATCHER_ENABLED requires SPRUCE_GOOSE_OBAN_ENABLED"
  end
end
