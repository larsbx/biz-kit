"""Bounded, opt-in NegMAS price negotiation with no fulfillment assumptions.

This is an original demonstration strategy, not a reproduction of a paper or a
claim about how merchants negotiate. Its only negotiated issue is integer price.
"""

from random import Random

from .validation import integer, require_runtime


NEGMAS_VERSION = "0.17.0"


def run_negotiation(
    seed: int = 0,
    buyer_limit: int = 120,
    seller_floor: int = 80,
    max_rounds: int = 20,
) -> dict:
    """Run a real SAO negotiation using seeded, round-based concessions.

    Prices are abstract integer minor units. Each party knows only its own
    reservation price and the public issue bounds; this function defines both
    parties for an experiment. Nonoverlapping reservations are valid input and
    produce no agreement. Negotiation rounds are not elapsed days.

    NegMAS 0.17.0 consumes global random draws even when random termination is
    disabled. Those draws cannot influence these economic results. The adapter
    neither seeds nor restores global state; use separate process workers when
    integrating this runtime with concurrent experiments.
    """
    seed = integer("seed", seed, 0, 2**63 - 1)
    buyer_limit = integer("buyer_limit", buyer_limit, 0, 10**9)
    seller_floor = integer("seller_floor", seller_floor, 0, 10**9)
    max_rounds = integer("max_rounds", max_rounds, 1, 1000)
    negmas = require_runtime("negmas", NEGMAS_VERSION, "negmas")
    from negmas.sao import ResponseType, SAONegotiator

    upper_bound = 2 * max(buyer_limit, seller_floor, 1)
    events = []

    class PriceNegotiator(SAONegotiator):
        def __init__(self, role: str, reservation: int):
            super().__init__(name=role, id=f"economic-demo-{role}")
            self.role = role
            self.reservation = reservation
            rng = Random(f"economic-negotiation-v1:{seed}:{role}")
            self.opening = (
                rng.randint(0, reservation)
                if role == "buyer"
                else rng.randint(reservation, upper_bound)
            )

        def price_at(self, step: int) -> int:
            if max_rounds == 1:
                return self.reservation
            progress = min(step, max_rounds - 1)
            remaining = max_rounds - 1 - progress
            if self.role == "buyer":
                return self.opening + (
                    (self.reservation - self.opening) * progress
                ) // (max_rounds - 1)
            return self.reservation + (
                (self.opening - self.reservation) * remaining
            ) // (max_rounds - 1)

        def propose(self, state, dest=None):
            price = self.price_at(state.step)
            events.append(
                {
                    "round": state.step + 1,
                    "party": self.role,
                    "kind": "offer",
                    "price": price,
                }
            )
            return (price,)

        def respond(self, state, source=None):
            offer = state.current_offer
            valid = (
                isinstance(offer, tuple)
                and len(offer) == 1
                and type(offer[0]) is int
                and 0 <= offer[0] <= upper_bound
            )
            threshold = self.price_at(state.step)
            accepted = valid and (
                offer[0] <= threshold if self.role == "buyer" else offer[0] >= threshold
            )
            events.append(
                {
                    "round": state.step + 1,
                    "party": self.role,
                    "kind": "accept" if accepted else "reject",
                    "price": offer[0] if valid else None,
                }
            )
            return ResponseType.ACCEPT_OFFER if accepted else ResponseType.REJECT_OFFER

    mechanism = negmas.SAOMechanism(
        name="economic-price-demo",
        id="economic-price-demo",
        outcome_space=negmas.make_os(
            issues=[negmas.make_issue((0, upper_bound), name="price")],
            name="economic-price-domain",
        ),
        n_steps=max_rounds,
        time_limit=None,
        step_time_limit=None,
        negotiator_time_limit=None,
        hidden_time_limit=float("inf"),
        pend=0,
        pend_per_second=0,
        dynamic_entry=False,
        avoid_ultimatum=False,
        check_offers=True,
        enforce_issue_types=True,
        offering_is_accepting=True,
        one_offer_per_step=False,
        sync_calls=True,
        extra_callbacks=False,
        checkpoint_every=0,
    )
    for party, reservation in (("buyer", buyer_limit), ("seller", seller_floor)):
        if not mechanism.add(PriceNegotiator(party, reservation), role=party):
            raise RuntimeError(f"NegMAS could not add the {party} negotiator")
    state = mechanism.run()
    if state.has_error:
        raise RuntimeError(f"NegMAS negotiation failed: {state.error_details}")
    agreement = None if state.agreement is None else {"price": int(state.agreement[0])}
    if agreement is not None and not seller_floor <= agreement["price"] <= buyer_limit:
        raise RuntimeError(
            "NegMAS returned an agreement outside the parties' reservation prices"
        )
    rounds_executed = max((event["round"] for event in events), default=0)
    if rounds_executed > max_rounds:
        raise RuntimeError("NegMAS exceeded the configured round bound")

    return {
        "schema_version": "economic-adapter-result-v1",
        "source": "synthetic",
        "adapter": "negmas_bilateral_price",
        "model_version": "1",
        "framework": {
            "name": "negmas",
            "version": NEGMAS_VERSION,
            "license": "AGPL-3.0-or-later",
        },
        "parameters": {
            "seed": seed,
            "buyer_limit": buyer_limit,
            "seller_floor": seller_floor,
            "max_rounds": max_rounds,
        },
        "status": "agreement" if agreement is not None else "no_agreement",
        "agreement": agreement,
        "rounds_executed": rounds_executed,
        "termination_reason": (
            "agreement"
            if agreement is not None
            else "incompatible_reservation_prices"
            if seller_floor > buyer_limit
            else "round_limit"
        ),
        "events": events,
        "assumptions": [
            "One buyer, one seller, one integer-price issue, and one indivisible item.",
            "Original linear concession policies; each party reaches its reservation price in the final round.",
            "Fixed buyer-first activation; a round may contain both parties' offers.",
            "Local seeded opening offers, no random termination, and no wallclock deadline.",
            "Rounds have no mapping to elapsed days; currency, capacity, quality, and delivery are absent.",
        ],
        "evidence_boundary": {
            "empirically_calibrated": False,
            "drives_core_engine": False,
            "agreement_is_qualified_quote": False,
            "fulfillment": "not_modeled",
        },
        "runtime_notes": [
            "NegMAS consumes unused global RNG draws; economic outputs depend only on the adapter's local streams.",
            "Use process workers to isolate concurrent experiments; this wrapper does not swap or seed global RNG state.",
        ],
    }
