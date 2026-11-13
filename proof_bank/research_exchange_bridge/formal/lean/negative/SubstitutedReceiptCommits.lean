import ResearchExchangeBridge.Refinement
open ResearchExchangeBridge
example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : p.binding ≠ s.binding) : step cfg s who p .rejected ≠ s := by
  simp [substituted_receipt_refused cfg s who p .rejected h]
