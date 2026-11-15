defmodule ProcurementHost.ReleaseTasks do
  @moduledoc "Explicit migration and offline governance enrollment; no second application database."
  alias CoopSubstrate.{Crypto, Log, Procurement}
  alias CoopSubstrate.Protocol.Envelope
  def migrate, do: CoopSubstrate.ReleaseTasks.init_event_stores()

  @doc "Apply an explicitly prepared grant/enrollment file. Never bootstraps governance or starts HTTP."
  def enroll(path) do
    {:ok, _} = Application.ensure_all_started(:commerce_core)
    {:ok, _} = Application.ensure_all_started(:coop_substrate)
    %{"type" => type, "chapter_id" => chapter, "payload" => payload} = path |> File.read!() |> Jason.decode!()
    unless type in ["ProcurementOperatorGrantedV1", "ProcurementBusinessEnrolledV1", "ProcurementDispatchRouteV1"],
      do: raise("not a procurement authority event")
    seed = Base.decode16!(System.fetch_env!("PROCUREMENT_GOVERNANCE_SEED_HEX"), case: :mixed)
    key = System.fetch_env!("PROCUREMENT_GOVERNANCE_KEY_ID")
    payload = case Map.pop(payload, "pubkey_hex") do
      {nil, payload} -> payload
      {hex, payload} -> Map.put(payload, "pubkey", {:bytes, Base.decode16!(hex, case: :mixed)})
    end
    {:ok, env} = Envelope.new(type: type, chapter_id: chapter, payload: payload,
      timestamp_ms: div(Procurement.clock_ms(), 1_000) * 1_000,
      signers: [%{role: "governance", key_id: key, pubkey: Crypto.pubkey_from_seed(seed)}])
    {:ok, signed} = Envelope.sign(env, key, seed)
    {:ok, [accepted]} = Log.append(signed)
    %{event_id: accepted.event_id, global_seq: accepted.global_seq}
  end
end
