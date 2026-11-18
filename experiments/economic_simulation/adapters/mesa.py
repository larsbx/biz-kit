"""Original synthetic participation model using actual Mesa agents."""

from .validation import integer, probability, require_runtime


MESA_VERSION = "3.5.2"


def run_mesa_demo(
    seed: int = 0,
    steps: int = 7,
    agents: int = 10,
    *,
    response_probability: float = 0.65,
    withdrawal_probability: float = 0.02,
) -> dict:
    """Run a deterministic participation demonstration, not a quote marketplace."""
    seed = integer("seed", seed, 0, 2**63 - 1)
    steps = integer("steps", steps, 1, 365)
    agents = integer("agents", agents, 0, 1000)
    response_probability = probability("response_probability", response_probability)
    withdrawal_probability = probability(
        "withdrawal_probability", withdrawal_probability
    )
    mesa = require_runtime("mesa", MESA_VERSION, "mesa")

    class Business(mesa.Agent):
        def __init__(self, model, business_id):
            super().__init__(model)
            self.business_id = business_id

        def step(self):
            if self.random.random() < withdrawal_probability:
                kind = "withdrawn"
                self.remove()
            elif self.random.random() < response_probability:
                kind = "responded"
            else:
                kind = "no_response"
            self.model.events.append(
                {"step": self.model.day, "business_id": self.business_id, "kind": kind}
            )

    class ParticipationModel(mesa.Model):
        def __init__(self):
            super().__init__(rng=seed)
            self.day = 0
            self.events = []
            self.daily = []
            for index in range(agents):
                Business(self, f"business-{index + 1:04}")

        def step(self):
            self.day += 1
            eligible = len(self.agents)
            start = len(self.events)
            # Stable creation-order activation; no shuffling or wallclock inputs.
            self.agents.do("step")
            events = self.events[start:]
            self.daily.append(
                {
                    "step": self.day,
                    "eligible_at_start": eligible,
                    "withdrawals": sum(
                        event["kind"] == "withdrawn" for event in events
                    ),
                    "responses": sum(event["kind"] == "responded" for event in events),
                    "no_response": sum(
                        event["kind"] == "no_response" for event in events
                    ),
                    "active_at_end": len(self.agents),
                }
            )

    model = ParticipationModel()
    for _ in range(steps):
        model.step()
    model.running = False
    return {
        "schema_version": "economic-adapter-result-v1",
        "source": "synthetic",
        "adapter": "mesa_participation",
        "model_version": "1",
        "framework": {"name": "mesa", "version": MESA_VERSION, "license": "Apache-2.0"},
        "parameters": {
            "seed": seed,
            "steps": steps,
            "agents": agents,
            "response_probability": response_probability,
            "withdrawal_probability": withdrawal_probability,
        },
        "status": "completed",
        "daily": model.daily,
        "events": model.events,
        "summary": {
            "responses": sum(row["responses"] for row in model.daily),
            "withdrawals": sum(row["withdrawals"] for row in model.daily),
            "active_at_end": len(model.agents),
        },
        "assumptions": [
            "One response opportunity per active business per step.",
            "Stable creation-order activation and model-local seeded randomness.",
            "Independent withdrawal and response draws with uncalibrated probabilities.",
        ],
        "evidence_boundary": {
            "empirically_calibrated": False,
            "drives_core_engine": False,
            "response_is_qualified_quote": False,
            "fulfillment": "not_modeled",
        },
    }
