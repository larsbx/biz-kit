defmodule CoopSubstrate.SignedConsumerSourceTest do
  @moduledoc """
  Verifies that the operational consumer source reads a REAL signed append
  through CoopSubstrate's canonical EventStore, not from notification claims.
  """
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.SignedConsumerSource, as: Source

  test "verifies canonical append and exposes only the captured signed prefix" do
    member = new_member()

    assert {:ok, 0} = Source.verified_head()
    assert {:ok, []} = Log.read_all()

    assert {:ok, [first]} = Log.append(signed_test_event(member, note: "first"))
    assert {:ok, 1} = Source.verified_head()

    assert {:ok, [read_first]} = Source.read_page(1, 1)
    assert read_first.event_id == first.event_id
    assert read_first.global_seq == 1

    assert {:ok, digest} = Source.event_digest(read_first)
    assert {:ok, ^digest} = Envelope.event_hash(first)

    assert {:ok, [second]} = Log.append(signed_test_event(member, note: "second"))
    assert second.global_seq == 2

    # A page bounded to head=1 cannot see a later appended event.
    assert {:ok, [only_first]} = Source.read_page(1, 1)
    assert only_first.event_id == first.event_id

    assert {:ok, 2} = Source.verified_head()
    assert {:ok, [_, latest]} = Source.read_page(1, 2)
    assert latest.event_id == second.event_id
  end

  test "refuses invalid page ranges and non-canonical envelope inputs" do
    assert {:error, :invalid_ledger_page} = Source.read_page(0, 1)
    assert {:error, :invalid_ledger_page} = Source.read_page(2, 1)
    assert {:error, :invalid_ledger_page} = Source.read_page(1, 102)
    assert {:error, :not_a_signed_ledger_envelope} = Source.event_digest(%{global_seq: 1})
  end
end
