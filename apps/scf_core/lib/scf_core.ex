defmodule ScfCore do
  @moduledoc """
  Pure accounting core for Algerian entities under the Système Comptable
  Financier (Loi 07-11; Décret exécutif 08-156; Arrêté du 26 juillet 2008).

  `Chart` → `Entry` → `Ledger` → `Statements` / `Tva`. No processes, storage
  or I/O: a host persists admitted entries and replays them.
  """

  @doc "The exercice of `year`: the calendar year, the SCF default."
  def exercice(year), do: [from: Date.new!(year, 1, 1), to: Date.new!(year, 12, 31)]
end
