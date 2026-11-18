defmodule TaskHost.Web.OwnershipBrowserTest do
  @moduledoc "Real browser acceptance for the governed ownership workflow."
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Enrolments, Log}
  alias CoopSubstrate.Enrolments.Approver
  alias TaskCore.{Projects, State}

  @moduletag :browser
  @moduletag timeout: 180_000
  @script Path.expand("../../browser/ownership.cjs", __DIR__)

  test "complete atomic succession, stale/rejected signatures and historic backfill" do
    providers!()
    w = world()
    admin = Principal.new_id()
    bind([{"https://idp.test", "sub-owner-admin", admin}])

    append!(
      event(w, w.gov, "TaskPrincipalKindDeclaredV1", %{
        "principal_id" => "alice",
        "kind" => "human"
      })
    )

    grant!(w, "TaskOperatorGrantedV1", member("operator"), "legacy", "old-project")
    base = serve!()
    node = System.find_executable("node") || flunk("node is required")
    global = System.cmd("npm", ["root", "-g"]) |> elem(0) |> String.trim()

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        {:env, [{~c"NODE_PATH", String.to_charlist(global)}]},
        args: [@script, base, w.chapter, tenant()]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    assert %{"code" => code} = read!(port)
    {:ok, request} = Enrolments.fetch(code)
    assert request.principal_id == admin
    {:ok, details} = Approver.fetch(base, code)
    assert {:ok, _} = Approver.approve(base, details, governance(w))
    Port.command(port, "go\n")
    assert %{"stage" => "selected"} = read!(port)
    grant!(w, "TaskReviewerGrantedV1", member("reviewer"), "another-reviewer", "project-1")
    Port.command(port, "go\n")
    assert %{"stage" => "prepared"} = read!(port)

    # Change holdings while the browser is showing the exact batch to sign.
    grant!(w, "TaskOperatorGrantedV1", member("operator"), "owner", "project-3")
    grant!(w, "TaskOperatorGrantedV1", member("operator"), "alice", "project-3")

    append!(
      event(w, w.gov, "TaskProjectOwnerAssignedV1", %{
        "tenant_id" => tenant(),
        "project_id" => "project-3",
        "principal_id" => "owner"
      })
    )

    head = Log.head()
    Port.command(port, "go\n")
    assert %{"stage" => "stale_refused"} = read!(port)
    assert Log.head() == head
    assert Projects.owner(Log.gate().orchestration, {w.chapter, tenant(), "project-1"}) == "owner"
    Port.command(port, "go\n")
    assert %{"stage" => "signature_refused"} = read!(port)
    assert Log.head() == head
    Port.command(port, "go\n")
    assert %{"stage" => "succeeded"} = read!(port)
    o = Log.gate().orchestration

    for project <- ["project-1", "project-2", "project-3"] do
      scope = {w.chapter, tenant(), project}
      assert Projects.owner(o, scope) == "alice"
      assert Projects.eligible_owner?(o, scope)
      assert State.held_by(o, "owner", scope) == []
    end

    assert State.held_by(o, "owner", {w.chapter, tenant(), "project-3"}) == []
    assert Projects.violations(o) == []
    {:ok, history} = Log.read_all(from: 1)
    Port.command(port, "go\n")
    assert %{"stage" => "backfilled"} = read!(port)

    assert Projects.owner(Log.gate().orchestration, {w.chapter, tenant(), "old-project"}) ==
             "legacy"

    {:ok, after_backfill} = Log.read_all(from: 1)
    assert Enum.take(after_backfill, length(history)) == history
  end

  defp read!(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode!(line) do
          %{"error" => error} -> flunk(error)
          message -> message
        end

      {^port, {:exit_status, status}} ->
        flunk("ownership browser exited: #{status}")
    after
      45_000 -> flunk("ownership browser did not report progress within 45s")
    end
  end
end
