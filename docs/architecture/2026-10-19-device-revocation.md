# Device revocation

Date: 2026-10-19. Status: **implemented**. Follows
[self-service device enrolment](2026-10-19-device-enrolment.md).

## Decision

A device is an operator grant naming a person's principal and the device's
key. Two ways end it:

| Who | Signs | Event | For |
| --- | --- | --- | --- |
| the person | one of their devices still enrolled in the project, or the device itself | `TaskDeviceRevokedV1` | a lost device, when they have another; retiring a device |
| an administrator | the governance key, with `mix coop.revoke <GRANT_ID>` | `TaskOperatorRevokedV1` (unchanged) | a person's only device; a compromised device; offboarding |

Letting the holder revoke without governance is safe because revocation
only removes authority. A holder can only deactivate their own device
grants in the same project. Someone holding a stolen device could revoke
the person's other devices, but they could already sign as the person, which
is worse. That is why the person revokes the lost device from another one at
once, or asks an administrator.

## The new event

```elixir
"TaskDeviceRevokedV1" =>   # operator-signed; stream task_grants/<tenant>/<project>
  %{"tenant_id", "project_id",
    "principal_id",            # the holder
    "authorization_event_id",  # the signing device's grant
    "revoked_grant_event_id"}  # the device grant to end
```

Admission, in order:

1. The signing device's grant: known, same project, active, same principal,
   and signed with its own key (the operator checks every command has:
   `:task_grant_revoked`, `:task_principal_mismatch`,
   `:task_operator_key_mismatch`).
2. The target grant: known (`:unknown_task_grant`), same project, the same
   principal (`:not_own_device`), and active (`:grant_already_revoked`).
   The target may be the signing grant itself.

The fold sets the target grant inactive, exactly as `TaskOperatorRevokedV1`
does. Everything that checks a grant follows from that:

- the device's commands are refused;
- feed readers using that grant are cut off at the revocation;
- delegations made from it end (`:delegator_grant_revoked`);
- the person's other devices are untouched.

`TaskOperatorGrantedV1` gains an optional `device_label` (1–80
characters). Enrolment sets it to the label the person chose, so a person can
tell their devices apart. Older grants have none. The approver checks the
label too.

## HTTP

```
GET  /api/v1/chapters/:c/tenants/:t/projects/:p/devices                      (session) → [{grant_id, key_id, label}]
POST /api/v1/chapters/:c/tenants/:t/projects/:p/devices/:grant_id/revocation (session) {"key_id"} → the command to sign
POST /api/v1/commands/:id                                                    (session) {"signature"}, as for decisions
GET  /api/v1/grants/:id                                                      → the grant
POST /api/v1/grants/:id/revocation                                           {"governance_key_id"} → the revocation to sign
POST /api/v1/grants/:id/revocation/:held_id                                  {"signature"}
```

The holder's revocation is held for the principal and submitted like a
decision. The governance revocation is held for `{:revocation, grant_id}`.
Preparing it needs no session, because the governance signature is the
authority, so `Commands.hold/5` keeps at most four held envelopes per owner,
evicting the oldest. Otherwise anyone who knew a grant ID could fill memory
with envelopes they can never sign. The bound applies to every owner:
principals, enrolment codes and grants.
`coop.revoke` and `coop.enrol` share `CoopSubstrate.Governance.Client`. It
decodes what the server prepared and signs only if the result is exactly
what was shown, signed by its own governance key alone. Neither task starts
an appender.

## The web view

*Your devices in this project* lists the person's devices by label, marking
this one, with a Revoke button on each. Revoking goes through the same
confirmation as decisions. The page decodes the command, checks it is a
`TaskDeviceRevokedV1` signed by this device for the chosen grant, shows it,
and signs on confirmation. After revoking itself, the device shows the
enrolment form again. The page re-checks its enrolment and device list every
30 seconds (10 while a request is pending). A revocation made elsewhere,
from another browser or `mix coop.revoke`, therefore disables its controls
without a reload.

## Verification

- `DeviceRevocationTest` (ledger, 12 tests):
  - labels are carried on grants;
  - revoking from another device, and a device revoking itself;
  - refusals: another principal's device, a revoked or wrong signing key,
    twice, unknown grants;
  - delegations end with the revoked grant;
  - governance still revokes anything;
  - `Devices`: the list, holder preparation, and the governance path.
  - Removing the same-principal check or the signing-grant check fails a
    test.
- The generated task histories now include devices retiring themselves.
  Every suggestion and delegation property holds over them, including "every
  task change traces to an active grant".
- `SpruceGoose.Web.RevocationTest` (5 tests):
  - the list and revocation over HTTP;
  - a device retiring itself;
  - refusals;
  - `mix coop.revoke --yes` against a running server;
  - an impostor governance key is refused;
  - the revoker refuses a revocation it was not shown.
- Node: the page signs only the command it was asked for.
- Browser (Chromium): after the device enrols and accepts a suggestion, it
  revokes itself. The ledger holds a `TaskDeviceRevokedV1` signed by the key
  the browser made, and its grant is inactive.

The Quint model of suggestions and delegations needs no change: its grants
already become inactive at arbitrary points, and who signs that does not
enter its properties.

## Limits

- Revocation is per grant. Revoking all of a person's devices at once, or
  across projects (offboarding), is one `coop.revoke` per grant for now.
- The unauthenticated `/api/v1/grants` and `/api/v1/enrolments` routes are
  bounded in memory and [rate-limited](2026-10-19-rate-limits.md) per client.
- A lost only device can only be revoked by an administrator. A person can
  enrol a new device first, then revoke the lost one themselves.
