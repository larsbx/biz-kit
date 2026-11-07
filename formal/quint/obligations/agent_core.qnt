// agent_core: "Only current approved profile revisions may launch runs".
// Abstracts AgentCore.Profiles.resolve/3 (called by AgentCore.Preflight.prepare/4
// before AgentCore.ExecutionPort.launch/3): a run pins execution_profile_id and
// execution_profile_digest; resolve requires the registry profile to be
// approved (approved/2, else :execution_profile_not_approved) and the digest of
// its CURRENT manifest to equal the pinned digest (else
// :execution_profile_digest_mismatch).
// Abstracted away: one profile id; a digest is the manifest revision 0..2;
// hashing, adapter and capability checks are omitted. GUARDED switches off the
// approval and digest checks.
module agent_core_spec {
  const GUARDED: bool
  type Launch = { pinned: int, current: int, approved: bool }

  var revision: int
  var approved: bool
  var launches: Set[Launch]
  var refused: bool

  action init = all {
    revision' = 0, approved' = false, launches' = Set(), refused' = false,
  }

  action revise = all {
    revision < 2, revision' = revision + 1,
    approved' = approved, launches' = launches, refused' = refused,
  }

  action setApproval(b) = all {
    approved' = b, revision' = revision, launches' = launches, refused' = refused,
  }

  action launch(pinned) = {
    val ok = approved and pinned == revision
    all {
      revision' = revision, approved' = approved,
      if (ok or not(GUARDED)) all {
        launches' = launches.union(Set({ pinned: pinned, current: revision, approved: approved })),
        refused' = refused,
      } else all { launches' = launches, refused' = true },
    }
  }

  action step = any {
    revise,
    nondet b = Set(true, false).oneOf() setApproval(b),
    nondet p = 0.to(2).oneOf() launch(p),
  }

  // Every launch ran the profile revision that was current and approved.
  val obligation = launches.forall(l => l.approved and l.pinned == l.current)
  // A revised profile was launched after some launch request was refused.
  val obligationWitness = not(refused and launches.exists(l => l.pinned > 0))
}

module agent_core { import agent_core_spec(GUARDED = true).* }
module agent_core_control { import agent_core_spec(GUARDED = false).* }
