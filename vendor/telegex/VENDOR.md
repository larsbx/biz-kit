# telegex (vendored)

Upstream: [telegex 1.8.0](https://hex.pm/packages/telegex/1.8.0) (MIT, `LICENSE`),
the latest stable release. Used by `apps/eatsbot_extension_telegram_bot`.

## Why it is vendored

`Telegex.Hook.Server` is compiled only `if Code.ensure_loaded?(Plug)`, then
`use Plug.Router`. telegex declares `plug` as a dev/test-only optional dependency,
so Hex records no dependency on it and Mix prunes `plug` from the code path while
compiling telegex. In this umbrella another dependency (`open_api_spex`) loads
`Plug` into the compiling VM first, so the guard passes, `Plug.Router` cannot be
found, and a clean build fails depending on compile order.

## Changes from upstream

1. `lib/telegex/hook/server.ex`: the guard checks `Plug.Router`, the module it
   uses, instead of `Plug`. eatsbot receives webhooks through its own Phoenix
   controller and does not use this server.
2. `mix.exs`: only the runtime dependencies Hex publishes for 1.8.0
   (`typed_struct`, `jason`). Upstream's dev/test pins (e.g. `finch ~> 0.18`)
   would conflict with the umbrella's lock.
3. Not copied: the API code generator (`lib/mix`) and its inputs (`priv/`).

`lib/` is otherwise byte-identical to the Hex package; `diff -r` against
`deps/telegex/lib` of a Hex install shows only change 1.

To drop this copy, upstream needs a guard on `Plug.Router` (or a non-dev
optional `plug` dependency); then return to `{:telegex, "~> 1.8"}`.
