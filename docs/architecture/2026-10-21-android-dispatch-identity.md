# Android dispatch identity and device integration

Date: 2026-10-21. Implementation: paired with d-patch Slice 1. Automated acceptance
results are recorded in the paired PRs; this note does not claim a deployed
provider or an emulator acceptance run.

## Identity and authority

Android opens the system browser through `POST /v1/mobile/authorize` and a
server-held S256 PKCE challenge. The endpoints delegate to the shared
`BizKit.Identity.native_begin/native_complete/native_exchange` API and
`NativeLogins` store; no separate native authority or handoff store is added.
The server's existing configured
`BizKit.Identity.Provider` authenticates, `Resolver` resolves an explicitly
bound platform principal, and `Sessions` issues the existing revocable session.
The callback checks a browser HttpOnly state cookie. It redirects to the fixed
native URI with a single-use, 60-second handoff code and client state, never a
session credential. Android exchanges that code and its original verifier at
`POST /v1/mobile/token`. Pending flows expire after ten minutes; process loss
fails closed. No provider secret or provider token is shipped to Android.

`Authorization: BizKit <session>` is deliberately distinct from the existing
OIDC `Bearer` scheme. The session is revalidated on every request, including
identity unbinding and logout. The resource-server OIDC path remains available
for existing non-device calls; claiming a device there now returns
`403 DEVICE_REJECTED`. Native sessions always require a signed device event.

Dispatch accounts predate platform principals. Link them explicitly using
`:mobile_principals`; never infer a link from email, a matching provider subject,
or the choice of identity provider. Provider migration keeps the same principal
and Dispatch account. This is an account link, not a grant: each request still
resolves exactly one current Dispatch role assignment and applies Ash policies.

## Deployment configuration

Configure the existing provider and resolver bindings as in
[identity](2026-10-18-identity.md), then configure Dispatch:

```elixir
config :dispatch, :native_identity,
  provider: "workos",
  public_url: "https://dispatch.example",
  redirect_uri: "com.dispatch.driver://signin"

# Add this URI to the existing exact native redirect allowlist.
config :biz_kit_identity, :native_redirect_uris, ["com.dispatch.driver://signin"]

config :dispatch, :mobile_principals, %{
  "prn_<existing-platform-principal>" => "<existing-dispatch-user-oidc_subject>"
}
config :dispatch, :mobile_enrolment_scopes, %{
  "<dispatch-tenant-uuid>" => {"<chapter-id>", "<ledger-tenant-id>", "<project-id>"}
}
```

Both mappings are operator-controlled server configuration. Missing links or
scope mappings fail closed. Register the HTTPS `/v1/mobile/callback` with the
provider. Keep secure cookies enabled. The fixed Android callback is
`com.dispatch.driver://signin`; PKCE protects a handoff intercepted by another
handler. Android checks the callback URI and client state before exchange.

The existing CoopSubstrate application, its event store and approval tools must
be running in the same biz-kit release. Dispatch's code-only substrate dependency
remains unchanged for deployments that use only its existing resource-server
surface; the acceptance launcher starts the substrate explicitly. A deployment
that enables native identity must start CoopSubstrate as well.

## Device lifecycle and status signatures

Android keeps an Ed25519 seed per account in encrypted preferences under
an Android Keystore-backed master key. This supports API 29 without claiming
hardware-backed Ed25519. The application already disables backup and transfer.
Loss of the encryption key fails closed; reinstallation requires a fresh device
enrolment. Signing out removes session credentials and role selection while
retaining keys and signed queued history for that account. Every signature binds its selected role.

The selected Dispatch tenant maps to one existing ledger scope. The enrolment
adapter calls `CoopSubstrate.Enrolments.begin/prove`; Android signs the canonical
challenge bytes and displays the resulting code. The existing administrator
approval (`mix coop.enrol CODE`) signs and admits the existing operator grant.
No Android endpoint approves its own request or issues another kind of grant.

`POST /v1/me/devices` registers the existing Dispatch installation resource only
after that exact full public key has an active operator grant for the principal
and configured scope. Retries return the caller's same active registration;
revoked Dispatch registrations are never revived. `key_id` is only a display
prefix: approval and signature checks compare the entire 32-byte public key.
Governance revocation uses the existing `mix coop.revoke GRANT_ID` workflow;
the mobile status endpoint rechecks that grant on every delivery, including an
otherwise idempotent duplicate. Lost devices require revocation and a newly
enrolled installation/key; the client never substitutes a new key into an old
queued signature.

The signed term is encoded by `CoopEventCanonicalV1` and signed with the existing
Ed25519 scheme:

```elixir
%{"schema" => "DispatchStatusV1",
  "role_assignment_id" => selected_assignment_id,
  "payload" => request_without_device_signature}
```

The payload includes subject, event ID, device ID and monotonic sequence.
Android writes the signed JSON once in the existing Room transaction and sends
it unchanged on retry. It never changes owner, role or signature at sync time.
The server locks the existing device row across proof verification, idempotent
admission and sequence advance. Lower sequences can only replay their already
stored event under the same role. Signature evidence (canonical bytes, signature
and public key) is preserved in the existing append-only audit payload, and the
admitted status is marked `DEVICE_AUTHENTICATED`, never biometric verification.

The original role and device status are checked before looking up an idempotent
201. Invalid ownership, key, signature or replay returns `403 DEVICE_REJECTED`;
conflicting IDs/keys return the existing 409 codes. Android retains 401/offline
work for retry and displays terminal rejection with its corrective action.

## Validation and acceptance

- Shared `native-status-vector.json`: produced by the actual Elixir/Rust encoder;
  Kotlin verifies its bytes and Ed25519 signature (including Unicode and an
  integer encoding boundary).
- `BizKit.Identity.NativeTest`: handoff, PKCE, single use, invalid provider,
  identity unbinding, session expiry and logout. Existing identity tests retained.
- Dispatch `MobileAcceptanceTest`: actual sessions, enrolment proof, governance
  approval, registry, role selection, signatures, duplicate delivery, conflicting
  reuse, watermark replay, revoked keys and role/session revocation.
- `d-patch/scripts/run-slice1-acceptance.sh`: actual HTTP backend plus Android
  NativeSession, Room and DispatchClient; offline queue, dropped response, retry
  duplicate, rejection and revocation. Only the provider is a test fixture.
- `.github/workflows/mobile-acceptance.yml` runs the backend acceptance cases
  with PostgreSQL/PostGIS. The paired d-patch lane checks out an immutable backend
  commit and runs the cross-repository acceptance script.

Local environment evidence: Elixir 1.19.0 / OTP 27.3.4 and Rust were available;
identity and Dispatch unit checks ran. The locked CI runtime is Elixir 1.19.6 /
OTP 28.3.3. PostgreSQL/PostGIS acceptance could not start here: no running service,
PostGIS absent, and the runtime cannot switch to a non-root database OS user.
Android build results and the cross-repository acceptance result are recorded in
the paired PR. Actual WorkOS/browser/device acceptance remains a deployment check,
not something established by the deterministic test provider.

The installation identifier is stable across account and role selection. The
existing Dispatch registry allows one active participant/tenant binding for that
installation; switching roles never generates another installation identifier
to evade that constraint. A different participant/tenant requires the existing
retirement/re-enrolment process for a fresh installation.

Android also applies the existing browser `isOwnEnrolment` guard before signing:
the statement must have the closed enrolment schema, its complete key, the
authenticated platform principal and the requested operator role. A command or
reviewer/governance request is never signed through the enrolment flow. The
shared `native-enrolment-vector.json` exercises that boundary in Kotlin.
