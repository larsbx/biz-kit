defmodule CoopSubstrate.FeedAccessTest do
  @moduledoc """
  Who may read a project's change feed (docs/architecture/2026-10-18-change-feed.md#access):
  the holder of an active operator or suggester grant for exactly that scope,
  proven by a fresh signed request, for as long as the grant stays active.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.Crypto
  alias CoopSubstrate.Feed
  alias CoopSubstrate.Feed.Access
  alias CoopSubstrate.Log

  @scope {"chapter-genesis", "tenant-1", "project-1"}
  @path "/api/v1/chapters/chapter-genesis/tenants/tenant-1/projects/project-1/feed"

  setup do
    gov = new_member("governance")
    op = new_member("operator")
    agent = new_member("suggester")
    deleg = as_role(new_member("operator"), "operator")
    op_grant = operator_grant(gov, op, "alice")
    agent_grant = suggester_grant(gov, agent, "bot")
    {:ok, _} = Log.append([declare_governance(gov), op_grant, agent_grant])
    {:ok, [delegation]} = Log.append(delegation(op, op_grant, deleg, "deleg-bot"))

    %{
      gov: gov,
      op: op,
      agent: agent,
      deleg: deleg,
      op_grant: op_grant,
      agent_grant: agent_grant,
      delegation: delegation
    }
  end

  defp now, do: System.system_time(:millisecond)

  defp request(grant, member, overrides \\ []) do
    Map.merge(
      %{
        method: "GET",
        path: @path,
        scope: @scope,
        cursor: 0,
        timestamp_ms: now(),
        nonce: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        authorization_event_id: grant.event_id,
        key_id: member.signer.key_id
      },
      Map.new(overrides)
    )
  end

  defp sign(request, member), do: Crypto.sign(Access.signing_bytes(request), member.seed)

  defp authorize(request, signature, at \\ now()),
    do: Access.authorize(Log.gate().orchestration, request, signature, at)

  describe "Access.authorize/4" do
    test "an operator or a suggester reads its own project", w do
      for {grant, member, role, principal} <- [
            {w.op_grant, w.op, :operator, "alice"},
            {w.agent_grant, w.agent, :suggester, "bot"}
          ] do
        req = request(grant, member)

        assert {:ok, reader} = authorize(req, sign(req, member))

        assert reader == %Access{
                 grant_id: grant.event_id,
                 role: role,
                 principal_id: principal,
                 scope: @scope
               }
      end
    end

    test "the signature binds every field of the request", w do
      req = request(w.op_grant, w.op)
      sig = sign(req, w.op)

      for {field, value} <- [
            method: "POST",
            path: String.replace(@path, "project-1", "project-2"),
            cursor: 7,
            timestamp_ms: req.timestamp_ms + 1,
            nonce: req.nonce <> "x"
          ] do
        assert authorize(Map.put(req, field, value), sig) == {:error, :bad_signature}
      end
    end

    test "only the grant's own scope", w do
      req = request(w.op_grant, w.op, scope: {"chapter-genesis", "tenant-1", "project-2"})
      assert authorize(req, sign(req, w.op)) == {:error, :scope_mismatch}
    end

    test "only the grant's own key", w do
      req = request(w.op_grant, w.agent)
      assert authorize(req, sign(req, w.agent)) == {:error, :key_mismatch}

      forged = request(w.op_grant, w.op)
      assert authorize(forged, sign(forged, w.agent)) == {:error, :bad_signature}
    end

    test "a delegation confers no read access", w do
      req = request(w.delegation, w.deleg)
      assert authorize(req, sign(req, w.deleg)) == {:error, :unknown_grant}
    end

    test "a revoked grant is refused", w do
      {:ok, _} = Log.append(operator_revoke(w.gov, w.op_grant))
      req = request(w.op_grant, w.op)
      assert authorize(req, sign(req, w.op)) == {:error, :grant_revoked}
    end

    test "a request is fresh for a minute either way", w do
      req = request(w.op_grant, w.op)
      sig = sign(req, w.op)

      assert {:ok, _} = authorize(req, sig, req.timestamp_ms + 60_000)
      assert {:ok, _} = authorize(req, sig, req.timestamp_ms - 60_000)
      assert authorize(req, sig, req.timestamp_ms + 60_001) == {:error, :stale_request}
      assert authorize(req, sig, req.timestamp_ms - 60_001) == {:error, :stale_request}
    end

    test "malformed requests are refused before any lookup", w do
      req = request(w.op_grant, w.op)
      assert authorize(%{req | nonce: "short"}, sign(req, w.op)) == {:error, :invalid_nonce}
      assert authorize(req, "not a signature") == {:error, :bad_signature}
    end
  end

  describe "Feed.authorize/2" do
    test "a request is accepted once", w do
      req = request(w.agent_grant, w.agent)
      sig = sign(req, w.agent)

      assert {:ok, %Access{role: :suggester}} = Feed.authorize(req, sig)
      assert Feed.authorize(req, sig) == {:error, :replayed}
    end

    test "a refused request does not use up its nonce", w do
      req = request(w.op_grant, w.op)
      assert {:error, :bad_signature} = Feed.authorize(req, sign(req, w.agent))
      assert {:ok, _} = Feed.authorize(req, sign(req, w.op))
    end
  end

  describe "a reader's session" do
    setup w do
      req = request(w.op_grant, w.op)
      {:ok, reader} = Feed.authorize(req, sign(req, w.op))
      %{reader: reader}
    end

    test "opens only on the reader's scope", w do
      assert {:ok, _session, _frame} = Feed.open(@scope, 0, w.reader)

      assert Feed.open({"chapter-genesis", "tenant-1", "project-2"}, 0, w.reader) ==
               {:error, :scope_mismatch}
    end

    test "does not open once the grant is revoked", w do
      {:ok, _} = Log.append(operator_revoke(w.gov, w.op_grant))
      assert Feed.open(@scope, 0, w.reader) == {:error, :grant_revoked}
    end

    test "ends at the revocation, without its frame", w do
      {:ok, session, _frame} = Feed.open(@scope, 0, w.reader)
      {:ok, [task]} = Log.append(create(w.op, w.op_grant, "task-1", unscheduled()))
      assert {%{seq: seq}, session} = Feed.advance(session, [task])
      assert seq == task.global_seq

      # One batch: a task change, then the revocation. Nothing in it reaches
      # the reader.
      {:ok, batch} =
        Log.append([
          create(w.op, w.op_grant, "task-2", unscheduled()),
          operator_revoke(w.gov, w.op_grant)
        ])

      assert {:revoked, _session} = Feed.advance(session, batch)
    end

    test "ends on a tick too, when the notification was lost", w do
      {:ok, session, _frame} = Feed.open(@scope, 0, w.reader)
      {:ok, _} = Log.append(operator_revoke(w.gov, w.op_grant))
      assert_receive {:coop_ledger, _lost}

      assert {:revoked, _session} = Feed.tick(session)
    end

    test "a suggester's session ends when its grant is revoked", w do
      req = request(w.agent_grant, w.agent)
      {:ok, reader} = Feed.authorize(req, sign(req, w.agent))
      {:ok, session, _frame} = Feed.open(@scope, 0, reader)
      {:ok, revocation} = Log.append(suggester_revoke(w.gov, w.agent_grant))

      assert {:revoked, _session} = Feed.advance(session, revocation)
    end

    test "is unaffected by other grants' revocations", w do
      {:ok, session, _frame} = Feed.open(@scope, 0, w.reader)
      {:ok, revocation} = Log.append(suggester_revoke(w.gov, w.agent_grant))

      assert {nil, _session} = Feed.advance(session, revocation)
    end
  end
end
