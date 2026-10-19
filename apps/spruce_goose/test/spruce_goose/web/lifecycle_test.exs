defmodule SpruceGoose.Web.LifecycleTest do
  @moduledoc """
  A person's lifecycle steps over HTTP (docs/architecture/2026-10-19-lifecycle.md):
  prepared for their session, signed by their device, refused before signing
  with the ledger's own reason.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Crypto, Log}

  setup do
    providers!()
    w = world()
    person = Principal.new_id()
    device = member("operator")
    grant = grant!(w, "TaskOperatorGrantedV1", device, person, "project-1")
    create!(w, grant, "task-1", "project-1", device)
    bind([{"https://idp.test", "sub-person", person}])

    Map.merge(w, %{
      person: person,
      device: device,
      grant: grant,
      session: session!("second", "sub-person")
    })
  end

  defp step(w, body) do
    path = "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1/commands"
    body = Map.put(body, "key_id", w.device.signer.key_id)

    with {201, held} <- post(path, w.session, body) do
      signature =
        held["signing_bytes"]
        |> Base.url_decode64!(padding: false)
        |> Crypto.sign(w.device.seed)
        |> Base.url_encode64(padding: false)

      post("/api/v1/commands/#{held["id"]}", w.session, %{"signature" => signature})
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

  defp task(w), do: Log.gate().orchestration.tasks[{w.chapter, tenant(), "project-1", "task-1"}]

  test "propose, then a queue the ledger refuses, named", w do
    assert {201, _} = step(w, %{"action" => "propose", "task_id" => "task-1"})
    assert task(w).state == "proposed"

    assert {409, %{"error" => "dod_not_defined"}} =
             step(w, %{"action" => "queue", "task_id" => "task-1"})

    assert {409, %{"error" => "invalid_task_transition"}} =
             step(w, %{"action" => "propose", "task_id" => "task-1"})
  end

  test "revoke a delegation the person made", w do
    agent = member("operator")

    [d] =
      append!(
        event(w, w.device, "TaskDelegationGrantedV1", %{
          "tenant_id" => tenant(),
          "project_id" => "project-1",
          "principal_id" => w.person,
          "authorization_event_id" => w.grant.event_id,
          "lifecycle_version" => 1,
          "delegate_principal_id" => "bot",
          "key_id" => agent.signer.key_id,
          "pubkey" => {:bytes, agent.signer.pubkey},
          "kinds" => ["timing"],
          "window" => %{"not_before_ms" => 0, "not_after_ms" => 1_000},
          "max_block_ms" => 1_000,
          "budget" => 1
        })
      )

    assert {201, _} =
             step(w, %{"action" => "revoke_delegation", "delegation_event_id" => d.event_id})

    refute Log.gate().orchestration.delegations[d.event_id].active
  end

  test "malformed or unknown steps", w do
    assert {400, %{"error" => "bad_action"}} =
             step(w, %{"action" => "launch", "task_id" => "task-1"})

    assert {400, %{"error" => "bad_action"}} =
             step(w, %{
               "action" => "ready",
               "task_id" => "task-1",
               "custody_receipts" => %{"x" => 1}
             })

    assert {409, %{"error" => "unknown_task"}} =
             step(w, %{"action" => "propose", "task_id" => "nope"})

    assert {409, %{"error" => "unknown_delegation"}} =
             step(w, %{"action" => "revoke_delegation", "delegation_event_id" => "nope"})
  end
end
