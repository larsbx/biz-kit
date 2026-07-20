defmodule CoopSubstrate.Constants do
  @moduledoc """
  Substrate constants.

  Every value here is **PLACEHOLDER — awaiting charter declaration** (04 §7
  charter-constant registry). None of these are real values; they exist so the
  code has one place to read them from and so the eventual
  `CharterConstantDeclared` governance events have a well-known target.
  """

  @doc "Hard cap on canonical-encoded output, bytes. PLACEHOLDER."
  def max_canonical_bytes, do: 65_536

  @doc "Hard cap on canonical term nesting depth. PLACEHOLDER."
  def max_canonical_depth, do: 32

  @doc """
  Entity classes (master_design §3 via the hand-off): carriers' co-op,
  workers' co-op, mechanics' co-op. Extending this set is a governance act
  (later phase), not a code edit.
  """
  def entity_classes, do: ["carriers_coop", "workers_coop", "mechanics_coop"]

  @doc """
  Default accrual weight in basis points (10_000 = 1.0) used by
  `capital-accrual-v1` when an activation's params omit a kind.
  PLACEHOLDER — the whole rule is illustrative, awaiting charter declaration.
  """
  def default_accrual_weight_bp, do: 10_000

  @doc "Redemption schedule method supported by the 1B data model."
  def redemption_methods, do: ["fifo"]

  @doc "Dispatch envelope scopes (8A; the field sets are per-scope gate checks)."
  def dispatch_scopes, do: ["tender_accept"]

  @doc "Tender parse grades (8A; 08 §7): machine output is never authoritative."
  def parse_grades, do: ["human", "machine"]

  @doc "Load stops (8B; 07 §3 interchange pattern on the carrier's own stream)."
  def load_stops, do: ["pickup", "delivery"]

  @doc """
  Recordable throughput components (Phase 1C). `settlement` is deliberately
  absent: it derives from obligation-rail discharge events (corpus 05 §1.2),
  never from a claim. PLACEHOLDER — the component taxonomy awaits the absent
  throughput_and_floor spec / charter declaration (docs/phase1c_plan.md).
  """
  def throughput_components, do: ["delivery", "match", "custody", "labor_hour"]

  @doc """
  Roles whose keys may be declared in a chapter's governance stream
  (Phase 1D): `governance` signs declarations themselves, `steward` the
  administrative event types, `checkpoint` the external head attestations.
  `member` is deliberately absent — member keys live in the member registry
  (`MemberRegistered`/`KeyRotated`), never here.
  """
  def declarable_roles, do: ["governance", "steward", "checkpoint"]

  @doc """
  Interview consent use-classes (corpus 11 §1.2; Phase 2A). Every use of
  interview material must be covered by a class the interviewee granted.
  """
  def consent_classes, do: ["synthesis", "anonymized_fixtures", "prospect_record"]

  @doc "Harness sections (corpus 11 §4, priority order)."
  def harness_sections, do: ["D", "L", "Y"]

  @doc """
  Interview modes (corpus 11 §1.2). `voice_agent` is deliberately absent —
  automated outbound voice is [LEGAL]-gated per state
  (docs/handoff_harness_d.md §1); enabling it is a code change behind
  counsel, not a config flip.
  """
  def interview_modes, do: ["call", "chat", "form"]

  @doc "Typed finding kinds (corpus 11 §1.2 FindingExtracted)."
  def finding_kinds do
    ~w(process_step duration pain workaround document rent exception tool term_of_art)
  end

  @doc """
  Charter-constant names for a section's harness gate (corpus 11 §2), read
  from `CharterConstantDeclared` events — declared before first evaluation,
  retro-fit void. Undeclared ⇒ the gate fails closed.
  """
  def harness_gate_constants(section) do
    ["harness/#{section}/n", "harness/#{section}/c", "harness/#{section}/d"]
  end

  @doc "Canonical profile name carried inside every signed core."
  def canonical_profile, do: "CoopEventCanonicalV1"

  @doc "Envelope schema version for Phase 1A."
  def envelope_schema_version, do: "EventEnvelopeV1"
end
