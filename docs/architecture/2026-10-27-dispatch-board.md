# The dispatch board: a carrier dispatches its own work

Date: 2026-10-27. Status: **implemented** in `Dispatch.Operations.Board`,
`DispatchWeb.OperationsController` (`/v1/operations`) and the desktop app's
Dispatch panel.

## Why

Dispatch could hold loads, stops and trips, but nobody could make one. The
Dispatcher's capabilities in Section 23.2 are reads, non-binding edits and
proposals, and proposals are not built. Loads and trips existed only because
seed scripts wrote them with authorization off. A carrier could not run its own
day.

## Decision

The owner decided to extend the Dispatcher beyond the specification's
capability table with six organization-scoped capabilities
(`Dispatch.Access.Capabilities`, the `@dispatching` group):

| Capability | Lets a dispatcher |
| --- | --- |
| `load.create` | create a `DRAFT` load with its own organization as the carrier |
| `stop.add` | append a stop to one of its loads |
| `assignment.read` | read every trip on its loads, not only its own |
| `assignment.plan` | plan a trip with one of its drivers, vehicles and trailers |
| `assignment.update.status` | activate, complete or cancel one of its trips |
| `fleet.read` | list its active drivers, vehicles and trailers |

What stays out, as Section 23.2 requires: nothing here sets a rate, names a
broker, accepts a load, or binds another organization. A load's carrier is the
actor's organization and is never a parameter. The negotiated rate is not
readable through the board.

`Dispatch.Access.SeedManifest` grants them to `DISPATCHER`. Its test keeps the
Section 23.2 table as an independent transcription and lists the extension
apart from it, so the table can still be checked against the specification.

## How it holds

- **Organization, not party rows.** Every read and write is confined to the
  actor's role assignment's organization: a load when it is the carrier, a
  driver, vehicle or trailer when it belongs to it. Anything else answers
  `404`, so the board discloses nothing about another carrier's work.
- **One transaction per write, with its audit event** (`load.created`,
  `load.updated`, `stop.added`, `assignment.planned`, `assignment.activated`,
  `assignment.completed`, `assignment.cancelled`).
- **Versions.** Edits and transitions take `expected_version`; a stale one is a
  `409 STALE_VERSION`.
- **Idempotency.** Every write honours `Idempotency-Key` (Section 24).
- **Exclusivity is derived.** Planning passes the driver's own role assignment,
  so `DeriveOperatorExclusivity` decides the one-active-trip rule from the
  profile and the partial index enforces it. A dispatcher cannot opt a driver
  out of it.
- **Stop order is serialized** per load with an advisory lock, so two stops
  added at once cannot take the same sequence number.

## Limits

- No vehicle or trailer registration over the API yet; the seeds create none.
- Load status (`TENDERED`, `BOOKED`, …) is not moved by the board. Trip status
  is.
- Every write records the actor's role assignment, but `assignment.read` is not
  narrowed by `active_assignment_only` the way `operations.participant.read` is.
