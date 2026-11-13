import BizKitCommercialSetoff
import Lean

open BizKitCommercialSetoff

-- Exercise the imported instance and transition independently of their proofs.
private def intent : IntentKey := (0, 1)
private def nextIntent : IntentKey := (0, 2)
private def left : SourceKey := (0, 7)
private def right : SourceKey := (1, 7)
private def other : SourceKey := (0, 8)
private def unrelated : SourceKey := (0, 9)

private def accepted : State := admit initial intent left right true
private def observe (s : State) :=
  (s.commits, s.consumed left, s.consumed right, s.consumed other,
    s.consumed unrelated, s.intents intent, s.intents nextIntent)

#guard decide (Ready initial intent left right true)
#guard observe accepted == (1, true, true, false, false, true, false)
#guard observe (admit initial intent left right false) == observe initial
#guard observe (admit initial intent left left true) == observe initial
#guard observe (admit accepted intent left right true) == observe accepted
#guard observe (admit accepted nextIntent left other true) == observe accepted
#guard observe (admit accepted nextIntent other right true) == observe accepted

-- Test the intent fence without a competing consumed source.
#guard observe (admit accepted intent other unrelated true) == observe accepted
#guard (admit accepted nextIntent other unrelated true).commits == 2

open Lean in
run_cmd do
  let env ← getEnv
  let some moduleIdx := env.getModuleIdx? `BizKitCommercialSetoff
    | throwError "missing compiled source-fence module"
  let allowed := #[`propext, `Classical.choice, `Quot.sound]
  let mut count : Nat := 0
  for (name, _) in env.constants.toList do
    if env.getModuleIdxFor? name == some moduleIdx then
      let axioms ← collectAxioms name
      logInfo m!"{name}: {axioms.toList}"
      unless axioms.all allowed.contains do
        throwError "unexpected axioms in {name}: {axioms.toList}"
      count := count + 1
  if count == 0 then
    throwError "empty compiled source-fence inventory"
  logInfo m!"Audited {count} compiled source-fence declarations and passed nine executable checks"
