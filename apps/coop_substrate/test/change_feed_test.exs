defmodule CoopSubstrate.ChangeFeedTest do
  @moduledoc """
  `CoopSubstrate.Feed` against the real appender. The subscribe/catch-up race
  itself is model-checked in spec/change_feed.qnt; these tests pin the
  behaviours that model relies on: register before reading, drop what was
  already delivered, backfill gaps from the store, catch up on a tick.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.Feed
  alias CoopSubstrate.Feed.SSE
  alias CoopSubstrate.Log

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  setup do
    gov = new_member("governance")
    op = new_member("operator")
    grant = operator_grant(gov, op, "alice")
    {:ok, _} = Log.append([declare_governance(gov), grant])
    %{op: op, grant: grant}
  end

  defp append!(env) do
    {:ok, [appended]} = Log.append(env)
    appended
  end

  defp create!(w, task_id, timing \\ unscheduled()),
    do: append!(create(w.op, w.grant, task_id, timing))

  defp notified do
    assert_receive {:coop_ledger, envelopes}
    envelopes
  end

  defp task_ids(%{changes: changes}),
    do: for(%{kind: :tasks, id: id} <- changes, do: id)

  test "opening at 0 sends the project as one frame at the head", w do
    create!(w, "task-1")
    create!(w, "task-2")

    {:ok, session, frame} = Feed.open(@scope, 0)

    assert frame.seq == Log.head().global_seq
    assert Enum.sort(task_ids(frame)) == ["task-1", "task-2"]
    assert Feed.seq(session) == frame.seq
  end

  test "an append reaches an open subscriber as a frame", w do
    {:ok, session, _frame} = Feed.open(@scope, 0)
    env = create!(w, "task-1", timed(1_792_396_800_000))

    {frame, session} = Feed.advance(session, notified())

    assert frame.seq == env.global_seq
    assert [%{kind: :tasks, id: "task-1", value: task}] = frame.changes
    assert task.timing == timed(1_792_396_800_000)
    assert task.state == "inbox"
    assert Feed.seq(session) == env.global_seq
  end

  test "resuming from a cursor sends only what changed after it", w do
    first = create!(w, "task-1")
    create!(w, "task-2")

    {:ok, _session, frame} = Feed.open(@scope, first.global_seq)

    assert task_ids(frame) == ["task-2"]
  end

  test "events already delivered produce no frame", w do
    env = create!(w, "task-1")
    {:ok, session, _frame} = Feed.open(@scope, 0)

    # An append between registering and reading is both read and notified.
    assert {nil, ^session} = Feed.advance(session, [env])
  end

  test "a gap in notifications is backfilled from the store", w do
    {:ok, session, _frame} = Feed.open(@scope, 0)
    create!(w, "task-1")
    _lost = notified()
    create!(w, "task-2")

    {frame, session} = Feed.advance(session, notified())

    assert Enum.sort(task_ids(frame)) == ["task-1", "task-2"]
    assert Feed.seq(session) == Log.head().global_seq
  end

  test "a tick catches up when the last notification was lost", w do
    {:ok, session, _frame} = Feed.open(@scope, 0)
    create!(w, "task-1")
    _lost = notified()

    {frame, session} = Feed.tick(session)
    assert task_ids(frame) == ["task-1"]
    assert {nil, ^session} = Feed.tick(session)
  end

  test "another project's events advance the cursor without a frame", w do
    {:ok, session, _frame} = Feed.open({"chapter-genesis", "tenant-1", "project-2"}, 0)
    env = create!(w, "task-1")

    {frame, session} = Feed.advance(session, notified())

    assert frame == nil
    assert Feed.seq(session) == env.global_seq
  end

  test "a cursor beyond the head is refused" do
    assert {:error, :cursor_ahead} = Feed.open(@scope, Log.head().global_seq + 1)
    assert {:error, :invalid_cursor} = Feed.open(@scope, -1)
  end

  test "closing stops notifications", w do
    {:ok, session, _frame} = Feed.open(@scope, 0)
    :ok = Feed.close(session)
    create!(w, "task-1")
    refute_receive {:coop_ledger, _}
  end

  describe "SSE" do
    test "a frame is one event whose id is its cursor", w do
      env = create!(w, "task-1")
      {:ok, _session, frame} = Feed.open(@scope, 0)

      seq = env.global_seq
      head = "id: #{seq}\nevent: changes\ndata: "
      assert ^head <> data = IO.iodata_to_binary(SSE.frame(frame))
      assert String.ends_with?(data, "\n\n")

      assert %{"seq" => ^seq, "changes" => [%{"kind" => "tasks", "id" => "task-1"}]} =
               Jason.decode!(data)
    end

    test "Last-Event-ID resumes; anything else starts over or is refused" do
      assert SSE.cursor(nil) == {:ok, 0}
      assert SSE.cursor("42") == {:ok, 42}
      assert SSE.cursor("-1") == {:error, :invalid_cursor}
      assert SSE.cursor("4x") == {:error, :invalid_cursor}
    end

    test "a heartbeat is a comment, which EventSource ignores" do
      assert IO.iodata_to_binary(SSE.heartbeat()) == ": heartbeat\n\n"
    end
  end
end
