# #402 restaurant-through-Dispatch acceptance, run locally

Date: 2026-11-16. Status: **local, unsigned runner observation; not hosted CI.**
The "next reproducible gate" in the
[decommission checklist](2026-11-07-eatsbot-decommission.md#migration-status-as-of-november-14-2026)
is draft [#402](https://github.com/larsbx/biz-kit/pull/402)'s acceptance on its
exact revision. Its hosted `real-worker` job
([run 43578830161](https://github.com/larsbx/biz-kit/actions/runs/43578830161))
failed before any scenario ran.

## Why it failed, and the two-line fix

1. `apps/dispatch/test/support/delivery_portal.ex` calls
   `Fixtures.role_definition/2` without aliasing `Dispatch.Support.Fixtures`,
   so every test that uses the shared courier portal crashes in setup (the 7
   failures in the hosted log). The restaurant scenario never started.
2. With that fixed, the restaurant scenario fails in
   `Phoenix.LiveViewTest.DOM.parse_document/2`: `LazyHTML` does not implement
   `Enumerable`. The script runs it with Dispatch as the root project
   (`cd apps/dispatch; mix test`), and `lazy_html` is only a test dependency of
   `restaurant_host`, so Dispatch's protocol consolidation omits LazyHTML's
   implementation. Declaring it in Dispatch's test dependencies fixes it;
   `mix.lock` is unchanged (it already pins 0.1.14).

```diff
diff --git a/apps/dispatch/mix.exs b/apps/dispatch/mix.exs
index b9febf93..1bbc5820 100644
--- a/apps/dispatch/mix.exs
+++ b/apps/dispatch/mix.exs
@@ -97,6 +97,8 @@ defmodule Dispatch.MixProject do
       {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
       {:stream_data, "~> 1.1"},
       {:excoveralls, "~> 0.18", only: :test},
+      # LiveViewTest parses with LazyHTML; Dispatch must consolidate its protocols.
+      {:lazy_html, "~> 0.1.13", only: :test},
       {:phoenix_live_reload, "~> 1.5", only: :dev}
     ]
   end
diff --git a/apps/dispatch/test/support/delivery_portal.ex b/apps/dispatch/test/support/delivery_portal.ex
index f32413ad..0e439b44 100644
--- a/apps/dispatch/test/support/delivery_portal.ex
+++ b/apps/dispatch/test/support/delivery_portal.ex
@@ -6,7 +6,7 @@ defmodule Dispatch.Support.DeliveryPortal do
   import Plug.Test
 
   alias Dispatch.Accounts.RoleAssignment
-  alias Dispatch.Support.PortalIdentity
+  alias Dispatch.Support.{Fixtures, PortalIdentity}
 
   @portal_path "/ui/restaurant-receipts"
   @session Plug.Session.init(
```

## Result

Revision `76f5398a` = #402 head `ac984729` plus exactly the diff above, as two
local commits (not pushed). `scripts/test-procurement-dispatch.sh` with
PostgreSQL 16 + PostGIS 3 on loopback, Elixir 1.19.0 / OTP 27, the workflow's
environment and role: exit 0.

| Step | Result |
| --- | --- |
| Substrate procurement admission | 14 tests, 0 failures |
| Dispatch regressions (`--include integration`) | 2 doctests, 507 tests, 0 failures |
| Real worker and custody (procurement) | 7 tests, 0 failures |
| Restaurant checkout to courier confirmation | 1 test, 0 failures |

The restaurant test covers: signed-in delivery checkout; one load and one
active assignment for the authorized courier; distinct pickup and drop-off
codes; an out-of-order drop-off refused (422) with nothing appended; a worker
restart recovering the same assignment; pickup, then drop-off; the storefront
showing **Delivered** and the assignment **COMPLETED**; an idempotent drop-off
replay; exactly three signed ledger steps, `accept`, `picked_up`, `delivered`.

Runner receipt (`result.json`):

```json
{
  "revision": "76f5398adc2a823263f504a222cd74a1f7a13abc",
  "execution_kind": "source-dispatch-worker-postgresql",
  "fixture": "synthetic-disposable-loopback",
  "trust": "unsigned-runner-observation",
  "checks": {
    "signer_count_rejection": true,
    "dispatch_regressions": true,
    "real_worker_assignment_and_custody": true,
    "machine_contract": true,
    "restaurant_checkout_to_courier_confirmation": true
  },
  "files_sha256": {
    "compile.log": "cd207484a221ff104a6ac742e64dc71df4ab4d89895c4b70016e2c7df962c98c",
    "contracts.log": "3d7a0a41f8bc5fa3866053aebfe60ba669c78aace707879eb61712e63aa049da",
    "dependencies.log": "802b12801e31fbe75fc1f9fe6b843bb152bafbd548732cbcabd27b2f5e0407cc",
    "dispatch.log": "7dd20717f629304673e0da36c529c0ceb130e48b05a9f3d0c77cd6d3a99387e7",
    "restaurant-worker.log": "fba8e8b4880fbba224d46765b606880379a9613eaf73e4580f2ca2f1526ca9df",
    "revision.txt": "7d64ee9bafd00f6f3902087c8e9c748d9ecc2b98b17db44f6337954fc4a15331",
    "signer-count.log": "7fd93d576f10d42bf6a4ab8273f35be8565e15bc324d91aa78ebfbb95dbccbfb",
    "toolchain.txt": "024cdd72254823c8c0e524cafe01dcfc94c04df4b41fe29d9d35ab096713b682",
    "worker.log": "7cdded72d204ca196bcd8d90504fc26ab56f7d812be91edde4a84580da9cd8b6"
  },
  "packaged_dispatch_worker": false,
  "live_delivery": false
}
```

## Not shown

Synthetic fixtures on disposable loopback databases, driven through the
LiveView test client. `packaged_dispatch_worker: false`, `live_delivery:
false`: packaged staging of both releases, a worker outage across real
processes, and a pickup report arriving after cancellation remain the next
evidence. The receipt is unsigned and was produced in a development container,
not by the hosted workflow; it holds for this revision only, and #402 needs the
two lines above before its hosted run can say the same.
