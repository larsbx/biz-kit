defmodule Dispatch.Outbox.Publisher do
  @moduledoc """
  Publishes committed PostgreSQL outbox rows to the local SSE PubSub boundary.

  Rows are locked with SKIP LOCKED, broadcast, and then marked published.
  Repetition is permitted; loss is not. Stream consumers always rebuild an
  authorized snapshot, so duplicate notifications do not duplicate domain data.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Outbox.Event

  @poll_ms 250
  @batch_size 100

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    publish_pending()
    schedule()
    {:noreply, state}
  end

  @doc "Publishes one bounded batch; public for deterministic integration tests."
  @spec publish_pending() :: non_neg_integer()
  def publish_pending do
    Dispatch.Repo.transaction(fn ->
      events =
        from(e in Event,
          where: is_nil(e.published_at),
          order_by: [asc: e.occurred_at, asc: e.id],
          limit: @batch_size,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Dispatch.Repo.all()

      now = DateTime.utc_now()

      Enum.each(events, fn event ->
        Phoenix.PubSub.broadcast(Dispatch.PubSub, event.topic, {:outbox, event.payload})

        from(e in Event, where: e.id == type(^event.id, :binary_id))
        |> Dispatch.Repo.update_all(
          set: [published_at: now],
          inc: [attempt_count: 1]
        )
      end)

      length(events)
    end)
    |> case do
      {:ok, count} -> count
      {:error, _reason} -> 0
    end
  end

  defp schedule, do: Process.send_after(self(), :poll, @poll_ms)
end
