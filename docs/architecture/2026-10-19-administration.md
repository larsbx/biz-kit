# Administration in the view

Date: 2026-10-19. Status: **implemented**. Decided 2026-10-19: a CLI is not
the surface for people; it stays only where a script or agent needs one.
Until now every governance act (approving an enrolment, revoking a device,
offboarding, cancelling a task) was a `mix` task signed with the governance
seed on an administrator's machine.

## Decision

An administrator's **browser holds a governance key**, a non-extractable
WebCrypto Ed25519 key like any device's, and acts from the web view. The
ledger is unchanged in kind: a governance key is a `RoleKeyDeclared` key of
the chapter, and every act is the same signed command, sent to the same
endpoints a script would use. The server signs nothing.

| | Holds | Can |
| --- | --- | --- |
| the seed holder | the genesis governance seed (`HARNESS_KEYS_DIR`) | approve the first administrator (`mix coop.enrol`) |
| an administrator's browser | a governance key declared for its person | everything below, and approve further administrators |
| the ledger | the role keys and who each names | decide |

## Becoming an administrator

The browser asks like a device ([device enrolment](2026-10-19-device-enrolment.md)),
with the role **administrator** (`governance`). Approval appends a
`RoleKeyDeclared` for the chapter: role `governance`, the browser's key, and
`member_id` naming the person's principal. The approver's tool or page signs
it only if it is exactly that (`Approver.grants?/2`, `grantFor` in the page).

- **The first administrator** is approved by the seed holder with
  `mix coop.enrol <CODE>`, once. That is the bootstrap.
- **After that**, any administrator approves requests in the view: devices,
  reviewers and other administrators.

The membership projection now records who each role key was declared for
(`role_key_members`). A person is an administrator of a chapter while a
governance key declared for them is still declared.

## What an administrator does in the view

The **Administration** section shows only in a browser whose key is a
governance key of the project's chapter, declared for the signed-in person:

| Act | Endpoint (as for any key holder) | Command signed |
| --- | --- | --- |
| Approve a request by its code | `GET`/`POST /api/v1/enrolments/:code[/approval[/:id]]` | the operator or reviewer grant, or the governance key declaration |
| Look up a person in this project | `GET /api/v1/principals/:id` (signed read) | — |
| Revoke one of their devices | `POST /api/v1/grants/:id/revocation[/:held]` | `TaskOperatorRevokedV1` or `TaskReviewerRevokedV1` |
| Offboard them from this project | `POST /api/v1/principals/:id/offboarding[/:held]` (signed) | `TaskPrincipalOffboardedV1` |
| Cancel any task short of completed | `POST …/tasks/:id/cancellation[/:held]` (signed) | `TaskCancelledByGovernanceV1` |
| List and revoke administrators | `GET`/`POST /api/v1/chapters/:c/administrators[/:key_id/revocation[/:held]]` (signed) | `RoleKeyRevoked` |

Each goes through the usual decode, check and confirm, more strictly: the
page signs a governance command only if its **whole payload** is exactly the
one shown, for this chapter (`exact`), since these grant and end access.

**Signed reads.** The routes that show only governance what they hold need a
request signed by the key (`Governance.Read`). The page builds it itself:
`cbor.js` now has a canonical encoder, checked against the ledger's own
test vectors, and the page's encoding of a read is checked byte for byte
against `Read.signing_bytes/1`.

**Reading the project.** A person holding a governance key of the chapter
reads every project's feed in it as an administrator, while the key stays
declared (`Feed.Access.for_administrator/3`); revoking the key ends the
stream, as revoking a grant does.

## Administrators of a chapter

```
GET  /api/v1/chapters/:chapter_id/administrators                     → [{key_id, principal_id}]
POST /api/v1/chapters/:chapter_id/administrators/:key_id/revocation  {"governance_key_id", "reason"}
POST …/revocation/:held_id                                           {"signature"}
```

The first two are signed reads by a governance key of that chapter. Any
administrator revokes any other, or their own browser's key; the ledger
refuses to revoke the chapter's last governance key
(`cannot_orphan_governance`).

## CLIs

`mix coop.cancel` is gone; cancelling is in the view. `coop.enrol` stays for
the bootstrap. `coop.revoke` and `coop.offboard` stay as scripted
equivalents of the view, on the same endpoints.

## Verification

- **`EnrolmentsTest`:**
  - an administrator request yields exactly the `RoleKeyDeclared` for the
    person, and the browser's key then approves another request;
  - the approval check refuses another person, role or chapter;
  - administrators revoke each other, never the last key;
  - an administrator reads every project of its chapter, not another
    chapter's, and its stream ends when the key is revoked.
- **`SpruceGoose.Web.AdministrationTest`:**
  - the seed holder approves the first administrator with
    `mix coop.enrol`;
  - its key lists administrators, offboards someone and revokes the seed's
    key over the signed endpoints, and cannot revoke the last key;
  - unsigned requests, or ones signed by another chapter's key, are
    refused.
- **Node:**
  - the canonical encoder reproduces every ledger test vector;
  - a governance read is byte for byte the server's;
  - `grantFor` builds each role's grant;
  - an extra payload field or another chapter is refused.
- **Browser (Chromium):** a third browser asks to administer the chapter
  and the seed holder approves it. In the view, the administrator:
  1. approves the reviewer's code;
  2. cancels a task as an administrator;
  3. offboards the reviewer from the project.

  The ledger holds each act signed by the administrator's browser key.
- **Mutation:** if the server prepares the reviewer grant with another label,
  the administrator's page refuses to sign and the browser test fails.

## Limits

- An administrator's key is per browser and per chapter; a person with
  several browsers enrols each.
- The page acts on the project it is opened for; the chapter's other
  projects are reached by opening them.
- Offboarding a person does not revoke their administrator keys; revoke
  those under *Administrators of this chapter*.
- The genesis seed remains the root of trust; publishing its checkpoint
  out of band, as before, is what anchors it.
