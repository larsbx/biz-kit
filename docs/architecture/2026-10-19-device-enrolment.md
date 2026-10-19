# Self-service device enrolment

Date: 2026-10-19. Status: **implemented**. Replaces "the administrator copies
the device's public key into a grant by hand" in
[deciding on suggestions](2026-10-18-decide.md).

## The flow

1. **The person asks, from the device.** In the web view, a signed-in person
   names the device and presses *Request access*. The server returns a
   `CoopDeviceEnrolmentV1` statement naming the person's principal, the
   project, the device's key ID and public key, the label and a nonce. The
   page decodes it and signs it only if it is exactly that: the enrolment
   schema, this key, and no `type` field, so it can never be a command. The
   signature proves the device holds the key. The server records the request,
   with the identity the person signed in with, and returns a code like
   `ABCD-EFGH-JKLM`.
2. **The administrator approves by code**, on a machine holding the
   governance key:

   ```
   mix coop.enrol ABCD-EFGH-JKLM --server https://bizkit.example
   ```

   The task shows who is asking (principal, provider and subject), for which
   project, and the device's label and key. On confirmation the server
   prepares the `TaskOperatorGrantedV1`. The task decodes it, checks that it
   grants exactly that principal, project and key, signed by its own
   governance key alone, and then signs and submits it.
3. **The ledger admits the grant** as it admits any grant: a governance key
   declared for the chapter, checked at append. The page asks for its status
   (by polling, until it can read the project's feed; then on every frame
   that changes its person's devices ([live view](2026-10-19-live-view.md))),
   sees it enrolled, and its decisions are accepted from then on.

A request names a **role**: `operator` (the default, as above),
`reviewer`, which yields a `TaskReviewerGrantedV1` for reviewing evidence
([execution](2026-10-19-execution.md)), or `governance`, which declares the
browser's key a governance key of the chapter for the person
([administration](2026-10-19-administration.md)). Once the first
administrator is approved with `mix coop.enrol`, administrators approve
codes in the view. The statement the device signs
names the role, the page checks it, status is kept per role, and the same
key may hold both.

## What holds what

| | Holds | Can |
| --- | --- | --- |
| the device | its private key (non-extractable) | prove possession; sign decisions once granted |
| the server | requests, codes, held approvals (memory) | prepare; never sign |
| the administrator's machine | the governance seed (`HARNESS_KEYS_DIR`, 0600) | sign grants |
| the ledger | the grants | decide |

A request gives no access. The code is a capability for one request: 60
random bits, valid for three days, single use. With it, anyone can read the
request (principal, identity, label, public key) and ask the server to
prepare its approval. Nothing is granted without a governance signature. The
approval is held for that code only (`Commands.hold/5`, owner
`{:enrolment, code}`) and expires after five minutes.

The approval goes through the running server over HTTP. The `harness.*`
tasks start their own appender against the event store; running one beside a
live server would leave the server's appender behind the ledger.
`coop.enrol` starts nothing.

## Rules (`CoopSubstrate.Enrolments`)

- The key ID must be `k-` and the first four bytes of the public key in hex
  (`:key_id_mismatch`). The public key is 32 bytes (`:invalid_pubkey`). The
  label is 1–80 characters (`:invalid_label`).
- A key already enrolled for that principal and project is not requested
  again (`:already_enrolled`). Asking again while a request is pending returns
  the same code. Once the grant is revoked, the device can ask afresh.
- A challenge is single use, and only the principal it was issued to can
  answer it (`:unknown_challenge`); anyone else's attempt leaves it in place.
  The proof must verify under the requested key (`:bad_proof`).
- Approval names a governance key declared for the chapter
  (`:unknown_governance_key`). A signature by any other key is refused and
  the request stays pending.

## HTTP (SpruceGoose)

```
GET  /api/v1/chapters/:c/tenants/:t/projects/:p/devices/:key_id   (session) → {status, code?, expires_at?}
POST /api/v1/chapters/:c/tenants/:t/projects/:p/devices           (session) {key_id, public_key, label} → {id, statement}
POST /api/v1/devices/challenges/:id                               (session) {signature} → {code, expires_at}
GET  /api/v1/enrolments/:code                                     → the request
POST /api/v1/enrolments/:code/approval                            {governance_key_id} → the grant to sign
POST /api/v1/enrolments/:code/approval/:id                        {signature} → {event_id, global_seq}
```

The JSON helpers and the error mapping of these endpoints and the command
endpoints are shared (`SpruceGoose.Web.Requests`).

## Verification

- `EnrolmentsTest` (ledger, 11 tests):
  - The statement is not an envelope.
  - Proof yields a code; asking twice gives the same code.
  - Malformed key IDs, keys and labels are refused, as are proofs by another
    key or another principal.
  - Approval issues exactly the requested grant.
  - Only a declared governance key can sign, and an approval is held for its
    own code.
  - Codes are single use, expired requests are neither pending nor
    approvable, and a revoked enrolment can be requested afresh.
- Mutations: removing the proof check, the challenge's principal binding, the
  key-ID check, the expiry check or the already-enrolled check each fail a
  test.
- `SpruceGoose.Web.DeviceTest` (7 tests):
  - The whole flow over HTTP, with the real approval client against a
    running server.
  - `mix coop.enrol --yes` with a governance seed on disk.
  - Refusals.
  - The approver refuses a grant that differs in principal, project, key,
    type or signers.
- `test/js/app.test.mjs`: the page signs only its own enrolment statement.
- `SpruceGoose.Web.BrowserTest` (Chromium):
  1. The page requests access and shows its code.
  2. The test approves the code with the governance key.
  3. After a reload, which keeps the key in IndexedDB, the page is enrolled.
  4. The person accepts an agent's suggestion. The decision is signed by the
     key the browser made, under the grant the code produced.

## Limits

- Requests, codes and held approvals live in memory, in one process for the
  whole [cluster](2026-10-19-cluster.md). If it restarts or moves, pending requests are lost; the
  device simply asks again.
- Code guessing: 60 bits makes it impractical, and `/api/v1/enrolments` is
  [rate-limited](2026-10-19-rate-limits.md) per client as well.
- Revocation: see [device revocation](2026-10-19-device-revocation.md).
