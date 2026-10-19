# Revoking one's own devices, of every kind

Date: 2026-10-19. Status: **implemented**. Extends
[device revocation](2026-10-19-device-revocation.md), which let a person
revoke only their operator devices. A reviewer device
([execution](2026-10-19-execution.md)) or an administrator's browser
([administration](2026-10-19-administration.md)) could only be revoked by an
administrator, so a lost one stayed live until someone else acted.

## Decision

A person's **devices** are everything that names them and a key they hold:

| Kind | What it is | `id` |
| --- | --- | --- |
| operator | an active `TaskOperatorGrantedV1` in the project | the grant's event ID |
| reviewer | an active `TaskReviewerGrantedV1` in the project | the grant's event ID |
| administrator | a governance key of the chapter declared for them (`member_id`) | the key ID |

Any of them revokes any grant of theirs, or itself; an administrator key is
revoked from an administrator browser of theirs, itself included. The
command is the one the signing device's role signs:

| Signed from | Revoking a grant | Revoking an administrator key |
| --- | --- | --- |
| an operator device | `TaskDeviceRevokedV1` | not allowed (`needs_administrator`) |
| a reviewer device | `TaskReviewerDeviceRevokedV1` (new, same payload) | not allowed |
| an administrator browser | `TaskOperatorRevokedV1` / `TaskReviewerRevokedV1` | `RoleKeyRevoked` |

**Why not an administrator key from any device.** A chapter's governance
keys are derived from its governance history alone, also offline, when an
exported bundle is verified (`Export.derive_role_keys/2`): every declaration
and revocation there is governance-signed. A revocation signed by an
operator or reviewer device lives in the project's stream and could not be
checked from that history, so an export would still trust the revoked key.
A person with no administrator browser left asks another administrator, who
revokes the key from *Administrators of this chapter*.

A key that holds several roles signs as an operator device, else as a
reviewer device, else as an administrator, except for an administrator key,
which it revokes as an administrator. The page works this out the same way
(`ownRevocation` in `view.js`) and signs only that command.

## Rules (`Tasks`, holder revocation)

`TaskDeviceRevokedV1` and `TaskReviewerDeviceRevokedV1` share one rule:

1. **The signing device** is the holder's active operator grant (or reviewer
   grant, for the reviewer form) in the project, signed with its own key.
2. **The target** (`revoked_grant_event_id`) is an operator or reviewer
   grant in the project, of the same principal (`not_own_device`), still
   active (`grant_already_revoked`).

The fold deactivates the grant; a feed read by that device ends there. An
administrator key revoked by `RoleKeyRevoked` ends that person's
administrator reads, as before.

As before, this is safe because revocation only removes authority: a holder
can end only their own devices, and someone with a stolen device could
already act as them.

## HTTP and the view

```
GET  …/devices                      → [{id, kind, grant_id, key_id, label}]
POST …/devices/:id/revocation       {"key_id"} → the revocation to sign
```

*Your devices in this project* lists all three kinds, each with what it does
(decides, reviews, administers the chapter) and **Revoke**, from whichever
role this browser holds.

## Verification

- **`OwnDevicesTest`:**
  - the list of all three kinds;
  - a reviewer device revoking itself and the operator device;
  - an operator device revoking the reviewer device, and refused the
    administrator key (`needs_administrator`);
  - an administrator browser giving up its key, after which its feed access
    is gone, and revoking all three kinds with governance commands;
  - refusals: another's device (also forged directly), an unenrolled key,
    the chapter's last key.
- **`RevocationTest`** over HTTP: a reviewer device revokes itself; an
  operator device is refused the administrator key, which the administrator
  browser then gives up itself.
- **Node:** the command each role signs for each kind.
- **Browser (Chromium):** the administrator's browser gives up its own key
  from its device list, and its Administration section goes.
