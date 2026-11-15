defmodule TaskHost.Web.ProjectKnowledgeBrowserTest do
  @moduledoc "Real browser governance approval and withdrawal, followed by Operations suggestions."
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.Enrolments.Approver
  alias CoopSubstrate.Log
  alias TaskCore.Knowledge

  @moduletag :browser
  @moduletag timeout: 180_000
  @script Path.expand("../../browser/project-knowledge.cjs", __DIR__)

  test "a browser approves the exact automatic draft, sees it during ops, then withdraws it" do
    providers!()
    w = world()
    admin = Principal.new_id()
    reader = Principal.new_id()

    bind([
      {"https://idp.test", "project-kb-admin", admin},
      {"https://idp.test", "project-kb-reader", reader}
    ])

    grant!(w, "TaskOperatorGrantedV1", member("operator"), reader, "project-1")
    artifact_dir = Path.join(System.tmp_dir!(), "project-kb-browser-" <> w.chapter)
    configure!(:coop_substrate, :artifact_dir, artifact_dir)
    on_exit(fn -> File.rm_rf!(artifact_dir) end)

    configure!(:task_host, :operations, %{
      "schema_version" => 1,
      "title" => "Project knowledge acceptance",
      "workspaces" => [
        %{
          "id" => "knowledge-desk",
          "label" => "Knowledge desk",
          "chapter_id" => w.chapter,
          "tenant_id" => tenant(),
          "project_id" => "project-1"
        }
      ]
    })

    revision = apply_blueprint!(w)

    append!(
      event(w, w.op, "TaskWorkflowInstantiatedV1", %{
        "tenant_id" => tenant(),
        "project_id" => "project-1",
        "principal_id" => "alice",
        "authorization_event_id" => w.op_grant.event_id,
        "lifecycle_version" => 1,
        "revision_event_id" => revision.event_id,
        "roadmap_key" => "q4",
        "workflow_id" => "release",
        "task_ids" => %{"build" => "kb-build", "ship" => "kb-ship"}
      })
    )

    scope = {w.chapter, tenant(), "project-1"}
    [candidate] = Knowledge.candidates(Log.gate().orchestration, scope)
    assert candidate["status"] == "pending"
    base = serve!()
    port = browser!(base, w)
    assert %{"stage" => "enrolment", "code" => code, "key_id" => key_id} = read!(port)
    assert {:ok, details} = Approver.fetch(base, code)
    assert details["principal_id"] == admin
    assert details["role"] == "governance"
    assert {:ok, _} = Approver.approve(base, details, governance(w))
    before = Log.head()
    Port.command(port, "enrolled\n")

    assert %{
             "stage" => "approved",
             "candidate_id" => id,
             "source_fingerprint" => source,
             "draft_digest" => draft
           } = read!(port)

    assert id == candidate["id"]
    assert source == candidate["source_fingerprint"]
    assert draft == candidate["draft_digest"]
    assert {:ok, approved} = Knowledge.candidate(Log.gate().orchestration, scope, id)
    assert approved["status"] == "approved"
    assert approved["review"]["key_id"] == key_id
    assert approved["review"]["snapshot"]["body"] == candidate["body"]
    Port.command(port, "withdraw\n")
    assert %{"stage" => "withdrawn"} = read!(port)
    assert {:ok, withdrawn} = Knowledge.candidate(Log.gate().orchestration, scope, id)
    assert withdrawn["status"] == "withdrawn"
    assert withdrawn["review_version"] == 2

    {:ok, events} = Log.read_all(from: before.global_seq + 1)
    decisions = Enum.filter(events, &(&1.chapter_id == w.chapter))
    assert Enum.map(decisions, & &1.type) == List.duplicate("KnowledgeCandidateReviewedV1", 2)
    assert Enum.map(decisions, & &1.payload["decision"]) == ["approve", "withdraw"]
    assert Enum.all?(decisions, &(hd(&1.signers).key_id == key_id))

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> flunk("project knowledge browser exited: #{status}")
    after
      15_000 -> flunk("project knowledge browser did not stop")
    end
  end

  defp configure!(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, prior} -> Application.put_env(app, key, prior)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp browser!(base, w) do
    node = System.find_executable("node") || flunk("node is required")

    global =
      case System.find_executable("npm") do
        nil -> nil
        npm -> System.cmd(npm, ["root", "-g"]) |> elem(0) |> String.trim()
      end

    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

    node_path =
      [System.get_env("NODE_PATH"), global]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.join(separator)

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        {:env, [{~c"NODE_PATH", String.to_charlist(node_path)}]},
        args: [@script, base, w.chapter, tenant(), "project-1"]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    port
  end

  defp read!(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode!(line) do
          %{"error" => error} -> flunk(error)
          message -> message
        end

      {^port, {:exit_status, status}} ->
        flunk("project knowledge browser stopped early: #{status}")
    after
      60_000 -> flunk("project knowledge browser did not report progress")
    end
  end
end
