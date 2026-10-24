# ADR: federated biz-kit and a common decentralized marketplace

Date: 2026-10-24. Status: **proposed protocol direction; first pure wire
contract staged, no deployed federation or marketplace**.

## Decision

Biz-kit is a **federatable business platform**, not a GitHub analogue or a
mandatory central SaaS installation. Organizations, merchants, carriers,
service providers and other authorized participants can run or join
independently administered biz-kit instances. A common marketplace is the
*network-wide, locally rendered union* of advertisements from those instances,
not a globally owned marketplace database, central listing authority or
payment processor.

Use W3C [ActivityPub](https://www.w3.org/TR/activitypub/) server-to-server
federation and [ActivityStreams 2.0](https://www.w3.org/TR/activitystreams-vocabulary/)
for public discovery, following, publishing, updating and withdrawing
marketplace advertisements. The native portable capability apps remain usable
without ActivityPub; federation is a service edge around them, not a dependency
from `task_core`, `commerce_core`, `inventory_core`, `fulfillment_core` or
`school_ops` to a third-party server.

This complements rather than rescinds
[one source of truth **per independently governed installation**](2026-10-11-single-source-of-truth.md).
That ADR's one signed ledger, one local command-admission path and one principal
registry apply *inside* each installation. Federation neither unifies remote
databases nor gives a foreign ledger the authority to mutate local business
facts. No cross-node ACID transaction is assumed.

## Parties, actors and home ownership

- Each installation has a stable HTTPS federation origin and can expose
  ActivityPub Organization, Person, Service or Application actors with inbox
  and outbox endpoints. Published actors are public projections mapped to
  `BizKit.Identity` principals or business entities by an explicit,
  administrator-governed binding; the AP actor URL is not a local principal ID.
- Every listing has exactly one **home origin** which owns its current
  publication revision, disclosure decision and withdrawal. Remote servers
  cache searchable projections and show source attribution and freshness.
- Participants may discover sellers on any node, follow them, and browse a
  single combined marketplace. User-facing searches union locally indexed
  remote advertisements with local listings and label stale/unknown status.
  Peer discovery via follows, explicit instance peering or optional relays is
  distributed; no relay may become an exclusive gatekeeper. Instances may
  block, rate-limit or distrust peers independently.
- No shared password, provider identity, operator grant, key material, client
  session or learner record crosses the federation. Portable verified
  statuses/ratings/attestations must be evidence-based, origin-bound, scoped
  and independently revocable. Never equate a self-claimed rating or AP
  display name with verified identity, reputation or proof of completion.

## ActivityPub public listing profile, slice 1

`FederationCore.Marketplace` stages a deterministic, intentionally minimal
public profile:

- Home node exports `Create`/`Update` activities whose objects are
  ActivityStreams `Page` objects, public title/summary and canonical `url`.
  The `attachment` is a same-origin `application/json` link to an exact-shape
  `bizkit.marketplace.listing.v1` document. Each activity has a home-issued,
  unique HTTPS `id`. `Delete` withdraws with `Tombstone`.
- The linked public metadata states `seller`, `id`, `revision`, `name`,
  `summary`, `category`, and `price` as either `quote` or `fixed` using an
  uppercase three-character currency code and nonnegative *integer minor
  units*. A quoted price or public fixed-price advertisement is not itself
  legal acceptance of sale, payment, currency exchange, available stock or
  transport promise. An implementation must publish quantity, jurisdiction,
  tax, fulfillment options and commitments only via separately versioned
  owner-authorized schemas and domain contracts.
- A remote inbox may parse only after verifying authenticated actor identity,
  key provenance and accepted origin policy. Parser output is a **quarantine
  candidate**, not a persisted accepted fact. Hosts must bind `activity.id`,
  `object.id`, actor and metadata document to the verified home origin;
  resolve actor moves and aliasing only through an explicit verified migration.
- Keep ActivityPub and biz-kit listing semantics distinct. Social clients may
  display the Page/link without supporting purchases. Federation-core's
  narrow profile is **not** a claim of full ActivityPub server conformance or
  demonstrated Mastodon compatibility.

## Local publication and remote delivery

A seller's authorized domain command is accepted **locally** into the home
signed ledger. A deterministic public projection is eligible for ActivityPub
publication only after its disclosure policy and publication consent pass.
A durable **ledger-derived outbox** records stable effect IDs, destination
actors/inboxes, delivery status, retry budgets and receipts; an external HTTP
failure must not roll back accepted local business history or create a second
business writer. The home instance exposes discoverable actor documents,
OrderedCollection outboxes and inboxes and, when desired, WebFinger resolution.

Incoming activities must have verified HTTPS request authentication,
request-body integrity, actor/key association, deduplication and origin
authorization before indexing. Key rotation and stale key handling require
explicit provenance. Defend all actor, collection, attachment and redirect
fetches against SSRF, DNS rebinding, local/private IPs, oversized responses,
JSON-LD context expansion abuse, fanout loops and request amplification.
Constrain audience traversal, redirect depth, message size, concurrency, key
caching, retry timing and retention. Private `to`/`cc`/direct activities are
**not** part of this public listing profile. Render all remote content as
untrusted text and allow blocklists, abuse reports and local moderation.

The first pure code slice does **not** implement these host obligations. It
only constructs and parses a narrow public wire profile and rejects obvious
origin and shape substitutions. It is not safe to expose an inbox with only
this library.

## Marketplace transactions are not federated ledger writes

Discovery, negotiation and legally meaningful commercial commitments are
separate processes:

1. Buyer discovers listing `L` from seller home `S`; local UI indicates
   remote source, last verification and whether terms remain fresh.
2. Buyer contacts `S` through an authenticated, purpose-specific commercial
   capability endpoint (ActivityPub `Offer`/ `Accept` may carry *nonbinding
   intent* notifications but **never** serve as unilateral signed business
   authority). Both sides agree on exact product/service, currency,
   amount, tax, delivery, expiry and applicable jurisdiction before admitting
   an obligation.
3. Seller home authorizes a unique conditional offer/stock hold with
   idempotency and expiry under CommerceCore/InventoryCore contracts. Buyer
   home may record its own intent, but cannot write the seller's ledger.
4. Commit/acceptance requires independently authorized decisions and matched
   terms; explicit receipts/reconciliation account for retries, partitioned
   nodes, expiry and compensation. **No global exactly-once or atomic
   cross-ledger commit** is asserted. Payment/settlement, KYC, credit,
   privacy and dispute handling are separate explicit regulated domain
   interfaces, not inferred from the ActivityPub stream.
5. Fulfillment and review/trust attestations reference independently
   verifiable proof, not just a seller's `Delivered` post. Buyer and seller
   may retain independent authoritative histories, reconcilable by durable
   cross-reference IDs; never pretend one global writer exists.

Domain examples include restaurant sales (Eatsbot), freight and courier
capacity (Dispatch), parts/catalog inventory and professional services.
SchoolOps may publish an authorized *institutional* service offer, but learner
identities/assessments and private employee records never federate by default.
Hawala financial trust, balances, deposits, credit/clearing and exchange
permissions stay in its own core; the marketplace cannot act as its ledger.

## Host delivery milestones / acceptance

1. **Pure metadata and ActivityStreams wire (this PR)**: exact schema,
   origin binding, integer prices, public-only messages, deletion and
   impersonation/invalid-shape tests. No server conformance claim.
2. **Read-only federated discovery**: signed actor lookup, authenticated inbox,
   durable deduplication, listing fetch with SSRF protections, revision/tombstone
   handling, provenance, moderation and local search. Test two *independent*
   instances and replay/restart/partition recovery.
3. **Publisher and subscriptions**: home-ledger-derived durable outbox, actor
   endpoints, OrderedCollection pagination, subscriber inbox discovery,
   retries, key rotation, Follow/Accept/Undo, block and abuse policy. Run
   ActivityPub conformance and third-party (Mastodon) smoke tests; record
   exactly which interoperability paths actually work.
4. **Common marketplace UI**: local+remote search, clear home origin and
   disclosure/freshness/reputation indicators, seller contact/quote channel,
   opt-in publication and takedowns. A discoverable public relay/index is an
   optional cache, not mandatory routing authority.
5. **Cross-instance commerce pilot**: two independent deployments and
   sellers, one fixed-price product plus one quote-only service. Verify
   seller-owned reservation and explicit buyer acceptance, out-of-order
   messages, timeout, payment isolation, dispute/proof and compensating
   failure behavior. No buyer or foreign activity can mutate local business
   state without a locally valid signed command.

Operational success means a participant on B can discover and contact a
merchant on A, without either joining a central biz-kit server, and can
complete a separate authorized transaction through domain interfaces even
when A and B preserve independent ledgers and administration. Network
partitions degrade availability, not ownership, history or safety.
