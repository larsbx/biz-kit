import Wire

/-! Local differential fixture program, not a source or business command API.
Reads one complete JSON fixture per line; malformed fixtures fail the process. -/
def main : IO Unit := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  repeat
    let line ← input.getLine
    if line == "" then break
    let result := do
      let json ← Lean.Json.parse line
      let bundle ← PlanningWire.bundle json
      PlanningWire.run bundle
    match result with
    | .error message => throw <| IO.userError s!"invalid oracle fixture: {message}"
    | .ok json =>
      output.putStrLn json.compress
      output.flush
