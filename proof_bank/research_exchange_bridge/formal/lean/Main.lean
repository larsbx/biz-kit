import ResearchExchangeBridge.Json

/- The line-oriented JSON adapter is executable conformance tooling, not a
public authentication endpoint. Parser, compiler and IO runtime correctness
remain implementation assumptions; malformed inputs are separately tested. -/
def main : IO UInt32 := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  let errors ← IO.getStderr
  let mut lineNumber : Nat := 0
  repeat
    let line ← input.getLine
    if line.isEmpty then return 0
    lineNumber := lineNumber + 1
    match ResearchExchangeBridge.Trace.parse line >>= ResearchExchangeBridge.Trace.replay with
    | .ok result => output.putStrLn result.compress
    | .error message =>
      errors.putStrLn s!"bridge input line {lineNumber}: {message}"
      return 1
  return 0
