import Proofs
import Lean

/-! Audit every compiled declaration in the kernel namespace. User theorem
inventory is marked separately from generated declarations, but both are checked
for unexpected axioms. The runner compares user theorem names with its registry. -/
open Lean in
run_cmd do
  let env ← getEnv
  let some proofsModule := env.getModuleIdx? `Proofs
    | throwError "missing compiled economic planning proofs"
  let allowed := #[`propext, `Classical.choice, `Quot.sound]
  let mut declarations : Nat := 0
  let mut theorems : Nat := 0
  let entries := env.constants.toList.mergeSort fun a b => a.1.toString < b.1.toString
  for (name, info) in entries do
    if "EconomicPlanning.".isPrefixOf name.toString then
      let axioms ← collectAxioms name
      let kind := match info with
        | .thmInfo _ =>
          if env.getModuleIdxFor? name == some proofsModule && name.getPrefix == `EconomicPlanning
          then "theorem" else "generated"
        | .axiomInfo _ => "axiom"
        | _ => "declaration"
      logInfo m!"DECL {name} {kind}"
      logInfo m!"AXIOMS {name} [{String.intercalate "," (axioms.toList.map Name.toString)}]"
      unless axioms.all allowed.contains do
        throwError "unexpected axioms in {name}: {axioms.toList}"
      if kind == "axiom" then
        throwError "custom axiom in kernel namespace: {name}"
      declarations := declarations + 1
      if kind == "theorem" then theorems := theorems + 1
  if declarations == 0 || theorems == 0 then
    throwError "empty economic planning inventory"
  logInfo m!"AUDIT_DECLARATIONS {declarations}"
  logInfo m!"AUDIT_THEOREMS {theorems}"
