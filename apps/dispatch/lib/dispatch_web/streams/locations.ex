defmodule DispatchWeb.Streams.Locations do
  @moduledoc """
  Complete authorized location snapshots, with device demand while watched.

  A heartbeat rebuilds the snapshot too: expiry or relationship changes must
  remove a position even if no outbox event arrives. Reconnects authorize and
  rebuild afresh; Last-Event-ID never resumes old authority or coordinates.
  """

  @behaviour DispatchWeb.Streams.Transport

  alias Dispatch.Operations.{LocationDemand, LocationSnapshot}
  alias DispatchWeb.Datastar

  @enforce_keys [:actor, :watching]
  defstruct [:actor, :watching]

  @spec open(Dispatch.Access.Actor.t(), keyword()) ::
          {:ok, %__MODULE__{}, iodata()} | {:error, :not_found}
  def open(actor, _opts \\ []) do
    with {:ok, result} <- LocationSnapshot.build(actor) do
      watching = synchronize(MapSet.new(), result.watch_ids)
      session = %__MODULE__{actor: result.actor, watching: watching}
      {:ok, session, [Datastar.retry(3_000), event(result.snapshot)]}
    end
  end

  @impl true
  def tick(%__MODULE__{} = session, _reason) do
    case LocationSnapshot.build(session.actor) do
      {:ok, result} ->
        watching = synchronize(session.watching, result.watch_ids)
        session = %{session | actor: result.actor, watching: watching}
        {:emit, event(result.snapshot), session}

      {:error, :not_found} ->
        LocationDemand.release_watches()
        {:close, :unauthorized}
    end
  end

  @impl true
  def release(_session), do: LocationDemand.release_watches()

  defp synchronize(previous, ids) do
    next = MapSet.new(ids)
    Enum.each(MapSet.difference(previous, next), &LocationDemand.unwatch/1)
    Enum.each(MapSet.difference(next, previous), &LocationDemand.watch/1)
    next
  end

  defp event(snapshot),
    do: ["event: dispatch-locations\ndata: ", Jason.encode!(snapshot), "\n\n"]
end
