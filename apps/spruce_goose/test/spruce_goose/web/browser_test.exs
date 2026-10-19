defmodule SpruceGoose.Web.BrowserTest do
  @moduledoc """
  The first workflow in a real browser (docs/architecture/2026-10-18-decide.md,
  2026-10-19-device-enrolment.md): a person signs in, their browser makes its
  device key and requests access, an administrator approves the code, an
  agent suggests, and the person accepts in the web view. The ledger then
  holds the decision, signed by the key the browser made.

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
    bind([{"https://idp.test", "sub-person", person}])

    base = serve!()
    port = browser!(base, w)
    assert %{"code" => code, "key_id" => key_id} = read!(port)

    # The administrator approves by code; an agent suggests.
    {:ok, details} = Approver.fetch(base, code)

    assert {details["principal_id"], details["key_id"], details["label"]} ==
             {person, key_id, "Test laptop"}

    governance = %{key_id: w.gov.signer.key_id, pubkey: w.gov.signer.pubkey, seed: w.gov.seed}
    {:ok, %{"event_id" => grant_id}} = Approver.approve(base, details, governance)

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

    # Governance defines the Definition of Done and readiness; the SOP and
    # the input are stored and recorded in custody.
    readiness!(w, "task-2")

    Port.command(port, "go\n")
    assert %{"done" => "Recorded on the ledger" <> _} = read!(port)

    suggestions = Log.gate().orchestration.suggestions
    assert suggestions[suggestion.event_id].status == :accepted

    # The create suggestion was edited before accepting.
    assert suggestions[to_create.event_id].status == :amended
    task = Log.gate().orchestration.tasks[{w.chapter, tenant(), "project-1", "task-2"}]
    assert task.title == "Write up the audit"

    # Then proposed, its SOP acknowledged, queued and marked ready, each signed
    # by the browser's key.
    assert task.state == "ready"
    assert task.readiness.acknowledgment.principal_id == person

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

    [created] = for e <- events, e.type == "TaskCreatedV1", e.chapter_id == w.chapter, do: e
    assert created.payload["suggestion_event_id"] == to_create.event_id
    assert hd(created.signers).pubkey == hd(decision.signers).pubkey
  end

  defp readiness!(w, task_id) do
    alias CoopSubstrate.Harness.Artifacts
    {:ok, sop} = Artifacts.put("The SOP for #{w.chapter}")
    {:ok, input} = Artifacts.put("The input for #{w.chapter}")

    for digest <- [sop, input] do
      append!(
        event(w, w.op, "ArtifactCustodyRecordedV1", %{
          "tenant_id" => tenant(),
          "project_id" => "project-1",
          "principal_id" => w.op_grant.payload["principal_id"],
          "authorization_event_id" => w.op_grant.event_id,
          "artifact_digest" => {:bytes, digest}
        })
      )
    end

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
