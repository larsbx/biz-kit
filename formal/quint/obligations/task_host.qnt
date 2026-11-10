// task_host: "The host appends a held command only with its owner's signature
// over exactly the bytes held, once, before the hold expires".
//
// Rule modelled: CoopSubstrate.Commands (prepare/hold, then submit), which
// every TaskHost.Web controller uses: the envelope is built and held for an
// owner (a principal, or an enrolment code or grant for a governance
// approval); submit attaches the owner's signature, which must verify under
// the owner's key over the held signing bytes; a hold is single-use and
// expires after five minutes. The host holds no key and cannot sign. Tested
// by TaskHost.Web.CommandTest, DeviceTest, RevocationTest and
// ProjectOwnershipTest ("wrong signatures without any partial append").
// Abstracted: two holds, two owners, two possible byte strings; a signature is
// modelled as the (signer, bytes) it covers.
module task_host_spec {
  const GUARDED: bool
  val Ids = Set(0, 1)
  val Owners = Set("alice", "bob")
  val Bytes = Set("x", "y")

  var held: int -> { owner: str, bytes: str, spent: bool, expired: bool, live: bool }
  var appended: int        // commands appended
  var forged: bool         // ghost: an append without the owner's signature over the held bytes
  var replayed: bool       // ghost: a hold appended twice, or after it expired
  var refused: bool

  action init = all {
    held' = Ids.mapBy(_ => { owner: "alice", bytes: "x", spent: false, expired: false, live: false }),
    appended' = 0, forged' = false, replayed' = false, refused' = false,
  }

  action prepare(i: int, o: str, b: str): bool = all {
    not(held.get(i).live),
    held' = held.set(i, { owner: o, bytes: b, spent: false, expired: false, live: true }),
    appended' = appended, forged' = forged, replayed' = replayed, refused' = refused,
  }

  action expire(i: int): bool = all {
    held.get(i).live,
    held' = held.set(i, held.get(i).with("expired", true)),
    appended' = appended, forged' = forged, replayed' = replayed, refused' = refused,
  }

  // A submission: `signer` signed `b`, presented for hold `i`.
  action submit(i: int, signer: str, b: str): bool = {
    val h = held.get(i)
    val valid = h.live and not(h.spent) and not(h.expired) and signer == h.owner and b == h.bytes
    all {
      h.live,
      if (valid or not(GUARDED)) all {
        held' = held.set(i, h.with("spent", true)),
        appended' = appended + 1,
        forged' = (forged or signer != h.owner or b != h.bytes),
        replayed' = (replayed or h.spent or h.expired),
        refused' = refused,
      } else all {
        held' = held, appended' = appended, forged' = forged, replayed' = replayed,
        refused' = true,
      },
    }
  }

  action step = any {
    nondet i = Ids.oneOf()
    nondet o = Owners.oneOf()
    nondet b = Bytes.oneOf()
    any { prepare(i, o, b), expire(i), submit(i, o, b) },
  }

  // Nothing appended without its owner's signature over the held bytes, and
  // no hold appended twice or after expiry.
  val obligation = not(forged) and not(replayed)
  // A command was appended, and another submission was refused.
  val obligationWitness = not(appended > 0 and refused)
}
module task_host { import task_host_spec(GUARDED = true).* }
module task_host_control { import task_host_spec(GUARDED = false).* }
