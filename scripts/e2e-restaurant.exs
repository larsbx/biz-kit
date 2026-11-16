# The rebuilt eatsbot in the end-to-end stack (scripts/e2e-stack.sh), which
# replaced the legacy apps/eatsbot (docs/architecture/2026-11-16-eatsbot-r0-inventory.md).
#
#   mix run --no-start scripts/e2e-restaurant.exs STATE_DIR
#
# Run after the stack recreates the ledger. Every start gets fresh keys:
#   * a governance key in STATE_DIR/keys (HARNESS_KEYS_DIR, 0600), declared on
#     the ledger; it never enters the server's environment;
#   * a storefront and a kitchen board key, granted by that governance key with
#     exactly the grants `mix restaurant.grant` signs (RestaurantHost.DeviceGrants);
#   * STATE_DIR/restaurant.json, the restaurant file, and STATE_DIR/restaurant.env,
#     the device seeds the server alone reads;
#   * STATE_DIR/restaurant-stack.json: where the storefront is and how to pair
#     the board, for the people and tests using the stack.
#
# Every fact is signed and admitted by the ledger's own appender, as in the
# release smoke; only the operator's HTTP round trip is skipped.

[state] = System.argv()
state = Path.expand(state)
keys = Path.join(state, "keys")
File.mkdir_p!(keys)
File.chmod!(keys, 0o700)
System.put_env("HARNESS_KEYS_DIR", keys)

alias CoopSubstrate.{Crypto, Log, ULID}
alias CoopSubstrate.Harness.Ops
alias CoopSubstrate.Protocol.Envelope
alias RestaurantHost.{Config, DeviceGrants, Restaurant}

# Money (the restaurant's menu prices) needs Localize running.
{:ok, _} = Application.ensure_all_started([:coop_substrate, :ex_money])

chapter = "e2e-restaurant"
merchant = "shop"

File.rm(Path.join(keys, "governance.seed"))
{:ok, _} = Ops.gen_key("governance")
{:ok, gov} = Ops.load_signer("governance")
governance = %{role: "governance", key_id: gov.key_id, pubkey: gov.pubkey}

device = fn id ->
  {_pubkey, seed} = Crypto.generate_keypair()
  {id, "k-" <> id, seed}
end

devices = [device.("storefront"), device.("board-1")]
secret = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

restaurant = %{
  "chapter" => chapter,
  "merchant" => merchant,
  "currency" => "USD",
  "jurisdiction" => "US-MI",
  "menu" => [
    %{"id" => "margherita", "name" => "Margherita", "sku" => "MARG", "price_minor" => 1250},
    %{"id" => "pepperoni", "name" => "Pepperoni", "sku" => "PEPP", "price_minor" => 1400}
  ],
  "storefront" => %{"device_id" => "storefront", "key_id" => "k-storefront"},
  "boards" => %{
    "board-1" => %{
      "device_id" => "board-1",
      "key_id" => "k-board-1",
      "pairing_sha256" => Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
    }
  }
}

file = Path.join(state, "restaurant.json")
File.write!(file, JSON.encode!(restaurant))

seeds = Map.new(devices, fn {id, _key, seed} -> {Config.seed_var(id), Base.encode64(seed)} end)
env_file = Path.join(state, "restaurant.env")
File.write!(env_file, Enum.map_join(seeds, "", fn {var, b64} -> "#{var}=#{b64}\n" end))
File.chmod!(env_file, 0o600)

append! = fn type, payload ->
  {:ok, env} =
    Envelope.new(%{
      event_id: ULID.generate(),
      chapter_id: chapter,
      type: type,
      payload: payload,
      signers: [governance],
      auth_ref: nil,
      timestamp_ms: System.system_time(:millisecond)
    })

  {:ok, signed} = Envelope.sign(env, gov.key_id, gov.seed)
  {:ok, _} = Log.append(signed)
end

append!.("RoleKeyDeclared", %{
  "role" => "governance",
  "key_id" => gov.key_id,
  "pubkey" => {:bytes, gov.pubkey}
})

{:ok, config} = Config.load(file, seeds)
r = Restaurant.build(config)

for {id, _key, _seed} <- devices do
  {:ok, d} = DeviceGrants.details(r, id)
  append!.(d.type, d.payload)
end

File.write!(
  Path.join(state, "restaurant-stack.json"),
  JSON.encode!(%{
    "storefront" => "http://127.0.0.1:4070/",
    "board_pairing" => "http://127.0.0.1:4070/board/pair/board-1/#{secret}",
    "chapter" => chapter,
    "merchant" => merchant,
    "harness_keys_dir" => keys
  })
)

IO.puts("restaurant ready: chapter #{chapter}, devices granted, menu from #{file}")
