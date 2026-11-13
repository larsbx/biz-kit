import ResearchExchangeBridge.Refinement
import Lean.Data.Json

open Lean

namespace ResearchExchangeBridge.Trace

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

def receiptBinding (j : Json) : Except String ReceiptBinding := do
  exactKeys j ["contributor", "library", "engine", "source_revision", "source_snapshot_sha256",
    "generation", "target", "artifact_sha256", "environment_sha256", "policy_sha256",
    "core_revision", "core_source_sha256"]
  return {
    contributor := (← strField j "contributor"), library := (← strField j "library")
    engine := (← strField j "engine"), source_revision := (← strField j "source_revision")
    source_snapshot_sha256 := (← strField j "source_snapshot_sha256")
    generation := (← natField j "generation"), target := (← strField j "target")
    artifact_sha256 := (← strField j "artifact_sha256")
    environment_sha256 := (← strField j "environment_sha256")
    policy_sha256 := (← strField j "policy_sha256"), core_revision := (← strField j "core_revision")
    core_source_sha256 := (← strField j "core_source_sha256") }

def config (j : Json) : Except String Config := do
  exactKeys j ["expected", "profile", "verifier", "reward"]
  return { expected := (← receiptBinding (← j.getObjVal? "expected"))
           profile := (← strField j "profile"), verifier := (← strField j "verifier")
           reward := (← natField j "reward") }

def phase (j : Json) : Except String Phase := do
  match ← j.getStr? with
  | "submitted" => return .submitted
  | "accepted" => return .accepted
  | "rejected" => return .rejected
  | _ => throw "unknown bridge phase"

def verdict (j : Json) : Except String Verdict := do
  match ← j.getStr? with
  | "accepted" => return .accepted
  | "rejected" => return .rejected
  | "inconclusive" => return .inconclusive
  | _ => throw "unknown bridge verdict"

def row (j : Json) : Except String Row := do
  exactKeys j ["binding", "phase", "version", "verifier_enabled", "authority_epoch",
    "requester_enabled", "requester_epoch", "payouts", "funder", "escrow", "balance_a",
    "balance_b", "settlement", "refund_amount"]
  let refund ← j.getObjVal? "refund_amount"
  let refundAmount ← if refund.isNull then pure none else some <$> refund.getNat?
  return {
    binding := (← receiptBinding (← j.getObjVal? "binding"))
    phase := (← phase (← j.getObjVal? "phase")), version := (← natField j "version")
    verifier_enabled := (← boolField j "verifier_enabled")
    authority_epoch := (← natField j "authority_epoch")
    requester_enabled := (← boolField j "requester_enabled")
    requester_epoch := (← natField j "requester_epoch"), payouts := (← natField j "payouts")
    funder := (← natField j "funder"), escrow := (← natField j "escrow")
    balance_a := (← natField j "balance_a"), balance_b := (← natField j "balance_b")
    settlement := (← boolField j "settlement"), refund_amount := refundAmount }

def identity (j : Json) : Except String Identity := do
  exactKeys j ["authenticated", "principal", "requester"]
  return {
    authenticated := (← boolField j "authenticated")
    principal := (← strField j "principal"), requester := (← strField j "requester") }

def prepared (j : Json) : Except String Prepared := do
  exactKeys j ["binding", "profile", "version", "authority_epoch", "requester_epoch", "checked"]
  return {
    binding := (← receiptBinding (← j.getObjVal? "binding"))
    profile := (← strField j "profile"), version := (← natField j "version")
    authority_epoch := (← natField j "authority_epoch")
    requester_epoch := (← natField j "requester_epoch"), checked := (← boolField j "checked") }

def bindingJson (b : ReceiptBinding) : Json := Json.mkObj [
  ("contributor", toJson b.contributor), ("library", toJson b.library), ("engine", toJson b.engine),
  ("source_revision", toJson b.source_revision), ("source_snapshot_sha256", toJson b.source_snapshot_sha256),
  ("generation", toJson b.generation), ("target", toJson b.target), ("artifact_sha256", toJson b.artifact_sha256),
  ("environment_sha256", toJson b.environment_sha256), ("policy_sha256", toJson b.policy_sha256),
  ("core_revision", toJson b.core_revision), ("core_source_sha256", toJson b.core_source_sha256)]

def phaseString : Phase → String
  | .submitted => "submitted"
  | .accepted => "accepted"
  | .rejected => "rejected"

def rowJson (s : Row) : Json := Json.mkObj [
  ("binding", bindingJson s.binding), ("phase", toJson (phaseString s.phase)),
  ("version", toJson s.version), ("verifier_enabled", toJson s.verifier_enabled),
  ("authority_epoch", toJson s.authority_epoch), ("requester_enabled", toJson s.requester_enabled),
  ("requester_epoch", toJson s.requester_epoch), ("payouts", toJson s.payouts), ("funder", toJson s.funder),
  ("escrow", toJson s.escrow), ("balance_a", toJson s.balance_a), ("balance_b", toJson s.balance_b),
  ("settlement", toJson s.settlement), ("refund_amount", s.refund_amount.map toJson |>.getD Json.null)]

def coreBindingJson (b : ResearchExchange.Binding) : Json := Json.mkObj [
  ("target", toJson b.target), ("input", toJson b.input),
  ("environment", toJson b.environment), ("policy", toJson b.policy)]

def candidateJson (c : ResearchExchange.Candidate) : Json := Json.mkObj [
  ("worker", toJson c.worker), ("generation", toJson c.generation),
  ("binding", coreBindingJson c.binding), ("artifact", toJson c.artifact),
  ("submittedAt", toJson c.submittedAt), ("leaseExpires", toJson c.leaseExpires)]

def rewardPhaseString : ResearchExchange.Reward.Phase → String
  | .open => "open"
  | .leased => "leased"
  | .submitted => "submitted"
  | .accepted => "accepted"
  | .rejected => "rejected"

def rewardJson (s : ResearchExchange.Reward.State) : Json := Json.mkObj [
  ("now", toJson s.now), ("generation", toJson s.generation), ("owner", toJson s.owner),
  ("expires", toJson s.expires), ("phase", toJson (rewardPhaseString s.phase)),
  ("candidate", s.candidate.map candidateJson |>.getD Json.null), ("payouts", toJson s.payouts),
  ("funder", toJson s.funder), ("escrow", toJson s.escrow),
  ("balanceA", toJson s.balanceA), ("balanceB", toJson s.balanceB)]

def closureJson (s : ResearchExchange.Closure.State) : Json := Json.mkObj [
  ("adapter", Json.mkObj [
    ("reward", rewardJson s.adapter.reward), ("version", toJson s.adapter.version),
    ("verifierEnabled", toJson s.adapter.verifierEnabled), ("verifierEpoch", toJson s.adapter.verifierEpoch),
    ("settlement", s.adapter.settlement.map candidateJson |>.getD Json.null)]),
  ("refund", s.refund.map (fun r => Json.mkObj [
    ("candidate", candidateJson r.candidate), ("amount", toJson r.amount)]) |>.getD Json.null)]

def replay (j : Json) : Except String Json := do
  exactKeys j ["config", "state", "identity", "prepared", "verdict"]
  let cfg ← config (← j.getObjVal? "config")
  let s ← row (← j.getObjVal? "state")
  let who ← identity (← j.getObjVal? "identity")
  let p ← prepared (← j.getObjVal? "prepared")
  let v ← verdict (← j.getObjVal? "verdict")
  let out := step cfg s who p v
  return Json.mkObj [
    ("ready", toJson (decide (ready cfg s who p))), ("state", rowJson out),
    ("projected", closureJson (projectRow out)), ("core_result", closureJson (coreResult cfg s who p v))]

end ResearchExchangeBridge.Trace
