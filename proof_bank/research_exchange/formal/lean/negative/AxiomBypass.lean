import ResearchExchange

namespace ResearchExchange.Negative

/-- Deliberate negative control: an unsupported assumption, excluded from the library. -/
axiom injected : False

theorem unproved : False := injected

#print axioms ResearchExchange.Negative.unproved

end ResearchExchange.Negative
