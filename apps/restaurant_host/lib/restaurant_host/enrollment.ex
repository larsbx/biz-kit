defmodule RestaurantHost.Enrollment do
  @moduledoc """
  Operator-side restaurant enrollment, shared by Mix and the production
  release. It starts only the HTTP client, never a ledger writer or the host.
  The governance seed is read from HARNESS_KEYS_DIR and never sent or printed.
  """
  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops
  alias RestaurantHost.DeviceGrants

  @usage "restaurant.grant DEVICE --chapter CHAPTER --merchant MERCHANT [--server URL] [--yes]"

  def run(args, io \\ %{info: &IO.puts/1, confirm: &confirm/1}) do
    with {:ok, device, chapter, merchant, base, yes?} <- options(args),
         {:ok, details} <- fetch(base, device, chapter, merchant),
         {:ok, signer} <- load_signer() do
      p = details["payload"]

      io.info.("""
      Restaurant device grant, chapter #{chapter}
        merchant  #{merchant}
        device    #{device} (key #{p["key_id"]}, public key #{p["pubkey"]})
        acts as   #{p["actor"]}: #{Enum.join(p["actions"], ", ")}
      Sign it with governance key #{signer.key_id}?
      """)

      if yes? or io.confirm.("Grant?") do
        case approve(base, details, signer) do
          {:ok, %{"event_id" => id}} ->
            io.info.("granted: event #{id}")
            :ok

          _ ->
            {:error, :not_granted}
        end
      else
        io.info.("not granted; nothing was signed")
        :ok
      end
    end
  end

  @doc "Release entry point; returns a failing exit status on refusal."
  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Enrollment refused: #{reason}. Usage: #{@usage}")
        System.halt(1)
    end
  end

  def fetch(base, device, chapter, merchant) do
    with {:ok, details} <- Client.get(url(base, device)),
         true <- DeviceGrants.valid_details?(details),
         true <- details["chapter_id"] == chapter,
         true <- details["payload"]["merchant_id"] == merchant,
         true <- details["payload"]["device_id"] == device do
      {:ok, details}
    else
      _ -> {:error, :unexpected_proposal}
    end
  end

  def approve(base, details, signer) do
    if DeviceGrants.valid_details?(details) do
      Client.sign_held(
        url(base, details["payload"]["device_id"]),
        signer,
        &DeviceGrants.grants?(&1, details),
        Map.take(details, ["chapter_id"])
        |> Map.put("merchant_id", details["payload"]["merchant_id"])
      )
    else
      {:error, :unexpected_proposal}
    end
  rescue
    _ -> {:error, :unexpected_proposal}
  end

  defp load_signer do
    case Ops.load_signer("governance") do
      {:ok, signer} -> {:ok, signer}
      _ -> {:error, :governance_key_unavailable}
    end
  rescue
    _ -> {:error, :governance_key_unavailable}
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

    base = opts[:server] || System.get_env("RESTAURANT_URL", "http://127.0.0.1:4070")

    with [device] <- positional,
         [] <- invalid,
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?([device, opts[:chapter], opts[:merchant]], &DeviceGrants.identifier?/1),
         %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path} <-
           URI.parse(base),
         true <- is_binary(host) and host != "" and path in [nil, "", "/"],
         true <-
           scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"]) do
      {:ok, device, opts[:chapter], opts[:merchant], String.trim_trailing(base, "/"),
       opts[:yes] == true}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp url(base, device), do: base <> "/api/device-grants/" <> Client.segment(device)
  defp confirm(prompt), do: IO.gets(prompt <> " [y/N] ") in ["y\n", "Y\n", "yes\n"]
end
