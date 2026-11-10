defmodule TaskHost.OperationsTest do
  use ExUnit.Case, async: true

  alias TaskHost.Operations

  defp workspace(id, chapter \\ "chapter-a", project \\ "project-1") do
    %{
      "id" => id,
      "label" => "Workspace " <> id,
      "chapter_id" => chapter,
      "tenant_id" => "tenant-1",
      "project_id" => project
    }
  end

  defp config(workspaces), do: %{"schema_version" => 1, "workspaces" => workspaces}

  defp gate do
    %{
      orchestration: TaskCore.State.init(TaskCore.Host),
      role_keys: %{},
      role_key_members: %{}
    }
  end

  defp grant(gate, id, principal, chapter, project, kind \\ :grants) do
    record = %{
      chapter_id: chapter,
      tenant_id: "tenant-1",
      project_id: project,
      principal_id: principal,
      active: true,
      key_id: "private-key-id",
      pubkey: "private-key-bytes"
    }

    put_in(gate, [:orchestration, kind, Access.key(id)], record)
  end

  defp task(gate, id, chapter, project) do
    task =
      TaskCore.State.new_task(%{event_id: "event-" <> id}, %{
        title: "Task " <> id,
        private_payload: "unprojected-private-data"
      })

    put_in(gate, [:orchestration, :tasks, Access.key({chapter, "tenant-1", project, id})], task)
  end

  test "unconfigured means empty, with generic display defaults" do
    assert {:ok, normalized} = Operations.normalize(config([]))
    assert normalized == Operations.default_config()
    assert {:ok, ^normalized} = Operations.snapshot(gate(), "principal-a", normalized)
  end

  test "custom labels, categories and exact scopes do not encode a business model" do
    input =
      config([
        workspace("studio")
        |> Map.put("label", "Studio tasks")
        |> Map.put("category", "Creative work"),
        workspace("personal", "chapter-b") |> Map.put("label", "Personal responsibilities")
      ])
      |> Map.put("title", "Shared work")
      |> Map.put("time_zone", "Europe/Copenhagen")

    assert {:ok, normalized} = Operations.normalize(input)
    assert normalized["title"] == "Shared work"
    assert normalized["time_zone"] == "Europe/Copenhagen"
    assert Enum.map(normalized["workspaces"], & &1["category"]) == ["Creative work", "general"]
    assert {:ok, %{"workspaces" => []}} = Operations.snapshot(gate(), "principal-a", normalized)
  end

  test "closed configuration rejects unknown fields, invalid identifiers and malformed values" do
    valid = config([workspace("a")])

    for invalid <- [
          nil,
          :invalid,
          [],
          %{},
          %{"schema_version" => 2, "workspaces" => []},
          %{"schema_version" => 1, "workspaces" => %{}},
          Map.put(valid, "grants", []),
          Map.put(valid, :title, "atom keys are not JSON keys"),
          Map.put(valid, "title", " "),
          Map.put(valid, "title", String.duplicate("x", 121)),
          Map.put(valid, "time_zone", "Etc/UTC\n"),
          Map.put(valid, "time_zone", "not a timezone"),
          Map.put(valid, "time_zone", 5),
          config([Map.put(workspace("a"), "roles", ["administrator"])]),
          config([Map.put(workspace("a"), "project_id", "../private")]),
          config([Map.put(workspace("a"), "chapter_id", "chapter/a")]),
          config([Map.put(workspace("a"), "id", "__proto__")]),
          config([Map.put(workspace("a"), "tenant_id", "")]),
          config([Map.delete(workspace("a"), "label")]),
          config([Map.put(workspace("a"), "category", nil)]),
          config([Map.put(workspace("a"), "label", "line\nbreak")]),
          config(["not a workspace"]),
          config(for i <- 1..33, do: workspace("w-#{i}", "c-#{i}"))
        ] do
      assert {:error, :invalid_operations_config} = Operations.normalize(invalid)
    end
  end

  test "duplicate ids and duplicate scopes are refused instead of double-counted" do
    assert {:error, :invalid_operations_config} =
             Operations.normalize(config([workspace("same"), workspace("same", "chapter-b")]))

    assert {:error, :invalid_operations_config} =
             Operations.normalize(config([workspace("one"), workspace("two")]))
  end

  test "project and chapter boundaries filter descriptors as well as task data" do
    input =
      config([
        workspace("a"),
        workspace("other-project", "chapter-a", "project-2"),
        workspace("private", "chapter-b")
      ])

    gate =
      gate()
      |> grant("g-a", "principal-a", "chapter-a", "project-1")
      |> grant("g-b", "principal-b", "chapter-b", "project-1")
      |> task("task-a", "chapter-a", "project-1")
      |> task("task-other-project", "chapter-a", "project-2")
      |> task("task-private", "chapter-b", "project-1")

    assert {:ok, %{"workspaces" => [visible]}} = Operations.snapshot(gate, "principal-a", input)
    assert visible["id"] == "a"
    assert Map.keys(visible["view"]) |> Enum.sort() == [:suggestions, :tasks, :workflows]
    assert Map.keys(visible["view"].tasks) == ["task-a"]

    encoded = inspect(visible, limit: :infinity)
    refute encoded =~ "private"
    refute encoded =~ "other-project"
    refute encoded =~ "unprojected-private-data"

    assert {:ok, %{"workspaces" => [other]}} = Operations.snapshot(gate, "principal-b", input)
    assert other["id"] == "private"
    assert Map.keys(other["view"].tasks) == ["task-private"]
  end

  test "operator, suggester and reviewer reads use current grants from the same snapshot" do
    for kind <- [:grants, :suggester_grants, :dod_grants] do
      before = gate() |> grant("grant", "principal-a", "chapter-a", "project-1", kind)
      after_revoke = put_in(before, [:orchestration, kind, "grant", :active], false)
      input = config([workspace("a")])

      assert {:ok, %{"workspaces" => [_]}} = Operations.snapshot(before, "principal-a", input)

      assert {:ok, %{"workspaces" => []}} =
               Operations.snapshot(after_revoke, "principal-a", input)
    end
  end

  test "chapter governance remains chapter-wide but never crosses into another chapter" do
    gate = %{
      gate()
      | role_keys: %{{"chapter-a", "governance"} => %{"key-a" => "private-governance-key"}},
        role_key_members: %{{"chapter-a", "governance", "key-a"} => "principal-admin"}
    }

    input =
      config([
        workspace("a"),
        workspace("a-second", "chapter-a", "project-2"),
        workspace("b", "chapter-b")
      ])

    assert {:ok, %{"workspaces" => visible}} = Operations.snapshot(gate, "principal-admin", input)
    assert Enum.map(visible, & &1["id"]) == ["a", "a-second"]
    refute inspect(visible, limit: :infinity) =~ "private-governance-key"

    revoked = %{gate | role_keys: %{}}
    assert {:ok, %{"workspaces" => []}} = Operations.snapshot(revoked, "principal-admin", input)

    reassigned =
      put_in(gate, [:role_key_members, {"chapter-a", "governance", "key-a"}], "someone-else")

    assert {:ok, %{"workspaces" => []}} =
             Operations.snapshot(reassigned, "principal-admin", input)
  end

  test "a delegated agent or configured workspace label cannot grant read access" do
    gate =
      put_in(gate(), [:orchestration, :delegations, Access.key("delegation")], %{
        principal_id: "principal-agent",
        chapter_id: "chapter-a",
        tenant_id: "tenant-1",
        project_id: "project-1",
        active: true
      })

    input = config([Map.put(workspace("a"), "category", "administrator")])
    assert {:ok, %{"workspaces" => []}} = Operations.snapshot(gate, "principal-agent", input)
    assert {:error, :unauthorized} = Operations.snapshot(gate, nil, input)
  end
end
