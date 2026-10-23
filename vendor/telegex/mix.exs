defmodule Telegex.MixProject do
  use Mix.Project

  # Vendored from Hex telegex 1.8.0; see vendor/telegex/VENDOR.md.
  def project do
    [
      app: :telegex,
      version: "1.8.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Telegex.Application, []}]
  end

  # The runtime dependencies Hex publishes for 1.8.0.
  defp deps do
    [
      {:typed_struct, "~> 0.3.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
