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
         {:ok, details, proposal} <- fetch_proposal(base, device, chapter, merchant),
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
        case approve_proposal(base, proposal, signer) do
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
    with {:ok, details, _proposal} <- fetch_proposal(base, device, chapter, merchant),
         do: {:ok, details}
  end

  def approve(base, details, signer) do
    with {:ok, proposal} <- DeviceGrants.decode_details(details),
         do: approve_proposal(base, proposal, signer)
  end

  defp fetch_proposal(base, device, chapter, merchant) do
    with {:ok, details} <- Client.get(url(base, device)),
         {:ok, proposal} <- DeviceGrants.decode_details(details),
         true <- proposal["chapter_id"] == chapter,
         true <- proposal["payload"]["merchant_id"] == merchant,
         true <- proposal["payload"]["device_id"] == device do
      {:ok, details, proposal}
    else
      _ -> {:error, :unexpected_proposal}
    end
  end

  defp approve_proposal(base, proposal, signer) do
    p = proposal["payload"]

    Client.sign_held(
      url(base, p["device_id"]),
      signer,
      &DeviceGrants.matches?(&1, proposal),
      %{"chapter_id" => proposal["chapter_id"], "merchant_id" => p["merchant_id"]}
    )
  rescue
    _ -> {:error, :unexpected_proposal}
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

    with [device] <- positional,
         [] <- invalid,
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?([device, opts[:chapter], opts[:merchant]], &DeviceGrants.identifier?/1),
         {:ok, base} <- server(opts[:server]) do
      {:ok, device, opts[:chapter], opts[:merchant], base, opts[:yes] == true}
    else
      _ -> {:error, :invalid_options}
    end
  rescue
    _ -> {:error, :invalid_options}
  end

  @doc """
  The host's base URL (`--server`, else `RESTAURANT_URL`, else local): HTTPS,
  or HTTP only on loopback, with no credentials, query or path.
  """
  def server(given) do
    base = given || System.get_env("RESTAURANT_URL", "http://127.0.0.1:4070")

    with %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path} <-
           URI.parse(base),
         true <- is_binary(host) and host != "" and path in [nil, "", "/"],
         true <-
           scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"]) do
      {:ok, String.trim_trailing(base, "/")}
    else
      _ -> {:error, :invalid_options}
    end
  end

  @doc "The governance signer from HARNESS_KEYS_DIR."
  def load_signer do
    case Ops.load_signer("governance") do
      {:ok, signer} -> {:ok, signer}
      _ -> {:error, :governance_key_unavailable}
    end
  rescue
    _ -> {:error, :governance_key_unavailable}
  end

  defp url(base, device), do: base <> "/api/device-grants/" <> Client.segment(device)
  defp confirm(prompt), do: IO.gets(prompt <> " [y/N] ") in ["y\n", "Y\n", "yes\n"]
end
