defmodule BizKit.Identity.SessionStore do
  @moduledoc """
  Where native apps' sessions outlive the session process
  (docs/architecture/2026-10-21-native-sign-in.md). Configured as
  `:biz_kit_identity, :session_store`; SpruceGoose provides the Postgres one.

  Keyed by the SHA-256 of the token: the store never holds a usable session.
  Unconfigured (`None`), native sessions live in memory only, and a restart
  ends them as it ends web sessions.
  """

  @type hash :: <<_::256>>
  @type row :: %{principal: String.t(), identity: BizKit.Identity.identity()}

  @callback put(hash(), principal :: String.t(), BizKit.Identity.identity()) :: :ok
  @callback get(hash()) :: {:ok, row()} | :error
  @callback delete(hash()) :: :ok
  @callback delete_principal(principal :: String.t()) :: :ok

  @doc "The configured store."
  @spec impl() :: module()
  def impl, do: Application.get_env(:biz_kit_identity, :session_store, __MODULE__.None)

  defmodule None do
    @moduledoc "Keeps nothing: native sessions are memory-only."
    @behaviour BizKit.Identity.SessionStore

    @impl true
    def put(_hash, _principal, _identity), do: :ok
    @impl true
    def get(_hash), do: :error
    @impl true
    def delete(_hash), do: :ok
    @impl true
    def delete_principal(_principal), do: :ok
  end
end
