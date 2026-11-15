"""Project purchase simulations to the unchanged CommerceCore pilot v1 schema.

The canonical reader counts actionable quotes and evidenced physical delivery.
It does not measure this lab's capacity-backed commitments or buyer acceptance.
Those measures remain in the simulation result, including its different treatment
of early withdrawals. This module never scores a snapshot or executes commerce.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
from typing import Any


class PilotExportError(ValueError):
    """The simulation cannot be faithfully represented by the pilot v1 schema."""


def idmap(namespace: str, identifier: str) -> str:
    """Return a stable 128-bit lowercase token for synthetic identifiers only.

    JSON encoding prevents ambiguous namespace concatenation. Hashing predictable
    IDs is not an anonymization method for live merchant data.
    """
    if not isinstance(namespace, str) or not isinstance(identifier, str):
        raise PilotExportError("ID namespace and identifier must be strings")
    value = json.dumps([namespace, identifier], ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


def _require(condition: bool, reason: str) -> None:
    if not condition:
        raise PilotExportError(reason)


def _hour(value: Any, *, nullable: bool = False) -> int | None:
    if nullable and value is None:
        return None
    _require(type(value) is int and value >= 0, "hours must be nonnegative integers")
    return value


def _amount(value: Any, *, positive: bool = False) -> int:
    _require(type(value) is int and value >= (1 if positive else 0),
             "amounts and quantities must be nonnegative integers; quantities must be positive")
    return value


def _index(rows: Any) -> dict[str, dict]:
    _require(isinstance(rows, list), "expected a row list")
    indexed: dict[str, dict] = {}
    for row in rows:
        _require(isinstance(row, dict), "expected a row object")
        key = row.get("id")
        _require(isinstance(key, str) and bool(key), "row ID must be a nonempty string")
        _require(key not in indexed, "duplicate row ID")
        indexed[key] = row
    return indexed


def _reference(index: dict, identifier: Any) -> dict:
    _require(isinstance(identifier, str) and identifier in index, "unknown row reference")
    return index[identifier]


def export_pilot_snapshot(scenario: dict, result: dict) -> dict:
    """Export an observed-through-cutoff, synthetic, purchase-only snapshot.

    Pass the exact normalized ``result['scenario']``. Future occurrences are
    omitted; known future quote expiries and delivery promises are retained.
    Barter has no monetary quote in this model and is deliberately unsupported.
    Unmodeled payments, reconciliation, fees and costs remain unknown.
    """
    _require(isinstance(scenario, dict) and isinstance(result, dict), "expected objects")
    _require(scenario.get("schema_version") == "1.0" and result.get("schema_version") == "1.0",
             "unsupported simulation schema")
    _require(result.get("source") == "synthetic", "only synthetic results may be exported")
    _require(result.get("scenario") == scenario, "result does not bind this exact scenario")
    _require(isinstance(scenario.get("policy"), dict)
             and scenario["policy"].get("mechanism") == "purchase",
             "pilot v1 export requires purchase quotes; barter export is unsupported")
    scenario_id = scenario.get("scenario_id")
    _require(isinstance(scenario_id, str) and bool(scenario_id), "missing scenario ID")
    currency = scenario.get("currency")
    _require(isinstance(currency, str) and re.fullmatch(r"[A-Z]{3}", currency) is not None,
             "invalid currency")
    start_at = scenario.get("start_at")
    _require(isinstance(start_at, str)
             and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", start_at) is not None,
             "start_at must be UTC to whole seconds")
    try:
        start = datetime.strptime(start_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise PilotExportError("invalid start_at") from exc
    cutoff = _hour(scenario.get("observed_until_hour"))

    def stamp(hour: int | None) -> str | None:
        if hour is None:
            return None
        try:
            return (start + timedelta(hours=hour)).isoformat(timespec="seconds").replace("+00:00", "Z")
        except (OverflowError, ValueError) as exc:
            raise PilotExportError("timestamp exceeds supported calendar") from exc

    def observed(hour: Any, earliest: int) -> int | None:
        value = _hour(hour, nullable=True)
        _require(value is None or value >= earliest, "event precedes its cause")
        return value if value is not None and value <= cutoff else None

    def token(kind: str, source_id: str) -> str:
        namespace = json.dumps(["economic-simulation", "1.0", scenario_id, kind], separators=(",", ":"))
        return idmap(namespace, source_id)

    businesses = _index(scenario.get("businesses"))
    requests = _index(scenario.get("requests"))
    offers = _index(scenario.get("offers"))
    request_results = _index(result.get("requests"))
    selected_requests: dict[str, tuple[dict, int | None]] = {}
    request_rows = []
    for request_id, request in requests.items():
        qualified = _hour(request.get("qualified_at_hour"))
        if qualified > cutoff:
            continue
        _reference(businesses, request.get("buyer_id"))
        _amount(request.get("quantity"), positive=True)
        _amount(request.get("max_unit_price_minor"))
        state = _reference(request_results, request_id)
        _require(_hour(state.get("qualified_at_hour")) == qualified, "qualification changed")
        withdrawn = observed(state.get("withdrawn_at_hour"), qualified)
        selected_requests[request_id] = (request, withdrawn)
        request_rows.append({"id": token("request", request_id), "qualified_at": stamp(qualified),
                             "withdrawn_at": stamp(withdrawn)})

    # Canonical invitations are unique by merchant/request, not by offer revision.
    invitations: dict[tuple[str, str], tuple[int, int | None]] = {}
    for invitation in _index(result.get("invitations")).values():
        invited = _hour(invitation.get("invited_at_hour"))
        if invited > cutoff:
            continue
        request_id, seller_id = invitation.get("request_id"), invitation.get("seller_id")
        _require(request_id in selected_requests, "invitation has no observed request")
        request, withdrawn = selected_requests[request_id]
        _reference(businesses, seller_id)
        offer = _reference(offers, invitation.get("offer_id"))
        _require(offer.get("seller_id") == seller_id, "invitation seller differs from offer")
        _require(invited >= request["qualified_at_hour"], "invitation precedes qualification")
        _require(withdrawn is None or invited < withdrawn, "invitation follows withdrawal")
        response = invitation.get("response")
        _require(response in {"quote", "declined", "no_response"}, "unknown response")
        responded = observed(invitation.get("responded_at_hour"), invited)
        _require(response != "no_response" or responded is None, "nonresponse has a response time")
        key = (request_id, seller_id)
        prior_invited, prior_responded = invitations.get(key, (invited, None))
        responses = [value for value in (prior_responded, responded) if value is not None]
        invitations[key] = (min(invited, prior_invited), min(responses) if responses else None)

    quote_rows: dict[str, dict] = {}
    quote_sources = _index(result.get("quotes"))
    for quote_id, quote in quote_sources.items():
        issued = _hour(quote.get("issued_at_hour"))
        if issued > cutoff:
            continue
        request_id, seller_id = quote.get("request_id"), quote.get("seller_id")
        _require(request_id in selected_requests, "quote has no observed request")
        request, _ = selected_requests[request_id]
        offer = _reference(offers, quote.get("offer_id"))
        _require(offer.get("seller_id") == seller_id, "quote seller differs from offer")
        _require((request_id, seller_id) in invitations, "quote has no invitation")
        _, responded = invitations[(request_id, seller_id)]
        _require(responded is not None and responded <= issued, "quote has no preceding response")
        expires = _hour(quote.get("expires_at_hour"))
        _require(expires > issued, "quote expires at or before issuance")
        withdrawn = observed(quote.get("withdrawn_at_hour"), issued)
        quantity = _amount(quote.get("quantity"), positive=True)
        price = _amount(quote.get("unit_price_minor"))
        qualified = (
            quantity >= request["quantity"]
            and price <= request["max_unit_price_minor"]
            and seller_id != request["buyer_id"]
            and all(offer.get(field) == request.get(field) for field in ("category", "area", "unit"))
            and _hour(offer.get("available_at_hour")) <= issued < _hour(offer.get("expires_at_hour"))
        )
        quote_rows[quote_id] = {
            "id": token("quote", quote_id), "request_id": token("request", request_id),
            "merchant_id": token("merchant", seller_id), "issued_at": stamp(issued),
            "expires_at": stamp(expires), "withdrawn_at": stamp(withdrawn),
            "qualified": qualified, "currency": currency, "all_in_minor": price * quantity,
        }

    order_rows = []
    used_quotes: set[str] = set()
    attempts: dict[str, list[tuple[int, int | None, str]]] = {}
    for order_id, order in _index(result.get("orders")).items():
        accepted = _hour(order.get("accepted_at_hour"))
        if accepted > cutoff:
            continue
        quote_id = order.get("quote_id")
        _require(quote_id in quote_rows and quote_id not in used_quotes, "order needs an unused observed quote")
        quote = quote_sources[quote_id]
        request_id = quote["request_id"]
        request, request_withdrawn = selected_requests[request_id]
        _require(order.get("request_id") == request_id and order.get("buyer_id") == request["buyer_id"],
                 "order request identity changed")
        _require(all(order.get(field) == quote.get(field) for field in ("offer_id", "seller_id", "unit_price_minor")),
                 "order quote terms changed")
        _require(_amount(order.get("quantity"), positive=True) == request["quantity"] == quote["quantity"],
                 "pilot v1 requires an exact full-quantity order quote")
        _require(order.get("cycle_id") is None, "purchase export cannot contain a barter cycle")
        quote_withdrawn = observed(quote.get("withdrawn_at_hour"), quote["issued_at_hour"])
        _require(quote_rows[quote_id]["qualified"]
                 and quote["issued_at_hour"] <= accepted < quote["expires_at_hour"]
                 and (quote_withdrawn is None or accepted < quote_withdrawn)
                 and (request_withdrawn is None or accepted < request_withdrawn),
                 "order accepted an inactive quote")
        promised = _hour(order.get("promised_at_hour"))
        _require(promised >= accepted, "promise precedes acceptance")
        delivered = observed(order.get("delivered_at_hour"), accepted)
        buyer_accepted = observed(order.get("buyer_accepted_at_hour"), accepted)
        _require(buyer_accepted is None or (delivered is not None and delivered <= buyer_accepted),
                 "buyer acceptance has no preceding full delivery")
        terminals = [(state, hour) for state, hour in (
            ("fulfilled", delivered),
            ("failed", observed(order.get("failed_at_hour"), accepted)),
            ("cancelled", observed(order.get("cancelled_at_hour"), accepted)),
        ) if hour is not None]
        _require(len(terminals) <= 1, "conflicting terminal outcomes")
        outcome, outcome_at = terminals[0] if terminals else ("pending", None)
        used_quotes.add(quote_id)
        attempts.setdefault(request_id, []).append((accepted, outcome_at, outcome))
        order_rows.append({
            "id": token("order", order_id), "quote_id": token("quote", quote_id),
            "servicing_store_id": None, "currency": currency, "accepted_at": stamp(accepted),
            "promised_by": stamp(promised), "outcome": outcome, "outcome_at": stamp(outcome_at),
            "paid_at": None, "returned_at": None, "disputed_at": None, "reconciled_at": None,
            "gross_minor": None, "refunds": [],
            "fees": {"servicing_store": {"gross_minor": 0, "reversed_minor": 0}, "platform": None},
            "costs_minor": {"merchant": None, "servicing_store": 0, "platform": None},
        })
    for entries in attempts.values():
        entries.sort(key=lambda row: row[0])
        for previous, current in zip(entries, entries[1:]):
            _require(previous[2] in {"failed", "cancelled"} and previous[1] < current[0],
                     "overlapping or same-hour retry cannot be represented by pilot v1")

    invitation_rows = [{
        "request_id": token("request", request_id), "merchant_id": token("merchant", seller_id),
        "invited_at": stamp(invited), "responded_at": stamp(responded),
    } for (request_id, seller_id), (invited, responded) in invitations.items()]
    return {
        "schema_version": 1, "dataset": "synthetic", "cohort_started_at": start_at, "as_of": stamp(cutoff),
        "requests": sorted(request_rows, key=lambda row: row["id"]),
        "invitations": sorted(invitation_rows, key=lambda row: (row["request_id"], row["merchant_id"])),
        "quotes": sorted(quote_rows.values(), key=lambda row: row["id"]),
        "orders": sorted(order_rows, key=lambda row: row["id"]),
        "unallocated_costs": [{"currency": currency, "role": role, "minor": None}
                              for role in ("merchant", "platform")],
    }
