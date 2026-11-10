defmodule ScfCore.Chart do
  @moduledoc """
  The SCF nomenclature des comptes (Arrêté du 26 juillet 2008, under Loi 07-11
  of 25 November 2007), classes 1–7.

  An account number is a digit string whose longest listed prefix (≥ 2 digits)
  names it, so an entity may open any sub-account (`41100012` under `411`).
  Classes 8 (unused) and 9 (analytical, optional) are outside this core. Every
  two-digit class 6/7 account is listed, so `ScfCore.Statements.tcr/2` covers
  each of them.
  """

  @accounts %{
    # Classe 1 — Comptes de capitaux
    "10" => "Capital, réserves et assimilés",
    "101" => "Capital émis",
    "104" => "Primes liées au capital social",
    "105" => "Écarts d'évaluation",
    "106" => "Réserves",
    "108" => "Compte de l'exploitant",
    "109" => "Capital souscrit non appelé",
    "11" => "Report à nouveau",
    "110" => "Report à nouveau (solde créditeur)",
    "119" => "Report à nouveau (solde débiteur)",
    "12" => "Résultat de l'exercice",
    "120" => "Résultat de l'exercice (bénéfice)",
    "129" => "Résultat de l'exercice (perte)",
    "13" => "Produits et charges différés hors cycle d'exploitation",
    "131" => "Subventions d'équipement",
    "15" => "Provisions pour charges — passifs non courants",
    "16" => "Emprunts et dettes assimilées",
    "164" => "Emprunts auprès des établissements de crédit",
    "17" => "Dettes rattachées à des participations",
    "18" => "Comptes de liaison des établissements et sociétés en participation",
    # Classe 2 — Comptes d'immobilisations
    "20" => "Immobilisations incorporelles",
    "21" => "Immobilisations corporelles",
    "211" => "Terrains",
    "213" => "Constructions",
    "215" => "Installations techniques, matériel et outillage industriel",
    "218" => "Autres immobilisations corporelles",
    "22" => "Immobilisations en concession",
    "23" => "Immobilisations en cours",
    "26" => "Participations et créances rattachées",
    "27" => "Autres immobilisations financières",
    "28" => "Amortissements des immobilisations",
    "281" => "Amortissements des immobilisations corporelles",
    "29" => "Pertes de valeur sur immobilisations",
    # Classe 3 — Comptes de stocks et en-cours
    "30" => "Stocks de marchandises",
    "31" => "Matières premières et fournitures",
    "32" => "Autres approvisionnements",
    "33" => "En-cours de production de biens",
    "34" => "En-cours de production de services",
    "35" => "Stocks de produits",
    "355" => "Produits finis",
    "36" => "Stocks provenant d'immobilisations",
    "37" => "Stocks à l'extérieur",
    "38" => "Achats stockés",
    "39" => "Pertes de valeur sur stocks et en-cours",
    # Classe 4 — Comptes de tiers
    "40" => "Fournisseurs et comptes rattachés",
    "401" => "Fournisseurs de stocks et services",
    "404" => "Fournisseurs d'immobilisations",
    "409" => "Fournisseurs débiteurs",
    "41" => "Clients et comptes rattachés",
    "411" => "Clients",
    "416" => "Clients douteux",
    "419" => "Clients créditeurs",
    "42" => "Personnel et comptes rattachés",
    "421" => "Personnel, rémunérations dues",
    "43" => "Organismes sociaux et comptes rattachés",
    "431" => "Sécurité sociale",
    "44" => "État, collectivités publiques et comptes rattachés",
    "444" => "État, impôts sur les résultats",
    "445" => "État, taxes sur le chiffre d'affaires",
    "4456" => "Taxes sur le chiffre d'affaires déductibles",
    "4457" => "Taxes sur le chiffre d'affaires collectées",
    "447" => "Autres impôts, taxes et versements assimilés",
    "45" => "Groupe et associés",
    "46" => "Débiteurs divers et créditeurs divers",
    "47" => "Comptes transitoires ou d'attente",
    "48" => "Charges ou produits constatés d'avance et provisions",
    "49" => "Pertes de valeur sur comptes de tiers",
    # Classe 5 — Comptes financiers
    "50" => "Valeurs mobilières de placement",
    "51" => "Banques, établissements financiers et assimilés",
    "512" => "Banques, comptes courants",
    "519" => "Concours bancaires courants",
    "52" => "Instruments financiers dérivés",
    "53" => "Caisse",
    "54" => "Régies d'avances et accréditifs",
    "58" => "Virements internes",
    "59" => "Pertes de valeur sur actifs financiers courants",
    # Classe 6 — Comptes de charges
    "60" => "Achats consommés",
    "600" => "Achats de marchandises vendues",
    "601" => "Matières premières",
    "61" => "Services extérieurs",
    "62" => "Autres services extérieurs",
    "63" => "Charges de personnel",
    "64" => "Impôts, taxes et versements assimilés",
    "65" => "Autres charges opérationnelles",
    "66" => "Charges financières",
    "67" => "Éléments extraordinaires — charges",
    "68" => "Dotations aux amortissements, provisions et pertes de valeur",
    "681" => "Dotations aux amortissements, provisions et pertes de valeur — actifs non courants",
    "69" => "Impôts sur les résultats et assimilés",
    "695" => "Impôts sur les bénéfices basés sur le résultat des activités ordinaires",
    # Classe 7 — Comptes de produits
    "70" => "Ventes de marchandises et de produits fabriqués, prestations de services",
    "700" => "Ventes de marchandises",
    "701" => "Ventes de produits finis",
    "706" => "Prestations de services",
    "72" => "Production stockée ou déstockée",
    "73" => "Production immobilisée",
    "74" => "Subventions d'exploitation",
    "75" => "Autres produits opérationnels",
    "76" => "Produits financiers",
    "77" => "Éléments extraordinaires — produits",
    "78" => "Reprises sur pertes de valeur et provisions"
  }

  @type account :: String.t()

  @doc "All listed headline accounts, `%{number => libellé}`."
  def accounts, do: @accounts

  @doc "True iff `a` is a digit string under a listed account of classes 1–7."
  def account?(a) when is_binary(a), do: a =~ ~r/^[1-7]\d{1,7}$/ and ancestor(a) != nil
  def account?(_), do: false

  @doc "The libellé of the account's nearest listed ancestor."
  def label(a), do: @accounts[ancestor(a)]

  @doc "The account's class, 1..7."
  def class(<<c, _::binary>>), do: c - ?0

  # Longest listed prefix of at least two digits, or nil.
  defp ancestor(a) do
    Enum.find_value(byte_size(a)..2//-1, fn n ->
      prefix = binary_part(a, 0, n)
      Map.has_key?(@accounts, prefix) && prefix
    end)
  end
end
