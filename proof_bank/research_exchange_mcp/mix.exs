defmodule ResearchExchange.MixProject do
  use Mix.Project
  def project, do: [app: :research_exchange, version: "0.1.0", elixir: "~> 1.19", deps: []]
  def application, do: [extra_applications: [:crypto]]
end
