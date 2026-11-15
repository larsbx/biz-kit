"""Generate versioned structural schemas; cross-field rules stay in scenario.py."""

from pathlib import Path
import json
import sys
from ..scenario import BUSINESS_DEFAULTS, POLICY_DEFAULTS, LIMIT_DEFAULTS, MAX_INTEGER


def contracts():
    def obj(p, required=None):
        return {
            "type": "object",
            "properties": p,
            "required": list(p) if required is None else required,
            "additionalProperties": False,
        }

    def integer(minimum=0, maximum=MAX_INTEGER):
        return {"type": "integer", "minimum": minimum, "maximum": maximum}

    def arr(items):
        return {"type": "array", "items": items}

    def nullable(value):
        return {"anyOf": [value, {"type": "null"}]}

    def default(s, v):
        return {**s, "default": v}

    token = {"type": "string", "pattern": "^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}$"}
    string = {"type": "string"}
    prob = {"type": "number", "minimum": 0, "maximum": 1}
    intnull = nullable(integer())
    nullable_id = nullable(string)
    business = obj(
        {
            "id": token,
            **{
                k: default(integer() if "hours" in k else prob, v)
                for k, v in BUSINESS_DEFAULTS.items()
            },
        },
        ["id"],
    )
    offer = obj(
        {
            k: token
            if k in ["id", "seller_id", "area", "category", "unit"]
            else integer(1 if k == "quantity" else 0)
            for k in [
                "id",
                "seller_id",
                "category",
                "area",
                "unit",
                "quantity",
                "available_at_hour",
                "expires_at_hour",
                "unit_price_minor",
                "delivery_hours",
            ]
        }
    )
    props = {
        k: token
        if k in ["id", "buyer_id", "category", "area", "unit"]
        else integer(1 if k == "quantity" else 0)
        for k in [
            "id",
            "buyer_id",
            "category",
            "area",
            "unit",
            "quantity",
            "qualified_at_hour",
            "due_at_hour",
            "max_unit_price_minor",
        ]
    }
    required = list(props)
    props.update(
        withdraw_at_hour=default(intnull, None),
        exchange_offer_id=default(nullable(token), None),
        acceptable_offer_ids=default(
            nullable({**arr(token), "uniqueItems": True}), None
        ),
    )
    policy = {
        "mechanism": {"enum": ["purchase", "barter"]},
        "cadence_hours": integer(),
        "selection": {"enum": ["first_quote", "lowest_cost", "reliability_adjusted"]},
        "max_cycle_length": nullable(integer(2)),
        "rematch_rounds": integer(0, 10),
        "failure_penalty_minor": integer(),
        "coordination_cost_minor_per_order": integer(),
    }
    scenario = obj(
        {
            "schema_version": {"const": "1.0"},
            "scenario_id": token,
            "description": default({"type": "string", "maxLength": 4096}, ""),
            "start_at": {
                "type": "string",
                "pattern": r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$",
            },
            "observed_until_hour": integer(),
            "currency": {"type": "string", "pattern": "^[A-Z]{3}$"},
            "annual_membership_fee_minor": default(integer(), 25000),
            "businesses": arr(business),
            "requests": arr(obj(props, required)),
            "offers": arr(offer),
            "policy": obj(
                {k: default(v, POLICY_DEFAULTS[k]) for k, v in policy.items()}, []
            ),
            "shocks": arr(
                {
                    "oneOf": [
                        obj(
                            {
                                "kind": {"const": "business_exit"},
                                "business_id": token,
                                "at_hour": integer(),
                            }
                        ),
                        obj(
                            {
                                "kind": {"const": "carrier_outage"},
                                "area": token,
                                "starts_at_hour": integer(),
                                "ends_at_hour": integer(1),
                            }
                        ),
                    ]
                }
            ),
            "limits": obj(
                {k: default(integer(1), v) for k, v in LIMIT_DEFAULTS.items()}, []
            ),
        },
        [
            "schema_version",
            "scenario_id",
            "start_at",
            "observed_until_hour",
            "currency",
            "businesses",
            "requests",
            "offers",
        ],
    )
    scenario = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://github.com/larsbx/biz-kit/economic-simulation/scenario-v1",
        "title": "Synthetic economic scenario v1",
        "description": "Structural validation; runtime also checks references, IDs, exclusive barter lots and timestamp ordering.",
        **scenario,
    }
    rate = obj(
        {"numerator": integer(), "denominator": integer(), "rate": nullable(prob)}
    )
    rates = [
        "quote_rate_7d",
        "pilot_quote_rate_7d",
        "commitment_rate_7d",
        "fulfillment_rate_7d",
        "original_due_date_fulfillment",
        "original_promise_reliability",
        "final_outcome_delivery_rate",
    ]
    counts = [
        "qualified_requests",
        "mature_requests",
        "immature_requests",
        "early_withdrawn_mature_requests",
        "accepted_orders",
        "failed_orders",
        "cancelled_orders",
        "pending_orders",
        "overdue_pending_orders",
        "delivered_awaiting_buyer_acceptance",
        "recovered_requests",
        "committed_cycles",
        "fulfilled_cycles",
        "stranded_outgoing_legs",
        "stranded_value_at_cost_minor",
        "coordination_cost_minor",
        "no_response_invitations",
    ]
    request = obj(
        {
            "id": token,
            "qualified_at_hour": integer(),
            "first_quote_hour": intnull,
            "first_commitment_hour": intnull,
            "fulfilled_at_hour": intnull,
            "withdrawn_at_hour": intnull,
            "status": {
                "enum": [
                    "not_yet_qualified",
                    "unmatched",
                    "committed",
                    "delivered",
                    "fulfilled",
                    "withdrawn",
                    "failed",
                ]
            },
            "attempts": integer(),
            "active_order_id": nullable_id,
            "retry_after_hour": integer(),
        }
    )
    invitation = obj(
        {
            "id": string,
            "request_id": token,
            "offer_id": token,
            "seller_id": token,
            "invited_at_hour": integer(),
            "responded_at_hour": intnull,
            "response": {"enum": ["quote", "declined", "no_response"]},
        }
    )
    quote = obj(
        {
            "id": string,
            "request_id": token,
            "offer_id": token,
            "seller_id": token,
            "issued_at_hour": integer(),
            "expires_at_hour": integer(),
            "withdrawn_at_hour": intnull,
            "unit_price_minor": integer(),
            "quantity": integer(1),
            "revision": integer(1),
        }
    )
    order = obj(
        {
            **{
                k: string
                for k in [
                    "id",
                    "request_id",
                    "quote_id",
                    "offer_id",
                    "seller_id",
                    "buyer_id",
                ]
            },
            "quantity": integer(1),
            "unit_price_minor": integer(),
            "accepted_at_hour": integer(),
            "promised_at_hour": integer(),
            **{
                k: intnull
                for k in [
                    "delivered_at_hour",
                    "buyer_accepted_at_hour",
                    "failed_at_hour",
                    "cancelled_at_hour",
                ]
            },
            "cycle_id": nullable_id,
            "source_request_id": nullable_id,
            "attempt": integer(1),
        }
    )
    cycle = obj(
        {
            "id": string,
            "request_ids": arr(token),
            "order_ids": arr(string),
            "committed_at_hour": integer(),
            "closed_at_hour": intnull,
            "status": {"enum": ["committed", "fulfilled", "failed", "cancelled"]},
        }
    )
    hexhash = {"type": "string", "pattern": "^[0-9a-f]{64}$"}
    result = obj(
        {
            "schema_version": {"const": "1.0"},
            "source": {"const": "synthetic"},
            "model": {"const": "demand_exchange_v1"},
            "scenario": {"$ref": "#/$defs/scenario"},
            "provenance": obj(
                {
                    "seed": integer(0, 2**63 - 1),
                    "scenario_sha256": hexhash,
                    "implementation_version": string,
                    "source_revision": nullable(string),
                    "source_tree_dirty": nullable({"type": "boolean"}),
                    "model_source_sha256": hexhash,
                    "model_source_scope": string,
                    "python_version": string,
                    "randomness": {"const": "sha256-keyed-event-primitives-v1"},
                    "calibration": {"const": "uncalibrated_synthetic"},
                }
            ),
            "metrics": obj(
                {
                    **{k: integer() for k in counts},
                    **{k: rate for k in rates},
                    "supplier_order_hhi": nullable(prob),
                }
            ),
            "requests": arr(request),
            "invitations": arr(invitation),
            "quotes": arr(quote),
            "orders": arr(order),
            "cycles": arr(cycle),
            "inventory": arr(
                obj(
                    {
                        "offer_id": token,
                        **{
                            k: integer()
                            for k in ["initial", "reserved", "delivered", "available"]
                        },
                    }
                )
            ),
            "solver_runs": arr(
                obj(
                    {
                        "hour": integer(),
                        "cycles": arr(arr(token)),
                        "matched_count": integer(),
                        "status": {"const": "optimal"},
                        "algorithm": string,
                        "work_units": integer(),
                    }
                )
            ),
            "events": arr(
                obj(
                    {
                        "sequence": integer(),
                        "hour": integer(),
                        "kind": string,
                        "data": {"type": "object"},
                    }
                )
            ),
        }
    )
    result = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://github.com/larsbx/biz-kit/economic-simulation/result-v1",
        "title": "Synthetic economic result v1",
        **result,
        "$defs": {
            "scenario": {
                k: v for k, v in scenario.items() if k not in ("$schema", "$id")
            }
        },
    }
    return {"scenario": scenario, "result": result}


if __name__ == "__main__":
    for name, value in contracts().items():
        path = Path(__file__).with_name(name + ".schema.json")
        text = json.dumps(value, indent=2) + "\n"
        if "--check" in sys.argv:
            if path.read_text() != text:
                raise SystemExit(f"stale schema: {path}")
        else:
            path.write_text(text)
