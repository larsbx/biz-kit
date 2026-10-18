defmodule SpruceGoose.Web.FeedTest do
  @moduledoc """
  The change-feed endpoint (docs/architecture/2026-10-18-change-feed.md#transport).

  SpruceGoose only carries the feed: `CoopSubstrate.Feed` decides what a reader
  sees and whether it may read at all, from the ledger's own grants. Refusals
  are checked through the router; live streams against a real server, since a
  stream is what only a real connection shows. Each test gets its own chapter,
  so the ledger needs no reset.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.LedgerFixtures

  alias CoopSubstrate.{Crypto, Log}
  alias CoopSubstrate.Feed.Access

  @tenant "tenant-1"

  setup do
    world()
  end

  # -- requests ---------------------------------------------------------------------

  defp scope(w, project), do: {w.chapter, @tenant, project}

  # An Authorization header signing exactly this request.
  defp signature(w, method, path, cursor, grant, member, opts \\ []) do
    project = Keyword.get(opts, :project, grant.payload["project_id"])

    req = %{
      method: method,
      path: path,
      scope: scope(w, project),
      cursor: cursor,
      timestamp_ms: Keyword.get(opts, :timestamp_ms, now()),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      authorization_event_id: grant.event_id,
      key_id: member.signer.key_id
    }

    sig = Base.url_encode64(Crypto.sign(Access.signing_bytes(req), member.seed), padding: false)

    ~s(CoopFeed grant="#{req.authorization_event_id}", key="#{req.key_id}", ) <>
      ~s(ts="#{req.timestamp_ms}", nonce="#{req.nonce}", sig="#{sig}")
  end

  # A signed GET of the feed at `cursor`, sent as Last-Event-ID when nonzero.
  defp signed_get(w, cursor, grant, member) do
    path = feed_path(w, grant.payload["project_id"])
    header = signature(w, "GET", path, cursor, grant, member)
    resume = if cursor > 0, do: [{"last-event-id", "#{cursor}"}], else: []
    {path, [{"authorization", header} | resume]}
  end

  # -- refusals -----------------------------------------------------------------------

  describe "refused" do
    test "without credentials", w do
      conn = call(:get, feed_path(w), [])

      assert conn.status == 401
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["CoopFeed"]
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end

    test "with a malformed or forged signature", w do
      good = signature(w, "GET", feed_path(w), 0, w.op_grant, w.op)
      forged = signature(w, "GET", feed_path(w), 0, w.op_grant, w.agent)

      for header <- [
            "CoopFeed nonsense",
            "Bearer x",
            String.replace(good, ~s(sig="), ~s(sig="A)),
            forged
          ] do
        assert call(:get, feed_path(w), [{"authorization", header}]).status == 401
      end
    end

    test "for another project than the grant's", w do
      path = feed_path(w, "project-2")
      header = signature(w, "GET", path, 0, w.agent_grant, w.agent, project: "project-2")

      assert call(:get, path, [{"authorization", header}]).status == 401
    end

    test "when the signature names another path or cursor", w do
      other = signature(w, "GET", feed_path(w) <> "x", 0, w.op_grant, w.op)
      assert call(:get, feed_path(w), [{"authorization", other}]).status == 401

      cursor = signature(w, "GET", feed_path(w), 5, w.op_grant, w.op)
      assert call(:get, feed_path(w), [{"authorization", cursor}]).status == 401
    end

    test "when stale or replayed", w do
      stale = signature(w, "GET", feed_path(w), 0, w.op_grant, w.op, timestamp_ms: now() - 61_000)
      assert call(:get, feed_path(w), [{"authorization", stale}]).status == 401

      # Past the head, so the first use is answered without opening a stream.
      {path, headers} = signed_get(w, Log.head().global_seq + 1, w.op_grant, w.op)
      assert call(:get, path, headers).status == 409
      assert call(:get, path, headers).status == 401
    end

    test "once the grant is revoked", w do
      revoke!(w, "TaskOperatorRevokedV1", w.op_grant)
      {path, headers} = signed_get(w, 0, w.op_grant, w.op)

      assert call(:get, path, headers).status == 401
    end

    test "a bad cursor is a bad request; one past the head must start over", w do
      assert call(:get, feed_path(w), [{"last-event-id", "x"}]).status == 400
      assert call(:get, feed_path(w) <> "?cursor=-1", []).status == 400

      {path, headers} = signed_get(w, Log.head().global_seq + 1, w.op_grant, w.op)
      conn = call(:get, path, headers)
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "cursor_ahead"}
    end
  end

  # -- live streams ----------------------------------------------------------------------

  describe "a live stream" do
    setup do
      %{base: serve!()}
    end

    test "a reader sees the project, then its changes live", w do
      create!(w, w.op_grant, "task-1")
      resp = open(w, signed_get(w, 0, w.agent_grant, w.agent))

      assert resp.status == 200
      assert Req.Response.get_header(resp, "content-type") == ["text/event-stream"]
      assert tasks(next(resp)) == ["task-1"]

      env = create!(w, w.op_grant, "task-2")
      assert {seq, _} = frame = next(resp)
      assert {seq, tasks(frame)} == {env.global_seq, ["task-2"]}
    end

    test "it ends when the reader's grant is revoked", w do
      resp = open(w, signed_get(w, 0, w.op_grant, w.op))
      _snapshot = next(resp)

      revoke!(w, "TaskOperatorRevokedV1", w.op_grant)
      assert next(resp) == :done
    end

    test "another project's changes never reach it", w do
      resp = open(w, signed_get(w, 0, w.op_grant_2, w.op))

      assert {_seq, %{"changes" => []}} = next(resp)

      create!(w, w.op_grant, "task-1", "project-1")
      env = create!(w, w.op_grant_2, "task-9", "project-2")

      assert {seq, _} = frame = next(resp)
      assert {seq, tasks(frame)} == {env.global_seq, ["task-9"]}
    end

    test "a reconnect resumes from Last-Event-ID without gaps or repeats", w do
      create!(w, w.op_grant, "task-1")

      first = open(w, signed_get(w, 0, w.op_grant, w.op))
      {seq, _} = next(first)
      Req.cancel_async_response(first)

      create!(w, w.op_grant, "task-2")
      create!(w, w.op_grant, "task-3")

      again = open(w, signed_get(w, seq, w.op_grant, w.op))
      assert tasks(next(again)) == ["task-2", "task-3"]
    end
  end
end
