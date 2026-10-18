defmodule CoopSubstrate.CommandsTest do
  @moduledoc """
  A person's decision on a suggestion, signed on their own device
  (docs/architecture/2026-10-18-decide.md). The server prepares the exact
  envelope; only the operator's key can sign it; the ledger admits it as it
  would any operator command.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Commands, Crypto, Log}

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  setup do
    gov = new_member("governance")
    op = new_member("operator")
    agent = new_member("suggester")
    op_grant = operator_grant(gov, op, "alice")
    agent_grant = suggester_grant(gov, agent, "bot")
    {:ok, _} = Log.append([declare_governance(gov), op_grant, agent_grant])
    {:ok, _} = Log.append(create(op, op_grant, "task-1", unscheduled()))

    {:ok, [suggestion]} =
      Log.append(suggest(agent, agent_grant, "task-1", timing_change(timed(t0())), base: 1))

    %{
      gov: gov,
      op: op,
      agent: agent,
      op_grant: op_grant,
      agent_grant: agent_grant,
      suggestion: suggestion
    }
  end

  defp suggestion(id), do: Log.gate().orchestration.suggestions[id]

  # What the browser does: sign the prepared bytes with the device key.
  defp sign(%{signing_bytes: bytes}, member), do: Crypto.sign(bytes, member.seed)

  defp prepare(w, decision, opts \\ []) do
    Commands.prepare(
      Keyword.get(opts, :principal, "alice"),
      Keyword.get(opts, :key_id, w.op.signer.key_id),
      Keyword.get(opts, :scope, @scope),
      decision
    )
  end

  describe "accepting" do
    test "a timing suggestion revises the task with exactly the suggested timing", w do
      {:ok, pending} = prepare(w, {:accept, w.suggestion.event_id})

      assert pending.type == "TaskTimingRevisedV1"

      assert %{
               "task_id" => "task-1",
               "timing" => timing,
               "expected_timing_version" => 1,
               "suggestion_event_id" => id,
               "principal_id" => "alice"
             } = pending.payload

      assert {timing, id} == {timed(t0()), w.suggestion.event_id}

      assert {:ok, env} = Commands.submit("alice", pending.id, sign(pending, w.op))
      assert env.global_seq == Log.head().global_seq
      assert suggestion(w.suggestion.event_id).status == :accepted
    end

    test "a create suggestion creates the task", w do
      {:ok, [s]} =
        Log.append(
          suggest(w.agent, w.agent_grant, "task-2", create_change("Write it up", unscheduled()))
        )

      {:ok, pending} = prepare(w, {:accept, s.event_id})
      assert pending.type == "TaskCreatedV1"
      assert %{"task_id" => "task-2", "title" => "Write it up"} = pending.payload

      assert {:ok, _} = Commands.submit("alice", pending.id, sign(pending, w.op))
      assert suggestion(s.event_id).status == :accepted
    end
  end

  test "declining records the reason", w do
    {:ok, pending} = prepare(w, {:decline, w.suggestion.event_id, "Clashes with the audit"})
    assert pending.type == "TaskSuggestionDeclinedV1"

    assert {:ok, _} = Commands.submit("alice", pending.id, sign(pending, w.op))

    assert %{status: :declined, reason: "Clashes with the audit"} =
             suggestion(w.suggestion.event_id)
  end

  describe "refused before signing" do
    test "without an active operator grant for this principal, key and project", w do
      assert prepare(w, {:accept, w.suggestion.event_id}, principal: "bot") ==
               {:error, :no_operator_grant}

      assert prepare(w, {:accept, w.suggestion.event_id}, key_id: w.agent.signer.key_id) ==
               {:error, :no_operator_grant}

      assert prepare(w, {:accept, w.suggestion.event_id},
               scope: {"chapter-genesis", "tenant-1", "project-2"}
             ) ==
               {:error, :no_operator_grant}

      {:ok, _} = Log.append(operator_revoke(w.gov, w.op_grant))
      assert prepare(w, {:accept, w.suggestion.event_id}) == {:error, :no_operator_grant}
    end

    test "for a suggestion that is unknown or already resolved", w do
      assert prepare(w, {:accept, "nope"}) == {:error, :unknown_suggestion}

      {:ok, pending} = prepare(w, {:decline, w.suggestion.event_id, "no"})
      {:ok, _} = Commands.submit("alice", pending.id, sign(pending, w.op))

      assert prepare(w, {:accept, w.suggestion.event_id}) == {:error, :suggestion_not_pending}
    end
  end

  describe "refused at submission" do
    test "a signature by any other key, and the command is spent", w do
      {:ok, pending} = prepare(w, {:accept, w.suggestion.event_id})

      assert {:error, {:invalid_signature, _}} =
               Commands.submit("alice", pending.id, sign(pending, w.agent))

      assert Commands.submit("alice", pending.id, sign(pending, w.op)) ==
               {:error, :unknown_command}
    end

    test "by another principal, or once expired", w do
      {:ok, pending} = prepare(w, {:accept, w.suggestion.event_id})

      assert Commands.submit("mallory", pending.id, sign(pending, w.op)) ==
               {:error, :unknown_command}

      {:ok, expiring} = prepare(w, {:decline, w.suggestion.event_id, "later"})

      assert Commands.submit("alice", expiring.id, sign(expiring, w.op), expiring.expires_at + 1) ==
               {:error, :unknown_command}

      # Neither attempt spent the first command.
      assert {:ok, _} = Commands.submit("alice", pending.id, sign(pending, w.op))
    end

    test "when the task changed after preparing", w do
      {:ok, pending} = prepare(w, {:accept, w.suggestion.event_id})
      {:ok, _} = Log.append(revise(w.op, w.op_grant, "task-1", 1, timed(t0() + 3_600_000)))

      assert {:error, {:reject, 0, _reason}} =
               Commands.submit("alice", pending.id, sign(pending, w.op))

      assert suggestion(w.suggestion.event_id).status == :pending
    end
  end
end
