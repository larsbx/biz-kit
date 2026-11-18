# Runs in a separate, non-started release VM on the operator side.
alias CoopSubstrate.ULID
alias CoopSubstrate.Harness.Ops
alias CoopSubstrate.Protocol.Envelope

nil = Process.whereis(CoopSubstrate.Log)
{:ok, _} = Ops.gen_key("governance")
{:ok, gov} = Ops.load_signer("governance")
config = System.fetch_env!("RESTAURANT_CONFIG_FILE") |> File.read!() |> Jason.decode!()

{:ok, env} =
  Envelope.new(%{
    event_id: ULID.generate(),
    chapter_id: config["chapter"],
    type: "RoleKeyDeclared",
    payload: %{"role" => "governance", "key_id" => gov.key_id, "pubkey" => {:bytes, gov.pubkey}},
    signers: [%{role: "governance", key_id: gov.key_id, pubkey: gov.pubkey}],
    timestamp_ms: System.system_time(:millisecond)
  })

{:ok, signed} = Envelope.sign(env, gov.key_id, gov.seed)
File.write!(System.fetch_env!("RESTAURANT_SMOKE_BOOTSTRAP"), :erlang.term_to_binary(signed))
