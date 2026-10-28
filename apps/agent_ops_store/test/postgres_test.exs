defmodule AgentOpsStore.PostgresTest do
  use ExUnit.Case, async: false

  alias AgentOpsStore.Postgres

  @moduletag :integration

  setup do
    conn = start_supervised!({Postgrex, AgentOpsStore.TestConnection.options()})

    %{conn: conn}
  end

  defp plan do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    run_id = "run-" <> random
    intent = "intent-" <> random

    %{
      effect_id: "agent-run:" <> intent,
      intent_event_id: intent,
      run_id: run_id,
      chapter_id: "chapter-ci",
      tenant_id: "tenant-ci",
      project_id: "project-ci",
      execution_profile_id: "approved",
      execution_profile_digest: {:bytes, <<1::256>>},
      execution: %{
        run_id: run_id,
        ticket: %{
          "chapter_id" => "chapter-ci",
          "tenant_id" => "tenant-ci",
          "project_id" => "project-ci",
          "task_id" => "task-ci",
          "task_version" => 3,
          "source_event_id" => "source-ci",
          "definition_digest" => String.duplicate("a", 64)
        }
      },
      requirements: %{"max_duration_ms" => 30_000, "max_output_bytes" => 4096}
    }
  end

  test "launch validation rejects stale, expired and cancelled leases", %{conn: conn} do
    p = plan()
    assert {:ok, :new} = Postgres.register(conn, p)
    assert {:ok, lease} = Postgres.claim(conn, p.effect_id, 1, "worker", 60_000, 2)
    assert :ok = Postgres.validate_launch_lease(conn, p.effect_id, lease)

    for stale <- [
          %{lease | version: lease.version + 1},
          %{lease | epoch: lease.epoch + 1},
          %{lease | token: :crypto.strong_rand_bytes(32)}
        ] do
      assert {:error, :launch_lease_invalid} =
               Postgres.validate_launch_lease(conn, p.effect_id, stale)
    end

    Postgrex.query!(
      conn,
      "UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE effect_id=$1",
      [p.effect_id]
    )

    assert {:error, :launch_lease_invalid} =
             Postgres.validate_launch_lease(conn, p.effect_id, lease)

    assert {:ok, _} = Postgres.request_cancel(conn, p.effect_id, lease.version)

    assert {:error, :launch_lease_invalid} =
             Postgres.validate_launch_lease(conn, p.effect_id, lease)
  end

  test "durable registration, CAS claim, backend binding, and candidate", %{conn: conn} do
    p = plan()
    assert {:ok, :new} = Postgres.register(conn, p)
    assert {:ok, :existing} = Postgres.register(conn, p)

    changed_task = put_in(p, [:execution, :ticket, "task_version"], 4)
    assert {:error, :agent_effect_conflict} = Postgres.register(conn, changed_task)

    assert {:ok, %{epoch: 1, version: 2, token: token}} =
             Postgres.claim(conn, p.effect_id, 1, "worker1", 60_000, 2)

    assert byte_size(token) == 32

    assert {:error, :claim_refused} = Postgres.claim(conn, p.effect_id, 1, "worker2", 60_000, 2)

    assert {:error, :transition_refused} =
             Postgres.renew(conn, p.effect_id, 2, 1, :crypto.strong_rand_bytes(32), 60_000)

    assert {:ok, 3} = Postgres.renew(conn, p.effect_id, 2, 1, token, 60_000)
    assert {:ok, 4} = Postgres.attach_backend(conn, p.effect_id, 3, 1, token, "backend-ci")

    assert {:error, :transition_refused} =
             Postgres.attach_backend(conn, p.effect_id, 4, 1, token, "different-backend")

    assert {:ok, 5} =
             Postgres.record_candidate(conn, p.effect_id, 4, 1, token, {:bytes, <<5::256>>})

    assert {:ok, state} = Postgres.snapshot(conn, p.effect_id)
    assert state.phase == "candidate_ready"
    assert state.epoch == 1
    assert state.version == 5
    assert state.backend_ref == "backend-ci"
    assert state.candidate_digest == <<5::256>>

    assert {:error, :claim_refused} = Postgres.claim(conn, p.effect_id, 5, "worker3", 60_000, 2)
  end

  test "cancel requests fence tokens and preserve proof reference", %{conn: conn} do
    p = plan()
    assert {:ok, :new} = Postgres.register(conn, p)

    assert {:ok, %{epoch: 1, version: 2, token: token}} =
             Postgres.claim(conn, p.effect_id, 1, "worker1", 60_000, 2)

    assert {:ok, 3} = Postgres.request_cancel(conn, p.effect_id, 2)

    assert {:error, :transition_refused} = Postgres.renew(conn, p.effect_id, 3, 1, token, 60_000)

    assert {:ok, 4} =
             Postgres.confirm_cancel_preverified(conn, p.effect_id, 3, "verified-termination")

    assert {:ok, state} = Postgres.snapshot(conn, p.effect_id)
    assert state.phase == "cancelled"
    assert state.version == 4
    assert state.cancellation_receipt_id == "verified-termination"

    assert {:error, :transition_refused} =
             Postgres.confirm_cancel_preverified(conn, p.effect_id, 4, "another-receipt")
  end
end
