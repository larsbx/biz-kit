defmodule ScfHost.HTML do
  @moduledoc "Server-rendered French console. Every value is escaped; no secrets or authority fields in forms."
  alias ScfCore.{Chart, Money}

  @journals [
    {"AC", "Achats"},
    {"VE", "Ventes"},
    {"BQ", "Banque"},
    {"CA", "Caisse"},
    {"OD", "Opérations diverses"}
  ]
  @blank_lines 8

  @messages %{
    invalid_credentials: "Jeton invalide, ou habilitation du comptable inactive.",
    invalid_document:
      "Indiquez la pièce justificative et joignez le fichier (ou son empreinte SHA-256).",
    invalid_line:
      "Chaque ligne porte un compte et un seul montant, au débit ou au crédit (ex. 1 234,56).",
    invalid_command_id: "Formulaire expiré : rechargez la page.",
    unknown_entry: "Écriture introuvable.",
    unsupported_currency: "Seul le dinar algérien (DZD) est accepté.",
    outside_open_fiscal_year: "La date n'appartient pas à l'exercice ouvert.",
    invalid_accounting_date: "Date invalide.",
    entry_already_reversed: "Cette écriture a déjà été contrepassée.",
    reversal_before_target: "La contrepassation ne peut précéder l'écriture d'origine.",
    invalid_fiscal_close: "La clôture porte sur le 31 décembre de l'exercice ouvert.",
    scf_idempotency_conflict: "Ce formulaire a déjà été soumis avec un autre contenu.",
    scf_forbidden: "Habilitation du comptable absente ou révoquée.",
    scf_authority_expired_or_replaced: "Session ou habilitation expirée : reconnectez-vous.",
    stale_scf_admission_time: "Horloge du serveur décalée : réessayez."
  }

  def escape(v), do: v |> to_string() |> Plug.HTML.html_escape()

  def page(title, body, entity) do
    "<!doctype html><html lang=\"fr\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" <>
      "<title>#{escape(title)} · Comptabilité SCF</title><style>" <>
      css() <>
      "</style><body><nav><strong>SCF · #{escape(entity)}</strong>" <>
      Enum.map_join(
        [
          {"/journal", "Journal"},
          {"/ecriture", "Nouvelle écriture"},
          {"/balance", "Balance"},
          {"/etats", "États financiers"},
          {"/tva", "TVA (G50)"}
        ],
        fn {href, label} -> "<a href=\"#{href}\">#{label}</a>" end
      ) <>
      "</nav><main><h1>#{escape(title)}</h1>" <>
      body <>
      "</main><footer><p>Montants en dinars algériens (DA). Chaque écriture est signée et admise au registre canonique ; " <>
      "les corrections se font par contrepassation.</p><form method=\"post\" action=\"/logout\">#{csrf()}<button>Se déconnecter</button></form></footer></body></html>"
  end

  defp css,
    do:
      "body{font:16px system-ui;max-width:1100px;margin:1.5rem auto;padding:0 1rem;color:#18232b;background:#fafafa}" <>
        "nav a{margin-left:1rem}section,form.card{background:#fff;border:1px solid #d8dfe3;padding:1rem;margin:1rem 0}" <>
        "table{width:100%;border-collapse:collapse;margin:1rem 0}td,th{padding:.4rem .5rem;border-bottom:1px solid #e3e7ea;text-align:left;vertical-align:top}" <>
        "td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}tfoot td{font-weight:600}" <>
        "input,select,button{font:inherit;padding:.35rem;max-width:100%;box-sizing:border-box}label{display:inline-block;margin:.4rem 1rem .4rem 0}" <>
        ".error{border-left:4px solid #a33;padding:.6rem 1rem;background:#fff}.muted{color:#5b6770}details{margin:.3rem 0}" <>
        "@media(max-width:700px){table{display:block;overflow-x:auto}}"

  def csrf, do: hidden("_csrf_token", Plug.CSRFProtection.get_csrf_token())

  defp hidden(name, value),
    do: "<input type=\"hidden\" name=\"#{escape(name)}\" value=\"#{escape(value)}\">"

  def error(reason), do: "<p class=\"error\">#{escape(message(reason))}</p>"

  def message({:invalid_entry, errors}),
    do: "Écriture refusée : " <> Enum.map_join(errors, " ; ", &entry_error/1)

  def message(reason), do: Map.get(@messages, reason, "Refusé : #{inspect(reason)}")

  defp entry_error({:unbalanced, d, c}),
    do: "total débit #{Money.format(d)} ≠ total crédit #{Money.format(c)}"

  defp entry_error({:invalid_account, a}), do: "compte #{inspect(a)} hors nomenclature SCF"
  defp entry_error({:non_positive_amount, a}), do: "montant nul sur le compte #{a}"
  defp entry_error(:fewer_than_two_lines), do: "au moins deux lignes"
  defp entry_error(:invalid_journal), do: "code journal invalide"
  defp entry_error(:invalid_date), do: "date invalide"
  defp entry_error(e), do: inspect(e)

  def login(error \\ nil),
    do:
      ((error && error(error)) || "") <>
        "<form class=\"card\" method=\"post\" action=\"/login\">#{csrf()}<label>Jeton d'accès du comptable " <>
        "<input type=\"password\" name=\"token\" required autocomplete=\"current-password\"></label><button>Se connecter</button></form>"

  # -- journal ------------------------------------------------------------------

  def journal(rows, command_id) do
    if rows == [] do
      "<p class=\"muted\">Aucune écriture. <a href=\"/ecriture\">Saisir la première écriture</a>.</p>"
    else
      "<table><thead><tr><th>N°</th><th>Date</th><th>Jnl</th><th>Pièce</th><th>Libellé / compte</th><th class=n>Débit</th><th class=n>Crédit</th></tr></thead><tbody>" <>
        Enum.map_join(rows, &journal_row(&1, command_id)) <> "</tbody></table>"
    end
  end

  defp journal_row(r, command_id) do
    note = if r.reverses, do: " <span class=muted>(contrepasse n° #{r.reverses})</span>", else: ""

    "<tr><td>#{r.sequence}</td><td>#{r.date}</td><td>#{escape(r.journal)}</td><td>#{escape(r.piece)}</td>" <>
      "<td><strong>#{escape(r.label)}</strong>#{note}#{reverse_form(r, command_id)}</td><td></td><td></td></tr>" <>
      Enum.map_join(r.lines, fn {side, a, m} ->
        {d, c} = if side == :debit, do: {Money.format(m), ""}, else: {"", Money.format(m)}

        "<tr><td></td><td></td><td></td><td></td><td>#{escape(a)} · #{escape(Chart.label(a))}</td><td class=n>#{d}</td><td class=n>#{c}</td></tr>"
      end)
  end

  defp reverse_form(%{reversible: false}, _), do: ""

  defp reverse_form(r, command_id),
    do:
      "<details><summary>Contrepasser</summary><form method=\"post\" action=\"/journal/#{r.sequence}/contrepasser\" enctype=\"multipart/form-data\">" <>
        csrf() <>
        hidden("command_id", "#{command_id}-r#{r.sequence}") <>
        "<label>Date <input type=\"date\" name=\"date\" value=\"#{r.date}\" required></label>" <>
        document_fields() <>
        "<button>Contrepasser l'écriture n° #{r.sequence}</button></form></details>"

  defp document_fields,
    do:
      "<label>Pièce justificative (n°) <input name=\"piece\" required maxlength=\"128\"></label>" <>
        "<label>Fichier <input type=\"file\" name=\"document\" required></label>"

  # -- saisie -------------------------------------------------------------------

  def entry_form(command_id, params \\ %{}) do
    rows = Map.get(params, "lines", %{})

    "<form class=\"card\" method=\"post\" action=\"/ecriture\" enctype=\"multipart/form-data\">" <>
      csrf() <>
      hidden("command_id", command_id) <>
      "<label>Journal <select name=\"journal\">" <>
      Enum.map_join(@journals, fn {code, name} ->
        selected = if params["journal"] == code, do: " selected", else: ""
        "<option value=\"#{code}\"#{selected}>#{code} · #{name}</option>"
      end) <>
      "</select></label><label>Date <input type=\"date\" name=\"date\" required value=\"#{escape(params["date"] || "")}\"></label>" <>
      "<label>Libellé <input name=\"label\" maxlength=\"256\" value=\"#{escape(params["label"] || "")}\"></label><br>" <>
      document_fields() <>
      "<table><thead><tr><th>Compte</th><th class=n>Débit (DA)</th><th class=n>Crédit (DA)</th></tr></thead><tbody>" <>
      Enum.map_join(0..(@blank_lines - 1), fn i ->
        row = rows[Integer.to_string(i)] || %{}

        cell = fn field ->
          "<input name=\"lines[#{i}][#{field}]\" value=\"#{escape(row[field] || "")}\" inputmode=\"decimal\">"
        end

        "<tr><td><input name=\"lines[#{i}][account]\" list=\"comptes\" value=\"#{escape(row["account"] || "")}\" pattern=\"[1-7][0-9]{1,7}\"></td><td class=n>#{cell.("debit")}</td><td class=n>#{cell.("credit")}</td></tr>"
      end) <>
      "</tbody></table><datalist id=\"comptes\">" <>
      Enum.map_join(Enum.sort(Chart.accounts()), fn {n, l} ->
        "<option value=\"#{n}\">#{escape(l)}</option>"
      end) <>
      "</datalist><button>Enregistrer l'écriture</button><p class=muted>Σ débit = Σ crédit ; comptes de la nomenclature SCF (classes 1 à 7) ou leurs sous-comptes.</p></form>"
  end

  # -- états ----------------------------------------------------------------------

  def window_form(action, from: from, to: to),
    do:
      "<form method=\"get\" action=\"#{action}\"><label>Du <input type=\"date\" name=\"du\" value=\"#{from}\"></label>" <>
        "<label>Au <input type=\"date\" name=\"au\" value=\"#{to}\"></label><button>Afficher</button></form>"

  def balance(s) do
    tb = s.trial_balance

    window_form("/balance", s.window) <>
      "<table><thead><tr><th>Compte</th><th>Libellé</th><th class=n>Mouvements débit</th><th class=n>Mouvements crédit</th><th class=n>Solde débiteur</th><th class=n>Solde créditeur</th></tr></thead><tbody>" <>
      Enum.map_join(tb.rows, fn r ->
        "<tr><td>#{escape(r.account)}</td><td>#{escape(r.label)}</td><td class=n>#{Money.format(r.debit)}</td><td class=n>#{Money.format(r.credit)}</td>" <>
          "<td class=n>#{if r.balance > 0, do: Money.format(r.balance)}</td><td class=n>#{if r.balance < 0, do: Money.format(-r.balance)}</td></tr>"
      end) <>
      "</tbody><tfoot><tr><td colspan=2>Totaux</td><td class=n>#{Money.format(tb.total_debit)}</td><td class=n>#{Money.format(tb.total_credit)}</td><td></td><td></td></tr></tfoot></table>"
  end

  @tcr [
    production: "I. Production de l'exercice",
    consommation: "II. Consommations de l'exercice",
    valeur_ajoutee: "III. Valeur ajoutée d'exploitation (I − II)",
    ebe: "IV. Excédent brut d'exploitation",
    resultat_operationnel: "V. Résultat opérationnel",
    resultat_financier: "VI. Résultat financier",
    resultat_ordinaire_avant_impots: "VII. Résultat ordinaire avant impôts (V + VI)",
    impots_sur_resultats: "Impôts sur les résultats",
    resultat_extraordinaire: "VIII. Résultat extraordinaire",
    resultat_net: "IX. Résultat net de l'exercice"
  ]

  def statements(s, close_command_id, open_year) do
    b = s.bilan

    window_form("/etats", s.window) <>
      "<section><h2>Compte de résultat (par nature)</h2><table><tbody>" <>
      Enum.map_join(@tcr, fn {k, label} ->
        "<tr><td>#{label}</td><td class=n>#{Money.format(s.tcr[k])}</td></tr>"
      end) <>
      "</tbody></table></section><section><h2>Bilan au #{s.window[:to]}</h2><table><tbody>" <>
      row("Actif non courant", b.actif.non_courant) <>
      row("Actif courant", b.actif.courant) <>
      row("<strong>Total actif</strong>", b.total_actif) <>
      row(
        "Capitaux propres (dont résultat #{Money.format(b.resultat)})",
        b.passif.capitaux_propres
      ) <>
      row("Passif non courant", b.passif.non_courant) <>
      row("Passif courant", b.passif.courant) <>
      row("<strong>Total passif</strong>", b.total_passif) <>
      "</tbody></table></section>" <> close_form(close_command_id, open_year)
  end

  defp row(label, amount),
    do: "<tr><td>#{label}</td><td class=n>#{Money.format(amount)}</td></tr>"

  defp close_form(command_id, year),
    do:
      "<form class=\"card\" method=\"post\" action=\"/cloture\" enctype=\"multipart/form-data\"><h2>Clôturer l'exercice #{year}</h2>" <>
        csrf() <>
        hidden("command_id", command_id) <>
        hidden("through", "#{year}-12-31") <>
        document_fields() <>
        "<button>Clôturer au 31/12/#{year}</button><p class=muted>Irréversible : aucune écriture datée de #{year} ne sera plus admise.</p></form>"

  def tva(s) do
    [from: from, to: _] = s.window
    g = s.g50

    "<form method=\"get\" action=\"/tva\"><label>Mois <input type=\"month\" name=\"mois\" value=\"#{Calendar.strftime(from, "%Y-%m")}\"></label><button>Afficher</button></form>" <>
      "<section><h2>Position TVA du #{from} au #{s.window[:to]}</h2><table><tbody>" <>
      row("TVA collectée (4457)", g.collectee) <>
      row("TVA déductible (4456)", g.deductible) <>
      row("<strong>TVA à payer</strong>", g.due) <>
      row("Précompte (crédit à reporter)", g.credit) <>
      "</tbody></table><p class=muted>Base de la déclaration G50 pour la TVA seulement ; les autres impôts et taxes de la G50 ne sont pas calculés ici.</p></section>"
  end
end
