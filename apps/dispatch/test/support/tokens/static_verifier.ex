defmodule Dispatch.Support.Tokens.StaticVerifier do
  @moduledoc """
  Test-only token verifier.

  A test needs to exercise the whole authenticated path — plug, resolution,
  policy, action — without an identity provider in the loop. This accepts a
  token that names claims directly, so a test states "a token for this subject"
  and nothing else.

  Compiled only from `test/support`, and named in the `Dispatch.Support`
  namespace that `Dispatch.Config` refuses in production. Both guards matter:
  the first means a release cannot load it, the second means a misconfiguration
  fails at startup with a legible violation rather than at the first request.

  It deliberately does *not* implement signature checking, so no test can
  accidentally conclude that signature verification works because this passed.
  `Dispatch.Identity.Tokens.OidcTest` exercises that against real keys.
  """

  @behaviour Dispatch.Identity.Tokens.Verifier

  alias Dispatch.Identity.Tokens.Verifier

  @doc """
  Encodes claims as a token this verifier accepts.

  Not a JWT, and not signed. Making it visibly not a JWT keeps a real token and
  a test token from ever being confused for one another.
  """
  @spec token(Verifier.claims() | map()) :: String.t()
  def token(claims) do
    "static." <> Base.url_encode64(:erlang.term_to_binary(claims), padding: false)
  end

  @doc "A token for `subject` with the defaults a test rarely cares about."
  @spec token_for(String.t(), keyword()) :: String.t()
  def token_for(subject, opts \\ []) do
    token(%{
      subject: subject,
      issuer: Keyword.get(opts, :issuer, "https://test.invalid"),
      audience: Keyword.get(opts, :audience, ["dispatch-api"]),
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 300, :second)),
      email: Keyword.get(opts, :email),
      name: Keyword.get(opts, :name)
    })
  end

  @impl Verifier
  def verify("static." <> encoded) do
    with {:ok, binary} <- Base.url_decode64(encoded, padding: false),
         %{subject: subject, expires_at: expires_at} = claims <- safe_binary_to_term(binary),
         true <- is_binary(subject) do
      if DateTime.compare(DateTime.utc_now(), expires_at) == :lt,
        do: {:ok, claims},
        else: {:error, :expired}
    else
      _malformed -> {:error, :invalid_token}
    end
  end

  def verify(_not_a_static_token), do: {:error, :invalid_token}

  # `:safe` keeps a malformed token from creating atoms, which is the one way
  # this shortcut could bite even in the test suite.
  defp safe_binary_to_term(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> nil
  end
end
