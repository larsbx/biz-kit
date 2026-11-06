// biz_kit_identity: "Revoked principal cannot act through persisted sessions".
//
// Rule modelled: BizKit.Identity.Sessions (sessions.ex). A native session lives in
// the ETS cache and in the durable SessionStore. A cache miss is a three-step
// restore: `{:fetch, ..}` hands out a ticket (the server state, a ref that every
// revocation replaces with make_ref()); the caller reads SessionStore outside
// the server; `{:restore, ticket, row}` re-inserts the row only if the ticket
// still equals the server state. `revoke_principal` deletes the durable rows and
// the cache rows and replaces the state. GUARDED is that ticket comparison.
// Abstracted: one principal, one native session, the ref as a counter, no TTL
// (native sessions never expire), no re-login (a new login is a new session).
module biz_kit_identity_spec {
  const GUARDED: bool
  var durable: bool        // row in SessionStore
  var cached: bool         // row in the ETS table
  var epoch: int           // server state ref; replaced on every revocation
  var ticket: int          // -1: no restore in flight
  var readRow: bool        // what the in-flight restore read from SessionStore
  var readDone: bool
  var revoked: bool
  var actedAfterRevocation: bool
  var restored: bool       // a restore re-inserted the row at least once

  action init = all {
    durable' = true, cached' = true, epoch' = 0, ticket' = -1, readRow' = false,
    readDone' = false, revoked' = false, actedAfterRevocation' = false, restored' = false,
  }
  // Cache rows can be lost on a process restart or node move.
  action evict = all { cached, cached' = false, durable' = durable, epoch' = epoch,
    ticket' = ticket, readRow' = readRow, readDone' = readDone, revoked' = revoked,
    actedAfterRevocation' = actedAfterRevocation, restored' = restored }
  // fetch hit: the session acts.
  action act = all { cached, actedAfterRevocation' = (actedAfterRevocation or revoked),
    durable' = durable, cached' = cached, epoch' = epoch, ticket' = ticket,
    readRow' = readRow, readDone' = readDone, revoked' = revoked, restored' = restored }
  action beginRestore = all { not(cached), ticket == -1, ticket' = epoch, readDone' = false,
    durable' = durable, cached' = cached, epoch' = epoch, readRow' = readRow,
    revoked' = revoked, actedAfterRevocation' = actedAfterRevocation, restored' = restored }
  action readStore = all { ticket != -1, not(readDone), readRow' = durable, readDone' = true,
    durable' = durable, cached' = cached, epoch' = epoch, ticket' = ticket,
    revoked' = revoked, actedAfterRevocation' = actedAfterRevocation, restored' = restored }
  def admits(t: int, e: int, row: bool): bool = row and (not(GUARDED) or t == e)
  action finishRestore = all { ticket != -1, readDone,
    cached' = (cached or admits(ticket, epoch, readRow)),
    restored' = (restored or admits(ticket, epoch, readRow)), ticket' = -1,
    readDone' = false, durable' = durable, epoch' = epoch, readRow' = readRow,
    revoked' = revoked, actedAfterRevocation' = actedAfterRevocation }
  action revokePrincipal = all { durable' = false, cached' = false, epoch' = epoch + 1,
    revoked' = true, ticket' = ticket, readRow' = readRow, readDone' = readDone,
    actedAfterRevocation' = actedAfterRevocation, restored' = restored }
  action step = any { evict, act, beginRestore, readStore, finishRestore,
    all { epoch < 2, revokePrincipal } }

  val obligation = not(actedAfterRevocation)
  // A restore that read the row before a revocation is pending after it.
  val obligationWitness = not(revoked and readDone and readRow)
}
module biz_kit_identity { import biz_kit_identity_spec(GUARDED = true).* }
module biz_kit_identity_control { import biz_kit_identity_spec(GUARDED = false).* }
