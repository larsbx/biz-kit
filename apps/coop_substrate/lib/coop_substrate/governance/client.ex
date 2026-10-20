defmodule CoopSubstrate.Governance.Client do
  @moduledoc """
  Signing with a governance key on an administrator's machine, against the
  running server (`mix coop.enrol`, `mix coop.revoke`,
  `mix coop.offboard`).

  The server prepares an envelope and holds it; this client decodes the
  bytes it is asked to sign, signs only if `expected` accepts the decoded
  core, and submits the signature. Every call goes to the server over HTTP,
  so the server's own appender admits the result: no second appender runs
  against the store.
  """

  alias CoopSubstrate.{Canonical, Crypto}
  alias CoopSubstrate.Governance.Read

  @type signer :: %{key_id: String.t(), pubkey: binary(), seed: binary()}

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(url), do: request(:get, url, nil)

  @doc "A GET signed by the governance key (`Governance.Read`)."
  @spec get_signed(String.t(), signer()) :: {:ok, map()} | {:error, term()}
  def get_signed(url, signer), do: request(:get, url, nil, [authorization("GET", url, signer)])

  @doc """
  Ask `url` to prepare an envelope for `signer` (with any further `params`),
  check it with `expected` (decoded core → boolean), then sign and submit it
  to `url/<held id>`. The request to prepare is itself signed
  (`Governance.Read`), for routes that show only governance what they hold.
  """
  @spec sign_held(String.t(), signer(), (map() -> boolean()), map()) ::
          {:ok, map()} | {:error, term()}
  def sign_held(url, signer, expected, params \\ %{}) do
    with {:ok, held} <-
           request(:post, url, Map.put(params, "governance_key_id", signer.key_id), [
             authorization("POST", url, signer)
           ]),
         {:ok, bytes} <- Base.url_decode64(held["signing_bytes"], padding: false),
         {:ok, core} <- Canonical.decode(bytes),
         true <- (expected.(core) and signed_by?(core, signer)) or {:error, :not_what_was_shown} do
      signature = Base.url_encode64(Crypto.sign(bytes, signer.seed), padding: false)
      request(:post, url <> "/" <> segment(held["id"]), %{"signature" => signature})
    end
  end

  @doc """
  `sign_held/4` for a batch held as one (`Commands.hold_batch/4`): every
  command is decoded and `expected` judges them all, in order, before any is
  signed; then one signature each, submitted together.
  """
  @spec sign_batch(String.t(), signer(), ([map()] -> boolean()), map()) ::
          {:ok, map()} | {:error, term()}
  def sign_batch(url, signer, expected, params \\ %{}) do
    with {:ok, held} <-
           request(:post, url, Map.put(params, "governance_key_id", signer.key_id), [
             authorization("POST", url, signer)
           ]),
         {:ok, bytes} <- decode_all(held["commands"]),
         {:ok, cores} <- bytes |> Enum.map(&Canonical.decode/1) |> all_ok(),
         true <-
           (expected.(cores) and Enum.all?(cores, &signed_by?(&1, signer))) or
             {:error, :not_what_was_shown} do
      signatures =
        Enum.map(bytes, &Base.url_encode64(Crypto.sign(&1, signer.seed), padding: false))

      request(:post, url <> "/" <> segment(held["id"]), %{"signatures" => signatures})
    end
  end

  defp decode_all(commands) when is_list(commands),
    do: commands |> Enum.map(&Base.url_decode64(&1["signing_bytes"], padding: false)) |> all_ok()

  defp decode_all(_commands), do: {:error, :not_what_was_shown}

  defp all_ok(results) do
    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(results, &elem(&1, 1))},
      else: {:error, :not_what_was_shown}
  end

  @doc "`value` as one URL path segment: every reserved character escaped."
  @spec segment(String.t()) :: String.t()
  def segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @doc "The core names this governance key, and only it, as signer."
  def signed_by?(core, signer),
    do:
      core["signers"] == [
        %{"role" => "governance", "key_id" => signer.key_id, "pubkey" => {:bytes, signer.pubkey}}
      ]

  # A `CoopGovernance` Authorization header for this request.
  defp authorization(method, url, signer) do
    read = %{
      method: method,
      path: URI.parse(url).path,
      timestamp_ms: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      key_id: signer.key_id
    }

    sig = Base.url_encode64(Crypto.sign(Read.signing_bytes(read), signer.seed), padding: false)

    {~c"authorization",
     String.to_charlist(
       ~s(CoopGovernance key="#{read.key_id}", ts="#{read.timestamp_ms}", ) <>
         ~s(nonce="#{read.nonce}", sig="#{sig}")
     )}
  end

  defp request(method, url, body, headers \\ []) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    request =
      case body do
        nil -> {String.to_charlist(url), headers}
        body -> {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}
      end

    case :httpc.request(method, request, [timeout: 15_000], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, raw}} when status in 200..299 -> Jason.decode(raw)
      {:ok, {{_, status, _}, _headers, raw}} -> {:error, {status, raw}}
      {:error, reason} -> {:error, reason}
    end
  end
end
