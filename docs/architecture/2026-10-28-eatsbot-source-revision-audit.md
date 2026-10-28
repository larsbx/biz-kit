# Eatsbot code-salvage R0a: pinned source revision comparison

Date: 2026-10-28. **Read-only code inventory; partial R0, not a production service/deployment inventory.**

Paired with [Eatsbot salvage/retirement](2026-10-28-eatsbot-salvage-and-retirement-plan.md), [biz-kit issue #176](https://github.com/larsbx/biz-kit/issues/176), [MarketingCore PR #177](https://github.com/larsbx/biz-kit/pull/177), and [DispatchCore PR #178](https://github.com/larsbx/biz-kit/pull/178).

## Exact repository revisions compared

- Imported code: `larsbx/biz-kit`, commit [`ef2d31d88784c12c86feb2f6a2a2fd1c7cdc8db5`](https://github.com/larsbx/biz-kit/tree/ef2d31d88784c12c86feb2f6a2a2fd1c7cdc8db5/apps/eatsbot_core/lib), rooted at `apps/eatsbot_core/lib/`.
- Separate product: `larsbx/eatsbot`, `dev` commit [`f81441ff0beb6381481f8ba391b3898fab364a23`](https://github.com/larsbx/eatsbot/tree/f81441ff0beb6381481f8ba391b3898fab364a23/eatsbot/core/lib), rooted at `eatsbot/core/lib/`.
- "Identical" is an exact Git blob SHA match for that file; "different" means content differs but **does not establish a semantic behavior change**. These are file samples, not an exhaustive tree inventory.

## Compared paths (Git blob SHA prefixes)

| Relative source path | Imported biz-kit | Standalone Eatsbot | Result |
| --- | --- | --- | --- |
| `marketing/attribution.ex` | `6d69e653e5c7` | `6d69e653e5c7` | Identical blob |
| `marketing/promotion.ex` | `6174e4ca2ed3` | `a146c24924f4` | Different blob |
| `marketing/subscriber.ex` | `7d57dfebc378` | `100deccf81fa` | Different blob |
| `marketing/visit.ex` | `9cf143fc308a` | `f6ccab8838c1` | Different blob |
| `marketing/visit/check_in.ex` | `71d4efd4e090` | `71d4efd4e090` | Identical blob |
| `marketing/touchpoint.ex` | `5ce7638c039b` | `534f68f767b8` | Different blob |
| `marketing/consent_bridge.ex` | `a1d77f16dce0` | — | Biz-kit-only |
| `orders/delivery_coupling.ex` | `24609607cdde` | `24609607cdde` | Identical blob |
| `orders/transitions.ex` | `d5e9a91eb641` | `d5e9a91eb641` | Identical blob |
| `carts/checkout.ex` | `e6ee067c67a6` | `e6ee067c67a6` | Identical blob |
| `deliveries/delivery.ex` | `b795e8ac1266` | `1ac2727f8530` | Different blob |
| `deliveries/transitions.ex` | `538587fa93e4` | `538587fa93e4` | Identical blob |
| `deliveries/stale_cleaner.ex` | `b8ad61ede592` | `b8ad61ede592` | Identical blob |
| `products/discount_rule.ex` | `dfc8e8f71243` | `9b4533d8baa1` | Different blob |
| `orders/fulfillment_bridge.ex` | `a7c6800f2741` | — | Biz-kit-only |

## Consequences for extraction

- `Attribution`, `Visit.CheckIn`, `DeliveryCoupling`, `Orders.Transitions`, `Cart.Checkout`, `Deliveries.Transitions`, and `StaleCleaner` have matching blob content at these two precise revisions. They are appropriate **starting points for characterization fixtures**, not authorization to cut over.
- `Promotion`, `Subscriber`, `Visit`, `Touchpoint`, `Delivery`, and `DiscountRule` have differing blobs even when observed text lengths match. Before importing tests or schemas, perform exact file-level diffs and identify which source owns the desirable behavior. Do not indiscriminately replace one with the other.
- `Marketing.ConsentBridge` and `Orders.FulfillmentBridge` appear **only in biz-kit** for these checked paths; they integrate shared SalesCore/FulfillmentCore behavior. Keep their fail-closed boundaries even when Eatsbot is retired.
- MarketingCore #177 explicitly strengthens the old notification-timestamp rule to require independently confirmed delivery, and uses a new integer-ppm half-up commission rule. Do not call it legacy behavioral parity until source-backed rounding/regulatory tests are written.
- DispatchCore #178 replays the historical **13-edge** delivery graph but introduces a stricter candidate policy and no physical proof authority. No live Dispatch or cross-domain FulfillmentCore write switches are implied.

## R0 still missing before any production decision

Repository source comparison cannot determine active runtime processes, externally configured databases, traffic, queues, Telegram webhooks, customer/merchant obligations, pending orders/deliveries/refunds/commissions, retention mandates, or independent deployments. Obtain these from **authorized operational evidence** and independently verify the single-writer migration plan. No replacement is authorized merely because this table is complete.

## Follow-up tests

- Compare semantic changes in each mismatched resource with its respective source tests.
- Characterize Money/Decimal rate rounding and the legacy check-in notification attribution defect, including second-level truncation and duplicate callback races.
- Retain the original order/delivery coupling tests, cancellation/pickup/delivery-history replays and unresolved-outcome recovery.
- Prove SalesCore consent suppression and exact webhook/notification replay before removing Eatsbot's old subscribers or delivery resources.

**No production components were inspected or modified by this audit.**
