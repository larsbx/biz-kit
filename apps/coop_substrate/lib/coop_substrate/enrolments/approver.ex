defmodule CoopSubstrate.Enrolments.Approver do
  @moduledoc """
  The administrator's side of device enrolment
  (docs/architecture/2026-10-19-device-enrolment.md), behind
  `mix coop.enrol`.

  It talks to the running server over HTTP, so the server's appender admits
  the grant. It never starts a second appender against the same store. It
  signs with the governance key on this machine
  (`CoopSubstrate.Harness.Ops.load_signer/1`) and only after decoding the
  grant it was given and checking that it grants exactly the request it
  showed: that principal, that project, that device key, signed by this
  governance key alone.
  """

  alias CoopSubstrate.{Canonical, Crypto}

  @type signer :: %{key_id: String.t(), pubkey: binary(), seed: binary()}

  @doc "The request a code names, as the server reports it."
  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(base, code), do: request(:get, base <> "/api/v1/enrolments/" <> URI.encode(code), nil)

  @doc "Approve the request `details` describes (from `fetch/2`), signing with `signer`."
  @spec approve(String.t(), map(), signer()) :: {:ok, map()} | {:error, term()}
  def approve(base, %{"code" => code} = details, signer) do
    path = base <> "/api/v1/enrolments/" <> URI.encode(code) <> "/approval"

    with {:ok, held} <- request(:post, path, %{"governance_key_id" => signer.key_id}),
         {:ok, bytes} <- Base.url_decode64(held["signing_bytes"], padding: false),
         {:ok, core} <- Canonical.decode(bytes),
         :ok <- matches(core, details, signer) do
      signature = Base.url_encode64(Crypto.sign(bytes, signer.seed), padding: false)
      request(:post, path <> "/" <> URI.encode(held["id"]), %{"signature" => signature})
    end
  end

  @doc "Whether the decoded grant is exactly the one the request asks for."
  @spec matches(map(), map(), signer()) :: :ok | {:error, :grant_does_not_match_request}
  def matches(core, details, signer) do
    expected_payload = %{
      "tenant_id" => details["tenant_id"],
      "project_id" => details["project_id"],
      "principal_id" => details["principal_id"],
      "key_id" => details["key_id"],
      "pubkey" => {:bytes, Base.url_decode64!(details["public_key"], padding: false)}
    }

    expected_signers = [
      %{"role" => "governance", "key_id" => signer.key_id, "pubkey" => {:bytes, signer.pubkey}}
    ]

    if core["type"] == "TaskOperatorGrantedV1" and core["chapter_id"] == details["chapter_id"] and
         core["payload"] == expected_payload and core["signers"] == expected_signers,
       do: :ok,
       else: {:error, :grant_does_not_match_request}
  end

  defp request(method, url, body) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    request =
      case body do
        nil -> {String.to_charlist(url), []}
        body -> {String.to_charlist(url), [], ~c"application/json", Jason.encode!(body)}
      end

    case :httpc.request(method, request, [timeout: 15_000], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, raw}} when status in 200..299 -> Jason.decode(raw)
      {:ok, {{_, status, _}, _headers, raw}} -> {:error, {status, raw}}
      {:error, reason} -> {:error, reason}
    end
  end
end
