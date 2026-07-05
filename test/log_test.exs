defmodule CoopSubstrate.LogTest do
  @moduledoc """
  Phase 1A acceptance for the append-only canonical log (hand-off §6 [1A]
  items 4–6, partially 7): verify-on-append rejections, dual-chain
  assignment, batch atomicity, tamper detection in BOTH chains, as-of
  reads, restart recovery, link repair, and signed stream export.
  """

  use CoopSubstrate.LogCase, async: false
  use ExUnitProperties

  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  describe "append/1" do
    test "assigns both chains, starting at the genesis of log and stream" do
      member = new_member()

      {:ok, [appended]} = Log.append(signed_test_event(member))

      assert appended.global_seq == 1
      assert appended.stream_seq == 1
      assert appended.stream_id == "chapter-genesis/test"
      assert appended.prev_global_hash == nil
      assert appended.prev_stream_hash == nil

      {:ok, hash} = Envelope.event_hash(appended)
      assert Log.head() == %{global_seq: 1, global_hash: hash}
    end

    test "chains successive events globally and per stream independently" do
      member = new_member()

      {:ok, [first]} = Log.append(signed_test_event(member, note: "a"))
      {:ok, [second]} = Log.append(signed_test_event(member, note: "b"))
      {:ok, [other_chapter]} = Log.append(signed_test_event(member, chapter_id: "chapter-two"))

      {:ok, first_hash} = Envelope.event_hash(first)
      {:ok, second_hash} = Envelope.event_hash(second)

      # Global chain covers everything, in order.
      assert second.prev_global_hash == first_hash
      assert other_chapter.prev_global_hash == second_hash
      assert other_chapter.global_seq == 3

      # Stream chains are per stream: same stream links, a new stream restarts.
      assert second.stream_seq == 2
      assert second.prev_stream_hash == first_hash
      assert other_chapter.stream_id == "chapter-two/test"
      assert other_chapter.stream_seq == 1
      assert other_chapter.prev_stream_hash == nil
    end

    test "rejects an envelope with a missing signature; nothing persists" do
      member = new_member()

      {:ok, unsigned} =
        Envelope.new(%{
          chapter_id: "chapter-genesis",
          type: "TestProjectionEvent",
          payload: %{"note" => "unsigned", "amount_minor" => 1},
          signers: [member.signer],
          timestamp_ms: System.system_time(:millisecond)
        })

      assert {:error, {:reject, 0, {:missing_signature, _}}} = Log.append(unsigned)
      assert Log.head().global_seq == 0
      assert Log.read_all() == {:ok, []}
    end

    test "rejects a forged signature before persistence" do
      member = new_member()
      signed = signed_test_event(member)
      forged = %{signed | sigs: %{member.signer.key_id => :crypto.strong_rand_bytes(64)}}

      assert {:error, {:reject, 0, {:invalid_signature, _}}} = Log.append(forged)
      assert Log.head().global_seq == 0
    end

    test "rejects unregistered types and invalid payloads (struct built by hand)" do
      member = new_member()
      signed = signed_test_event(member)

      assert {:error, {:reject, 0, :unknown_type}} = Log.append(%{signed | type: "NotAType"})

      assert {:error, {:reject, 0, {:payload_invalid, _}}} =
               Log.append(%{signed | payload: %{"wrong" => "fields"}})
    end

    test "rejects an already-appended envelope" do
      member = new_member()
      {:ok, [appended]} = Log.append(signed_test_event(member))

      assert {:error, {:already_appended, 0, _}} = Log.append(appended)
    end

    test "the store rejects re-appending the same event_id (uuid conflict)" do
      member = new_member()
      signed = signed_test_event(member)

      {:ok, _} = Log.append(signed)
      assert {:error, {:store_append_failed, _}} = Log.append(signed)
      assert Log.head().global_seq == 1
    end

    test "a batch is atomic: one bad envelope rejects the whole batch" do
      member = new_member()
      good = signed_test_event(member, note: "good")
      bad = %{signed_test_event(member, note: "bad") | sigs: %{}}

      assert {:error, {:reject, 1, {:missing_signature, _}}} = Log.append([good, bad])
      assert Log.head().global_seq == 0
      assert Log.read_all() == {:ok, []}
    end

    test "a multi-stream batch appends atomically with contiguous sequences" do
      member = new_member()

      batch = [
        signed_test_event(member, note: "one"),
        signed_test_event(member, chapter_id: "chapter-two"),
        signed_test_event(member, note: "two")
      ]

      {:ok, [a, b, c]} = Log.append(batch)

      assert {a.global_seq, b.global_seq, c.global_seq} == {1, 2, 3}
      assert {a.stream_seq, b.stream_seq, c.stream_seq} == {1, 1, 2}
      {:ok, a_hash} = Envelope.event_hash(a)
      assert c.prev_stream_hash == a_hash

      {:ok, genesis_stream} = Log.read_stream("chapter-genesis/test")
      {:ok, two_stream} = Log.read_stream("chapter-two/test")
      assert Enum.map(genesis_stream, & &1.global_seq) == [1, 3]
      assert Enum.map(two_stream, & &1.global_seq) == [2]
    end
  end

  describe "reads" do
    test "read_all returns global order; as_of truncates" do
      member = new_member()
      for note <- ~w(a b c), do: {:ok, _} = Log.append(signed_test_event(member, note: note))

      {:ok, all} = Log.read_all()
      assert Enum.map(all, &(&1.payload["note"])) == ~w(a b c)

      {:ok, as_of} = Log.read_all(as_of: 2)
      assert Enum.map(as_of, &(&1.payload["note"])) == ~w(a b)
    end

    test "read_stream supports as_of on global_seq" do
      member = new_member()
      {:ok, _} = Log.append(signed_test_event(member, note: "a"))
      {:ok, _} = Log.append(signed_test_event(member, chapter_id: "chapter-two"))
      {:ok, _} = Log.append(signed_test_event(member, note: "b"))

      {:ok, stream} = Log.read_stream("chapter-genesis/test", as_of: 2)
      assert Enum.map(stream, &(&1.payload["note"])) == ~w(a)
    end

    test "reading an unknown stream returns empty" do
      assert Log.read_stream("chapter-genesis/nothing") == {:ok, []}
    end
  end

  describe "tamper evidence (hand-off §6 [1A] item 4)" do
    setup do
      member = new_member()
      for note <- ~w(a b c), do: {:ok, _} = Log.append(signed_test_event(member, note: note))
      %{member: member}
    end

    test "raw SQL UPDATE is blocked by the store's trigger" do
      {:ok, conn} = raw_conn()

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               Postgrex.query(conn, "UPDATE events SET event_type = 'Forged'", [])

      assert message =~ "Cannot update events"
      GenServer.stop(conn)
    end

    test "raw SQL DELETE is blocked by the store's trigger" do
      {:ok, conn} = raw_conn()

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               Postgrex.query(conn, "DELETE FROM events", [])

      assert message =~ "Cannot delete events"
      GenServer.stop(conn)
    end

    test "a superuser who forges event bytes is caught by BOTH chains", %{member: member} do
      # Forge: replace event 2's stored bytes with a re-signed variant.
      forged = signed_test_event(member, note: "forged")

      {:ok, [forged_assigned]} =
        {:ok,
         [
           Envelope.with_log_assignment(forged, %{
             stream_id: "chapter-genesis/test",
             stream_seq: 2,
             global_seq: 2,
             prev_stream_hash: :crypto.strong_rand_bytes(32),
             prev_global_hash: :crypto.strong_rand_bytes(32)
           })
         ]}

      {:ok, bytes} = CoopSubstrate.Canonical.encode(Envelope.full_record_term(forged_assigned))

      with_update_bypass(fn conn ->
        %{num_rows: 1} =
          Postgrex.query!(
            conn,
            "UPDATE events SET data = $1 WHERE event_id IN
               (SELECT event_id FROM stream_events
                 WHERE stream_id = (SELECT stream_id FROM streams WHERE stream_uuid = 'ledger')
                   AND stream_version = 2)",
            [bytes]
          )
      end)

      assert {:error, breaks} = Log.verify_chains()

      reasons = Enum.flat_map(breaks, fn {:break, _seq, reasons} -> reasons end)
      # BOTH chains must independently catch the forgery.
      assert :global_chain_break in reasons
      assert :stream_chain_break in reasons
    end

    test "a superuser who deletes an event is caught" do
      with_delete_bypass(fn conn ->
        Postgrex.query!(
          conn,
          "DELETE FROM stream_events WHERE event_id IN
             (SELECT event_id FROM stream_events
               WHERE stream_id = (SELECT stream_id FROM streams WHERE stream_uuid = 'ledger')
                 AND stream_version = 2)",
          []
        )
      end)

      assert {:error, breaks} = Log.verify_chains()

      reasons = Enum.flat_map(breaks, fn {:break, _seq, reasons} -> reasons end)
      assert Enum.any?(reasons, &match?({:global_seq_mismatch, _}, &1)) or
               :global_chain_break in reasons
    end

    test "an untampered log verifies clean" do
      assert Log.verify_chains() == :ok
    end
  end

  # Acceptance §6 [1A] item 4, property form: ANY single-byte corruption of
  # any stored record is detected, and untampered logs never false-positive.
  # DB-bound, so runs are few; the example-based tests above cover the
  # adversarial (validly re-signed) forgery in depth.
  property "any byte-level tamper of any event is detected; clean logs verify" do
    check all(
            event_count <- StreamData.integer(2..4),
            victim <- StreamData.integer(1..2),
            seed <- StreamData.integer(0..10_000),
            max_runs: 8
          ) do
      victim = min(victim, event_count)
      reset_log(nil)

      member = new_member()

      for n <- 1..event_count do
        {:ok, _} = Log.append(signed_test_event(member, note: "event-#{n}"))
      end

      assert Log.verify_chains() == :ok

      {:ok, conn} = raw_conn()

      %{rows: [[bytes]]} =
        Postgrex.query!(
          conn,
          "SELECT data FROM events e JOIN stream_events se ON se.event_id = e.event_id
            WHERE se.stream_id = (SELECT stream_id FROM streams WHERE stream_uuid = 'ledger')
              AND se.stream_version = $1",
          [victim]
        )

      position = rem(seed, byte_size(bytes))
      <<head::binary-size(position), byte, tail::binary>> = bytes
      corrupted = <<head::binary, Bitwise.bxor(byte, 0x01), tail::binary>>

      with_update_bypass(fn tamper_conn ->
        Postgrex.query!(
          tamper_conn,
          "UPDATE events SET data = $1 WHERE event_id IN
             (SELECT event_id FROM stream_events
               WHERE stream_id = (SELECT stream_id FROM streams WHERE stream_uuid = 'ledger')
                 AND stream_version = $2)",
          [corrupted, victim]
        )
      end)

      GenServer.stop(conn)

      assert {:error, breaks} = Log.verify_chains()
      assert Enum.any?(breaks, fn {:break, seq, _reasons} -> seq >= victim end)
    end
  end

  describe "restart recovery" do
    test "heads are rebuilt from the ledger and the chain continues unbroken" do
      member = new_member()
      {:ok, _} = Log.append(signed_test_event(member, note: "before"))
      head_before = Log.head()

      restart_log()

      assert Log.head() == head_before

      {:ok, [after_restart]} = Log.append(signed_test_event(member, note: "after"))
      assert after_restart.global_seq == 2
      assert after_restart.prev_global_hash == head_before.global_hash
      assert Log.verify_chains() == :ok
    end

    test "missing per-stream links are repaired on restart" do
      member = new_member()
      {:ok, _} = Log.append(signed_test_event(member, note: "a"))
      {:ok, _} = Log.append(signed_test_event(member, note: "b"))

      # Simulate a crash between append and link: drop the link rows.
      with_delete_bypass(fn conn ->
        Postgrex.query!(
          conn,
          "DELETE FROM stream_events
            WHERE stream_id = (SELECT stream_id FROM streams
                                WHERE stream_uuid = 'chapter-genesis/test')",
          []
        )

        Postgrex.query!(
          conn,
          "UPDATE streams SET stream_version = 0
            WHERE stream_uuid = 'chapter-genesis/test'",
          []
        )
      end)

      assert {:ok, []} = Log.read_stream("chapter-genesis/test")

      restart_log()

      {:ok, stream} = Log.read_stream("chapter-genesis/test")
      assert Enum.map(stream, &(&1.payload["note"])) == ~w(a b)
    end
  end

  describe "signed stream export (08 §1, minimal)" do
    test "export round-trips through independent verification" do
      member = new_member()
      {:ok, _} = Log.append(signed_test_event(member, note: "a"))
      {:ok, _} = Log.append(signed_test_event(member, note: "b"))

      {:ok, records} = Log.export_stream("chapter-genesis/test")
      assert length(records) == 2
      assert Enum.all?(records, &is_binary/1)

      {:ok, envelopes} = Log.verify_export(records)
      assert Enum.map(envelopes, &(&1.payload["note"])) == ~w(a b)
    end

    test "a tampered export fails verification" do
      member = new_member()
      {:ok, _} = Log.append(signed_test_event(member, note: "a"))
      {:ok, _} = Log.append(signed_test_event(member, note: "b"))

      {:ok, [first, _second]} = Log.export_stream("chapter-genesis/test")

      # Drop a record: the stream chain has a gap.
      {:ok, [_, second_env]} = Log.read_stream("chapter-genesis/test")
      {:ok, second_bytes} = CoopSubstrate.Canonical.encode(Envelope.full_record_term(second_env))
      assert {:error, {:export_invalid, 1, _}} = Log.verify_export([second_bytes])

      # Flip a byte: the record no longer decodes canonically/verifies.
      <<head::binary-size(10), byte, tail::binary>> = first
      corrupted = <<head::binary, Bitwise.bxor(byte, 1), tail::binary>>
      assert {:error, {:export_invalid, 1, _}} = Log.verify_export([corrupted, second_bytes])
    end
  end
end
