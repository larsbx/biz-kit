defmodule Dispatch.Outbox.Event do
  @moduledoc """
  A durable notification written in the same transaction as its domain event.

  Publication is at-least-once: a crash after broadcast but before the row is
  marked published may repeat a refresh, which is harmless because streams
  render fresh authorized state rather than applying domain deltas.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "outbox_events" do
    field :tenant_id, :binary_id
    field :topic, :string
    field :event_type, :string
    field :payload, :map
    field :occurred_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0
  end
end
