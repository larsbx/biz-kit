defmodule CoopSubstrate.ScfReplayCaptureTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{Log, ScfReplaySource}
  alias CoopSubstrate.Protocol.Envelope

  test "captures records actually admitted by the canonical log" do
    assert {:ok, %{head: %{sequence: 0}, rows: []}} = ScfReplaySource.capture(1)
    {:ok, [first]} = Log.append(signed_test_event(new_member(), note: "first"))
    {:ok, [second]} = Log.append(signed_test_event(new_member(), note: "second"))
    {:ok, first_hash} = Envelope.event_hash(first)
    {:ok, second_hash} = Envelope.event_hash(second)

    assert {:error, :capture_limit_exceeded} = ScfReplaySource.capture(1)

    assert {:ok,
            %{
              head: %{sequence: 2, digest: ^second_hash},
              rows: [
                %{ref: %{sequence: 1, digest: ^first_hash}, payload: %{"note" => "first"}},
                %{ref: %{sequence: 2, digest: ^second_hash}, payload: %{"note" => "second"}}
              ]
            }} = ScfReplaySource.capture(2)
  end
end
