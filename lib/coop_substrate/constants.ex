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

  @doc "Canonical profile name carried inside every signed core."
  def canonical_profile, do: "CoopEventCanonicalV1"

  @doc "Envelope schema version for Phase 1A."
  def envelope_schema_version, do: "EventEnvelopeV1"
end
