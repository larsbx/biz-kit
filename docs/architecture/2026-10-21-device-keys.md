# Device keys: the field app signs its declarations

Date: 2026-10-21. Status: **implemented** in `Dispatch.Accounts.DeviceKeys`,
`DispatchWeb.DeviceController` and `Dispatch.Operations.Declarations`. The
client is the d-patch Android field app (its ADR-0012).

## Why

d-patch's specification (§23.1) has the app register an installation public
key after interactive login and sign offline events with it. Dispatch had the
`devices` table and accepted `device_id`, `device_sequence` and
`device_signature` on status events, but nothing registered a key and nothing
checked a signature: a device ID was taken on trust.

## Decision

The device registers its own key, and every declaration that names it carries
its signature.

```
app, signed in ── POST /v1/me/devices {installation_id, public_key, proof}
                    proof = Ed25519 over DispatchDeviceRegistrationV1
                  → 201 {device_id} (200 if this key is already registered)

app ── POST /v1/me/status-events {…, device_id, device_sequence, device_signature}
         device_signature = Ed25519 over the body's other fields + DispatchStatusEventV1
       → 201, event.verification = DEVICE_AUTHENTICATED
```

- **Statements are canonical maps** (`CoopEventCanonicalV1`, the scheme
  capability documents and the ledger use) with a `schema` and no `type`, so
  a registration proof, an event signature and a ledger command cannot pass
  for one another.

  | Schema | Fields |
  | --- | --- |
  | `DispatchDeviceRegistrationV1` | `tenant_id`, `participant_id`, `installation_id`, `public_key` (bytes) |
  | `DispatchStatusEventV1` | the event body's own fields, less `device_signature` |

  The server builds the registration statement from the caller's tenant and
  participant, so a proof made for anyone else does not verify. The event
  statement is built from the body as received (`conn.body_params`), so a
  field changed after signing fails.
- **Self-service.** Proof of possession is the whole check; no one approves
  a handset. The same key again is a no-op. An installation registered with
  another key, to someone else, or in another tenant is a conflict
  (`409 INSTALLATION_CONFLICT`): a new installation is how a key changes.
- **A device's events are signed.** Naming the caller's own active device
  without a signature is `422 DEVICE_SIGNATURE_REQUIRED`; a signature that does
  not verify, or was made over fields naming another device, is
  `422 DEVICE_SIGNATURE_INVALID`. A device that is not the caller's own active
  one is refused as before (`ReferencedRows`). An event without a device is
  `verification: NONE`. The verification is decided in `Declarations`, never
  taken from the request.

What `DEVICE_AUTHENTICATED` means: the declaration was made on that
participant's registered handset, whenever it was uploaded. It does not mean
the person was present (that is `SYSTEM_BIOMETRIC` or `FACE_1_TO_1`).

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| `CoopSubstrate.Enrolments` (the earlier roadmap item) | It grants task-ledger roles inside a `{chapter, tenant, project}` scope, and an administrator approves each device by code with the governance key. A field device is none of those roles, dispatch tenants have no coop scope, and a code per driver's phone is a step §23.1 does not ask for |
| Sign the raw request body | Dispatch would have to keep raw bodies; a field-wise canonical form survives JSON re-encoding |
| ECDSA P-256 in the Android Keystore | Hardware-bound, but a second signature scheme. The app keeps Ed25519 and seals the seed under a Keystore key (d-patch ADR-0012) |

## Limits

- A registration proof has no nonce. Replaying one registers the same key for
  the same participant and installation again, which changes nothing.
- No key rotation beyond a new installation, and revocation is `Device.revoke`
  (Section 13), with no endpoint yet.
- Only status events are signed. Location samples carry a signature field in
  d-patch's specification and will use the same statement form.

## Verification

- `DispatchWeb.DeviceControllerTest` (6): registration once and again; proofs
  by another key, for another participant or with a `type` refused; an
  installation keeping its key across keys and tenants; malformed bodies; a
  domain caller whose signed fields name another device; a registered
  device's declaration stored `DEVICE_AUTHENTICATED`.
- `DispatchWeb.StatusEventControllerTest`: unsigned, altered, foreign-key and
  undecodable signatures refused; a signed retry is the original event; no
  device is `NONE`; a client-sent `verification` is ignored.
- Mutations: removing the event-signature check, the required signature, the
  registration proof, the participant binding, the same-key rule on
  re-registration, the signed-device match or the server-decided verification
  each fails a test.
- d-patch reproduces both statements and signatures byte for byte from
  vectors this server generated (`device-signing-vectors.json`).
