import ResearchExchange

namespace ResearchExchange.Negative

def closureConfig : Adapter.Config := ⟨Examples.config, 30, 42⟩
def closureSubmitted : Closure.State := ⟨⟨Examples.admitted, 2, true, 0, none⟩, none⟩
def closurePrepared : Adapter.Prepared := ⟨Examples.evidence, 42, 2, 0, true⟩

/-- Deliberately false even with an authenticated verifier and fresh evidence. -/
theorem inconclusive_can_refund :
    (Closure.decide closureConfig closureSubmitted ⟨true, 30⟩ closurePrepared
      .inconclusive).refund = some ⟨Examples.evidence, 5⟩ := by
  decide

end ResearchExchange.Negative
