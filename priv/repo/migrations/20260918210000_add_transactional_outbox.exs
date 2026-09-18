defmodule Dispatch.Repo.Migrations.AddTransactionalOutbox do
  use Ecto.Migration

  def up do
    create table(:outbox_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :tenant_id, :uuid, null: false
      add :topic, :text, null: false
      add :event_type, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
      add :published_at, :utc_datetime_usec
      add :attempt_count, :bigint, null: false, default: 0
    end

    create index(:outbox_events, [:occurred_at, :id],
             name: "outbox_events_pending_index",
             where: "published_at IS NULL"
           )
  end

  def down do
    drop_if_exists index(:outbox_events, [:occurred_at, :id],
                     name: "outbox_events_pending_index"
                   )

    drop table(:outbox_events)
  end
end
