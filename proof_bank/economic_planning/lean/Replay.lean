import EconomicPlanning

/-!
Replay accepts an ordered action list under one frozen context. A rejection has
no successful result; callers cannot supply an opening planning state through
`replay`. Source authentication and concrete decoding remain host obligations.
-/
namespace EconomicPlanning

/-- Internal continuation over a known state; external adapters use `replay`. -/
def replayFrom (ctx : Context) : State → List Action → Option State
  | s, [] => some s
  | s, action :: rest => (step ctx s action).bind fun next => replayFrom ctx next rest

/-- The only opening state is the kernel's empty state and a host-owned token. -/
def replay (ctx : Context) (operationalToken : String) (actions : List Action) : Option State :=
  replayFrom ctx (initial operationalToken) actions

end EconomicPlanning
