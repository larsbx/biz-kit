defmodule SpruceGoose.Web.BrowserTest do
  @moduledoc """
  The first workflow in a real browser (docs/architecture/2026-10-18-decide.md,
  2026-10-19-device-enrolment.md): a person signs in, their browser makes its
  device key and requests access, an administrator approves the code, an
  agent suggests, and the person accepts in the web view. The ledger then
  holds the decision, signed by the key the browser made. The person then
  takes a task from proposed to completed (2026-10-19-execution.md), with a
  reviewer accepting its evidence from a browser of their own.

  Needs Node and Playwright with Chromium, so it is excluded by default:
  `mix test --include browser`.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.Enrolments.Approver
  alias CoopSubstrate.Log

  @moduletag :browser

  @script Path.expand("../../browser/decide.cjs", __DIR__)

  test "a device enrols itself, then accepts a suggestion signed by its own key" do
    providers!()
    w = world()
    person = Principal.new_id()
    reviewer = Principal.new_id()
    administrator = Principal.new_id()

    bind([
      {"https://idp.test", "sub-person", person},
      {"https://idp.test", "sub-reviewer", reviewer},
      {"https://idp.test", "sub-admin", administrator}
    ])

    base = serve!()
    port = browser!(base, w)
    assert %{"code" => code, "key_id" => key_id, "admin_code" => admin_code} = read!(port)

    # The administrator approves by code; an agent suggests.
    {:ok, details} = Approver.fetch(base, code)

    assert {details["principal_id"], details["key_id"], details["label"]} ==
             {person, key_id, "Test laptop"}

    governance = %{key_id: w.gov.signer.key_id, pubkey: w.gov.signer.pubkey, seed: w.gov.seed}
    {:ok, %{"event_id" => grant_id}} = Approver.approve(base, details, governance)

    # The bootstrap: the seed holder approves the first administrator's browser.
    {:ok, admin_request} = Approver.fetch(base, admin_code)
    assert {admin_request["principal_id"], admin_request["role"]} == {administrator, "governance"}
    {:ok, _} = Approver.approve(base, admin_request, governance)
    create!(w, w.op_grant, "task-3")

    create!(w, w.op_grant, "task-1")

    suggestion =
      suggest!(w, w.agent_grant, "task-1", %{"schedule" => nil, "due_ms" => 1_792_396_800_000}, 1)

    to_create =
      suggest_create!(w, w.agent_grant, "task-2", "Write it up", %{
        "schedule" => nil,
        "due_ms" => nil
      })

    Port.command(port, "go\n")
    assert %{"proposed" => true} = read!(port)

    # Governance defines the Definition of Done and readiness; the browser
    # then uploads the SOP and the input and records custody of them.
    readiness!(w, "task-2")

    # The person takes it to ready, starts it and submits evidence; a
    # reviewer's browser asks for reviewer access, and the administrator's
    # browser approves it in the view.
    Port.command(port, "go\n")

    assert %{"reviewer_key_id" => reviewer_key, "reviewer" => ^reviewer} = read!(port)
    assert %{"done" => "Recorded on the ledger" <> _} = read!(port)

    suggestions = Log.gate().orchestration.suggestions
    assert suggestions[suggestion.event_id].status == :accepted

    # The create suggestion was edited before accepting.
    assert suggestions[to_create.event_id].status == :amended
    task = Log.gate().orchestration.tasks[{w.chapter, tenant(), "project-1", "task-2"}]
    assert task.title == "Write up the audit"

    # Then proposed, its SOP and input stored from the browser, the SOP
    # acknowledged, queued and marked ready, started, its evidence stored and
    # submitted, accepted by the reviewer and completed, each signed by the
    # browser's own key.
    assert task.state == "completed"
    assert task.started_by == person
    assert task.readiness.acknowledgment.principal_id == person
    assert task.dod.submission.principal_id == person

    assert %{principal_id: ^reviewer, decision: "accept", reason: "Complete and clear"} =
             task.dod.review

    receipts = Log.gate().orchestration.custody_receipts

    stored =
      for {_, r} <- receipts, r.chapter_id == w.chapter, r.principal_id == person, do: r.digest

    assert Enum.sort(stored) ==
             Enum.sort([
               {:bytes, :crypto.hash(:sha256, "SOP for #{w.chapter}")},
               {:bytes, :crypto.hash(:sha256, "Input for #{w.chapter}")},
               {:bytes, :crypto.hash(:sha256, "Report for #{w.chapter}")}
             ])

    assert task.dod.submission.evidence == %{
             "report" => {:bytes, :crypto.hash(:sha256, "Report for #{w.chapter}")}
           }

    {:ok, events} = Log.read_all(from: suggestion.global_seq + 1)

    [decision] =
      for e <- events, e.type == "TaskTimingRevisedV1", e.chapter_id == w.chapter, do: e

    assert decision.payload["principal_id"] == person
    assert decision.payload["authorization_event_id"] == grant_id

    assert hd(decision.signers).pubkey ==
             Base.url_decode64!(details["public_key"], padding: false)

    # Then the device retired itself, signed by its own key.
    refute Log.gate().orchestration.grants[grant_id].active

    [revocation] =
      for e <- events,
          e.type == "TaskDeviceRevokedV1",
          e.chapter_id == w.chapter,
          do: e

    assert revocation.payload["revoked_grant_event_id"] == grant_id
    assert hd(revocation.signers).pubkey == hd(decision.signers).pubkey

    of_type = fn type -> for e <- events, e.type == type, e.chapter_id == w.chapter, do: e end
    # The administrator's browser key, declared for it by the seed holder,
    # approved the reviewer, cancelled task-3 and offboarded the reviewer.
    {:ok, from_start} = Log.read_all(from: 1)

    [declared] =
      for e <- from_start,
          e.type == "RoleKeyDeclared",
          e.chapter_id == w.chapter,
          e.payload["member_id"] == administrator,
          do: e

    admin_key = elem(declared.payload["pubkey"], 1)
    [reviewer_grant] = of_type.("TaskReviewerGrantedV1")
    assert reviewer_grant.payload["key_id"] == reviewer_key
    assert hd(reviewer_grant.signers).pubkey == admin_key
    [governance_cancel] = of_type.("TaskCancelledByGovernanceV1")
    assert governance_cancel.payload["task_id"] == "task-3"
    assert hd(governance_cancel.signers).pubkey == admin_key
    [offboarded] = of_type.("TaskPrincipalOffboardedV1")
    assert offboarded.payload["principal_id"] == reviewer
    assert hd(offboarded.signers).pubkey == admin_key
    refute Log.gate().orchestration.dod_grants[reviewer_grant.event_id].active

    [review] = of_type.("TaskDoDReviewedV1")
    assert hd(review.signers).pubkey == elem(reviewer_grant.payload["pubkey"], 1)
    assert hd(review.signers).role == "reviewer"

    for type <- ["TaskStartedV1", "TaskEvidenceSubmittedV2", "TaskCompletedV1"] do
      [e] = of_type.(type)
      assert hd(e.signers).pubkey == hd(decision.signers).pubkey
    end

    [completed] = of_type.("TaskCompletedV1")
    assert completed.payload["review_event_id"] == review.event_id

    # The rescheduled task was then cancelled from the page, with a reason.
    [cancelled] = of_type.("TaskCancelledV1")
    assert cancelled.payload["reason"] == "No longer needed"
    assert hd(cancelled.signers).pubkey == hd(decision.signers).pubkey

    assert Log.gate().orchestration.tasks[{w.chapter, tenant(), "project-1", "task-1"}].state ==
             "cancelled"

    [created] = for e <- events, e.type == "TaskCreatedV1", e.chapter_id == w.chapter, do: e
    assert created.payload["suggestion_event_id"] == to_create.event_id
    assert hd(created.signers).pubkey == hd(decision.signers).pubkey
  end

  # What the task needs, by digest: the browser stores the files itself.
  defp readiness!(w, task_id) do
    sop = :crypto.hash(:sha256, "SOP for #{w.chapter}")
    input = :crypto.hash(:sha256, "Input for #{w.chapter}")

    key = {w.chapter, tenant(), "project-1", task_id}
    version = fn -> Log.gate().orchestration.tasks[key].version end
    subject = %{"tenant_id" => tenant(), "project_id" => "project-1", "task_id" => task_id}

    append!(
      event(
        w,
        w.gov,
        "TaskDoDDefinedV1",
        Map.merge(subject, %{
          "expected_version" => version.(),
          "criteria" => [%{"id" => "report", "description" => "Report supplied"}]
        })
      )
    )

    append!(
      event(
        w,
        w.gov,
        "TaskReadinessDefinedV1",
        Map.merge(subject, %{
          "expected_version" => version.(),
          "artifact_requirements" => %{"input" => {:bytes, input}},
          "predecessor_ids" => [],
          "sop_digest" => {:bytes, sop}
        })
      )
    )
  end

  defp browser!(base, w) do
    node = System.find_executable("node") || flunk("node is not installed")
    global = System.cmd("npm", ["root", "-g"]) |> elem(0) |> String.trim()

    Port.open({:spawn_executable, node}, [
      :binary,
      :exit_status,
      {:line, 1_000_000},
      {:env, [{~c"NODE_PATH", String.to_charlist(global)}]},
      args: [@script, base, w.chapter, tenant(), "project-1"]
    ])
  end

  defp read!(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"error" => error}} -> flunk("browser: " <> error)
          {:ok, message} -> message
          {:error, _} -> read!(port)
        end

      {^port, {:exit_status, status}} ->
        flunk("browser exited with #{status}")
    after
      30_000 -> flunk("no word from the browser in 30s")
    end
  end
end
