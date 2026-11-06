import ResearchExchange

namespace ResearchExchange.Negative

def staleConfig : Reward.Config :=
  { expected := ⟨1, 2, 3, 4⟩, reward := 5, workerA := 10, workerB := 20 }

def currentLease : Reward.State :=
  Reward.lease staleConfig (Reward.initial staleConfig 7 0 0) 10 2

/-- Deliberately false: the current generation is 1, so generation 0 cannot submit. -/
theorem stale_generation_accepted :
    (Reward.submit staleConfig currentLease 10 0 staleConfig.expected 9).phase =
      Reward.Phase.submitted := by
  decide

end ResearchExchange.Negative
