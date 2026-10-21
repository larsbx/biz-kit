defmodule BizKit.Identity.Native do
  @moduledoc """
  Native-client handoff to existing Identity sessions. The browser gets only a
  single-use code, bound to S256 PKCE; the session never enters a redirect URL.
  Provider state and the native redirect are held server-side, not supplied on
  callback. Restart loses pending handoffs and fails closed.
  """
  use GenServer
  alias BizKit.Identity
  @server BizKit.Cluster.Singleton.name(__MODULE__)
  @ttl 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def begin(provider, challenge, client_state, callback, redirect) do
    if is_binary(challenge) and Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, challenge) and
         is_binary(client_state) and byte_size(client_state) in 32..128 do
      id = token()

      with {:ok, url} <- Identity.authorize_url(provider, id, callback) do
        case GenServer.call(
               @server,
               {:put, id,
                %{
                  provider: provider,
                  challenge: challenge,
                  client_state: client_state,
                  callback: callback,
                  redirect: redirect,
                  url: url
                }, now() + @ttl}
             ) do
          :ok -> {:ok, %{id: id, url: url}}
          error -> error
        end
      end
    else
      {:error, :invalid_request}
    end
  end

  # Called only after the HTTP layer has checked the browser's state cookie.
  def authorization_url(id), do: GenServer.call(@server, {:url, id})
  def complete(id, code), do: GenServer.call(@server, {:complete, id, code})

  def exchange(code, verifier) when is_binary(code) and is_binary(verifier),
    do: GenServer.call(@server, {:exchange, code, verifier})

  def exchange(_, _), do: {:error, :invalid_request}
  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp now, do: System.system_time(:millisecond)
  @impl true
  def init(_), do: {:ok, %{}}
  @impl true
  def handle_call({:put, id, value, expiry}, _, state) do
    state = sweep(state)

    if map_size(state) < 1000 do
      {:reply, :ok, Map.put(state, id, {value, expiry})}
    else
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:url, id}, _, state) do
    state = sweep(state)

    reply =
      case Map.get(state, id) do
        {%{url: url}, _} -> {:ok, url}
        _ -> {:error, :invalid_request}
      end

    {:reply, reply, state}
  end

  def handle_call({:complete, id, code}, _, state) do
    {entry, state} = Map.pop(sweep(state), id)

    case entry do
      {%{provider: provider} = flow, _} ->
        case Identity.login(provider, code, flow.callback) do
          {:ok, session} ->
            handoff = token()
            value = %{session: session, challenge: flow.challenge}
            result = %{code: handoff, state: flow.client_state, redirect: flow.redirect}
            {:reply, {:ok, result}, Map.put(state, handoff, {value, now() + 60_000})}

          error ->
            {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :invalid_request}, state}
    end
  end

  def handle_call({:exchange, code, verifier}, _, state) do
    state = sweep(state)

    case Map.get(state, code) do
      {%{session: session, challenge: challenge}, _} when is_binary(verifier) ->
        actual = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

        if byte_size(verifier) in 43..128 and :crypto.hash_equals(actual, challenge) do
          {:reply, {:ok, session}, Map.delete(state, code)}
        else
          {:reply, {:error, :invalid_request}, state}
        end

      _ ->
        {:reply, {:error, :invalid_request}, state}
    end
  end

  defp sweep(state) do
    Map.reject(state, fn {_id, {value, expiry}} ->
      if expiry < now() do
        if Map.has_key?(value, :session), do: Identity.logout(value.session)
        true
      else
        false
      end
    end)
  end
end
