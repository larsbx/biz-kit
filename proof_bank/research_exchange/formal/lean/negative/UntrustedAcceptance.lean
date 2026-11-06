import ResearchExchange

namespace ResearchExchange.Negative

def untrustedConfig : Reward.Config :=
  { expected := ⟨1, 2, 3, 4⟩, reward := 5, workerA := 10, workerB := 20 }

def untrustedCandidate : Candidate := ⟨10, 1, ⟨1, 2, 3, 4⟩, 9, 0, 2⟩

def submitted : Reward.State :=
  Reward.submit untrustedConfig
    (Reward.lease untrustedConfig (Reward.initial untrustedConfig 7 0 0) 10 2)
    10 1 untrustedConfig.expected 9

/-- Deliberately false: a candidate alone does not supply verifier authority. -/
theorem untrusted_acceptance_pays :
    (Reward.accept untrustedConfig submitted false untrustedCandidate).payouts = 1 := by
  decide

end ResearchExchange.Negative
