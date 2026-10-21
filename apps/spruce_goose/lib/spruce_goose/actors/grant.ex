defmodule SpruceGoose.Actors.Grant do
  @moduledoc """
  One historical grant of a role to an actor over one scope.

  A separate resource rather than an array column on `Actor`, because the
  questions actually asked of a permission are "who granted this, and when" and
  "revoke exactly this one" — neither of which an array answers well.

  `scope` is `*` (fleet-wide) or `project:KEY`. Two levels only: deeper scoping
  turns every permission check into a tree walk, and work on this fleet is
  partitioned by project.
  """

  use Ash.Resource,
    domain: SpruceGoose.Actors,
    data_layer: AshPostgres.DataLayer,
    # Relationship loads and policy reads must see active grants only.
    primary_read_warning?: false

  alias SpruceGoose.Actors.Role

  @global "*"

  postgres do
    table("actor_grants")
    repo(SpruceGoose.Repo)
    identity_wheres_to_sql(unique_grant: "revoked_at IS NULL")

    check_constraints do
      check_constraint([:revoked_at, :revoked_by], "actor_grants_revocation_pair",
        check:
          "(revoked_at IS NULL AND revoked_by IS NULL) OR " <>
            "(revoked_at IS NOT NULL AND revoked_by IS NOT NULL AND " <>
            "length(trim(revoked_by)) > 0 AND revoked_at >= granted_at)",
        message: "revocation requires an actor and a time at or after the grant"
      )
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:role, Role, allow_nil?: false, public?: true)
    attribute(:scope, :string, allow_nil?: false, public?: true)
    attribute(:granted_by, :string, allow_nil?: false, public?: true)
    attribute(:granted_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)
    attribute(:revoked_by, :string, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :actor, SpruceGoose.Actors.Actor do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    read :read do
      primary?(true)
      filter(expr(is_nil(revoked_at)))
    end

    # Explicit audit read. Authorization and relationship loads use :read.
    read(:history)

    create :create do
      primary?(true)
      accept([:actor_id, :role, :scope, :granted_by])
      change(set_attribute(:granted_at, &DateTime.utc_now/0))
    end

    update :revoke do
      require_atomic?(false)
      accept([:revoked_by])
      require_attributes([:revoked_by])
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end

  identities do
    identity(:unique_grant, [:actor_id, :role, :scope], where: expr(is_nil(revoked_at)))
  end

  validations do
    validate(string_length(:revoked_by, min: 1, max: 64), on: [:update])

    validate(fn changeset, _context ->
      changeset |> Ash.Changeset.get_attribute(:scope) |> valid_scope()
    end)
  end

  def global, do: @global

  @doc "Parse a scope string. Existence of the named project is checked at grant time."
  def parse_scope(@global), do: {:ok, :global}

  def parse_scope("project:" <> key) when byte_size(key) > 0, do: {:ok, {:project, key}}

  def parse_scope(_scope), do: {:error, "scope must be #{@global} or project:KEY"}

  defp valid_scope(scope) do
    case parse_scope(scope) do
      {:ok, _parsed} -> :ok
      {:error, message} -> {:error, field: :scope, message: message}
    end
  end
end
