# Vendoring portable biz-kit cores

The following source apps are intended to work both **inside** the umbrella
and as dependency packages consumed by independently evolving domain products:

- `task_core` — workflow and task policy, without persistence
- `commerce_core` — catalog and price calculation policy
- `inventory_core` — replayable stock/reservation policy
- `fulfillment_core` — transport handoff protocol
- `sales_core` — sales progression and promotional-consent policy

These packages detect whether they are in the biz-kit umbrella. Only there
do they use the shared root `mix.lock`, `deps`, `_build` and `config`.
When copied into an independent consumer, they use their **own** Mix paths.
CommerceCore declares its `ex_money` dependency; no other app above requires
Ash/Postgres just to compile its pure rules.

Example for an external Elixir consumer:

```elixir
defp deps do
  [
    {:task_core, git: "https://github.com/larsbx/biz-kit.git",
      sparse: "apps/task_core", ref: "<reviewed commit>"},
    {:inventory_core, git: "https://github.com/larsbx/biz-kit.git",
      sparse: "apps/inventory_core", ref: "<reviewed commit>"}
  ]
end
```

Pin an immutable reviewed commit and test the consumer against it. Do not
specify `:in_umbrella` outside biz-kit. Android and non-Elixir consumers must
use versioned protocols and SDKs rather than vendoring Elixir BEAM modules.

`apps/biz_kit_composition` remains an **umbrella host adapter** and is not
yet a standalone consumer package: its dependencies are explicitly
`:in_umbrella`. Production state authority stays in the existing domain
service/ledger until approved, tested handoffs replace it.

CI [Portable cores](../../.github/workflows/portable-business-cores.yml)
copies each listed app to a directory entirely outside the umbrella, resolves
dependencies independently, compiles with warnings-as-errors and runs its
own tests. This catches accidental reliance on the umbrella root or on
unrelated application configuration. It is **not** end-to-end production
authorization, deployment, or signed-ledger acceptance evidence.
