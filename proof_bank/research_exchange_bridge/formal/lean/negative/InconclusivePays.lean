import ResearchExchangeBridge.Refinement
open ResearchExchangeBridge
example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : s.payouts = 0) : (step cfg s who p .inconclusive).payouts = 1 := by
  simp [inconclusive_is_inert, h]
