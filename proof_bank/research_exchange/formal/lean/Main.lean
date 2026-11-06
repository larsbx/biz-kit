import ResearchExchange
import Lean.Data.Json

/-
Finite trace adapter for the executable functions proved in ResearchExchange.
The JSON decoder, compiler, IO runtime, and this adapter are tested separately;
they are not part of the universal safety theorem statements.
-/

open Lean

namespace ResearchExchange.Trace

namespace Parser

open Std.Internal.Parsec Std.Internal.Parsec.String

/- Use Lean's JSON string decoder while rejecting duplicate fields and all
   numeric forms outside the protocol's nonnegative integer domain. -/
mutual
  partial def value : Parser Json := do
    let c ← peek!
    if c == '{' then
      skip
      ws
      if (← peek!) == '}' then
        skip
        ws
        return Json.mkObj []
      object []
    else if c == '[' then
      skip
      ws
      if (← peek!) == ']' then
        skip
        ws
        return Json.arr #[]
      array #[]
    else if c == '"' then
      skip
      let s ← Lean.Json.Parser.str
      ws
      return Json.str s
    else if c == 't' then
      skipString "true"
      ws
      return Json.bool true
    else if c == 'f' then
      skipString "false"
      ws
      return Json.bool false
    else if c == 'n' then
      skipString "null"
      ws
      return Json.null
    else if '0' ≤ c && c ≤ '9' then
      let n ← Lean.Json.Parser.nat
      if !(← isEof) then
        let next ← peek!
        if next == '.' || next == 'e' || next == 'E' then
          fail "expected a nonnegative JSON integer"
      ws
      return toJson n
    else
      fail "unexpected JSON value or non-integer number"

  partial def object (fields : List (String × Json)) : Parser Json := do
    Lean.Json.Parser.lookahead (fun c => c == '"') "object key"
    skip
    let key ← Lean.Json.Parser.str
    if fields.any (fun field => field.1 == key) then
      fail s!"duplicate JSON key: {key}"
    ws
    Lean.Json.Parser.lookahead (fun c => c == ':') ":"
    skip
    ws
    let item ← value
    let fields := (key, item) :: fields
    let separator ← any
    if separator == '}' then
      ws
      return Json.mkObj fields
    else if separator == ',' then
      ws
      object fields
    else
      fail "expected comma or closing brace"

  partial def array (items : Array Json) : Parser Json := do
    let item ← value
    let items := items.push item
    let separator ← any
    if separator == ']' then
      ws
      return Json.arr items
    else if separator == ',' then
      ws
      array items
    else
      fail "expected comma or closing bracket"
end

def document : Parser Json := do
  ws
  let result ← value
  eof
  return result

end Parser

def parse (line : String) : Except String Json :=
  Std.Internal.Parsec.String.Parser.run Parser.document line

def exactKeys (j : Json) (keys : List String) : Except String Unit := do
  let fields ← j.getObj?
  let actual := fields.foldl (init := []) (fun acc key _ => key :: acc)
  if actual.length != keys.length || !(keys.all actual.contains) then
    throw "unexpected or missing object fields"

def natField (j : Json) (key : String) : Except String Nat := do
  (← j.getObjVal? key).getNat?

def strField (j : Json) (key : String) : Except String String := do
  (← j.getObjVal? key).getStr?

def boolField (j : Json) (key : String) : Except String Bool := do
  (← j.getObjVal? key).getBool?

def binding (j : Json) : Except String Binding := do
  exactKeys j ["target", "input", "environment", "policy"]
  return {
    target := (← natField j "target")
    input := (← natField j "input")
    environment := (← natField j "environment")
    policy := (← natField j "policy") }

def candidate (j : Json) : Except String Candidate := do
  exactKeys j ["worker", "generation", "binding", "artifact", "submittedAt", "leaseExpires"]
  return {
    worker := (← natField j "worker")
    generation := (← natField j "generation")
    binding := (← binding (← j.getObjVal? "binding"))
    artifact := (← natField j "artifact")
    submittedAt := (← natField j "submittedAt")
    leaseExpires := (← natField j "leaseExpires") }

def rewardConfig (j : Json) : Except String Reward.Config := do
  exactKeys j ["expected", "reward", "workerA", "workerB"]
  return {
    expected := (← binding (← j.getObjVal? "expected"))
    reward := (← natField j "reward")
    workerA := (← natField j "workerA")
    workerB := (← natField j "workerB") }

def rewardPhase (j : Json) : Except String Reward.Phase := do
  match ← j.getStr? with
  | "open" => return .open
  | "leased" => return .leased
  | "submitted" => return .submitted
  | "accepted" => return .accepted
  | _ => throw "unknown reward phase"

def rewardState (j : Json) : Except String Reward.State := do
  exactKeys j ["now", "generation", "owner", "expires", "phase", "candidate", "payouts",
    "funder", "escrow", "balanceA", "balanceB"]
  let c ← j.getObjVal? "candidate"
  let admitted ← if c.isNull then pure none else some <$> candidate c
  return {
    now := (← natField j "now")
    generation := (← natField j "generation")
    owner := (← natField j "owner")
    expires := (← natField j "expires")
    phase := (← rewardPhase (← j.getObjVal? "phase"))
    candidate := admitted
    payouts := (← natField j "payouts")
    funder := (← natField j "funder")
    escrow := (← natField j "escrow")
    balanceA := (← natField j "balanceA")
    balanceB := (← natField j "balanceB") }

def rewardAction (j : Json) : Except String Reward.Action := do
  match ← strField j "type" with
  | "tick" =>
    exactKeys j ["type", "delta"]
    return .tick (← natField j "delta")
  | "lease" =>
    exactKeys j ["type", "worker", "deadline"]
    return .lease (← natField j "worker") (← natField j "deadline")
  | "submit" =>
    exactKeys j ["type", "worker", "generation", "binding", "artifact"]
    return .submit (← natField j "worker") (← natField j "generation")
      (← binding (← j.getObjVal? "binding")) (← natField j "artifact")
  | "accept" =>
    exactKeys j ["type", "trusted", "evidence"]
    return .accept (← boolField j "trusted") (← candidate (← j.getObjVal? "evidence"))
  | _ => throw "unknown reward action"

def reservationPhase (j : Json) : Except String Reservation.Phase := do
  match ← j.getStr? with
  | "idle" => return .idle
  | "reserved" => return .reserved
  | "running" => return .running
  | "cancelling" => return .cancelling
  | "stopped" => return .stopped
  | "settled" => return .settled
  | _ => throw "unknown reservation phase"

def reservationState (j : Json) : Except String Reservation.State := do
  exactKeys j ["phase", "available", "held", "spent"]
  return {
    phase := (← reservationPhase (← j.getObjVal? "phase"))
    available := (← natField j "available")
    held := (← natField j "held")
    spent := (← natField j "spent") }

def reservationAction (j : Json) : Except String Reservation.Action := do
  match ← strField j "type" with
  | "reserve" =>
    exactKeys j ["type", "cap"]
    return .reserve (← natField j "cap")
  | "start" =>
    exactKeys j ["type"]
    return .start
  | "cancel" =>
    exactKeys j ["type"]
    return .cancel
  | "stop" =>
    exactKeys j ["type", "trusted"]
    return .stop (← boolField j "trusted")
  | "settle" =>
    exactKeys j ["type", "cost"]
    return .settle (← natField j "cost")
  | _ => throw "unknown reservation action"

def bindingJson (b : Binding) : Json := Json.mkObj [
  ("target", toJson b.target), ("input", toJson b.input),
  ("environment", toJson b.environment), ("policy", toJson b.policy)]

def candidateJson (c : Candidate) : Json := Json.mkObj [
  ("worker", toJson c.worker), ("generation", toJson c.generation),
  ("binding", bindingJson c.binding), ("artifact", toJson c.artifact),
  ("submittedAt", toJson c.submittedAt), ("leaseExpires", toJson c.leaseExpires)]

def rewardPhaseString : Reward.Phase → String
  | .open => "open"
  | .leased => "leased"
  | .submitted => "submitted"
  | .accepted => "accepted"

def rewardStateJson (s : Reward.State) : Json := Json.mkObj [
  ("now", toJson s.now), ("generation", toJson s.generation),
  ("owner", toJson s.owner), ("expires", toJson s.expires),
  ("phase", toJson (rewardPhaseString s.phase)),
  ("candidate", s.candidate.map candidateJson |>.getD Json.null),
  ("payouts", toJson s.payouts), ("funder", toJson s.funder),
  ("escrow", toJson s.escrow), ("balanceA", toJson s.balanceA), ("balanceB", toJson s.balanceB)]

def reservationPhaseString : Reservation.Phase → String
  | .idle => "idle"
  | .reserved => "reserved"
  | .running => "running"
  | .cancelling => "cancelling"
  | .stopped => "stopped"
  | .settled => "settled"

def reservationStateJson (s : Reservation.State) : Json := Json.mkObj [
  ("phase", toJson (reservationPhaseString s.phase)), ("available", toJson s.available),
  ("held", toJson s.held), ("spent", toJson s.spent)]

def replay (request : Json) : Except String Json := do
  match ← strField request "kind" with
  | "reward" =>
    exactKeys request ["kind", "config", "state", "actions"]
    let cfg ← rewardConfig (← request.getObjVal? "config")
    let mut state ← rewardState (← request.getObjVal? "state")
    let actions ← (← request.getObjVal? "actions").getArr?
    let mut states := #[rewardStateJson state]
    for item in actions do
      let action ← rewardAction item
      state := Reward.step cfg state action
      states := states.push (rewardStateJson state)
    return Json.mkObj [("states", Json.arr states)]
  | "reservation" =>
    exactKeys request ["kind", "state", "actions"]
    let mut state ← reservationState (← request.getObjVal? "state")
    let actions ← (← request.getObjVal? "actions").getArr?
    let mut states := #[reservationStateJson state]
    for item in actions do
      let action ← reservationAction item
      state := Reservation.step state action
      states := states.push (reservationStateJson state)
    return Json.mkObj [("states", Json.arr states)]
  | _ => throw "unknown kernel kind"

end ResearchExchange.Trace

def main : IO UInt32 := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  let errors ← IO.getStderr
  let mut lineNumber : Nat := 0
  repeat
    let line ← input.getLine
    if line.isEmpty then return 0
    lineNumber := lineNumber + 1
    match ResearchExchange.Trace.parse line >>= ResearchExchange.Trace.replay with
    | .ok result => output.putStrLn result.compress
    | .error message =>
      errors.putStrLn s!"trace input line {lineNumber}: {message}"
      return 1
  return 0
