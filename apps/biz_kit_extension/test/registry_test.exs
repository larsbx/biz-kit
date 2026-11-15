defmodule BizKit.Extension.RegistryTest do
  use ExUnit.Case, async: true

  alias BizKit.Extension.{Registry, ReleaseLock}

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
        requested_grants: [],
        commands: [],
        events: [],
        projections: [],
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
      BizKit.Extension.RegistryTest.Base.manifest()
      |> Map.merge(%{
        id: "consumer",
        dependencies: [%{id: "example", min_version: "1.1.0"}],
        capabilities: []
      })
    end
  end

  defmodule Independent do
    @behaviour BizKit.Extension

    @impl true
    def manifest do
      BizKit.Extension.RegistryTest.Base.manifest()
      |> Map.merge(%{id: "independent", capabilities: []})
    end
  end

  defmodule Old do
    @behaviour BizKit.Extension

    @impl true
    def manifest, do: %{BizKit.Extension.RegistryTest.Base.manifest() | version: "1.0.0"}
  end

  defmodule Changing do
    @behaviour BizKit.Extension

    @impl true
    def manifest do
      manifest = BizKit.Extension.RegistryTest.Base.manifest()

      case Process.put(__MODULE__, :called) do
        nil -> manifest
        :called -> %{manifest | version: "1.3.0"}
      end
    end
  end

  @pins %{"example" => String.duplicate("a", 40)}

  test "reviewed startup exposes only the verified manifest snapshot after reconciliation" do
    assert {:ok, lock} = ReleaseLock.build([Base], @pins)
    release = %{source_commits: @pins, lock: lock}
    assert {:ok, host} = Registry.start_link(modules: [Changing], reviewed_release: release)
    assert Registry.visible(host) == []
    assert {:error, :not_visible} = Registry.lookup(host, "example")
    assert {:ok, ["example"]} = Registry.reconcile(host, ["example"])
    assert {:ok, %{version: "1.2.0"}} = Registry.lookup(host, "example")
    GenServer.stop(host)
  end

  test "reviewed startup refuses drift and incomplete configuration before registration" do
    assert {:ok, lock} = ReleaseLock.build([Base], @pins)
    release = %{source_commits: @pins, lock: lock}
    opts = [name: __MODULE__, modules: [Base]]

    assert {:error, :unreviewed_or_stale_release_lock} =
             Registry.start_link(
               opts ++
                 [
                   reviewed_release: %{
                     release
                     | source_commits: %{"example" => String.duplicate("b", 40)}
                   }
                 ]
             )

    assert {:error, :unreviewed_or_stale_release_lock} =
             Registry.start_link(
               name: __MODULE__,
               modules: [Old],
               reviewed_release: release
             )

    assert {:error, :invalid_reviewed_release} =
             Registry.start_link(opts ++ [reviewed_release: %{lock: lock}])

    assert {:error, :invalid_reviewed_release} =
             Registry.start_link(opts ++ [reviewed_release: release, reviewed_release: release])

    assert Process.whereis(__MODULE__) == nil
  end

  test "registered compiled descriptors start hidden, even when installed" do
    host = start_supervised!({Registry, modules: [Consumer, Base, Independent]})

    assert Registry.installed(host) == ["example", "consumer", "independent"]
    assert Registry.visible(host) == []
    assert {:error, :not_visible} = Registry.lookup(host, "example")
  end

  test "reconciliation is atomic and respects dependency order" do
    host = start_supervised!({Registry, modules: [Consumer, Base, Independent]})

    assert {:error, {:unapproved_dependency, "consumer"}} =
             Registry.reconcile(host, ["consumer"])

    assert Registry.visible(host) == []

    assert {:ok, ["example", "consumer"]} =
             Registry.reconcile(host, ["consumer", "example"])

    assert {:ok, %{id: "example"}} = Registry.lookup(host, "example")
    assert {:error, :not_visible} = Registry.lookup(host, "independent")

    assert {:error, :unknown_extension} = Registry.reconcile(host, ["missing"])

    assert {:error, :invalid_approvals} =
             Registry.reconcile(host, ["example", "example"])

    assert Registry.visible(host) == ["example", "consumer"]
    assert {:ok, ["independent"]} = Registry.reconcile(host, ["independent"])
    assert {:error, :not_visible} = Registry.lookup(host, "example")
    assert Registry.visible(host) == ["independent"]

    assert {:ok, []} = Registry.reconcile(host, [])
    assert Registry.visible(host) == []
  end

  test "invalid manifests, unknown modules and dependency versions refuse startup" do
    assert {:error, :missing_modules} = Registry.start_link([])
    assert {:error, :invalid_options} = Registry.start_link([:invalid])
    assert {:error, :invalid_modules} = Registry.start_link(modules: "not a list")

    assert {:error, {:not_an_extension, "SchoolOps.Extension"}} =
             Registry.start_link(modules: ["SchoolOps.Extension"])

    assert {:error, {:outdated_dependency, "consumer", "example"}} =
             Registry.start_link(modules: [Old, Consumer])

    assert {:error, :duplicate_extension} = Registry.start_link(modules: [Base, Base])
  end

  test "restart loses visibility; no durable approval or domain process is created" do
    {:ok, first} = Registry.start_link(modules: [Base])
    assert {:ok, ["example"]} = Registry.reconcile(first, ["example"])
    assert Registry.visible(first) == ["example"]
    GenServer.stop(first)

    {:ok, second} = Registry.start_link(modules: [Base])
    assert Registry.visible(second) == []
    assert {:error, :not_visible} = Registry.lookup(second, "example")
    GenServer.stop(second)
  end

  test "independent host instances never share visibility" do
    first = start_supervised!({Registry, modules: [Base]})
    {:ok, second} = Registry.start_link(modules: [Base])

    assert {:ok, ["example"]} = Registry.reconcile(first, ["example"])
    assert Registry.visible(second) == []
    assert {:error, :not_visible} = Registry.lookup(second, "example")

    GenServer.stop(second)
  end
end
