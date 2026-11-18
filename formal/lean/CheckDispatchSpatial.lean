import BizKitDispatchSpatial
import Lean

open BizKitDispatchSpatial

private def scope : Scope := ⟨10, 20, .participant, 11, 3⟩
private def subject : Subject := ⟨⟨11⟩, ⟨101⟩⟩
private def authority : Authority := ⟨scope, true, true, true, true, true, true⟩
private def sample : Sample := ⟨subject, 10, 20, 7, 5⟩
private def consent : Consent := ⟨5, 10, ⟨11⟩, 7, true, true⟩
private def initial : View :=
  ⟨scope, 1, .snapshot, 0, 0, [], none, none, 0, false, 0, false, 7⟩
private def getFrame : Frame := ⟨scope, 1, .get, 10, 0, true, [subject], true⟩
private def firstFrame : Frame := ⟨scope, 1, .stream, 20, 0, true, [subject], true⟩
private def handoff : View := receive initial getFrame
private def live : View := receive handoff firstFrame
private def selected : View := select live subject
private def reply : WorkReply := ⟨scope, 1, selected.workEpoch, subject, true, true⟩
private def inspected : View := receiveWork selected reply
private def deleted : View := receive inspected { firstFrame with sequence := 1, visible := [] }

-- These evaluate definitions independently of the theorem statements. The
-- successful paths make refusal/no-resurrection checks nonvacuous.
#guard observe scope authority sample consent == some subject
#guard observe scope authority { sample with organization := 21 } consent == none
#guard observe scope { authority with preciseRead := false } sample consent == none
#guard observe scope authority sample { consent with id := 6 } == none
#guard handoff.phase == .handoff && handoff.visible == [subject]
#guard live.phase == .streaming && live.sequence == 0 && live.watching
#guard (receive initial { getFrame with sequence := 1 }).phase == .stopped
#guard (receive handoff { firstFrame with sequence := 1 }).phase == .stopped
#guard (receive handoff { firstFrame with stream := 10 }).phase == .stopped
#guard receive live firstFrame == live
#guard receive live { firstFrame with generation := 0 } == live
#guard (receive live { firstFrame with scope := { scope with role := 4 } }).phase == .stopped
#guard (receive live { firstFrame with stream := 30 }).phase == .stopped
#guard inspected.work == some subject
#guard receiveWork selected { reply with assignmentRead := false } == selected
#guard receiveWork selected { reply with loadRead := false } == selected
#guard receiveWork selected { reply with requestEpoch := 0 } == selected
#guard receiveWork selected { reply with scope := { scope with role := 4 } } == selected
#guard receiveWork selected { reply with generation := 0 } == selected
#guard deleted.visible == [] && deleted.selected == none && deleted.work == none
#guard receive deleted firstFrame == deleted
#guard (receive deleted firstFrame).liveness == deleted.liveness
#guard receiveWork deleted reply == deleted
#guard receiveWork (clear inspected) reply == clear inspected
#guard receive (clear inspected) firstFrame == clear inspected
#guard (reconnect inspected scope).visible == [] && (reconnect inspected scope).work == none
#guard (reconnect inspected scope).businessVersion == 7 && deleted.businessVersion == 7

open Lean in
run_cmd do
  let env ← getEnv
  let some moduleIdx := env.getModuleIdx? `BizKitDispatchSpatial
    | throwError "missing compiled dispatch spatial module"
  let required := #[
    `BizKitDispatchSpatial.authorized_observation_is_shown,
    `BizKitDispatchSpatial.replacement_consent_cannot_reveal_original,
    `BizKitDispatchSpatial.wrong_scope_clears,
    `BizKitDispatchSpatial.cleared_view_cannot_be_restored,
    `BizKitDispatchSpatial.old_or_duplicate_cursor_is_ignored,
    `BizKitDispatchSpatial.ignored_frame_cannot_renew_liveness,
    `BizKitDispatchSpatial.authorized_matching_work_is_shown,
    `BizKitDispatchSpatial.cleared_view_refuses_late_work,
    `BizKitDispatchSpatial.frame_processing_preserves_business,
    `BizKitDispatchSpatial.work_inspection_preserves_business]
  for name in required do
    match env.find? name with
    | some (.thmInfo _) => pure ()
    | _ => throwError "required spatial theorem absent: {name}"
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
    throwError "empty compiled dispatch spatial inventory"
  logInfo m!"Audited {count} compiled spatial declarations; all 27 executable checks passed"
