"""JSON command-line boundary for scripts and a future experiment interface."""

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from .comparison import compare
from .engine import SimulationLimitError, simulate
from .generator import generate_market
from .matching import MatchingBudgetExceeded
from .pilot import export_pilot_snapshot
from .scenario import ScenarioError, load_json


def _write(value, target):
    payload = json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if target:
        Path(target).write_text(payload, encoding="utf-8")
    else:
        sys.stdout.write(payload)


def _parser():
    parser = argparse.ArgumentParser(
        description="Synthetic economic experiments; no live business effects"
    )
    sub = parser.add_subparsers(dest="command", required=True)
    models = sub.add_parser(
        "models", help="list models and optional runtime availability"
    )
    models.add_argument("--output")
    schema = sub.add_parser("schema", help="print a published JSON Schema")
    schema.add_argument("name", choices=("scenario", "result"))
    schema.add_argument("--output")
    run = sub.add_parser("run", help="simulate an explicit scenario")
    run.add_argument("scenario")
    run.add_argument("--seed", type=int, default=0)
    run.add_argument("--output")
    generate = sub.add_parser(
        "generate", help="generate an inspectable demand-first market"
    )
    for flag, default in (
        ("seed", 0),
        ("requests", 100),
        ("suppliers", 5),
        ("feasible-suppliers", 2),
        ("intake-hours", 672),
    ):
        generate.add_argument("--" + flag, type=int, default=default)
    generate.add_argument("--areas", default="metro-a")
    generate.add_argument("--categories", default="materials")
    generate.add_argument("--output")
    sweep = sub.add_parser(
        "sweep", help="paired policy replicates, independently evolving state"
    )
    sweep.add_argument("scenario")
    sweep.add_argument("--replicates", type=int, default=20)
    sweep.add_argument("--seed-start", type=int, default=0)
    sweep.add_argument("--policies", help="JSON map of names to policy overrides")
    sweep.add_argument("--output")
    pilot = sub.add_parser(
        "pilot", help="export a synthetic purchase result to the canonical v1 reader"
    )
    pilot.add_argument("result")
    pilot.add_argument("--output")
    adapter = sub.add_parser(
        "adapter", help="run a pinned optional Mesa or NegMAS model"
    )
    adapter.add_argument("name", choices=("mesa", "negmas"))
    for flag, default in (
        ("seed", 0),
        ("steps", 7),
        ("agents", 10),
        ("buyer-limit", 120),
        ("seller-floor", 80),
        ("max-rounds", 20),
    ):
        adapter.add_argument("--" + flag, type=int, default=default)
    adapter.add_argument("--output")
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    try:
        if args.command == "models":
            result = {
                "schema_version": "1.0",
                "source": "synthetic",
                "models": [
                    {
                        "id": "demand_exchange_v1",
                        "available": True,
                        "mechanisms": ["purchase", "barter"],
                        "purchase_selection": [
                            "first_quote",
                            "lowest_cost",
                            "reliability_adjusted",
                        ],
                        "clearing": "immediate or explicit integer-hour batches",
                        "barter": "unrestricted exact slot cycles; optional length-bound sensitivity",
                        "calibrated": False,
                    },
                    {
                        "id": "mesa_participation",
                        "available": importlib.util.find_spec("mesa") is not None,
                        "extra": "mesa",
                        "fulfillment_modeled": False,
                    },
                    {
                        "id": "negmas_bilateral",
                        "available": importlib.util.find_spec("negmas") is not None,
                        "extra": "negmas",
                        "fulfillment_modeled": False,
                    },
                ],
            }
        elif args.command == "schema":
            result = load_json(
                Path(__file__).parent / "schemas" / (args.name + ".schema.json")
            )
        elif args.command == "run":
            result = simulate(load_json(args.scenario), args.seed)
        elif args.command == "generate":
            result = generate_market(
                args.seed,
                args.requests,
                args.suppliers,
                args.feasible_suppliers,
                args.areas.split(","),
                args.categories.split(","),
                args.intake_hours,
            )
        elif args.command == "sweep":
            if not 1 <= args.replicates <= 1000:
                raise ScenarioError("replicates must be in [1, 1000]")
            policies = (
                load_json(args.policies)
                if args.policies
                else {
                    "immediate": {"cadence_hours": 0},
                    "daily": {"cadence_hours": 24},
                    "two_day": {"cadence_hours": 48},
                }
            )
            result = compare(
                load_json(args.scenario),
                policies,
                range(args.seed_start, args.seed_start + args.replicates),
            )
        elif args.command == "pilot":
            result = load_json(args.result)
            if not isinstance(result, dict):
                raise ScenarioError("pilot input must be a simulation result object")
            result = export_pilot_snapshot(result["scenario"], result)
        else:
            from .adapters import run_mesa_demo, run_negotiation

            result = (
                run_mesa_demo(seed=args.seed, steps=args.steps, agents=args.agents)
                if args.name == "mesa"
                else run_negotiation(
                    seed=args.seed,
                    buyer_limit=args.buyer_limit,
                    seller_floor=args.seller_floor,
                    max_rounds=args.max_rounds,
                )
            )
        _write(result, args.output)
        return 0
    except (
        ScenarioError,
        SimulationLimitError,
        MatchingBudgetExceeded,
        ValueError,
        OSError,
        KeyError,
        ImportError,
    ) as error:
        sys.stderr.write(
            json.dumps(
                {
                    "schema_version": "1.0",
                    "status": "error",
                    "error_type": type(error).__name__,
                    "message": str(error),
                }
            )
            + "\n"
        )
        return 2
