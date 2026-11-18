// coop_substrate: "Accepted append always binds canonical bytes, authorization,
// scope and replay identity."
//
// Models CoopSubstrate.Log.handle_call({:append, ...}) (apps/coop_substrate/lib/
// coop_substrate/log.ex): verify_batch/1 (Envelope.verify/1: every declared
// signer signed the canonical signing bytes; batch event IDs unique),
// duplicate/2 (a replayed event ID returns the earlier result and appends
// nothing), verify_validity/2 (TypeRegistry.validity_check/2 against the gate:
// authorization and scope), then assign_chains/2 (stream_id derived from type,
// chapter and payload; sequence and previous-hash links).
// Abstracted: crypto as a boolean, the gate as a boolean, a hash as an integer,
// one envelope per batch, one stream. GUARDED switches off the three checks.
module coop_substrate_spec {
  const GUARDED: bool

  type Entry = { id: int, signed: bool, authorized: bool, derivedStream: bool,
               seq: int, prev: int, hash: int }

  var log: List[Entry]

  pure val IDS = 1.to(3)

  action init = log' = []

  pure def hashOf(id: int, seq: int, prev: int): int = id * 100 + seq * 10 + prev % 10

  action admit(id: int, signed: bool, authorized: bool): bool = {
    val seen = log.indices().exists(i => log[i].id == id)
    val accept = not(GUARDED) or (signed and authorized and not(seen))
    val prev = if (log.length() == 0) 0 else log[log.length() - 1].hash
    val seq = log.length() + 1
    if (accept)
      log' = log.append({ id: id, signed: signed, authorized: authorized, derivedStream: true,
                          seq: seq, prev: prev, hash: hashOf(id, seq, prev) })
    else log' = log
  }

  action step = nondet id = IDS.oneOf()
    nondet signed = Set(true, false).oneOf()
    nondet authorized = Set(true, false).oneOf()
    admit(id, signed, authorized)

  // Every accepted record carries verified canonical bytes, an authorized
  // scope, a derived stream, a unique replay identity and an unbroken chain.
  val obligation = log.indices().forall(i => all {
    log[i].signed, log[i].authorized, log[i].derivedStream,
    log[i].seq == i + 1,
    log[i].prev == (if (i == 0) 0 else log[i - 1].hash),
    log.indices().forall(j => j != i implies log[j].id != log[i].id),
  })

  // Two records chained: a real append history exists.
  val obligationWitness = log.length() < 2
}

module coop_substrate {
  import coop_substrate_spec(GUARDED = true).*
}

module coop_substrate_control {
  import coop_substrate_spec(GUARDED = false).*
}
