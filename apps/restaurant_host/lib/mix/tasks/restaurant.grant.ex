defmodule Mix.Tasks.Restaurant.Grant do
  @shortdoc "Enroll a restaurant device with a governance-signed ledger grant"
  @moduledoc """
      mix restaurant.grant board-1 --chapter CHAPTER --merchant SHOP --server https://order.example

  Reviews and signs the configured checkout or kitchen capability with the
  governance key in HARNESS_KEYS_DIR. Does not start an application or writer.
  The same workflow is available without Mix via RestaurantHost.Enrollment.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    shell = Mix.shell()
    io = %{info: &shell.info/1, confirm: &shell.yes?/1}

    case RestaurantHost.Enrollment.run(args, io) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("cannot grant: #{reason}")
    end
  end
end
