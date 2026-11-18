defmodule CoopSubstrate.ScfReplaySourceTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.{Crypto, ScfReplaySource}
  alias CoopSubstrate.Protocol.Envelope

  test "captures exact recorded references across pages and excludes later appends" do
    events = signed_invoices(102)
    prefix = Enum.take(events, 101)
    head = head(List.last(prefix))

    assert {:ok, %{head: %{sequence: 101}, rows: rows}} =
             ScfReplaySource.read_prefix(head, page_reader(events))

    assert Enum.map(rows, & &1.ref.sequence) == Enum.to_list(1..101)
    event = List.last(prefix)

    assert List.last(rows) == %{
             ref: %{
               sequence: 101,
               digest: head.global_hash,
               event_id: event.event_id,
               chapter: event.chapter_id,
               stream_id: event.stream_id,
               stream_sequence: event.stream_seq,
               type: "InvoiceIssued"
             },
             payload: event.payload
           }

    assert_received {:page, 1, 100}
    assert_received {:page, 101, 101}
    refute_received {:page, _, _}
  end

  test "fails closed on a truncated, reordered, duplicated or oversized page" do
    [first, second] = signed_invoices(2)
    head = head(second)

    for page <- [[first], [second, first], [first, first], [first, second, second]] do
      assert {:error, :invalid_ledger_page} =
               ScfReplaySource.read_prefix(head, fn _, _ -> {:ok, page} end)
    end
  end

  test "rejects chain changes and an otherwise well-formed replacement at the captured head" do
    [first, second] = signed_invoices(2)
    [_, replacement] = signed_invoices(2)

    assert {:error, :invalid_ledger_page} =
             ScfReplaySource.read_prefix(head(second), page_reader([first, replacement]))

    replacement = %{replacement | prev_global_hash: head(first).global_hash}

    assert {:error, :ledger_head_mismatch} =
             ScfReplaySource.read_prefix(head(second), page_reader([first, replacement]))
  end

  test "an empty head reads no pages and invalid limits fail before accessing the log" do
    assert {:ok, %{head: %{sequence: 0, digest: nil}, rows: []}} =
             ScfReplaySource.read_prefix(%{global_seq: 0, global_hash: nil}, fn _, _ ->
               flunk("empty head must not request a page")
             end)

    for limit <- [0, 10_001, "100"] do
      assert {:error, :invalid_capture_limit} = ScfReplaySource.capture(limit)
    end
  end

  defp page_reader(events) do
    fn first, last ->
      send(self(), {:page, first, last})
      {:ok, Enum.slice(events, first - 1, last - first + 1)}
    end
  end

  defp head(event) do
    {:ok, digest} = Envelope.event_hash(event)
    %{global_seq: event.global_seq, global_hash: digest}
  end

  defp signed_invoices(count) do
    {pubkey, seed} = Crypto.generate_keypair()
    signer = %{role: "steward", key_id: "fixture-steward", pubkey: pubkey}

    {events, _} =
      Enum.map_reduce(1..count, nil, fn seq, previous ->
        {:ok, event} =
          Envelope.new(%{
            chapter_id: "scf-replay-fixture",
            type: "InvoiceIssued",
            payload: %{
              "invoice_id" => "invoice-#{seq}",
              "load_id" => "load-#{seq}",
              "member_id" => "fixture-member",
              "entity_id" => "fixture-entity",
              "terms_version" => 1,
              "lines" => [],
              "amount_minor" => 125
            },
            signers: [signer],
            timestamp_ms: 1_789_000_000_000
          })

        {:ok, event} = Envelope.sign(event, signer.key_id, seed)
        assert :ok = Envelope.verify(event)
        {:ok, stream_id} = Envelope.stream_id(event)

        recorded =
          Envelope.with_log_assignment(event, %{
            stream_id: stream_id,
            stream_seq: seq,
            global_seq: seq,
            prev_stream_hash: previous,
            prev_global_hash: previous
          })

        {recorded, head(recorded).global_hash}
      end)

    events
  end
end
