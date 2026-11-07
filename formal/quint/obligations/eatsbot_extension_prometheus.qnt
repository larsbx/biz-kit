// eatsbot_extension_prometheus: "Monitoring does not disclose private records
// or confer commands".
//
// Rule modelled: Eatsbot.Extensions.Prometheus.PromExPlugin.event_metrics/1
// (promex_plugin.ex) exports counters whose tag_values project telemetry
// metadata onto the fixed tags [:action] and [:action, :state] (or none); the
// extension's endpoint/0 mounts only PromEx.Plug, which serves a read-only
// scrape. Obligation: an exported series carries only public tag keys and a
// scrape never changes business state. GUARDED is the tag_values projection;
// the control exports metadata verbatim, including record fields.
// Abstracted: one delivery record with private fields; tag keys as names.
// NOTE: the model treats the scrape as read-only, as PromEx.Plug is. Whether
// /metrics needs authentication is deployment configuration and is not modelled.
module eatsbot_extension_prometheus_spec {
  const GUARDED: bool
  pure val PUBLIC = Set("action", "state")
  pure val METADATA = Set("action", "state", "delivery_id", "customer", "address")
  var exported: Set[str]   // tag keys present on exported series
  var businessVersion: int // version of the delivery record
  var scrapes: int

  action init = all { exported' = Set(), businessVersion' = 0, scrapes' = 0 }
  action telemetryEvent = all {
    exported' = exported.union(if (GUARDED) METADATA.intersect(PUBLIC) else METADATA),
    businessVersion' = businessVersion, scrapes' = scrapes }
  action businessUpdate = all { businessVersion < 3, businessVersion' = businessVersion + 1,
    exported' = exported, scrapes' = scrapes }
  action scrape = all { scrapes < 3, scrapes' = scrapes + 1, exported' = exported,
    businessVersion' = businessVersion }
  action step = any { telemetryEvent, businessUpdate, scrape }

  val obligation = exported.subseteq(PUBLIC)
  val obligationWitness = not(scrapes > 0 and exported.contains("state"))
}
module eatsbot_extension_prometheus { import eatsbot_extension_prometheus_spec(GUARDED = true).* }
module eatsbot_extension_prometheus_control { import eatsbot_extension_prometheus_spec(GUARDED = false).* }
