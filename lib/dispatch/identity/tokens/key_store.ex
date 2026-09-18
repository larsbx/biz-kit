defmodule Dispatch.Identity.Tokens.KeyStore do
  @moduledoc """
  Owns refreshing the OIDC signing keys, so that only one refresh runs at a time.

  Reads stay where they were — `Dispatch.Identity.Tokens.Oidc` looks keys up in
  `:persistent_term` on every request, and routing that through a process would
  serialise all token verification behind one mailbox. Only the *refresh* comes
  here.

  ## Why a process and not a timestamp

  The cooldown began as a read-check-write over `:persistent_term`: look at when
  the last attempt was, and if it is old enough, record a new one and fetch.
  Those three steps are not atomic. Under the burst the cooldown exists to stop
  — many requests arriving at once with unknown `kid` values — every one of them
  can read the old timestamp before any has written the new one, and every one
  then fetches. The check passes while doing nothing, and a sequential test
  cannot show it, because the interleaving that breaks it never happens with one
  caller.

  A single process makes the sequence atomic by construction rather than by
  argument. Callers queue; the first one's refresh updates the cache; the rest
  are answered from it without a second outbound request. There is no window
  because there is no interleaving.
  """

  use GenServer

  alias Dispatch.Identity.Tokens.Oidc

  # Long enough that a burst of invented key IDs costs one fetch rather than
  # thousands; short enough that a genuine rotation is picked up within a minute
  # of the first token that needs it.
  @cooldown_ms :timer.seconds(30)

  # Derived from the work it covers, never chosen next to it. A deadline shorter
  # than one refresh's worst case does not bound anything: it abandons a caller
  # with `:unavailable` for a key that was about to arrive, while the refresh
  # continues unobserved — and every caller queued behind shares the same
  # undersized deadline. The margin is for queueing and the reply itself.
  @queue_margin_ms 5_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Ensures `kid` is in the cache, refreshing at most once per cooldown.

  Returns `{:ok, jwk}`, or an error when the key is genuinely unknown or the
  issuer is unreachable. A caller that arrives while a refresh is running waits
  for that refresh rather than starting another.
  """
  @spec ensure(String.t()) :: {:ok, JOSE.JWK.t()} | {:error, :invalid_token | :unavailable}
  def ensure(kid) do
    GenServer.call(__MODULE__, {:ensure, kid}, call_timeout_ms())
  catch
    # A refresh slower than the call timeout, or a store not running. Neither is
    # a reason to admit a token whose key could not be confirmed.
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  How long `ensure/1` waits, which is the refresh budget plus room to queue.

  Public so a test can assert it still covers `Oidc.refresh_budget_ms/0` — the
  two are only correct together, and nothing else would notice them drifting
  apart.
  """
  @spec call_timeout_ms() :: pos_integer()
  def call_timeout_ms, do: Oidc.refresh_budget_ms() + @queue_margin_ms

  @doc false
  @impl GenServer
  def init(_opts), do: {:ok, %{last_attempt_at: nil}}

  @doc false
  @impl GenServer
  def handle_call({:ensure, kid}, _from, state) do
    # Re-checked inside the process: by the time this call is served, an earlier
    # caller in the queue may already have fetched the very key it asks for.
    case Oidc.cached_key(kid) do
      {:ok, jwk} -> {:reply, {:ok, jwk}, state}
      :error -> refresh(kid, state)
    end
  end

  defp refresh(kid, state) do
    if within_cooldown?(state) do
      {:reply, {:error, :invalid_token}, state}
    else
      state = %{state | last_attempt_at: System.monotonic_time(:millisecond)}

      case Oidc.refresh_keys() do
        :ok -> {:reply, found_or_unknown(kid), state}
        {:error, :unavailable} -> {:reply, {:error, :unavailable}, state}
      end
    end
  end

  defp found_or_unknown(kid) do
    case Oidc.cached_key(kid) do
      {:ok, jwk} -> {:ok, jwk}
      :error -> {:error, :invalid_token}
    end
  end

  defp within_cooldown?(%{last_attempt_at: nil}), do: false

  defp within_cooldown?(%{last_attempt_at: at}),
    do: System.monotonic_time(:millisecond) - at < @cooldown_ms
end
