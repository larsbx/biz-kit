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

Any of them revokes any other, or itself. The command is the one the
signing device's role signs:

| Signed from | Revoking a grant | Revoking an administrator key |
| --- | --- | --- |
| an operator device | `TaskDeviceRevokedV1` (`revoked_grant_event_id`) | `TaskDeviceRevokedV1` (`revoked_key_id`) |
| a reviewer device | `TaskReviewerDeviceRevokedV1` (new, same payload) | `TaskReviewerDeviceRevokedV1` |
| an administrator browser | `TaskOperatorRevokedV1` / `TaskReviewerRevokedV1` | `RoleKeyRevoked` |

A key that holds several roles signs as an operator device, else as a
reviewer device, else as an administrator; the page works this out the same
way (`ownRevocation` in `view.js`) and signs only that command.

## Rules (`Tasks`, holder revocation)

`TaskDeviceRevokedV1` and `TaskReviewerDeviceRevokedV1` share one rule:

1. **The signing device** is the holder's active operator grant (or reviewer
   grant, for the reviewer form) in the project, signed with its own key.
2. **The target** is exactly one of:
   - `revoked_grant_event_id`: an operator or reviewer grant in the project,
     of the same principal (`not_own_device`), still active
     (`grant_already_revoked`);
   - `revoked_key_id`: a governance key of the chapter declared for the same
     principal (`not_own_device`), never the chapter's last
     (`cannot_orphan_governance`).

   Both or neither: `invalid_revocation_target`.

The fold deactivates the grant, or removes the key from the chapter's role
keys (the membership projection), as `RoleKeyRevoked` would. A feed read by
that device, or as that administrator, ends there.

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
  - an operator device revoking the reviewer device and the administrator
    key, after which the administrator's feed access is gone;
  - an administrator browser revoking all three with governance commands;
  - refusals: another's device, an unenrolled key, someone else's key,
    both targets or none, the chapter's last key.
- **`RevocationTest`** over HTTP: a reviewer device revokes itself, and an
  operator device revokes the person's administrator key.
- **Node:** the command each role signs for each kind.
- **Browser (Chromium):** the administrator's browser gives up its own key
  from its device list, and its Administration section goes.
