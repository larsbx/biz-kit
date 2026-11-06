// proof_bank_core: "Generated candidate cannot promote its own proof, approval or
// extension activation".
// Abstracts ProofBankCore.compile/1: Schema.fields/2 refuses any candidate key
// outside the closed set (:unknown_fields), Schema.obligation/1 fixes every
// obligation's status to :unverified, and the blueprint's verification_state
// and activation_state are the constants :unverified and :inert, never copied
// from the candidate.
// Abstracted away: one candidate per compile; text, reference and identifier
// validation are omitted. A candidate may *claim* a proof, an approval and an
// activation (the self-promotion attempt). GUARDED switches off the closed-key
// check and the fixed outputs, so a compiler copies the candidate's claims.
module proof_bank_core_spec {
  const GUARDED: bool
  type Blueprint = { verified: bool, approved: bool, activated: bool }

  var blueprints: Set[Blueprint]
  var refusedClaims: int

  action init = all { blueprints' = Set(), refusedClaims' = 0 }

  action compile(claimsProof, claimsApproval, claimsActivation) = {
    val claims = claimsProof or claimsApproval or claimsActivation
    if (GUARDED)
      if (claims) all { refusedClaims' = refusedClaims + 1, blueprints' = blueprints }
      else all {
        blueprints' = blueprints.union(Set({ verified: false, approved: false, activated: false })),
        refusedClaims' = refusedClaims,
      }
    else all {
      blueprints' = blueprints.union(Set({ verified: claimsProof, approved: claimsApproval,
                                           activated: claimsActivation })),
      refusedClaims' = refusedClaims,
    }
  }

  action step =
    nondet p = Set(true, false).oneOf()
    nondet a = Set(true, false).oneOf()
    nondet x = Set(true, false).oneOf()
    compile(p, a, x)

  // Every compiled blueprint is unverified, unapproved and inert.
  val obligation = blueprints.forall(b => not(b.verified or b.approved or b.activated))
  // A blueprint compiled and a self-promoting candidate was refused.
  val obligationWitness = not(blueprints.size() > 0 and refusedClaims > 0)
}

module proof_bank_core { import proof_bank_core_spec(GUARDED = true).* }
module proof_bank_core_control { import proof_bank_core_spec(GUARDED = false).* }
