import ResearchExchange.Reward
import ResearchExchange.Reservation

/-
Small positive controls, evaluated by the kernel-backed `decide` tactic.
These executable examples supplement the universally quantified theorems;
they are not substitutes for them.
-/

namespace ResearchExchange.Examples

def config : Reward.Config :=
  { expected := ⟨1, 2, 3, 4⟩, reward := 5, workerA := 10, workerB := 20 }

def evidence : Candidate := ⟨10, 1, config.expected, 9, 0, 2⟩

def leased : Reward.State := Reward.lease config (Reward.initial config 7 0 0) 10 2

def admitted : Reward.State := Reward.submit config leased 10 1 config.expected 9

def delayed : Reward.State := Reward.tick admitted 100

def paid : Reward.State := Reward.accept config delayed true evidence

example : admitted.candidate = some evidence := by decide

example : delayed.expires < delayed.now ∧ paid.phase = .accepted ∧ paid.payouts = 1 := by
  decide

example : paid.balanceA = 5 ∧ paid.balanceB = 0 ∧ paid.escrow = 0 ∧ Reward.total paid = 12 := by
  decide

example : Reward.accept config paid true evidence = paid := by decide

example : Reward.accept config delayed false evidence = delayed := by decide

example : Reward.submit config leased 10 0 config.expected 9 = leased := by decide

def reserved : Reservation.State := Reservation.reserve (Reservation.initial 10) 5
def running : Reservation.State := Reservation.start reserved
def cancelling : Reservation.State := Reservation.cancel running
def stopped : Reservation.State := Reservation.stop cancelling true
def settled : Reservation.State := Reservation.settle stopped 3

example : cancelling.phase = .cancelling ∧ cancelling.available = 5 ∧ cancelling.held = 5 := by
  decide

example : Reservation.settle cancelling 0 = cancelling := by decide

example : Reservation.stop cancelling false = cancelling := by decide

example : settled.phase = .settled ∧ settled.available = 7 ∧ settled.held = 0 ∧
    settled.spent = 3 ∧ Reservation.total settled = 10 := by
  decide

example : Reservation.settle settled 0 = settled := by decide

example : (Reservation.settle (Reservation.cancel reserved) 0).available = 10 := by decide

end ResearchExchange.Examples
