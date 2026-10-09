defmodule Eatsbot.Extensions.TelegramBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :eatsbot_extension_telegram_bot,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # The application and its path dependencies resolve one shared security lock.
      lockfile: Path.expand("../../mix.lock", __DIR__),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:telegex, "~> 1.8.0"},
      {:finch, "~> 0.13"},
      {:multipart, "~> 0.4.0"},
      {:remote_ip, "~> 1.2"},
      {:ash_authentication, "~> 4.15.0"},
      {:ash_authentication_phoenix, "~> 2.17.4"},
      {:ash_graphql, "~> 1.12.0"},
      {:ash_phoenix, "~> 2.3.25"},
      {:ash_postgres, "~> 2.14.5"},
      {:ash, "~> 3.34.6"},
      {:ash_admin, "~> 1.3.2"},
      {:phoenix, "~> 1.7.24"},
      {:eatsbot_core,
       path:
         Path.join(["..", "..", "core"])
         |> Path.expand()},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
