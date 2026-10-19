defmodule SpruceGoose.Web.UploadTest do
  @moduledoc """
  A person's device stores an artifact and records custody of it
  (docs/architecture/2026-10-19-uploads.md): only with a device grant in the
  project, only bytes that hash to what the device computed, at most the
  custody limit.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{ArtifactCustody, Crypto, Log}

  setup do
    providers!()
    w = world()
    person = Principal.new_id()
    stranger = Principal.new_id()
    device = member("operator")
    grant = grant!(w, "TaskOperatorGrantedV1", device, person, "project-1")

    bind([
      {"https://idp.test", "sub-person", person},
      {"https://idp.test", "sub-stranger", stranger}
    ])

    Map.merge(w, %{
      device: device,
      grant: grant,
      person: person,
      session: session!("second", "sub-person"),
      stranger: session!("second", "sub-stranger")
    })
  end

  defp path(w), do: "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1"

  defp upload(w, bytes, opts \\ []) do
    headers =
      [
        {"content-type", Keyword.get(opts, :type, "application/octet-stream")},
        {"x-content-sha256", Keyword.get(opts, :claim, hex(bytes))}
      ] ++ if(cookie = Keyword.get(opts, :cookie, w.session), do: [{"cookie", cookie}], else: [])

    conn = call(:post, path(w) <> "/artifacts", headers, bytes)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # A proposed task whose readiness names these files' digests: only those
  # may be stored.
  defp naming!(w, sop, inputs) do
    create!(w, w.grant, "task-1", "project-1", w.device)
    subject = %{"tenant_id" => tenant(), "project_id" => "project-1", "task_id" => "task-1"}

    append!(
      event(
        w,
        w.device,
        "TaskProposedV1",
        Map.merge(subject, %{
          "principal_id" => w.person,
          "authorization_event_id" => w.grant.event_id,
          "lifecycle_version" => 1,
          "expected_version" => 1
        })
      )
    )

    append!(
      event(
        w,
        w.gov,
        "TaskDoDDefinedV1",
        Map.merge(subject, %{
          "expected_version" => 2,
          "criteria" => [%{"id" => "r", "description" => "Report"}]
        })
      )
    )

    append!(
      event(
        w,
        w.gov,
        "TaskReadinessDefinedV1",
        Map.merge(subject, %{
          "expected_version" => 3,
          "artifact_requirements" =>
            inputs
            |> Enum.with_index()
            |> Map.new(fn {b, i} -> {"in#{i}", {:bytes, :crypto.hash(:sha256, b)}} end),
          "predecessor_ids" => [],
          "sop_digest" => {:bytes, :crypto.hash(:sha256, sop)}
        })
      )
    )
  end

  defp json(path, cookie, body) do
    conn =
      call(
        :post,
        path,
        [{"content-type", "application/json"}, {"cookie", cookie}],
        Jason.encode!(body)
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "stored, then custody recorded by the device's signature", w do
    bytes = "The SOP, from the browser #{w.chapter}"
    naming!(w, bytes, [])
    assert {201, %{"digest" => digest, "size" => size}} = upload(w, bytes)
    assert {digest, size} == {hex(bytes), byte_size(bytes)}

    {201, held} =
      json(path(w) <> "/commands", w.session, %{
        "action" => "record_custody",
        "artifact_digest" => digest,
        "key_id" => w.device.signer.key_id
      })

    signature =
      held["signing_bytes"]
      |> Base.url_decode64!(padding: false)
      |> Crypto.sign(w.device.seed)
      |> Base.url_encode64(padding: false)

    assert {201, %{"event_id" => id}} =
             json("/api/v1/commands/#{held["id"]}", w.session, %{"signature" => signature})

    assert %{principal_id: principal} = Log.gate().orchestration.custody_receipts[id]
    assert principal == w.person
  end

  test "refused: no session, no grant here, not named, wrong hash, too large, not raw bytes", w do
    big = :binary.copy("x", ArtifactCustody.limit() + 1)
    naming!(w, "x", ["y", big])

    assert {422, %{"error" => "not_named"}} = upload(w, "something no task names")
    assert {401, _} = upload(w, "x", cookie: false)
    assert {403, %{"error" => "no_operator_grant"}} = upload(w, "x", cookie: w.stranger)
    assert {422, %{"error" => "digest_mismatch"}} = upload(w, "x", claim: hex("y"))
    assert {400, _} = upload(w, "x", claim: "not hex")
    assert {400, _} = upload(w, "x", type: "text/plain")

    assert {413, %{"error" => "too_large"}} = upload(w, big)

    assert {400, %{"error" => "bad_action"}} =
             json(path(w) <> "/commands", w.session, %{
               "action" => "record_custody",
               "artifact_digest" => "short",
               "key_id" => w.device.signer.key_id
             })
  end
end
