defmodule Eatsbot.ReleaseRuntimeConfigTest do
  @moduledoc """
  eatsbot's section of the umbrella's single runtime configuration.

  A release reads `config/runtime.exs` whole, so every app's production checks run
  unless the section is gated on `RELEASE_NAME`. eatsbot ships as its own `eatsbot`
  release: it must boot on its own settings alone, and the releases that do not
  carry it must not need them.
  """
  use ExUnit.Case, async: true

  @runtime Path.expand("../../../../config/runtime.exs", __DIR__)

  @eatsbot_env [
    {"DATABASE_URL", "ecto://eatsbot:eatsbot@127.0.0.1/eatsbot"},
    {"SECRET_KEY_BASE", String.duplicate("e", 64)},
    {"GEOCODING_TOKEN", "geocoding-token"},
    {"TOKEN_SIGNING_SECRET", String.duplicate("t", 64)}
  ]

  # Every other app's production variables, unset so none leaks in from the shell.
  @peer_vars ~w(PUBLIC_BASE_URL OIDC_ISSUER OIDC_CLIENT_ID_API OIDC_AUDIENCE
                APPLICATION_ENCRYPTION_KEY_ID DIAGNOSTICS_TOKEN
                SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR SPRUCE_GOOSE_MCP_ENABLED
                OUTBOX_DISPATCHER_ENABLED SPRUCE_GOOSE_OBAN_ENABLED)

  defp read_runtime(env) do
    code = """
    config = Config.Reader.read!(#{inspect(@runtime)}, env: :prod)
    repo = get_in(config, [:eatsbot, Eatsbot.Repo]) || []
    IO.puts("eatsbot_repo_url=\#{inspect(repo[:url])}")
    """

    unset = for var <- @peer_vars ++ Enum.map(@eatsbot_env, &elem(&1, 0)), do: {var, nil}
    System.cmd("elixir", ["-e", code], env: unset ++ env, stderr_to_stdout: true)
  end

  test "the eatsbot release boots on eatsbot's settings alone" do
    {output, status} = read_runtime([{"RELEASE_NAME", "eatsbot"} | @eatsbot_env])

    assert status == 0, output
    assert output =~ ~s(eatsbot_repo_url="ecto://eatsbot:eatsbot@127.0.0.1/eatsbot")
  end

  test "the eatsbot release still refuses to start without its own secrets" do
    env = [{"RELEASE_NAME", "eatsbot"} | List.keydelete(@eatsbot_env, "TOKEN_SIGNING_SECRET", 0)]
    {output, status} = read_runtime(env)

    assert status != 0
    assert output =~ "TOKEN_SIGNING_SECRET"
  end

  test "the orchestration release needs none of eatsbot's settings and gets none" do
    {output, status} =
      read_runtime([
        {"RELEASE_NAME", "orchestration"},
        {"DATABASE_URL", "ecto://orchestration:orchestration@127.0.0.1/orchestration"},
        {"TOKEN_SIGNING_SECRET", String.duplicate("x", 64)},
        {"SPRUCE_GOOSE_MCP_ENABLED", "false"},
        {"OUTBOX_DISPATCHER_ENABLED", "false"},
        {"SPRUCE_GOOSE_OBAN_ENABLED", "false"},
        {"SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR", "configured-genesis"}
      ])

    assert status == 0, output
    assert output =~ "eatsbot_repo_url=nil"
  end
end
