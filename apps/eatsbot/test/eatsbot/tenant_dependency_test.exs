defmodule Eatsbot.TenantDependencyTest do
  use ExUnit.Case, async: false

  alias Eatsbot.DependencyFixtures.TenantRecord, as: Record

  test "repeated reads and counts stay isolated across tenant contexts" do
    suffix = Ash.UUID.generate()
    tenants = ["a-#{suffix}", "b-#{suffix}"]

    Enum.each(tenants, fn tenant ->
      Ash.create!(Record, %{name: tenant}, tenant: tenant)
    end)

    Enum.each(tenants ++ Enum.reverse(tenants), fn tenant ->
      assert [%{name: ^tenant, tenant_id: ^tenant}] = Ash.read!(Record, tenant: tenant)
      assert Ash.count!(Record, tenant: tenant) == 1
    end)
  end

  test "a tenant-scoped resource rejects an omitted tenant" do
    assert {:error, _} = Ash.read(Record)
  end
end
