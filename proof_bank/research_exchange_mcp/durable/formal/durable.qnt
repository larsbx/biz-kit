module durable {
  type Binding = { artifact: int, target: int, source: int, environment: int, policy: int, epoch: int }
  type State = { epoch: int, enabled: bool, stored: bool, binding: Binding, terminal: int }
  pure val approved = { artifact: 1, target: 2, source: 3, environment: 4, policy: 5, epoch: 1 }
  pure val initial = { epoch: 1, enabled: true, stored: false, binding: approved, terminal: 0 }

  pure def current(s: State, b: Binding): bool =
    s.enabled and s.epoch == b.epoch
  pure def admit(s: State, b: Binding): State =
    if (not(s.stored) and current(s, b) and b.target == approved.target
        and b.source == approved.source and b.environment == approved.environment
        and b.policy == approved.policy)
      { ...s, stored: true, binding: b }
    else s

  // 0 = inconclusive, 1 = passed, 2 = profile mismatch.
  pure def finish(s: State, b: Binding, outcome: int): State =
    if (s.stored and s.terminal == 0 and s.binding == b and current(s, b)
        and (outcome == 1 or outcome == 2))
      { ...s, terminal: outcome }
    else s

  pure val admitted = admit(initial, approved)
  pure val passed = finish(admitted, approved, 1)

  run admittedBindingsTest = assert(admitted.stored and admitted.binding == approved)
  run wrongTargetTest = assert(admit(initial, { ...approved, target: 7 }) == initial)
  run substitutedSourceTest = assert(admit(initial, { ...approved, source: 7 }) == initial)
  run inconclusiveTest = assert(finish(admitted, approved, 0) == admitted)
  run competingDecisionsTest = assert(finish(passed, approved, 2) == passed)
  run revokedEpochTest = {
    val revoked = { ...admitted, epoch: 2, enabled: false };
    val regranted = { ...revoked, enabled: true };
    assert(finish(revoked, approved, 1) == revoked and finish(regranted, approved, 1) == regranted)
  }
  run substitutedCandidateTest = assert(finish(admitted, { ...approved, artifact: 7 }, 1) == admitted)
  run crashRetryTest = assert(finish(admitted, approved, 1) == passed and finish(passed, approved, 1) == passed)
}
