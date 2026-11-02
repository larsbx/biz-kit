# Run inside the restaurant release (scripts/restaurant-release-smoke.sh): a
# throwaway governance key declares itself in the smoke's fresh chapter and
# grants the configured devices (signing in-process, which only a smoke may); a pickup order is then placed by the
# storefront device and walked to completion by the board, every step admitted
# by the release's own ledger.
alias CoopSubstrate.{Crypto, Log, ULID}
alias CoopSubstrate.Protocol.Envelope
alias RestaurantHost.{DeviceGrants, Orders, Restaurant}

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

# The grants `mix restaurant.grant` would ask the administrator to sign.
for device <- ["storefront", "board-1"] do
  {:ok, d} = DeviceGrants.details(r, device)
  append.(d.type, d.payload)
end

{:ok, id} = Orders.place(r, %{"margherita" => 2}, "Smoke", ULID.generate())

for {action, version} <- Enum.with_index([:accept, :start_preparing, :mark_ready, :complete]),
    do: :ok = Orders.step(r, "board-1", id, action, version)

%{state: :completed, version: 4, total: 2706} = Orders.get(r, id)
IO.puts("SMOKE OK #{id}")
