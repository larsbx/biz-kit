defmodule Eatsbot.Extensions.TelegramBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :eatsbot_extension_telegram_bot,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
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
      {:telegex, path: "../../vendor/telegex"},
      {:finch, "~> 0.13"},
      {:multipart, "~> 0.4.0"},
      {:remote_ip, "~> 1.2"},
      {:ash_authentication, "~> 5.0-rc"},
      {:ash_authentication_phoenix, "~> 3.0-rc"},
      {:ash_graphql, "~> 1.12.0"},
      {:ash_phoenix, "~> 2.3.25"},
      {:ash_postgres, "~> 2.15.2"},
      {:ash, "~> 3.37.2"},
      {:ash_admin, "~> 1.3.2"},
      {:phoenix, "~> 1.8"},
      {:eatsbot_core, in_umbrella: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
