import CrossCurrencySetoff

/-!
Batch arithmetic evaluator for differential comparison, using the same definitions
as the universal proofs. Input: Q<TAB>B<TAB>n<TAB>d, one row per line.
Output: status<TAB>quoteReduction<TAB>baseReduction<TAB>quoteResidual<TAB>baseResidual.
Statuses: 0 = invalid amount/rate; 1 = no positive exact offset; 2 = accepted.
This executable does not model source/contract authentication or execute effects.
-/
open CrossCurrencySetoff

def response (Q B n d : Nat) : List Nat :=
  if Q = 0 ∨ B = 0 ∨ maxMinor < Q ∨ maxMinor < B ∨ maxMinor < n ∨ maxMinor < d ∨
      ¬ Canonical n d then
    [0, 0, 0, Q, B]
  else if multiples Q B n d = 0 then
    [1, 0, 0, Q, B]
  else
    [2, quoteReduction Q B n d, baseReduction Q B n d,
      quoteResidual Q B n d, baseResidual Q B n d]

def parseRow (line : String) : Option (List Nat) :=
  match line.trimAscii.toString.splitOn "\t" with
  | [q, b, n, d] => do
    let Q ← q.toNat?
    let B ← b.toNat?
    let N ← n.toNat?
    let D ← d.toNat?
    pure (response Q B N D)
  | _ => none

def main : IO Unit := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  let mut row := 0
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    row := row + 1
    match parseRow line with
    | some result => stdout.putStrLn (String.intercalate "\t" (result.map toString))
    | none => throw (IO.userError s!"invalid arithmetic TSV row {row}")
