import ResearchExchangeBridge.Refinement
open ResearchExchangeBridge
example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : p.version ≠ s.version) : step cfg s who p .accepted ≠ s := by
  simp [stale_version_refused cfg s who p .accepted h]
