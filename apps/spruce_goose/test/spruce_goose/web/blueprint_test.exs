defmodule SpruceGoose.Web.BlueprintTest do
  @moduledoc """
  Applying a blueprint with the governance key
  (docs/architecture/2026-10-20-hierarchy-and-blueprints.md): `mix
  coop.blueprint` reads it at the (stubbed) forge, the server stores the
  bytes and prepares the event, the tool signs it, and the ledger's
  hierarchy follows.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import SpruceGoose.LedgerFixtures

  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Log

  @commit String.duplicate("a", 40)
  @tree String.duplicate("b", 40)

  defmodule Forge do
    @moduledoc false
    # The forge's answer: whatever bytes this test put there.
    def verify("acme/plans", _commit, "launch.yaml"),
      do: {:ok, %{tree: String.duplicate("b", 40), bytes: :persistent_term.get(__MODULE__)}}

    def verify(_, _, _), do: {:error, :not_found}
  end

  setup do
    previous = Application.get_env(:spruce_goose, :blueprint_source_verifier)
    Application.put_env(:spruce_goose, :blueprint_source_verifier, Forge)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :blueprint_source_verifier, previous),
        else: Application.delete_env(:spruce_goose, :blueprint_source_verifier)
    end)

    w = world()
    governance_keys!(w)
    Map.merge(w, %{base: serve!(), scope: "#{w.chapter}/#{tenant()}/project-1"})
  end

  defp forge!(name) do
    :persistent_term.put(Forge, """
    # #{System.unique_integer()}
    schema_version: 2
    project: {key: project-1, name: #{name}}
    roadmaps:
      - key: q4
        name: Fourth quarter
        workflows:
          - id: release
            name: Release
            tasks:
              - id: build
                title: Build the release
                definition_of_done: [{id: artifact, description: The signed artifact}]
    """)
  end

  defp blueprint!(w, args \\ []) do
    capture_io(fn ->
      Mix.Tasks.Coop.Blueprint.run(
        [w.scope, "acme/plans", @commit, "launch.yaml", "--server", w.base, "--yes"] ++ args
      )
    end)
  end

  test "the tool applies what it read at the forge, and the hierarchy follows", w do
    forge!("Launch")
    out = blueprint!(w)

    assert out =~ "q4  Fourth quarter"
    assert out =~ "release  Release  (1 tasks)"
    assert [_, event_id] = Regex.run(~r/applied: event (\S+)/, out)

    project = Log.gate().orchestration.hierarchy[{w.chapter, tenant(), "project-1"}]
    assert project.name == "Launch"
    assert project.roadmaps["q4"].workflows["release"].revision == event_id
  end

  test "a source is applied once; a different project's blueprint is refused", w do
    forge!("Launch")
    blueprint!(w)
    assert_raise Mix.Error, ~r/blueprint_already_applied/, fn -> blueprint!(w) end

    elsewhere = %{w | scope: "#{w.chapter}/#{tenant()}/project-2"}
    forge!("Launch")
    assert_raise Mix.Error, ~r/blueprint_project_mismatch/, fn -> blueprint!(elsewhere) end
  end

  test "only governance may ask, and the tool signs only the bytes it read", w do
    path = "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1/blueprints"
    url = w.base <> path
    unsigned = call(:post, path, [{"content-type", "application/json"}], "{}")
    assert unsigned.status == 401

    forge!("Launch")
    bytes = :persistent_term.get(Forge)

    source = %{
      "repository" => "acme/plans",
      "commit" => @commit,
      "tree" => @tree,
      "path" => "launch.yaml"
    }

    params = Map.put(source, "manifest", Base.url_encode64(bytes, padding: false))

    # Shown different bytes than it read, the tool does not sign.
    assert {:error, :not_what_was_shown} =
             Client.sign_held(
               url,
               governance(w),
               &CoopSubstrate.Blueprints.expected?(&1, source, bytes <> "# changed\n"),
               params
             )

    assert Log.gate().orchestration.hierarchy[{w.chapter, tenant(), "project-1"}] == nil
  end
end
