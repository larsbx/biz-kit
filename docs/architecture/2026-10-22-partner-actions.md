# Slice 1 partner actions (Section 33.4 scenarios 17–19)

The shipper and receiver stop pages now submit readiness reports, encrypted
proof references, and appointment/instruction proposals. The broker's `/loads`
and `/loads/:id` pages show the selected contracted load, stop summaries, its
own conversation metadata, and proposal forms. All forms are ordinary HTML
POSTs with CSRF protection and idempotency keys. They require no new browser
JavaScript. The same Ash actions back Section 24.6's machine API.

## Authority

`PartnerScope` is an Ash filter check. SQL confines partner reads to the
explicit tenant, the one selected active role assignment and scope, and an
active matching stop/load party relationship. Principal and assignment state
are re-read, including active user/participant and role definition. Stop kinds
come from the allowlisted profile callback, not seeded role-key branches.
The preexisting read-only `OTHER` stop view stays readable; its contribution
forms are disabled and its writes are refused.

`PartnerMutation` independently requires the action capability. Readiness and
references require a stop grant and the profile's pickup/delivery kind;
proposals additionally require `proposal.create` and `appointment.propose`
or `instruction.propose`. A broker's load grant cannot report readiness or
add proof. Administrative authority supplies none of these permissions.

New contributions derive tenant, organization, participant, assignment,
source and receipt time from the server actor. Clients cannot supply approval,
execution or identity fields. The mutation locks the stop and authority rows,
then revalidates authorization before appending. Revocation and party-ending
updates serialize with admission. The audit append commits in the same Ash
transaction. Idempotency is scoped by assignment and includes action, subject
and body in its hash; replay reauthorizes subject access before returning a
stored acknowledgment.

Every inaccessible or missing subject returns the same 404, without subject
IDs or existence-bearing detail. Encrypted-session role selection and machine
`X-Role-Assignment-ID` both select authority rather than grant it.

## Data and attribution

- `stop_readiness_events` is append-only. Initial states are `NOT_READY`,
  `READY`, `CHECKED_IN`, `BLOCKED`. Forms compare both the stop version and
  the latest recorded readiness ID, so two stale initial forms cannot both
  append. Late offline reports retain occurrence and receipt times; the latest
  occurrence supplies the displayed readiness. No driver declaration changes.
- `action_proposals` is append-only, with only `PROPOSED` as a persisted state.
  A versioned, fixed-order JSON payload binds requested values, tenant, stop,
  selected assignment, basis version and expiry to its SHA-256. Expiry must be
  in the next 24 hours. Window ordering and mutually exclusive payload kinds
  are checked. The view labels an old basis `STALE` and an elapsed expiry
  `EXPIRED`; neither becomes a confirmed appointment or instruction. No
  approval, confirmation or execution action exists here. A later execution
  path must satisfy the common approval, exact-hash, expiry, current-authority
  and execution-receipt controls; this slice cannot execute commitments.
- `document_references` stores an encrypted opaque locator, category and label.
  Pickup documents and proof-of-delivery references are kind-scoped. It accepts
  no URL or executable content, does not fetch a locator, and has no upload or
  download endpoint. `REFERENCE_ONLY` expressly records that no file has been
  uploaded, scanned or verified. The locator uses AES-256-GCM with a random
  nonce and a version-specific additional-data label. Production needs a
  separate base64 32-byte `DOCUMENT_REFERENCE_KEY`; absence fails additions
  closed. Dev/test use a published synthetic key. Keep the production key
  available for stored references; key rotation/re-encryption is not supplied.
- `conversations` supplies read-only partner thread metadata: load,
  counterparty organization, subject, channel, state and observation time.
  There is no message body in this resource or view. Partner creation is
  denied; provider intake and message content remain Slice 4 work. A contract
  on a load never grants another organization's thread metadata.

Contribution reads stay private to the contributing organization and scoped
subject. View models contain no rate, commodity/carrier note, driver timeline,
route trace, other stop on a stop page, or other party's contact/message
content. Load field policies additionally hide rate, currency and commodity
from authorized partner Ash reads. Readiness, proposals, references, load
status and conversation metadata retain source/freshness labels. Location is
explicitly unavailable until a consented, policy-authorized summary source
exists (Slice 2); no driver position is substituted.

## Contract and acceptance

Machine routes: `GET /v1/loads/:load_id`, `GET /v1/stops/:stop_id`,
`POST /v1/stops/:stop_id/readiness-events`,
`POST /v1/stops/:stop_id/document-references`, and
`POST /v1/actions/proposals`. Each mutation requires `Idempotency-Key` and
`expected_version`. The proposal body names `stop_id`. Unknown fields are
rejected. The generated contract is copied to d-patch's
`contracts/biz-kit-dispatch.openapi.json`; its frozen `central/` is unchanged.

The domain and API tests cover permitted actions, direct unauthorized Ash
calls, organization/tenant/role boundaries, field and thread isolation,
revocation, stale readiness and proposal bases, expiry, invalid payloads,
encryption failure, idempotency conflict and replay after relationship end.
The real-server Playwright suite covers scenarios 17–19 with JavaScript on
and off, plus a form held across an offline interval whose basis changes.
Existing courier, role-administration, signed offline declaration and stream
revocation scenarios remain in the same suite.

The `dispatch-partners` workflow runs all dispatch tests with PostGIS,
OpenAPI verification and resource-snapshot checking. d-patch's paired branch
workflow runs the real stack. This server change builds on merged biz-kit #61. The d-patch change is
stacked on its still-open #18; accept that prerequisite, then this server
change, then the client/test change. Hosted CI and Android emulator execution
must be recorded separately from local results; no merge with a failing gate.
