defmodule CommerceCore.MerchantPilot do
  @moduledoc "Offline procurement measurement and source-owned intake projection. No ledger or commerce execution."
  alias CommerceCore.MerchantPilot.{Intake, Scorecard, Validation}

  def score(snapshot, opts \\ []),
    do: Validation.protect(fn -> Scorecard.score!(snapshot, opts) end)

  def export(bundle), do: Validation.protect(fn -> Intake.export!(bundle) end)

  def assemble(control, extracts),
    do: Validation.protect(fn -> Intake.assemble!(control, extracts) end)
end
