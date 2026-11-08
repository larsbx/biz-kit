defmodule ProcurementHost.HTML do
  @moduledoc false
  alias CoopSubstrate.ULID
  @fields %{
    "request" => ~w(buyer_business_id description quantity currency needed_by_ms consent_ref),
    "qualify" => ~w(evidence_ref),
    "quote" => ~w(quote_id merchant_business_id revision total_minor currency expires_at_ms source_ref),
    "accept" => ~w(quote_id revision buyer_business_id evidence_ref),
    "fulfill" => ~w(evidence_ref), "cancel" => ~w(evidence_ref),
    "dispute" => ~w(evidence_ref), "payment_evidence" => ~w(evidence_ref)
  }
  @integers ~w(quantity revision total_minor)
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
      escape(inspect(q, pretty: true)) <> "</pre>" <>
      if(r.phase == :qualified,
        do: form(id, r.version, "accept", %{"quote_id" => q.quote_id, "revision" => q.revision,
          "buyer_business_id" => r.request.buyer_business_id}, businesses), else: "") <> "</section>"
    end)
    frozen = if r.accepted_quote, do: "<h2>Frozen accepted quote</h2><pre>" <>
      escape(inspect(r.accepted_quote, pretty: true)) <> "</pre>", else: ""
    actions = case r.phase do
      :requested -> ["qualify", "cancel"]
      :qualified -> ["quote", "cancel"]
      :accepted -> ["fulfill", "cancel", "dispute", "payment_evidence"]
      :fulfilled -> ["dispute", "payment_evidence"]
      :disputed -> ["payment_evidence"]
      _ -> []
    end
    summary <> quotes <> frozen <> Enum.map_join(actions, &form(id, r.version, &1,
      if(&1 == "quote", do: %{"currency" => r.request.currency}, else: %{}), businesses)) <>
      "<h2>Evidence and command history</h2><pre>" <>
      escape(inspect(%{acceptance: r.acceptance_ref, outcome: r.outcome_ref,
        payment: r.payment_evidence, commands: r.receipts}, pretty: true, limit: :infinity)) <> "</pre>"
  end
  def form(id, version, action, fixed, businesses) do
    "<form method=\"post\" action=\"/requests/#{escape(id)}/#{escape(action)}\"><h3>#{escape(String.replace(action, "_", " "))}</h3>" <>
    csrf() <> hidden("command_id", ULID.generate()) <> hidden("expected_version", version) <>
    Enum.map_join(@fields[action], fn name ->
      if Map.has_key?(fixed, name), do: hidden(name, fixed[name]), else: input(name, businesses)
    end) <> "<button>Record #{escape(String.replace(action, "_", " "))}</button></form>"
  end
  defp input(name, businesses) do
    label = escape(String.replace(name, "_", " "))
    field = cond do
      name in ~w(buyer_business_id merchant_business_id) ->
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
