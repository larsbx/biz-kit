defmodule Mix.Tasks.Restaurant.Revoke do
  @shortdoc "Revoke a restaurant device's ledger grant, signed by governance"
  @moduledoc """
      mix restaurant.revoke KEY_ID --chapter CHAPTER --merchant SHOP --server https://order.example

  Shows the device the key belongs to and signs its revocation with the
  governance key in HARNESS_KEYS_DIR. The key is refused from then on and is
  never granted again; give a replacement device a new key. Does not start an
  application or writer. Without Mix: `RestaurantHost.ReleaseTasks.revoke/1`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    shell = Mix.shell()
    io = %{info: &shell.info/1, confirm: &shell.yes?/1}

    case RestaurantHost.DeviceRevoker.run(args, io) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("cannot revoke: #{reason}")
    end
  end
end
