import ResearchExchange

namespace ResearchExchange.Negative

def workerAdapterConfig : Adapter.Config :=
  { reward := { expected := ⟨1, 2, 3, 4⟩, reward := 5, workerA := 10, workerB := 20 },
    verifier := 30, profile := 42 }

def workerAdapterCandidate : Candidate := ⟨10, 1, ⟨1, 2, 3, 4⟩, 9, 0, 2⟩

def workerAdapterSubmitted : Adapter.State :=
  { reward := Reward.submit workerAdapterConfig.reward
      (Reward.lease workerAdapterConfig.reward
        (Reward.initial workerAdapterConfig.reward 7 0 0) 10 2)
      10 1 workerAdapterConfig.reward.expected 9,
    version := 2, verifierEnabled := true, verifierEpoch := 0, settlement := none }

def workerAdapterPrepared : Adapter.Prepared :=
  { candidate := workerAdapterCandidate, profile := 42, version := 2,
    authorityEpoch := 0, checked := true }

/-- Deliberately false: all proof and freshness fields are valid, but an
    authenticated worker is still not the configured verifier. -/
theorem worker_identity_can_authorize_payment :
    (Adapter.commit workerAdapterConfig workerAdapterSubmitted
      { authenticated := true, principal := 10 } workerAdapterPrepared).reward.payouts = 1 := by
  decide

end ResearchExchange.Negative
