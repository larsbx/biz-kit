// Every successful packaged load yields the exact document bytes identified
// by the compiled manifest.
//
// Abstracts Catalog.load_packaged/1: verify_manifest_pin/2 checks the compiled
// pin before load_documents/2 checks every manifest entry. Two documents
// stand for a primary and a companion. Distinct byte tokens stand for distinct
// digests. The model abstracts path validation, release custody and host
// authorization. The control skips only the compiled manifest pin.
module bizops_kb_spec {
  const CHECK_COMPILED_PIN: bool
  type DocumentBodies = { primary: str, companion: str }

  pure val RETAINED = { primary: "original", companion: "companion" }
  var loaded: Set[DocumentBodies]
  var refusedRewrite: bool

  action init = all { loaded' = Set(), refusedRewrite' = false }

  action load(manifestPrimary: str, bodies: DocumentBodies): bool = {
    val matchesManifest = bodies.primary == manifestPrimary and bodies.companion == RETAINED.companion
    val matchesCompiledPin = manifestPrimary == RETAINED.primary
    val canLoad = matchesManifest and (matchesCompiledPin or not(CHECK_COMPILED_PIN))
    all {
      loaded' = if (canLoad) loaded.union(Set(bodies)) else loaded,
      refusedRewrite' = (refusedRewrite or (matchesManifest and not(canLoad))),
    }
  }

  action step =
    nondet manifestPrimary = Set(RETAINED.primary, "substituted").oneOf()
    nondet primary = Set(RETAINED.primary, "substituted", "missing").oneOf()
    nondet companion = Set(RETAINED.companion, "changed", "missing").oneOf()
    load(manifestPrimary, { primary: primary, companion: companion })

  val obligation = loaded.forall(bodies => bodies == RETAINED)
  val obligationWitness = not(loaded.contains(RETAINED) and refusedRewrite)
}

module bizops_kb { import bizops_kb_spec(CHECK_COMPILED_PIN = true).* }
module bizops_kb_control { import bizops_kb_spec(CHECK_COMPILED_PIN = false).* }
