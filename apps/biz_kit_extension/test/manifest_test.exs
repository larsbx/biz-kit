defmodule BizKit.Extension.ManifestTest do
  use ExUnit.Case, async: true

  alias BizKit.Extension.{Catalog, Manifest}

  defmodule Base do
    @behaviour BizKit.Extension

    @impl true
    def manifest do
      %{
        id: "example",
        contract_version: 1,
        version: "1.2.0",
        dependencies: [],
        capabilities: ["example.catalog.read"],
        requested_grants: ["example.order.write"],
        commands: [
          %{
            name: "example.order.place",
            writer: "example",
            required_grants: ["example.order.write"]
          }
        ],
        events: [%{name: "example.order.placed", writer: "example"}],
        projections: [%{name: "example.orders", source_event: "example.order.placed"}],
        migrations: [],
        deployment: :integrated,
        activation: :manual,
        health: :host
      }
    end
  end

  defmodule Consumer do
    @behaviour BizKit.Extension

    @impl true
    def manifest do
      BizKit.Extension.ManifestTest.Base.manifest()
      |> Map.merge(%{
        id: "consumer",
        version: "0.2.0",
        dependencies: [%{id: "example", min_version: "1.1.0"}],
        capabilities: [],
        requested_grants: [],
        commands: [],
        events: [],
        projections: []
      })
    end
  end

  defmodule Cycle do
    @behaviour BizKit.Extension

    @impl true
    def manifest do
      BizKit.Extension.ManifestTest.Consumer.manifest()
      |> Map.merge(%{
        id: "example",
        version: "2.0.0",
        dependencies: [%{id: "consumer", min_version: "0.2.0"}]
      })
    end
  end

  defmodule Old do
    @behaviour BizKit.Extension

    @impl true
    def manifest, do: %{BizKit.Extension.ManifestTest.Base.manifest() | version: "1.0.0"}
  end

  test "strict manifest and deterministic canonical order" do
    assert {:ok, valid} = Manifest.validate(Base.manifest())
    assert valid.id == "example"
    assert valid.activation == :manual
    assert {:ok, ^valid} = Manifest.validate(valid)
  end

  test "unknown fields, invalid versions, duplicate names and foreign writers refuse" do
    manifest = Base.manifest()

    assert {:error, {:invalid_fields, :manifest}} =
             Manifest.validate(Map.put(manifest, :extra, true))

    assert {:error, {:invalid_field, :version}} =
             Manifest.validate(%{manifest | version: "latest"})

    assert {:error, {:invalid_field, :capabilities}} =
             Manifest.validate(%{manifest | capabilities: ["example.a", "example.a"]})

    assert {:error, {:invalid_field, :commands}} =
             Manifest.validate(%{
               manifest
               | commands: [
                   %{name: "example.order.place", writer: "dispatch", required_grants: []}
                 ]
             })

    assert {:error, {:invalid_field, :events}} =
             Manifest.validate(%{
               manifest
               | events: [%{name: "dispatch.order.placed", writer: "example"}]
             })

    assert {:error, {:invalid_field, :commands}} =
             Manifest.validate(%{
               manifest
               | commands: [
                   %{
                     name: "example.order.place",
                     writer: "example",
                     required_grants: ["example.superuser"]
                   }
                 ]
             })
  end

  test "registration resolves approved modules in dependency order" do
    assert {:ok, entries} = Catalog.build([Consumer, Base])
    assert Enum.map(entries, & &1.manifest.id) == ["example", "consumer"]
    assert {:ok, []} = Catalog.activation_plan(entries, [])

    assert {:error, {:unapproved_dependency, "consumer"}} =
             Catalog.activation_plan(entries, ["consumer"])

    assert {:ok, ^entries} = Catalog.activation_plan(entries, ["consumer", "example"])
    assert {:error, :unknown_extension} = Catalog.activation_plan(entries, ["missing"])

    assert {:error, :invalid_approvals} =
             Catalog.activation_plan(entries, ["example", "example"])
  end

  test "duplicate modules, absent dependencies, version mismatch and cycles refuse" do
    assert {:error, :duplicate_extension} = Catalog.build([Base, Base])
    assert {:error, {:missing_dependency, "consumer", "example"}} = Catalog.build([Consumer])
    assert {:error, :dependency_cycle} = Catalog.build([Consumer, Cycle])

    assert {:error, {:outdated_dependency, "consumer", "example"}} =
             Catalog.build([Old, Consumer])
  end

  test "no arbitrary module names are accepted" do
    assert {:error, {:not_an_extension, String}} = Catalog.build([String])
    assert {:error, {:not_an_extension, "Not.A.Module"}} = Catalog.build(["Not.A.Module"])
  end
end
