"""Deterministic, offline scorecard for one merchant procurement pilot."""

import argparse
from collections import defaultdict
from datetime import datetime, timedelta
import json
from pathlib import Path
import re
from statistics import median

ROLES = ("merchant", "servicing_store", "platform")
COST_SHOCKS = (0, 1000, 2500)  # basis points


class InvalidSnapshot(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidSnapshot(message)


def fields(row, names, label):
    require(isinstance(row, dict) and row.keys() == set(names.split()),
            f"{label}: unexpected or missing fields")


def rows(value, label):
    require(isinstance(value, list), f"{label}: expected an array")
    return value


def token(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value),
            "expected an opaque 32-character lowercase hex key")


def currency(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Z]{3}", value),
            "expected a three-letter currency code")


def amount(value, nullable=False):
    require((nullable and value is None) or (type(value) is int and value >= 0),
            "expected nonnegative integer minor units or an explicitly allowed null")


def timestamp(value):
    require(isinstance(value, str) and re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value),
        "expected a UTC timestamp to whole seconds")
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        raise InvalidSnapshot("invalid calendar timestamp") from None


def occurred(value, earliest, as_of, optional=False):
    if optional and value is None:
        return None
    instant = timestamp(value)
    require(earliest <= instant <= as_of, "event outside its observation interval")
    return instant


def unique(index, key, value):
    require(key not in index, "duplicate snapshot key")
    index[key] = value


def reference(index, key):
    token(key)
    require(key in index, "unknown snapshot reference")
    return index[key]


def ratio(numerator, denominator):
    return {"numerator": numerator, "denominator": denominator}


def rate_with_followup(eligible, predicate, total):
    return {**ratio(sum(predicate(row) for row in eligible), len(eligible)),
            "incomplete": total - len(eligible)}


def read_demand(snapshot, start, as_of):
    requests, invitations, quotes = {}, {}, {}
    for row in rows(snapshot["requests"], "requests"):
        fields(row, "id qualified_at withdrawn_at", "request")
        token(row["id"])
        qualified = occurred(row["qualified_at"], start, as_of)
        withdrawn = occurred(row["withdrawn_at"], qualified, as_of, optional=True)
        unique(requests, row["id"], (qualified, withdrawn))
    for row in rows(snapshot["invitations"], "invitations"):
        fields(row, "request_id merchant_id invited_at responded_at", "invitation")
        qualified, withdrawn = reference(requests, row["request_id"])
        token(row["merchant_id"])
        invited = occurred(row["invited_at"], qualified, as_of)
        require(withdrawn is None or invited < withdrawn, "invitation after request withdrawal")
        responded = occurred(row["responded_at"], invited, as_of, optional=True)
        unique(invitations, (row["request_id"], row["merchant_id"]), (invited, responded))
    for row in rows(snapshot["quotes"], "quotes"):
        fields(row, "id request_id merchant_id issued_at expires_at withdrawn_at qualified currency all_in_minor",
               "quote version")
        token(row["id"])
        reference(requests, row["request_id"])
        token(row["merchant_id"])
        key = (row["request_id"], row["merchant_id"])
        require(key in invitations, "quote requires a merchant invitation")
        _, responded = invitations[key]
        require(responded is not None, "quote requires a merchant response")
        issued = occurred(row["issued_at"], responded, as_of)
        expires = timestamp(row["expires_at"])
        require(issued < expires, "quote must expire after issuance")
        withdrawn = occurred(row["withdrawn_at"], issued, as_of, optional=True)
        require(type(row["qualified"]) is bool, "expected quote qualification flag")
        currency(row["currency"])
        amount(row["all_in_minor"])
        unique(quotes, row["id"], dict(row, issued_at=issued, expires_at=expires, withdrawn_at=withdrawn))
    return requests, invitations, quotes


def actionable(quote, request_withdrawn, at):
    return (quote["qualified"] and quote["issued_at"] <= at < quote["expires_at"]
            and (quote["withdrawn_at"] is None or at < quote["withdrawn_at"])
            and (request_withdrawn is None or at < request_withdrawn))


def demand_metrics(requests, invitations, quotes, as_of):
    first_quote = {}
    for quote in quotes.values():
        request_id = quote["request_id"]
        qualified, withdrawn = requests[request_id]
        issued = quote["issued_at"]
        if actionable(quote, withdrawn, issued) and issued - qualified <= timedelta(days=7):
            first_quote[request_id] = min(issued, first_quote.get(request_id, issued))

    mature, early_withdrawals = {}, 0
    window = timedelta(days=7)
    for request_id, (qualified, withdrawn) in requests.items():
        if withdrawn is not None and withdrawn - qualified < window:
            early_withdrawals += 1
        elif as_of - qualified >= window:
            mature[request_id] = qualified + window

    latencies = [(first_quote[key] - requests[key][0]).total_seconds()
                 for key in mature if key in first_quote]
    response_due = [responded is not None and responded <= mature[request_id]
                    for (request_id, _), (invited, responded) in invitations.items()
                    if request_id in mature and invited <= mature[request_id]]
    return {
        "qualified_requests": len(requests),
        "seven_day_match": {**ratio(len(latencies), len(mature)),
                            "incomplete": len(requests) - len(mature) - early_withdrawals,
                            "withdrawn_early": early_withdrawals},
        "first_quote_within_seven_days": {
            "median_seconds": median(latencies) if latencies else None,
            "observed": len(latencies),
            "unmatched_mature": len(mature) - len(latencies),
        },
        "seven_day_invitation_response": ratio(sum(response_due), len(response_due)),
    }


def order_economics(row, accepted, paid, as_of, refund_ids):
    gross = row["gross_minor"]
    amount(gross, nullable=True)
    require(paid is not None or gross in (None, 0), "positive gross requires confirmed payment")
    reconciled = occurred(row["reconciled_at"], accepted, as_of, optional=True)
    refunded = 0
    for refund in rows(row["refunds"], "refunds"):
        fields(refund, "id at minor", "refund")
        token(refund["id"])
        unique(refund_ids, refund["id"], True)
        require(paid is not None, "refund requires confirmed payment")
        occurred(refund["at"], paid, reconciled or as_of)
        amount(refund["minor"])
        require(refund["minor"] > 0, "refund must be positive")
        refunded += refund["minor"]
    require(refunded == 0 or (gross is not None and refunded <= gross),
            "refunds exceed known gross")

    fees, costs = row["fees"], row["costs_minor"]
    fields(fees, "servicing_store platform", "fees")
    fields(costs, "merchant servicing_store platform", "incremental costs")
    net_fees = {}
    for role, fee in fees.items():
        if fee is None:
            net_fees[role] = None
            continue
        fields(fee, "gross_minor reversed_minor", "fee")
        amount(fee["gross_minor"])
        amount(fee["reversed_minor"])
        require(fee["reversed_minor"] <= fee["gross_minor"], "fee reversals exceed fee")
        net_fees[role] = fee["gross_minor"] - fee["reversed_minor"]
    for cost in costs.values():
        amount(cost, nullable=True)
    if row["servicing_store_id"] is None:
        require(fees["servicing_store"] == {"gross_minor": 0, "reversed_minor": 0}
                and costs["servicing_store"] == 0, "absent servicing store requires zero fees and costs")
    merchant_parts = (gross, *net_fees.values())
    revenues = dict(net_fees, merchant=(gross - refunded - sum(net_fees.values())
                                        if None not in merchant_parts else None))
    return reconciled, revenues


def read_orders(snapshot, requests, quotes, start, as_of):
    orders, accepted_quotes, refund_ids = {}, {}, {}
    by_request = defaultdict(list)
    for row in rows(snapshot["orders"], "orders"):
        fields(row, "id quote_id servicing_store_id currency accepted_at promised_by outcome outcome_at "
               "paid_at returned_at disputed_at reconciled_at gross_minor refunds fees costs_minor", "order")
        token(row["id"])
        quote = reference(quotes, row["quote_id"])
        _, withdrawn = requests[quote["request_id"]]
        accepted = occurred(row["accepted_at"], start, as_of)
        require(actionable(quote, withdrawn, accepted), "order accepts an ineligible or inactive quote")
        unique(accepted_quotes, row["quote_id"], True)
        store = row["servicing_store_id"]
        if store is not None:
            token(store)
            require(store != quote["merchant_id"], "servicing store must be distinct from the supplier")
        require(row["currency"] == quote["currency"], "order and quote currencies differ")
        promise = timestamp(row["promised_by"])
        require(accepted <= promise, "promise predates acceptance")
        outcome = row["outcome"]
        require(outcome in ("pending", "fulfilled", "failed", "cancelled"), "invalid fulfillment outcome")
        completed = occurred(row["outcome_at"], accepted, as_of, optional=outcome == "pending")
        require((outcome == "pending") == (completed is None), "outcome timestamp does not match status")
        paid = occurred(row["paid_at"], accepted, as_of, optional=True)
        returned = occurred(row["returned_at"], completed or accepted, as_of, optional=True)
        require(returned is None or outcome == "fulfilled", "return requires prior fulfillment")
        disputed = occurred(row["disputed_at"], accepted, as_of, optional=True)
        reconciled, revenue = order_economics(row, accepted, paid, as_of, refund_ids)
        if reconciled is not None:
            require(completed is not None and all(t is None or t <= reconciled
                    for t in (completed, paid, returned, disputed)),
                    "reconciliation predates an outcome or other recorded event")
        realized = max(paid, completed) if paid is not None and outcome == "fulfilled" else None
        unique(orders, row["id"], dict(
            row, merchant_id=quote["merchant_id"], accepted_at=accepted, realized_at=realized,
            on_time=outcome == "fulfilled" and completed <= promise, returned_at=returned,
            disputed_at=disputed, reconciled_at=reconciled, revenue=revenue, promised_by=promise,
        ))
        by_request[quote["request_id"]].append((accepted, completed, outcome))
    for attempts in by_request.values():
        attempts.sort(key=lambda attempt: attempt[0])
        for previous, following in zip(attempts, attempts[1:]):
            require(previous[2] in ("failed", "cancelled") and previous[1] < following[0],
                    "overlapping or duplicate request acceptance")
    return orders


def outcome_metrics(orders, as_of):
    final = [order for order in orders if order["outcome"] != "pending"]
    thirty_days = timedelta(days=30)
    dispute_eligible = [order for order in orders if as_of - order["accepted_at"] >= thirty_days]
    ninety_days = timedelta(days=90)
    realized_by_merchant = defaultdict(list)
    for order in orders:
        if order["realized_at"] is not None:
            realized_by_merchant[order["merchant_id"]].append(order["realized_at"])
    cohorts = [sorted(times) for times in realized_by_merchant.values()]
    repeat_eligible = [times for times in cohorts if as_of - times[0] >= ninety_days]
    return {
        "accepted_orders": len(orders),
        "realized_orders": sum(len(times) for times in cohorts),
        "on_time_fulfillment": {
            **rate_with_followup(final, lambda o: o["on_time"], len(orders)),
            "pending_past_promise": sum(o["outcome"] == "pending" and o["promised_by"] <= as_of
                                        for o in orders),
        },
        "cancelled": ratio(sum(o["outcome"] == "cancelled" for o in final), len(final)),
        "returns_to_date": ratio(sum(o["returned_at"] is not None for o in final),
                                 sum(o["outcome"] == "fulfilled" for o in final)),
        "refunded_orders_to_date": ratio(sum(bool(o["refunds"]) for o in orders), len(orders)),
        "intervention_disputes_30_day": rate_with_followup(
            dispute_eligible,
            lambda o: o["disputed_at"] is not None and o["disputed_at"] - o["accepted_at"] <= thirty_days,
            len(orders),
        ),
        "merchant_repeat_90_day": rate_with_followup(
            repeat_eligible, lambda times: len(times) >= 2 and times[1] - times[0] <= ninety_days,
            len(cohorts),
        ),
    }


def margin(revenue, cost, basis_points):
    # Round additional expense up to a whole minor unit per transaction.
    return revenue - cost - (cost * basis_points + 9999) // 10000


def summarize_margins(orders, overhead, include_orders):
    grouped = defaultdict(list)
    for order in orders.values():
        for role in ROLES:
            if role != "servicing_store" or order["servicing_store_id"] is not None:
                grouped[(order["currency"], role)].append((order, order["revenue"][role],
                                                          order["costs_minor"][role]))

    aggregates = defaultdict(dict)
    details = defaultdict(dict)
    for code, role in sorted(grouped.keys() | overhead.keys()):
        entries = grouped[(code, role)]
        known = []
        missing, open_count = 0, 0
        for order, revenue, cost in entries:
            if order["reconciled_at"] is None:
                status = "unreconciled"
                open_count += 1
            elif revenue is None or cost is None:
                status = "missing_inputs"
                missing += 1
            else:
                status = "complete"
                known.append((revenue, cost))
            if include_orders:
                detail = {"status": status}
                if status == "complete":
                    detail.update(revenue_minor=revenue, incremental_cost_minor=cost,
                                  margin_minor=revenue - cost, cost_headroom_minor=revenue - cost)
                details[order["id"]][role] = detail

        unallocated = overhead.get((code, role), 0)
        complete = len(known) == len(entries) and unallocated is not None
        scenarios = []
        for shock in COST_SHOCKS:
            margins = [margin(revenue, cost, shock) for revenue, cost in known]
            known_total = sum(margins) if known else None
            scenarios.append({
                "added_cost_basis_points": shock,
                "known_orders_margin_minor": known_total,
                "nonpositive_known_orders": sum(value <= 0 for value in margins),
                "negative_known_orders": sum(value < 0 for value in margins),
                "cohort_margin_minor": sum(margins) + margin(0, unallocated, shock) if complete else None,
            })
        aggregates[code][role] = {
            "accepted": len(entries), "complete": len(known), "unreconciled": open_count,
            "missing_inputs": missing,
            "known_orders_revenue_minor": sum(revenue for revenue, _ in known) if known else None,
            "known_orders_cost_minor": sum(cost for _, cost in known) if known else None,
            "unallocated_cost_minor": unallocated, "scenarios": scenarios,
        }
    result = {"by_currency": dict(aggregates)}
    if include_orders:
        result["orders"] = [
            {"id": key, "currency": orders[key]["currency"], "roles": details[key]}
            for key in sorted(details)
        ]
    return result


def score(snapshot, *, include_orders=False):
    fields(snapshot, "schema_version dataset cohort_started_at as_of requests invitations quotes orders "
           "unallocated_costs", "snapshot")
    require(type(snapshot["schema_version"]) is int and snapshot["schema_version"] == 1,
            "unsupported snapshot schema")
    require(snapshot["dataset"] in ("synthetic", "observed"), "invalid dataset classification")
    start, as_of = timestamp(snapshot["cohort_started_at"]), timestamp(snapshot["as_of"])
    require(start <= as_of, "cohort starts after observation cutoff")
    requests, invitations, quotes = read_demand(snapshot, start, as_of)
    orders = read_orders(snapshot, requests, quotes, start, as_of)
    overhead = {}
    for row in rows(snapshot["unallocated_costs"], "unallocated costs"):
        fields(row, "currency role minor", "unallocated cost")
        currency(row["currency"])
        require(row["role"] in ROLES, "invalid cost role")
        amount(row["minor"], nullable=True)
        unique(overhead, (row["currency"], row["role"]), row["minor"])
    demand = demand_metrics(requests, invitations, quotes, as_of)
    demand["requests_with_accepted_order"] = len({quotes[o["quote_id"]]["request_id"]
                                                   for o in orders.values()})
    return {
        "schema_version": 1,
        "dataset": snapshot["dataset"],
        "cohort_started_at": snapshot["cohort_started_at"],
        "as_of": snapshot["as_of"],
        "demand": demand,
        "orders": outcome_metrics(list(orders.values()), as_of),
        "economics": summarize_margins(orders, overhead, include_orders),
    }


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        unique(result, key, value)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--include-orders", action="store_true", help="include private pseudonymous order detail")
    args = parser.parse_args()
    try:
        with args.snapshot.open(encoding="utf-8") as source:
            snapshot = json.load(source, object_pairs_hook=unique_object)
        report = score(snapshot, include_orders=args.include_orders)
    except InvalidSnapshot as exc:
        parser.exit(2, f"Invalid snapshot: {exc}\n")
    except (OSError, UnicodeError, ValueError, OverflowError):
        parser.exit(2, "Could not read a valid snapshot.\n")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
