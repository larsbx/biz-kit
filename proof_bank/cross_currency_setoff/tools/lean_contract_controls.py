"""Execute statement weakening and hidden-contract-axiom controls in isolated builds.

The original source tree is never edited. Each invocation gets a private module
search path so a stale or baseline .olean cannot satisfy a mutant import.
"""
from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Callable


def run_contract_controls(lean_dir: Path, build: Path, binaries: dict[str, Path],
                          run: Callable, audit_axioms: Callable,
                          targets: list[str], contracts: list[str]) -> list[dict[str, object]]:
    directory = build / "contract-controls"
    directory.mkdir(exist_ok=False)
    lean = str(binaries["lean"])
    override = {"LEAN_PATH": str(directory)}
    core = (lean_dir / "CrossCurrencySetoff.lean").read_text()
    contract_source = (lean_dir / "Contracts.lean").read_text()
    core_start = "theorem canonical_unique "
    core_end = "\ntheorem quote_reduction_bounded "
    if core.count(core_start) != 1 or core.count(core_end) != 1:
        raise RuntimeError("changed canonical-uniqueness control anchor")
    start = core.index(core_start)
    end = core.index(core_end, start)
    weakened = core[:start] + "theorem canonical_unique : True := True.intro\n" + core[end:]
    (directory / "CrossCurrencySetoff.lean").write_text(weakened)
    (directory / "Contracts.lean").write_text(contract_source)
    (directory / "AxiomAudit.lean").write_text((lean_dir / "AxiomAudit.lean").read_text())

    def compile_module(label: str, module: str, *, allowed: tuple[int, ...] = (0,)):
        return run(label, [lean, "-DwarningAsError=true", "-o",
                          str(directory / (module + ".olean")), module + ".lean"],
                   cwd=directory, allowed=allowed, env_overrides=override)

    compile_module("lean-contract-weakened-core", "CrossCurrencySetoff")
    rejected = compile_module("lean-contract-weakened-target", "Contracts", allowed=(1,))
    if ("error: Function expected at" not in rejected.stdout or
            "canonical_unique" not in rejected.stdout):
        raise RuntimeError("weakened target was not rejected by its independent expected type")

    # A custom axiom is a valid Lean declaration, so warningAsError is not a
    # sufficient contract guard. Prove the original, stronger expected type
    # with it and require the *contract's* transitive audit to expose the axiom.
    namespace_anchor = "namespace CrossCurrencySetoff.Contracts\n"
    proof_anchor = ":= canonical_unique h h' he"
    if contract_source.count(namespace_anchor) != 1 or contract_source.count(proof_anchor) != 1:
        raise RuntimeError("changed independent canonical-uniqueness contract anchor")
    custom_axiom = "CrossCurrencySetoff.ContractControl.fabricated"
    fabricated = contract_source.replace(
        namespace_anchor,
        "namespace CrossCurrencySetoff.ContractControl\n"
        "axiom fabricated : False\n"
        "end CrossCurrencySetoff.ContractControl\n\n" + namespace_anchor, 1)
    fabricated = fabricated.replace(
        proof_anchor,
        ":= by\n  have _sourcePremise := h\n  have _secondPremise := h'\n"
        "  have _equalValue := he\n  exact False.elim " + custom_axiom, 1)
    (directory / "Contracts.lean").write_text(fabricated)
    compile_module("lean-contract-custom-axiom", "Contracts")
    result = run("lean-contract-custom-axiom-audit",
                 [lean, "-DwarningAsError=true", "AxiomAudit.lean"],
                 cwd=directory, env_overrides=override)
    contract_name = "CrossCurrencySetoff.Contracts.check_canonical_unique"
    try:
        audit_axioms(result.stdout, targets + contracts)
    except ValueError as exc:
        message = str(exc)
        if not (message.startswith("unapproved axioms: " + contract_name + ":") and
                custom_axiom in message):
            raise
    else:
        raise RuntimeError("custom axiom in an independent contract escaped the transitive audit")

    return [
        {"name": "weakened-model-target", "status": "detected",
         "target": "CrossCurrencySetoff.canonical_unique", "contract": contract_name,
         "rejected_by": "independently restated expected type",
         "mutant_source_sha256": hashlib.sha256(weakened.encode()).hexdigest()},
        {"name": "custom-axiom-contract-bypass", "status": "detected",
         "target": "CrossCurrencySetoff.canonical_unique", "contract": contract_name,
         "custom_axiom": custom_axiom,
         "rejected_by": "compiled contract transitive axiom audit",
         "mutant_source_sha256": hashlib.sha256(fabricated.encode()).hexdigest()},
    ]
