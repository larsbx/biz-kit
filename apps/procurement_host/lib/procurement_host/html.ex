defmodule ProcurementHost.HTML do
  @moduledoc false
  alias CommerceCore.MerchantPilot.SourcingBounty
  alias CoopSubstrate.ULID
  @quote_fields ~w(quote_id merchant_business_id revision total_minor currency expires_at_ms source_ref)
  @fields %{
    "request" => ~w(buyer_business_id description quantity currency needed_by_ms consent_ref),
    "qualify" => ~w(evidence_ref),
    "quote" => @quote_fields,
    "sourced_quote" => @quote_fields ++ ~w(sourcing_business_id sourcing_ref),
    "post_bounty" => ~w(reward_minor maximum_total_minor terms_ref),
    "confirm_bounty" => ~w(attestation_id),
    "bounty_payment_evidence" => ~w(attestation_id),
    "accept" => ~w(quote_id revision buyer_business_id evidence_ref),
    "fulfill" => ~w(evidence_ref), "cancel" => ~w(evidence_ref),
    "dispute" => ~w(evidence_ref), "payment_evidence" => ~w(evidence_ref)
  }
  @integers ~w(quantity revision total_minor reward_minor maximum_total_minor)
  @dates ~w(needed_by_ms expires_at_ms)

  def escape(v) do
    v |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;") |> String.replace("'", "&#39;")
  end
  def page(title, body) do
    "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" <>
    "<title>" <> escape(title) <> " · Biz-kit</title><style>body{font:17px system-ui;max-width:1050px;margin:2rem auto;padding:0 1rem;color:#18232b;background:#fafafa}nav,a{margin-right:1rem}section,form{background:white;border:1px solid #d8dfe3;padding:1rem;margin:1rem 0}label{display:block;margin:.7rem 0}input,select,textarea,button{font:inherit;padding:.5rem;max-width:100%;box-sizing:border-box}textarea{width:100%}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:.6rem;border-bottom:1px solid #ddd}pre{white-space:pre-wrap;overflow-wrap:anywhere}.notice{border-left:4px solid #84704b;padding:1rem}</style>" <>
    "<body><nav><strong>Biz-kit / Procurement</strong> <a href=\"/requests\">Requests</a><a href=\"/orders\">Orders</a><a href=\"/operations\">Operations</a></nav><h1>" <>
    escape(title) <> "</h1>" <> body <> "<footer>Private coordinator pilot. External evidence is an attestation, not bank verification." <>
    "<form method=\"post\" action=\"/logout\">" <> csrf() <> "<button>Sign out</button></form></footer></body></html>"
  end
  def csrf, do: hidden("_csrf_token", Plug.CSRFProtection.get_csrf_token())
  def hidden(name, value), do: "<input type=\"hidden\" name=\"#{escape(name)}\" value=\"#{escape(value)}\">"
  def login, do: "<form method=\"post\" action=\"/login\">" <> csrf() <>
    "<label>Coordinator access token <input type=\"password\" name=\"token\" required autocomplete=\"current-password\"></label><button>Sign in</button></form>"

  def requests(s) do
    list(s.requests) <> "<h2>Record a business request</h2>" <>
      form(ULID.generate(), 0, "request", %{}, s.businesses)
  end
  def orders(s), do: list(Enum.filter(s.requests, &(map_size(&1.quotes) > 0)))
  def operations(s) do
    "<p class=\"notice\">Payment is unknown unless evidence is recorded. Evidence remains an unverified operator attestation. " <>
    "Costs, membership revenue and overhead are not calculated by this console.</p>" <>
    "<p>Enrolled businesses: " <> escape(Enum.join(s.businesses, ", ")) <> "</p>" <>
    list(s.requests) <> Enum.map_join(s.requests, fn r ->
      "<section><h2>" <> escape(elem(r.scope, 2)) <> "</h2><p>Payment evidence records: " <>
        to_string(length(r.payment_evidence)) <> "</p><pre>" <>
        escape(inspect(r.payment_evidence, pretty: true)) <> "</pre></section>"
    end)
  end
  defp list(rows) do
    "<table><thead><tr><th>Request</th><th>Buyer</th><th>Phase</th><th>Version</th></tr></thead><tbody>" <>
    Enum.map_join(rows, fn r ->
      id = elem(r.scope, 2)
      "<tr><td><a href=\"/requests/#{escape(id)}\">#{escape(id)}</a></td><td>#{escape(r.request.buyer_business_id)}</td>" <>
      "<td>#{escape(r.phase)}</td><td>#{r.version}</td></tr>"
    end) <> "</tbody></table>"
  end
  def detail(r, businesses) do
    id = elem(r.scope, 2)
    summary = "<p>Phase: <strong>#{escape(r.phase)}</strong>; version #{r.version}</p><pre>" <>
      escape(inspect(r.request, pretty: true)) <> "</pre>"
    quotes = "<h2>Current merchant quote revisions</h2>" <> Enum.map_join(Enum.sort(r.quotes), fn {_id, q} ->
      "<section><p>#{escape(q.quote_id)} / revision #{q.revision}: #{q.total_minor} #{escape(q.currency)} minor units</p><pre>" <>
      escape(inspect(q, pretty: true)) <> "</pre>" <> bounty_total(r[:bounty], q) <>
      if(r.phase == :qualified,
        do: form(id, r.version, "accept", %{"quote_id" => q.quote_id, "revision" => q.revision,
          "buyer_business_id" => r.request.buyer_business_id}, businesses), else: "") <> "</section>"
    end)
    frozen = if r.accepted_quote, do: "<h2>Frozen accepted quote</h2><pre>" <>
      escape(inspect(r.accepted_quote, pretty: true)) <> "</pre>", else: ""
    actions = case r.phase do
      :requested -> ["qualify", "cancel"]
      :qualified -> ["quote", "cancel"]
      :accepted ->
        case r[:dispatch_phase] do
          nil -> ["fulfill", "cancel", "dispute", "payment_evidence"]
          :requested -> ["cancel", "payment_evidence"]
          _ -> ["payment_evidence"]
        end
      :fulfilled -> ["dispute", "payment_evidence"]
      :disputed -> ["payment_evidence"]
      _ -> []
    end
    summary <> bounty_summary(r) <> quotes <> frozen <>
      Enum.map_join(actions ++ bounty_actions(r), &form(id, r.version, &1,
        if(&1 in ["quote", "sourced_quote"], do: %{"currency" => r.request.currency}, else: %{}),
        businesses)) <>
      "<h2>Evidence and command history</h2><pre>" <>
      escape(inspect(%{acceptance: r.acceptance_ref, outcome: r.outcome_ref,
        payment: r.payment_evidence, commands: r.receipts}, pretty: true, limit: :infinity)) <> "</pre>"
  end

  defp bounty_total(%{} = terms, %{sourcing_business_id: _} = quote) do
    "<p>Sourcing reward: #{terms.reward_minor}. All-in including reward: " <>
      "#{SourcingBounty.all_in_total(terms, quote)} #{escape(quote.currency)} minor units.</p>"
  end

  defp bounty_total(_, _), do: ""

  defp bounty_summary(%{bounty: terms} = row) do
    currency = escape(row.request.currency)
    "<section><h2>Sourcing bounty</h2><p>Fixed reward: #{terms.reward_minor} #{currency} minor units. " <>
      "All-in cap: #{terms.maximum_total_minor} #{currency} minor units.</p>" <>
      "<p>Terms reference: #{escape(terms.terms_ref)}</p>" <> bounty_status(terms.award, row.phase) <>
      "</section>"
  end

  defp bounty_summary(_), do: ""

  defp bounty_status(nil, _), do: "<p>No sourcing award recorded.</p>"

  defp bounty_status(award, phase) do
    status = cond do
      phase == :disputed -> "Disputed"
      phase == :cancelled -> "Cancelled"
      award.payment_ref -> "External payment evidence recorded (operator attestation)"
      award.closeout_ref -> "Reward recorded as earned (operator-attested closeout)"
      award.delivered_on_time -> "Awaiting closeout evidence"
      award.delivery_ref -> "Delivery missed the bounty deadline"
      true -> "Awarded, awaiting fulfillment"
    end

    "<p>#{status}. Sourcing business: #{escape(award.sourcing_business_id)}. " <>
      "Quote: #{escape(award.quote_id)} / revision #{award.quote_revision}.</p>"
  end

  defp bounty_actions(%{phase: :qualified, bounty: _}), do: ["sourced_quote"]

  defp bounty_actions(%{phase: :fulfilled, bounty: %{award: %{closeout_ref: closeout, payment_ref: nil}}})
       when is_binary(closeout), do: ["bounty_payment_evidence"]

  defp bounty_actions(%{phase: :fulfilled, bounty: %{award: %{delivered_on_time: true, closeout_ref: nil}}}),
    do: ["confirm_bounty"]

  defp bounty_actions(%{phase: phase, quotes: quotes} = row) when phase in [:requested, :qualified] do
    if map_size(quotes) == 0 and not Map.has_key?(row, :bounty), do: ["post_bounty"], else: []
  end

  defp bounty_actions(_), do: []

  def dispatch(%{phase: :accepted, dispatch: %{site: site}, dispatch_phase: phase} = row, _, context) do
    id = elem(row.scope, 2)
    phase_label = escape(phase)
    pickup = if phase == :accepted, do: code(context, id, "picked_up"), else: ""
    dropoff = code(context, id, "delivered")
    "<section><h2>Dispatch</h2><p>#{escape(site)} · #{phase_label}</p>#{pickup}#{dropoff}</section>"
  end

  def dispatch(%{phase: :accepted} = row, site, _context) when is_binary(site) do
    path = "/requests/" <> URI.encode(elem(row.scope, 2), &URI.char_unreserved?/1) <> "/dispatch"
    ~s(<form method="post" action="#{escape(path)}"><h3>Dispatch to #{escape(site)}</h3>) <>
      csrf() <> hidden("expected_version", row.version) <> "<button>Queue Dispatch handoff</button></form>"
  end

  def dispatch(%{dispatch_phase: :delivered}, _, _),
    do: "<section><h2>Dispatch</h2><p>Delivery recorded against this order.</p></section>"

  def dispatch(_, _, _), do: ""

  defp code(context, id, phase) do
    label = if phase == "picked_up", do: "Pickup code", else: "Drop-off code"
    "<p>#{label} <code>#{escape(ProcurementHost.Dispatch.code(context, id, phase))}</code></p>"
  end

  def form(id, version, action, fixed, businesses) do
    label = action_label(action)
    "<form method=\"post\" action=\"/requests/#{escape(id)}/#{escape(action)}\"><h3>#{escape(label)}</h3>" <>
    csrf() <> hidden("command_id", ULID.generate()) <> hidden("expected_version", version) <>
    bounty_instructions(action) <>
    Enum.map_join(@fields[action], fn name ->
      if Map.has_key?(fixed, name), do: hidden(name, fixed[name]), else: input(name, businesses)
    end) <> "<button>Record #{escape(label)}</button></form>"
  end

  defp action_label("post_bounty"), do: "sourcing bounty terms"
  defp action_label("confirm_bounty"), do: "bounty closeout"
  defp action_label(action), do: String.replace(action, "_", " ")

  defp bounty_instructions("post_bounty"),
    do: "<p>Enter the fixed reward and maximum buyer total including the reward, both in minor units.</p>"

  defp bounty_instructions("sourced_quote"),
    do: "<p>Enter the landed supplier quote with disclosed fees, before adding the sourcing reward.</p>"

  defp bounty_instructions("confirm_bounty"),
    do: "<p>Enter the signed governance attestation ID for buyer closeout on this request version.</p>"

  defp bounty_instructions("bounty_payment_evidence"),
    do: "<p>Enter the signed governance attestation ID for the separate external payment evidence.</p>"

  defp bounty_instructions(_), do: ""

  defp input(name, businesses) do
    label = escape(String.replace(name, "_", " "))
    field = cond do
      name in ~w(buyer_business_id merchant_business_id sourcing_business_id) ->
        "<select name=\"#{name}\" required>" <> Enum.map_join(businesses,
          &"<option value=\"#{escape(&1)}\">#{escape(&1)}</option>") <> "</select>"
      name == "description" -> "<textarea name=\"description\" maxlength=\"2000\" required></textarea>"
      name in @dates -> "<input type=\"datetime-local\" name=\"#{name}\" required> (UTC)"
      name in @integers -> "<input type=\"number\" name=\"#{name}\" min=\"0\" step=\"1\" required>"
      true -> "<input name=\"#{name}\" maxlength=\"256\" required>"
    end
    "<label>#{label} #{field}</label>"
  end
  def attributes(action, params) do
    case @fields[action] do
      nil -> {:error, :invalid_action}
      fields -> Enum.reduce_while(fields, {:ok, %{}}, fn name, {:ok, attrs} ->
        case value(name, params[name]) do
          {:ok, v} -> {:cont, {:ok, Map.put(attrs, name, v)}}
          error -> {:halt, error}
        end
      end)
    end
  end
  defp value(name, v) when name in @integers and is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_integer}
    end
  end
  defp value(name, v) when name in @dates and is_binary(v) do
    text = if byte_size(v) == 16, do: v <> ":00Z", else: v <> "Z"
    case DateTime.from_iso8601(text) do
      {:ok, date, 0} -> {:ok, DateTime.to_unix(date, :millisecond)}
      _ -> {:error, :invalid_utc_time}
    end
  end
  defp value(_, v) when is_binary(v), do: {:ok, v}
  defp value(_, _), do: {:error, :missing_field}
end
