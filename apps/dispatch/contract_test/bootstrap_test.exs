defmodule Dispatch.ExtensionBootstrapTest do
  use ExUnit.Case, async: false

  alias BizKit.Extension.Catalog

  test "descriptor validation and approved plans leave domain infrastructure stopped" do
    assert Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox)
    before = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for app <- [:dispatch, :ecto_sql, :postgrex, :coop_substrate] do
      refute MapSet.member?(before, app)
    end

    for name <- [Dispatch.Repo, Dispatch.Supervisor, DispatchWeb.Endpoint] do
      assert Process.whereis(name) == nil
    end

    assert {:ok, entries} = Catalog.build([Dispatch.Extension])
    assert {:ok, []} = Catalog.activation_plan(entries, [])
    assert {:ok, ^entries} = Catalog.activation_plan(entries, ["dispatch"])
    after_apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert after_apps == before

    for name <- [Dispatch.Repo, Dispatch.Supervisor, DispatchWeb.Endpoint] do
      assert Process.whereis(name) == nil
    end
  end

  @tag timeout: 60_000
  test "ordinary helper still refuses an unstarted repo instead of bypassing Sandbox" do
    {output, status} =
      System.cmd("mix", ["run", "--no-start", "test/test_helper.exs"],
        cd: Path.expand("..", __DIR__),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "could not lookup Ecto repo Dispatch.Repo"
    assert output =~ "Ecto.Adapters.SQL.Sandbox.mode/2"
    assert output =~ "test/test_helper.exs:6"
  end
end
