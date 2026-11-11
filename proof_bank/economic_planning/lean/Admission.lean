import Std

set_option warningAsError true

namespace EconomicPlanning.Admission

structure ReadGrant where
  principal : String
  scope : String
  source : String
  revision : String
  deriving DecidableEq

structure Epoch where
  number : Nat
  grants : List ReadGrant

def permits (current : Epoch) (requested : Nat) (read : ReadGrant) : Bool :=
  decide (requested = current.number) && current.grants.contains read

theorem permits_exact (current : Epoch) (requested : Nat) (read : ReadGrant) :
    permits current requested read = true ↔
      requested = current.number ∧ read ∈ current.grants := by
  simp [permits]

theorem stale_epoch_denies (old current : Epoch) (read : ReadGrant)
    (advanced : old.number < current.number) :
    permits current old.number read = false := by
  simp [permits, Nat.ne_of_lt advanced]

theorem revoked_grant_denies (current : Epoch) (read : ReadGrant)
    (absent : read ∉ current.grants) :
    permits current current.number read = false := by
  simp [permits, absent]

theorem complete_reads_exact (current : Epoch) (requested : Nat)
    (reads : List ReadGrant)
    (checked : reads.all (permits current requested) = true) :
    ∀ read ∈ reads, requested = current.number ∧ read ∈ current.grants := by
  intro read member
  exact (permits_exact current requested read).mp (List.all_eq_true.mp checked read member)

end EconomicPlanning.Admission

#print axioms EconomicPlanning.Admission.permits_exact
#print axioms EconomicPlanning.Admission.stale_epoch_denies
#print axioms EconomicPlanning.Admission.revoked_grant_denies
#print axioms EconomicPlanning.Admission.complete_reads_exact
