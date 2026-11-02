# Run inside the restaurant release (scripts/restaurant-release-smoke.sh): a
# throwaway governance key declares itself in the smoke's fresh chapter and
# grants the configured devices; a pickup order is then placed by the
# storefront device and walked to completion by the board, every step admitted
# by the release's own ledger.
alias CoopSubstrate.{Crypto, Log, ULID}
alias CoopSubstrate.Protocol.Envelope
alias RestaurantHost.{Orders, Restaurant}

r = Restaurant.current()
{pubkey, seed} = Crypto.generate_keypair()
gov = %{role: "governance", key_id: "k-smoke-governance", pubkey: pubkey}

append = fn type, payload ->
  {:ok, env} =
    Envelope.new(%{
      event_id: ULID.generate(),
      chapter_id: r.chapter,
      type: type,
      payload: payload,
      signers: [gov],
      auth_ref: nil,
      timestamp_ms: System.system_time(:millisecond)
    })

  {:ok, signed} = Envelope.sign(env, gov.key_id, seed)
  {:ok, _} = Log.append(signed)
end

append.("RoleKeyDeclared", %{
  "role" => "governance",
  "key_id" => gov.key_id,
  "pubkey" => {:bytes, pubkey}
})

for {device, actor, actions} <- [
      {r.storefront, "system", ["checkout"]},
      {r.boards["board-1"], "staff", ~w(accept start_preparing mark_ready complete cancel)}
    ] do
  append.("RestaurantDeviceGrantedV1", %{
    "merchant_id" => r.merchant,
    "device_id" => device.device_id,
    "key_id" => device.signer.key_id,
    "pubkey" => {:bytes, device.signer.pubkey},
    "actor" => actor,
    "actions" => actions
  })
end

{:ok, id} = Orders.place(r, %{"margherita" => 2}, "Smoke", ULID.generate())

for {action, version} <- Enum.with_index([:accept, :start_preparing, :mark_ready, :complete]),
    do: :ok = Orders.step(r, "board-1", id, action, version)

%{state: :completed, version: 4, total: 2706} = Orders.get(r, id)
IO.puts("SMOKE OK #{id}")
