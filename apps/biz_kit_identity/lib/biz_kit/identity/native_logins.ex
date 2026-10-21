defmodule BizKit.Identity.NativeLogins do
  @moduledoc """
  Sign-in for native apps (docs/architecture/2026-10-21-native-sign-in.md):
  OAuth 2.0 for Native Apps (RFC 8252) with PKCE (RFC 7636), brokered by
  biz-kit so the app never talks to the provider.

      app ── begin(redirect, S256 challenge) ──►  request   (10 min, single use)
      provider callback ── complete ──►           code      (60 s, single use)
      app ── exchange(code, verifier) ──►         session   (BizKit.Identity.Sessions)

  The app's redirect URI must be configured (`:native_redirect_uris`,
  matched exactly), and only `S256` is accepted: a `plain` challenge is the
  verifier itself, which an app sharing the redirect scheme could read. A code
  is spent by its first exchange, right or wrong, so it cannot be guessed at.

  Requests and codes are held in memory, in one process for the cluster, like
  sessions. A restart loses those in flight; the app simply signs in again.
  """

  use GenServer

  @table __MODULE__
  @request_ttl_ms 600_000
  @code_ttl_ms 60_000
  @max_state_bytes 512

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  @type request :: %{
          provider: String.t(),
          redirect_uri: String.t(),
          challenge: String.t(),
          state: String.t() | nil
        }
  @type grant :: %{
          principal: String.t(),
          identity: BizKit.Identity.identity(),
          challenge: String.t(),
          redirect_uri: String.t()
        }

  @doc "Checks a native sign-in request before anything is stored."
  @spec validate(String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok
          | {:error,
             :redirect_not_allowed
             | :unsupported_challenge_method
             | :invalid_challenge
             | :invalid_state}
  def validate(redirect_uri, challenge, method, state) do
    cond do
      redirect_uri not in Application.get_env(:biz_kit_identity, :native_redirect_uris, []) ->
        {:error, :redirect_not_allowed}

      method != "S256" ->
        {:error, :unsupported_challenge_method}

      not s256_challenge?(challenge) ->
        {:error, :invalid_challenge}

      not (is_nil(state) or (is_binary(state) and byte_size(state) <= @max_state_bytes)) ->
        {:error, :invalid_state}

      true ->
        :ok
    end
  end

  @doc "Whether `verifier` is the one `challenge` was derived from (RFC 7636 §4.6)."
  @spec verifies?(String.t(), String.t()) :: boolean()
  def verifies?(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    expected = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    byte_size(verifier) in 43..128 and byte_size(challenge) == byte_size(expected) and
      :crypto.hash_equals(expected, challenge)
  end

  def verifies?(_verifier, _challenge), do: false

  @doc "Stores a validated request; its ID is the provider's `state`."
  @spec put_request(request()) :: String.t()
  def put_request(request), do: put({:request, token()}, request, @request_ttl_ms)

  @doc "Takes a request, once."
  @spec take_request(String.t()) :: {:ok, request()} | :error
  def take_request(id), do: take({:request, id})

  @doc "Whether a request is pending, without spending it."
  @spec request?(String.t()) :: boolean()
  def request?(id), do: GenServer.call(@server, {:peek, {:request, id}, now()})

  @doc "Stores a signed-in grant behind a one-time code."
  @spec put_code(grant()) :: String.t()
  def put_code(grant), do: put({:code, token()}, grant, @code_ttl_ms)

  @doc "Takes a code, once — whether or not the exchange then succeeds."
  @spec take_code(String.t()) :: {:ok, grant()} | :error
  def take_code(code), do: take({:code, code})

  defp put({_kind, id} = key, value, ttl) do
    :ok = GenServer.call(@server, {:put, key, value, now() + ttl})
    id
  end

  defp take(key), do: GenServer.call(@server, {:take, key, now()})

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp now, do: System.system_time(:millisecond)

  # S256 yields 32 bytes, which base64url encodes as exactly 43 characters.
  defp s256_challenge?(challenge) when is_binary(challenge) and byte_size(challenge) == 43,
    do: match?({:ok, <<_::256>>}, Base.url_decode64(challenge, padding: false))

  defp s256_challenge?(_challenge), do: false

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, key, value, expires_at}, _from, state) do
    true = :ets.insert_new(@table, {key, value, expires_at})
    {:reply, :ok, state}
  end

  def handle_call({:take, key, now}, _from, state) do
    reply =
      case :ets.take(@table, key) do
        [{^key, value, expires_at}] when now <= expires_at -> {:ok, value}
        _missing_or_expired -> :error
      end

    {:reply, reply, state}
  end

  def handle_call({:peek, key, now}, _from, state) do
    {:reply,
     match?([{^key, _value, expires_at}] when now <= expires_at, :ets.lookup(@table, key)), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, 60_000)
end
