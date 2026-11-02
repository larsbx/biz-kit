defmodule BizKit.Extension.Registry do
  @moduledoc """
  Ephemeral, read-only visibility registry over a trusted ExtensionV1 catalog.

  A host supplies an explicit list of compiled modules. The registry validates
  them once on startup, starts with every descriptor hidden, and atomically
  reconciles *visibility* against the existing dependency-checked plan.

  Visibility is NOT extension execution, authorization, installation, a
  durable approval, or a substitute for signed business-event admission.
  This process never starts a domain application, runs an extension callback
  after startup, or writes business state. Restart clears all visibility.
  """

  use GenServer

  alias BizKit.Extension.Catalog

  @type server :: GenServer.server()

  @doc """
  Start only from trusted host code with an explicit compiled-module allowlist.

  Modules supplied from a request, user-controlled string, or remote manifest
  are outside this API's trust boundary.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :modules) do
        {:ok, modules} ->
          with {:ok, catalog} <- Catalog.build(modules) do
            GenServer.start_link(__MODULE__, catalog, Keyword.take(opts, [:name]))
          end

        :error ->
          {:error, :missing_modules}
      end
    else
      {:error, :invalid_options}
    end
  end

  def start_link(_), do: {:error, :invalid_options}

  @doc "A deterministic list of installed descriptor IDs; no module execution."
  @spec installed(server()) :: [String.t()]
  def installed(server), do: GenServer.call(server, :installed)

  @doc "Return IDs whose descriptors are currently visible. Empty on startup."
  @spec visible(server()) :: [String.t()]
  def visible(server), do: GenServer.call(server, :visible)

  @doc """
  Replace the visible ID set atomically. Dependencies must also be visible.

  This is a *read-model control*, not an authenticated activation API.
  Callers must not interpret the return value as business permission.
  """
  @spec reconcile(server(), term()) :: {:ok, [String.t()]} | {:error, term()}
  def reconcile(server, desired_ids), do: GenServer.call(server, {:reconcile, desired_ids})

  @doc "Only returns validated manifest metadata for visible descriptors."
  @spec lookup(server(), String.t()) :: {:ok, map()} | {:error, :not_visible}
  def lookup(server, id), do: GenServer.call(server, {:lookup, id})

  @impl true
  def init(catalog), do: {:ok, %{catalog: catalog, visible: []}}

  @impl true
  def handle_call(:installed, _from, state) do
    {:reply, Enum.map(state.catalog, & &1.manifest.id), state}
  end

  def handle_call(:visible, _from, state), do: {:reply, state.visible, state}

  def handle_call({:reconcile, desired_ids}, _from, state) do
    case Catalog.activation_plan(state.catalog, desired_ids) do
      {:ok, selected} ->
        ids = Enum.map(selected, & &1.manifest.id)
        {:reply, {:ok, ids}, %{state | visible: ids}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:lookup, id}, _from, state) do
    if is_binary(id) and id in state.visible do
      entry = Enum.find(state.catalog, &(&1.manifest.id == id))
      {:reply, {:ok, entry.manifest}, state}
    else
      {:reply, {:error, :not_visible}, state}
    end
  end
end
