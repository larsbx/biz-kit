import BizKitCommercialLineage

open BizKitCommercialLineage

def main : IO Unit := do
  let histories : List (String × List Change) :=
    [ ("recorded", [])
    , ("assigned", [.assignment])
    , ("assigned_back", [.assignment, .assignment])
    , ("direct_discharge", [.directDischarge])
    , ("assigned_back_discharged", [.assignment, .assignment, .directDischarge])
    , ("legacy_netting", [.legacyNetting])
    ]
  for (name, operations) in histories do
    let state := replay recorded operations
    IO.println s!"{name}\t{state.originalOnly}\t{state.isOpen}\t{state.revision}"
