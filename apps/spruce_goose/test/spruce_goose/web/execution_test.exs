defmodule SpruceGoose.Web.ExecutionTest do
  @moduledoc """
  A task after ready, over HTTP (docs/architecture/2026-10-19-execution.md):
  the person starts it, uploads and submits evidence, a reviewer reads it
  and reviews from their reviewer device, and the person completes it. Each
  step is prepared for a session and signed by that person's device.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Crypto, Log}
  alias CoopSubstrate.Harness.Artifacts

  setup do
    providers!()
    w = world()
    person = Principal.new_id()
    reviewer = Principal.new_id()
    stranger = Principal.new_id()
    device = member("operator")
    tablet = member("reviewer")
    grant = grant!(w, "TaskOperatorGrantedV1", device, person, "project-1")
    grant!(w, "TaskReviewerGrantedV1", tablet, reviewer, "project-1")
    create!(w, grant, "task-1", "project-1", device)

    bind([
      {"https://idp.test", "sub-person", person},
      {"https://idp.test", "sub-reviewer", reviewer},
      {"https://idp.test", "sub-stranger", stranger}
    ])

    w =
      Map.merge(w, %{
        person: %{session: session!("second", "sub-person"), device: device},
        reviewer: %{session: session!("second", "sub-reviewer"), device: tablet},
        stranger: session!("second", "sub-stranger")
      })

    ready!(w)
    w
  end

  defp path(w), do: "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1"

  # What a device does: prepare, sign the bytes it was given, submit.
  defp step(w, who, body) do
    body = Map.put(body, "key_id", who.device.signer.key_id)

    with {201, held} <- post(path(w) <> "/commands", who.session, body) do
      signature =
        held["signing_bytes"]
        |> Base.url_decode64!(padding: false)
        |> Crypto.sign(who.device.seed)
        |> Base.url_encode64(padding: false)

      post("/api/v1/commands/#{held["id"]}", who.session, %{"signature" => signature})
    end
  end

  defp post(path, cookie, body) do
    conn =
      call(
        :post,
        path,
        [{"content-type", "application/json"}, {"cookie", cookie}],
        Jason.encode!(body)
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp get(path, cookie), do: call(:get, path, [{"cookie", cookie}])

  defp upload(w, bytes, query) do
    conn =
      call(
        :post,
        path(w) <> "/artifacts" <> query,
        [
          {"content-type", "application/octet-stream"},
          {"x-content-sha256", Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)},
          {"cookie", w.person.session}
        ],
        bytes
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp task(w), do: Log.gate().orchestration.tasks[{w.chapter, tenant(), "project-1", "task-1"}]

  defp governance!(w, type, payload) do
    subject = %{"tenant_id" => tenant(), "project_id" => "project-1", "task_id" => "task-1"}

    append!(
      event(
        w,
        w.gov,
        type,
        Map.merge(subject, Map.put(payload, "expected_version", task(w).version))
      )
    )
  end

  defp custody!(w, bytes) do
    {:ok, digest} = Artifacts.put(bytes)

    {201, %{"event_id" => id}} =
      step(w, w.person, %{
        "action" => "record_custody",
        "artifact_digest" => Base.encode16(digest, case: :lower)
      })

    {digest, id}
  end

  defp ready!(w) do
    {201, _} = step(w, w.person, %{"action" => "propose", "task_id" => "task-1"})
    {sop, sop_receipt} = custody!(w, "SOP for #{w.chapter}")
    {input, input_receipt} = custody!(w, "Input for #{w.chapter}")

    governance!(w, "TaskDoDDefinedV1", %{
      "criteria" => [%{"id" => "report", "description" => "Report supplied"}]
    })

    governance!(w, "TaskReadinessDefinedV1", %{
      "artifact_requirements" => %{"input" => {:bytes, input}},
      "predecessor_ids" => [],
      "sop_digest" => {:bytes, sop}
    })

    for body <- [
          %{"action" => "acknowledge_sop", "custody_receipt_id" => sop_receipt},
          %{"action" => "queue"},
          %{"action" => "ready", "custody_receipts" => %{"input" => input_receipt}}
        ],
        do: {201, _} = step(w, w.person, Map.put(body, "task_id", "task-1"))
  end

  # Started, with the report uploaded as evidence and submitted.
  defp submitted!(w, report) do
    {201, _} = step(w, w.person, %{"action" => "start", "task_id" => "task-1"})
    assert {201, %{"digest" => digest}} = upload(w, report, "?evidence_for=task-1")

    {201, %{"event_id" => receipt}} =
      step(w, w.person, %{"action" => "record_custody", "artifact_digest" => digest})

    {201, _} =
      step(w, w.person, %{
        "action" => "submit_evidence",
        "task_id" => "task-1",
        "custody_receipts" => %{"report" => receipt}
      })

    {digest, receipt}
  end

  test "start, evidence, a review from the reviewer's device, complete", w do
    report = "The report, #{w.chapter}"
    {digest, receipt} = submitted!(w, report)
    assert task(w).state == "in_progress"

    # The reviewer reads what was submitted, and the file itself, as a download.
    conn = get(path(w) <> "/tasks/task-1/evidence", w.reviewer.session)
    assert conn.status == 200

    assert %{
             "evidence" => %{"report" => %{"digest" => ^digest, "custody_receipt_id" => ^receipt}}
           } =
             Jason.decode!(conn.resp_body)

    conn = get(path(w) <> "/receipts/#{receipt}", w.reviewer.session)
    assert {conn.status, conn.resp_body} == {200, report}
    assert ["attachment" <> _] = Plug.Conn.get_resp_header(conn, "content-disposition")
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    review = %{"action" => "review", "task_id" => "task-1", "decision" => "accept"}

    # Only a reviewer device reviews.
    assert {403, %{"error" => "no_reviewer_grant"}} =
             step(w, w.person, Map.put(review, "reason", "Mine"))

    assert {201, %{"event_id" => accepted}} =
             step(w, w.reviewer, Map.put(review, "reason", "Complete and clear"))

    assert %{decision: "accept", principal_id: _} = task(w).dod.review

    assert {201, _} =
             step(w, w.person, %{
               "action" => "complete",
               "task_id" => "task-1",
               "review_event_id" => accepted
             })

    assert task(w).state == "completed"
  end

  test "refusals, named", w do
    # Evidence only for a task in progress.
    assert {422, %{"error" => "not_named"}} = upload(w, "Too early", "?evidence_for=task-1")
    assert {400, _} = upload(w, "Too early", "?evidence_for[]=task-1")

    {_digest, receipt} = submitted!(w, "A draft, #{w.chapter}")

    assert {409, %{"error" => "dod_review_mismatch"}} =
             step(w, w.person, %{
               "action" => "complete",
               "task_id" => "task-1",
               "review_event_id" => "none"
             })

    assert {409, %{"error" => "invalid_dod_review"}} =
             step(w, w.reviewer, %{
               "action" => "review",
               "task_id" => "task-1",
               "decision" => "maybe",
               "reason" => "Unsure"
             })

    assert {400, %{"error" => "bad_action"}} =
             step(w, w.person, %{"action" => "complete", "task_id" => "task-1"})

    # Someone without a grant here reads neither the evidence nor the file.
    assert get(path(w) <> "/tasks/task-1/evidence", w.stranger).status == 403
    assert get(path(w) <> "/receipts/#{receipt}", w.stranger).status == 403
    assert get(path(w) <> "/receipts/nope", w.reviewer.session).status == 404
    assert get(path(w) <> "/tasks/task-1/evidence", "bizkit_session=nope").status == 401
  end
end
