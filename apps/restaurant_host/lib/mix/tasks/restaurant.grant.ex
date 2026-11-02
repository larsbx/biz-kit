defmodule Mix.Tasks.Restaurant.Grant do
  @shortdoc "Grant a restaurant device on the ledger: restaurant.grant <DEVICE> [--server URL] [--yes]"
  @moduledoc """
  Grant one of a running restaurant host's devices (the storefront, or a
  kitchen board) its ledger authority (`RestaurantHost.DeviceGrants`):

      mix restaurant.grant board-1 --server https://order.example

  Shows the grant the host asks for (merchant, device, key, actor and actions)
  and, once confirmed, signs exactly that with the governance key in
  `HARNESS_KEYS_DIR` and submits it; the host's ledger admits it. The seed
  never leaves this machine. Does not start the application.
  `--server` defaults to `$RESTAURANT_URL`, then `http://127.0.0.1:4070`.
  """
  use Mix.Task

  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops
  alias RestaurantHost.DeviceGrants

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {opts, positional, _} = OptionParser.parse(args, strict: [server: :string, yes: :boolean])

    device =
      List.first(positional) ||
        Mix.raise("usage: mix restaurant.grant <DEVICE> [--server URL] [--yes]")

    base = opts[:server] || System.get_env("RESTAURANT_URL", "http://127.0.0.1:4070")
    url = base <> "/api/device-grants/" <> Client.segment(device)

    with {:ok, signer} <- Ops.load_signer("governance"),
         {:ok, details} <- Client.get(url) do
      p = details["payload"]

      Mix.shell().info("""
      Restaurant device grant, chapter #{details["chapter_id"]}
        merchant  #{p["merchant_id"]}
        device    #{p["device_id"]} (key #{p["key_id"]}, public key #{p["pubkey"]})
        acts as   #{p["actor"]}: #{Enum.join(p["actions"], ", ")}
      Sign it with governance key #{signer.key_id}?
      """)

      if opts[:yes] || Mix.shell().yes?("Grant?") do
        case Client.sign_held(url, signer, &DeviceGrants.grants?(&1, details)) do
          {:ok, %{"event_id" => id}} -> Mix.shell().info("granted: event #{id}")
          {:error, reason} -> Mix.raise("not granted: #{inspect(reason)}")
        end
      else
        Mix.shell().info("not granted; nothing was signed")
      end
    else
      {:error, reason} -> Mix.raise("cannot grant: #{inspect(reason)}")
    end
  end
end
