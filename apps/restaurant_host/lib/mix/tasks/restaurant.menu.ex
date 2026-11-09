defmodule Mix.Tasks.Restaurant.Menu do
  @shortdoc "Add or replace a restaurant menu item with a governance-signed ledger fact"
  @moduledoc """
      mix restaurant.menu put calzone.json --chapter CHAPTER --merchant SHOP --server https://order.example

  Shows the item next to the one it replaces, at the menu's current version,
  and signs it with the governance key in HARNESS_KEYS_DIR. Does not start an
  application or writer. The same workflow is available without Mix via
  `RestaurantHost.ReleaseTasks.menu/1`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    shell = Mix.shell()
    io = %{info: &shell.info/1, confirm: &shell.yes?/1}

    case RestaurantHost.MenuEditor.run(args, io) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("cannot update the menu: #{reason}")
    end
  end
end
