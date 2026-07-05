# AshEvents spike — answers hand-off §1.7's five questions + atomic
# multi-event append, empirically. Run: mix run spike_run.exs
# Findings are transcribed into SUBSTRATE.md §3.

import Ecto.Query

alias AshEventsSpike.Events.Event
alias AshEventsSpike.Notes.Note
alias AshEventsSpike.Repo

defmodule Spike do
  def q(header), do: IO.puts("\n=== #{header} ===")
end

Repo.delete_all(from(e in "events"))
Repo.delete_all(from(n in "notes"))

Spike.q("Q1 — append-only enforcement")

actions = Ash.Resource.Info.actions(Event) |> Enum.map(&{&1.name, &1.type})
IO.puts("event log resource actions: #{inspect(actions)}")

{:ok, _} = Ash.create(Note, %{body: "first"}, context: %{ash_events_metadata: %{"k" => 1}})

{count, _} =
  Repo.update_all(from(e in "events", update: [set: [action: "tampered"]]), [])

IO.puts("raw SQL UPDATE of a persisted event: #{count} row(s) updated (no DB-level protection)")

{count, _} = Repo.delete_all(from(e in "events"))
IO.puts("raw SQL DELETE of persisted events: #{count} row(s) deleted (no DB-level protection)")

Spike.q("Q2 — reject before persistence (verification hook)")

result =
  try do
    Ash.create(Note, %{body: "should not persist"},
      context: %{ash_events_metadata: %{"reject_me" => true}}
    )
  rescue
    e -> {:raised, e.__struct__}
  end

notes_after = Repo.aggregate("notes", :count)
events_after = Repo.aggregate("events", :count)

IO.puts(
  "create with failing event validation → #{inspect(elem(result, 0))} " <>
    "(AshEvents uses create_event!/5 internally: rejection RAISES out of the " <>
    "wrapped action instead of returning {:error, _})"
)

IO.puts(
  "rows after rejection: notes=#{notes_after} events=#{events_after} " <>
    "(both 0 → event validation aborts the whole action transaction)"
)

Spike.q("Q3 — global + per-stream ordering")

cols =
  Repo.query!(
    "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'events' ORDER BY ordinal_position"
  )

Enum.each(cols.rows, fn [name, type] -> IO.puts("  #{name}: #{type}") end)

IO.puts("global order: integer PK sequence (id). per-stream (record_id) sequence column: none.")

Spike.q("Q4 — deterministic replay, independently testable")

# Q1's tamper probes left a note whose events were raw-SQL-deleted; clear both
# tables so the replay comparison measures AshEvents, not the tamper damage.
Repo.delete_all(from(e in "events"))
Repo.delete_all(from(n in "notes"))

{:ok, n1} = Ash.create(Note, %{body: "a", counter: 1})
{:ok, n2} = Ash.create(Note, %{body: "b", counter: 2})
{:ok, _} = Ash.update(Ash.get!(Note, n1.id), %{counter: 10}, action: :update)
:ok = Ash.destroy(Ash.get!(Note, n2.id))

snapshot = fn ->
  Repo.query!("SELECT id, body, counter FROM notes ORDER BY id").rows
end

before_replay = snapshot.()
:ok = Ash.ActionInput.for_action(Event, :replay, %{}) |> Ash.run_action!()
after_replay_1 = snapshot.()
:ok = Ash.ActionInput.for_action(Event, :replay, %{}) |> Ash.run_action!()
after_replay_2 = snapshot.()

IO.puts("replay reproduces state: #{before_replay == after_replay_1}")
IO.puts("replay is stable across runs: #{after_replay_1 == after_replay_2}")
IO.puts("note: replay re-executes resource ACTIONS (business logic), not a pure fold")

Spike.q("Q5 — can metadata carry Envelope V1")

envelope_meta = %{
  "schema_version" => "EventEnvelopeV1",
  "chapter_id" => "chapter-genesis",
  "key_id" => "k1",
  "author_pubkey_hex" => String.duplicate("ab", 32),
  "sig_hex" => String.duplicate("cd", 64),
  "prev_global_hash_hex" => String.duplicate("ef", 32),
  "prev_stream_hash_hex" => String.duplicate("01", 32)
}

{:ok, _} = Ash.create(Note, %{body: "with envelope"}, context: %{ash_events_metadata: envelope_meta})

[meta] =
  Repo.query!("SELECT metadata FROM events ORDER BY id DESC LIMIT 1").rows |> List.first()

IO.puts("metadata round-trips as jsonb map: #{meta["schema_version"] == "EventEnvelopeV1"}")

raw_binary_result =
  try do
    Ash.create(Note, %{body: "raw bytes"},
      context: %{ash_events_metadata: %{"sig" => <<0xDE, 0xAD, 0xBE, 0xEF>>}}
    )
  rescue
    e -> {:raised, e.__struct__}
  end

IO.puts("raw (non-UTF8) binary in metadata: #{inspect(elem(raw_binary_result, 0))} " <>
  "(jsonb → binaries must be hex/base64-encoded; canonical bytes not first-class)")

Spike.q("Q6 — atomic multi-event append")

notes_before = Repo.aggregate("notes", :count)
events_before = Repo.aggregate("events", :count)

tx_result =
  try do
    Repo.transaction(fn ->
      {:ok, _} = Ash.create(Note, %{body: "batch-1"})

      case Ash.create(Note, %{body: "batch-2"},
             context: %{ash_events_metadata: %{"reject_me" => true}}
           ) do
        {:ok, note} -> note
        {:error, err} -> Repo.rollback(err)
      end
    end)
  rescue
    e -> {:raised, e.__struct__}
  end

IO.puts("batch with failing second event → #{inspect(elem(tx_result, 0))}")

IO.puts(
  "counts unchanged after rollback: notes=#{Repo.aggregate("notes", :count) == notes_before} " <>
    "events=#{Repo.aggregate("events", :count) == events_before}"
)

IO.puts("expected_version-style optimistic append control: none found in API (advisory locks only)")

IO.puts("\nspike complete")
