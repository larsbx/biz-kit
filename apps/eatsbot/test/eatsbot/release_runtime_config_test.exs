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
                OUTBOX_DISPATCHER_ENABLED SPRUCE_GOOSE_OBAN_ENABLED TELEGRAM_BOT_TOKEN
                TELEGRAM_WEBHOOK TELEGRAM_WEBHOOK_SECRET)

  defp read_runtime(env) do
    code = """
    config = Config.Reader.read!(#{inspect(@runtime)}, env: :prod)
    repo = get_in(config, [:eatsbot, Eatsbot.Repo]) || []
    IO.puts("eatsbot_repo_url=\#{inspect(repo[:url])}")
    IO.puts("telegram_token=\#{inspect(get_in(config, [:telegex, :token]))}")
    handler = get_in(config, [:eatsbot, Eatsbot.Extensions.TelegramBot.Handler]) || []
    IO.puts("telegram_webhook=\#{inspect(handler[:webhook_url])}")
    IO.puts("telegram_secret=\#{inspect(handler[:webhook_secret])}")
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

  # A release is built once and configured where it runs, so the bot's settings
  # are read when it boots, not baked in when it is compiled.
  test "the eatsbot release reads the Telegram bot's settings at boot" do
    telegram = [
      {"TELEGRAM_BOT_TOKEN", "123:token"},
      {"TELEGRAM_WEBHOOK", "https://eatsbot.example/telegram"},
      {"TELEGRAM_WEBHOOK_SECRET", "webhook-secret"}
    ]

    {output, status} = read_runtime([{"RELEASE_NAME", "eatsbot"} | @eatsbot_env ++ telegram])

    assert status == 0, output
    assert output =~ ~s(telegram_token="123:token")
    assert output =~ ~s(telegram_webhook="https://eatsbot.example/telegram")
    assert output =~ ~s(telegram_secret="webhook-secret")
  end

  # The webhook rejects every update that lacks the secret, so a webhook without
  # one would be a bot that silently ignores everyone.
  test "the eatsbot release refuses a Telegram webhook without its secret" do
    env = [
      {"RELEASE_NAME", "eatsbot"},
      {"TELEGRAM_WEBHOOK", "https://eatsbot.example/telegram"} | @eatsbot_env
    ]

    {output, status} = read_runtime(env)

    assert status != 0
    assert output =~ "TELEGRAM_WEBHOOK_SECRET"
  end

  for {label, secret} <- [
        {"empty", ""},
        {"space", " "},
        {"embedded space", "abc def"},
        {"punctuation", "abc!"},
        {"newline", "abc\n"},
        {"unicode", "café"},
        {"too long", String.duplicate("a", 257)}
      ] do
    test "the eatsbot release rejects a #{label} Telegram secret" do
      for webhook <- [nil, "https://eatsbot.example/telegram"] do
        env = [
          {"RELEASE_NAME", "eatsbot"},
          {"TELEGRAM_WEBHOOK", webhook},
          {"TELEGRAM_WEBHOOK_SECRET", unquote(secret)} | @eatsbot_env
        ]

        {output, status} = read_runtime(env)
        assert status != 0
        assert output =~ "TELEGRAM_WEBHOOK_SECRET"
        assert output =~ "1-256 characters"
      end
    end
  end

  test "the eatsbot release accepts both secret length boundaries and permitted characters" do
    for secret <- ["a", String.duplicate("Az09_-", 42) <> "Az09"] do
      env = [
        {"RELEASE_NAME", "eatsbot"},
        {"TELEGRAM_WEBHOOK", "https://eatsbot.example/telegram"},
        {"TELEGRAM_WEBHOOK_SECRET", secret} | @eatsbot_env
      ]

      {output, status} = read_runtime(env)
      assert status == 0, output
      assert output =~ "telegram_secret=#{inspect(secret)}"
    end
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
