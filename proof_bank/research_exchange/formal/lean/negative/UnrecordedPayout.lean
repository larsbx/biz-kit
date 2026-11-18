import ResearchExchange

namespace ResearchExchange.Negative

def recordedAdapterConfig : Adapter.Config :=
  { reward := { expected := ⟨1, 2, 3, 4⟩, reward := 5, workerA := 10, workerB := 20 },
    verifier := 30, profile := 42 }

def recordedAdapterCandidate : Candidate := ⟨10, 1, ⟨1, 2, 3, 4⟩, 9, 0, 2⟩

def recordedAdapterSubmitted : Adapter.State :=
  { reward := Reward.submit recordedAdapterConfig.reward
      (Reward.lease recordedAdapterConfig.reward
        (Reward.initial recordedAdapterConfig.reward 7 0 0) 10 2)
      10 1 recordedAdapterConfig.reward.expected 9,
    version := 2, verifierEnabled := true, verifierEpoch := 0, settlement := none }

def recordedAdapterPrepared : Adapter.Prepared :=
  { candidate := recordedAdapterCandidate, profile := 42, version := 2,
    authorityEpoch := 0, checked := true }

def recordedAdapterCommit : Adapter.State :=
  Adapter.commit recordedAdapterConfig recordedAdapterSubmitted
    { authenticated := true, principal := 30 } recordedAdapterPrepared

/-- Deliberately false: this valid commit really pays, but cannot publish the
    paid reward state while omitting its matching settlement record. -/
theorem successful_payment_can_omit_settlement :
    recordedAdapterCommit.reward.payouts = 1 ∧ recordedAdapterCommit.settlement = none := by
  decide

end ResearchExchange.Negative
