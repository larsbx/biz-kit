defmodule Dispatch.DependencyTenantSecurityTest do
  use ExUnit.Case, async: false
  require Ash.Expr
  alias Dispatch.DependencySecurityFixtures.{Row, Link}
  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    # Transaction-local tables exercise the actual PostgreSQL data layer and
    # need neither production migrations nor access to deployed business data.
    Ecto.Adapters.SQL.query!(Dispatch.Repo, """
    CREATE TEMP TABLE dependency_security_rows (
      id uuid PRIMARY KEY, tenant_id uuid NOT NULL, name text NOT NULL,
      UNIQUE (tenant_id, name)
    ) ON COMMIT DROP
    """)

    Ecto.Adapters.SQL.query!(Dispatch.Repo, """
    CREATE TEMP TABLE dependency_security_links (
      id uuid PRIMARY KEY, tenant_id uuid NOT NULL,
      source_id uuid NOT NULL, destination_id uuid NOT NULL
    ) ON COMMIT DROP
    """)

    %{a: Ash.UUID.generate(), b: Ash.UUID.generate()}
  end

  defp row(tenant, name), do: Ash.create!(Row, %{name: name}, tenant: tenant, authorize?: false)

  test "a primary-key upsert cannot read, overwrite or take over another tenant's row", c do
    original = row(c.a, "private")

    assert {:error, _} =
             Ash.create(Row, %{id: original.id, name: "hijacked"},
               tenant: c.b,
               authorize?: false,
               upsert?: true,
               upsert_fields: [:name]
             )

    assert %{id: id, tenant_id: tenant, name: "private"} =
             Ash.get!(Row, original.id, tenant: c.a, authorize?: false)

    assert id == original.id and tenant == c.a
    assert [] = Ash.read!(Row, tenant: c.b, authorize?: false)
  end

  test "single and bulk skipped upserts return only the caller's tenant", c do
    # Duplicate identity values exist in both tenants. A correct reread must
    # include tenant scope even when the SQL ON CONFLICT update was skipped.
    records = Map.new([c.b, c.a], fn tenant -> {tenant, row(tenant, "shared")} end)

    for tenant <- [c.a, c.b] do
      opts = [
        tenant: tenant,
        authorize?: false,
        upsert?: true,
        upsert_identity: :tenant_name,
        upsert_fields: [:name],
        upsert_condition: Ash.Expr.expr(false),
        return_skipped_upsert?: true
      ]

      own = records[tenant]
      single = Ash.create!(Row, %{name: "shared"}, opts)
      assert single.id == own.id and single.tenant_id == tenant

      assert %Ash.BulkResult{status: :success, records: [bulk]} =
               Ash.bulk_create(
                 [%{name: "shared"}],
                 Row,
                 :create,
                 opts ++ [return_records?: true, return_errors?: true]
               )

      assert bulk.id == own.id and bulk.tenant_id == tenant
    end
  end

  test "joins and limited through loads exclude another tenant's join rows", c do
    decoy = row(c.a, "decoy-created-first")
    source = row(c.a, "source")
    linked = row(c.a, "linked")

    for {tenant, target} <- [{c.a, linked}, {c.b, decoy}] do
      Ash.create!(Link, %{source_id: source.id, destination_id: target.id},
        tenant: tenant,
        authorize?: false
      )
    end

    loaded = Ash.load!(source, [:linked_rows, :through_rows], tenant: c.a, authorize?: false)
    assert Enum.map(loaded.linked_rows, & &1.id) == [linked.id]
    assert Enum.map(loaded.through_rows, & &1.id) == [linked.id]

    limited =
      Ash.load!(source, [through_rows: Ash.Query.limit(Row, 1)], tenant: c.a, authorize?: false)

    assert Enum.map(limited.through_rows, & &1.id) == [linked.id]
  end
end
