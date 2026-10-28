defmodule CoopSubstrate.AgentEventEffectsTest do
  use ExUnit.Case, async: true
  import CoopSubstrate.LogCase, only: [new_member: 1, signed_event: 3]
  alias CoopSubstrate.AgentEventEffects, as: Effects
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}

  defp assigned(env, seq, previous) do
    {:ok, stream} = Envelope.stream_id(env)

    Envelope.with_log_assignment(env, %{
      global_seq: seq,
      prev_global_hash: previous,
      stream_id: stream,
      stream_seq: 1,
      prev_stream_hash: nil
    })
  end

  test "known signed scope events derive stable discovery identity without execution data" do
    env =
      signed_event(new_member("governance"), "TaskOperatorGrantedV1", %{
        "tenant_id" => "tenant",
        "project_id" => "project",
        "principal_id" => "operator",
        "key_id" => "key",
        "pubkey" => {:bytes, <<1::256>>}
      })
      |> assigned(1, nil)

    assert {:ok, bundle} = Effects.derive(env, TypeRegistry.types())
    assert bundle.effect_id == "agent-event:" <> env.event_id
    assert bundle.tenant_id == "tenant"
    assert bundle.project_id == "project"
    refute Map.has_key?(bundle, :payload)
    refute Map.has_key?(bundle, :execution)
    assert Effects.derive(env, TypeRegistry.types()) == {:ok, bundle}
    assert {:error, :unknown_event_type} = Effects.derive(env, [])

    assert {:error, :uncommitted_event} =
             Effects.derive(%{env | global_seq: nil}, TypeRegistry.types())

    assert {:error, _} = Effects.derive(%{env | sigs: %{}}, TypeRegistry.types())
    assert {:error, :invalid_event} = Effects.derive(%{global_seq: 1}, TypeRegistry.types())
  end

  test "a zero-effect event still has a hash-bound processed receipt" do
    env =
      signed_event(new_member("author"), "TestProjectionEvent", %{
        "note" => "inert",
        "amount_minor" => 0
      })
      |> assigned(1, nil)

    assert {:ok, %{effect_id: nil, chapter_id: nil, tenant_id: nil, project_id: nil, hash: hash}} =
             Effects.derive(env, TypeRegistry.types())

    assert byte_size(hash) == 32
  end
end
