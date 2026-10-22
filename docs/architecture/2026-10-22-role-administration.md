# Role administration: an administrator grants and revokes, after a recent sign-in

Date: 2026-10-22. Status: **implemented** in `Dispatch.Accounts.Administration`,
`DispatchWeb.SettingsController` (`/settings/users`) and
`BizKit.Identity.Sessions` (`authenticated_at`). d-patch's scenario 15 runs
against it end to end.

## Why

d-patch's specification gives `ADMIN` the `/settings` surface for role
assignments (§4.3) and sets the rules for changing them (§23.3): recent
step-up authentication and an idempotency key on every change; no one creates,
expands or reactivates their own assignment; the tenant's last administrator
stays; nothing is assigned that the role definition does not carry; and
administration confers no operational sight. Dispatch had `:grant` and
`:revoke` actions and nothing that let a person use them.

## Decision

**Step-up is a recent sign-in.** Every biz-kit session now records when the
person signed in (`authenticated_at`), and a native session's store keeps it
across restarts. Dispatch's verifiers pass it on: biz-kit's session directly,
an OIDC token through `auth_time`. The portal keeps it in the encrypted session
at sign-in. A role change is accepted only within five minutes of it;
otherwise the page asks the administrator to sign in again. A session lasting
until sign-out says nothing about how recently it was earned, so the session's
existence is never taken as recency.

**The rules live in one module.** `Administration.grant/3` and `revoke/4`
check, in order: the actor's assignment carries `role_assignment.manage`
(otherwise `:not_found`, as for any page it does not open); the recent sign-in;
the target is in the actor's organization; it is not the actor; the
definition is active and `SELF`- or `ORGANIZATION`-scoped (a `LOAD` or `STOP`
grant needs its party row, which belongs with the load or stop); and, to
revoke, the version the page showed and that it is not the organization's last
assignment carrying `role_assignment.manage`. Each change is audited.

**One organization's changes are serialized** by a transaction-scoped advisory
lock, so two administrators revoking each other at once cannot leave none.

**The page is transport.** Each form carries its CSRF token and an idempotency
key made when the page is drawn; `Dispatch.Idempotency` answers a resubmitted
form once. A profile's scope is declared by its module (`scope_type/0`) and a
test holds the seeded manifests to it.

## Rejected alternatives

- **Passkey (WebAuthn) step-up.** Stronger, and break-glass will need it, but
  a new surface of its own; a fresh sign-in works with every provider today.
- **Trusting the provider's `auth_time` alone.** Not every provider sends it,
  and the development provider would have to fake it.
- **Taking the session's age as recency.** A native session lasts until
  sign-out; its age measures nothing.

## Limits

- Grants are whole, unscoped role definitions. `LOAD` and `STOP` grants arrive
  with the partner surfaces (d-patch scenarios 17–19).
- Memberships, integrations, retention and audit settings are not built.

## Verification

`test/dispatch/accounts/administration_test.exs` (each rule, with
mutation checks), `test/dispatch_web/settings_controller_test.exs` (the browser
path, step-up, idempotency, scenario 15), biz-kit identity's durable-session
tests (`authenticated_at` across a restart), and d-patch's Playwright scenario
15 against `scripts/e2e-stack.sh`.
