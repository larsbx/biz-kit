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

  @doc "Canonical profile name carried inside every signed core."
  def canonical_profile, do: "CoopEventCanonicalV1"

  @doc "Envelope schema version for Phase 1A."
  def envelope_schema_version, do: "EventEnvelopeV1"
end
