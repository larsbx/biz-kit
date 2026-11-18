import BizKitInventoryLocations
open BizKitInventoryLocations

def opName : Op → String
  | .receive => "receive" | .reserve => "reserve" | .commit => "commit"
  | .release => "release" | .transfer => "transfer" | .expire => "expire"

def statusName : Status → String
  | .active => "active" | .committed => "committed"
  | .released => "released" | .expired => "expired"

def encodeCommand (c : Command) : String :=
  String.intercalate "," [toString c.id, toString c.version, opName c.op,
    if c.location then "b" else "a", toString c.quantity, toString c.expires]

def encodeSlot : Option Reservation → String
  | none => "none"
  | some r => s!"{statusName r.status},{r.remaining},{r.expires}"

def encodeState (s : Ledger) : String :=
  String.intercalate "\t" [toString (s.stock.onHand false), toString (s.stock.onHand true),
    encodeSlot (s.stock.reservations false), encodeSlot (s.stock.reservations true),
    toString s.stock.watermark, toString s.version,
    String.intercalate ";" (s.seen.map encodeCommand)]

def emit (trace : Nat) (commands : List Command) : IO Unit := do
  let mut s := initial
  for c in commands do
    let (next, tag) := match admit s c with
      | .ok (next, tag) => (next, tag)
      | .error e => (s, e)
    IO.println s!"{trace}\t{encodeCommand c}\t{tag}\t{encodeState next}"
    s := next

def main : IO Unit := do
  let mut trace := 0
  for a in List.range 4 do
    for b in List.range 4 do
      for qa in List.range 4 do
        for qb in List.range 4 do
          for l in [false, true] do
            for branch in List.range 3 do
              let mut s := initial
              let mut commands : List Command := []
              for (op, loc, q, e) in [(.receive, false, a, 0), (.receive, true, b, 0),
                  (.reserve, false, qa+1, 5), (.reserve, true, qb+1, 7)] do
                let c : Command := ⟨commands.length, s.version, op, loc, q, e⟩
                commands := commands ++ [c]
                if let .ok (next, _) := admit s c then s := next
              let reserveA := commands[2]!
              let reserveB := commands[3]!
              let ops := if branch = 0 then [(.commit, l, 1, 0), (.commit, !l, 4, 0)]
                else if branch = 1 then [(.release, l, 0, 0)]
                else [(.expire, false, 5, 0), (.expire, false, 7, 0)]
              for (op, loc, q, e) in ops ++ [(.transfer, l, 1, 0), (.expire, false, 6, 0),
                  (.commit, l, 1, 0), (.reserve, l, 1, 8), (.reserve, !l, 1, 0), (.expire, false, 9, 0)] do
                let c : Command := ⟨commands.length, s.version, op, loc, q, e⟩
                commands := commands ++ [c]
                if let .ok (next, _) := admit s c then s := next
              commands := commands ++ [reserveA, reserveB, { reserveA with quantity := 8 },
                ⟨99, 0, .receive, l, 1, 0⟩]
              emit trace commands
              trace := trace + 1
