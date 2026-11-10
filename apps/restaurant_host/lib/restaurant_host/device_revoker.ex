defmodule RestaurantHost.DeviceRevoker do
  @moduledoc """
  Operator-side device revocation, shared by Mix and the production release:
  reads the granted devices with a governance-signed request, shows the one
  the key belongs to, and signs exactly its revocation with the governance key
  in HARNESS_KEYS_DIR. It starts only the HTTP client, never a ledger writer.
  """
  alias CoopSubstrate.Governance.Client
  alias RestaurantHost.{DeviceGrants, DeviceRevocations, Enrollment}

  @usage "restaurant.revoke KEY_ID --chapter CHAPTER --merchant MERCHANT [--server URL] [--yes]"

  def run(args, io \\ %{info: &IO.puts/1, confirm: &confirm/1}) do
    with {:ok, key, chapter, merchant, base, yes?} <- options(args),
         {:ok, signer} <- Enrollment.load_signer(),
         {:ok, %{"devices" => devices}} <- Client.get_signed(base <> "/api/devices", signer),
         %{} = d <- Enum.find(devices, &(&1["key_id"] == key)) || {:error, :unknown_device} do
      io.info.("""
      Revoke a restaurant device, chapter #{chapter}
        merchant  #{merchant}
        device    #{d["device_id"]} (key #{key})
        acts as   #{d["actor"]}: #{Enum.join(d["actions"], ", ")}
      The key is refused from then on and can never be granted again.
      Sign it with governance key #{signer.key_id}?
      """)

      if yes? or io.confirm.("Revoke?") do
        url = base <> "/api/device-revocations/" <> Client.segment(key)
        params = %{"chapter_id" => chapter, "merchant_id" => merchant}
        expected = &DeviceRevocations.matches?(&1, chapter, merchant, key)

        case Client.sign_held(url, signer, expected, params) do
          {:ok, %{"event_id" => id}} ->
            io.info.("revoked: event #{id}")
            :ok

          _ ->
            {:error, :not_revoked}
        end
      else
        io.info.("not revoked; nothing was signed")
        :ok
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :unexpected_devices}
    end
  rescue
    _ -> {:error, :unexpected_devices}
  end

  @doc "Release entry point; returns a failing exit status on refusal."
  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Revocation refused: #{reason}. Usage: #{@usage}")
        System.halt(1)
    end
  end

  defp options(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          server: [:string, :keep],
          chapter: [:string, :keep],
          merchant: [:string, :keep],
          yes: [:boolean, :keep]
        ]
      )

    with [key] <- positional,
         [] <- invalid,
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?([key, opts[:chapter], opts[:merchant]], &DeviceGrants.identifier?/1),
         {:ok, base} <- Enrollment.server(opts[:server]) do
      {:ok, key, opts[:chapter], opts[:merchant], base, opts[:yes] == true}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp confirm(prompt), do: IO.gets(prompt <> " [y/N] ") in ["y\n", "Y\n", "yes\n"]
end
