defmodule Dispatch.Idempotency.Record do
  @moduledoc """
  The stored result of one idempotent mutation (Section 24).

  A plain Ecto schema rather than an Ash resource, deliberately. Everything in
  `Dispatch.*` that models the business is an Ash resource with policies,
  because it answers a question about authority. This answers none: it is the
  transport's own bookkeeping, and the actor it belongs to is part of its *key*
  rather than something a policy decides. Modelling it as a resource would mean
  inventing policies that correspond to nothing and then bypassing them, which
  would make `authorize?: false` mean less everywhere it appears.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "idempotency_records" do
    field :tenant_id, :binary_id
    field :role_assignment_id, :binary_id
    field :idempotency_key, :string
    field :request_hash, :string
    field :state, :string
    field :response_status, :integer
    field :response_body, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end
end
