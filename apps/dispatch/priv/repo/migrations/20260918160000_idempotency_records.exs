defmodule Dispatch.Repo.Migrations.IdempotencyRecords do
  @moduledoc """
  The `Idempotency-Key` ledger of Section 24.

  Hand-written rather than generated, because `Dispatch.Idempotency.Record` is
  a plain Ecto schema: it is the transport's bookkeeping, not domain data with
  an authorization question, so it is deliberately not an Ash resource.
  """

  use Ecto.Migration

  def up do
    create table(:idempotency_records, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :tenant_id, :uuid, null: false
      add :role_assignment_id, :uuid, null: false
      add :idempotency_key, :text, null: false
      add :request_hash, :text, null: false
      add :state, :text, null: false
      add :response_status, :integer
      add :response_body, :jsonb

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :expires_at, :utc_datetime_usec, null: false
    end

    # The claim in `Dispatch.Idempotency.claim/4` is an `ON CONFLICT DO NOTHING`
    # against exactly this index, which is what makes two simultaneous copies of
    # one request resolve to a single execution. Section 23.3 makes the role
    # assignment the unit of authority, so the key is scoped to it rather than
    # to the tenant alone.
    create unique_index(:idempotency_records, [:tenant_id, :role_assignment_id, :idempotency_key],
             name: "idempotency_records_unique_key_index"
           )

    # Retention sweeps by expiry (Section 24's 24 hours).
    create index(:idempotency_records, [:expires_at])
  end

  def down do
    drop table(:idempotency_records)
  end
end
