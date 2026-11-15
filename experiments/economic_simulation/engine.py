"""Event-driven synthetic demand, quotes, commitments and physical fulfillment.

This is an original experiment, not a replication of a cited paper or runtime
refinement of authoritative business cores. Each request consumes one supplier
lot, without split sourcing. Barter requests own distinct outgoing lots.
Reservations and delivered units must remain within each lot's capacity.
Failed undelivered legs release their stock; spoilage/goods loss is not modeled.
"""

from __future__ import annotations

import copy
import hashlib
import heapq
import platform
import subprocess
from pathlib import Path

from . import __version__
from .matching import pack_cycles
from .scenario import ScenarioError, canonical_json, digest, validate_scenario


class SimulationLimitError(RuntimeError):
    """A deterministic simulation budget was exhausted; no result is certified."""


def _draw(seed, *keys):
    """Common primitive keyed by event identity; no shared mutable RNG."""
    raw = hashlib.sha256(canonical_json([seed, *keys]).encode("utf-8")).digest()
    return (int.from_bytes(raw[:8], "big") >> 11) / 2**53


def _rate(numerator, denominator):
    return {"numerator": numerator, "denominator": denominator,
            "rate": numerator / denominator if denominator else None}


def _provenance(scenario, seed):
    package = Path(__file__).resolve().parent
    # Enumerate only implementation modules. Recursive traversal would walk a
    # local virtualenv on every Monte Carlo run, even if later filtering it out.
    paths = sorted([*package.glob("*.py"), *(package / "adapters").glob("*.py")])
    sources = {str(path.relative_to(package)): hashlib.sha256(path.read_bytes()).hexdigest()
               for path in paths}
    try:
        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=package, stderr=subprocess.DEVNULL,
            timeout=2, text=True,
        ).strip()
        dirty = bool(subprocess.check_output(
            ["git", "status", "--porcelain", "--", "."], cwd=package,
            stderr=subprocess.DEVNULL, timeout=2, text=True,
        ).strip())
    except (OSError, subprocess.SubprocessError):
        revision, dirty = None, None
    return {
        "seed": seed, "scenario_sha256": digest(scenario),
        "implementation_version": __version__, "source_revision": revision,
        "source_tree_dirty": dirty, "model_source_sha256": digest(sources),
        "model_source_scope": "package/*.py and package/adapters/*.py; excludes tests and environments",
        "python_version": platform.python_version(),
        "randomness": "sha256-keyed-event-primitives-v1", "calibration": "uncalibrated_synthetic",
    }


class _Run:
    def __init__(self, scenario, seed):
        self.s, self.seed = scenario, seed
        self.policy = scenario["policy"]
        self.end, self.now = scenario["observed_until_hour"], 0
        self.businesses = {b["id"]: b for b in scenario["businesses"]}
        self.requests = {r["id"]: r for r in scenario["requests"]}
        self.offers = {o["id"]: o for o in scenario["offers"]}
        self.alive = set(self.businesses)
        self.stock = {identifier: {"initial": row["quantity"], "reserved": 0, "delivered": 0}
                      for identifier, row in self.offers.items()}
        self.state = {
            identifier: {"id": identifier, "qualified_at_hour": row["qualified_at_hour"],
                         "first_quote_hour": None, "first_commitment_hour": None,
                         "fulfilled_at_hour": None, "withdrawn_at_hour": None,
                         "status": "not_yet_qualified", "attempts": 0,
                         "active_order_id": None, "retry_after_hour": 0}
            for identifier, row in self.requests.items()
        }
        self.invitations, self.quotes, self.orders, self.cycles, self.events = [], [], [], [], []
        self.queue, self.queue_sequence, self.scheduled = [], 0, 0
        self.decisions, self.used_quotes, self.declined_quotes = set(), set(), set()
        self.quote_counter, self.invitation_by_pair, self.solver_runs = {}, {}, []

    def emit(self, kind, **data):
        if len(self.events) >= self.s["limits"]["max_events"]:
            raise SimulationLimitError("event log budget exhausted")
        self.events.append({"sequence": len(self.events), "hour": self.now, "kind": kind, "data": data})

    def push(self, hour, phase, kind, data):
        if hour > self.end:
            return
        if hour < self.now:
            raise RuntimeError("event scheduled in the past")
        self.scheduled += 1
        if self.scheduled > self.s["limits"]["max_events"]:
            raise SimulationLimitError("scheduled event budget exhausted")
        self.queue_sequence += 1
        heapq.heappush(self.queue, (hour, phase, self.queue_sequence, kind, data))

    def decision(self, hour):
        if hour not in self.decisions:
            self.decisions.add(hour)
            self.push(hour, 20, "clear", None)

    def available(self, offer_id):
        stock = self.stock[offer_id]
        return stock["initial"] - stock["reserved"] - stock["delivered"]

    def compatible(self, request, offer):
        return (
            request["buyer_id"] != offer["seller_id"]
            and all(request[key] == offer[key] for key in ("category", "area", "unit"))
            and offer["quantity"] >= request["quantity"]
            and (request["acceptable_offer_ids"] is None
                 or offer["id"] in request["acceptable_offer_ids"])
        )

    def pending(self, request_id):
        request, state = self.requests[request_id], self.state[request_id]
        return (
            request["qualified_at_hour"] <= self.now <= request["due_at_hour"]
            and state["withdrawn_at_hour"] is None and state["fulfilled_at_hour"] is None
            and state["active_order_id"] is None
            and state["attempts"] <= self.policy["rematch_rounds"]
            and self.now >= state["retry_after_hour"] and request["buyer_id"] in self.alive
        )

    def quote_actionable(self, request, offer):
        # Future shocks are absent from decision predicates. Availability here
        # concerns this instant; a quote is not an exclusive stock reservation.
        return (
            self.pending(request["id"]) and offer["seller_id"] in self.alive
            and offer["available_at_hour"] <= self.now < offer["expires_at_hour"]
            and self.available(offer["id"]) >= request["quantity"]
            and (self.policy["mechanism"] == "barter"
                 or offer["unit_price_minor"] <= request["max_unit_price_minor"])
            and self.now + offer["delivery_hours"]
            + self.businesses[request["buyer_id"]]["receipt_delay_hours"] <= request["due_at_hour"]
        )

    def initialize(self):
        candidate_work = 0
        for request in self.requests.values():
            self.push(request["qualified_at_hour"], 1, "qualify", request["id"])
            if request["withdraw_at_hour"] is not None:
                self.push(request["withdraw_at_hour"], 0, "withdraw", request["id"])
            for offer in self.offers.values():
                candidate_work += 1
                if candidate_work > self.s["limits"]["max_candidate_pairs"]:
                    raise SimulationLimitError("candidate pair budget exhausted")
                if self.compatible(request, offer):
                    hour = max(request["qualified_at_hour"], offer["available_at_hour"])
                    if hour < offer["expires_at_hour"] and hour <= request["due_at_hour"]:
                        self.push(hour, 5, "invite", (request["id"], offer["id"]))
        for shock in self.s["shocks"]:
            if shock["kind"] == "business_exit":
                self.push(shock["at_hour"], 0, "exit", shock["business_id"])
            else:
                self.push(shock["starts_at_hour"], 0, "outage_start", shock)
                self.push(shock["ends_at_hour"], 0, "outage_end", shock)
        if self.policy["cadence_hours"]:
            self.decision(0)

    def invite(self, pair):
        request_id, offer_id = pair
        offer = self.offers[offer_id]
        if not self.pending(request_id) or offer["seller_id"] not in self.alive:
            return
        row = {"id": f"invitation-{len(self.invitations)}", "request_id": request_id,
               "offer_id": offer_id, "seller_id": offer["seller_id"],
               "invited_at_hour": self.now, "responded_at_hour": None, "response": "no_response"}
        self.invitations.append(row)
        self.invitation_by_pair[pair] = row
        self.emit("invited", **row)
        seller = self.businesses[offer["seller_id"]]
        if _draw(self.seed, "response", request_id, offer_id) < seller["response_probability"]:
            self.push(self.now + seller["response_delay_hours"], 10, "quote", pair)

    def issue_quote(self, pair):
        request_id, offer_id = pair
        request, offer = self.requests[request_id], self.offers[offer_id]
        invitation = self.invitation_by_pair.get(pair)
        if invitation is None or offer["seller_id"] not in self.alive:
            return
        if invitation["responded_at_hour"] is None:
            invitation["responded_at_hour"] = self.now
        if not self.quote_actionable(request, offer):
            if invitation["response"] != "quote":
                invitation["response"] = "declined"
            self.emit("quote_unavailable", request_id=request_id, offer_id=offer_id)
            return
        self.quote_counter[pair] = self.quote_counter.get(pair, 0) + 1
        row = {"id": f"quote-{len(self.quotes)}", "request_id": request_id,
               "offer_id": offer_id, "seller_id": offer["seller_id"],
               "issued_at_hour": self.now, "expires_at_hour": offer["expires_at_hour"],
               "withdrawn_at_hour": None, "unit_price_minor": offer["unit_price_minor"],
               "quantity": request["quantity"], "revision": self.quote_counter[pair]}
        self.quotes.append(row)
        invitation["response"] = "quote"
        state = self.state[request_id]
        if state["first_quote_hour"] is None:
            state["first_quote_hour"] = self.now
        self.emit("quote_issued", **row)
        if self.policy["cadence_hours"] == 0:
            self.decision(self.now)

    def eligible_quotes(self, request_id):
        request = self.requests[request_id]
        return [q for q in self.quotes
                if q["request_id"] == request_id and q["id"] not in self.used_quotes
                and q["id"] not in self.declined_quotes and q["withdrawn_at_hour"] is None
                and q["issued_at_hour"] <= self.now < q["expires_at_hour"]
                and self.quote_actionable(request, self.offers[q["offer_id"]])]

    def accepted(self, business_id, *terms):
        return (_draw(self.seed, "acceptance", business_id, *terms)
                < self.businesses[business_id]["acceptance_probability"])

    def clear(self):
        if self.policy["mechanism"] == "purchase":
            self.clear_purchase()
        else:
            self.clear_barter()
        if self.policy["cadence_hours"]:
            self.decision(self.now + self.policy["cadence_hours"])

    def clear_purchase(self):
        for request in sorted(self.requests.values(), key=lambda r: (r["qualified_at_hour"], r["id"])):
            if not self.pending(request["id"]):
                continue
            quotes = self.eligible_quotes(request["id"])
            if not quotes:
                continue

            def priority(quote):
                total = quote["unit_price_minor"] * quote["quantity"]
                if self.policy["selection"] == "first_quote":
                    return quote["issued_at_hour"], total, quote["id"]
                if self.policy["selection"] == "reliability_adjusted":
                    total += ((1 - self.businesses[quote["seller_id"]]["fulfillment_probability"])
                              * self.policy["failure_penalty_minor"])
                return total, quote["issued_at_hour"], quote["id"]

            for quote in sorted(quotes, key=priority):
                self.emit("proposed", request_id=request["id"], quote_id=quote["id"], mechanism="purchase")
                terms = (request["id"], quote["offer_id"], self.state[request["id"]]["attempts"])
                if all(self.accepted(b, *terms) for b in sorted({request["buyer_id"], quote["seller_id"]})):
                    self.commit(request["id"], quote, None, None)
                    break
                # Rejection of a proposal does not erase the historically
                # actionable quote or fabricate a same-hour seller withdrawal.
                self.declined_quotes.add(quote["id"])
                self.emit("proposal_declined", request_id=request["id"], quote_id=quote["id"])

    def clear_barter(self):
        nodes = [r for r in sorted(self.requests) if self.pending(r)]
        by_pair = {}
        for request_id in nodes:
            for quote in sorted(self.eligible_quotes(request_id), key=lambda q: (q["issued_at_hour"], q["id"])):
                by_pair.setdefault((quote["offer_id"], request_id), quote)
        edges = [(source, target) for source in nodes for target in nodes
                 if source != target and (self.requests[source]["exchange_offer_id"], target) in by_pair]
        if not edges:
            return
        plan = pack_cycles(nodes, edges, self.policy["max_cycle_length"], self.s["limits"]["solver_work_budget"])
        self.solver_runs.append({"hour": self.now, **plan})
        for nodes_in_cycle in plan["cycles"]:
            legs = [(source, target, by_pair[(self.requests[source]["exchange_offer_id"], target)])
                    for source, target in zip(nodes_in_cycle, nodes_in_cycle[1:] + nodes_in_cycle[:1])]
            self.emit("cycle_proposed", request_ids=nodes_in_cycle, solver_status=plan["status"])
            participants = sorted({self.requests[r]["buyer_id"] for r in nodes_in_cycle})
            terms = ("barter", tuple(nodes_in_cycle), tuple(self.state[r]["attempts"] for r in nodes_in_cycle))
            if not all(self.accepted(b, *terms) for b in participants):
                for _, _, quote in legs:
                    self.declined_quotes.add(quote["id"])
                self.emit("cycle_declined", request_ids=nodes_in_cycle)
                if self.policy["cadence_hours"] == 0:
                    self.decision(self.now + 1)
                continue
            cycle = {"id": f"cycle-{len(self.cycles)}", "request_ids": nodes_in_cycle,
                     "order_ids": [], "committed_at_hour": self.now,
                     "closed_at_hour": None, "status": "committed"}
            self.cycles.append(cycle)
            for source, target, quote in legs:
                order = self.commit(target, quote, cycle["id"], source)
                cycle["order_ids"].append(order["id"])
            self.emit("cycle_committed", cycle_id=cycle["id"], request_ids=nodes_in_cycle)

    def commit(self, request_id, quote, cycle_id, source_request_id):
        request, state = self.requests[request_id], self.state[request_id]
        offer = self.offers[quote["offer_id"]]
        if not self.quote_actionable(request, offer):
            raise RuntimeError("commit lost an exclusive capacity or deadline precondition")
        state["attempts"] += 1
        row = {"id": f"order-{len(self.orders)}", "request_id": request_id,
               "quote_id": quote["id"], "offer_id": offer["id"],
               "seller_id": offer["seller_id"], "buyer_id": request["buyer_id"],
               "quantity": request["quantity"], "unit_price_minor": quote["unit_price_minor"],
               "accepted_at_hour": self.now, "promised_at_hour": self.now + offer["delivery_hours"],
               "delivered_at_hour": None, "buyer_accepted_at_hour": None,
               "failed_at_hour": None, "cancelled_at_hour": None,
               "cycle_id": cycle_id, "source_request_id": source_request_id,
               "attempt": state["attempts"]}
        self.orders.append(row)
        self.used_quotes.add(quote["id"])
        self.stock[offer["id"]]["reserved"] += request["quantity"]
        state["active_order_id"], state["status"] = row["id"], "committed"
        if state["first_commitment_hour"] is None:
            state["first_commitment_hour"] = self.now
        self.emit("committed", **row)
        self.push(row["promised_at_hour"], 30, "deliver", row)
        return row

    def terminal(self, order):
        return (order["failed_at_hour"] is not None or order["cancelled_at_hour"] is not None
                or order["buyer_accepted_at_hour"] is not None)

    def deliver(self, order):
        if self.terminal(order) or order["delivered_at_hour"] is not None:
            return
        request = self.requests[order["request_id"]]
        outages = [s for s in self.s["shocks"] if s["kind"] == "carrier_outage"
                   and s["area"] == request["area"] and s["starts_at_hour"] <= self.now < s["ends_at_hour"]]
        if outages:
            resume = max(s["ends_at_hour"] for s in outages)
            self.emit("delivery_delayed", order_id=order["id"], resume_at_hour=resume)
            self.push(resume, 30, "deliver", order)
            return
        seller = self.businesses[order["seller_id"]]
        if (order["seller_id"] not in self.alive
                or _draw(self.seed, "leg_failure", order["request_id"], order["offer_id"], order["attempt"])
                >= seller["fulfillment_probability"]):
            self.fail(order, "failed")
            return
        stock = self.stock[order["offer_id"]]
        stock["reserved"] -= order["quantity"]
        stock["delivered"] += order["quantity"]
        order["delivered_at_hour"] = self.now
        self.state[order["request_id"]]["status"] = "delivered"
        self.emit("delivered", order_id=order["id"], quantity=order["quantity"])
        self.push(self.now + self.businesses[request["buyer_id"]]["receipt_delay_hours"], 40, "receipt", order)

    def receipt(self, order):
        if self.terminal(order):
            return
        # Fixed-delay receipt evidence is retained after physical delivery,
        # including subsequent withdrawal. Delivered goods never teleport back.
        order["buyer_accepted_at_hour"] = self.now
        state = self.state[order["request_id"]]
        state["fulfilled_at_hour"], state["active_order_id"], state["status"] = self.now, None, "fulfilled"
        self.emit("buyer_accepted", order_id=order["id"], request_id=order["request_id"])
        if order["cycle_id"] is not None:
            cycle = next(c for c in self.cycles if c["id"] == order["cycle_id"])
            members = [o for o in self.orders if o["cycle_id"] == cycle["id"]]
            if cycle["status"] == "committed" and all(o["buyer_accepted_at_hour"] is not None for o in members):
                cycle["status"], cycle["closed_at_hour"] = "fulfilled", self.now
                self.emit("cycle_fulfilled", cycle_id=cycle["id"])

    def fail(self, order, reason):
        if self.terminal(order) or order["delivered_at_hour"] is not None:
            return
        affected = [order]
        if order["cycle_id"] is not None:
            cycle = next(c for c in self.cycles if c["id"] == order["cycle_id"])
            if cycle["status"] == "committed":
                cycle["status"], cycle["closed_at_hour"] = reason, self.now
                self.emit("cycle_" + reason, cycle_id=cycle["id"], triggering_order_id=order["id"])
            affected += [o for o in self.orders if o["cycle_id"] == cycle["id"] and o is not order
                         and not self.terminal(o) and o["delivered_at_hour"] is None]
        for item in affected:
            event = reason if item is order else "cancelled"
            item[event + "_at_hour"] = self.now
            self.stock[item["offer_id"]]["reserved"] -= item["quantity"]
            state = self.state[item["request_id"]]
            state["active_order_id"] = None
            state["status"] = "withdrawn" if state["withdrawn_at_hour"] is not None else "failed"
            state["retry_after_hour"] = self.now + 1
            # Subsequent attempts must obtain fresh quotes. Preserve the quote
            # already consumed by an accepted order, even for zero-delay failure.
            for quote in self.quotes:
                if (quote["request_id"] == item["request_id"] and quote["id"] not in self.used_quotes
                        and quote["withdrawn_at_hour"] is None):
                    quote["withdrawn_at_hour"] = self.now
            self.emit(event, order_id=item["id"], request_id=item["request_id"])
            if state["attempts"] <= self.policy["rematch_rounds"] and state["withdrawn_at_hour"] is None:
                self.push(self.now + 1, 5, "retry", item["request_id"])
        # Freed capacity can serve other waiting requests even when this
        # failed request has exhausted its retries. Reaction takes one hour.
        if self.policy["cadence_hours"] == 0:
            self.decision(self.now + 1)

    def retry(self, request_id):
        if not self.pending(request_id):
            return
        self.state[request_id]["status"] = "unmatched"
        self.emit("rematching", request_id=request_id)
        for (rid, offer_id), invitation in sorted(self.invitation_by_pair.items()):
            if rid == request_id and invitation["response"] == "quote":
                seller = self.businesses[self.offers[offer_id]["seller_id"]]
                self.push(self.now + seller["response_delay_hours"], 10, "quote", (request_id, offer_id))
        if self.policy["cadence_hours"] == 0:
            self.decision(self.now)

    def withdraw(self, request_id):
        state = self.state[request_id]
        # This model has no returns. A later exit does not erase completed
        # demand from the historical pilot denominator.
        if state["withdrawn_at_hour"] is not None or state["fulfilled_at_hour"] is not None:
            return
        state["withdrawn_at_hour"], state["status"] = self.now, "withdrawn"
        self.emit("request_withdrawn", request_id=request_id)
        for order in self.orders:
            if order["request_id"] == request_id:
                self.fail(order, "cancelled")

    def exit(self, business_id):
        if business_id not in self.alive:
            return
        self.alive.remove(business_id)
        self.emit("business_exited", business_id=business_id)
        for quote in self.quotes:
            if (quote["seller_id"] == business_id and quote["withdrawn_at_hour"] is None
                    and quote["id"] not in self.used_quotes):
                quote["withdrawn_at_hour"] = self.now
        for request in self.requests.values():
            if request["buyer_id"] == business_id and request["qualified_at_hour"] <= self.now:
                self.withdraw(request["id"])
        for order in self.orders:
            if order["seller_id"] == business_id:
                self.fail(order, "failed")

    def run(self):
        self.initialize()
        while self.queue:
            self.now, _, _, kind, data = heapq.heappop(self.queue)
            if kind == "qualify":
                state = self.state[data]
                if state["withdrawn_at_hour"] is None:
                    state["status"] = "unmatched"
                    if self.requests[data]["buyer_id"] not in self.alive:
                        self.withdraw(data)
                self.emit("qualified", request_id=data)
            elif kind == "clear":
                self.clear()
            elif kind in ("outage_start", "outage_end"):
                self.emit(kind, **{key: value for key, value in data.items() if key != "kind"})
            elif kind == "quote":
                self.issue_quote(data)
            else:
                getattr(self, kind)(data)
            self.check_stock()
        self.now = self.end
        return self.result()

    def check_stock(self):
        for stock in self.stock.values():
            if (stock["reserved"] < 0 or stock["delivered"] < 0
                    or stock["reserved"] + stock["delivered"] > stock["initial"]):
                raise RuntimeError("exclusive stock conservation invariant violated")

    def result(self):
        qualified = [s for s in self.state.values() if s["qualified_at_hour"] <= self.end]
        mature = [s for s in qualified if s["qualified_at_hour"] + 168 <= self.end]
        early = [s for s in mature if s["withdrawn_at_hour"] is not None
                 and s["withdrawn_at_hour"] < s["qualified_at_hour"] + 168]
        eligible_pilot = [s for s in mature if s not in early]

        def within(row, field, window=168):
            return row[field] is not None and row[field] <= row["qualified_at_hour"] + window

        due = [s for s in qualified if self.requests[s["id"]]["due_at_hour"] <= self.end]
        promised = [o for o in self.orders if o["promised_at_hour"] <= self.end]
        delivered = [o for o in self.orders if o["delivered_at_hour"] is not None]
        final = [o for o in self.orders if o in delivered or o["failed_at_hour"] is not None
                 or o["cancelled_at_hour"] is not None]
        pending = [o for o in self.orders if o not in final]
        matched_suppliers = {}
        for order in self.orders:
            matched_suppliers[order["seller_id"]] = matched_suppliers.get(order["seller_id"], 0) + 1
        stranded = [o for o in delivered if o["source_request_id"] is not None
                    and self.state[o["source_request_id"]]["fulfilled_at_hour"] is None]
        metrics = {
            "qualified_requests": len(qualified), "mature_requests": len(mature),
            "immature_requests": len(qualified) - len(mature),
            "early_withdrawn_mature_requests": len(early),
            "quote_rate_7d": _rate(sum(within(s, "first_quote_hour") for s in mature), len(mature)),
            "pilot_quote_rate_7d": _rate(sum(within(s, "first_quote_hour") for s in eligible_pilot), len(eligible_pilot)),
            "commitment_rate_7d": _rate(sum(within(s, "first_commitment_hour") for s in mature), len(mature)),
            "fulfillment_rate_7d": _rate(sum(within(s, "fulfilled_at_hour") for s in mature), len(mature)),
            "original_due_date_fulfillment": _rate(sum(s["fulfilled_at_hour"] is not None
                and s["fulfilled_at_hour"] <= self.requests[s["id"]]["due_at_hour"] for s in due), len(due)),
            "original_promise_reliability": _rate(sum(o["delivered_at_hour"] is not None
                and o["delivered_at_hour"] <= o["promised_at_hour"] for o in promised), len(promised)),
            "final_outcome_delivery_rate": _rate(len(delivered), len(final)),
            "accepted_orders": len(self.orders),
            "failed_orders": sum(o["failed_at_hour"] is not None for o in self.orders),
            "cancelled_orders": sum(o["cancelled_at_hour"] is not None for o in self.orders),
            "pending_orders": len(pending),
            "overdue_pending_orders": sum(o["promised_at_hour"] < self.end for o in pending),
            "delivered_awaiting_buyer_acceptance": sum(o["buyer_accepted_at_hour"] is None for o in delivered),
            "recovered_requests": sum(s["fulfilled_at_hour"] is not None and s["attempts"] > 1 for s in qualified),
            "committed_cycles": len(self.cycles),
            "fulfilled_cycles": sum(c["status"] == "fulfilled" for c in self.cycles),
            "stranded_outgoing_legs": len(stranded),
            "stranded_value_at_cost_minor": sum(o["unit_price_minor"] * o["quantity"] for o in stranded),
            "coordination_cost_minor": len(self.orders) * self.policy["coordination_cost_minor_per_order"],
            "supplier_order_hhi": (sum((n / len(self.orders)) ** 2 for n in matched_suppliers.values())
                                   if self.orders else None),
            "no_response_invitations": sum(i["responded_at_hour"] is None for i in self.invitations),
        }
        if not (metrics["fulfillment_rate_7d"]["numerator"]
                <= metrics["commitment_rate_7d"]["numerator"] <= metrics["quote_rate_7d"]["numerator"]):
            raise RuntimeError("fulfillment/commitment/quote funnel invariant violated")
        return {
            "schema_version": "1.0", "source": "synthetic", "model": "demand_exchange_v1",
            "scenario": copy.deepcopy(self.s), "provenance": _provenance(self.s, self.seed),
            "metrics": metrics, "requests": list(self.state.values()), "invitations": self.invitations,
            "quotes": self.quotes, "orders": self.orders, "cycles": self.cycles,
            "inventory": [{"offer_id": key, **value, "available": self.available(key)}
                          for key, value in self.stock.items()],
            "solver_runs": self.solver_runs, "events": self.events,
        }


def simulate(scenario, seed=0):
    """Validate and run a scenario without mutating its input."""
    if type(seed) is not int or not 0 <= seed < 2**63:
        raise ScenarioError("seed must be an integer in [0, 2**63)")
    return _Run(validate_scenario(scenario), seed).run()
