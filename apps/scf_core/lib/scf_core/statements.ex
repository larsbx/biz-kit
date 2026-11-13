defmodule ScfCore.Statements do
  @moduledoc """
  États financiers SCF from a ledger holding one exercice (prior results
  carried to 11/12).

  * `tcr/2` — Compte de résultat par nature with its soldes intermédiaires.
  * `bilan/2` — Bilan, net of amortissements and pertes de valeur; classes 4
    and 5 are split per account by the sign of their balance, so a debtor
    supplier is an asset and a bank overdraft a liability.

  `total_actif == total_passif` and the TCR's résultat net equals
  Σ produits − Σ charges for every admitted ledger (test/invariants_test.exs).
  """
  alias ScfCore.{Chart, Ledger}

  @doc "Compte de résultat over `window` (`from:`/`to:`)."
  def tcr(ledger, window \\ []), do: ledger |> Ledger.balances(window) |> tcr_of()

  defp tcr_of(bal) do
    produits = &(-sum(bal, &1))
    charges = &sum(bal, &1)

    production = produits.(~w(70 72 73 74))
    consommation = charges.(~w(60 61 62))
    va = production - consommation
    ebe = va - charges.(~w(63 64))
    ro = ebe + produits.(~w(75 78)) - charges.(~w(65 68))
    rf = produits.(~w(76)) - charges.(~w(66))
    impots = charges.(~w(69))
    extraordinaire = produits.(~w(77)) - charges.(~w(67))

    %{
      production: production,
      consommation: consommation,
      valeur_ajoutee: va,
      ebe: ebe,
      resultat_operationnel: ro,
      resultat_financier: rf,
      resultat_ordinaire_avant_impots: ro + rf,
      impots_sur_resultats: impots,
      resultat_extraordinaire: extraordinaire,
      resultat_net: ro + rf - impots + extraordinaire
    }
  end

  @doc "Bilan at date `at` (default: every entry)."
  def bilan(ledger, opts \\ []) do
    bal = Ledger.balances(ledger, to: opts[:at])
    tiers = for {a, s} <- bal, Chart.class(a) in [4, 5], do: s
    resultat = tcr_of(bal).resultat_net

    actif = %{
      non_courant: sum(bal, ~w(2)),
      courant: sum(bal, ~w(3)) + Enum.sum(for s <- tiers, s > 0, do: s)
    }

    passif = %{
      capitaux_propres: -sum(bal, ~w(10 11 12)) + resultat,
      non_courant: -sum(bal, ~w(13 14 15 16 17 18)),
      courant: -Enum.sum(for s <- tiers, s < 0, do: s)
    }

    %{
      actif: actif,
      passif: passif,
      resultat: resultat,
      total_actif: total(actif),
      total_passif: total(passif)
    }
  end

  defp total(side), do: side |> Map.values() |> Enum.sum()

  defp sum(bal, prefixes),
    do: for({a, s} <- bal, String.starts_with?(a, prefixes), reduce: 0, do: (acc -> acc + s))
end
