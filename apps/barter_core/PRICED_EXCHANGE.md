# Price all supply; always offer cash; incentivize network exchange

`BarterCore.PricedExchange.quote/4` is an additive pure contract on the
`PooledClearing` allocation. Every available supply resource must have
a seller-origin monetary list price expressed in exact integer minor units
per exact resource unit. Supplier revision and price expiry must match
the validated clearing snapshot.

The application can present **both** options for every proposed shipment:

- **Pay cash:** full seller list price, with ordinary merchant payment.
- **In-network:** supplier-opted-in lower network price, plus separately
  authorized member-to-member in-kind obligation offset or partial monetary
  top-up. Cash remains selectable; no participant is forced to barter.

The first incentive is **seller-funded**: a per-unit discount no larger
than the listed unit price. The seller receives a correspondingly lower
amount; the platform does not invent funds, promise redeemable credits or
create a central monetary ledger. Quotes return exact amounts and the
explicit incentive, so users can compare them transparently.

If an entire pooled exchange elects network offset through authenticated
consent, the proposed discounted obligations can be summarized as a
separate per-member/per-currency **conditional** net cash position. Different
currencies are never netted or exchanged automatically. A party can decline,
re-quote and use ordinary payment without implying that other participants'
signed terms remain valid.

No payment, company formation, stock reservation, signature verification,
legal netting, ledger admission, FX, tax, shipping, escrow or settlement is
performed in this pure module. Hosts must authenticate the offers, enforce
the local authority boundary and obtain explicit agreement for any netting.
The underlying matcher maximizes resource units, not economic welfare or
price-based opportunity. Pricing-aware optimized matching is further work.

Run `cd apps/barter_core && mix test` (Elixir 1.19 / OTP 27).

See [decision record](../../docs/architecture/2026-10-26-priced-network-choice.md).
