defmodule SpruceGoose.DispatchRuntimeConfigTest do
  @moduledoc """
  Dispatch's production section of the umbrella's runtime configuration: the
  OIDC issuer's settings are required only when the OIDC token verifier is
  selected (docs/architecture/2026-10-21-native-sign-in.md).
  """
  use ExUnit.Case, async: true

  @oidc_env ~w(OIDC_ISSUER OIDC_CLIENT_ID_API OIDC_AUDIENCE)

  defp read_runtime(extra_env) do
    code = """
    config = Config.Reader.read!(#{inspect(SpruceGoose.UmbrellaRuntime.path())}, env: :prod)
    dispatch = Keyword.fetch!(config, :dispatch)
    IO.puts("verifier=\#{inspect(dispatch[:identity][:token_verifier])}")
    IO.puts("oidc_issuer=\#{inspect(dispatch[:oidc_issuer])}")
    """

    peer_env =
      Enum.reject(SpruceGoose.UmbrellaRuntime.peer_env(), fn {k, _v} -> k in @oidc_env end)

    System.cmd("elixir", ["-e", code],
      env:
        [
          {"DATABASE_URL", "ecto://rehearsal:rehearsal@127.0.0.1/rehearsal"},
          {"TOKEN_SIGNING_SECRET", String.duplicate("x", 64)},
          {"SPRUCE_GOOSE_MCP_ENABLED", "false"},
          {"OUTBOX_DISPATCHER_ENABLED", "false"},
          {"SPRUCE_GOOSE_OBAN_ENABLED", "false"},
          {"SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR", "configured-genesis"}
        ] ++ peer_env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  test "a deployment on biz-kit sessions needs no OIDC issuer settings" do
    {output, status} =
      read_runtime([{"TOKEN_VERIFIER_ADAPTER", "Dispatch.Identity.Tokens.BizKitSession"}])

    assert status == 0, output
    assert output =~ "verifier=Dispatch.Identity.Tokens.BizKitSession"
    assert output =~ "oidc_issuer=nil"
  end

  test "the OIDC verifier still refuses to start without its issuer" do
    {output, status} = read_runtime([])

    assert status != 0
    assert output =~ "OIDC_ISSUER"
  end

  test "with its settings, the OIDC verifier starts as before" do
    {output, status} =
      read_runtime(
        Enum.filter(SpruceGoose.UmbrellaRuntime.peer_env(), fn {k, _v} -> k in @oidc_env end)
      )

    assert status == 0, output
    assert output =~ "oidc_issuer=\"https://issuer.invalid\""
  end
end
